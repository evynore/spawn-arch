#!/usr/bin/env bash

if ! declare -F die >/dev/null 2>&1; then
  _spawn_runtime_module_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  # shellcheck source=lib/spawn-arch/common.sh
  source "$_spawn_runtime_module_dir/common.sh"
  unset _spawn_runtime_module_dir
fi

SPAWN_RUNTIME_DIR="${SPAWN_RUNTIME_DIR:-/run/spawn-arch}"
SPAWN_STATE_PATH="$SPAWN_RUNTIME_DIR/install-state.json"
SPAWN_LOCK_PATH="$SPAWN_RUNTIME_DIR/install.lock"
SPAWN_MOUNT_JOURNAL="$SPAWN_RUNTIME_DIR/mounts.journal"
declare -ag SPAWN_CREDENTIAL_PATHS=()
SPAWN_RUNTIME_CHILD_PID=""
SPAWN_RUNTIME_TRAPS_INSTALLED=false

_runtime_traps_install() {
  if [[ "${SPAWN_RUNTIME_DISABLE_TRAPS:-false}" == true ]] || [[ "$SPAWN_RUNTIME_TRAPS_INSTALLED" == true ]]; then
    return 0
  fi
  trap '_runtime_exit_handler "$?"' EXIT
  trap '_runtime_signal_handler INT 130' INT
  trap '_runtime_signal_handler TERM 143' TERM
  SPAWN_RUNTIME_TRAPS_INSTALLED=true
}

runtime_init() {
  (
    umask 077
    install -d -m 0700 -- "$SPAWN_RUNTIME_DIR" || return $?
    chmod 0700 -- "$SPAWN_RUNTIME_DIR" || return $?
    if [[ ! -e "$SPAWN_LOCK_PATH" ]]; then
      install -m 0600 /dev/null "$SPAWN_LOCK_PATH" || return $?
    fi
    chmod 0600 -- "$SPAWN_LOCK_PATH" || return $?
  ) || return $?
  _runtime_traps_install
}

_state_write_json() {
  local state_json="$1"
  local temporary

  temporary="$(mktemp "$SPAWN_STATE_PATH.tmp.XXXXXX")" || return $?
  chmod 0600 -- "$temporary"
  if ! printf '%s\n' "$state_json" >"$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  atomic_replace "$temporary" "$SPAWN_STATE_PATH"
}

state_create() {
  local plan_sha256="$1"
  local now state_json lock_fd

  if [[ ! "$plan_sha256" =~ ^[0-9a-f]+$ ]]; then
    die "plan hash must be lowercase hexadecimal" 65
    return $?
  fi
  runtime_init || return $?
  exec {lock_fd}<>"$SPAWN_LOCK_PATH" || return $?
  flock -x "$lock_fd" || return $?
  if [[ -e "$SPAWN_STATE_PATH" ]]; then
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    die "install state already exists" 65
    return $?
  fi

  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ! state_json="$(jq -n \
    --arg plan_sha256 "$plan_sha256" \
    --arg now "$now" '
      {
        schema_version: 1,
        plan_sha256: $plan_sha256,
        phase: "planned",
        failed_from: null,
        last_completed_phase: "planned",
        created_at: $now,
        updated_at: $now
      }
    ')"; then
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    return 1
  fi
  _state_write_json "$state_json"
  local status=$?
  flock -u "$lock_fd"
  exec {lock_fd}>&-
  return "$status"
}

_transition_allowed() {
  local expected="$1"
  local next="$2"

  case "$expected:$next" in
    planned:confirmed | confirmed:materialized | materialized:archinstall_running | \
      archinstall_running:archinstall_complete | archinstall_complete:finalizing | \
      finalizing:verified | verified:complete)
      return 0
      ;;
    *:failed)
      [[ "$expected" != complete && "$expected" != failed ]]
      ;;
    *)
      return 1
      ;;
  esac
}

