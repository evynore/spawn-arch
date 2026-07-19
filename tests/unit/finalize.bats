#!/usr/bin/env bats

load ../helpers/load

setup() {
  export SPAWN_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
  export SPAWN_RUNTIME_DISABLE_TRAPS=true
  export SPAWN_COMMAND_LOG="$BATS_TEST_TMPDIR/commands"
  export TARGET_ROOT="$BATS_TEST_TMPDIR/target"
  export PLAN_PATH="$BATS_TEST_TMPDIR/plan.json"
  mkdir -p \
    "$SPAWN_RUNTIME_DIR" \
    "$TARGET_ROOT/etc/pam.d" \
    "$TARGET_ROOT/etc/xdg/autostart" \
    "$TARGET_ROOT/var/lib/pacman/local" \
    "$TARGET_ROOT/var/lib/pacman/sync" \
    "$TARGET_ROOT/var/cache/pacman/pkg" \
    "$TARGET_ROOT/usr/bin" \
    "$TARGET_ROOT/usr/lib/pam.d" \
    "$TARGET_ROOT/usr/share/fonts/TTF"
  cp "$REPO_ROOT/tests/fixtures/archinstall/plan.json" "$PLAN_PATH"
  cp "$REPO_ROOT/tests/fixtures/fstab/archinstall.txt" "$TARGET_ROOT/etc/fstab"
  printf '#en_US.UTF-8 UTF-8\n#ru_RU.UTF-8 UTF-8\n' >"$TARGET_ROOT/etc/locale.gen"
  printf '%s\n' \
    '-auth optional pam_kwallet5.so' \
    '-session optional pam_kwallet5.so auto_start' \
    >"$TARGET_ROOT/etc/pam.d/plasmalogin"
  cp "$TARGET_ROOT/etc/pam.d/plasmalogin" "$TARGET_ROOT/usr/lib/pam.d/plasmalogin"
  printf 'evynore:x:1000:1000::/home/evynore:/bin/bash\n' >"$TARGET_ROOT/etc/passwd"
  printf 'docker:x:971:\n' >"$TARGET_ROOT/etc/group"
  printf '%s\n' \
    '[Desktop Entry]' \
    'Type=Application' \
    'Exec=firewall-applet' \
    >"$TARGET_ROOT/etc/xdg/autostart/firewall-applet.desktop"
  install -m 0755 /dev/null "$TARGET_ROOT/usr/bin/ksshaskpass"
  install -m 0755 /dev/null "$TARGET_ROOT/usr/bin/nvidia-container-runtime"
  install -m 0755 /dev/null "$TARGET_ROOT/usr/bin/zsh"
  install -m 0644 /dev/null \
    "$TARGET_ROOT/usr/share/fonts/TTF/FiraCodeNerdFontMono-Regular.ttf"
  target_storage_json() {
    printf 'target-storage:%s\n' "$1" >>"$SPAWN_COMMAND_LOG"
    jq -n '{
      mount_source: "/dev/mapper/root",
      canonical_mount_source: "/dev/dm-0",
      mapper_name: "root",
      luks_device: "/dev/nvme0n1p2",
      luks_uuid: "11111111-2222-3333-4444-555555555555"
    }'
  }
  load_lib finalize
  make_command_fakes
}

