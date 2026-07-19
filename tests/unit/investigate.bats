#!/usr/bin/env bats

load ../helpers/load

setup() {
  export SPAWN_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
  export SPAWN_INVESTIGATE_NOW=2026-07-17T12:00:00Z
  export SPAWN_INVESTIGATE_TIMEOUT_SECONDS=2
  export SPAWN_INVESTIGATE_TAIL_LINES=50
  export SPAWN_INVESTIGATE_MAX_BYTES=512
  export REPORT_DIR="$BATS_TEST_TMPDIR/out"
  export FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$SPAWN_RUNTIME_DIR" "$REPORT_DIR" "$FAKE_BIN"
  load_lib investigate
  make_investigation_fakes
  make_investigation_sources
}

assert_file_omits() {
  local needle="$1"
  local file="$2"

  if grep -Fq -- "$needle" "$file"; then
    printf 'unexpected sensitive value in %s: %s\n' "$file" "$needle" >&2
    return 1
  fi
}

make_investigation_fakes() {
  cat >"$FAKE_BIN/dmesg" <<'FAKE'
#!/usr/bin/env bash
printf 'adapter mac=aa:bb:cc:dd:ee:ff serial=DISK-SERIAL-SECRET\n'
printf '\377invalid-utf8\n'
head -c 2048 /dev/zero | tr '\0' x
exit 9
FAKE
  cat >"$FAKE_BIN/lsblk" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' '{"blockdevices":[{"name":"nvme0n1","serial":"DISK-SERIAL-SECRET","wwn":"eui.STABLE-DEVICE-ID"}]}'
FAKE
  cat >"$FAKE_BIN/findmnt" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *'-rn -o SOURCE'*) printf '/dev/mapper/cryptroot\n' ;;
  *) printf '/mnt /dev/mapper/cryptroot btrfs rw\n' ;;
esac
FAKE
  cat >"$FAKE_BIN/cryptsetup" <<'FAKE'
#!/usr/bin/env bash
printf '/dev/mapper/%s is active\n' "$2"
FAKE
  cat >"$FAKE_BIN/machinectl" <<'FAKE'
#!/usr/bin/env bash
printf 'machined unavailable\n' >&2
exit 7
FAKE
  cat >"$FAKE_BIN/ps" <<'FAKE'
#!/usr/bin/env bash
printf '100 1 S 3 archinstall archinstall --silent\n'
FAKE
  chmod +x "$FAKE_BIN"/*
  export PATH="$FAKE_BIN:$PATH"
}

make_investigation_sources() {
  cp "$REPO_ROOT/tests/fixtures/archinstall/plan.json" "$SPAWN_RUNTIME_DIR/plan.json"
  jq -n '{schema_version:1, phase:"archinstall_running", failed_from:null, plan_sha256:"abc"}' \
    >"$SPAWN_RUNTIME_DIR/install-state.json"
  cat >"$SPAWN_RUNTIME_DIR/archinstall-console.log" <<'LOG'
password=console-secret
Authorization: Bearer bearer-secret-token
$y$j9T$secret-password-hash
LOG
  printf '\033[31mcolored-console-line\033[0m\n' >>"$SPAWN_RUNTIME_DIR/archinstall-console.log"
  printf 'credential-canary-must-never-appear\n' >"$SPAWN_RUNTIME_DIR/user_credentials.json"
}

@test "investigate writes bounded redacted machine and screen reports" {
  local readable json
  local -a paths
  cd "$REPORT_DIR"

  run cmd_investigate

  [ "$status" -eq 0 ]
  mapfile -t paths <<<"$output"
  [ "${paths[0]}" = "readable_report=$REPORT_DIR/spawn-arch-investigation-20260717T120000Z.txt" ]
  [ "${paths[1]}" = "json_report=$REPORT_DIR/spawn-arch-investigation-20260717T120000Z.json" ]
  readable="${paths[0]#readable_report=}"
  json="${paths[1]#json_report=}"
  [ -f "$readable" ]
  [ -f "$json" ]
  [ "$(stat -c %a "$readable")" = 600 ]
  [ "$(stat -c %a "$json")" = 600 ]
  jq -e '
    .schema_version == 1 and
    .ok == true and
    .created_at == "2026-07-17T12:00:00Z" and
    .collectors.machinectl.ok == false and
    .collectors.machinectl.exit_code == 7 and
    .collectors.dmesg.ok == false and
    .collectors.dmesg.exit_code == 9 and
    .collectors.dmesg.truncated == true and
    .collectors.archinstall_console.ok == true
  ' "$json"
  jq -e . "$json" >/dev/null
  grep -F '===== archinstall_console | ok=true exit=0 truncated=false =====' "$readable"
  grep -Fx 'password=<redacted>' "$readable"
  grep -Fx 'colored-console-line' "$readable"
  grep -F '<redacted>' "$json"
  for report in "$readable" "$json"; do
    assert_file_omits 'console-secret' "$report"
    assert_file_omits 'bearer-secret-token' "$report"
    assert_file_omits 'secret-password-hash' "$report"
    assert_file_omits 'aa:bb:cc:dd:ee:ff' "$report"
    assert_file_omits 'DISK-SERIAL-SECRET' "$report"
    assert_file_omits 'eui.STABLE-DEVICE-ID' "$report"
    assert_file_omits 'credential-canary-must-never-appear' "$report"
    assert_file_omits 'S7H0NX0W123456A' "$report"
    assert_file_omits $'\033' "$report"
  done
}

@test "investigate publishes one collision-safe basename for both reports" {
  local readable json
  local -a paths
  cd "$REPORT_DIR"
  printf 'keep-json\n' >spawn-arch-investigation-20260717T120000Z.json
  printf 'keep-text\n' >spawn-arch-investigation-20260717T120000Z.txt

  run cmd_investigate

  [ "$status" -eq 0 ]
  mapfile -t paths <<<"$output"
  [ "${paths[0]}" = "readable_report=$REPORT_DIR/spawn-arch-investigation-20260717T120000Z-1.txt" ]
  [ "${paths[1]}" = "json_report=$REPORT_DIR/spawn-arch-investigation-20260717T120000Z-1.json" ]
  readable="${paths[0]#readable_report=}"
  json="${paths[1]#json_report=}"
  [ -f "$readable" ]
  [ -f "$json" ]
  [ "$(cat spawn-arch-investigation-20260717T120000Z.json)" = keep-json ]
  [ "$(cat spawn-arch-investigation-20260717T120000Z.txt)" = keep-text ]
}
