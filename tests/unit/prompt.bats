#!/usr/bin/env bats

load ../helpers/load

setup() {
  load_lib prompt
  export SPAWN_ZONEINFO_ROOT="$BATS_TEST_TMPDIR/zoneinfo"
  export SPAWN_KEYMAP_ROOT="$BATS_TEST_TMPDIR/keymaps"
  export SPAWN_LOCALE_GEN="$BATS_TEST_TMPDIR/locale.gen"
  mkdir -p "$SPAWN_ZONEINFO_ROOT/Etc" "$SPAWN_KEYMAP_ROOT/i386/qwerty"
  touch "$SPAWN_ZONEINFO_ROOT/Etc/UTC" "$SPAWN_KEYMAP_ROOT/i386/qwerty/us.map.gz"
  printf '#en_US.UTF-8 UTF-8\n#ru_RU.UTF-8 UTF-8\n' >"$SPAWN_LOCALE_GEN"
}

@test "accepts the approved profile values" {
  run validate_hostname spawn
  [ "$status" -eq 0 ]
  run validate_username evynore
  [ "$status" -eq 0 ]
  run validate_timezone Etc/UTC
  [ "$status" -eq 0 ]
  run validate_keymap us
  [ "$status" -eq 0 ]
  run validate_locale en_US.UTF-8
  [ "$status" -eq 0 ]

  run generated_locales_json en_US.UTF-8
  [ "$status" -eq 0 ]
  jq -e '. == ["en_US.UTF-8", "ru_RU.UTF-8"]' <<<"$output"
}

@test "rejects invalid profile values" {
  run validate_hostname '-spawn'
  [ "$status" -ne 0 ]
  run validate_hostname 'spawn..local'
  [ "$status" -ne 0 ]
  run validate_username root
  [ "$status" -ne 0 ]
  run validate_username 'Bad User'
  [ "$status" -ne 0 ]
  run validate_timezone ../../etc/passwd
  [ "$status" -ne 0 ]
  run validate_timezone Europe/Nowhere
  [ "$status" -ne 0 ]
  run validate_keymap moon
  [ "$status" -ne 0 ]
  run validate_locale xx_YY.UTF-8
  [ "$status" -ne 0 ]
}

@test "password prompt returns through a named variable and rejects mismatch" {
  local tty_file="$BATS_TEST_TMPDIR/tty"
  local secret="unchanged"

  printf 'correct horse\ncorrect horse\n' >"$tty_file"
  SPAWN_TTY_PATH="$tty_file" prompt_password_into secret 'User password'
  [ "$secret" = 'correct horse' ]

  printf 'first\nsecond\n' >"$tty_file"
  SPAWN_TTY_PATH="$tty_file" run prompt_password_into secret 'User password'
  [ "$status" -ne 0 ]
  [[ "$output" != *first* ]]
  [[ "$output" != *second* ]]
}