make_command_fakes() {
  local fake_bin="$BATS_TEST_TMPDIR/bin"
  local command_name
  mkdir -p "$fake_bin"
  cat >"$fake_bin/fake-command" <<'FAKE'
#!/usr/bin/env bash
set -u
name="$(basename "$0")"
printf '%s:%s\n' "$name" "$*" >>"$SPAWN_COMMAND_LOG"
case "$name:$*" in
  "findmnt:"*"--verify"*)
    [[ "${SPAWN_REJECT_HOST_FSTAB_VERIFY:-false}" != true ]] || exit 1
    ;;
  "findmnt:"*) printf '/dev/mapper/root\n' ;;
  "cryptsetup:status root") printf '%s\n' '/dev/mapper/root is active' '  device:  /dev/nvme0n1p2' ;;
  "cryptsetup:isLuks --type luks2 /dev/nvme0n1p2") exit 0 ;;
  "cryptsetup:luksDump"*) printf 'Version:       2\n' ;;
  "blkid:"*"-s TYPE"*"/dev/nvme0n1p2") printf 'crypto_LUKS\n' ;;
  "blkid:"*"-s UUID"*"/dev/nvme0n1p2") printf '11111111-2222-3333-4444-555555555555\n' ;;
  "mountpoint:"*) exit 0 ;;
  "btrfs:subvolume show"*) printf 'Subvolume ID:\t\t256\n' ;;
  "btrfs:subvolume get-default"*) printf 'ID 256 gen 1 top level 5 path @\n' ;;
  "arch-chroot:"*"passwd -S root"*) printf 'root L 2026-07-16 0 99999 7 -1\n' ;;
  "arch-chroot:"*"locale-gen"*)
    if [[ "${SPAWN_FAIL_LOCALE_GEN:-false}" == true ]]; then
      printf >&2 'locale archive write failed\n'
      exit 42
    fi
    ;;
  "arch-chroot:"*"btrfs qgroup show"*) exit 1 ;;
  "arch-chroot:"*"bootctl --esp-path=/boot --json=short list"*)
    printf '%s\n' '[{"type":"type2","source":"uki","id":"spawn-arch-current.efi","path":"/boot/EFI/Linux/spawn-arch-current.efi"},{"type":"type2","source":"uki","id":"spawn-arch-last-good.efi","path":"/boot/EFI/Linux/spawn-arch-last-good.efi"}]'
    ;;
  "arch-chroot:"*"bootctl --esp-path=/boot list"*)
    printf '%s\n' 'Boot Loader Entries:' '  type: Boot Loader Specification Type #2 (.efi)' '    id: spawn-arch-current.efi' 'source: /boot/EFI/Linux/spawn-arch-current.efi' '  type: Boot Loader Specification Type #2 (.efi)' '    id: spawn-arch-last-good.efi' 'source: /boot/EFI/Linux/spawn-arch-last-good.efi'
    ;;
  "arch-chroot:"*"pacman -Q steam"* | \
  "arch-chroot:"*"pacman -Q wine"* | \
  "arch-chroot:"*"pacman -Q docker"* | \
  "arch-chroot:"*"pacman -Q podman"* | \
  "arch-chroot:"*"pacman -Q cuda"* | \
  "arch-chroot:"*"pacman -Q tlp"* | \
  "arch-chroot:"*"pacman -Q auto-cpufreq"* | \
  "arch-chroot:"*"pacman -Q asusctl"*) exit 1 ;;
  "arch-chroot:"*"snapper --no-dbus -c root list"*) exit 0 ;;
  "arch-chroot:"*"firewall-offline-cmd --get-default-zone"*) printf 'spawn-workstation\n' ;;
  "arch-chroot:"*"firewall-offline-cmd --get-log-denied"*) printf 'unicast\n' ;;
  "arch-chroot:"*"systemctl is-enabled sshd.service"*) exit 1 ;;
  "arch-chroot:"*"ssh -G example.invalid"*) printf 'addkeystoagent true\n' ;;
  "arch-chroot:"*"snapper -c root list"*)
    printf >&2 '%s\n' 'Failure (org.freedesktop.DBus.Error.ServiceUnknown).'
    exit 1
    ;;
  "arch-chroot:"*"mkinitcpio -p linux"*)
    mkdir -p -- "$1/boot/EFI/Linux"
    printf 'fixture-current-uki\n' >"$1/boot/EFI/Linux/spawn-arch-current.efi"
    ;;
  "arch-chroot:"*"usermod --shell /usr/bin/zsh evynore"*)
    awk -F: -v user="$5" -v shell="$4" '
      BEGIN { OFS=FS }
      $1 == user { $7=shell }
      { print }
    ' "$1/etc/passwd" >"$1/etc/passwd.spawn-arch"
    mv -- "$1/etc/passwd.spawn-arch" "$1/etc/passwd"
    ;;
esac
exit 0
FAKE
  cat >"$fake_bin/objcopy" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
if [[ " ${args[*]} " == *" --update-section "* ]]; then
  input="${args[${#args[@]} - 2]}"
  output="${args[${#args[@]} - 1]}"
  cp -- "$input" "$output"
  exit 0
