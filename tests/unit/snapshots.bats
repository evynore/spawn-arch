#!/usr/bin/env bats

load ../helpers/load

setup() {
  export FAKE_SNAPPER_JSON="$REPO_ROOT/tests/fixtures/snapper/list.json"
  export SPAWN_COMMAND_LOG="$BATS_TEST_TMPDIR/commands"
  make_snapper_fake
  # shellcheck source=/dev/null
  source "$REPO_ROOT/payload/usr/local/lib/spawn-arch/snapshots.sh"
  STATE="$(jq -n '{
    schema_version: 1,
    generation: 1,
    current: {entry: "spawn-arch-current", sha256: ("a" * 64), blessed: true},
    last_good: {entry: "spawn-arch-last-good", sha256: ("b" * 64)},
    pending: null,
    seed: {subvolume_id: 256, retired: false, safety_snapshot_id: null}
  }')"
}

make_snapper_fake() {
  local fake_bin="$BATS_TEST_TMPDIR/bin"

  mkdir -p "$fake_bin"
  cat >"$fake_bin/snapper" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'snapper:%s\n' "$*" >>"$SPAWN_COMMAND_LOG"
cat -- "$FAKE_SNAPPER_JSON"
FAKE
  chmod +x "$fake_bin/snapper"
  export PATH="$fake_bin:$PATH"
}

@test "machine-readable list derives relations eligibility and pending marker" {
  local pending

  pending="$(jq '.pending = {
    kind: "pacman", pre_snapshot_id: 7394,
    previous_current_sha256: .current.sha256,
    packages: ["linux"], created_at: "2026-07-16T00:00:00Z"
  }' <<<"$STATE")"
  run snapshots_list "$pending"

  [ "$status" -eq 0 ]
  jq -e '
    any(.snapshots[]; .id == 7394 and .type == "pre" and .eligible == true and .pending == true) and
    any(.snapshots[]; .id == 7395 and .type == "post" and .eligible == false) and
    any(.snapshots[]; .id == 7401 and .type == "single" and .eligible == true) and
    any(.snapshots[]; .id == 0 and .eligible == false)
  ' <<<"$output"
  grep -Fx 'snapper:-c root --jsonout list --columns number,default,active,date,user,cleanup,description,userdata,read-only,pre-number,post-number' \
    "$SPAWN_COMMAND_LOG"
}

@test "latest pins pending pacman pre-snapshot and never falls forward" {
  local pending missing

  pending="$(jq '.pending = {
    kind: "pacman", pre_snapshot_id: 7394,
    previous_current_sha256: .current.sha256,
    packages: ["linux"], created_at: "2026-07-16T00:00:00Z"
  }' <<<"$STATE")"
  run snapshots_resolve latest "$pending"
  [ "$status" -eq 0 ]
  [ "$output" = 7394 ]

  missing="$(jq '.pending.pre_snapshot_id = 9999' <<<"$pending")"
  run snapshots_resolve latest "$missing"
  [ "$status" -ne 0 ]
}

@test "latest without pending chooses greatest eligible pre only" {
  run snapshots_resolve latest "$STATE"

  [ "$status" -eq 0 ]
  [ "$output" = 7394 ]
}

@test "explicit target accepts eligible pre or single and rejects unsafe rows" {
  run snapshots_resolve 7394 "$STATE"
  [ "$status" -eq 0 ]
  [ "$output" = 7394 ]

  run snapshots_resolve 7401 "$STATE"
  [ "$status" -eq 0 ]
  [ "$output" = 7401 ]

  for target in 0 7395 9999 latest-ish; do
    run snapshots_resolve "$target" "$STATE"
    [ "$status" -ne 0 ]
  done
}
