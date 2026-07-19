#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO_ROOT
QEMU_PLAN="$REPO_ROOT/tests/integration/fixtures/qemu-plan.json"
readonly QEMU_PLAN
QEMU_RUNTIME_BASE="$REPO_ROOT/tests/integration/.runtime"
readonly QEMU_RUNTIME_BASE
QEMU_OWNED_PID=""

cleanup_owned_qemu() {
  if [[ -n "$QEMU_OWNED_PID" ]]; then
    qemu_stop || true
  fi
}
trap cleanup_owned_qemu EXIT

die() {
  printf 'spawn-arch integration: %s\n' "$1" >&2
  return "${2:-1}"
}

runtime_resolve() {
  local requested="${SPAWN_QEMU_RUNTIME:-$QEMU_RUNTIME_BASE}"
  local base runtime parent

  base="$(realpath -m -- "$QEMU_RUNTIME_BASE")" || return $?
  runtime="$(realpath -m -- "$requested")" || return $?
  parent="$(dirname -- "$runtime")"
  if [[ "$runtime" != "$base" && "$parent" != "$base" ]]; then
    die "runtime must stay under $base" 65
    return $?
  fi
  if [[ -L "$requested" ]]; then
    die 'runtime must not be a symbolic link' 65
    return $?
  fi
  printf '%s\n' "$runtime"
}

