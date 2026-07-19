#!/usr/bin/env bats

load ../helpers/load
bats_require_minimum_version 1.5.0

setup() {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/payload/usr/local/lib/spawn-arch/windows-boot.sh"
  SPAWN_WINDOWS_BOOT_ESP="$BATS_TEST_TMPDIR/boot"
  SPAWN_WINDOWS_BOOT_RUNTIME="$BATS_TEST_TMPDIR/run"
  mkdir -p "$SPAWN_WINDOWS_BOOT_ESP/EFI" "$SPAWN_WINDOWS_BOOT_RUNTIME"
  windows_boot_validate_destination() { :; }
}

make_windows_tree() {
  local root="$1"
  mkdir -p "$root/EFI/Microsoft/Boot/en-US"
  printf 'MZ microsoft boot manager\n' >"$root/EFI/Microsoft/Boot/bootmgfw.efi"
  printf 'BCD database\n' >"$root/EFI/Microsoft/Boot/BCD"
  printf 'locale\n' >"$root/EFI/Microsoft/Boot/en-US/bootmgfw.efi.mui"
}

lsblk_fixture() {
  cat <<'JSON'
{
  "blockdevices": [
    {"path":"/dev/nvme0n1","type":"disk","fstype":null,"parttype":null,"children":[
      {"path":"/dev/nvme0n1p1","type":"part","fstype":"vfat","parttype":"c12a7328-f81f-11d2-ba4b-00a0c93ec93b"}
    ]},
    {"path":"/dev/nvme1n1","type":"disk","fstype":null,"parttype":null,"children":[
      {"path":"/dev/nvme1n1p1","type":"part","fstype":"vfat","parttype":"C12A7328-F81F-11D2-BA4B-00A0C93EC93B"},
      {"path":"/dev/nvme1n1p2","type":"part","fstype":"ntfs","parttype":"ebd0a0a2-b9e5-4433-87c0-68b6b72699c7"}
    ]},
    {"path":"/dev/sda","type":"disk","fstype":null,"parttype":null,"children":[
      {"path":"/dev/sda1","type":"part","fstype":"vfat","parttype":"0x0c"}
    ]}
  ]
}
JSON
}

@test "candidate parser returns only GPT vfat ESP partitions except the active ESP" {
  run windows_boot_candidates_from_json "$(lsblk_fixture)" /dev/nvme0n1p1

  [ "$status" -eq 0 ]
  [ "$output" = /dev/nvme1n1p1 ]
}

@test "source tree requires both Windows boot manager and BCD" {
  local source="$BATS_TEST_TMPDIR/source"
  mkdir -p "$source/EFI/Microsoft/Boot"

  run windows_boot_validate_tree "$source"
  [ "$status" -eq 65 ]

  printf 'MZ executable\n' >"$source/EFI/Microsoft/Boot/bootmgfw.efi"
  run windows_boot_validate_tree "$source"
  [ "$status" -eq 65 ]

  printf 'BCD\n' >"$source/EFI/Microsoft/Boot/BCD"
  run windows_boot_validate_tree "$source"
  [ "$status" -eq 0 ]

  ln -s Boot/BCD "$source/EFI/Microsoft/linked-bcd"
  run windows_boot_validate_tree "$source"
  [ "$status" -eq 65 ]
}

@test "source mount is vfat read-only nosuid nodev and noexec" {
  local fake_bin="$BATS_TEST_TMPDIR/bin"
  local command_log="$BATS_TEST_TMPDIR/mount.log"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/mount" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$SPAWN_COMMAND_LOG"
FAKE
  chmod +x "$fake_bin/mount"
  export PATH="$fake_bin:$PATH" SPAWN_COMMAND_LOG="$command_log"

  windows_boot_mount_source /dev/nvme0n1p1 "$BATS_TEST_TMPDIR/mount"

  grep -Fx -- '--types vfat --options ro,nosuid,nodev,noexec -- /dev/nvme0n1p1 '"$BATS_TEST_TMPDIR/mount" "$command_log"
}

@test "explicit source must still be a GPT vfat ESP containing Windows artifacts" {
  windows_boot_lsblk_json() { lsblk_fixture; }
  windows_boot_active_esp_source() { printf '%s\n' /dev/nvme0n1p1; }
  windows_boot_probe_source() { [ "$1" = /dev/nvme1n1p1 ]; }

  run windows_boot_validate_explicit_source /dev/nvme1n1p1
  [ "$status" -eq 0 ]

  run windows_boot_validate_explicit_source /dev/nvme1n1p2
  [ "$status" -eq 65 ]

  run windows_boot_validate_explicit_source /dev/nvme0n1p1
  [ "$status" -eq 65 ]
}

