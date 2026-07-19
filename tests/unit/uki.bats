#!/usr/bin/env bats

load ../helpers/load

setup() {
  export SPAWN_BOOT_ROOT="$BATS_TEST_TMPDIR/boot"
  export SPAWN_ETC_ROOT="$BATS_TEST_TMPDIR/etc"
  export SPAWN_INSTALLED_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
  export SPAWN_EFIVAR_PATH="$BATS_TEST_TMPDIR/LoaderEntrySelected"
  export FAKE_SECTIONS_JSON="$REPO_ROOT/tests/fixtures/uki/sections.json"
  mkdir -p "$SPAWN_BOOT_ROOT/EFI/Linux" "$SPAWN_BOOT_ROOT/loader" "$SPAWN_ETC_ROOT/kernel" "$SPAWN_ETC_ROOT/spawn-arch" "$SPAWN_INSTALLED_RUNTIME_DIR"
  jq -r '.cmdline' "$FAKE_SECTIONS_JSON" >"$SPAWN_ETC_ROOT/kernel/cmdline"
  jq -r '.osrel_last_good_template' "$FAKE_SECTIONS_JSON" >"$SPAWN_ETC_ROOT/spawn-arch/uki-last-good.os-release"
  make_uki_fakes
  # shellcheck source=/dev/null
  source "$REPO_ROOT/payload/usr/local/lib/spawn-arch/boot-state.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/payload/usr/local/lib/spawn-arch/uki.sh"
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

make_uki_fakes() {
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
  for argument in "${args[@]}"; do
    if [[ "$argument" == .osrel=* ]]; then
      python3 - "${argument#*=}" "$(jq -r '.uname' "$FAKE_SECTIONS_JSON")~lg" "$FAKE_SECTIONS_JSON" <<'PY'
import json
import pathlib
import shlex
import sys

raw = pathlib.Path(sys.argv[1]).read_bytes()
fixture = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
section_capacity = len((fixture["osrel_current"] + "\n").encode("utf-8"))
if len(raw) > section_capacity:
    raise SystemExit(65)
values = {}
for line in raw.decode("utf-8").splitlines():
    if "=" in line:
        key, raw = line.split("=", 1)
        parsed = shlex.split(raw)
        if len(parsed) == 1:
            values[key] = parsed[0]
if values.get("VERSION_ID") != sys.argv[2]:
    raise SystemExit(65)
PY
    fi
  done
  cp "$input" "$output"
  exit 0
fi
slot=current
[[ "$input" == *last-good* ]] && slot=last_good
if [[ "${FAKE_OBJCOPY_MUTATE_INPUT:-false}" == true ]]; then
  printf 'objcopy-rewrite\n' >>"$input"
fi
for argument in "${args[@]}"; do
  case "$argument" in
    .linux=*) jq -r '.linux' "$FAKE_SECTIONS_JSON" >"${argument#*=}" ;;
    .initrd=*) jq -r '.initrd' "$FAKE_SECTIONS_JSON" >"${argument#*=}" ;;
    .uname=*) jq -r '.uname' "$FAKE_SECTIONS_JSON" >"${argument#*=}" ;;
    .cmdline=*) printf '%s \n\0' "$(jq -r '.cmdline' "$FAKE_SECTIONS_JSON")" >"${argument#*=}" ;;
    .osrel=*) jq -r ".osrel_${slot}" "$FAKE_SECTIONS_JSON" >"${argument#*=}" ;;
  esac
done
FAKE
  cat >"$fake_bin/bootctl" <<'FAKE'
#!/usr/bin/env bash
if [[ " $* " == *" --json=short "* ]]; then
  printf '%s\n' '[{"type":"type2","source":"uki","id":"spawn-arch-current.efi","path":"/boot/EFI/Linux/spawn-arch-current.efi"},{"type":"type2","source":"uki","id":"spawn-arch-last-good.efi","path":"/boot/EFI/Linux/spawn-arch-last-good.efi"}]'
  exit 0
fi
cat <<'OUTPUT'
Boot Loader Entries:
         type: Boot Loader Specification Type #2 (.efi)
        title: Spawn Arch (current) (default)
           id: spawn-arch-current.efi
       source: /boot/EFI/Linux/spawn-arch-current.efi

         type: Boot Loader Specification Type #2 (.efi)
        title: Spawn Arch (last-good)
           id: spawn-arch-last-good.efi
       source: /boot/EFI/Linux/spawn-arch-last-good.efi
OUTPUT
FAKE
  chmod +x "$fake_bin/objcopy" "$fake_bin/bootctl"
  export PATH="$fake_bin:$PATH"
}

@test "selected entry is decoded only from the standardized EFI variable" {
  decode_hex_fixture "$REPO_ROOT/tests/fixtures/efi/loader-entry-current.bin" "$SPAWN_EFIVAR_PATH"
  run boot_selected_entry
  [ "$status" -eq 0 ]
  [ "$output" = spawn-arch-current ]

  decode_hex_fixture "$REPO_ROOT/tests/fixtures/efi/loader-entry-last-good.bin" "$SPAWN_EFIVAR_PATH"
  run boot_selected_entry
  [ "$status" -eq 0 ]
  [ "$output" = spawn-arch-last-good ]

  printf 'bad' >"$SPAWN_EFIVAR_PATH"
  run boot_selected_entry
  [ "$status" -ne 0 ]
}

@test "UKI validator requires sections exact cmdline slot metadata and bootctl entry" {
  local current="$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-current.efi"
  local cmdline
  printf 'fixture-pe\n' >"$current"
  cmdline="$(<"$SPAWN_ETC_ROOT/kernel/cmdline")"

  run uki_validate "$current" "$cmdline" current

  [ "$status" -eq 0 ]
}

@test "UKI validator rejects a fixed root subvolume" {
  local current="$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-current.efi"
  local bad
  printf 'fixture-pe\n' >"$current"
  bad="$(jq -r '.cmdline' "$FAKE_SECTIONS_JSON") rootflags=subvol=@"
  jq --arg cmdline "$bad" '.cmdline = $cmdline' "$FAKE_SECTIONS_JSON" >"$BATS_TEST_TMPDIR/bad-sections.json"
  FAKE_SECTIONS_JSON="$BATS_TEST_TMPDIR/bad-sections.json" run uki_validate "$current" "$bad" current

  [ "$status" -ne 0 ]
}

@test "metadata reads and validation never mutate the source UKI" {
  local current="$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-current.efi"
  local before after
  printf 'fixture-pe\n' >"$current"
  export FAKE_OBJCOPY_MUTATE_INPUT=true

  before="$(sha256sum "$current" | awk '{print $1}')"
  run uki_section_read "$current" .uname
  [ "$status" -eq 0 ]
  after="$(sha256sum "$current" | awk '{print $1}')"
  [ "$after" = "$before" ]

  run uki_validate "$current" "$(<"$SPAWN_ETC_ROOT/kernel/cmdline")" current false
  [ "$status" -eq 0 ]
  after="$(sha256sum "$current" | awk '{print $1}')"
  [ "$after" = "$before" ]
}

@test "last-good is copied through a validated same-ESP staging file" {
  local current="$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-current.efi"
  local last_good="$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-last-good.efi"
  printf 'fixture-pe\n' >"$current"

  uki_copy_as_last_good "$current" "$last_good"

  [ -s "$last_good" ]
  run uki_validate "$last_good" "$(<"$SPAWN_ETC_ROOT/kernel/cmdline")" last-good
  [ "$status" -eq 0 ]
}
