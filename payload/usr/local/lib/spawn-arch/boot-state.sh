#!/usr/bin/env bash

_boot_test_pause_checkpoint() {
  local phase="$1"
  local requested="${SPAWN_TEST_PAUSE_PHASE:-}"
  local exchange_root marker root_real parent temporary

  [[ -n "$requested" && "$requested" == "$phase" ]] || return 0
  case "$phase" in
    state_temp | last_good_temp | current_candidate | post_snapper_pre_state_commit) ;;
    *) return 65 ;;
  esac
  exchange_root="${SPAWN_TEST_EXCHANGE_ROOT:-/run/spawn-exchange}"
  marker="${SPAWN_TEST_PAUSE_MARKER:-}"
  root_real="$(readlink -f -- "$exchange_root" 2>/dev/null)" || return 65
  parent="$(readlink -f -- "$(dirname -- "$marker")" 2>/dev/null)" || return 65
  [[ -d "$root_real" && "$parent" == "$root_real" && "$(basename -- "$marker")" =~ ^[A-Za-z0-9._-]+$ ]] || return 65
  temporary="$(mktemp "$root_real/.checkpoint.XXXXXX")" || return $?
  chmod 0600 -- "$temporary"
  printf '%s\n' "$phase" >"$temporary" || return $?
  sync -f -- "$temporary" || return $?
  mv -f -- "$temporary" "$marker" || return $?
  sync -f -- "$marker" || return $?
  kill -STOP "$BASHPID"
}

_spawn_boot_state_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if ! declare -F atomic_replace_same_directory >/dev/null 2>&1; then
  # shellcheck source=payload/usr/local/lib/spawn-arch/common.sh
  source "$_spawn_boot_state_dir/common.sh"
fi

_boot_root() {
  printf '%s\n' "${SPAWN_BOOT_ROOT:-/boot}"
}

_boot_loader_dir() {
  printf '%s/loader\n' "$(_boot_root)"
}

_boot_efi_linux_dir() {
  printf '%s/EFI/Linux\n' "$(_boot_root)"
}

_boot_state_path() {
  printf '%s/spawn-arch-state.json\n' "$(_boot_loader_dir)"
}

_boot_transaction_path() {
  printf '%s/spawn-arch-transaction.json\n' "$(_boot_loader_dir)"
}

_boot_runtime_dir() {
  printf '%s\n' "${SPAWN_INSTALLED_RUNTIME_DIR:-/run/spawn-arch}"
}

_boot_prepare_directories() {
  install -d -m 0700 -- "$(_boot_runtime_dir)" || return $?
  install -d -m 0700 -- "$(_boot_loader_dir)" || return $?
  install -d -m 0700 -- "$(_boot_efi_linux_dir)"
}

boot_state_validate() {
  local state_json="$1"

  jq -e '
    def hash: type == "string" and test("^[0-9a-f]{64}$");
    def exact_keys($keys): (keys_unsorted | sort) == ($keys | sort);
    def positive_integer: type == "number" and floor == . and . >= 1;
    def timestamp: type == "string" and
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    def pacman_pending:
      type == "object" and
      exact_keys(["kind", "pre_snapshot_id", "previous_current_sha256", "packages", "created_at"]) and
      .kind == "pacman" and (.pre_snapshot_id | positive_integer) and
      (.previous_current_sha256 | hash) and
      (.packages | type == "array" and length >= 1 and
        all(.[]; type == "string" and test("^[a-z0-9@._+:-]+$")) and
        (unique | length) == length) and
      (.created_at | timestamp);
    def rollback_pending:
      type == "object" and
      exact_keys(["kind", "target_snapshot_id", "new_default_subvolume_id", "previous_default_subvolume_id", "safety_snapshot_id", "previous_current_sha256", "created_at"]) and
      .kind == "rollback" and
      all(.target_snapshot_id, .new_default_subvolume_id, .previous_default_subvolume_id, .safety_snapshot_id; positive_integer) and
      (.previous_current_sha256 | hash) and (.created_at | timestamp);
    type == "object" and
    exact_keys(["schema_version", "generation", "current", "last_good", "pending", "seed"]) and
    .schema_version == 1 and
    (.generation | type == "number" and floor == . and . >= 1) and
    (.current | type == "object" and
      exact_keys(["entry", "sha256", "blessed"]) and
      .entry == "spawn-arch-current" and (.sha256 | hash) and
      (.blessed | type == "boolean")) and
    (.last_good | type == "object" and
      exact_keys(["entry", "sha256"]) and
      .entry == "spawn-arch-last-good" and (.sha256 | hash)) and
    (.pending == null or (.pending | (pacman_pending or rollback_pending))) and
    (.seed | type == "object" and
      exact_keys(["subvolume_id", "retired", "safety_snapshot_id"]) and
      (.subvolume_id | type == "number" and floor == . and . >= 1) and
      (.retired | type == "boolean") and
      (.safety_snapshot_id == null or
        (.safety_snapshot_id | type == "number" and floor == . and . >= 1)))
  ' <<<"$state_json" >/dev/null
}