fi
input="${args[${#args[@]} - 1]}"
target_root="$TARGET_ROOT"
slot=current
[[ "$input" == *last-good* ]] && slot=last-good
for argument in "${args[@]}"; do
  case "$argument" in
    .linux=*) printf 'fixture-linux\n' >"${argument#*=}" ;;
    .initrd=*) printf 'fixture-initrd\n' >"${argument#*=}" ;;
    .uname=*) printf '6.15.7-arch1-1\n' >"${argument#*=}" ;;
    .cmdline=*) printf '%s \n\0' "$(<"$target_root/etc/kernel/cmdline")" >"${argument#*=}" ;;
    .osrel=*)
      version_slot="$slot"
      [[ "$version_slot" != last-good ]] || version_slot=lg
      sed "s/^VERSION_ID=.*/VERSION_ID=6.15.7-arch1-1~$version_slot/" \
        "$target_root/etc/spawn-arch/uki-$slot.os-release" >"${argument#*=}"
      ;;
  esac
done
FAKE
  cat >"$fake_bin/bootctl" <<'FAKE'
#!/usr/bin/env bash
printf >&2 '%s\n' 'Failure (org.freedesktop.DBus.Error.ServiceUnknown)'
exit 1
FAKE
  chmod +x "$fake_bin/fake-command"
  chmod +x "$fake_bin/objcopy" "$fake_bin/bootctl"
  for command_name in arch-chroot blkid btrfs cryptsetup findmnt mount mountpoint umount; do
    ln -s fake-command "$fake_bin/$command_name"
  done
  export PATH="$fake_bin:$PATH"
}

snapshot_tree() {
  local root="$1"
  find "$root" -type f -printf '%P\0' | sort -z | while IFS= read -r -d '' path; do
    printf '%s  %s\n' "$(sha256sum "$root/$path" | awk '{print $1}')" "$path"
  done
}

@test "fstab rewrite follows the dynamic-default Btrfs contract" {
  rewrite_fstab "$TARGET_ROOT/etc/fstab" "$TARGET_ROOT"

  diff -u "$REPO_ROOT/tests/fixtures/fstab/final.txt" "$TARGET_ROOT/etc/fstab"
  fstab_assert_contract "$TARGET_ROOT/etc/fstab" "$TARGET_ROOT"
}

@test "fstab rewrite verifies usability inside the installed target" {
  export SPAWN_REJECT_HOST_FSTAB_VERIFY=true

  run rewrite_fstab "$TARGET_ROOT/etc/fstab" "$TARGET_ROOT"

  [ "$status" -eq 0 ]
  grep -Fx "arch-chroot:$TARGET_ROOT findmnt --verify --tab-file /etc/fstab.spawn-arch.new" \
    "$SPAWN_COMMAND_LOG"
}

@test "fstab contract verifies usability inside the installed target" {
  rewrite_fstab "$TARGET_ROOT/etc/fstab" "$TARGET_ROOT"
  : >"$SPAWN_COMMAND_LOG"
  export SPAWN_REJECT_HOST_FSTAB_VERIFY=true

  run fstab_assert_contract "$TARGET_ROOT/etc/fstab" "$TARGET_ROOT"

  [ "$status" -eq 0 ]
  grep -Fx "arch-chroot:$TARGET_ROOT findmnt --verify --tab-file /etc/fstab" \
    "$SPAWN_COMMAND_LOG"
}

@test "pacman storage normalization repairs restrictive umask artifacts" {
  local path

  for path in \
    var/lib/pacman \
    var/lib/pacman/local \
    var/lib/pacman/sync \
    var/cache/pacman \
    var/cache/pacman/pkg; do
    mkdir -p "$TARGET_ROOT/$path"
    chmod 0700 "$TARGET_ROOT/$path"
  done

  pacman_storage_prepare "$TARGET_ROOT"

  for path in \
    var/lib/pacman \
    var/lib/pacman/local \
    var/lib/pacman/sync \
    var/cache/pacman \
    var/cache/pacman/pkg; do
    [ "$(stat -c '%a' "$TARGET_ROOT/$path")" = '755' ]
  done
  pacman_storage_assert_contract "$TARGET_ROOT" evynore
}