@test "tree manifest is deterministic and covers relative paths and content" {
  local source="$BATS_TEST_TMPDIR/source"
  make_windows_tree "$source"

  run windows_boot_tree_manifest "$source/EFI/Microsoft"

  [ "$status" -eq 0 ]
  [[ "$output" == *'  Boot/BCD'* ]]
  [[ "$output" == *'  Boot/bootmgfw.efi'* ]]
  [[ "$output" == *'  Boot/en-US/bootmgfw.efi.mui'* ]]
  [ "$(printf '%s\n' "$output" | sed 's/^[^ ]*  //')" = $'Boot/BCD\nBoot/bootmgfw.efi\nBoot/en-US/bootmgfw.efi.mui' ]
}

@test "sync refuses zero or ambiguous discovered Windows ESPs without touching destination" {
  windows_boot_discover_sources() { return 74; }
  run windows_boot_sync
  [ "$status" -eq 74 ]
  [ ! -e "$SPAWN_WINDOWS_BOOT_ESP/EFI/Microsoft" ]

  windows_boot_discover_sources() { return 0; }
  run windows_boot_sync
  [ "$status" -eq 66 ]
  [ ! -e "$SPAWN_WINDOWS_BOOT_ESP/EFI/Microsoft" ]

  windows_boot_discover_sources() { printf '%s\n' /dev/a /dev/b; }
  run windows_boot_sync
  [ "$status" -eq 65 ]
  [ ! -e "$SPAWN_WINDOWS_BOOT_ESP/EFI/Microsoft" ]
}

@test "sync copies the complete tree through staging and creates an explicit loader entry" {
  local source="$BATS_TEST_TMPDIR/source"
  local command_log="$BATS_TEST_TMPDIR/commands"
  make_windows_tree "$source"

  windows_boot_discover_sources() { printf '%s\n' /dev/windows-esp; }
  windows_boot_mount_source() {
    printf 'mount:%s:%s\n' "$1" "$2" >>"$command_log"
    mkdir -p "$2"
    cp -a "$source/." "$2/"
  }
  windows_boot_unmount_source() {
    printf 'umount:%s\n' "$1" >>"$command_log"
    find "$1" -mindepth 1 -delete
  }
  windows_boot_bootctl_has_windows() { return 0; }

  run windows_boot_sync

  [ "$status" -eq 0 ]
  cmp "$source/EFI/Microsoft/Boot/bootmgfw.efi" \
    "$SPAWN_WINDOWS_BOOT_ESP/EFI/Microsoft/Boot/bootmgfw.efi"
  cmp "$source/EFI/Microsoft/Boot/BCD" \
    "$SPAWN_WINDOWS_BOOT_ESP/EFI/Microsoft/Boot/BCD"
  grep -Fx 'title Windows Boot Manager' "$SPAWN_WINDOWS_BOOT_ESP/loader/entries/windows.conf"
  grep -Fx 'efi /EFI/Microsoft/Boot/bootmgfw.efi' "$SPAWN_WINDOWS_BOOT_ESP/loader/entries/windows.conf"
  grep -Fx "mount:/dev/windows-esp:$SPAWN_WINDOWS_BOOT_RUNTIME/source" "$command_log"
  grep -Fx "umount:$SPAWN_WINDOWS_BOOT_RUNTIME/source" "$command_log"
  [ -z "$(find "$SPAWN_WINDOWS_BOOT_ESP/EFI" -maxdepth 1 -name '.spawn-arch-windows-*' -print)" ]
}

@test "sync is idempotent when source and managed copy match" {
  local source="$BATS_TEST_TMPDIR/source"
  local command_log="$BATS_TEST_TMPDIR/commands"
  make_windows_tree "$source"
  mkdir -p "$SPAWN_WINDOWS_BOOT_ESP/EFI/Microsoft"
  cp -a "$source/EFI/Microsoft/." "$SPAWN_WINDOWS_BOOT_ESP/EFI/Microsoft/"

  windows_boot_discover_sources() { printf '%s\n' /dev/windows-esp; }
  windows_boot_mount_source() {
    mkdir -p "$2"
    cp -a "$source/." "$2/"
  }
  windows_boot_unmount_source() { find "$1" -mindepth 1 -delete; }
  windows_boot_bootctl_has_windows() { return 0; }
  mv() {
    printf 'mv:%s\n' "$*" >>"$command_log"
    command mv "$@"
  }

  run windows_boot_sync

  [ "$status" -eq 0 ]
  [[ "$output" == *'already up to date'* ]]
  run grep -F 'EFI/Microsoft' "$command_log"
  [ "$status" -eq 1 ]
  [ -r "$SPAWN_WINDOWS_BOOT_ESP/loader/entries/windows.conf" ]
}