_json_write_durable() {
  local destination="$1"
  local json="$2"
  local temporary

  temporary="$(mktemp "$(dirname -- "$destination")/.spawn-arch-json.XXXXXX")" || return $?
  chmod 0600 -- "$temporary" || return $?
  if ! jq -S . <<<"$json" >"$temporary"; then
    rm -f -- "$temporary"
    return 65
  fi
  atomic_replace_same_directory "$temporary" "$destination"
}

_boot_state_write_locked() {
  local state_json="$1"
  local state_path previous_path temporary current_generation new_generation

  boot_state_validate "$state_json" || {
    die "boot state does not match schema v1" 65
    return $?
  }
  state_path="$(_boot_state_path)"
  previous_path="$state_path.previous"
  new_generation="$(jq -r '.generation' <<<"$state_json")" || return $?

  if [[ -e "$state_path" ]]; then
    if ! boot_state_validate "$(<"$state_path")"; then
      die "refusing to replace invalid primary boot state" 65
      return $?
    fi
    current_generation="$(jq -r '.generation' "$state_path")" || return $?
    if ((new_generation <= current_generation)); then
      die "boot state generation must increase monotonically" 65
      return $?
    fi
    temporary="$(mktemp "$(_boot_loader_dir)/.spawn-arch-state.previous.XXXXXX")" || return $?
    cp -- "$state_path" "$temporary" || return $?
    chmod 0600 -- "$temporary" || return $?
    atomic_replace_same_directory "$temporary" "$previous_path" || return $?
  fi

  temporary="$(mktemp "$(_boot_loader_dir)/.spawn-arch-state.new.XXXXXX")" || return $?
  chmod 0600 -- "$temporary" || return $?
  jq -S . <<<"$state_json" >"$temporary" || return $?
  boot_state_validate "$(<"$temporary")" || return 65
  sync -f -- "$temporary" || return $?
  _boot_test_pause_checkpoint state_temp || return $?
  if [[ "${SPAWN_TEST_FAIL_PHASE:-}" == before_state_rename ]]; then
    rm -f -- "$temporary"
    return 75
  fi
  atomic_replace_same_directory "$temporary" "$state_path" || return $?
  boot_state_validate "$(<"$state_path")"
}

boot_state_write() {
  local state_json="$1"
  local lock_path status

  _boot_prepare_directories || return $?
  lock_path="$(_boot_runtime_dir)/boot-state.lock"
  exec {boot_state_lock_fd}>"$lock_path" || return $?
  flock -x "$boot_state_lock_fd" || return $?
  _boot_state_write_locked "$state_json"
  status=$?
  flock -u "$boot_state_lock_fd" || true
  exec {boot_state_lock_fd}>&-
  return "$status"
}

boot_state_read() {
  local state_path previous_path temporary

  _boot_prepare_directories || return $?
  state_path="$(_boot_state_path)"
  previous_path="$state_path.previous"
  if [[ -r "$state_path" ]] && boot_state_validate "$(<"$state_path")"; then
    jq -S . "$state_path"
    return
  fi
  if [[ ! -r "$previous_path" ]] || ! boot_state_validate "$(<"$previous_path")"; then
    die "boot state and recovery copy are invalid" 65
    return $?
  fi
  log_warn "recovering invalid boot state from .previous"
  temporary="$(mktemp "$(_boot_loader_dir)/.spawn-arch-state.recover.XXXXXX")" || return $?
  cp -- "$previous_path" "$temporary" || return $?
  chmod 0600 -- "$temporary" || return $?
  atomic_replace_same_directory "$temporary" "$state_path" || return $?
  jq -S . "$state_path"
}

