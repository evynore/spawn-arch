#!/usr/bin/env bats

load ../helpers/load

setup() {
  export SPAWN_TEST_EXCHANGE_ROOT="$BATS_TEST_TMPDIR/exchange"
  mkdir -p "$SPAWN_TEST_EXCHANGE_ROOT"
  # shellcheck source=payload/usr/local/lib/spawn-arch/boot-state.sh
  source "$REPO_ROOT/payload/usr/local/lib/spawn-arch/boot-state.sh"
}

teardown() {
  if [[ -n "${CHECKPOINT_CHILD:-}" ]] && kill -0 "$CHECKPOINT_CHILD" 2>/dev/null; then
    kill -CONT "$CHECKPOINT_CHILD" 2>/dev/null || true
    kill -TERM "$CHECKPOINT_CHILD" 2>/dev/null || true
    wait "$CHECKPOINT_CHILD" 2>/dev/null || true
  fi
}

@test "power checkpoint durably announces its phase and stops the mutating process" {
  local child state="" attempt
  SPAWN_TEST_PAUSE_PHASE=state_temp
  SPAWN_TEST_PAUSE_MARKER="$SPAWN_TEST_EXCHANGE_ROOT/state-temp.ready"

  (
    _boot_test_pause_checkpoint state_temp
    printf 'resumed\n' >"$SPAWN_TEST_EXCHANGE_ROOT/resumed"
  ) &
  child=$!
  CHECKPOINT_CHILD="$child"
  for ((attempt = 0; attempt < 100; attempt++)); do
    [[ -s "$SPAWN_TEST_PAUSE_MARKER" ]] && break
    sleep 0.01
  done

  [ "$(<"$SPAWN_TEST_PAUSE_MARKER")" = state_temp ]
  state="$(ps -o stat= -p "$child")"
  [[ "$state" == T* ]]
  [ ! -e "$SPAWN_TEST_EXCHANGE_ROOT/resumed" ]

  kill -CONT "$child"
  wait "$child"
  CHECKPOINT_CHILD=""
  [ -s "$SPAWN_TEST_EXCHANGE_ROOT/resumed" ]
}

@test "power checkpoint rejects markers outside its dedicated exchange" {
  SPAWN_TEST_PAUSE_PHASE=state_temp
  SPAWN_TEST_PAUSE_MARKER="$BATS_TEST_TMPDIR/outside.ready"

  run _boot_test_pause_checkpoint state_temp

  [ "$status" -ne 0 ]
  [ ! -e "$SPAWN_TEST_PAUSE_MARKER" ]
}
