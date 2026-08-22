#!/usr/bin/env bash

if ! declare -F die >/dev/null 2>&1; then
  _spawn_preflight_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  # shellcheck source=lib/spawn-arch/common.sh
  source "$_spawn_preflight_dir/common.sh"
  unset _spawn_preflight_dir
fi

_linux_kernel_version_supported() {
  local version="$1"
  local major minor patch

  if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))?([^0-9].*)?$ ]]; then
    return 1
  fi
  major=$((10#${BASH_REMATCH[1]}))
  minor=$((10#${BASH_REMATCH[2]}))
  patch="${BASH_REMATCH[4]:-0}"
  patch=$((10#$patch))

  ((major > 7 || (major == 7 && (minor > 2 || (minor == 2 && patch >= 0)))))
}

assert_linux_kernel_version() {
  local version="$1"

  if ! _linux_kernel_version_supported "$version"; then
    die "unsupported Linux kernel version: $version (required Linux kernel >= 7.2.0)" 65
    return $?
  fi
}

_linux_kernel_available_version() {
  local metadata version

  if [[ -n "${FAKE_LINUX_KERNEL_VERSION:-}" ]]; then
    printf '%s\n' "$FAKE_LINUX_KERNEL_VERSION"
    return 0
  fi
  pacman -Sy --noconfirm >/dev/null 2>&1 || return $?
  metadata="$(pacman -Si linux 2>/dev/null)" || return $?
  version="$(awk -F: '$1 ~ /^[[:space:]]*Version[[:space:]]*$/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' <<<"$metadata")"
  [[ -n "$version" ]] || return 1
  printf '%s\n' "$version"
}

_archinstall_version_supported() {
  local version="$1"
  local major minor

  if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+)([^0-9].*)?)?$ ]]; then
    return 1
  fi

  major=$((10#${BASH_REMATCH[1]}))
  minor=$((10#${BASH_REMATCH[2]}))
  ((major == 4 && minor == 4))
}

assert_archinstall_version() {
  local version="$1"

  if ! _archinstall_version_supported "$version"; then
    die "unsupported Archinstall version: $version (required Archinstall 4.4)" 65
    return $?
  fi
}

_archinstall_version() {
  local raw

  if [[ -n "${FAKE_ARCHINSTALL_VERSION:-}" ]]; then
    printf '%s\n' "$FAKE_ARCHINSTALL_VERSION"
    return 0
  fi

  if ! raw="$(archinstall --version 2>/dev/null)"; then
    return 1
  fi
  if [[ "$raw" =~ (^|[[:space:]])([0-9]+\.[0-9]+(\.[0-9]+[^[:space:]]*)?)($|[[:space:]]) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

_required_commands_check() {
  local -a required=(
    archinstall bash curl findmnt git jq lsblk mountpoint pacman python3 readlink sha256sum sync uname
  )
  local -a missing=()
  local command_name

  if [[ -n "${FAKE_REQUIRED_COMMANDS_OK:-}" ]]; then
    printf '%s\t%s\n' "$FAKE_REQUIRED_COMMANDS_OK" "injected result"
    return 0
  fi

  for command_name in "${required[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done

  if ((${#missing[@]} == 0)); then
    printf 'true\tall required commands are available\n'
  else
    printf 'false\tmissing: %s\n' "${missing[*]}"
  fi
}

_network_ok() {
  if [[ -n "${FAKE_NETWORK_OK:-}" ]]; then
    [[ "$FAKE_NETWORK_OK" == true ]]
    return
  fi
  curl --fail --silent --show-error --head \
    --connect-timeout 3 --max-time 5 https://archlinux.org/ >/dev/null 2>&1
}

_hardware_hints() {
  local cpu_ok=false intel_gpu_ok=false nvidia_gpu_ok=false memory_ok=false model_ok=false
  local pci_output="" memory_kib=0 model=""

  grep -q 'vendor_id[[:space:]]*: GenuineIntel' /proc/cpuinfo 2>/dev/null && cpu_ok=true
  if command -v lspci >/dev/null 2>&1; then
    pci_output="$(lspci -nn 2>/dev/null || true)"
    grep -Eiq 'VGA|3D|Display' <<<"$pci_output" && grep -Eiq 'Intel' <<<"$pci_output" && intel_gpu_ok=true
    grep -Eiq 'VGA|3D|Display' <<<"$pci_output" && grep -Eiq 'NVIDIA' <<<"$pci_output" && nvidia_gpu_ok=true
  fi
  memory_kib="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null || printf '0')"
  [[ "$memory_kib" =~ ^[0-9]+$ ]] || memory_kib=0
  ((memory_kib >= 60 * 1024 * 1024)) && memory_ok=true
  if [[ -r /sys/class/dmi/id/product_name ]]; then
    IFS= read -r model </sys/class/dmi/id/product_name || true
    [[ "$model" == *GU606AX* ]] && model_ok=true
  fi

  jq -n \
    --argjson intel_cpu "$cpu_ok" \
    --argjson intel_gpu "$intel_gpu_ok" \
    --argjson nvidia_gpu "$nvidia_gpu_ok" \
    --argjson memory "$memory_ok" \
    --argjson model "$model_ok" \
    '{
      intel_cpu_hint: $intel_cpu,
      intel_gpu_hint: $intel_gpu,
      nvidia_gpu_hint: $nvidia_gpu,
      memory_64g_hint: $memory,
      target_model_hint: $model
    }'
}

doctor_collect_json() {
  local efi_dir="${FAKE_EFI_DIR:-/sys/firmware/efi}"
  local efivarfs_dir="${FAKE_EFIVARFS_DIR:-/sys/firmware/efi/efivars}"
  local effective_uid="${FAKE_EUID:-$EUID}"
  local machine="${FAKE_UNAME_M:-$(uname -m)}"
  local clock_epoch="${FAKE_CLOCK_EPOCH:-$(date -u +%s)}"
  local root_ok=false uefi_ok=false efivarfs_ok=false network_ok=false clock_ok=false
  local version_ok=false kernel_ok=false commands_ok commands_detail
  local archinstall_version="unavailable" linux_kernel_version="unavailable" discovered_kernel_version
  local hardware

  [[ "$effective_uid" == 0 ]] && root_ok=true
  [[ -d "$efi_dir" ]] && uefi_ok=true
  [[ -d "$efivarfs_dir" ]] && efivarfs_ok=true
  _network_ok && network_ok=true
  [[ "$clock_epoch" =~ ^[0-9]+$ ]] && ((clock_epoch >= 1704067200)) && clock_ok=true

  if archinstall_version="$(_archinstall_version)" && _archinstall_version_supported "$archinstall_version"; then
    version_ok=true
  fi
  if discovered_kernel_version="$(_linux_kernel_available_version)"; then
    linux_kernel_version="$discovered_kernel_version"
    if _linux_kernel_version_supported "$linux_kernel_version"; then
      kernel_ok=true
    fi
  fi

  IFS=$'\t' read -r commands_ok commands_detail < <(_required_commands_check)
  hardware="$(_hardware_hints)"

  jq -n \
    --argjson root "$root_ok" \
    --argjson uefi "$uefi_ok" \
    --argjson efivarfs "$efivarfs_ok" \
    --argjson network "$network_ok" \
    --argjson clock "$clock_ok" \
    --argjson version "$version_ok" \
    --argjson kernel "$kernel_ok" \
    --argjson commands "$commands_ok" \
    --argjson arch "$([[ "$machine" == x86_64 ]] && printf true || printf false)" \
    --arg archinstall_version "$archinstall_version" \
    --arg linux_kernel_version "$linux_kernel_version" \
    --arg commands_detail "$commands_detail" \
    --argjson hardware "$hardware" '
      def check($ok; $required; $detail):
        {ok: $ok, required: $required, detail: $detail};
      {
        checks: {
          root: check($root; true; "must run as root"),
          uefi: check($uefi; true; "UEFI firmware directory"),
          efivarfs: check($efivarfs; true; "EFI variables filesystem"),
          network: check($network; true; "HTTPS access to archlinux.org"),
          clock: check($clock; true; "UTC clock is later than 2024-01-01"),
          archinstall_version: check($version; true; $archinstall_version),
          linux_kernel: check($kernel; true; $linux_kernel_version),
          required_commands: check($commands; true; $commands_detail),
          x86_64: check($arch; true; "x86_64 userspace"),
          intel_cpu_hint: check($hardware.intel_cpu_hint; false; "Intel CPU target hint"),
          intel_gpu_hint: check($hardware.intel_gpu_hint; false; "Intel GPU target hint"),
          nvidia_gpu_hint: check($hardware.nvidia_gpu_hint; false; "NVIDIA GPU target hint"),
          memory_64g_hint: check($hardware.memory_64g_hint; false; "64 GiB target hint"),
          target_model_hint: check($hardware.target_model_hint; false; "GU606AX target hint")
        }
      }
      | .ok = ([.checks[] | select(.required) | .ok] | all)
    '
}

doctor_assert_installable() {
  local report failed

  report="$(doctor_collect_json)" || return $?
  if jq -e '.ok' >/dev/null <<<"$report"; then
    return 0
  fi

  failed="$(jq -r '[.checks | to_entries[] | select(.value.required and (.value.ok | not)) | .key] | join(", ")' <<<"$report")"
  die "doctor failed required checks: $failed" 69
  return $?
}

cmd_doctor() {
  local report

  report="$(doctor_collect_json)" || return $?
  printf '%s\n' "$report"
  jq -e '.ok' >/dev/null <<<"$report"
}
