REPO_ROOT="$(cd -- "$BATS_TEST_DIRNAME/../.." && pwd -P)"
readonly REPO_ROOT
QEMU_HARNESS="$REPO_ROOT/tests/integration/run-qemu.sh"
readonly QEMU_HARNESS

integration_runtime() {
  : "${SPAWN_QEMU_RUNTIME:?scripts/integration.sh must provide SPAWN_QEMU_RUNTIME}"
  printf '%s\n' "$SPAWN_QEMU_RUNTIME"
}

scenario_result() {
  local scenario="$1"

  printf '%s/results/%s.json\n' "$(integration_runtime)" "$scenario"
}

assert_scenario_result() {
  local scenario="$1"
  local expression="$2"
  local result

  result="$(scenario_result "$scenario")"
  [ -s "$result" ]
  jq -e --arg scenario "$scenario" \
    '.schema_version == 1 and .scenario == $scenario' "$result"
  jq -e "$expression" "$result"
}
