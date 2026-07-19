#!/usr/bin/env bats

load ../helpers/load

setup() {
  export SPAWN_BOOT_ROOT="$BATS_TEST_TMPDIR/boot"
  export SPAWN_ETC_ROOT="$BATS_TEST_TMPDIR/etc"
  export SPAWN_INSTALLED_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
  export SPAWN_EFIVAR_PATH="$BATS_TEST_TMPDIR/LoaderEntrySelected"
  export SPAWN_SNAP_PAC_PREFILE="$BATS_TEST_TMPDIR/snap-pac-pre_root"
  export SPAWN_NOW=2026-07-16T00:00:00Z
  export FAKE_SECTIONS_JSON="$REPO_ROOT/tests/fixtures/uki/sections.json"
  export FAKE_SNAPPER_OUTPUT="$REPO_ROOT/tests/fixtures/snapper/pre-list.csv"
  export FAKE_BAD_LAST_GOOD=false
  export SPAWN_COMMAND_LOG="$BATS_TEST_TMPDIR/commands"
  mkdir -p \
    "$SPAWN_BOOT_ROOT/EFI/Linux" \
    "$SPAWN_BOOT_ROOT/loader" \
    "$SPAWN_ETC_ROOT/kernel" \
    "$SPAWN_ETC_ROOT/spawn-arch" \
    "$SPAWN_INSTALLED_RUNTIME_DIR"
  jq -r '.cmdline' "$FAKE_SECTIONS_JSON" >"$SPAWN_ETC_ROOT/kernel/cmdline"
  jq -r '.osrel_last_good' "$FAKE_SECTIONS_JSON" >"$SPAWN_ETC_ROOT/spawn-arch/uki-last-good.os-release"
  make_command_fakes
  # shellcheck source=/dev/null
  source "$REPO_ROOT/payload/usr/local/lib/spawn-arch/preserve-uki.sh"
  printf 'fixture-current-uki\n' >"$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-current.efi"
  printf 'fixture-old-last-good-uki\n' >"$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-last-good.efi"
  write_valid_state
  decode_hex_fixture "$REPO_ROOT/tests/fixtures/efi/loader-entry-current.bin" "$SPAWN_EFIVAR_PATH"
  printf '7394\n' >"$SPAWN_SNAP_PAC_PREFILE"
}

decode_hex_fixture() {
  local source="$1"
  local destination="$2"
  local hex index

  hex="$(tr -d '[:space:]' <"$source")"
  : >"$destination"
  for ((index = 0; index < ${#hex}; index += 2)); do
    printf '%b' "\\x${hex:index:2}" >>"$destination"
  done
}

write_valid_state() {
  local current_hash last_good_hash state

  current_hash="$(sha256sum "$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-current.efi" | awk '{print $1}')"
  last_good_hash="$(sha256sum "$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-last-good.efi" | awk '{print $1}')"
  state="$(jq -n --arg current "$current_hash" --arg last_good "$last_good_hash" '{
    schema_version: 1,
    generation: 1,
    current: {entry: "spawn-arch-current", sha256: $current, blessed: true},
    last_good: {entry: "spawn-arch-last-good", sha256: $last_good},
    pending: null,
    seed: {subvolume_id: 256, retired: false, safety_snapshot_id: null}
  }')"
  boot_state_write "$state"
}

make_command_fakes() {
  local fake_bin="$BATS_TEST_TMPDIR/bin"

  mkdir -p "$fake_bin"
  cat >"$fake_bin/objcopy" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
input="${args[${#args[@]} - 1]}"
if [[ " ${args[*]} " == *" --update-section "* ]]; then
  input="${args[${#args[@]} - 2]}"
  output="${args[${#args[@]} - 1]}"
  cp -- "$input" "$output"
  exit 0
fi
slot=current
[[ "$input" == *last-good* ]] && slot=last_good
for argument in "${args[@]}"; do
  case "$argument" in
    .linux=*) jq -r '.linux' "$FAKE_SECTIONS_JSON" >"${argument#*=}" ;;
    .initrd=*) jq -r '.initrd' "$FAKE_SECTIONS_JSON" >"${argument#*=}" ;;
    .uname=*) jq -r '.uname' "$FAKE_SECTIONS_JSON" >"${argument#*=}" ;;
    .cmdline=*) jq -r '.cmdline' "$FAKE_SECTIONS_JSON" >"${argument#*=}" ;;
    .osrel=*)
      if [[ "$FAKE_BAD_LAST_GOOD" == true && "$input" == */spawn-arch-last-good.efi ]]; then
        printf 'NAME="Spawn Arch"\nVERSION_ID="broken"\nPRETTY_NAME="broken"\n' >"${argument#*=}"
      else
        jq -r ".osrel_${slot}" "$FAKE_SECTIONS_JSON" >"${argument#*=}"
      fi
      ;;
  esac
