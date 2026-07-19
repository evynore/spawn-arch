#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly REPO_ROOT
readonly HARNESS="$REPO_ROOT/tests/integration/run-qemu.sh"
export SPAWN_QEMU_RUNTIME="$REPO_ROOT/tests/integration/.runtime"

: "${SPAWN_QEMU_ISO:?set SPAWN_QEMU_ISO to a verified Arch ISO path}"
: "${SPAWN_QEMU_ISO_SHA256:?set SPAWN_QEMU_ISO_SHA256 to its lowercase SHA-256}"
command -v openssl >/dev/null 2>&1 || {
  printf 'spawn-arch integration: openssl is required for ephemeral test credentials\n' >&2
  exit 69
}

cleanup_secrets() {
  local secrets="$SPAWN_QEMU_RUNTIME/secrets"

  if [[ -d "$secrets" ]]; then
    find "$secrets" -mindepth 1 -maxdepth 1 -type f -delete
    rmdir -- "$secrets" 2>/dev/null || true
  fi
}
trap cleanup_secrets EXIT INT TERM

"$HARNESS" reset
install -d -m 0700 -- "$SPAWN_QEMU_RUNTIME/secrets"
umask 077
openssl rand -hex 32 >"$SPAWN_QEMU_RUNTIME/secrets/luks-passphrase"
openssl rand -hex 32 >"$SPAWN_QEMU_RUNTIME/secrets/user-password"
chmod 0600 -- \
  "$SPAWN_QEMU_RUNTIME/secrets/luks-passphrase" \
  "$SPAWN_QEMU_RUNTIME/secrets/user-password"
"$HARNESS" prepare

bats \
  "$REPO_ROOT/tests/integration/qemu-install.bats" \
  "$REPO_ROOT/tests/integration/qemu-update-recovery.bats" \
  "$REPO_ROOT/tests/integration/qemu-rollback.bats"
