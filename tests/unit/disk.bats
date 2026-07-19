#!/usr/bin/env bats

load ../helpers/load

setup() {
  load_lib disk
}

fixture_json() {
  cat "$REPO_ROOT/tests/fixtures/lsblk/$1.json"
}

@test "inventory derives EUI from the standard WWN column" {
  lsblk() {
    if [[ "$*" == *",EUI,"* ]]; then
      printf '%s\n' 'lsblk: unknown column: EUI' >&2
      return 64
    fi
    cat <<'JSON'
{"blockdevices":[{"name":"nvme0n1","kname":"nvme0n1","path":"/dev/nvme0n1","type":"disk","size":2000398934016,"log-sec":512,"model":"Samsung SSD","serial":"S7H0NX0W123456A","wwn":"eui.002538b111111111","ro":false,"rm":false,"mountpoints":[]}]}
JSON
  }
  findmnt() {
    return 1
  }
  export -f lsblk findmnt

  SPAWN_BY_ID_DIR="$BATS_TEST_TMPDIR/missing-by-id" \
    SPAWN_SYS_BLOCK_DIR="$BATS_TEST_TMPDIR/missing-sys-block" \
    run disk_inventory_json

  [ "$status" -eq 0 ]
  jq -e '
    .disks | length == 1 and
    .[0].wwn == "eui.002538b111111111" and
    .[0].eui == "002538b111111111"
  ' <<<"$output"
}

@test "resolves the target after nvme enumeration changes" {
  local identity
  identity="$(disk_identity_json /dev/nvme1n1 "$(fixture_json gu606ax)")"

  run resolve_disk_identity "$identity" "$(fixture_json reordered)"

  [ "$status" -eq 0 ]
  [ "$output" = "/dev/nvme0n1" ]
}

@test "identity pins serial size by-id sector size and optional WWN or EUI" {
  run disk_identity_json /dev/nvme1n1 "$(fixture_json gu606ax)"

  [ "$status" -eq 0 ]
  jq -e '
    .serial == "S7H0NX0W123456A" and
    .wwn_or_eui == "002538b111111111" and
    .size_bytes == 2000398934016 and
    .by_id == "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S7H0NX0W123456A" and
    .logical_sector_bytes == 512
  ' <<<"$output"
}

@test "resolution rejects a changed stable identifier" {
  local identity inventory
  identity="$(disk_identity_json /dev/nvme1n1 "$(fixture_json gu606ax)")"
  inventory="$(jq '(.disks[] | select(.serial == "S7H0NX0W123456A") | .size_bytes) = 2000398933504' <<<"$(fixture_json reordered)")"

  run resolve_disk_identity "$identity" "$inventory"

  [ "$status" -ne 0 ]
}

@test "rejects mounted holder-backed removable readonly and live-media disks" {
  local inventory device identity
  inventory="$(fixture_json unsafe)"

  while IFS= read -r device; do
    identity="$(disk_identity_json "$device" "$inventory")"
    run assert_disk_safe "$identity" "$inventory" /dev/sda
    [ "$status" -ne 0 ]
  done <"$REPO_ROOT/tests/fixtures/lsblk/unsafe-devices.txt"
}

@test "erasure confirmation is byte-for-byte exact" {
  local serial="S7H0NX0W123456A"
  local tty_file="$BATS_TEST_TMPDIR/tty"

  printf 'ERASE %s\n' "$serial" >"$tty_file"
  SPAWN_TTY_PATH="$tty_file" run confirm_disk_erase "$serial"
  [ "$status" -eq 0 ]

  for reply in "ERASE S7H0" " ERASE $serial" "ERASE $serial " "$serial"; do
    printf '%s\n' "$reply" >"$tty_file"
    SPAWN_TTY_PATH="$tty_file" run confirm_disk_erase "$serial"
    [ "$status" -ne 0 ]
  done

  : >"$tty_file"
  SPAWN_TTY_PATH="$tty_file" run confirm_disk_erase "$serial"
  [ "$status" -ne 0 ]
}