state_transition() {
  local expected_phase="$1"
  local next_phase="$2"
  local lock_fd state current_phase now updated status

  if [[ ! -r "$SPAWN_STATE_PATH" ]]; then
    die "install state does not exist" 65
    return $?
  fi
  exec {lock_fd}<>"$SPAWN_LOCK_PATH" || return $?
  flock -x "$lock_fd" || return $?
  if ! state="$(<"$SPAWN_STATE_PATH")" || ! current_phase="$(jq -r '.phase' <<<"$state")"; then
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    return 1
  fi

  if [[ "$current_phase" != "$expected_phase" ]]; then
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    die "stale state transition: expected $expected_phase, found $current_phase" 65
    return $?
  fi
  if ! _transition_allowed "$expected_phase" "$next_phase"; then
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    die "invalid state transition: $expected_phase -> $next_phase" 65
    return $?
  fi

  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ! updated="$(jq -c \
    --arg expected "$expected_phase" \
    --arg next "$next_phase" \
    --arg now "$now" '
      .phase = $next
      | .updated_at = $now
      | if $next == "failed" then
          .failed_from = $expected
        else
          .failed_from = null
        end
      | if (["planned", "confirmed", "materialized", "archinstall_complete", "verified", "complete"] | index($next)) then
          .last_completed_phase = $next
        else
          .
        end
    ' <<<"$state")"; then
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    return 1
  fi
  _state_write_json "$updated"
  status=$?
  flock -u "$lock_fd"
  exec {lock_fd}>&-
  return "$status"
}