done
FAKE
  cat >"$fake_bin/bootctl" <<'FAKE'
#!/usr/bin/env bash
if [[ " $* " == *" --json=short "* ]]; then
  printf '%s\n' '[{"type":"type2","source":"uki","id":"spawn-arch-current.efi","path":"/boot/EFI/Linux/spawn-arch-current.efi"},{"type":"type2","source":"uki","id":"spawn-arch-last-good.efi","path":"/boot/EFI/Linux/spawn-arch-last-good.efi"}]'
else
  printf '%s\n' spawn-arch-current.efi spawn-arch-last-good.efi
fi
FAKE
  cat >"$fake_bin/snapper" <<'FAKE'
#!/usr/bin/env bash
printf 'snapper:%s\n' "$*" >>"$SPAWN_COMMAND_LOG"
cat -- "$FAKE_SNAPPER_OUTPUT"
FAKE
  chmod +x "$fake_bin/objcopy" "$fake_bin/bootctl" "$fake_bin/snapper"
  export PATH="$fake_bin:$PATH"
}

tree_hash() {
  local path

  while IFS= read -r -d '' path; do
    printf '%s  %s\n' "$(sha256sum "$SPAWN_BOOT_ROOT/$path" | awk '{print $1}')" "$path"
  done < <(find "$SPAWN_BOOT_ROOT" -type f -printf '%P\0' | sort -z)
}

@test "hook runs after snap-pac pre with the exact critical target set" {
  local hook="$REPO_ROOT/payload/etc/pacman.d/hooks/06-spawn-arch-preserve-uki.hook"
  local expected="$BATS_TEST_TMPDIR/expected"
  local actual="$BATS_TEST_TMPDIR/actual"

  printf '%s\n' linux linux-firmware intel-ucode nvidia-open nvidia-utils mkinitcpio systemd cryptsetup btrfs-progs | sort >"$expected"
  sed -n 's/^Target = //p' "$hook" | sort >"$actual"
  diff -u "$expected" "$actual"
  [ "$(grep -c '^Operation = ' "$hook")" -eq 3 ]
  grep -Fx 'Operation = Install' "$hook"
  grep -Fx 'Operation = Upgrade' "$hook"
  grep -Fx 'Operation = Remove' "$hook"
  grep -Fx 'Type = Package' "$hook"
  grep -Fx 'When = PreTransaction' "$hook"
  grep -Fx 'Exec = /usr/local/lib/spawn-arch/preserve-uki.sh' "$hook"
  grep -Fx 'AbortOnFail' "$hook"
  grep -Fx 'NeedsTargets' "$hook"
  [[ 05-snap-pac-pre < 06-spawn-arch-preserve-uki ]]
}

