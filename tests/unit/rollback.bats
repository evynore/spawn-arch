#!/usr/bin/env bats

load ../helpers/load

setup() {
  export SPAWN_BOOT_ROOT="$BATS_TEST_TMPDIR/boot"
  export SPAWN_ETC_ROOT="$BATS_TEST_TMPDIR/etc"
  export SPAWN_INSTALLED_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
  export SPAWN_ROLLBACK_MOUNT_ROOT="$BATS_TEST_TMPDIR/mnt"
  export SPAWN_EFIVAR_PATH="$BATS_TEST_TMPDIR/LoaderEntrySelected"
  export SPAWN_NOW=2026-07-16T00:00:00Z
  export SPAWN_COMMAND_LOG="$BATS_TEST_TMPDIR/commands"
  export FAKE_SECTIONS_JSON="$REPO_ROOT/tests/fixtures/uki/sections.json"
  export FAKE_SNAPPER_BEFORE="$REPO_ROOT/tests/fixtures/snapper/list.json"
  export FAKE_SNAPPER_AFTER="$REPO_ROOT/tests/fixtures/snapper/rollback-after.json"
  export FAKE_TEST_ROOT="$BATS_TEST_TMPDIR"
  mkdir -p \
    "$SPAWN_BOOT_ROOT/EFI/Linux" "$SPAWN_BOOT_ROOT/loader" \
    "$SPAWN_ETC_ROOT/kernel" "$SPAWN_ETC_ROOT/spawn-arch" \
    "$SPAWN_INSTALLED_RUNTIME_DIR"
  jq -r '.cmdline' "$FAKE_SECTIONS_JSON" >"$SPAWN_ETC_ROOT/kernel/cmdline"
  jq -r '.osrel_last_good' "$FAKE_SECTIONS_JSON" >"$SPAWN_ETC_ROOT/spawn-arch/uki-last-good.os-release"
  make_command_fakes
  # shellcheck source=/dev/null
  source "$REPO_ROOT/payload/usr/local/lib/spawn-arch/rollback.sh"
  reset_fixture
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

reset_fixture() {
  local current_hash last_good_hash state

  rm -f \
    "$BATS_TEST_TMPDIR/snapper-rolled" "$BATS_TEST_TMPDIR/default-restored" \
    "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json.previous" \
    "$SPAWN_BOOT_ROOT/loader/spawn-arch-transaction.json"
  find "$SPAWN_BOOT_ROOT/EFI/Linux" -type f -delete
  find "$SPAWN_INSTALLED_RUNTIME_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  : >"$SPAWN_COMMAND_LOG"
  printf 'old-current-uki\n' >"$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-current.efi"
  printf 'old-last-good-uki\n' >"$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-last-good.efi"
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
  jq -S . <<<"$state" >"$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json"
  chmod 0600 "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json"
  decode_hex_fixture "$REPO_ROOT/tests/fixtures/efi/loader-entry-current.bin" "$SPAWN_EFIVAR_PATH"
}

make_command_fakes() {
  local fake_bin="$BATS_TEST_TMPDIR/bin"
  local command_name

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
    .osrel=*) jq -r ".osrel_${slot}" "$FAKE_SECTIONS_JSON" >"${argument#*=}" ;;
  esac
done
FAKE
  cat >"$fake_bin/fake-command" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
name="$(basename "$0")"
printf '%s:%s\n' "$name" "$*" >>"$SPAWN_COMMAND_LOG"
case "$name:$*" in
  "mountpoint:-q /" | "mountpoint:-q /.snapshots" | "mountpoint:-q /boot") exit 0 ;;
  "findmnt:-n -o FSTYPE --target /" | "findmnt:-n -o FSTYPE --target /.snapshots") printf 'btrfs\n' ;;
  "findmnt:-n -o SOURCE --target /") printf '/dev/mapper/cryptroot\n' ;;
  "findmnt:-n -o SOURCE --target /boot") printf '/dev/nvme0n1p1\n' ;;
  "btrfs:subvolume get-default "*)
    if [[ -e "$FAKE_TEST_ROOT/snapper-rolled" && ! -e "$FAKE_TEST_ROOT/default-restored" ]]; then
      printf 'ID 812 gen 2 top level 5 path @rollback\n'
    else
      printf 'ID 256 gen 1 top level 5 path @\n'
    fi
    ;;
  "btrfs:subvolume set-default 256 "*) touch "$FAKE_TEST_ROOT/default-restored" ;;
  "snapper:-c root --jsonout list"*)
    if [[ -e "$FAKE_TEST_ROOT/snapper-rolled" ]]; then cat "$FAKE_SNAPPER_AFTER"; else cat "$FAKE_SNAPPER_BEFORE"; fi
    ;;
  "snapper:-c root rollback 7394") touch "$FAKE_TEST_ROOT/snapper-rolled" ;;
  "snapper:-c root delete "*) exit 0 ;;
  "bootctl:"*"get-default") printf 'spawn-arch-current\n' ;;
  "bootctl:"*"set-default "*) exit 0 ;;
  "bootctl:"*"--json=short"*"list")
    printf '%s\n' '[{"type":"type2","source":"uki","id":"spawn-arch-current.efi","path":"/boot/EFI/Linux/spawn-arch-current.efi"},{"type":"type2","source":"uki","id":"spawn-arch-last-good.efi","path":"/boot/EFI/Linux/spawn-arch-last-good.efi"}]'
    ;;
  "bootctl:"*"list") printf '%s\n' spawn-arch-current.efi spawn-arch-last-good.efi ;;
  "mount:-t btrfs -o subvolid=5 -- "*) mkdir -p -- "${*: -1}" ;;
  "mount:-t btrfs -o subvolid=812 -- "*)
    root="${*: -1}"
    mkdir -p "$root"/{boot,dev,proc,sys,run,etc/kernel,etc/mkinitcpio.d,usr/lib/modules/6.15.7-arch1-1}
    cp "$FAKE_TEST_ROOT/etc/kernel/cmdline" "$root/etc/kernel/cmdline"
    printf 'linux\n' >"$root/usr/lib/modules/6.15.7-arch1-1/pkgbase"
    printf 'future-kernel\n' >"$root/usr/lib/modules/6.15.7-arch1-1/vmlinuz"
    ;;
  "mount:-t tmpfs"* | "mount:--rbind "* | "mount:-t proc "* | "mount:--make-rslave "*) exit 0 ;;
  "umount:-- "*)
    target="${*: -1}"
    rm -rf -- "$target"/*
    ;;
  "arch-chroot:"*"mkinitcpio -p linux")
    mkdir -p "$1/boot/EFI/Linux"
    printf 'candidate-current-uki\n' >"$1/boot/EFI/Linux/spawn-arch-current.efi"
    ;;
  *) exit 0 ;;
esac
FAKE
  chmod +x "$fake_bin/objcopy" "$fake_bin/fake-command"
  for command_name in arch-chroot bootctl btrfs findmnt mount mountpoint snapper umount; do
    ln -s fake-command "$fake_bin/$command_name"
  done
  export PATH="$fake_bin:$PATH"
}

boot_tree_hash() {
  local path

  while IFS= read -r -d '' path; do
    printf '%s  %s\n' "$(sha256sum "$SPAWN_BOOT_ROOT/$path" | awk '{print $1}')" "$path"
  done < <(find "$SPAWN_BOOT_ROOT" -type f -printf '%P\0' | sort -z)
}

@test "successful rollback commits future default candidate UKI and pending state" {
  local old_current_hash new_current_hash

  old_current_hash="$(sha256sum "$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-current.efi" | awk '{print $1}')"
  run rollback_main latest

  [ "$status" -eq 0 ]
  new_current_hash="$(sha256sum "$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-current.efi" | awk '{print $1}')"
  [ "$new_current_hash" != "$old_current_hash" ]
  jq -e --arg old "$old_current_hash" --arg new "$new_current_hash" '
    .generation == 2 and .current.sha256 == $new and .current.blessed == false and
    .pending == {
      kind: "rollback",
      target_snapshot_id: 7394,
      new_default_subvolume_id: 812,
      previous_default_subvolume_id: 256,
      safety_snapshot_id: 7400,
      previous_current_sha256: $old,
      created_at: "2026-07-16T00:00:00Z"
    }
  ' "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json"
  [ ! -e "$SPAWN_BOOT_ROOT/loader/spawn-arch-transaction.json" ]
  grep -F 'bootctl:--esp-path=' "$SPAWN_COMMAND_LOG"
  grep -F 'set-default spawn-arch-current' "$SPAWN_COMMAND_LOG"
}

@test "booting last-good retains it instead of copying untrusted current" {
  local before after

  decode_hex_fixture "$REPO_ROOT/tests/fixtures/efi/loader-entry-last-good.bin" "$SPAWN_EFIVAR_PATH"
  before="$(sha256sum "$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-last-good.efi" | awk '{print $1}')"
  rollback_main 7394
  after="$(sha256sum "$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-last-good.efi" | awk '{print $1}')"

  [ "$after" = "$before" ]
}

@test "last-good recovery replaces a changed pending current without trusting its state hash" {
  local state before

  state="$(jq '.generation = 2 | .current.blessed = false | .pending = {
    kind: "pacman", pre_snapshot_id: 7394,
    previous_current_sha256: .current.sha256,
    packages: ["linux"], created_at: "2026-07-16T00:00:00Z"
  }' "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json")"
  jq -S . <<<"$state" >"$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json"
  printf 'untrusted-updated-current\n' >"$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-current.efi"
  decode_hex_fixture "$REPO_ROOT/tests/fixtures/efi/loader-entry-last-good.bin" "$SPAWN_EFIVAR_PATH"
  before="$(sha256sum "$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-last-good.efi" | awk '{print $1}')"

  run rollback_main latest

  [ "$status" -eq 0 ]
  [ "$(sha256sum "$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-last-good.efi" | awk '{print $1}')" = "$before" ]
  jq -e '.generation == 3 and .pending.kind == "rollback" and .pending.target_snapshot_id == 7394' \
    "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json"
}

@test "every rollback boundary restores default UKIs state and private mounts" {
  local phase before after default_output
  local -a phases=(
    state_lock top_level_mount snapper_rollback future_default future_root_mount binds
    candidate_mkinitcpio uki_validation last_good_preservation current_replacement state_commit
  )

  for phase in "${phases[@]}"; do
    reset_fixture
    before="$(boot_tree_hash)"
    export SPAWN_TEST_FAIL_PHASE="$phase"
    run rollback_main 7394
    [ "$status" -ne 0 ]
    unset SPAWN_TEST_FAIL_PHASE
    after="$(boot_tree_hash)"
    [ "$after" = "$before" ]
    default_output="$(btrfs subvolume get-default /)"
    [[ "$default_output" == 'ID 256 '* ]]
    [ ! -e "$SPAWN_BOOT_ROOT/loader/spawn-arch-transaction.json" ]
    [ -z "$(find "$SPAWN_ROLLBACK_MOUNT_ROOT" -maxdepth 1 -type d -name 'spawn-arch-rollback.*' -print -quit)" ]
    if [[ -e "$BATS_TEST_TMPDIR/snapper-rolled" ]]; then
      grep -Fx 'snapper:-c root delete 7402' "$SPAWN_COMMAND_LOG"
      grep -Fx 'snapper:-c root delete 7400' "$SPAWN_COMMAND_LOG"
    fi
  done
}

@test "durable operation journal restores an interrupted cross-device commit" {
  local current staged old_hash new_hash state new_state transaction operation before_ids

  current="$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-current.efi"
  staged="$SPAWN_BOOT_ROOT/EFI/Linux/.spawn-arch-current.efi.new-power"
  old_hash="$(sha256sum "$current" | awk '{print $1}')"
  printf 'candidate-after-power-loss\n' >"$staged"
  new_hash="$(sha256sum "$staged" | awk '{print $1}')"
  state="$(<"$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json")"
  new_state="$(jq --arg hash "$new_hash" --arg old "$old_hash" '
    .generation = 2 | .current.sha256 = $hash | .current.blessed = false |
    .pending = {
      kind: "rollback", target_snapshot_id: 7394,
      new_default_subvolume_id: 812, previous_default_subvolume_id: 256,
      safety_snapshot_id: 7400, previous_current_sha256: $old,
      created_at: "2026-07-16T00:00:00Z"
    }
  ' <<<"$state")"
  transaction="$(jq -n --arg old "$old_hash" --arg new "$new_hash" --argjson state "$new_state" '{
    schema_version: 1,
    operation_id: "00000000-0000-4000-8000-000000000003",
    kind: "rollback",
    base_generation: 1,
    phase: "prepared",
    old_btrfs_default: 256,
    artifacts: [{
      temp_basename: ".spawn-arch-current.efi.new-power",
      final_basename: "spawn-arch-current.efi",
      previous_basename: ".spawn-arch-current.efi.previous-power",
      old_sha256: $old,
      new_sha256: $new
    }],
    new_state: $state
  }')"
  boot_transaction_begin "$transaction"
  export SPAWN_TEST_FAIL_PHASE=after_artifact_rename
  run boot_transaction_recover
  [ "$status" -ne 0 ]
  unset SPAWN_TEST_FAIL_PHASE
  [ "$(sha256sum "$current" | awk '{print $1}')" = "$new_hash" ]

  before_ids="$(jq -c '[.root[].number] | sort | unique' "$FAKE_SNAPPER_BEFORE")"
  operation="$(jq -n --argjson before "$before_ids" '{
    schema_version: 1,
    operation_id: "00000000-0000-4000-8000-000000000003",
    phase: "snapper_applied",
    target_snapshot_id: 7394,
    base_generation: 1,
    old_btrfs_default: 256,
    old_loader_default: "spawn-arch-current",
    root_source: "/dev/mapper/cryptroot",
    before_snapshot_ids: $before,
    created_snapshot_ids: [7400, 7402],
    new_default_subvolume_id: 812
  }')"
  _rollback_operation_write "$operation"
  touch "$BATS_TEST_TMPDIR/snapper-rolled"

  rollback_recover

  [ "$(sha256sum "$current" | awk '{print $1}')" = "$old_hash" ]
  jq -e '.generation == 1 and .pending == null' "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json"
  [ ! -e "$SPAWN_BOOT_ROOT/loader/spawn-arch-transaction.json" ]
  [ ! -e "$SPAWN_BOOT_ROOT/loader/spawn-arch-rollback.json" ]
  [[ "$(btrfs subvolume get-default /)" == 'ID 256 '* ]]
  grep -Fx 'snapper:-c root delete 7402' "$SPAWN_COMMAND_LOG"
  grep -Fx 'snapper:-c root delete 7400' "$SPAWN_COMMAND_LOG"
}

@test "operation journal rejects control characters in the root source" {
  local operation

  operation="$(jq -n --arg root $'/dev/mapper/cryptroot\nforged' '{
    schema_version: 1,
    operation_id: "00000000-0000-4000-8000-000000000004",
    phase: "prepared",
    target_snapshot_id: 7394,
    base_generation: 1,
    old_btrfs_default: 256,
    old_loader_default: "spawn-arch-current",
    root_source: $root,
    before_snapshot_ids: [0, 7394],
    created_snapshot_ids: [],
    new_default_subvolume_id: null
  }')"

  run _rollback_operation_validate "$operation"

  [ "$status" -ne 0 ]
}
