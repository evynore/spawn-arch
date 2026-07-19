#!/usr/bin/env bats

load ../helpers/load

setup() {
  export SPAWN_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
  export SPAWN_RUNTIME_DISABLE_TRAPS=true
  export SPAWN_PLAN_PATH="$SPAWN_RUNTIME_DIR/plan.json"
  export SPAWN_TARGET_ROOT="$BATS_TEST_TMPDIR/target"
  export SPAWN_CALL_LOG="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$SPAWN_RUNTIME_DIR" "$SPAWN_TARGET_ROOT/etc"
  cp "$REPO_ROOT/tests/fixtures/archinstall/plan.json" "$SPAWN_PLAN_PATH"
  chmod 0600 "$SPAWN_PLAN_PATH"
  load_lib install
}

install_test_ports() {
  doctor_assert_installable() { printf 'doctor\n' >>"$SPAWN_CALL_LOG"; }
  source_commit_resolve() { jq -r '.source.commit' "$SPAWN_PLAN_PATH"; }
  resolve_disk_identity() {
    printf 'resolve\n' >>"$SPAWN_CALL_LOG"
    printf '/dev/nvme0n1\n'
  }
  assert_disk_safe() {
    printf 'safe\n' >>"$SPAWN_CALL_LOG"
    printf '/dev/nvme0n1\n'
  }
  confirm_disk_erase() { printf 'confirm\n' >>"$SPAWN_CALL_LOG"; }
  prompt_password_into() {
    printf 'password:%s\n' "$2" >>"$SPAWN_CALL_LOG"
    printf -v "$1" '%s' 'unit-test-secret'
  }
  archinstall_user_config() {
    printf 'materialize:user\n' >>"$SPAWN_CALL_LOG"
    install -m 0600 /dev/null "$2"
  }
  archinstall_credentials() {
    printf 'materialize:credentials\n' >>"$SPAWN_CALL_LOG"
    install -m 0600 /dev/null "$2"
    credentials_register "$2"
  }
  archinstall_validate_materialized() { printf 'validate\n' >>"$SPAWN_CALL_LOG"; }
  target_fingerprint_record() { :; }
  assert_resume_target() { printf 'resume-target\n' >>"$SPAWN_CALL_LOG"; }
  finalize_target() {
    printf 'finalize-umask:%s\n' "$(umask)" >>"$SPAWN_CALL_LOG"
    printf 'finalize\n' >>"$SPAWN_CALL_LOG"
  }
  verify_target_offline() {
    printf 'verify\n' >>"$SPAWN_CALL_LOG"
    printf '{"ok":true}\n'
  }
}

@test "target fingerprint consumes the shared encrypted storage identity" {
  local plan_json
  plan_json="$(<"$SPAWN_PLAN_PATH")"
  target_storage_json() {
    printf 'target-storage:%s\n' "$1" >>"$SPAWN_CALL_LOG"
    jq -n '{
      mount_source: "/dev/mapper/cryptroot",
      canonical_mount_source: "/dev/dm-0",
      mapper_name: "cryptroot",
      luks_device: "/dev/nvme0n1p2",
      luks_uuid: "11111111-2222-3333-4444-555555555555"
    }'
  }
  blkid() {
    case "$*" in
      *'-s TYPE'*'/dev/dm-0') printf 'btrfs\n' ;;
      *'-s UUID'*'/dev/dm-0') printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n' ;;
      *) return 1 ;;
    esac
  }
  disk_inventory_json() {
    jq '(.disks[] | select(.serial == "S7H0NX0W123456A") | .descendant_paths) += ["/dev/nvme0n1p2"]' \
      "$REPO_ROOT/tests/fixtures/lsblk/reordered.json"
  }

  run _target_fingerprint_json "$plan_json" /mnt

  [ "$status" -eq 0 ]
  jq -e '
    .mount_source == "/dev/dm-0" and
    .luks_device == "/dev/nvme0n1p2" and
    .luks_uuid == "11111111-2222-3333-4444-555555555555"
  ' <<<"$output"
  [ "$(cat "$SPAWN_CALL_LOG")" = 'target-storage:/mnt' ]
}

