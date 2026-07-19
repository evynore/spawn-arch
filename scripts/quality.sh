#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly REPO_ROOT
cd -- "$REPO_ROOT"

shellcheck_paths=(spawn-arch lib/spawn-arch)
[[ ! -d payload/usr/local/bin ]] || shellcheck_paths+=(payload/usr/local/bin)
[[ ! -d payload/usr/local/lib/spawn-arch ]] || shellcheck_paths+=(payload/usr/local/lib/spawn-arch)

mapfile -d '' shellcheck_files < <(
  find "${shellcheck_paths[@]}" -type f \
    \( -name 'spawn-arch' -o -name '*.sh' \) -print0
)
shellcheck "${shellcheck_files[@]}"

format_paths=(spawn-arch lib tests scripts)
[[ ! -d payload ]] || format_paths+=(payload)

mapfile -d '' format_files < <(
  find "${format_paths[@]}" -type f \
    \( -name 'spawn-arch' -o -name '*.sh' -o -name '*.bash' -o -name '*.bats' \) -print0
)
shfmt -d -i 2 -ci "${format_files[@]}"

bats tests/unit
