#!/usr/bin/env bash

_spawn_finalize_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

_load_finalize_dependency() {
  local function_name="$1"
  local module="$2"

  if ! declare -F "$function_name" >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$_spawn_finalize_dir/$module.sh"
  fi
}

_load_finalize_dependency die common
_load_finalize_dependency packages_json config
_load_finalize_dependency runtime_init runtime-state
_load_finalize_dependency payload_install payload
_load_finalize_dependency target_storage_json target-storage

_finalize_contract_error() {
  die "finalization contract failed: $1" 65
}

_finalize_run() {
  local step="$1"
  shift
  local status command_text

  log_info "finalize step: $step"
  if "$@"; then
    return 0
  else
    status=$?
  fi
  printf -v command_text '%q ' "$@"
  command_text="${command_text% }"
  if ((${#command_text} > 512)); then
    command_text="${command_text:0:509}..."
  fi
  printf >&2 'spawn-arch: error: finalize step failed: %s (exit %d)\n' "$step" "$status"
  printf >&2 'spawn-arch: error: command: %s\n' "$command_text"
  return "$status"
}

_write_text_atomic() {
  local path="$1"
  local mode="$2"
  local content="$3"
  local temporary

  install -d -m 0755 -- "$(dirname -- "$path")" || return $?
  temporary="$(mktemp "$path.tmp.XXXXXX")" || return $?
  chmod "$mode" -- "$temporary"
  if ! printf '%s\n' "$content" >"$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  atomic_replace "$temporary" "$path"
}

rewrite_fstab() {
  local fstab_path="$1"
  local target_root="$2"
  local source mountpoint filesystem options _dump pass extra
  local root_source="" boot_source=""
  local -A sources=() seen=()
  local -a required=(/ /home /var/log /var/cache/pacman/pkg /.snapshots /boot)
  local temporary

  if [[ ! -r "$fstab_path" ]]; then
    die "target fstab is unreadable" 65
    return $?
  fi
  while read -r source mountpoint filesystem options _dump pass extra; do
    [[ -n "$source" && "$source" != \#* ]] || continue
    if [[ -n "${extra:-}" || -z "${pass:-}" ]]; then
      die "fstab contains a malformed entry" 65
      return $?
    fi
    if [[ "$filesystem" == swap ]]; then
      continue
    fi
    case "$mountpoint" in
      / | /home | /var/log | /var/cache/pacman/pkg | /.snapshots)
        [[ "$filesystem" == btrfs ]] || {
          die "expected Btrfs at $mountpoint" 65
          return $?
        }
        ;;
      /boot)
        [[ "$filesystem" == vfat ]] || {
          die "expected vfat at /boot" 65
          return $?
        }
        ;;
      *)
        die "unexpected fstab mountpoint: $mountpoint" 65
        return $?
        ;;
    esac
    if [[ -n "${seen[$mountpoint]:-}" ]]; then
      die "duplicate fstab mountpoint: $mountpoint" 65
      return $?
    fi
    seen[$mountpoint]=1
    sources[$mountpoint]="$source"
  done <"$fstab_path"

  for mountpoint in "${required[@]}"; do
    if [[ -z "${seen[$mountpoint]:-}" ]]; then
      die "fstab is missing required mountpoint: $mountpoint" 65
      return $?
    fi
  done
  mountpoint=/
  root_source="${sources[$mountpoint]}"
  mountpoint=/boot
  boot_source="${sources[$mountpoint]}"
  for mountpoint in /home /var/log /var/cache/pacman/pkg /.snapshots; do
    if [[ "${sources[$mountpoint]}" != "$root_source" ]]; then
      die "Btrfs subvolume sources do not match root" 65
      return $?
    fi
  done

  temporary="$fstab_path.spawn-arch.new"
  rm -f -- "$temporary"
  install -m 0644 /dev/null "$temporary" || return $?
  {
    printf '%s / btrfs noatime,compress=zstd:1,nodiscard 0 0\n' "$root_source"
    printf '%s /home btrfs noatime,compress=zstd:1,nodiscard,subvol=@home 0 0\n' "$root_source"
    printf '%s /var/log btrfs noatime,compress=zstd:1,nodiscard,subvol=@log 0 0\n' "$root_source"
    printf '%s /var/cache/pacman/pkg btrfs noatime,compress=zstd:1,nodiscard,subvol=@pkg 0 0\n' "$root_source"
    printf '%s /.snapshots btrfs noatime,compress=zstd:1,nodiscard,subvol=@snapshots 0 0\n' "$root_source"
    printf '%s /boot vfat fmask=0077,dmask=0077 0 2\n' "$boot_source"
  } >"$temporary"
  if ! arch-chroot "$target_root" findmnt --verify --tab-file "/${temporary#"$target_root"/}" >/dev/null; then
    rm -f -- "$temporary"
    return 65
  fi
  atomic_replace "$temporary" "$fstab_path"
}

fstab_assert_contract() {
  local fstab_path="$1"
  local target_root="$2"
  local source mountpoint filesystem options _dump _pass extra
  local -A expected_options=()
  local -A seen=() sources=()
  local root_source

  expected_options["/"]='noatime,compress=zstd:1,nodiscard'
  expected_options["/home"]='noatime,compress=zstd:1,nodiscard,subvol=@home'
  expected_options["/var/log"]='noatime,compress=zstd:1,nodiscard,subvol=@log'
  expected_options["/var/cache/pacman/pkg"]='noatime,compress=zstd:1,nodiscard,subvol=@pkg'
  expected_options["/.snapshots"]='noatime,compress=zstd:1,nodiscard,subvol=@snapshots'
  expected_options["/boot"]='fmask=0077,dmask=0077'

  while read -r source mountpoint filesystem options _dump _pass extra; do
    [[ -n "$source" && "$source" != \#* ]] || continue
    if [[ "$filesystem" == swap || -n "${extra:-}" || -z "${expected_options[$mountpoint]:-}" ]]; then
      return 1
    fi
    [[ "$options" == "${expected_options[$mountpoint]}" ]] || return 1
    if [[ "$mountpoint" == / ]]; then
      [[ "$filesystem" == btrfs && "$options" != *subvol=* && "$options" != *subvolid=* ]] || return 1
    elif [[ "$mountpoint" == /boot ]]; then
      [[ "$filesystem" == vfat ]] || return 1
    else
      [[ "$filesystem" == btrfs ]] || return 1
    fi
    [[ -z "${seen[$mountpoint]:-}" ]] || return 1
    seen[$mountpoint]=1
    sources[$mountpoint]="$source"
  done <"$fstab_path"
  ((${#seen[@]} == 6)) || return 1
  mountpoint=/
  root_source="${sources[$mountpoint]}"
  for mountpoint in /home /var/log /var/cache/pacman/pkg /.snapshots; do
    [[ "${sources[$mountpoint]}" == "$root_source" ]] || return 1
  done
  arch-chroot "$target_root" findmnt --verify --tab-file "/${fstab_path#"$target_root"/}" >/dev/null
}

pacman_storage_prepare() {
  local target_root="$1"
  local path
  local -a paths=(
    /var/lib/pacman
    /var/lib/pacman/local
    /var/lib/pacman/sync
    /var/cache/pacman
    /var/cache/pacman/pkg
  )

  for path in "${paths[@]}"; do
    install -d -m 0755 -- "$target_root$path" || return $?
  done
}

pacman_storage_assert_contract() {
  local target_root="$1"
  local username="$2"
  local path metadata
  local -a paths=(
    /var/lib/pacman
    /var/lib/pacman/local
    /var/lib/pacman/sync
    /var/cache/pacman
    /var/cache/pacman/pkg
  )

  for path in "${paths[@]}"; do
    metadata="$(stat -c '%a' -- "$target_root$path" 2>/dev/null)" ||
      _finalize_contract_error "pacman storage path is unavailable: $path" || return $?
    [[ "$metadata" == '755' ]] ||
      _finalize_contract_error "pacman storage path has unsafe mode: $path" || return $?
  done

  arch-chroot "$target_root" runuser -u "$username" -- pacman -Qq >/dev/null ||
    _finalize_contract_error 'installed user cannot read the pacman package database' || return $?
  arch-chroot "$target_root" runuser -u alpm -- test -x /var/cache/pacman/pkg ||
    _finalize_contract_error 'pacman download user cannot traverse the package cache' || return $?
}

_ensure_locale_gen() {
  local locale_gen="$1"
  local line normalized found_en=false found_ru=false temporary

  temporary="$(mktemp "$locale_gen.tmp.XXXXXX")" || return $?
  chmod 0644 -- "$temporary"
  while IFS= read -r line || [[ -n "$line" ]]; do
    normalized="${line#\#}"
    normalized="${normalized# }"
    case "$normalized" in
      'en_US.UTF-8 UTF-8')
        if [[ "$found_en" == false ]]; then printf 'en_US.UTF-8 UTF-8\n' >>"$temporary"; fi
        found_en=true
        ;;
      'ru_RU.UTF-8 UTF-8')
        if [[ "$found_ru" == false ]]; then printf 'ru_RU.UTF-8 UTF-8\n' >>"$temporary"; fi
        found_ru=true
        ;;
      *) printf '%s\n' "$line" >>"$temporary" ;;
    esac
  done <"$locale_gen"
  [[ "$found_en" == true ]] || printf 'en_US.UTF-8 UTF-8\n' >>"$temporary"
  [[ "$found_ru" == true ]] || printf 'ru_RU.UTF-8 UTF-8\n' >>"$temporary"
  atomic_replace "$temporary" "$locale_gen"
}

_btrfs_set_initial_default() {
  local target_root="$1"
  local root_source top_level seed_id default_output

  root_source="$(awk '$2 == "/" {print $1; exit}' "$target_root/etc/fstab")"
  [[ -n "$root_source" ]] || return 65
  runtime_init || return $?
  top_level="$SPAWN_RUNTIME_DIR/finalize-root"
  if [[ -e "$top_level" ]]; then
    die "private finalizer mount path already exists: $top_level" 65
    return $?
  fi
  install -d -m 0700 -- "$top_level" || return $?
  if ! mount -t btrfs -o subvolid=5 -- "$root_source" "$top_level"; then
    rmdir -- "$top_level"
    return 1
  fi
  mount_journal_register "$top_level" || return $?
  seed_id="$(btrfs_subvolume_id_from_show "$(LC_ALL=C btrfs subvolume show "$top_level/@")")" || {
    die "could not identify the initial @ subvolume" 65
    return $?
  }
  btrfs subvolume set-default "$seed_id" "$top_level" || return $?
  default_output="$(btrfs subvolume get-default "$top_level")" || return $?
  if [[ ! "$default_output" =~ ^ID[[:space:]]+$seed_id([[:space:]]|$) ]]; then
    die "Btrfs default subvolume verification failed" 65
    return $?
  fi
  mount_journal_cleanup || return $?
  rmdir -- "$top_level"
  printf '%s\n' "$seed_id"
}

_ensure_boot_initialize() {
  local repository_root

  declare -F boot_initialize >/dev/null 2>&1 && return 0
  repository_root="${REPO_ROOT:-$(cd -- "$_spawn_finalize_dir/../.." && pwd -P)}"
  if [[ ! -r "$repository_root/payload/usr/local/lib/spawn-arch/boot-state.sh" ]]; then
    die "durable boot-state library is unavailable" 70
    return $?
  fi
  # shellcheck source=/dev/null
  source "$repository_root/payload/usr/local/lib/spawn-arch/boot-state.sh"
  declare -F boot_initialize >/dev/null 2>&1
}

workstation_policy_assert_contract() {
  local target_root="$1"
  local username="${2:-}"
  local repository_root="${REPO_ROOT:-$(cd -- "$_spawn_finalize_dir/../.." && pwd -P)}"
  local applet group_members relative
  local -a policy_files=(
    etc/docker/daemon.json
    etc/firewalld/zones/spawn-workstation.xml
    etc/systemd/journald.conf.d/10-spawn-arch.conf
    etc/systemd/system/docker.service.d/10-spawn-arch-ordering.conf
    etc/systemd/system/systemd-pcrlogin@.service.d/10-spawn-arch-disable.conf
    etc/sysctl.d/60-spawn-arch-security.conf
  )

  for relative in "${policy_files[@]}"; do
    cmp -s -- "$repository_root/payload/$relative" "$target_root/$relative" ||
      _finalize_contract_error "managed workstation file differs: /$relative" || return $?
  done
  jq -e '
    . == {
      "live-restore": true,
      "log-driver": "local",
      "log-opts": {"max-file": "3", "max-size": "20m"},
      "no-new-privileges": true,
      "runtimes": {
        "nvidia": {
          "args": [],
          "path": "nvidia-container-runtime"
        }
      }
    } and
    (has("hosts") | not) and
    (has("default-runtime") | not)
  ' "$target_root/etc/docker/daemon.json" >/dev/null ||
    _finalize_contract_error 'Docker daemon policy is invalid' || return $?
  [[ -x "$target_root/usr/bin/nvidia-container-runtime" ]] ||
    _finalize_contract_error 'NVIDIA container runtime is not installed' || return $?
  [[ -n "$username" && -r "$target_root/etc/group" ]] ||
    _finalize_contract_error 'installed username or target group database is unavailable' || return $?
  group_members="$(awk -F: '$1 == "docker" {print $4; exit}' "$target_root/etc/group")"
  [[ ",$group_members," != *",$username,"* ]] ||
    _finalize_contract_error "installed user $username must not belong to the docker group" || return $?
  applet="$target_root/etc/xdg/autostart/firewall-applet.desktop"
  [[ -r "$applet" ]] ||
    _finalize_contract_error 'packaged firewall-applet XDG autostart entry is unavailable' || return $?
  grep -Eq '^Exec=(/usr/bin/)?firewall-applet([[:space:]]|$)' "$applet" ||
    _finalize_contract_error 'firewall-applet XDG autostart command is invalid' || return $?
  ! grep -Eqi '^Hidden[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$applet" ||
    _finalize_contract_error 'firewall-applet XDG autostart entry is disabled' || return $?
  arch-chroot "$target_root" dockerd --validate --config-file=/etc/docker/daemon.json >/dev/null || return $?
  [[ "$(arch-chroot "$target_root" firewall-offline-cmd --get-default-zone)" == spawn-workstation ]] ||
    _finalize_contract_error 'firewalld default zone is not spawn-workstation' || return $?
  [[ "$(arch-chroot "$target_root" firewall-offline-cmd --get-log-denied)" == unicast ]] ||
    _finalize_contract_error 'firewalld log-denied policy is not unicast' || return $?
  arch-chroot "$target_root" firewall-offline-cmd --check-config >/dev/null
}

boot_ui_assert_contract() {
  local target_root="$1"
  local repository_root="${REPO_ROOT:-$(cd -- "$_spawn_finalize_dir/../.." && pwd -P)}"

  cmp -s -- "$repository_root/payload/etc/plymouth/plymouthd.conf" \
    "$target_root/etc/plymouth/plymouthd.conf" ||
    _finalize_contract_error 'managed Plymouth configuration differs' || return $?
  grep -Fx 'HOOKS=(base systemd plymouth autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)' \
    "$target_root/etc/mkinitcpio.conf.d/spawn-arch.conf" >/dev/null ||
    _finalize_contract_error 'mkinitcpio Plymouth hook ordering is invalid' || return $?
}

remove_legacy_power_profile_unit() {
  local target_root="$1"

  arch-chroot "$target_root" systemctl disable spawn-arch-initial-power-profile.service \
    >/dev/null 2>&1 || true
  rm -f -- \
    "$target_root/etc/systemd/system/spawn-arch-initial-power-profile.service" \
    "$target_root/etc/systemd/system/multi-user.target.wants/spawn-arch-initial-power-profile.service" \
    "$target_root/etc/systemd/system/graphical.target.wants/spawn-arch-initial-power-profile.service"
}

remove_archinstall_fallback_uki() {
  local target_root="$1"

  [[ -s "$target_root/boot/EFI/Linux/spawn-arch-current.efi" &&
    -s "$target_root/boot/EFI/Linux/spawn-arch-last-good.efi" &&
    -s "$target_root/boot/loader/spawn-arch-state.json" ]] || {
    _finalize_contract_error 'managed boot artifacts are unavailable before Archinstall UKI cleanup'
    return $?
  }
  rm -f -- "$target_root/boot/EFI/Linux/arch-linux.efi"
}

user_services_assert_contract() {
  local target_root="$1"

  arch-chroot "$target_root" systemctl --global is-enabled ssh-agent.service >/dev/null 2>&1 ||
    _finalize_contract_error 'ssh-agent.service is not globally enabled' || return $?
  if arch-chroot "$target_root" systemctl is-enabled sshd.service >/dev/null 2>&1; then
    _finalize_contract_error 'sshd.service is enabled'
  fi
}

ssh_wallet_assert_contract() {
  local target_root="$1"
  local repository_root="${REPO_ROOT:-$(cd -- "$_spawn_finalize_dir/../.." && pwd -P)}"
  local pam_path relative effective_ssh
  local -a managed_files=(
    etc/environment.d/10-ssh-agent.conf
    etc/ssh/ssh_config.d/20-spawn-arch-agent.conf
  )

  for relative in "${managed_files[@]}"; do
    cmp -s -- "$repository_root/payload/$relative" "$target_root/$relative" ||
      _finalize_contract_error "managed SSH file differs: /$relative" || return $?
  done
  [[ -x "$target_root/usr/bin/ksshaskpass" ]] ||
    _finalize_contract_error '/usr/bin/ksshaskpass is missing or not executable' || return $?

  if [[ -r "$target_root/etc/pam.d/plasmalogin" ]]; then
    pam_path="$target_root/etc/pam.d/plasmalogin"
  elif [[ -r "$target_root/usr/lib/pam.d/plasmalogin" ]]; then
    pam_path="$target_root/usr/lib/pam.d/plasmalogin"
  else
    _finalize_contract_error 'effective plasmalogin PAM file is missing'
    return $?
  fi
  grep -Eq '^[[:space:]]*-?auth[[:space:]].*pam_kwallet5\.so([[:space:]]|$)' "$pam_path" ||
    _finalize_contract_error "effective plasmalogin PAM is missing auth pam_kwallet5.so: $pam_path" || return $?
  grep -Eq '^[[:space:]]*-?session[[:space:]].*pam_kwallet5\.so([[:space:]]|$)' "$pam_path" ||
    _finalize_contract_error "effective plasmalogin PAM is missing session pam_kwallet5.so: $pam_path" || return $?
  effective_ssh="$(arch-chroot "$target_root" ssh -G example.invalid 2>/dev/null)" ||
    _finalize_contract_error 'could not evaluate effective OpenSSH configuration' || return $?
  grep -Eq '^addkeystoagent[[:space:]]+(yes|true)$' <<<"$effective_ssh" ||
    _finalize_contract_error 'effective OpenSSH configuration does not set addkeystoagent yes' || return $?
}

shell_assert_contract() {
  local target_root="$1"
  local username="$2"
  local repository_root="${REPO_ROOT:-$(cd -- "$_spawn_finalize_dir/../.." && pwd -P)}"
  local passwd_shell relative
  local -a managed_files=(
    etc/environment.d/20-starship.conf
    etc/starship.toml
    etc/zsh/zshrc
  )

  for relative in "${managed_files[@]}"; do
    cmp -s -- "$repository_root/payload/$relative" "$target_root/$relative" ||
      _finalize_contract_error "managed shell file differs: /$relative" || return $?
  done
  [[ -x "$target_root/usr/bin/zsh" ]] ||
    _finalize_contract_error '/usr/bin/zsh is missing or not executable' || return $?
  [[ -r "$target_root/usr/share/fonts/TTF/FiraCodeNerdFontMono-Regular.ttf" ]] ||
    _finalize_contract_error 'FiraCode Nerd Font Mono regular face is missing' || return $?
  passwd_shell="$(awk -F: -v user="$username" '$1 == user { print $7; found=1 } END { if (!found) exit 1 }' \
    "$target_root/etc/passwd")" ||
    _finalize_contract_error "installed user is missing from /etc/passwd: $username" || return $?
  [[ "$passwd_shell" == /usr/bin/zsh ]] ||
    _finalize_contract_error "installed user login shell is $passwd_shell, expected /usr/bin/zsh" || return $?
  arch-chroot "$target_root" zsh -n /etc/zsh/zshrc >/dev/null ||
    _finalize_contract_error 'managed /etc/zsh/zshrc fails zsh syntax validation' || return $?
}

finalize_target() {
  local target_root="$1"
  local plan_path="$2"
  local plan_json seed_id luks luks_uuid cmdline preset loader unit username
  local -a units=(
    NetworkManager.service bluetooth.service firewalld.service
    plasmalogin.service switcheroo-control.service power-profiles-daemon.service
    docker.service arch-audit.timer
    fstrim.timer spawn-arch-btrfs-scrub.timer snapper-cleanup.timer
  )

  target_root="$(readlink -f -- "$target_root")" || return $?
  [[ -d "$target_root" && -r "$plan_path" && -r "$target_root/etc/fstab" ]] ||
    _finalize_contract_error 'target root, plan, or target fstab is unavailable' || return $?
  plan_json="$(<"$plan_path")"
  username="$(jq -er '.system.username | select(type == "string" and length > 0)' <<<"$plan_json")" ||
    _finalize_contract_error 'plan has no valid system username' || return $?
  _finalize_run 'load durable boot-state library' _ensure_boot_initialize || return $?
  _finalize_run 'rewrite and validate target fstab' \
    rewrite_fstab "$target_root/etc/fstab" "$target_root" || return $?
  seed_id="$(_finalize_run 'select initial Btrfs default subvolume' \
    _btrfs_set_initial_default "$target_root")" || return $?
  _finalize_run 'normalize pacman storage permissions' \
    pacman_storage_prepare "$target_root" || return $?
  _finalize_run 'install managed payload' payload_install "$target_root" || return $?
  _finalize_run 'remove legacy power-profile unit' \
    remove_legacy_power_profile_unit "$target_root" || return $?
  _finalize_run 'set closed firewalld zone' \
    arch-chroot "$target_root" firewall-offline-cmd --set-default-zone=spawn-workstation || return $?
  _finalize_run 'set firewalld denied-packet logging' \
    arch-chroot "$target_root" firewall-offline-cmd --set-log-denied=unicast || return $?
  _finalize_run 'validate workstation policy' workstation_policy_assert_contract "$target_root" "$username" || return $?
  _finalize_run 'validate Plymouth boot UI' boot_ui_assert_contract "$target_root" || return $?

  luks="$(_finalize_run 'inspect encrypted target storage' target_storage_json "$target_root")" || return $?
  luks_uuid="$(jq -r '.luks_uuid' <<<"$luks")"
  cmdline="rd.luks.name=${luks_uuid}=cryptroot rd.luks.options=${luks_uuid}=discard root=/dev/mapper/cryptroot rw quiet splash"
  _finalize_run 'write kernel command line' \
    _write_text_atomic "$target_root/etc/kernel/cmdline" 0644 "$cmdline" || return $?

  preset=$'ALL_kver="/boot/vmlinuz-linux"\nPRESETS=(\x27current\x27)\ncurrent_uki="/boot/EFI/Linux/spawn-arch-current.efi"\ncurrent_cmdline="/etc/kernel/cmdline"\ncurrent_options=(--osrelease /etc/spawn-arch/uki-current.os-release)'
  _finalize_run 'write mkinitcpio UKI preset' \
    _write_text_atomic "$target_root/etc/mkinitcpio.d/linux.preset" 0644 "$preset" || return $?
  loader=$'default spawn-arch-current*\ntimeout 3\neditor yes'
  _finalize_run 'write systemd-boot loader policy' \
    _write_text_atomic "$target_root/boot/loader/loader.conf" 0644 "$loader" || return $?
  _finalize_run 'enable configured locales' _ensure_locale_gen "$target_root/etc/locale.gen" || return $?
  _finalize_run 'write primary locale' \
    _write_text_atomic "$target_root/etc/locale.conf" 0644 'LANG=en_US.UTF-8' || return $?
  _finalize_run 'write virtual-console keymap' \
    _write_text_atomic "$target_root/etc/vconsole.conf" 0644 "KEYMAP=$(jq -r '.system.keymap' <<<"$plan_json")" || return $?
  _finalize_run 'write hostname' \
    _write_text_atomic "$target_root/etc/hostname" 0644 "$(jq -r '.system.hostname' <<<"$plan_json")" || return $?
  _finalize_run 'register root Snapper configuration' \
    _write_text_atomic "$target_root/etc/conf.d/snapper" 0644 'SNAPPER_CONFIGS="root"' || return $?

  _finalize_run 'locale generation' arch-chroot "$target_root" locale-gen || return $?
  _finalize_run 'lock root password' arch-chroot "$target_root" passwd -l root || return $?
  _finalize_run 'set user login shell' \
    arch-chroot "$target_root" usermod --shell /usr/bin/zsh "$username" || return $?
  _finalize_run 'validate wheel sudo policy' \
    arch-chroot "$target_root" visudo -cf /etc/sudoers.d/10-wheel || return $?
  _finalize_run 'validate KWallet SSH contract' ssh_wallet_assert_contract "$target_root" || return $?
  _finalize_run 'validate Zsh and Starship contract' shell_assert_contract "$target_root" "$username" || return $?
  _finalize_run 'build current unified kernel image' arch-chroot "$target_root" mkinitcpio -p linux || return $?
  _finalize_run 'initialize durable boot artifacts' boot_initialize "$target_root" "$seed_id" "$cmdline" || return $?
  _finalize_run 'remove Archinstall fallback UKI' \
    remove_archinstall_fallback_uki "$target_root" || return $?
  _finalize_run 'install systemd-boot' arch-chroot "$target_root" bootctl --esp-path=/boot install || return $?
  for unit in "${units[@]}"; do
    _finalize_run "enable system service $unit" arch-chroot "$target_root" systemctl enable "$unit" || return $?
  done
  _finalize_run 'enable user SSH agent' \
    arch-chroot "$target_root" systemctl --global enable ssh-agent.service || return $?
  _finalize_run 'disable SSH server' arch-chroot "$target_root" systemctl disable sshd.service || return $?
  _finalize_run 'disable Snapper timeline' \
    arch-chroot "$target_root" systemctl disable snapper-timeline.timer || return $?
  _finalize_run 'validate root Snapper registration' \
    arch-chroot "$target_root" snapper --no-dbus -c root list >/dev/null || return $?
  _finalize_run 'validate pacman storage permissions' \
    pacman_storage_assert_contract "$target_root" "$username" || return $?
  _finalize_run 'validate final fstab contract' \
    fstab_assert_contract "$target_root/etc/fstab" "$target_root"
}

_verification_add() {
  local output_name="$1"
  local name="$2"
  local ok="$3"
  local detail="$4"
  local current updated

  current="${!output_name}"
  updated="$(jq -c --arg name "$name" --argjson ok "$ok" --arg detail "$detail" \
    '. + [{name: $name, ok: $ok, required: true, detail: $detail}]' <<<"$current")" || return $?
  printf -v "$output_name" '%s' "$updated"
}

verify_target_offline() {
  local target_root="$1"
  local plan_path="$2"
  local checks='[]' ok output state current_hash last_good_hash luks root_status boot_list
  local plan_json username
  local active_id default_output package
  local -a packages units excluded

  [[ -r "$plan_path" ]] || return 65
  plan_json="$(<"$plan_path")"
  username="$(jq -r '.system.username' <<<"$plan_json")" || return $?
  if fstab_assert_contract "$target_root/etc/fstab" "$target_root"; then ok=true; else ok=false; fi
  _verification_add checks fstab "$ok" 'dynamic-default Btrfs fstab and no disk swap'

  mapfile -t packages < <(packages_json "${REPO_ROOT:-$_spawn_finalize_dir/../..}/config/packages.txt" | jq -r '.[]')
  if arch-chroot "$target_root" pacman -Q "${packages[@]}" >/dev/null 2>&1; then ok=true; else ok=false; fi
  _verification_add checks packages "$ok" 'approved package set is installed'

  if pacman_storage_assert_contract "$target_root" "$username"; then ok=true; else ok=false; fi
  _verification_add checks pacman_storage "$ok" 'package database and download cache are readable by their unprivileged consumers'

  units=(NetworkManager bluetooth firewalld plasmalogin switcheroo-control power-profiles-daemon docker.service arch-audit.timer fstrim.timer spawn-arch-btrfs-scrub.timer snapper-cleanup.timer)
  if arch-chroot "$target_root" systemctl is-enabled "${units[@]}" >/dev/null 2>&1; then ok=true; else ok=false; fi
  _verification_add checks services "$ok" 'approved units are enabled'

  if workstation_policy_assert_contract "$target_root" "$username"; then ok=true; else ok=false; fi
  _verification_add checks workstation_policy "$ok" 'closed firewall, bounded logs, local Docker, and sysctl policy are installed'

  if boot_ui_assert_contract "$target_root"; then ok=true; else ok=false; fi
  _verification_add checks boot_ui "$ok" 'Breeze Plymouth is ordered before encrypted-root unlock'

  if user_services_assert_contract "$target_root"; then ok=true; else ok=false; fi
  _verification_add checks user_services "$ok" 'SSH agent is globally enabled while sshd remains disabled'

  if ssh_wallet_assert_contract "$target_root"; then ok=true; else ok=false; fi
  _verification_add checks ssh_wallet "$ok" 'OpenSSH askpass, agent policy, and effective Plasma KWallet PAM integration validate'

  if shell_assert_contract "$target_root" "$username"; then ok=true; else ok=false; fi
  _verification_add checks shell "$ok" 'login Zsh, managed Starship configuration, and FiraCode Nerd Font validate'

  root_status="$(arch-chroot "$target_root" passwd -S root 2>/dev/null || true)"
  if [[ "$root_status" =~ ^root[[:space:]]+L([[:space:]]|$) ]]; then ok=true; else ok=false; fi
  _verification_add checks root_lock "$ok" 'root password is locked'

  if arch-chroot "$target_root" visudo -cf /etc/sudoers.d/10-wheel >/dev/null 2>&1; then ok=true; else ok=false; fi
  _verification_add checks sudo "$ok" 'wheel sudo policy validates'

  if [[ -r "$target_root/boot/loader/spawn-arch-state.json" ]]; then
    state="$(<"$target_root/boot/loader/spawn-arch-state.json")"
  else
    state=""
  fi
  current_hash="$(sha256_file "$target_root/boot/EFI/Linux/spawn-arch-current.efi" 2>/dev/null || true)"
  last_good_hash="$(sha256_file "$target_root/boot/EFI/Linux/spawn-arch-last-good.efi" 2>/dev/null || true)"
  if jq -e --arg current "$current_hash" --arg last_good "$last_good_hash" '
    .schema_version == 1 and .current.blessed == true and
    .current.sha256 == $current and .last_good.sha256 == $last_good
  ' >/dev/null 2>&1 <<<"$state"; then ok=true; else ok=false; fi
  _verification_add checks boot_artifacts "$ok" 'both UKIs match durable boot state'

  boot_list="$(arch-chroot "$target_root" bootctl --esp-path=/boot --json=short list 2>/dev/null || true)"
  if jq -e '
    any(.[]; .id == "spawn-arch-current.efi") and
    any(.[]; .id == "spawn-arch-last-good.efi")
  ' >/dev/null 2>&1 <<<"$boot_list"; then ok=true; else ok=false; fi
  _verification_add checks bootloader "$ok" 'systemd-boot sees both Type #2 entries'

  if arch-chroot "$target_root" snapper --no-dbus -c root list >/dev/null 2>&1; then ok=true; else ok=false; fi
  _verification_add checks snapper "$ok" 'root Snapper configuration is registered'

  if arch-chroot "$target_root" btrfs qgroup show / >/dev/null 2>&1; then ok=false; else ok=true; fi
  _verification_add checks qgroups "$ok" 'Btrfs qgroups remain disabled'

  luks="$(target_storage_json "$target_root" 2>/dev/null || true)"
  if [[ -n "$luks" ]] && cryptsetup isLuks --type luks2 "$(jq -r '.luks_device' <<<"$luks")" 2>/dev/null; then ok=true; else ok=false; fi
  _verification_add checks luks2 "$ok" 'root backing partition is LUKS2'

  active_id="$(btrfs_subvolume_id_from_show "$(LC_ALL=C btrfs subvolume show "$target_root" 2>/dev/null || true)" 2>/dev/null || true)"
  default_output="$(btrfs subvolume get-default "$target_root" 2>/dev/null || true)"
  if [[ "$active_id" =~ ^[1-9][0-9]*$ && "$default_output" =~ ^ID[[:space:]]+$active_id([[:space:]]|$) ]]; then ok=true; else ok=false; fi
  _verification_add checks default_subvolume "$ok" 'active root is the Btrfs default subvolume'

  if grep -Fxq 'zram-size = ram / 2' "$target_root/etc/systemd/zram-generator.conf" &&
    grep -Fxq 'compression-algorithm = zstd' "$target_root/etc/systemd/zram-generator.conf" &&
    grep -Fxq 'swap-priority = 100' "$target_root/etc/systemd/zram-generator.conf"; then ok=true; else ok=false; fi
  _verification_add checks zram "$ok" 'half-RAM zstd zram policy is installed'

  excluded=(steam wine podman cuda tlp auto-cpufreq asusctl)
  ok=true
  for package in "${excluded[@]}"; do
    if arch-chroot "$target_root" pacman -Q "$package" >/dev/null 2>&1; then
      ok=false
      break
    fi
  done
  _verification_add checks excluded_scope "$ok" 'scope-expanding packages are absent'

  output="$(jq -n --argjson checks "$checks" '{checks: $checks} | .ok = ([.checks[].ok] | all)')"
  printf '%s\n' "$output"
  jq -e '.ok' >/dev/null <<<"$output"
}

cmd_verify() {
  local target_root="${1:-/mnt}"

  if (($# > 1)); then
    die_usage "verify accepts at most one target root"
    return $?
  fi
  verify_target_offline "$target_root" "${SPAWN_PLAN_PATH:-$SPAWN_RUNTIME_DIR/plan.json}"
}
