#!/usr/bin/env bats

load ../helpers/load

setup() {
  export SPAWN_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
  load_lib install
}

@test "plan is deterministic secret-free and invokes no destructive command" {
  local fake_bin="$BATS_TEST_TMPDIR/bin"
  local calls="$BATS_TEST_TMPDIR/destructive-calls"
  local archinstall_call="$BATS_TEST_TMPDIR/archinstall-call"
  local source_root="$BATS_TEST_TMPDIR/source"
  local plan_path="$BATS_TEST_TMPDIR/run/plan.json"
  local zoneinfo_root="$BATS_TEST_TMPDIR/zoneinfo"
  local keymap_root="$BATS_TEST_TMPDIR/keymaps"
  local locale_gen="$BATS_TEST_TMPDIR/locale.gen"
  local tty_file="$BATS_TEST_TMPDIR/tty"
  local command_name
  mkdir -p "$fake_bin" "$source_root" "$zoneinfo_root/Etc" "$keymap_root/i386/qwerty"
  printf '%s\n' 0123456789abcdef0123456789abcdef01234567 >"$source_root/SOURCE_COMMIT"
  touch "$zoneinfo_root/Etc/UTC" "$keymap_root/i386/qwerty/us.map.gz"
  printf '#en_US.UTF-8 UTF-8\n#ru_RU.UTF-8 UTF-8\n' >"$locale_gen"
  printf '\n' >"$tty_file"

  for command_name in wipefs sgdisk cryptsetup mkfs.ext4 mkfs.fat mkfs.btrfs mount; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >>"%s"\nexit 99\n' \
      "$command_name" "$calls" >"$fake_bin/$command_name"
    chmod +x "$fake_bin/$command_name"
  done
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >"%s"\n[[ -r "$4" ]]\n' \
    "$archinstall_call" >"$fake_bin/archinstall"
  chmod +x "$fake_bin/archinstall"

  doctor_assert_installable() { return 0; }
  export -f doctor_assert_installable
  _yescrypt_from_stdin() {
    cat >/dev/null
    printf '%s\n' '$y$j9T$dry-run-test-hash'
  }
  export -f _yescrypt_from_stdin
  PATH="$fake_bin:$PATH" \
    SPAWN_INVENTORY_JSON="$(cat "$REPO_ROOT/tests/fixtures/lsblk/gu606ax.json")" \
    SPAWN_LIVE_SOURCE=/dev/sda \
    SPAWN_DISK_SELECTION=2 \
    SPAWN_HOSTNAME=spawn \
    SPAWN_USERNAME=evynore \
    SPAWN_KEYMAP=us \
    SPAWN_LOCALE=en_US.UTF-8 \
    SPAWN_ARCHINSTALL_VERSION=4.4.0 \
    SPAWN_NOW=2026-07-16T00:00:00Z \
    SPAWN_SOURCE_ROOT="$source_root" \
    SPAWN_PLAN_PATH="$plan_path" \
    SPAWN_RUNTIME_DISABLE_TRAPS=true \
    SPAWN_TTY_PATH="$tty_file" \
    SPAWN_ZONEINFO_ROOT="$zoneinfo_root" \
    SPAWN_KEYMAP_ROOT="$keymap_root" \
    SPAWN_LOCALE_GEN="$locale_gen" \
    run cmd_plan

  [ "$status" -eq 0 ]
  [ ! -e "$calls" ]
  [ "$(cat "$archinstall_call")" = "--config $BATS_TEST_TMPDIR/run/user_configuration.json --creds $BATS_TEST_TMPDIR/run/dry-run-credentials.json --silent --dry-run" ]
  [ ! -e "$BATS_TEST_TMPDIR/run/dry-run-credentials.json" ]
  jq -e '
    .schema_version == 1 and
    .target.device_at_plan_time == "/dev/nvme1n1" and
    .system.username == "evynore" and
    .system.timezone == "Etc/UTC" and
    .storage.subvolumes == ["@", "@home", "@log", "@pkg", "@snapshots"] and
    .archinstall.version == "4.4.0" and
    .source.commit == "0123456789abcdef0123456789abcdef01234567" and
    ([paths(scalars) as $p | $p[-1] | strings | select(test("password|credential|secret"; "i"))] | length == 0)
  ' "$plan_path"
  [ "$(stat -c %a "$plan_path")" = 600 ]
}

@test "source provenance rejects malformed release metadata" {
  local source_root="$BATS_TEST_TMPDIR/source"
  mkdir -p "$source_root"
  printf 'not-a-commit\n' >"$source_root/SOURCE_COMMIT"

  run source_commit_resolve "$source_root"

  [ "$status" -ne 0 ]
}