@test "pacman storage contract rejects a cache hidden from the download user" {
  local path

  for path in \
    var/lib/pacman \
    var/lib/pacman/local \
    var/lib/pacman/sync \
    var/cache/pacman \
    var/cache/pacman/pkg; do
    install -d -m 0755 "$TARGET_ROOT/$path"
  done
  chmod 0700 "$TARGET_ROOT/var/cache/pacman/pkg"

  run pacman_storage_assert_contract "$TARGET_ROOT" evynore

  [ "$status" -eq 65 ]
  [[ "$output" == *'pacman storage path has unsafe mode: /var/cache/pacman/pkg'* ]]
}

@test "finalizer is byte-idempotent with identical command ordering" {
  local first_tree="$BATS_TEST_TMPDIR/first-tree"
  local second_tree="$BATS_TEST_TMPDIR/second-tree"
  local first_log="$BATS_TEST_TMPDIR/first-log"
  local second_log="$BATS_TEST_TMPDIR/second-log"

  finalize_target "$TARGET_ROOT" "$PLAN_PATH"
  snapshot_tree "$TARGET_ROOT" >"$first_tree"
  cp "$SPAWN_COMMAND_LOG" "$first_log"

  : >"$SPAWN_COMMAND_LOG"
  finalize_target "$TARGET_ROOT" "$PLAN_PATH"
  snapshot_tree "$TARGET_ROOT" >"$second_tree"
  cp "$SPAWN_COMMAND_LOG" "$second_log"

  diff -u "$first_tree" "$second_tree"
  diff -u "$first_log" "$second_log"
  run grep -Fx 'rd.luks.name=11111111-2222-3333-4444-555555555555=cryptroot rd.luks.options=11111111-2222-3333-4444-555555555555=discard root=/dev/mapper/cryptroot rw' \
    "$TARGET_ROOT/etc/kernel/cmdline"
  [ "$status" -eq 1 ]
  grep -Fx 'rd.luks.name=11111111-2222-3333-4444-555555555555=cryptroot rd.luks.options=11111111-2222-3333-4444-555555555555=discard root=/dev/mapper/cryptroot rw quiet splash' \
    "$TARGET_ROOT/etc/kernel/cmdline"
  grep -Fx 'default spawn-arch-current*' "$TARGET_ROOT/boot/loader/loader.conf"
  grep -Fx 'editor yes' "$TARGET_ROOT/boot/loader/loader.conf"
  run grep -Fx 'editor no' "$TARGET_ROOT/boot/loader/loader.conf"
  [ "$status" -eq 1 ]
  grep -Fx 'KEYMAP=us' "$TARGET_ROOT/etc/vconsole.conf"
  grep -Fx "target-storage:$TARGET_ROOT" "$SPAWN_COMMAND_LOG"
  grep -Fx "arch-chroot:$TARGET_ROOT firewall-offline-cmd --set-default-zone=spawn-workstation" "$SPAWN_COMMAND_LOG"
  grep -Fx "arch-chroot:$TARGET_ROOT firewall-offline-cmd --set-log-denied=unicast" "$SPAWN_COMMAND_LOG"
  grep -Fx "arch-chroot:$TARGET_ROOT firewall-offline-cmd --check-config" "$SPAWN_COMMAND_LOG"
  grep -Fx "arch-chroot:$TARGET_ROOT dockerd --validate --config-file=/etc/docker/daemon.json" "$SPAWN_COMMAND_LOG"
  grep -Fx "arch-chroot:$TARGET_ROOT systemctl enable docker.service" "$SPAWN_COMMAND_LOG"
  run grep -F 'systemctl enable spawn-arch-initial-power-profile.service' "$SPAWN_COMMAND_LOG"
  [ "$status" -eq 1 ]
  grep -Fx "arch-chroot:$TARGET_ROOT systemctl enable arch-audit.timer" "$SPAWN_COMMAND_LOG"
  grep -Fx "arch-chroot:$TARGET_ROOT systemctl --global enable ssh-agent.service" "$SPAWN_COMMAND_LOG"
  grep -Fx "arch-chroot:$TARGET_ROOT systemctl disable sshd.service" "$SPAWN_COMMAND_LOG"
  grep -Fx "arch-chroot:$TARGET_ROOT usermod --shell /usr/bin/zsh evynore" "$SPAWN_COMMAND_LOG"
  grep -Fx "arch-chroot:$TARGET_ROOT ssh -G example.invalid" "$SPAWN_COMMAND_LOG"
  grep -Fx "arch-chroot:$TARGET_ROOT zsh -n /etc/zsh/zshrc" "$SPAWN_COMMAND_LOG"
  grep -Fx 'evynore:x:1000:1000::/home/evynore:/usr/bin/zsh' "$TARGET_ROOT/etc/passwd"
}

