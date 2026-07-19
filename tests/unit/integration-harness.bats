#!/usr/bin/env bats

load ../helpers/load

setup() {
  export SPAWN_QEMU_RUNTIME="$REPO_ROOT/tests/integration/.runtime/unit-$BATS_TEST_NUMBER"
  export SPAWN_QEMU_ISO="$BATS_TEST_TMPDIR/archlinux.iso"
  export SPAWN_QEMU_OVMF_CODE="$BATS_TEST_TMPDIR/OVMF_CODE.fd"
  export SPAWN_QEMU_OVMF_VARS="$BATS_TEST_TMPDIR/OVMF_VARS.fd"
  export SPAWN_QEMU_SKIP_TOOLS=true
  mkdir -p "$SPAWN_QEMU_RUNTIME"
  touch "$SPAWN_QEMU_ISO" "$SPAWN_QEMU_OVMF_CODE" "$SPAWN_QEMU_OVMF_VARS"
  printf 'archisobasedir=arch archisosearchuuid=test-only\n' >"$SPAWN_QEMU_RUNTIME/archiso-cmdline"
}

teardown() {
  rm -rf -- "$SPAWN_QEMU_RUNTIME"
}

@test "first-boot guest contract covers KWallet SSH and shell baseline without secrets" {
  local scenario="$REPO_ROOT/tests/integration/guest-scenarios.sh"
  local assertion="$REPO_ROOT/tests/integration/qemu-install.bats"

  grep -Fq 'pacman -Q ksshaskpass kwallet-pam zsh zsh-completions starship ttf-firacode-nerd' "$scenario"
  grep -Fq "getent passwd evynore | cut -d: -f7" "$scenario"
  grep -Fq "ssh -G example.invalid" "$scenario"
  grep -Fq 'zsh -n /etc/zsh/zshrc' "$scenario"
  grep -Fq 'FiraCodeNerdFontMono-Regular.ttf' "$scenario"
  grep -Fq '/home/evynore/.zshrc' "$scenario"
  grep -Fq '/home/evynore/.config/starship.toml' "$scenario"
  grep -Fq '.first_boot.developer_session_baseline' "$assertion"

  run grep -E 'ssh-keygen|ssh-add .*[^-]$|kwallet.*(dump|list|read)' "$scenario"
  [ "$status" -eq 1 ]
}

@test "QEMU fixture fixes disposable disks memory and every power-loss window" {
  jq -e '
    .schema_version == 1 and
    .machine.firmware == "UEFI/OVMF" and
    .machine.memory_mib == 8192 and
    .machine.target.serial == "SPAWNARCH-TARGET" and
    .machine.target.guest_by_id == "/dev/disk/by-id/virtio-SPAWNARCH-TARGET" and
    .machine.sentinel.read_only == true and
    .machine.host_block_passthrough == false and
    .power_loss_windows == [
      "state_temp", "last_good_temp", "current_candidate",
      "post_snapper_pre_state_commit"
    ]
  ' "$REPO_ROOT/tests/integration/fixtures/qemu-plan.json"
}

@test "QEMU argv exposes only runtime images and a read-only sentinel" {
  run "$REPO_ROOT/tests/integration/run-qemu.sh" inspect-argv live

  [ "$status" -eq 0 ]
  jq -e --arg runtime "$SPAWN_QEMU_RUNTIME" '
    index("-m") and index("8192") and
    any(.[]; contains("serial=SPAWNARCH-TARGET")) and
    any(.[]; contains("serial=WINDOWS-SENTINEL")) and
    any(.[]; contains("node-name=sentinel") and contains("read-only=on")) and
    any(.[]; contains($runtime + "/target.qcow2")) and
    any(.[]; contains($runtime + "/sentinel.raw")) and
    all(.[]; contains("host_device") | not) and
    all(.[]; startswith("/dev/") | not)
  ' <<<"$output"
}

@test "runtime must be the real ignored repository directory or its direct child" {
  SPAWN_QEMU_RUNTIME="$BATS_TEST_TMPDIR/outside" \
    run "$REPO_ROOT/tests/integration/run-qemu.sh" inspect-argv live

  [ "$status" -ne 0 ]
  [[ "$output" == *"runtime must stay under"* ]]
}

@test "QEMU argv never contains credential material" {
  mkdir -p "$SPAWN_QEMU_RUNTIME/secrets"
  printf 'not-a-real-secret\n' >"$SPAWN_QEMU_RUNTIME/secrets/luks-passphrase"

  run "$REPO_ROOT/tests/integration/run-qemu.sh" inspect-argv live

  [ "$status" -eq 0 ]
  [[ "$output" != *"not-a-real-secret"* ]]
  [[ "$output" != *"luks-passphrase"* ]]
}

@test "live guest enters through a read-only UEFI boot image instead of direct kernel boot" {
  run "$REPO_ROOT/tests/integration/run-qemu.sh" inspect-argv live

  [ "$status" -eq 0 ]
  jq -e '
    any(.[]; contains("node-name=integration-boot") and contains("read-only=on")) and
    any(.[]; contains("serial=ARCHISO-BOOT") and contains("bootindex=0")) and
    index("-kernel") == null and index("-append") == null
  ' <<<"$output"
}

@test "installed boot excludes live media and exposes only bounded 9p shares" {
  run "$REPO_ROOT/tests/integration/run-qemu.sh" inspect-argv installed

  [ "$status" -eq 0 ]
  jq -e --arg runtime "$SPAWN_QEMU_RUNTIME" '
    all(.[]; contains("integration-boot") | not) and
    any(.[]; contains("path=" + $runtime + "/source") and contains("readonly=on")) and
    any(.[]; contains("path=" + $runtime + "/exchange")) and
    all(.[]; contains("/secrets") | not)
  ' <<<"$output"
}

@test "current Arch ISO selects the standard non-accessibility boot entry by content" {
  local fake_bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/bsdtar" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "$1:${3:-}" in
  -tf:)
    printf '%s\n' \
      loader/entries/01-archiso-linux.conf \
      loader/entries/02-archiso-speech-linux.conf \
      loader/entries/03-archiso-memtest86+x64.conf
    ;;
  -xOf:loader/entries/01-archiso-linux.conf)
    printf '%s\n' \
      'linux /arch/boot/x86_64/vmlinuz-linux' \
      'initrd /arch/boot/x86_64/initramfs-linux.img' \
      'options archisobasedir=arch archisosearchuuid=2026-test'
    ;;
  -xOf:loader/entries/02-archiso-speech-linux.conf)
    printf '%s\n' \
      'linux /arch/boot/x86_64/vmlinuz-linux' \
      'initrd /arch/boot/x86_64/initramfs-linux.img' \
      'options archisobasedir=arch archisosearchuuid=2026-test accessibility=on'
    ;;
  -xOf:loader/entries/03-archiso-memtest86+x64.conf)
    printf '%s\n' 'efi /EFI/memtest86+/memtest.efi'
    ;;
  *) exit 64 ;;
esac
FAKE
  chmod +x "$fake_bin/bsdtar"

  PATH="$fake_bin:$PATH" run \
    "$REPO_ROOT/tests/integration/run-qemu.sh" inspect-archiso-entry "$SPAWN_QEMU_ISO"

  [ "$status" -eq 0 ]
  [ "$output" = loader/entries/01-archiso-linux.conf ]
}
