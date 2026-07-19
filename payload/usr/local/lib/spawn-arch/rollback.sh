#!/usr/bin/env bash

_spawn_rollback_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=payload/usr/local/lib/spawn-arch/boot-state.sh
source "$_spawn_rollback_dir/boot-state.sh"
# shellcheck source=payload/usr/local/lib/spawn-arch/uki.sh
source "$_spawn_rollback_dir/uki.sh"
# shellcheck source=payload/usr/local/lib/spawn-arch/snapshots.sh
source "$_spawn_rollback_dir/snapshots.sh"

_rollback_checkpoint() {
  [[ "${SPAWN_TEST_FAIL_PHASE:-}" != "$1" ]] || return 75
}

_rollback_operation_path() {
  printf '%s/spawn-arch-rollback.json\n' "$(_boot_loader_dir)"
}

_rollback_operation_validate() {
  local operation="$1"

  jq -e '
    def positive: type == "number" and floor == . and . >= 1;
    type == "object" and
    (keys_unsorted | sort) == ([
      "schema_version", "operation_id", "phase", "target_snapshot_id", "base_generation",
      "old_btrfs_default", "old_loader_default", "root_source", "before_snapshot_ids",
      "created_snapshot_ids", "new_default_subvolume_id"
    ] | sort) and
    .schema_version == 1 and
    (.operation_id | type == "string" and
      test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")) and
    (.phase == "prepared" or .phase == "snapper_applied" or .phase == "boot_state_committed") and
    (.target_snapshot_id | positive) and (.base_generation | positive) and
    (.old_btrfs_default | positive) and
    (.old_loader_default | type == "string" and test("^[A-Za-z0-9._*+-]+$") and length <= 128) and
    (.root_source | type == "string" and startswith("/dev/") and (test("[\\r\\n]") | not)) and
    (.before_snapshot_ids | type == "array" and all(.[]; type == "number" and floor == . and . >= 0) and
      (unique | length) == length) and
    (.created_snapshot_ids | type == "array" and all(.[]; positive) and (unique | length) == length) and
    (.new_default_subvolume_id == null or (.new_default_subvolume_id | positive))
  ' >/dev/null <<<"$operation"
}

_rollback_operation_write() {
  local operation="$1"

  _rollback_operation_validate "$operation" || return 65
  _json_write_durable "$(_rollback_operation_path)" "$operation"
}

_rollback_operation_begin() {
  local target="$1"
  local state="$2"
  local root_source="$3"
  local before_snapshots="$4"
  local operation

  [[ ! -e "$(_rollback_operation_path)" ]] || return 75
  operation="$(jq -n \
    --arg operation_id "$_rollback_operation_id" --argjson target "$target" \
    --argjson generation "$(jq -r '.generation' <<<"$state")" \
    --argjson old_default "$_rollback_old_default" \
    --arg old_loader "$_rollback_old_loader_default" --arg root_source "$root_source" \
    --argjson before_ids "$(jq -c '[.root[].number] | sort | unique' <<<"$before_snapshots")" '{
      schema_version: 1,
      operation_id: $operation_id,
      phase: "prepared",
      target_snapshot_id: $target,
      base_generation: $generation,
      old_btrfs_default: $old_default,
      old_loader_default: $old_loader,
      root_source: $root_source,
      before_snapshot_ids: $before_ids,
      created_snapshot_ids: [],
      new_default_subvolume_id: null
    }')" || return $?
  _rollback_operation_write "$operation"
}

_rollback_operation_record_snapper() {
  local created_ids="$1"
  local new_default="$2"
  local operation

  operation="$(jq --argjson ids "$created_ids" --argjson default "$new_default" '
    .phase = "snapper_applied" |
    .created_snapshot_ids = $ids |
    .new_default_subvolume_id = $default
  ' "$(_rollback_operation_path)")" || return $?
  _rollback_operation_write "$operation"
}

