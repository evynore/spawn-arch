#!/usr/bin/env bats

load ../helpers/load

setup() {
  export SPAWN_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
  mkdir -m 0700 "$SPAWN_RUNTIME_DIR"
  load_lib archinstall-config
  PLAN_JSON="$(cat "$REPO_ROOT/tests/fixtures/archinstall/plan.json")"
}

@test "materializes the exact Archinstall 4.4 user configuration" {
  local output="$SPAWN_RUNTIME_DIR/user_configuration.json"

  archinstall_user_config "$PLAN_JSON" "$output"

  jq -e -f "$REPO_ROOT/tests/fixtures/archinstall/expected-shape.jq" "$output"
  jq -e --slurpfile packages <(packages_json "$REPO_ROOT/config/packages.txt") \
    '.packages == $packages[0]' "$output"
  [ "$(stat -c %a "$output")" = 600 ]
}

@test "credentials read secrets from file descriptors and lock root" {
  local output="$SPAWN_RUNTIME_DIR/user_credentials.json"
  local luks_fd user_fd
  _yescrypt_from_stdin() {
    local plaintext
    plaintext="$(cat)"
    [ "$plaintext" = 'user passphrase' ]
    printf '%s\n' '$y$j9T$fixed-test-hash'
  }

  exec {luks_fd}<<<'luks passphrase'
  exec {user_fd}<<<'user passphrase'
  archinstall_credentials "$PLAN_JSON" "$output" "$luks_fd" "$user_fd"
  exec {luks_fd}<&-
  exec {user_fd}<&-

  jq -e '
    .encryption_password == "luks passphrase" and
    (.users | length == 1) and
    .users[0].username == "evynore" and
    .users[0].sudo == true and
    .users[0].groups == ["wheel"] and
    (.users[0].enc_password | startswith("$y$")) and
    (has("root_enc_password") | not)
  ' "$output"
  [ "$(stat -c %a "$output")" = 600 ]
}

@test "materialized validator rejects commands and a broken LUKS reference" {
  local user_config="$SPAWN_RUNTIME_DIR/user_configuration.json"
  local credentials="$SPAWN_RUNTIME_DIR/user_credentials.json"
  local tampered="$SPAWN_RUNTIME_DIR/tampered.json"
  local luks_fd user_fd
  _yescrypt_from_stdin() {
    cat >/dev/null
    printf '%s\n' '$y$j9T$fixed-test-hash'
  }
  exec {luks_fd}<<<'luks passphrase'
  exec {user_fd}<<<'user passphrase'
  archinstall_user_config "$PLAN_JSON" "$user_config"
  archinstall_credentials "$PLAN_JSON" "$credentials" "$luks_fd" "$user_fd"
  exec {luks_fd}<&-
  exec {user_fd}<&-

  run archinstall_validate_materialized "$user_config" "$credentials"
  [ "$status" -eq 0 ]

  jq '.custom_commands = ["touch /bad"]' "$user_config" >"$tampered"
  chmod 0600 "$tampered"
  run archinstall_validate_materialized "$tampered" "$credentials"
  [ "$status" -ne 0 ]

  jq '.disk_config.disk_encryption.partitions = ["not-the-root-id"]' "$user_config" >"$tampered"
  chmod 0600 "$tampered"
  run archinstall_validate_materialized "$tampered" "$credentials"
  [ "$status" -ne 0 ]

  jq '.locale_config.kb_layout = "us"' "$user_config" >"$tampered"
  chmod 0600 "$tampered"
  run archinstall_validate_materialized "$tampered" "$credentials"
  [ "$status" -ne 0 ]

  jq '.disk_config.device_modifications[0].partitions[0].flags = ["boot"]' "$user_config" >"$tampered"
  chmod 0600 "$tampered"
  run archinstall_validate_materialized "$tampered" "$credentials"
  [ "$status" -ne 0 ]
}