@test "successful install preserves the exact guarded phase order" {
  local fake_bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$fake_bin"
  install_test_ports
  disk_inventory_json() { cat "$REPO_ROOT/tests/fixtures/lsblk/reordered.json"; }
  cat >"$fake_bin/archinstall" <<'FAKE'
#!/usr/bin/env bash
printf 'archinstall:%s\n' "$*" >>"$SPAWN_CALL_LOG"
printf 'archinstall-umask:%s\n' "$(umask)" >>"$SPAWN_CALL_LOG"
printf 'fixture-stdout\n'
printf 'fixture-stderr\n' >&2
install -d -m 0755 "$SPAWN_TARGET_ROOT/etc"
printf 'fixture\n' >"$SPAWN_TARGET_ROOT/etc/fstab"
FAKE
  chmod +x "$fake_bin/archinstall"

  umask 0077
  PATH="$fake_bin:$PATH" run cmd_install

  [ "$status" -eq 0 ]
  cat >"$BATS_TEST_TMPDIR/expected" <<EOF
doctor
resolve
safe
confirm
password:LUKS passphrase
password:User password
materialize:user
materialize:credentials
validate
resolve
safe
archinstall:--config $SPAWN_RUNTIME_DIR/user_configuration.json --creds $SPAWN_RUNTIME_DIR/user_credentials.json --silent
archinstall-umask:0022
finalize-umask:0022
finalize
verify
EOF
  diff -u "$BATS_TEST_TMPDIR/expected" "$SPAWN_CALL_LOG"
  jq -e '.phase == "complete"' "$SPAWN_RUNTIME_DIR/install-state.json"
  [ ! -e "$SPAWN_RUNTIME_DIR/user_credentials.json" ]
  [[ "$output" != *fixture-stdout* ]]
  [[ "$output" != *fixture-stderr* ]]
  [[ "$output" == *'Archinstall running; detailed output is captured at'* ]]
  [[ "$output" == *'Archinstall completed successfully'* ]]
  grep -Fx fixture-stdout "$SPAWN_RUNTIME_DIR/archinstall-console.log"
  grep -Fx fixture-stderr "$SPAWN_RUNTIME_DIR/archinstall-console.log"
  [ "$(stat -c %a "$SPAWN_RUNTIME_DIR/archinstall-console.log")" = 600 ]
}

@test "failed Archinstall prints a readable sanitized tail without replaying progress output" {
  local fake_bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$fake_bin"
  install_test_ports
  disk_inventory_json() { cat "$REPO_ROOT/tests/fixtures/lsblk/reordered.json"; }
  cat >"$fake_bin/archinstall" <<'FAKE'
#!/usr/bin/env bash
printf '\033[32mTotal (1/157) 10 MiB\rTotal (2/157) 20 MiB\033[0m\n'
printf 'fatal: package transaction failed\n' >&2
exit 42
FAKE
  chmod +x "$fake_bin/archinstall"

  PATH="$fake_bin:$PATH" run cmd_install

  [ "$status" -eq 42 ]
  [[ "$output" == *'Archinstall failed (exit 42); sanitized log tail follows:'* ]]
  [[ "$output" == *'fatal: package transaction failed'* ]]
  [[ "$output" != *$'\033'* ]]
  [[ "$output" != *$'\r'* ]]
  [ "$(grep -c 'Total (' <<<"$output")" -le 2 ]
  grep -Fq $'\033[32mTotal' "$SPAWN_RUNTIME_DIR/archinstall-console.log"
}

@test "rejected erase confirmation leaves no state and permits a retry" {
  local fake_bin="$BATS_TEST_TMPDIR/bin"
  local archinstall_marker="$BATS_TEST_TMPDIR/archinstall-called"
  mkdir -p "$fake_bin"
  install_test_ports
  disk_inventory_json() { cat "$REPO_ROOT/tests/fixtures/lsblk/reordered.json"; }
  confirm_disk_erase() { return 65; }
  cat >"$fake_bin/archinstall" <<FAKE
#!/usr/bin/env bash
touch "$archinstall_marker"
install -d -m 0755 "$SPAWN_TARGET_ROOT/etc"
printf 'fixture\n' >"$SPAWN_TARGET_ROOT/etc/fstab"
FAKE
  chmod +x "$fake_bin/archinstall"

  PATH="$fake_bin:$PATH" run cmd_install

  [ "$status" -eq 65 ]
  [ ! -e "$SPAWN_RUNTIME_DIR/install-state.json" ]
  [ ! -e "$SPAWN_RUNTIME_DIR/user_credentials.json" ]
  [ ! -e "$archinstall_marker" ]

  confirm_disk_erase() { :; }
  PATH="$fake_bin:$PATH" run cmd_install

  [ "$status" -eq 0 ]
  [ -e "$archinstall_marker" ]
  jq -e '.phase == "complete"' "$SPAWN_RUNTIME_DIR/install-state.json"
}