@test "valid transaction pins the exact pre snapshot and preserves current as last-good" {
  run preserve_uki_main <<<'systemd
linux'

  [ "$status" -eq 0 ]
  jq -e '
    .generation == 2 and .current.blessed == false and
    .pending == {
      kind: "pacman",
      pre_snapshot_id: 7394,
      previous_current_sha256: .current.sha256,
      packages: ["linux", "systemd"],
      created_at: "2026-07-16T00:00:00Z"
    }
  ' "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json"
  [ -e "$SPAWN_SNAP_PAC_PREFILE" ]
  [ ! -e "$SPAWN_BOOT_ROOT/loader/spawn-arch-transaction.json" ]
  grep -Fx 'snapper:-c root --csvout --no-headers --columns number,pre-number list --type pre-post' "$SPAWN_COMMAND_LOG"
}

@test "missing or invalid state aborts before mutation" {
  rm -f "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json"
  run preserve_uki_main <<<'linux'
  [ "$status" -ne 0 ]

  printf '{broken\n' >"$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json"
  rm -f "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json.previous"
  run preserve_uki_main <<<'linux'
  [ "$status" -ne 0 ]
}

@test "unblessed current and an existing pending operation are blocked" {
  jq '.current.blessed = false' "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json" >"$BATS_TEST_TMPDIR/state"
  mv "$BATS_TEST_TMPDIR/state" "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json"
  run preserve_uki_main <<<'linux'
  [ "$status" -ne 0 ]

  jq '.current.blessed = true | .pending = {
    kind: "pacman", pre_snapshot_id: 7000,
    previous_current_sha256: .current.sha256,
    packages: ["linux"], created_at: "2026-07-15T00:00:00Z"
  }' "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json" >"$BATS_TEST_TMPDIR/state"
  mv "$BATS_TEST_TMPDIR/state" "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json"
  run preserve_uki_main <<<'linux'
  [ "$status" -ne 0 ]
}

@test "selected last-good and a changed current hash are blocked" {
  decode_hex_fixture "$REPO_ROOT/tests/fixtures/efi/loader-entry-last-good.bin" "$SPAWN_EFIVAR_PATH"
  run preserve_uki_main <<<'linux'
  [ "$status" -ne 0 ]

  decode_hex_fixture "$REPO_ROOT/tests/fixtures/efi/loader-entry-current.bin" "$SPAWN_EFIVAR_PATH"
  printf 'changed\n' >"$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-current.efi"
  run preserve_uki_main <<<'linux'
  [ "$status" -ne 0 ]
}

@test "missing and nonnumeric snap-pac prefiles are blocked" {
  rm -f "$SPAWN_SNAP_PAC_PREFILE"
  run preserve_uki_main <<<'linux'
  [ "$status" -ne 0 ]

  printf 'latest\n' >"$SPAWN_SNAP_PAC_PREFILE"
  run preserve_uki_main <<<'linux'
  [ "$status" -ne 0 ]
}

@test "absent and post snapshots cannot satisfy the pinned pre snapshot" {
  printf '7000,\n' >"$BATS_TEST_TMPDIR/snapshots.csv"
  FAKE_SNAPPER_OUTPUT="$BATS_TEST_TMPDIR/snapshots.csv" run preserve_uki_main <<<'linux'
  [ "$status" -ne 0 ]

  printf '7394,7000\n' >"$BATS_TEST_TMPDIR/snapshots.csv"
  FAKE_SNAPPER_OUTPUT="$BATS_TEST_TMPDIR/snapshots.csv" run preserve_uki_main <<<'linux'
  [ "$status" -ne 0 ]
}

@test "invalid last-good metadata and foreign targets are blocked" {
  FAKE_BAD_LAST_GOOD=true run preserve_uki_main <<<'linux'
  [ "$status" -ne 0 ]

  run preserve_uki_main <<<'openssl'
  [ "$status" -ne 0 ]
}

@test "ordinary commit failure restores state and last-good exactly" {
  local before after

  before="$(tree_hash)"
  SPAWN_TEST_FAIL_PHASE=after_artifact_rename run preserve_uki_main <<<'linux'
  [ "$status" -ne 0 ]
  after="$(tree_hash)"

  [ "$after" = "$before" ]
  [ ! -e "$SPAWN_BOOT_ROOT/loader/spawn-arch-transaction.json" ]
}
