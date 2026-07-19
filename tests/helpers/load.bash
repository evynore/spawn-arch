REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../.." && pwd -P)"

load_lib() {
  local name="$1"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/spawn-arch/$name.sh"
}