@test "failed bootctl validation restores the previous complete tree" {
  local source="$BATS_TEST_TMPDIR/source"
  make_windows_tree "$source"
  mkdir -p "$SPAWN_WINDOWS_BOOT_ESP/EFI/Microsoft/Boot"
  printf 'old manager\n' >"$SPAWN_WINDOWS_BOOT_ESP/EFI/Microsoft/Boot/bootmgfw.efi"
  printf 'old BCD\n' >"$SPAWN_WINDOWS_BOOT_ESP/EFI/Microsoft/Boot/BCD"

  windows_boot_discover_sources() { printf '%s\n' /dev/windows-esp; }
  windows_boot_mount_source() {
    mkdir -p "$2"
    cp -a "$source/." "$2/"
  }
  windows_boot_unmount_source() { find "$1" -mindepth 1 -delete; }
  windows_boot_bootctl_has_windows() { return 1; }

  run windows_boot_sync

  [ "$status" -ne 0 ]
  [ "$(cat "$SPAWN_WINDOWS_BOOT_ESP/EFI/Microsoft/Boot/bootmgfw.efi")" = 'old manager' ]
  [ "$(cat "$SPAWN_WINDOWS_BOOT_ESP/EFI/Microsoft/Boot/BCD")" = 'old BCD' ]
  [ -z "$(find "$SPAWN_WINDOWS_BOOT_ESP/EFI" -maxdepth 1 -name '.spawn-arch-windows-*' -print)" ]
}

@test "entry backup failure restores the previous complete tree" {
  local source="$BATS_TEST_TMPDIR/source"
  local entry="$SPAWN_WINDOWS_BOOT_ESP/loader/entries/windows.conf"
  make_windows_tree "$source"
  mkdir -p "$SPAWN_WINDOWS_BOOT_ESP/EFI/Microsoft/Boot" "$(dirname -- "$entry")"
  printf 'old manager\n' >"$SPAWN_WINDOWS_BOOT_ESP/EFI/Microsoft/Boot/bootmgfw.efi"
  printf 'old BCD\n' >"$SPAWN_WINDOWS_BOOT_ESP/EFI/Microsoft/Boot/BCD"
  printf 'old entry\n' >"$entry"

  cp() {
    if [[ " $* " == *" $entry "* ]]; then return 1; fi
    command cp "$@"
  }

  run windows_boot_publish "$source"

  [ "$status" -ne 0 ]
  [ "$(cat "$SPAWN_WINDOWS_BOOT_ESP/EFI/Microsoft/Boot/bootmgfw.efi")" = 'old manager' ]
  [ "$(cat "$entry")" = 'old entry' ]
  [ -z "$(find "$SPAWN_WINDOWS_BOOT_ESP/EFI" -maxdepth 1 -name '.spawn-arch-windows-*' -print)" ]
}

@test "unchanged tree restores the previous entry when bootctl validation fails" {
  local source="$BATS_TEST_TMPDIR/source"
  local entry="$SPAWN_WINDOWS_BOOT_ESP/loader/entries/windows.conf"
  make_windows_tree "$source"
  mkdir -p "$SPAWN_WINDOWS_BOOT_ESP/EFI/Microsoft" "$(dirname -- "$entry")"
  cp -a "$source/EFI/Microsoft/." "$SPAWN_WINDOWS_BOOT_ESP/EFI/Microsoft/"
  printf 'old entry\n' >"$entry"
  windows_boot_bootctl_has_windows() { return 1; }

  run windows_boot_publish "$source"

  [ "$status" -ne 0 ]
  [ "$(cat "$entry")" = 'old entry' ]
  [ -z "$(find "$SPAWN_WINDOWS_BOOT_ESP/EFI" -maxdepth 1 -name '.spawn-arch-windows-*' -print)" ]
}

@test "argument parser accepts only sync with an optional absolute source device" {
  windows_boot_discover_sources() { printf '%s\n' /dev/discovered; }
  windows_boot_sync() { printf 'source=%s\n' "${1:-}"; }

  run cmd_windows_boot sync
  [ "$status" -eq 0 ]
  [ "$output" = source= ]

  run cmd_windows_boot sync --source /dev/nvme0n1p1
  [ "$status" -eq 0 ]
  [ "$output" = source=/dev/nvme0n1p1 ]

  run cmd_windows_boot sync --source relative
  [ "$status" -eq 64 ]
  run cmd_windows_boot sync --unknown
  [ "$status" -eq 64 ]
  run cmd_windows_boot nope
  [ "$status" -eq 64 ]
}
