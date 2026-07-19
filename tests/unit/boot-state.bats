#!/usr/bin/env bats

load ../helpers/load
bats_require_minimum_version 1.5.0

setup() {
  export SPAWN_BOOT_ROOT="$BATS_TEST_TMPDIR/boot"
  export SPAWN_ETC_ROOT="$BATS_TEST_TMPDIR/etc"
  export SPAWN_INSTALLED_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
  mkdir -p "$SPAWN_BOOT_ROOT/loader" "$SPAWN_BOOT_ROOT/EFI/Linux" "$SPAWN_ETC_ROOT" "$SPAWN_INSTALLED_RUNTIME_DIR"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/payload/usr/local/lib/spawn-arch/boot-state.sh"
}

state_json() {
  local generation="$1"
  local current_hash="${2:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
  local last_good_hash="${3:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
  jq -n --argjson generation "$generation" --arg current "$current_hash" --arg last_good "$last_good_hash" '{
    schema_version: 1,
    generation: $generation,
    current: {entry: "spawn-arch-current", sha256: $current, blessed: true},
    last_good: {entry: "spawn-arch-last-good", sha256: $last_good},
    pending: null,
    seed: {subvolume_id: 256, retired: false, safety_snapshot_id: null}
  }'
}

@test "state replacement exposes only complete monotonic generations" {
  boot_state_write "$(state_json 1)"

  SPAWN_TEST_FAIL_PHASE=before_state_rename run boot_state_write "$(state_json 2)"
  [ "$status" -ne 0 ]
  run boot_state_read
  [ "$status" -eq 0 ]
  jq -e '.generation == 1' <<<"$output"

  boot_state_write "$(state_json 2)"
  jq -e '.generation == 2' "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json"
  jq -e '.generation == 1' "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json.previous"
}

@test "reader loudly recovers a corrupt primary from previous" {
  boot_state_write "$(state_json 1)"
  boot_state_write "$(state_json 2)"
  printf '{broken\n' >"$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json"

  run --separate-stderr boot_state_read

  [ "$status" -eq 0 ]
  [[ "$stderr" == *'recovering invalid boot state from .previous'* ]]
  jq -e '.generation == 1' <<<"$output"
  [[ "$output" == *'"generation": 1'* ]]
  jq -e '.generation == 1' "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json"
}

@test "state schema rejects bad hashes generations entries and pending kinds" {
  run boot_state_validate "$(state_json 0)"
  [ "$status" -ne 0 ]
  run boot_state_validate "$(state_json 1 | jq '.current.sha256 = "BAD"')"
  [ "$status" -ne 0 ]
  run boot_state_validate "$(state_json 1 | jq '.current.entry = "foreign"')"
  [ "$status" -ne 0 ]
  run boot_state_validate "$(state_json 1 | jq '.pending = {kind: "guess"}')"
  [ "$status" -ne 0 ]
}

@test "prepared transaction rolls artifact and state forward by hashes" {
  local final="$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-last-good.efi"
  local staged="$SPAWN_BOOT_ROOT/EFI/Linux/.spawn-arch-last-good.efi.new-test"
  local old_hash new_hash transaction new_state
  printf 'old-artifact\n' >"$final"
  printf 'new-artifact\n' >"$staged"
  old_hash="$(sha256sum "$final" | awk '{print $1}')"
  new_hash="$(sha256sum "$staged" | awk '{print $1}')"
  boot_state_write "$(state_json 1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$old_hash")"
  new_state="$(state_json 2 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$new_hash")"
  transaction="$(jq -n \
    --arg old "$old_hash" --arg new "$new_hash" --argjson state "$new_state" '{
      schema_version: 1,
      operation_id: "00000000-0000-4000-8000-000000000001",
      kind: "initialize",
      base_generation: 1,
      phase: "prepared",
      old_btrfs_default: null,
      artifacts: [{
        temp_basename: ".spawn-arch-last-good.efi.new-test",
        final_basename: "spawn-arch-last-good.efi",
        previous_basename: ".spawn-arch-last-good.efi.previous-test",
        old_sha256: $old,
        new_sha256: $new
      }],
      new_state: $state
    }')"

  boot_transaction_begin "$transaction"
  boot_transaction_recover

  [ "$(sha256sum "$final" | awk '{print $1}')" = "$new_hash" ]
  jq -e '.generation == 2' "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json"
  [ ! -e "$SPAWN_BOOT_ROOT/loader/spawn-arch-transaction.json" ]
}

@test "transaction begin rejects a stale state generation before artifact mutation" {
  local final="$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-last-good.efi"
  local staged="$SPAWN_BOOT_ROOT/EFI/Linux/.spawn-arch-last-good.efi.new-stale"
  local old_hash new_hash transaction new_state

  printf 'old-artifact\n' >"$final"
  printf 'new-artifact\n' >"$staged"
  old_hash="$(sha256sum "$final" | awk '{print $1}')"
  new_hash="$(sha256sum "$staged" | awk '{print $1}')"
  boot_state_write "$(state_json 1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$old_hash")"
  new_state="$(state_json 2 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$new_hash")"
  transaction="$(jq -n --arg old "$old_hash" --arg new "$new_hash" --argjson state "$new_state" '{
    schema_version: 1,
    operation_id: "00000000-0000-4000-8000-000000000002",
    kind: "preserve",
    base_generation: 1,
    phase: "prepared",
    old_btrfs_default: null,
    artifacts: [{
      temp_basename: ".spawn-arch-last-good.efi.new-stale",
      final_basename: "spawn-arch-last-good.efi",
      previous_basename: ".spawn-arch-last-good.efi.previous-stale",
      old_sha256: $old,
      new_sha256: $new
    }],
    new_state: $state
  }')"
  boot_state_write "$(state_json 2 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$old_hash")"

  run boot_transaction_begin "$transaction"

  [ "$status" -ne 0 ]
  [ ! -e "$SPAWN_BOOT_ROOT/loader/spawn-arch-transaction.json" ]
  [ "$(sha256sum "$final" | awk '{print $1}')" = "$old_hash" ]
}