_rollback_operation_mark_boot_state() {
  local operation

  operation="$(jq '.phase = "boot_state_committed"' "$(_rollback_operation_path)")" || return $?
  _rollback_operation_write "$operation"
}

_rollback_operation_remove() {
  rm -f -- "$(_rollback_operation_path)"
  sync -f -- "$(_boot_loader_dir)"
}

_rollback_default_id() {
  local path="$1"
  local output id

  output="$(btrfs subvolume get-default "$path")" || return $?
  id="$(awk '$1 == "ID" {print $2; exit}' <<<"$output")"
  [[ "$id" =~ ^[1-9][0-9]*$ ]] || return 65
  printf '%s\n' "$id"
}

_rollback_register_mount() {
  _rollback_mounts+=("$1")
}

_rollback_cleanup_mounts() {
  local index path status=0

  for ((index = ${#_rollback_mounts[@]} - 1; index >= 0; index--)); do
    path="${_rollback_mounts[$index]}"
    umount -- "$path" || status=$?
  done
  _rollback_mounts=()
  if [[ -n "${_rollback_work_dir:-}" && -d "$_rollback_work_dir" ]]; then
    find "$_rollback_work_dir" -depth -type d -empty -delete || status=$?
  fi
  return "$status"
}

_rollback_identify_created() {
  local before="$1"
  local after="$2"

  jq -e -n --argjson before "$before" --argjson after "$after" '
    ([ $before.root[].number ]) as $old_ids |
    ([ $after.root[] | select((.number as $id | $old_ids | index($id)) == null) ]) as $created |
    ([ $created[] | select(.["read-only"] == true and .number > 0) ]) as $safety |
    ([ $created[] | select(.default == true and .["read-only"] == false and .number > 0) ]) as $future |
    select(($safety | length) == 1 and ($future | length) == 1) |
    {
      ids: ($created | map(.number) | sort),
      safety_snapshot_id: $safety[0].number,
      default_snapshot_id: $future[0].number
    }
  '
}

_rollback_identify_created_from_ids() {
  local before_ids="$1"
  local after="$2"

  jq -e -n --argjson old_ids "$before_ids" --argjson after "$after" '
    ([ $after.root[] | select((.number as $id | $old_ids | index($id)) == null) ]) as $created |
    if ($created | length) == 0 then
      {ids: [], safety_snapshot_id: null, default_snapshot_id: null}
    else
      ([ $created[] | select(.["read-only"] == true and .number > 0) ]) as $safety |
      ([ $created[] | select(.default == true and .["read-only"] == false and .number > 0) ]) as $future |
      select(($safety | length) == 1 and ($future | length) == 1) |
      {
        ids: ($created | map(.number) | sort),
        safety_snapshot_id: $safety[0].number,
        default_snapshot_id: $future[0].number
      }
    end
  '
}

_rollback_mount_future_root() {
  local root_source="$1"
  local new_default_id="$2"
  local future_root="$3"
  local pkgbase module_dir
  local -a kernel_candidates=()

  mount -t btrfs -o "subvolid=$new_default_id" -- "$root_source" "$future_root" || return $?
  _rollback_register_mount "$future_root"
  _rollback_checkpoint future_root_mount || return $?
  mount -t tmpfs -o mode=0700,nodev,nosuid,noexec tmpfs "$future_root/boot" || return $?
  _rollback_register_mount "$future_root/boot"

  while IFS= read -r -d '' pkgbase; do
    [[ "$(<"$pkgbase")" == linux ]] || continue
    module_dir="$(dirname -- "$pkgbase")"
    [[ -f "$module_dir/vmlinuz" ]] || continue
    kernel_candidates+=("$module_dir/vmlinuz")
  done < <(find "$future_root/usr/lib/modules" -mindepth 2 -maxdepth 2 -type f -name pkgbase -print0)
  ((${#kernel_candidates[@]} == 1)) || return 65
  install -D -m 0600 -- "${kernel_candidates[0]}" "$future_root/boot/vmlinuz-linux" || return $?

  mount --rbind /dev "$future_root/dev" || return $?
  _rollback_register_mount "$future_root/dev"
  mount --make-rslave "$future_root/dev" || return $?
  mount -t proc -o nosuid,nodev,noexec proc "$future_root/proc" || return $?
  _rollback_register_mount "$future_root/proc"
  mount --rbind /sys "$future_root/sys" || return $?
  _rollback_register_mount "$future_root/sys"
  mount --make-rslave "$future_root/sys" || return $?
  mount --rbind /run "$future_root/run" || return $?
  _rollback_register_mount "$future_root/run"
  mount --make-rslave "$future_root/run" || return $?
  _rollback_checkpoint binds
}

_rollback_stage_current() {
  local candidate="$1"
  local expected_cmdline="$2"
  local efi_dir staged

  efi_dir="$(_boot_efi_linux_dir)"
  staged="$(mktemp "$efi_dir/.spawn-arch-current.efi.new.XXXXXX")" || return $?
  cp -- "$candidate" "$staged" || return $?
  chmod 0600 -- "$staged" || return $?
  sync -f -- "$staged" || return $?
  uki_validate "$staged" "$expected_cmdline" current false || {
    rm -f -- "$staged"
    return 65
  }
  printf '%s\n' "$staged"
}

_rollback_build_transaction() {
  local state="$1"
  local target_snapshot_id="$2"
  local new_default_id="$3"
  local safety_snapshot_id="$4"
  local staged_current="$5"
  local staged_last_good="$6"
  local actual_current_hash="$7"
  local current_hash last_good_hash old_current_hash old_last_good_hash created_at artifacts new_state

  current_hash="$(sha256_file "$staged_current")" || return $?
  old_current_hash="$actual_current_hash"
  old_last_good_hash="$(jq -r '.last_good.sha256' <<<"$state")" || return $?
  last_good_hash="$old_last_good_hash"
  artifacts="$(jq -n \
    --arg temp "$(basename -- "$staged_current")" \
    --arg previous ".spawn-arch-current.efi.previous-$_rollback_operation_id" \
    --arg old "$old_current_hash" --arg new "$current_hash" '[{
      temp_basename: $temp,
      final_basename: "spawn-arch-current.efi",
      previous_basename: $previous,
      old_sha256: $old,
      new_sha256: $new
    }]')" || return $?
  if [[ -n "$staged_last_good" ]]; then
    last_good_hash="$(sha256_file "$staged_last_good")" || return $?
    artifacts="$(jq \
      --arg temp "$(basename -- "$staged_last_good")" \
      --arg previous ".spawn-arch-last-good.efi.previous-$_rollback_operation_id" \
      --arg old "$old_last_good_hash" --arg new "$last_good_hash" '. + [{
        temp_basename: $temp,
        final_basename: "spawn-arch-last-good.efi",
        previous_basename: $previous,
        old_sha256: $old,
        new_sha256: $new
      }]' <<<"$artifacts")" || return $?
  fi
  created_at="${SPAWN_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  new_state="$(jq \
    --arg current "$current_hash" --arg last_good "$last_good_hash" \
    --arg previous_current "$old_current_hash" --arg created_at "$created_at" \
    --argjson target "$target_snapshot_id" --argjson new_default "$new_default_id" \
    --argjson previous_default "$_rollback_old_default" --argjson safety "$safety_snapshot_id" '
      .generation += 1 |
      .current.sha256 = $current |
      .current.blessed = false |
      .last_good.sha256 = $last_good |
      .pending = {
        kind: "rollback",
        target_snapshot_id: $target,
        new_default_subvolume_id: $new_default,
        previous_default_subvolume_id: $previous_default,
        safety_snapshot_id: $safety,
        previous_current_sha256: $previous_current,
        created_at: $created_at
      }
    ' <<<"$state")" || return $?
  jq -n \
    --arg operation_id "$_rollback_operation_id" \
    --argjson base_generation "$(jq -r '.generation' <<<"$state")" \
    --argjson old_default "$_rollback_old_default" \
    --argjson artifacts "$artifacts" --argjson new_state "$new_state" '{
      schema_version: 1,
      operation_id: $operation_id,
      kind: "rollback",
      base_generation: $base_generation,
      phase: "prepared",
      old_btrfs_default: $old_default,
      artifacts: $artifacts,
      new_state: $new_state
    }'
}

_rollback_commit_boot_locked() {
  local transaction="$1"
  local artifact new_state

  _boot_transaction_begin_locked "$transaction" || return $?
  while IFS= read -r artifact; do
    _transaction_commit_artifact "$artifact" || return $?
  done < <(jq -c '.artifacts[]' <<<"$transaction")
  _transaction_set_phase "$(_boot_transaction_path)" artifacts_committed || return $?
  _rollback_checkpoint current_replacement || return $?
  new_state="$(jq -c '.new_state' <<<"$transaction")" || return $?
  _boot_state_write_locked "$new_state" || return $?
  _transaction_set_phase "$(_boot_transaction_path)" state_committed || return $?
  _rollback_checkpoint state_commit
}

_rollback_validate_mounts() {
  mountpoint -q / || return 65
  mountpoint -q /.snapshots || return 65
  mountpoint -q "$(_boot_root)" || return 65
  [[ "$(findmnt -n -o FSTYPE --target /)" == btrfs ]] || return 65
  [[ "$(findmnt -n -o FSTYPE --target /.snapshots)" == btrfs ]]
}

_rollback_execute_locked() {
  local requested="$1"
  local state target root_source before_snapshots after_snapshots created selected expected_cmdline
  local future_root candidate staged_current staged_last_good="" transaction artifact list current_hash last_good_hash

  _rollback_checkpoint state_lock || return $?
  [[ ! -e "$(_boot_transaction_path)" ]] || return 75
  _rollback_validate_mounts || return $?
  state="$(boot_state_read)" || return $?
  target="$(snapshots_resolve "$requested" "$state")" || return $?
  root_source="$(findmnt -n -o SOURCE --target /)" || return $?
  root_source="${root_source%%\[*}"
  [[ "$root_source" == /dev/* ]] || return 65
  before_snapshots="$(snapshots_read_raw)" || return $?
  _rollback_old_default="$(_rollback_default_id /)" || return $?
  _rollback_old_loader_default="$(bootctl --esp-path="$(_boot_root)" get-default)" || return $?
  _rollback_operation_begin "$target" "$state" "$root_source" "$before_snapshots" || return $?
  _rollback_operation_started=true

  install -d -m 0700 -- "${SPAWN_ROLLBACK_MOUNT_ROOT:-/mnt}" || return $?
  _rollback_work_dir="$(mktemp -d "${SPAWN_ROLLBACK_MOUNT_ROOT:-/mnt}/spawn-arch-rollback.XXXXXX")" || return $?
  _rollback_top_level="$_rollback_work_dir/top"
  future_root="$_rollback_work_dir/future"
  install -d -m 0700 -- "$_rollback_top_level" "$future_root" || return $?
  mount -t btrfs -o subvolid=5 -- "$root_source" "$_rollback_top_level" || return $?
  _rollback_register_mount "$_rollback_top_level"
  _rollback_checkpoint top_level_mount || return $?

  _rollback_default_changed=true
  snapper -c root rollback "$target" >/dev/null || return $?
  _rollback_snapper_changed=true
  after_snapshots="$(snapshots_read_raw)" || return $?
  created="$(_rollback_identify_created "$before_snapshots" "$after_snapshots")" || return $?
  _rollback_created_snapshot_ids="$(jq -c '.ids' <<<"$created")"
  _rollback_safety_snapshot_id="$(jq -r '.safety_snapshot_id' <<<"$created")"
  _rollback_checkpoint snapper_rollback || return $?

  _rollback_new_default="$(_rollback_default_id "$_rollback_top_level")" || return $?
  [[ "$_rollback_new_default" != "$_rollback_old_default" ]] || return 65
  _rollback_operation_record_snapper "$_rollback_created_snapshot_ids" "$_rollback_new_default" || return $?
  _rollback_checkpoint future_default || return $?
  _boot_test_pause_checkpoint post_snapper_pre_state_commit || return $?
  _rollback_mount_future_root "$root_source" "$_rollback_new_default" "$future_root" || return $?
  arch-chroot "$future_root" mkinitcpio -p linux || return $?
  _rollback_checkpoint candidate_mkinitcpio || return $?

  expected_cmdline="$(<"$(installed_etc_root)/kernel/cmdline")" || return $?
  [[ "$(<"$future_root/etc/kernel/cmdline")" == "$expected_cmdline" ]] || return 65
  candidate="$future_root/boot/EFI/Linux/spawn-arch-current.efi"
  uki_validate "$candidate" "$expected_cmdline" current false || return $?
  staged_current="$(_rollback_stage_current "$candidate" "$expected_cmdline")" || return $?
  _rollback_staged_paths+=("$staged_current")
  _boot_test_pause_checkpoint current_candidate || return $?
  _rollback_checkpoint uki_validation || return $?

  current_hash="$(sha256_file "$(_boot_efi_linux_dir)/spawn-arch-current.efi")" || return $?
  last_good_hash="$(sha256_file "$(_boot_efi_linux_dir)/spawn-arch-last-good.efi")" || return $?
  [[ "$last_good_hash" == "$(jq -r '.last_good.sha256' <<<"$state")" ]] || return 75
  uki_validate "$(_boot_efi_linux_dir)/spawn-arch-last-good.efi" "$expected_cmdline" last-good || return $?
  selected="$(boot_selected_entry)" || return $?
  if [[ "$selected" == spawn-arch-current && "$(jq -r '.current.blessed' <<<"$state")" == true ]]; then
    [[ "$current_hash" == "$(jq -r '.current.sha256' <<<"$state")" ]] || return 75
    uki_validate "$(_boot_efi_linux_dir)/spawn-arch-current.efi" "$expected_cmdline" current || return $?
    staged_last_good="$(uki_prepare_last_good \
      "$(_boot_efi_linux_dir)/spawn-arch-current.efi" \
      "$(_boot_efi_linux_dir)/spawn-arch-last-good.efi" "$expected_cmdline")" || return $?
    _rollback_staged_paths+=("$staged_last_good")
  elif [[ "$selected" != spawn-arch-current && "$selected" != spawn-arch-last-good ]]; then
    return 75
  fi
  _rollback_checkpoint last_good_preservation || return $?

  transaction="$(_rollback_build_transaction "$state" "$target" "$_rollback_new_default" \
    "$_rollback_safety_snapshot_id" "$staged_current" "$staged_last_good" "$current_hash")" || return $?
  _rollback_commit_boot_locked "$transaction" || return $?
  _rollback_boot_changed=true
  _rollback_operation_mark_boot_state || return $?
  _rollback_loader_changed=true
  bootctl --esp-path="$(_boot_root)" set-default spawn-arch-current || return $?
  list="$(bootctl --esp-path="$(_boot_root)" list)" || return $?
  grep -Fq spawn-arch-current.efi <<<"$list" || return 65
  grep -Fq spawn-arch-last-good.efi <<<"$list" || return 65
  [[ "$(_rollback_default_id "$_rollback_top_level")" == "$_rollback_new_default" ]] || return 65
  _boot_state_matches_new_state "$(jq -c '.new_state' <<<"$transaction")" || return 65
  while IFS= read -r artifact; do
    [[ "$(sha256_file "$(_boot_efi_linux_dir)/$(jq -r '.final_basename' <<<"$artifact")")" == "$(jq -r '.new_sha256' <<<"$artifact")" ]] || return 65
  done < <(jq -c '.artifacts[]' <<<"$transaction")
  _rollback_operation_remove || return $?
  _rollback_operation_started=false
  _boot_transaction_finish_locked || return $?
  _rollback_committed=true
  jq -n --argjson target "$target" --argjson default "$_rollback_new_default" \
    --argjson safety "$_rollback_safety_snapshot_id" \
    '{ok: true, target_snapshot_id: $target, new_default_subvolume_id: $default, safety_snapshot_id: $safety}'
}

_rollback_restore_locked() {
  local status=0 id

  if [[ "$_rollback_default_changed" == true && -n "$_rollback_top_level" ]]; then
    btrfs subvolume set-default "$_rollback_old_default" "$_rollback_top_level" || status=$?
    if ((status == 0)) && [[ "$(_rollback_default_id "$_rollback_top_level")" != "$_rollback_old_default" ]]; then status=70; fi
  fi
  if [[ "$_rollback_loader_changed" == true ]]; then
    bootctl --esp-path="$(_boot_root)" set-default "$_rollback_old_loader_default" || status=$?
  fi
  if [[ -e "$(_boot_transaction_path)" ]]; then
    _boot_transaction_abort_locked || status=$?
  fi
  for id in "${_rollback_staged_paths[@]}"; do rm -f -- "$id"; done
  _rollback_cleanup_mounts || status=$?
  if ((status == 0)) && [[ "$_rollback_snapper_changed" == true ]]; then
    while IFS= read -r id; do
      snapper -c root delete "$id" || status=$?
    done < <(jq -r 'reverse[]' <<<"$_rollback_created_snapshot_ids")
  fi
  if ((status == 0)) && [[ "$_rollback_operation_started" == true ]]; then
    _rollback_operation_remove || status=$?
    _rollback_operation_started=false
  fi
  return "$status"
}

_rollback_recover_operation_locked() {
  local operation state generation root_source old_default old_loader before_ids created current_snapshots identified
  local recovery_root top_level status=0 id

  operation="$(<"$(_rollback_operation_path)")"
  _rollback_operation_validate "$operation" || return 65
  generation="$(jq -r '.base_generation' <<<"$operation")"
  root_source="$(jq -r '.root_source' <<<"$operation")"
  old_default="$(jq -r '.old_btrfs_default' <<<"$operation")"
  old_loader="$(jq -r '.old_loader_default' <<<"$operation")"
  before_ids="$(jq -c '.before_snapshot_ids' <<<"$operation")"
  created="$(jq -c '.created_snapshot_ids' <<<"$operation")"

  install -d -m 0700 -- "${SPAWN_ROLLBACK_MOUNT_ROOT:-/mnt}" || return $?
  recovery_root="$(mktemp -d "${SPAWN_ROLLBACK_MOUNT_ROOT:-/mnt}/spawn-arch-recover.XXXXXX")" || return $?
  top_level="$recovery_root/top"
  install -d -m 0700 -- "$top_level" || return $?
  if ! mount -t btrfs -o subvolid=5 -- "$root_source" "$top_level"; then
    rmdir -- "$top_level" "$recovery_root"
    return 70
  fi
  btrfs subvolume set-default "$old_default" "$top_level" || status=$?
  if ((status == 0)) && [[ "$(_rollback_default_id "$top_level")" != "$old_default" ]]; then status=70; fi
  if ((status == 0)); then bootctl --esp-path="$(_boot_root)" set-default "$old_loader" || status=$?; fi
  if ((status == 0)) && [[ -e "$(_boot_transaction_path)" ]]; then
    _boot_transaction_abort_locked || status=$?
  fi
  if ((status == 0)); then
    state="$(boot_state_read)" || status=$?
  fi
  if ((status == 0)) && [[ "$(jq -r '.generation' <<<"$state")" != "$generation" ]]; then status=70; fi
  umount -- "$top_level" || status=$?
  rmdir -- "$top_level" "$recovery_root" || status=$?

  if ((status == 0)); then
    current_snapshots="$(snapshots_read_raw)" || status=$?
  fi
  if ((status == 0)); then
    identified="$(_rollback_identify_created_from_ids "$before_ids" "$current_snapshots")" || status=$?
  fi
  if ((status == 0)) && [[ "$created" != '[]' ]]; then
    jq -e --argjson recorded "$created" '
      all(.ids[]; . as $id | $recorded | index($id) != null)
    ' >/dev/null <<<"$identified" || status=70
  fi
  if ((status == 0)); then
    created="$(jq -c '.ids' <<<"$identified")"
    while IFS= read -r id; do
      snapper -c root delete "$id" || status=$?
    done < <(jq -r 'reverse[]' <<<"$created")
  fi
  if ((status == 0)); then _rollback_operation_remove || status=$?; fi
  return "$status"
}

rollback_recover() {
  local lock_path status=0

  _boot_prepare_directories || return $?
  [[ -e "$(_rollback_operation_path)" || -e "$(_boot_transaction_path)" ]] || return 0
  lock_path="$(_boot_runtime_dir)/boot-state.lock"
  exec {rollback_recovery_lock_fd}>"$lock_path" || return $?
  flock -x "$rollback_recovery_lock_fd" || return $?
  if [[ -e "$(_rollback_operation_path)" ]]; then
    _rollback_recover_operation_locked || status=$?
  elif [[ -e "$(_boot_transaction_path)" ]]; then
    _boot_transaction_recover_locked || status=$?
  fi
  flock -u "$rollback_recovery_lock_fd" || true
  exec {rollback_recovery_lock_fd}>&-
  return "$status"
}

rollback_main() {
  local requested="${1:-}"
  local lock_path status output output_path restore_status=0

  [[ "$requested" == latest || "$requested" =~ ^[1-9][0-9]*$ ]] || return 64
  _boot_prepare_directories || return $?
  _rollback_operation_id="$(</proc/sys/kernel/random/uuid)" || return $?
  _rollback_work_dir=""
  _rollback_top_level=""
  _rollback_old_default=""
  _rollback_new_default=""
  _rollback_safety_snapshot_id=""
  _rollback_old_loader_default=""
  _rollback_created_snapshot_ids='[]'
  _rollback_snapper_changed=false
  _rollback_default_changed=false
  _rollback_boot_changed=false
  _rollback_loader_changed=false
  _rollback_committed=false
  _rollback_operation_started=false
  _rollback_mounts=()
  _rollback_staged_paths=()

  lock_path="$(_boot_runtime_dir)/boot-state.lock"
  exec {rollback_lock_fd}>"$lock_path" || return $?
  flock -x "$rollback_lock_fd" || return $?
  output_path="$(mktemp "$(_boot_runtime_dir)/rollback-output.XXXXXX")" || return $?
  if _rollback_execute_locked "$requested" >"$output_path"; then
    status=0
  else
    status=$?
  fi
  output="$(<"$output_path")"
  rm -f -- "$output_path"
  if ((status == 0)); then
    _rollback_cleanup_mounts || status=$?
  else
    _rollback_restore_locked || restore_status=$?
  fi
  flock -u "$rollback_lock_fd" || true
  exec {rollback_lock_fd}>&-

  if ((restore_status != 0)); then
    die "rollback failed and restoration is incomplete; boot the Arch ISO and inspect $(_boot_transaction_path)" 70
    return $?
  fi
  ((status == 0)) || return "$status"
  printf '%s\n' "$output"
}