boot_transaction_validate() {
  local transaction_json="$1"

  jq -e '
    def hash: type == "string" and test("^[0-9a-f]{64}$");
    def basename: type == "string" and length > 0 and
      . != "." and . != ".." and (contains("/") | not);
    type == "object" and
    .schema_version == 1 and
    (.operation_id | type == "string" and
      test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")) and
    (.kind == "initialize" or .kind == "preserve" or .kind == "rollback") and
    (.base_generation | type == "number" and floor == . and . >= 0) and
    (.phase == "prepared" or .phase == "artifacts_committed" or .phase == "state_committed") and
    (.old_btrfs_default == null or
      (.old_btrfs_default | type == "number" and floor == . and . >= 1)) and
    (.artifacts | type == "array" and length >= 1 and all(.[];
      (.temp_basename | basename) and (.final_basename | basename) and
      (.previous_basename | basename) and
      (.old_sha256 == null or (.old_sha256 | hash)) and (.new_sha256 | hash)))
  ' <<<"$transaction_json" >/dev/null || return 65
  boot_state_validate "$(jq -c '.new_state' <<<"$transaction_json")"
}

_boot_transaction_begin_locked() {
  local transaction_json="$1"
  local transaction_path base_generation state_path artifact temp_path final_path old_hash new_hash actual_hash

  _boot_prepare_directories || return $?
  boot_transaction_validate "$transaction_json" || {
    die "boot transaction does not match schema v1" 65
    return $?
  }
  transaction_path="$(_boot_transaction_path)"
  if [[ -e "$transaction_path" ]]; then
    die "a boot transaction is already active" 75
    return $?
  fi
  base_generation="$(jq -r '.base_generation' <<<"$transaction_json")" || return $?
  state_path="$(_boot_state_path)"
  if ((base_generation == 0)); then
    [[ ! -e "$state_path" ]] || return 75
  else
    [[ -r "$state_path" ]] || return 75
    boot_state_validate "$(<"$state_path")" || return 75
    [[ "$(jq -r '.generation' "$state_path")" == "$base_generation" ]] || return 75
  fi
  while IFS= read -r artifact; do
    temp_path="$(_boot_efi_linux_dir)/$(jq -r '.temp_basename' <<<"$artifact")"
    final_path="$(_boot_efi_linux_dir)/$(jq -r '.final_basename' <<<"$artifact")"
    old_hash="$(jq -r '.old_sha256 // empty' <<<"$artifact")"
    new_hash="$(jq -r '.new_sha256' <<<"$artifact")"
    [[ -f "$temp_path" && "$(sha256_file "$temp_path")" == "$new_hash" ]] || return 75
    if [[ -n "$old_hash" ]]; then
      [[ -f "$final_path" ]] || return 75
      actual_hash="$(sha256_file "$final_path")" || return $?
      [[ "$actual_hash" == "$old_hash" ]] || return 75
    else
      [[ ! -e "$final_path" ]] || return 75
    fi
  done < <(jq -c '.artifacts[]' <<<"$transaction_json")
  _json_write_durable "$transaction_path" "$transaction_json"
}

boot_transaction_begin() {
  local transaction_json="$1"
  local lock_path status

  _boot_prepare_directories || return $?
  lock_path="$(_boot_runtime_dir)/boot-state.lock"
  exec {boot_begin_lock_fd}>"$lock_path" || return $?
  flock -x "$boot_begin_lock_fd" || return $?
  _boot_transaction_begin_locked "$transaction_json"
  status=$?
  flock -u "$boot_begin_lock_fd" || true
  exec {boot_begin_lock_fd}>&-
  return "$status"
}

_transaction_set_phase() {
  local transaction_path="$1"
  local phase="$2"
  local transaction_json

  transaction_json="$(jq --arg phase "$phase" '.phase = $phase' "$transaction_path")" || return $?
  _json_write_durable "$transaction_path" "$transaction_json"
}

_transaction_commit_artifact() {
  local artifact_json="$1"
  local efi_dir temp_path final_path previous_path old_hash new_hash actual_hash temporary

  efi_dir="$(_boot_efi_linux_dir)"
  temp_path="$efi_dir/$(jq -r '.temp_basename' <<<"$artifact_json")"
  final_path="$efi_dir/$(jq -r '.final_basename' <<<"$artifact_json")"
  previous_path="$efi_dir/$(jq -r '.previous_basename' <<<"$artifact_json")"
  old_hash="$(jq -r '.old_sha256 // empty' <<<"$artifact_json")"
  new_hash="$(jq -r '.new_sha256' <<<"$artifact_json")"

  if [[ -f "$final_path" ]]; then
    actual_hash="$(sha256_file "$final_path")" || return $?
    if [[ "$actual_hash" == "$new_hash" ]]; then
      rm -f -- "$temp_path"
      return 0
    fi
  else
    actual_hash=""
  fi
  if [[ ! -f "$temp_path" ]] || [[ "$(sha256_file "$temp_path")" != "$new_hash" ]]; then
    die "boot transaction has no valid staged artifact" 65
    return $?
  fi
  if [[ -n "$old_hash" ]]; then
    [[ "$actual_hash" == "$old_hash" ]] || {
      die "boot artifact does not match transaction base hash" 65
      return $?
    }
    temporary="$(mktemp "$efi_dir/.spawn-arch-artifact.previous.XXXXXX")" || return $?
    cp -- "$final_path" "$temporary" || return $?
    chmod 0600 -- "$temporary" || return $?
    atomic_replace_same_directory "$temporary" "$previous_path" || return $?
  elif [[ -e "$final_path" ]]; then
    die "unexpected pre-existing boot artifact" 65
    return $?
  fi
  atomic_replace_same_directory "$temp_path" "$final_path" || return $?
  [[ "$(sha256_file "$final_path")" == "$new_hash" ]]
}

_boot_state_matches_new_state() {
  local expected_json="$1"
  local actual expected

  [[ -r "$(_boot_state_path)" ]] || return 1
  boot_state_validate "$(<"$(_boot_state_path)")" || return 1
  actual="$(jq -S -c . "$(_boot_state_path)")" || return $?
  expected="$(jq -S -c . <<<"$expected_json")" || return $?
  [[ "$actual" == "$expected" ]]
}

_boot_transaction_finish_locked() {
  local transaction_json artifact_json efi_dir previous_basename new_hash final_basename
  local transaction_path

  transaction_path="$(_boot_transaction_path)"
  transaction_json="$(<"$transaction_path")"
  while IFS= read -r artifact_json; do
    efi_dir="$(_boot_efi_linux_dir)"
    final_basename="$(jq -r '.final_basename' <<<"$artifact_json")"
    previous_basename="$(jq -r '.previous_basename' <<<"$artifact_json")"
    new_hash="$(jq -r '.new_sha256' <<<"$artifact_json")"
    [[ -f "$efi_dir/$final_basename" && "$(sha256_file "$efi_dir/$final_basename")" == "$new_hash" ]] || return 65
    rm -f -- "$efi_dir/$previous_basename"
  done < <(jq -c '.artifacts[]' <<<"$transaction_json")
  _boot_state_matches_new_state "$(jq -c '.new_state' <<<"$transaction_json")" || return 65
  rm -f -- "$transaction_path"
  sync -f -- "$(_boot_loader_dir)"
  sync -f -- "$(_boot_efi_linux_dir)"
}

boot_transaction_finish() {
  [[ -r "$(_boot_transaction_path)" ]] || return 0
  _boot_transaction_finish_locked
}

_boot_transaction_recover_locked() {
  local transaction_path transaction_json artifact_json new_state
  local current_generation new_generation status

  transaction_path="$(_boot_transaction_path)"
  [[ -r "$transaction_path" ]] || return 0
  transaction_json="$(<"$transaction_path")"
  if ! boot_transaction_validate "$transaction_json"; then
    status=65
  else
    status=0
    while IFS= read -r artifact_json; do
      _transaction_commit_artifact "$artifact_json" || {
        status=$?
        break
      }
    done < <(jq -c '.artifacts[]' <<<"$transaction_json")
    if ((status == 0)); then
      _transaction_set_phase "$transaction_path" artifacts_committed || status=$?
    fi
    if ((status == 0)) && [[ "${SPAWN_TEST_FAIL_PHASE:-}" == after_artifact_rename ]]; then
      status=75
    fi
    if ((status == 0)); then
      new_state="$(jq -c '.new_state' <<<"$transaction_json")" || status=$?
    fi
    if ((status == 0)) && ! _boot_state_matches_new_state "$new_state"; then
      new_generation="$(jq -r '.generation' <<<"$new_state")" || status=$?
      current_generation=0
      if [[ -r "$(_boot_state_path)" ]] && boot_state_validate "$(<"$(_boot_state_path)")"; then
        current_generation="$(jq -r '.generation' "$(_boot_state_path)")" || status=$?
      fi
      if ((status == 0 && new_generation <= current_generation)); then
        status=65
      elif ((status == 0)); then
        _boot_state_write_locked "$new_state" || status=$?
      fi
    fi
    if ((status == 0)); then
      _transaction_set_phase "$transaction_path" state_committed || status=$?
    fi
    if ((status == 0)); then
      _boot_transaction_finish_locked || status=$?
    fi
  fi

  return "$status"
}

boot_transaction_recover() {
  local lock_path status

  _boot_prepare_directories || return $?
  [[ -r "$(_boot_transaction_path)" ]] || return 0
  lock_path="$(_boot_runtime_dir)/boot-state.lock"
  exec {boot_transaction_lock_fd}>"$lock_path" || return $?
  flock -x "$boot_transaction_lock_fd" || return $?
  _boot_transaction_recover_locked
  status=$?
  flock -u "$boot_transaction_lock_fd" || true
  exec {boot_transaction_lock_fd}>&-
  return "$status"
}

_boot_transaction_abort_locked() {
  local transaction_path transaction_json artifact_json efi_dir
  local temp_path final_path previous_path old_hash new_hash actual_hash
  local state_path state_previous base_generation new_generation actual_generation temporary

  transaction_path="$(_boot_transaction_path)"
  [[ -r "$transaction_path" ]] || return 0
  transaction_json="$(<"$transaction_path")"
  boot_transaction_validate "$transaction_json" || return 65
  efi_dir="$(_boot_efi_linux_dir)"
  while IFS= read -r artifact_json; do
    temp_path="$efi_dir/$(jq -r '.temp_basename' <<<"$artifact_json")"
    final_path="$efi_dir/$(jq -r '.final_basename' <<<"$artifact_json")"
    previous_path="$efi_dir/$(jq -r '.previous_basename' <<<"$artifact_json")"
    old_hash="$(jq -r '.old_sha256 // empty' <<<"$artifact_json")"
    new_hash="$(jq -r '.new_sha256' <<<"$artifact_json")"
    actual_hash=""
    [[ ! -f "$final_path" ]] || actual_hash="$(sha256_file "$final_path")"

    if [[ -n "$old_hash" ]]; then
      if [[ "$actual_hash" == "$new_hash" || -z "$actual_hash" ]]; then
        [[ -f "$previous_path" && "$(sha256_file "$previous_path")" == "$old_hash" ]] || return 65
        atomic_replace_same_directory "$previous_path" "$final_path" || return $?
      elif [[ "$actual_hash" != "$old_hash" ]]; then
        return 65
      fi
      [[ "$(sha256_file "$final_path")" == "$old_hash" ]] || return 65
    else
      if [[ "$actual_hash" == "$new_hash" ]]; then
        rm -f -- "$final_path" || return $?
      elif [[ -n "$actual_hash" ]]; then
        return 65
      fi
    fi
    rm -f -- "$temp_path" "$previous_path"
  done < <(jq -c '.artifacts[]' <<<"$transaction_json")

  state_path="$(_boot_state_path)"
  state_previous="$state_path.previous"
  base_generation="$(jq -r '.base_generation' <<<"$transaction_json")"
  new_generation="$(jq -r '.new_state.generation' <<<"$transaction_json")"
  actual_generation=0
  if [[ -r "$state_path" ]] && boot_state_validate "$(<"$state_path")"; then
    actual_generation="$(jq -r '.generation' "$state_path")"
  fi
  if ((actual_generation == new_generation)); then
    if ((base_generation == 0)); then
      rm -f -- "$state_path"
    else
      [[ -r "$state_previous" ]] || return 65
      boot_state_validate "$(<"$state_previous")" || return 65
      [[ "$(jq -r '.generation' "$state_previous")" == "$base_generation" ]] || return 65
      temporary="$(mktemp "$(_boot_loader_dir)/.spawn-arch-state.abort.XXXXXX")" || return $?
      cp -- "$state_previous" "$temporary" || return $?
      chmod 0600 -- "$temporary" || return $?
      atomic_replace_same_directory "$temporary" "$state_path" || return $?
    fi
  elif ((actual_generation != base_generation)); then
    return 65
  fi
  if ((base_generation > 0)); then
    boot_state_validate "$(<"$state_path")" || return 65
    [[ "$(jq -r '.generation' "$state_path")" == "$base_generation" ]] || return 65
  fi
  rm -f -- "$state_previous" "$transaction_path"
  sync -f -- "$(_boot_loader_dir)"
  sync -f -- "$efi_dir"
}

boot_transaction_abort() {
  local lock_path status

  _boot_prepare_directories || return $?
  [[ -r "$(_boot_transaction_path)" ]] || return 0
  lock_path="$(_boot_runtime_dir)/boot-state.lock"
  exec {boot_abort_lock_fd}>"$lock_path" || return $?
  flock -x "$boot_abort_lock_fd" || return $?
  _boot_transaction_abort_locked
  status=$?
  flock -u "$boot_abort_lock_fd" || true
  exec {boot_abort_lock_fd}>&-
  return "$status"
}

boot_initialize() (
  local target_root="$1"
  local seed_id="$2"
  local expected_cmdline="$3"
  local current_path last_good_path staged_path current_hash last_good_hash old_hash
  local existing_state base_generation new_generation operation_id transaction state

  [[ "$seed_id" =~ ^[1-9][0-9]*$ ]] || return 65
  export SPAWN_BOOT_ROOT="$target_root/boot"
  export SPAWN_ETC_ROOT="$target_root/etc"
  export SPAWN_INSTALLED_RUNTIME_DIR="$target_root/run/spawn-arch"
  # shellcheck source=payload/usr/local/lib/spawn-arch/uki.sh
  source "$_spawn_boot_state_dir/uki.sh"
  _boot_prepare_directories || return $?
  boot_transaction_recover || return $?

  current_path="$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-current.efi"
  last_good_path="$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-last-good.efi"
  uki_validate "$current_path" "$expected_cmdline" current false || return $?
  current_hash="$(sha256_file "$current_path")" || return $?

  if [[ -r "$(_boot_state_path)" ]]; then
    existing_state="$(boot_state_read)" || return $?
    base_generation="$(jq -r '.generation' <<<"$existing_state")" || return $?
    if [[ -s "$last_good_path" ]]; then
      last_good_hash="$(sha256_file "$last_good_path")" || return $?
      if jq -e \
        --arg current "$current_hash" \
        --arg last_good "$last_good_hash" \
        --argjson seed "$seed_id" '
          .current.sha256 == $current and .current.blessed == true and
          .last_good.sha256 == $last_good and .pending == null and
          .seed == {subvolume_id: $seed, retired: false, safety_snapshot_id: null}
        ' >/dev/null <<<"$existing_state" &&
        uki_validate "$last_good_path" "$expected_cmdline" last-good false; then
        return 0
      fi
    fi
  else
    existing_state=""
    base_generation=0
  fi

  staged_path="$(uki_prepare_last_good "$current_path" "$last_good_path" "$expected_cmdline")" || return $?
  last_good_hash="$(sha256_file "$staged_path")" || return $?
  old_hash=""
  if [[ -s "$last_good_path" ]]; then
    old_hash="$(sha256_file "$last_good_path")" || return $?
  fi
  new_generation=$((base_generation + 1))
  state="$(jq -n \
    --arg current "$current_hash" \
    --arg last_good "$last_good_hash" \
    --argjson generation "$new_generation" \
    --argjson seed "$seed_id" '{
      schema_version: 1,
      generation: $generation,
      current: {entry: "spawn-arch-current", sha256: $current, blessed: true},
      last_good: {entry: "spawn-arch-last-good", sha256: $last_good},
      pending: null,
      seed: {subvolume_id: $seed, retired: false, safety_snapshot_id: null}
    }')" || return $?
  operation_id="$(</proc/sys/kernel/random/uuid)" || return $?
  transaction="$(jq -n \
    --arg operation_id "$operation_id" \
    --argjson base_generation "$base_generation" \
    --arg temp_basename "$(basename -- "$staged_path")" \
    --arg final_basename "$(basename -- "$last_good_path")" \
    --arg previous_basename ".spawn-arch-last-good.efi.previous-$operation_id" \
    --arg old_sha256 "$old_hash" \
    --arg new_sha256 "$last_good_hash" \
    --argjson new_state "$state" '{
      schema_version: 1,
      operation_id: $operation_id,
      kind: "initialize",
      base_generation: $base_generation,
      phase: "prepared",
      old_btrfs_default: null,
      artifacts: [{
        temp_basename: $temp_basename,
        final_basename: $final_basename,
        previous_basename: $previous_basename,
        old_sha256: (if $old_sha256 == "" then null else $old_sha256 end),
        new_sha256: $new_sha256
      }],
      new_state: $new_state
    }')" || return $?
  boot_transaction_begin "$transaction" || return $?
  boot_transaction_recover || return $?
  uki_validate "$last_good_path" "$expected_cmdline" last-good false || return $?
  _boot_state_matches_new_state "$state"
)