state_resume_finalizing() {
  local lock_fd state phase last_completed now updated status

  if [[ ! -r "$SPAWN_STATE_PATH" ]]; then
    die "install state does not exist" 65
    return $?
  fi
  exec {lock_fd}<>"$SPAWN_LOCK_PATH" || return $?
  flock -x "$lock_fd" || return $?
  state="$(<"$SPAWN_STATE_PATH")"
  phase="$(jq -r '.phase' <<<"$state")" || return $?
  last_completed="$(jq -r '.last_completed_phase' <<<"$state")" || return $?
  if [[ "$phase" != archinstall_complete && ! ("$phase" == failed && "$last_completed" == archinstall_complete) ]]; then
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    die "state is not eligible for finalizer-only resumption" 65
    return $?
  fi

  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ! updated="$(jq -c --arg now "$now" '
    .phase = "finalizing"
    | .failed_from = null
    | .updated_at = $now
    | .resume_count = ((.resume_count // 0) + 1)
  ' <<<"$state")"; then
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    return 1
  fi
  _state_write_json "$updated"
  status=$?
  flock -u "$lock_fd"
  exec {lock_fd}>&-
  return "$status"
}

mount_journal_register() {
  local mount_path="$1"
  local canonical lock_fd

  canonical="$(readlink -f -- "$mount_path" 2>/dev/null || true)"
  if [[ -z "$canonical" || ! -d "$canonical" || "$canonical" == *$'\n'* ]]; then
    die "invalid mount journal path" 65
    return $?
  fi
  exec {lock_fd}<>"$SPAWN_LOCK_PATH" || return $?
  flock -x "$lock_fd" || return $?
  if [[ ! -e "$SPAWN_MOUNT_JOURNAL" ]]; then
    install -m 0600 /dev/null "$SPAWN_MOUNT_JOURNAL" || return $?
  fi
  if ! grep -Fxq -- "$canonical" "$SPAWN_MOUNT_JOURNAL"; then
    printf '%s\n' "$canonical" >>"$SPAWN_MOUNT_JOURNAL" || return $?
    sync -f "$SPAWN_MOUNT_JOURNAL"
  fi
  flock -u "$lock_fd"
  exec {lock_fd}>&-
}

mount_journal_cleanup() {
  local mount_path status=0
  local index
  local -a mounts=()

  [[ -r "$SPAWN_MOUNT_JOURNAL" ]] || return 0
  mapfile -t mounts <"$SPAWN_MOUNT_JOURNAL"
  for ((index = ${#mounts[@]} - 1; index >= 0; index--)); do
    mount_path="${mounts[index]}"
    [[ -n "$mount_path" ]] || continue
    if mountpoint -q -- "$mount_path"; then
      umount -- "$mount_path" || status=$?
    fi
  done
  if ((status == 0)); then
    rm -f -- "$SPAWN_MOUNT_JOURNAL"
  fi
  return "$status"
}

credentials_register() {
  local credential_path="$1"
  local runtime_real credential_real mode owner registered

  runtime_real="$(readlink -f -- "$SPAWN_RUNTIME_DIR" 2>/dev/null || true)"
  credential_real="$(readlink -f -- "$credential_path" 2>/dev/null || true)"
  if [[ -z "$runtime_real" || -z "$credential_real" || "$credential_real" != "$runtime_real"/* || ! -f "$credential_real" ]]; then
    die "credential path must be a regular file beneath the runtime directory" 65
    return $?
  fi
  mode="$(stat -c %a -- "$credential_real")" || return $?
  owner="$(stat -c %u -- "$credential_real")" || return $?
  if [[ "$mode" != 600 || "$owner" != "$EUID" ]]; then
    die "credential file must be owned by the caller with mode 0600" 65
    return $?
  fi

  for registered in "${SPAWN_CREDENTIAL_PATHS[@]}"; do
    [[ "$registered" != "$credential_real" ]] || return 0
  done
  SPAWN_CREDENTIAL_PATHS+=("$credential_real")
}

credentials_destroy() {
  local credential_path
  local status=0

  for credential_path in "${SPAWN_CREDENTIAL_PATHS[@]}"; do
    rm -f -- "$credential_path" || status=$?
  done
  SPAWN_CREDENTIAL_PATHS=()
  return "$status"
}

runtime_track_child() {
  local child_pid="$1"

  if [[ ! "$child_pid" =~ ^[0-9]+$ ]]; then
    die "cannot track invalid child process" 65
    return $?
  fi
  SPAWN_RUNTIME_CHILD_PID="$child_pid"
}

runtime_clear_child() {
  SPAWN_RUNTIME_CHILD_PID=""
}

_runtime_terminate_child() {
  local attempt

  [[ -n "$SPAWN_RUNTIME_CHILD_PID" ]] || return 0
  if kill -0 "$SPAWN_RUNTIME_CHILD_PID" 2>/dev/null; then
    kill -TERM "$SPAWN_RUNTIME_CHILD_PID" 2>/dev/null || true
    for ((attempt = 0; attempt < 50; attempt++)); do
      kill -0 "$SPAWN_RUNTIME_CHILD_PID" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$SPAWN_RUNTIME_CHILD_PID" 2>/dev/null; then
      kill -KILL "$SPAWN_RUNTIME_CHILD_PID" 2>/dev/null || true
    fi
    wait "$SPAWN_RUNTIME_CHILD_PID" 2>/dev/null || true
  fi
  SPAWN_RUNTIME_CHILD_PID=""
}

_runtime_mark_failed() {
  local phase

  [[ -r "$SPAWN_STATE_PATH" ]] || return 0
  phase="$(jq -r '.phase' "$SPAWN_STATE_PATH" 2>/dev/null || true)"
  [[ -n "$phase" && "$phase" != complete && "$phase" != failed ]] || return 0
  state_transition "$phase" failed >/dev/null 2>&1 || true
}

_runtime_exit_handler() {
  local status="$1"

  trap - EXIT INT TERM
  if ((status != 0)); then
    _runtime_terminate_child
    _runtime_mark_failed
  fi
  mount_journal_cleanup || true
  credentials_destroy
  exit "$status"
}

_runtime_signal_handler() {
  local signal_name="$1"
  local status="$2"

  trap - EXIT INT TERM
  _runtime_terminate_child
  _runtime_mark_failed
  mount_journal_cleanup || true
  credentials_destroy
  log_warn "received $signal_name; installer state marked failed"
  exit "$status"
}
