#!/usr/bin/env bats

load ../helpers/load

setup() {
  export SPAWN_COMMAND_LOG="$BATS_TEST_TMPDIR/commands"
  export SPAWN_SYS_CLASS_BLOCK_DIR="$BATS_TEST_TMPDIR/sys-class-block"
  export FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  export FAKE_FINDMNT_SOURCE_FILE="$BATS_TEST_TMPDIR/findmnt-source"
  export FAKE_MAPPER_CANONICAL_FILE="$BATS_TEST_TMPDIR/mapper-canonical"
  mkdir -p "$FAKE_BIN" "$SPAWN_SYS_CLASS_BLOCK_DIR"
  printf '/dev/mapper/cryptroot\n' >"$FAKE_FINDMNT_SOURCE_FILE"
  printf '/dev/dm-0\n' >"$FAKE_MAPPER_CANONICAL_FILE"
  make_storage_fakes
  export PATH="$FAKE_BIN:$PATH"
  load_lib target-storage
}

make_storage_fakes() {
  cat >"$FAKE_BIN/findmnt" <<'FAKE'
#!/usr/bin/env bash
cat "$FAKE_FINDMNT_SOURCE_FILE"
FAKE
  cat >"$FAKE_BIN/readlink" <<'FAKE'
#!/usr/bin/env bash
case "${*: -1}" in
  /dev/mapper/cryptroot) cat "$FAKE_MAPPER_CANONICAL_FILE" ;;
  /dev/dm-0 | /dev/dm-1 | /dev/nvme1n1p2) printf '%s\n' "${*: -1}" ;;
  *) exit 1 ;;
esac
FAKE
  cat >"$FAKE_BIN/cryptsetup" <<'FAKE'
#!/usr/bin/env bash
printf 'cryptsetup:%s\n' "$*" >>"$SPAWN_COMMAND_LOG"
[[ "$*" == 'status cryptroot' ]] || exit 1
printf '%s\n' '/dev/mapper/cryptroot is active' '  device:  /dev/nvme1n1p2'
FAKE
  cat >"$FAKE_BIN/blkid" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *'-s TYPE'*'/dev/nvme1n1p2') printf 'crypto_LUKS\n' ;;
  *'-s UUID'*'/dev/nvme1n1p2') printf '11111111-2222-3333-4444-555555555555\n' ;;
  *) exit 1 ;;
esac
FAKE
  chmod +x "$FAKE_BIN"/*
}

@test "preserves mapper name when its alias resolves to a dm kernel node" {
  run target_storage_json /mnt

  [ "$status" -eq 0 ]
  jq -e '
    .mount_source == "/dev/mapper/cryptroot" and
    .canonical_mount_source == "/dev/dm-0" and
    .mapper_name == "cryptroot" and
    .luks_device == "/dev/nvme1n1p2" and
    .luks_uuid == "11111111-2222-3333-4444-555555555555"
  ' <<<"$output"
  [ "$(cat "$SPAWN_COMMAND_LOG")" = 'cryptsetup:status cryptroot' ]
}

@test "recovers mapper name from sysfs when findmnt reports a dm kernel node" {
  printf '/dev/dm-0\n' >"$FAKE_FINDMNT_SOURCE_FILE"
  mkdir -p "$SPAWN_SYS_CLASS_BLOCK_DIR/dm-0/dm"
  printf 'cryptroot\n' >"$SPAWN_SYS_CLASS_BLOCK_DIR/dm-0/dm/name"

  run target_storage_json /mnt

  [ "$status" -eq 0 ]
  jq -e '.mapper_name == "cryptroot" and .canonical_mount_source == "/dev/dm-0"' <<<"$output"
  [ "$(cat "$SPAWN_COMMAND_LOG")" = 'cryptsetup:status cryptroot' ]
}

@test "rejects a mapper alias that resolves away from the mounted dm node" {
  printf '/dev/dm-0\n' >"$FAKE_FINDMNT_SOURCE_FILE"
  printf '/dev/dm-1\n' >"$FAKE_MAPPER_CANONICAL_FILE"
  mkdir -p "$SPAWN_SYS_CLASS_BLOCK_DIR/dm-0/dm"
  printf 'cryptroot\n' >"$SPAWN_SYS_CLASS_BLOCK_DIR/dm-0/dm/name"

  run target_storage_json /mnt

  [ "$status" -ne 0 ]
  [[ "$output" == *'does not resolve to mounted device'* ]]
  [ ! -e "$SPAWN_COMMAND_LOG" ]
}