path_assert_qemu_safe() {
  local path="$1"

  [[ "$path" != *$'\n'* && "$path" != *$'\r'* && "$path" != *,* ]] || {
    die "QEMU path contains an unsupported character: $path" 65
    return $?
  }
  [[ "$path" == /* ]] || {
    die "QEMU path must be absolute: $path" 65
    return $?
  }
}

readable_file_resolve() {
  local label="$1"
  local requested="$2"
  local resolved

  [[ -n "$requested" ]] || {
    die "$label is required" 64
    return $?
  }
  resolved="$(realpath -e -- "$requested" 2>/dev/null)" || {
    die "$label is not a readable regular file: $requested" 66
    return $?
  }
  [[ -f "$resolved" && -r "$resolved" ]] || {
    die "$label is not a readable regular file: $requested" 66
    return $?
  }
  path_assert_qemu_safe "$resolved" || return $?
  printf '%s\n' "$resolved"
}

ovmf_default() {
  local kind="$1"
  local candidate
  local -a candidates=()

  case "$kind" in
    code)
      candidates=(
        /usr/share/OVMF/OVMF_CODE_4M.fd
        /usr/share/edk2/x64/OVMF_CODE.4m.fd
        /usr/share/edk2-ovmf/x64/OVMF_CODE.fd
      )
      ;;
    vars)
      candidates=(
        /usr/share/OVMF/OVMF_VARS_4M.fd
        /usr/share/edk2/x64/OVMF_VARS.4m.fd
        /usr/share/edk2-ovmf/x64/OVMF_VARS.fd
      )
      ;;
    *) return 64 ;;
  esac
  for candidate in "${candidates[@]}"; do
    if [[ -r "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

source_ovmf_path() {
  local kind="$1"
  local variable default_path=""

  case "$kind" in
    code) variable="${SPAWN_QEMU_OVMF_CODE:-}" ;;
    vars) variable="${SPAWN_QEMU_OVMF_VARS:-}" ;;
    *) return 64 ;;
  esac
  if [[ -z "$variable" ]]; then
    default_path="$(ovmf_default "$kind" 2>/dev/null || true)"
    variable="$default_path"
  fi
  readable_file_resolve "OVMF $kind image" "$variable"
}

qemu_acceleration() {
  if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    printf 'kvm\n'
  else
    printf 'tcg\n'
  fi
}

required_tools_assert() {
  local command_name
  local -a missing=()
  local -a required=(
    awk bats bsdtar expect flock git jq mcopy mformat mmd qemu-img
    qemu-system-x86_64 realpath sgdisk sha256sum socat stat tar timeout
  )

  [[ "${SPAWN_QEMU_SKIP_TOOLS:-}" != true ]] || return 0
  for command_name in "${required[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done
  if ((${#missing[@]} > 0)); then
    die "missing QEMU integration tools: ${missing[*]}" 69
    return $?
  fi
}

iso_verify() {
  local iso="$1"
  local expected="${SPAWN_QEMU_ISO_SHA256:-}"
  local actual

  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || {
    die 'SPAWN_QEMU_ISO_SHA256 must be the verified lowercase SHA-256' 64
    return $?
  }
  actual="$(sha256sum -- "$iso")" || return $?
  actual="${actual%% *}"
  [[ "$actual" == "$expected" ]] || {
    die 'Arch ISO SHA-256 does not match SPAWN_QEMU_ISO_SHA256' 65
    return $?
  }
}

source_tree_prepare() {
  local runtime="$1"
  local source_dir="$runtime/source"
  local commit status

  commit="$(git -C "$REPO_ROOT" rev-parse --verify HEAD)" || return $?
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || return 65
  status="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal)" || return $?
  [[ -z "$status" ]] || {
    die 'QEMU integration requires a clean committed source tree' 65
    return $?
  }
  install -d -m 0700 -- "$source_dir" || return $?
  git -C "$REPO_ROOT" archive --format=tar HEAD | tar -xf - -C "$source_dir" || return $?
  printf '%s\n' "$commit" >"$source_dir/SOURCE_COMMIT"
  chmod -R a-w -- "$source_dir"
}

archiso_standard_entry() {
  local iso="$1"
  local entry entry_text kernel_path cmdline
  local -a candidates=() matches=() initrd_paths=()

  mapfile -t candidates < <(
    bsdtar -tf "$iso" | awk '/(^|\/)loader\/entries\/[^/]+[.]conf$/ {print}'
  )
  for entry in "${candidates[@]}"; do
    entry_text="$(bsdtar -xOf "$iso" "$entry")" || return $?
    kernel_path="$(awk '$1 == "linux" {print $2; exit}' <<<"$entry_text")"
    cmdline="$(awk '$1 == "options" {sub(/^[^[:space:]]+[[:space:]]+/, ""); print; exit}' <<<"$entry_text")"
    mapfile -t initrd_paths < <(awk '$1 == "initrd" {print $2}' <<<"$entry_text")
    if [[ "$kernel_path" == /arch/boot/x86_64/vmlinuz-linux &&
      "$cmdline" == *archisobasedir=* && "$cmdline" == *archisosearchuuid=* &&
      " $cmdline " != *' accessibility=on '* && ${#initrd_paths[@]} -gt 0 ]]; then
      matches+=("$entry")
    fi
  done
  ((${#matches[@]} == 1)) || {
    die 'Arch ISO must contain exactly one standard x86_64 systemd-boot entry' 65
    return $?
  }
  printf '%s\n' "${matches[0]}"
}

archiso_boot_extract() {
  local runtime="$1"
  local iso="$2"
  local entry entry_text kernel_path cmdline archive_path temporary
  local -a initrd_paths=()

  entry="$(archiso_standard_entry "$iso")" || return $?
  entry_text="$(bsdtar -xOf "$iso" "$entry")" || return $?
  kernel_path="$(awk '$1 == "linux" {print $2; exit}' <<<"$entry_text")"
  cmdline="$(awk '$1 == "options" {sub(/^[^[:space:]]+[[:space:]]+/, ""); print; exit}' <<<"$entry_text")"
  mapfile -t initrd_paths < <(awk '$1 == "initrd" {print $2}' <<<"$entry_text")
  [[ "$kernel_path" == /* && -n "$cmdline" ]] || return 65
  ((${#initrd_paths[@]} > 0)) || return 65

  archive_path="${kernel_path#/}"
  temporary="$runtime/archiso-vmlinuz.tmp"
  bsdtar -xOf "$iso" "$archive_path" >"$temporary" || return $?
  chmod 0600 -- "$temporary"
  mv -f -- "$temporary" "$runtime/archiso-vmlinuz"

  temporary="$runtime/archiso-initramfs-integration.img.tmp"
  : >"$temporary"
  for archive_path in "${initrd_paths[@]}"; do
    archive_path="${archive_path#/}"
    bsdtar -xOf "$iso" "$archive_path" >>"$temporary" || return $?
  done
  chmod 0600 -- "$temporary"
  mv -f -- "$temporary" "$runtime/archiso-initramfs-integration.img"
  printf '%s\n' "$cmdline" >"$runtime/archiso-cmdline"
  chmod 0600 -- "$runtime/archiso-cmdline"
}

systemd_boot_path() {
  local requested="${SPAWN_QEMU_SYSTEMD_BOOT:-}"
  local candidate
  local -a candidates=(
    /usr/lib/systemd/boot/efi/systemd-bootx64.efi
    /usr/lib/systemd/boot/efi/systemd-bootx64.efi.stub
  )

  if [[ -n "$requested" ]]; then
    readable_file_resolve 'systemd-boot EFI binary' "$requested"
    return
  fi
  for candidate in "${candidates[@]}"; do
    if [[ -r "$candidate" ]]; then
      readable_file_resolve 'systemd-boot EFI binary' "$candidate"
      return
    fi
  done
  die 'systemd-boot EFI binary is unavailable' 66
}

uefi_live_media_prepare() {
  local runtime="$1"
  local boot_binary image loader entry

  boot_binary="$(systemd_boot_path)" || return $?
  image="$runtime/integration-boot.raw"
  loader="$runtime/integration-loader.conf"
  entry="$runtime/integration-entry.conf"
  qemu-img create -q -f raw "$image" 536870912 || return $?
  mformat -i "$image" -F :: || return $?
  mmd -i "$image" ::/EFI ::/EFI/BOOT ::/EFI/Linux ::/loader ::/loader/entries || return $?
  mcopy -i "$image" "$boot_binary" ::/EFI/BOOT/BOOTX64.EFI || return $?
  mcopy -i "$image" "$runtime/archiso-vmlinuz" ::/EFI/Linux/archiso-vmlinuz || return $?
  mcopy -i "$image" "$runtime/archiso-initramfs-integration.img" ::/EFI/Linux/archiso-initramfs.img || return $?
  printf '%s\n' \
    'default spawn-arch-integration.conf' \
    'timeout 0' \
    'editor no' >"$loader"
  {
    printf '%s\n' \
      'title Spawn Arch integration live ISO' \
      'linux /EFI/Linux/archiso-vmlinuz' \
      'initrd /EFI/Linux/archiso-initramfs.img'
    printf 'options %s console=ttyS0,115200n8 systemd.show_status=1\n' "$(<"$runtime/archiso-cmdline")"
  } >"$entry"
  mcopy -i "$image" "$loader" ::/loader/loader.conf || return $?
  mcopy -i "$image" "$entry" ::/loader/entries/spawn-arch-integration.conf || return $?
  rm -f -- "$loader" "$entry"
  chmod 0400 -- "$image"
}

disk_images_prepare() {
  local runtime="$1"
  local target_size sentinel_size

  target_size="$(jq -er '.machine.target.virtual_size_bytes' "$QEMU_PLAN")" || return $?
  sentinel_size="$(jq -er '.machine.sentinel.virtual_size_bytes' "$QEMU_PLAN")" || return $?
  [[ "$target_size" =~ ^[1-9][0-9]*$ && "$sentinel_size" =~ ^[1-9][0-9]*$ ]] || return 65

  qemu-img create -q -f qcow2 -o preallocation=metadata "$runtime/target.qcow2" "$target_size" || return $?
  qemu-img create -q -f raw "$runtime/sentinel.raw" "$sentinel_size" || return $?
  sgdisk --clear \
    --new=1:2048:+512M --typecode=1:ef00 --change-name=1:'Windows ESP' \
    --new=2:0:0 --typecode=2:0700 --change-name=2:'Windows Data' \
    "$runtime/sentinel.raw" >/dev/null || return $?
  chmod 0400 -- "$runtime/sentinel.raw"
  sha256sum -- "$runtime/sentinel.raw" >"$runtime/sentinel.before.sha256"
  chmod 0600 -- "$runtime/sentinel.before.sha256"
}

runtime_reset() {
  local runtime

  runtime="$(runtime_resolve)" || return $?
  if qemu_pid_read "$runtime" >/dev/null 2>&1; then
    die 'refusing to reset runtime with a recorded QEMU process' 65
    return $?
  fi
  rm -f -- "$runtime/qemu.pid"
  if [[ -d "$runtime" ]]; then
    find "$runtime" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  fi
  install -d -m 0700 -- "$runtime"
}

runtime_prepare() {
  local runtime iso vars_source lock_file

  required_tools_assert || return $?
  runtime="$(runtime_resolve)" || return $?
  install -d -m 0700 -- "$runtime" || return $?
  lock_file="$runtime/prepare.lock"
  exec {prepare_lock_fd}>"$lock_file" || return $?
  flock -n "$prepare_lock_fd" || {
    die 'another QEMU preparation owns the runtime lock' 75
    return $?
  }
  if [[ -e "$runtime/target.qcow2" || -e "$runtime/sentinel.raw" ]]; then
    die 'runtime already contains disk images; run reset explicitly' 65
    return $?
  fi

  iso="$(readable_file_resolve 'Arch ISO' "${SPAWN_QEMU_ISO:-}")" || return $?
  iso_verify "$iso" || return $?
  vars_source="$(source_ovmf_path vars)" || return $?
  source_ovmf_path code >/dev/null || return $?
  install -m 0600 -- "$vars_source" "$runtime/OVMF_VARS.fd" || return $?
  install -d -m 0700 -- "$runtime/exchange" || return $?
  source_tree_prepare "$runtime" || return $?
  archiso_boot_extract "$runtime" "$iso" || return $?
  uefi_live_media_prepare "$runtime" || return $?
  disk_images_prepare "$runtime" || return $?
  printf 'prepared\n' >"$runtime/prepared"
  chmod 0600 -- "$runtime/prepared"
  exec {prepare_lock_fd}>&-
}

runtime_assert_prepared() {
  local runtime="$1"
  local path
  local -a required=(
    prepared OVMF_VARS.fd target.qcow2 sentinel.raw sentinel.before.sha256
    archiso-vmlinuz archiso-initramfs-integration.img archiso-cmdline integration-boot.raw
    source/SOURCE_COMMIT
  )

  for path in "${required[@]}"; do
    [[ -s "$runtime/$path" ]] || {
      die "prepared runtime file is missing: $path" 66
      return $?
    }
  done
  [[ "$(stat -c %a -- "$runtime/sentinel.raw")" == 400 ]] || {
    die 'sentinel image must remain host read-only' 65
    return $?
  }
}

runtime_secrets_assert() {
  local runtime="$1"
  local path

  for path in luks-passphrase user-password; do
    path="$runtime/secrets/$path"
    [[ -s "$path" && "$(stat -c %a -- "$path")" == 600 ]] || {
      die 'integration secrets must be non-empty mode-0600 runtime files' 65
      return $?
    }
  done
}

qemu_pid_read() {
  local runtime="$1"
  local pid command_line

  [[ -r "$runtime/qemu.pid" ]] || return 1
  pid="$(<"$runtime/qemu.pid")"
  [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/$pid/cmdline" ]] || return 1
  command_line="$(tr '\0' ' ' <"/proc/$pid/cmdline")"
  [[ " $command_line " == *' spawn-arch-integration'* ]] || return 1
  printf '%s\n' "$pid"
}

qemu_start() {
  local mode="$1"
  local runtime argv_file pid attempt
  local -a argv=()

  runtime="$(runtime_resolve)" || return $?
  runtime_assert_prepared "$runtime" || return $?
  if qemu_pid_read "$runtime" >/dev/null 2>&1; then
    die 'QEMU integration guest is already running' 65
    return $?
  fi
  rm -f -- "$runtime/qemu.pid" "$runtime/qmp.sock" "$runtime/serial.sock"
  argv_file="$(mktemp)" || return $?
  if ! qemu_argv "$mode" >"$argv_file"; then
    rm -f -- "$argv_file"
    return 1
  fi
  mapfile -d '' -t argv <"$argv_file"
  rm -f -- "$argv_file"

  "${argv[@]}" >"$runtime/qemu.stderr.log" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" >"$runtime/qemu.pid"
  QEMU_OWNED_PID="$pid"
  chmod 0600 -- "$runtime/qemu.pid" "$runtime/qemu.stderr.log"
  for ((attempt = 0; attempt < 300; attempt++)); do
    if [[ -S "$runtime/qmp.sock" && -S "$runtime/serial.sock" ]]; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" || true
      rm -f -- "$runtime/qemu.pid"
      die 'QEMU exited before its control sockets became ready' 70
      return $?
    fi
    sleep 0.1
  done
  qemu_stop || true
  die 'QEMU control sockets did not become ready' 75
}

qemu_stop() {
  local runtime pid attempt

  runtime="$(runtime_resolve)" || return $?
  if ! pid="$(qemu_pid_read "$runtime")"; then
    rm -f -- "$runtime/qemu.pid"
    QEMU_OWNED_PID=""
    return 0
  fi
  if [[ -S "$runtime/qmp.sock" ]]; then
    printf '%s\n' \
      '{"execute":"qmp_capabilities"}' \
      '{"execute":"quit"}' | socat - "UNIX-CONNECT:$runtime/qmp.sock" >/dev/null 2>&1 || true
  fi
  for ((attempt = 0; attempt < 100; attempt++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid"
    for ((attempt = 0; attempt < 50; attempt++)); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
  fi
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid"
  fi
  wait "$pid" 2>/dev/null || true
  rm -f -- "$runtime/qemu.pid" "$runtime/qmp.sock" "$runtime/serial.sock"
  QEMU_OWNED_PID=""
}

console_run() {
  local mode="$1"
  local transcript="$2"
  local runtime

  runtime="$(runtime_resolve)" || return $?
  runtime_secrets_assert "$runtime" || return $?
  timeout --kill-after=30s 7200s expect "$REPO_ROOT/tests/integration/console.exp" \
    "$mode" "$runtime/serial.sock" "$runtime/secrets" "$transcript"
}

sentinel_hash_verify() {
  local runtime="$1"
  local expected actual

  expected="$(awk 'NR == 1 {print $1; exit}' "$runtime/sentinel.before.sha256")"
  actual="$(sha256sum -- "$runtime/sentinel.raw")"
  actual="${actual%% *}"
  [[ "$expected" =~ ^[0-9a-f]{64}$ && "$actual" == "$expected" ]] || {
    die 'sentinel disk changed' 74
    return $?
  }
  printf '%s\n' "$actual"
}

scenario_install() {
  local runtime before after result temporary status=0

  runtime="$(runtime_resolve)" || return $?
  runtime_assert_prepared "$runtime" || return $?
  runtime_secrets_assert "$runtime" || return $?
  before="$(sentinel_hash_verify "$runtime")" || return $?
  install -d -m 0700 -- "$runtime/results" || return $?

  qemu_start live || return $?
  if console_run live-install "$runtime/live-install.serial.log"; then
    :
  else
    status=$?
  fi
  qemu_stop || true
  ((status == 0)) || return "$status"

  qemu_start installed || return $?
  if console_run first-boot "$runtime/first-boot.serial.log"; then
    :
  else
    status=$?
  fi
  qemu_stop || true
  ((status == 0)) || return "$status"

  after="$(sentinel_hash_verify "$runtime")" || return $?
  [[ -s "$runtime/exchange/install-live.json" && -s "$runtime/exchange/first-boot.json" ]] || return 70
  result="$runtime/results/install.json"
  temporary="$(mktemp "$result.tmp.XXXXXX")" || return $?
  jq -n \
    --arg before "$before" \
    --arg after "$after" \
    --slurpfile installer "$runtime/exchange/install-live.json" \
    --slurpfile first_boot "$runtime/exchange/first-boot.json" '{
      schema_version: 1,
      scenario: "install",
      sentinel: {
        before_sha256: $before,
        after_sha256: $after,
        unchanged: ($before == $after)
      },
      installer: ($installer[0] + {luks_unlocked: true}),
      first_boot: $first_boot[0]
    }' >"$temporary" || return $?
  chmod 0600 -- "$temporary"
  mv -f -- "$temporary" "$result"
  sync -f -- "$result"
}

installed_phase_run() {
  local mode="$1"
  local runtime status=0

  runtime="$(runtime_resolve)" || return $?
  qemu_start installed || return $?
  if console_run "$mode" "$runtime/$mode.serial.log"; then
    :
  else
    status=$?
  fi
  qemu_stop || true
  return "$status"
}

power_loss_case() {
  local key="$1"
  local trigger_mode="$2"
  local inspect_mode="$3"
  local result_phase="$4"
  local runtime target main_target vars main_vars baseline marker result status=0

  runtime="$(runtime_resolve)" || return $?
  target="$runtime/target.qcow2"
  main_target="$runtime/target.main.qcow2"
  vars="$runtime/OVMF_VARS.fd"
  main_vars="$runtime/OVMF_VARS.main.fd"
  baseline="$runtime/update-blessed-base.qcow2"
  marker="$runtime/exchange/power-$result_phase.ready"
  result="$runtime/exchange/power-$result_phase.json"
  [[ -s "$baseline" && ! -e "$main_target" && ! -e "$main_vars" ]] || return 66
  rm -f -- "$marker" "$result"

  mv -- "$target" "$main_target" || return $?
  mv -- "$vars" "$main_vars" || {
    mv -- "$main_target" "$target"
    return 1
  }
  if install -m 0600 -- "$runtime/update-blessed-OVMF_VARS.fd" "$vars"; then
    :
  else
    status=$?
  fi
  if ((status == 0)); then
    if qemu-img create -q -f qcow2 -F qcow2 -b "$baseline" "$target"; then
      :
    else
      status=$?
    fi
  fi

  if ((status == 0)); then
    qemu_start installed || status=$?
  fi
  if ((status == 0)); then
    if console_run "$trigger_mode" "$runtime/$key-trigger.serial.log"; then
      :
    else
      status=$?
    fi
  fi
  qemu_stop || true
  if ((status == 0)) && [[ ! -s "$marker" ]]; then status=70; fi

  if ((status == 0)); then
    installed_phase_run "$inspect_mode" || status=$?
  fi
  if ((status == 0)) && [[ ! -s "$result" ]]; then status=70; fi
  sentinel_hash_verify "$runtime" >/dev/null || status=$?

  rm -f -- "$target" "$vars"
  mv -- "$main_target" "$target" || status=$?
  mv -- "$main_vars" "$vars" || status=$?
  return "$status"
}

scenario_update_recovery() {
  local runtime result temporary

  runtime="$(runtime_resolve)" || return $?
  [[ -s "$runtime/results/install.json" ]] || {
    die 'install scenario must pass before update-recovery' 65
    return $?
  }
  installed_phase_run update-stage || return $?
  installed_phase_run update-bless || return $?
  qemu-img convert -q -O qcow2 "$runtime/target.qcow2" "$runtime/update-blessed-base.qcow2" || return $?
  install -m 0600 -- "$runtime/OVMF_VARS.fd" "$runtime/update-blessed-OVMF_VARS.fd" || return $?
  installed_phase_run update-allow || return $?

  power_loss_case state-temp power-state-temp inspect-state-temp state_temp || return $?
  power_loss_case last-good-temp power-last-good-temp inspect-last-good-temp last_good_temp || return $?
  power_loss_case current-candidate power-current-candidate inspect-current-candidate current_candidate || return $?

  result="$runtime/results/update-recovery.json"
  temporary="$(mktemp "$result.tmp.XXXXXX")" || return $?
  jq -n \
    --slurpfile stage "$runtime/exchange/update-stage.json" \
    --slurpfile bless "$runtime/exchange/update-bless.json" \
    --slurpfile allow "$runtime/exchange/update-allow.json" \
    --slurpfile state_temp "$runtime/exchange/power-state_temp.json" \
    --slurpfile last_good_temp "$runtime/exchange/power-last_good_temp.json" \
    --slurpfile current_candidate "$runtime/exchange/power-current_candidate.json" '
      {
        schema_version: 1,
        scenario: "update-recovery",
        hook_order: $stage[0].hook_order,
        pinned_pre_snapshot_id: $stage[0].pinned_pre_snapshot_id,
        last_good_sha256: $stage[0].last_good_sha256,
        second_transaction_blocked: $stage[0].second_transaction_blocked,
        non_gpu_checks_passed: $bless[0].non_gpu_checks_passed,
        blessed: $bless[0].blessed,
        next_transaction_allowed: $allow[0].next_transaction_allowed,
        power_loss_windows: {
          state_temp: $state_temp[0],
          last_good_temp: $last_good_temp[0],
          current_candidate: $current_candidate[0]
        }
      }
    ' >"$temporary" || return $?
  chmod 0600 -- "$temporary"
  mv -f -- "$temporary" "$result"
  sync -f -- "$result"
  sentinel_hash_verify "$runtime" >/dev/null
}

scenario_rollback() {
  local runtime result temporary baseline_temp

  runtime="$(runtime_resolve)" || return $?
  [[ -s "$runtime/results/update-recovery.json" ]] || {
    die 'update-recovery scenario must pass before rollback' 65
    return $?
  }
  installed_phase_run rescue-stage || return $?
  installed_phase_run rollback || return $?
  installed_phase_run rollback-bless || return $?

  baseline_temp="$runtime/update-blessed-base.qcow2.new"
  qemu-img convert -q -O qcow2 "$runtime/target.qcow2" "$baseline_temp" || return $?
  mv -f -- "$baseline_temp" "$runtime/update-blessed-base.qcow2"
  install -m 0600 -- "$runtime/OVMF_VARS.fd" "$runtime/update-blessed-OVMF_VARS.fd" || return $?
  power_loss_case post-snapper power-post-snapper inspect-post-snapper post_snapper_pre_state_commit || return $?

  result="$runtime/results/rollback.json"
  temporary="$(mktemp "$result.tmp.XXXXXX")" || return $?
  jq -n \
    --slurpfile rescue "$runtime/exchange/rescue-stage.json" \
    --slurpfile rollback "$runtime/exchange/rollback.json" \
    --slurpfile bless "$runtime/exchange/rollback-bless.json" \
    --slurpfile power "$runtime/exchange/power-post_snapper_pre_state_commit.json" '
      {
        schema_version: 1,
        scenario: "rollback",
        last_good_selected: $rollback[0].last_good_selected,
        latest_resolved_to_pinned_pre: (
          $rollback[0].latest_resolved_to_pinned_pre and
          $rollback[0].target_snapshot_id == $rescue[0].pinned_pre_snapshot_id
        ),
        default_subvolume_transitioned: $rollback[0].default_subvolume_transitioned,
        active_equals_default: $bless[0].active_equals_default,
        blessed: $bless[0].blessed,
        seed_retired: $bless[0].seed_retired,
        post_snapper_power_loss: $power[0]
      }
    ' >"$temporary" || return $?
  chmod 0600 -- "$temporary"
  mv -f -- "$temporary" "$result"
  sync -f -- "$result"
  sentinel_hash_verify "$runtime" >/dev/null
}

qemu_argv() {
  local mode="$1"
  local runtime iso code vars_source vars machine_accel cpu memory target_serial sentinel_serial
  local target sentinel exchange serial_socket qmp_socket
  local boot_media
  local -a argv=()

  [[ "$mode" == live || "$mode" == installed ]] || {
    die "unknown QEMU boot mode: $mode" 64
    return $?
  }
  runtime="$(runtime_resolve)" || return $?
  install -d -m 0700 -- "$runtime" "$runtime/exchange" || return $?
  iso="$(readable_file_resolve 'Arch ISO' "${SPAWN_QEMU_ISO:-}")" || return $?
  code="$(source_ovmf_path code)" || return $?
  vars_source="$(source_ovmf_path vars)" || return $?
  : "$vars_source"
  vars="$runtime/OVMF_VARS.fd"
  target="$runtime/target.qcow2"
  sentinel="$runtime/sentinel.raw"
  exchange="$runtime/exchange"
  serial_socket="$runtime/serial.sock"
  qmp_socket="$runtime/qmp.sock"
  boot_media="$runtime/integration-boot.raw"
  for path in "$vars" "$target" "$sentinel" "$exchange" "$serial_socket" "$qmp_socket" "$boot_media"; do
    path_assert_qemu_safe "$path" || return $?
  done

  machine_accel="$(qemu_acceleration)"
  memory="$(jq -er '.machine.memory_mib' "$QEMU_PLAN")" || return $?
  target_serial="$(jq -er '.machine.target.serial' "$QEMU_PLAN")" || return $?
  sentinel_serial="$(jq -er '.machine.sentinel.serial' "$QEMU_PLAN")" || return $?
  if [[ "$machine_accel" == kvm ]]; then
    cpu=host
  else
    cpu=max
  fi
  argv=(
    qemu-system-x86_64
    -name "spawn-arch-integration,process=spawn-arch-integration"
    -machine "q35,accel=$machine_accel,pflash0=ovmf-code,pflash1=ovmf-vars"
    -cpu "$cpu"
    -smp 4
    -m "$memory"
    -display none
    -no-reboot
    -qmp "unix:$qmp_socket,server=on,wait=off"
    -serial "unix:$serial_socket,server=on,wait=off"
    -blockdev "driver=file,node-name=ovmf-code-file,filename=$code,read-only=on"
    -blockdev "driver=raw,node-name=ovmf-code,file=ovmf-code-file,read-only=on"
    -blockdev "driver=file,node-name=ovmf-vars-file,filename=$vars"
    -blockdev "driver=raw,node-name=ovmf-vars,file=ovmf-vars-file"
    -blockdev "driver=file,node-name=target-file,filename=$target"
    -blockdev "driver=qcow2,node-name=target,file=target-file"
    -device "virtio-blk-pci,drive=target,serial=$target_serial,bootindex=1"
    -blockdev "driver=file,node-name=sentinel-file,filename=$sentinel,read-only=on"
    -blockdev "driver=raw,node-name=sentinel,file=sentinel-file,read-only=on"
    -device "virtio-blk-pci,drive=sentinel,serial=$sentinel_serial"
    -blockdev "driver=file,node-name=archiso-file,filename=$iso,read-only=on"
    -blockdev "driver=raw,node-name=archiso,file=archiso-file,read-only=on"
    -device "virtio-scsi-pci,id=archiso-scsi"
    -device "scsi-cd,drive=archiso,bus=archiso-scsi.0"
    -virtfs "local,id=source,path=$runtime/source,mount_tag=spawn_arch,security_model=none,readonly=on"
    -virtfs "local,id=exchange,path=$exchange,mount_tag=spawn_exchange,security_model=mapped-xattr"
    -netdev "user,id=network"
    -device "virtio-net-pci,netdev=network"
    -device virtio-rng-pci
  )
  if [[ "$mode" == live ]]; then
    argv+=(
      -blockdev "driver=file,node-name=integration-boot-file,filename=$boot_media,read-only=on"
      -blockdev "driver=raw,node-name=integration-boot,file=integration-boot-file,read-only=on"
      -device "virtio-blk-pci,drive=integration-boot,serial=ARCHISO-BOOT,bootindex=0"
    )
  fi
  printf '%s\0' "${argv[@]}"
}

inspect_argv() {
  local mode="$1"
  local argv_file
  local -a argv=()

  argv_file="$(mktemp)" || return $?
  if ! qemu_argv "$mode" >"$argv_file"; then
    rm -f -- "$argv_file"
    return 1
  fi
  mapfile -d '' -t argv <"$argv_file"
  rm -f -- "$argv_file"
  jq -n --args '$ARGS.positional' -- "${argv[@]}"
}

usage() {
  cat <<'EOF'
Usage: tests/integration/run-qemu.sh <command> [arguments]

Commands:
  reset                        Delete only the validated disposable runtime
  prepare                      Build isolated source, firmware, and disk images
  inspect-archiso-entry ISO    Print the selected standard Arch boot entry
  inspect-argv live|installed  Print the exact QEMU argv as JSON
  install                      Install and assert first-boot invariants
  update-recovery              Exercise critical updates and power recovery
  rollback                     Exercise last-good rescue and Btrfs rollback
EOF
}

main() {
  local command_name="${1:---help}"
  shift || true

  case "$command_name" in
    reset) runtime_reset ;;
    prepare) runtime_prepare ;;
    inspect-archiso-entry) archiso_standard_entry "${1:-}" ;;
    inspect-argv) inspect_argv "${1:-}" ;;
    install) scenario_install ;;
    update-recovery) scenario_update_recovery ;;
    rollback) scenario_rollback ;;
    -h | --help) usage ;;
    *)
      usage >&2
      die "unknown command: $command_name" 64
      ;;
  esac
}

main "$@"