@test "workstation policy rejects Docker group access for the installed user" {
  printf 'docker:x:971:evynore\n' >"$TARGET_ROOT/etc/group"
  payload_install "$TARGET_ROOT"

  run workstation_policy_assert_contract "$TARGET_ROOT" evynore

  [ "$status" -ne 0 ]
  [[ "$output" == *"must not belong to the docker group"* ]]
}

@test "workstation policy requires the packaged firewall applet autostart entry" {
  payload_install "$TARGET_ROOT"
  printf 'Hidden=true\n' >>"$TARGET_ROOT/etc/xdg/autostart/firewall-applet.desktop"

  run workstation_policy_assert_contract "$TARGET_ROOT" evynore

  [ "$status" -ne 0 ]
  [[ "$output" == *"firewall-applet XDG autostart entry is disabled"* ]]
}

@test "finalizer removes only the known Archinstall UKI after durable artifacts are initialized" {
  mkdir -p "$TARGET_ROOT/boot/EFI/Linux"
  printf 'archinstall\n' >"$TARGET_ROOT/boot/EFI/Linux/arch-linux.efi"
  printf 'keep me\n' >"$TARGET_ROOT/boot/EFI/Linux/vendor-recovery.efi"

  finalize_target "$TARGET_ROOT" "$PLAN_PATH"

  [ ! -e "$TARGET_ROOT/boot/EFI/Linux/arch-linux.efi" ]
  [ -e "$TARGET_ROOT/boot/EFI/Linux/vendor-recovery.efi" ]
  [ -e "$TARGET_ROOT/boot/EFI/Linux/spawn-arch-current.efi" ]
  [ -e "$TARGET_ROOT/boot/EFI/Linux/spawn-arch-last-good.efi" ]
}

@test "KWallet PAM verification honors effective override and ignores comments" {
  payload_install "$TARGET_ROOT"
  printf '%s\n' \
    'auth optional pam_kwallet5.so' \
    '# session optional pam_kwallet5.so auto_start' \
    >"$TARGET_ROOT/etc/pam.d/plasmalogin"

  run ssh_wallet_assert_contract "$TARGET_ROOT"

  [ "$status" -eq 65 ]
  [[ "$output" == *'effective plasmalogin PAM is missing session pam_kwallet5.so'* ]]
  [[ "$output" == *"$TARGET_ROOT/etc/pam.d/plasmalogin"* ]]

  rm -- "$TARGET_ROOT/etc/pam.d/plasmalogin"
  run ssh_wallet_assert_contract "$TARGET_ROOT"

  [ "$status" -eq 0 ]
}

@test "finalizer reports the failed step system output command and original status" {
  export SPAWN_FAIL_LOCALE_GEN=true

  run finalize_target "$TARGET_ROOT" "$PLAN_PATH"

  [ "$status" -eq 42 ]
  [[ "$output" == *'finalize step: locale generation'* ]]
  [[ "$output" == *'locale archive write failed'* ]]
  [[ "$output" == *'finalize step failed: locale generation (exit 42)'* ]]
  [[ "$output" == *"command: arch-chroot $TARGET_ROOT locale-gen"* ]]
  [[ "$output" != *'passphrase'* ]]
  [[ "$output" != *'password'* ]]
}

@test "offline verifier emits named hard checks and passes the fixture target" {
  finalize_target "$TARGET_ROOT" "$PLAN_PATH"

  run verify_target_offline "$TARGET_ROOT" "$PLAN_PATH"

  [ "$status" -eq 0 ]
  jq -e '
    .ok == true and
    ([.checks[].name] | index("fstab")) and
    ([.checks[].name] | index("packages")) and
    ([.checks[].name] | index("pacman_storage")) and
    ([.checks[].name] | index("boot_artifacts")) and
    ([.checks[].name] | index("workstation_policy")) and
    ([.checks[].name] | index("user_services")) and
    ([.checks[].name] | index("ssh_wallet")) and
    ([.checks[].name] | index("shell")) and
    ([.checks[].name] | index("luks2")) and
    ([.checks[] | select(.ok == false)] | length == 0)
  ' <<<"$output"
}
