#!/usr/bin/env bats

load ../helpers/load

setup() {
  export SPAWN_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
  export SPAWN_RUNTIME_DISABLE_TRAPS=true
  load_lib runtime-state
}

@test "runtime files use strict modes" {
  runtime_init
  [ "$(stat -c %a "$SPAWN_RUNTIME_DIR")" = 700 ]

  state_create abc123

  [ "$(stat -c %a "$SPAWN_RUNTIME_DIR/install-state.json")" = 600 ]
  [ "$(stat -c %a "$SPAWN_RUNTIME_DIR/install.lock")" = 600 ]
  jq -e '.phase == "planned" and .plan_sha256 == "abc123"' \
    "$SPAWN_RUNTIME_DIR/install-state.json"
}

@test "runtime initialization preserves the caller umask" {
  umask 0022

  runtime_init

  [ "$(umask)" = 0022 ]
}

@test "state machine rejects stale and skipped transitions" {
  runtime_init
  state_create abc123

  run state_transition planned confirmed
  [ "$status" -eq 0 ]
  run state_transition planned materialized
  [ "$status" -ne 0 ]
  run state_transition confirmed archinstall_running
  [ "$status" -ne 0 ]
  run state_transition confirmed materialized
  [ "$status" -eq 0 ]
  run state_transition materialized archinstall_running
  [ "$status" -eq 0 ]
  run state_transition archinstall_running failed
  [ "$status" -eq 0 ]

  jq -e '
    .phase == "failed" and
    .failed_from == "archinstall_running" and
    .last_completed_phase == "materialized"
  ' "$SPAWN_RUNTIME_DIR/install-state.json"
}

@test "credential registration rejects paths outside runtime and loose modes" {
  local outside="$BATS_TEST_TMPDIR/outside.json"
  runtime_init
  install -m 0600 /dev/null "$outside"
  run credentials_register "$outside"
  [ "$status" -ne 0 ]

  install -m 0644 /dev/null "$SPAWN_RUNTIME_DIR/loose.json"
  run credentials_register "$SPAWN_RUNTIME_DIR/loose.json"
  [ "$status" -ne 0 ]
}

@test "credential cleanup runs on an injected failure" {
  run env SPAWN_RUNTIME_DIR="$SPAWN_RUNTIME_DIR" SPAWN_RUNTIME_DISABLE_TRAPS=false bash -c '
    set -Eeuo pipefail
    source lib/spawn-arch/runtime-state.sh
    runtime_init
    install -m 0600 /dev/null "$SPAWN_RUNTIME_DIR/user_credentials.json"
    credentials_register "$SPAWN_RUNTIME_DIR/user_credentials.json"
    false
  '

  [ "$status" -ne 0 ]
  [ ! -e "$SPAWN_RUNTIME_DIR/user_credentials.json" ]
}

@test "TERM cleans credentials terminates the child and marks state failed without leaks" {
  local secret='test-passphrase-do-not-log'
  local password_hash='$y$j9T$do-not-log-this-hash'
  local child_marker="$BATS_TEST_TMPDIR/child-terminated"

  run env \
    SPAWN_RUNTIME_DIR="$SPAWN_RUNTIME_DIR" \
    SPAWN_RUNTIME_DISABLE_TRAPS=false \
    TEST_SECRET="$secret" \
    TEST_HASH="$password_hash" \
    CHILD_MARKER="$child_marker" \
    bash -c '
      set -Eeuo pipefail
      source lib/spawn-arch/runtime-state.sh
      runtime_init
      state_create abc123
      state_transition planned confirmed
      install -m 0600 /dev/null "$SPAWN_RUNTIME_DIR/user_credentials.json"
      credentials_register "$SPAWN_RUNTIME_DIR/user_credentials.json"
      bash -c '\''trap "printf terminated >\"$CHILD_MARKER\"; exit 0" TERM; printf ready >"$CHILD_MARKER.ready"; while :; do sleep 1; done'\'' &
      runtime_track_child "$!"
      while [[ ! -e "$CHILD_MARKER.ready" ]]; do :; done
      kill -TERM "$$"
    '

  [ "$status" -eq 143 ]
  [ ! -e "$SPAWN_RUNTIME_DIR/user_credentials.json" ]
  [ "$(cat "$child_marker")" = terminated ]
  jq -e '.phase == "failed" and .failed_from == "confirmed"' \
    "$SPAWN_RUNTIME_DIR/install-state.json"
  [[ "$output" != *"$secret"* ]]
  [[ "$output" != *"$password_hash"* ]]
}