@test "changed disk identity stops before Archinstall and finalization" {
  local fake_bin="$BATS_TEST_TMPDIR/bin"
  local inventory_count="$BATS_TEST_TMPDIR/inventory-count"
  local archinstall_marker="$BATS_TEST_TMPDIR/archinstall-called"
  local finalizer_marker="$BATS_TEST_TMPDIR/finalizer-called"
  mkdir -p "$fake_bin"
  printf '0\n' >"$inventory_count"
  source_commit_resolve() { jq -r '.source.commit' "$SPAWN_PLAN_PATH"; }
  doctor_assert_installable() { :; }
  confirm_disk_erase() { :; }
  prompt_password_into() { printf -v "$1" '%s' 'unit-test-secret'; }
  archinstall_user_config() { install -m 0600 /dev/null "$2"; }
  archinstall_credentials() {
    install -m 0600 /dev/null "$2"
    credentials_register "$2"
  }
  archinstall_validate_materialized() { :; }
  finalize_target() { touch "$finalizer_marker"; }
  verify_target_offline() { :; }
  disk_inventory_json() {
    local count
    count="$(<"$inventory_count")"
    printf '%s\n' "$((count + 1))" >"$inventory_count"
    if ((count == 0)); then
      cat "$REPO_ROOT/tests/fixtures/lsblk/reordered.json"
    else
      jq '(.disks[] | select(.serial == "S7H0NX0W123456A") | .serial) = "CHANGED"' \
        "$REPO_ROOT/tests/fixtures/lsblk/reordered.json"
    fi
  }
  cat >"$fake_bin/archinstall" <<FAKE
#!/usr/bin/env bash
touch "$archinstall_marker"
FAKE
  chmod +x "$fake_bin/archinstall"

  PATH="$fake_bin:$PATH" run cmd_install

  [ "$status" -ne 0 ]
  [ ! -e "$archinstall_marker" ]
  [ ! -e "$finalizer_marker" ]
  jq -e '.phase == "failed"' "$SPAWN_RUNTIME_DIR/install-state.json"
}

@test "resume-finalize never invokes Archinstall or disk writers" {
  local fake_bin="$BATS_TEST_TMPDIR/bin"
  local forbidden="$BATS_TEST_TMPDIR/forbidden"
  local command_name
  mkdir -p "$fake_bin"
  install_test_ports
  for command_name in archinstall wipefs sgdisk cryptsetup mkfs.btrfs; do
    cat >"$fake_bin/$command_name" <<FAKE
#!/usr/bin/env bash
touch "$forbidden"
exit 99
FAKE
    chmod +x "$fake_bin/$command_name"
  done
  runtime_init
  state_create "$(sha256_file "$SPAWN_PLAN_PATH")"
  state_transition planned confirmed
  state_transition confirmed materialized
  state_transition materialized archinstall_running
  state_transition archinstall_running archinstall_complete
  state_transition archinstall_complete finalizing
  state_transition finalizing failed
  printf 'fixture\n' >"$SPAWN_TARGET_ROOT/etc/fstab"

  PATH="$fake_bin:$PATH" run cmd_install --resume-finalize

  [ "$status" -eq 0 ]
  [ ! -e "$forbidden" ]
  grep -Fx resume-target "$SPAWN_CALL_LOG"
  grep -Fx finalize "$SPAWN_CALL_LOG"
  grep -Fx verify "$SPAWN_CALL_LOG"
  jq -e '.phase == "complete"' "$SPAWN_RUNTIME_DIR/install-state.json"
}

@test "failed finalization forbids reboot and prints only safe follow-up commands" {
  local fake_bin="$BATS_TEST_TMPDIR/bin"
  local command_lines
  mkdir -p "$fake_bin"
  install_test_ports
  disk_inventory_json() { cat "$REPO_ROOT/tests/fixtures/lsblk/reordered.json"; }
  finalize_target() { return 70; }
  cat >"$fake_bin/archinstall" <<'FAKE'
#!/usr/bin/env bash
install -d -m 0755 "$SPAWN_TARGET_ROOT/etc"
printf 'fixture\n' >"$SPAWN_TARGET_ROOT/etc/fstab"
FAKE
  chmod +x "$fake_bin/archinstall"

  PATH="$fake_bin:$PATH" run cmd_install

  [ "$status" -ne 0 ]
  [[ "$output" == *'Do not reboot'* ]]
  [[ "$output" == *'./spawn-arch install --resume-finalize'* ]]
  [[ "$output" == *'./spawn-arch verify /mnt'* ]]
  command_lines="$(grep -E '^(sudo )?\./spawn-arch ' <<<"$output")"
  [ "$command_lines" = $'./spawn-arch install --resume-finalize\n./spawn-arch verify /mnt' ]
  jq -e '.phase == "failed" and .last_completed_phase == "archinstall_complete"' \
    "$SPAWN_RUNTIME_DIR/install-state.json"
}

@test "incomplete Archinstall target never advertises finalizer-only resume" {
  local fake_bin="$BATS_TEST_TMPDIR/bin"
  local command_lines
  mkdir -p "$fake_bin"
  install_test_ports
  disk_inventory_json() { cat "$REPO_ROOT/tests/fixtures/lsblk/reordered.json"; }
  cat >"$fake_bin/archinstall" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
  chmod +x "$fake_bin/archinstall"

  PATH="$fake_bin:$PATH" run cmd_install

  [ "$status" -ne 0 ]
  [[ "$output" == *'Do not reboot'* ]]
  [[ "$output" != *'./spawn-arch install --resume-finalize'* ]]
  command_lines="$(grep -E '^(sudo )?\./spawn-arch ' <<<"$output")"
  [ "$command_lines" = './spawn-arch verify /mnt' ]
  jq -e '.phase == "failed" and .failed_from == "archinstall_complete"' \
    "$SPAWN_RUNTIME_DIR/install-state.json"
}
