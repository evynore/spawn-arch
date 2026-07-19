#!/usr/bin/env bats

load ../helpers/load
bats_require_minimum_version 1.5.0

setup() {
  export SPAWN_LIB_DIR="$REPO_ROOT/payload/usr/local/lib/spawn-arch"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/payload/usr/local/bin/spawn-arch"
  verify_status() { printf 'status\n'; }
  verify_run() { printf 'verify\n'; }
  verify_and_bless() { printf 'bless\n'; }
  boot_state_read() { printf '{}\n'; }
  snapshots_list() { printf 'snapshots\n'; }
  rollback_main() { printf 'rollback:%s\n' "$1"; }
  cmd_windows_boot() { printf 'windows-boot:%s\n' "$*"; }
}

@test "installed dispatcher exposes only status verify and explicit bless" {
  run installed_main status
  [ "$status" -eq 0 ]
  [ "$output" = status ]

  run installed_main verify
  [ "$status" -eq 0 ]
  [ "$output" = verify ]

  run installed_main verify --bless
  [ "$status" -eq 0 ]
  [ "$output" = bless ]

  run installed_main snapshots list
  [ "$status" -eq 0 ]
  [ "$output" = snapshots ]

  run installed_main rollback latest
  [ "$status" -eq 0 ]
  [ "$output" = rollback:latest ]

  run installed_main rollback 7394
  [ "$status" -eq 0 ]
  [ "$output" = rollback:7394 ]

  run installed_main windows-boot sync
  [ "$status" -eq 0 ]
  [ "$output" = windows-boot:sync ]

  for command in doctor plan install; do
    run installed_main "$command"
    [ "$status" -eq 64 ]
  done
  run installed_main snapshots
  [ "$status" -eq 64 ]
  run installed_main rollback
  [ "$status" -eq 64 ]
}

@test "installed entrypoint rejects non-root callers" {
  run --separate-stderr bash "$REPO_ROOT/payload/usr/local/bin/spawn-arch" status

  [ "$status" -eq 77 ]
  [[ "$stderr" == *'require root'* ]]
}
