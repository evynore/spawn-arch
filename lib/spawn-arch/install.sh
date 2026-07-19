#!/usr/bin/env bash

_spawn_install_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

_load_install_dependency() {
  local function_name="$1"
  local module="$2"

  if ! declare -F "$function_name" >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$_spawn_install_dir/$module.sh"
  fi
}

_load_install_dependency die common
_load_install_dependency doctor_assert_installable preflight
_load_install_dependency disk_inventory_json disk
_load_install_dependency partition_geometry_json geometry
_load_install_dependency prompt_value_into prompt
_load_install_dependency runtime_init runtime-state
_load_install_dependency archinstall_user_config archinstall-config
_load_install_dependency target_storage_json target-storage

source_commit_resolve() {
  local source_root="$1"
  local source_file="$source_root/SOURCE_COMMIT"
  local commit head status
  local -a lines=()

  if [[ -r "$source_file" ]]; then
    mapfile -t lines <"$source_file"
    if ((${#lines[@]} != 1)) || [[ ! "${lines[0]}" =~ ^[0-9a-f]{40}$ ]]; then
      die "SOURCE_COMMIT must contain exactly one lowercase 40-hex commit" 65
      return $?
    fi
    commit="${lines[0]}"

    if git -C "$source_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      head="$(git -C "$source_root" rev-parse HEAD)" || return $?
      if [[ "$head" != "$commit" ]]; then
        die "SOURCE_COMMIT does not match repository HEAD" 65
        return $?
      fi
      status="$(git -C "$source_root" status --porcelain --untracked-files=normal)" || return $?
      if [[ -n "$status" ]]; then
        die "source repository is dirty" 65
        return $?
      fi
    fi
  else
    if ! git -C "$source_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      die "source provenance is unavailable" 65
      return $?
    fi
    status="$(git -C "$source_root" status --porcelain --untracked-files=normal)" || return $?
    if [[ -n "$status" ]]; then
      die "source repository is dirty" 65
      return $?
    fi
    commit="$(git -C "$source_root" rev-parse HEAD)" || return $?
  fi

  if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
    die "resolved source commit is not lowercase 40-hex" 65
    return $?
  fi
  printf '%s\n' "$commit"
}

_select_plan_disk() {
  local eligible_json="$1"
  local selection="${SPAWN_DISK_SELECTION:-}"
  local count index

  count="$(jq 'length' <<<"$eligible_json")" || return $?
  if ((count == 0)); then
    die "no eligible target disks were found" 65
    return $?
  fi

  jq -r 'to_entries[] | "\(.key + 1)) \(.value.device)  \(.value.model // "unknown")  serial=\(.value.identity.serial)"' \
    <<<"$eligible_json" >&2
  if [[ -z "$selection" ]]; then
    printf 'Select target disk [1-%s]: ' "$count" >&2
    if ! IFS= read -r selection <"${SPAWN_TTY_PATH:-/dev/tty}"; then
      die "disk selection was not received" 65
      return $?
    fi
  fi
  if [[ ! "$selection" =~ ^[0-9]+$ ]] || ((selection < 1 || selection > count)); then
    die "invalid disk selection: $selection" 65
    return $?
  fi
  index=$((selection - 1))
  jq -c --argjson index "$index" '.[$index]' <<<"$eligible_json"
}

_profile_value() {
  local output_name="$1"
  local environment_value="$2"
  local label="$3"
  local default_value="$4"

  if [[ -n "$environment_value" ]]; then
    printf -v "$output_name" '%s' "$environment_value"
  else
    prompt_value_into "$output_name" "$label" "$default_value"
  fi
}

cmd_plan() {
  local inventory eligible selected identity geometry archinstall_version source_commit created_at
  local hostname username timezone keymap locale source_root plan_path plan_dir temporary_plan live_source
  local materialized_plan user_config dry_run_credentials dry_luks_fd dry_user_fd dry_run_status

  doctor_assert_installable || return $?
  inventory="${SPAWN_INVENTORY_JSON:-}"
  [[ -n "$inventory" ]] || inventory="$(disk_inventory_json)" || return $?
  live_source="${SPAWN_LIVE_SOURCE:-$(findmnt -n -o SOURCE --target /run/archiso/bootmnt 2>/dev/null || true)}"
  eligible="$(eligible_disks_json "$inventory" "$live_source")" || return $?
  selected="$(_select_plan_disk "$eligible")" || return $?
  identity="$(jq -c '.identity' <<<"$selected")" || return $?

  _profile_value hostname "${SPAWN_HOSTNAME:-}" Hostname spawn || return $?
  _profile_value username "${SPAWN_USERNAME:-}" Username evynore || return $?
  _profile_value timezone "${SPAWN_TIMEZONE:-}" Timezone Etc/UTC || return $?
  _profile_value keymap "${SPAWN_KEYMAP:-}" Keymap us || return $?
  _profile_value locale "${SPAWN_LOCALE:-}" Locale en_US.UTF-8 || return $?
  validate_hostname "$hostname" || return $?
  validate_username "$username" || return $?
  validate_timezone "$timezone" || return $?
  validate_keymap "$keymap" || return $?
  validate_locale "$locale" || return $?

  geometry="$(partition_geometry_json \
    "$(jq -r '.size_bytes' <<<"$identity")" \
    "$(jq -r '.logical_sector_bytes' <<<"$identity")")" || return $?
  archinstall_version="${SPAWN_ARCHINSTALL_VERSION:-$(_archinstall_version)}" || return $?
  assert_archinstall_version "$archinstall_version" || return $?
  source_root="${SPAWN_SOURCE_ROOT:-${REPO_ROOT:-$(cd -- "$_spawn_install_dir/../.." && pwd -P)}}"
  source_commit="$(source_commit_resolve "$source_root")" || return $?
  created_at="${SPAWN_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

  plan_path="${SPAWN_PLAN_PATH:-${SPAWN_RUNTIME_DIR:-/run/spawn-arch}/plan.json}"
  plan_dir="$(dirname -- "$plan_path")"
  install -d -m 0700 -- "$plan_dir" || return $?
  temporary_plan="$(mktemp "$plan_path.tmp.XXXXXX")" || return $?
  chmod 0600 -- "$temporary_plan"

  if ! jq -n \
    --arg created_at "$created_at" \
    --arg device "$(jq -r '.device' <<<"$selected")" \
    --argjson identity "$identity" \
    --argjson geometry "$geometry" \
    --arg hostname "$hostname" \
    --arg username "$username" \
    --arg timezone "$timezone" \
    --arg keymap "$keymap" \
    --arg locale "$locale" \
    --arg archinstall_version "$archinstall_version" \
    --arg source_commit "$source_commit" '
      {
        schema_version: 1,
        created_at: $created_at,
        target: {device_at_plan_time: $device, identity: $identity},
        storage: {
          geometry: $geometry,
          subvolumes: ["@", "@home", "@log", "@pkg", "@snapshots"]
        },
        system: {
          hostname: $hostname,
          username: $username,
          timezone: $timezone,
          keymap: $keymap,
          locale: $locale
        },
        archinstall: {
          version: $archinstall_version,
          schema_commit: "3ece182d31dda7b14abd56d13abf3ff79a5717ae"
        },
        source: {commit: $source_commit}
      }
    ' >"$temporary_plan"; then
    rm -f -- "$temporary_plan"
    return 1
  fi

  atomic_replace "$temporary_plan" "$plan_path" || return $?
  materialized_plan="$(<"$plan_path")"

  runtime_init || return $?
  user_config="$plan_dir/user_configuration.json"
  dry_run_credentials="$plan_dir/dry-run-credentials.json"
  archinstall_user_config "$materialized_plan" "$user_config" || return $?
  exec {dry_luks_fd}<<<'spawn-arch-dry-run-only'
  exec {dry_user_fd}<<<'spawn-arch-dry-run-only'
  if archinstall_credentials \
    "$materialized_plan" "$dry_run_credentials" "$dry_luks_fd" "$dry_user_fd"; then
    dry_run_status=0
  else
    dry_run_status=$?
    exec {dry_luks_fd}<&-
    exec {dry_user_fd}<&-
    credentials_destroy
    return "$dry_run_status"
  fi
  exec {dry_luks_fd}<&-
  exec {dry_user_fd}<&-
  if ! archinstall_validate_materialized "$user_config" "$dry_run_credentials"; then
    credentials_destroy
    return 65
  fi

  if archinstall \
    --config "$user_config" \
    --creds "$dry_run_credentials" \
    --silent \
    --dry-run; then
    dry_run_status=0
  else
    dry_run_status=$?
  fi
  credentials_destroy || return $?
  ((dry_run_status == 0)) || return "$dry_run_status"

  log_info "non-destructive plan written to $plan_path"
  jq -r '
    "Target: \(.target.device_at_plan_time) serial=\(.target.identity.serial)",
    "Profile: KDE Plasma, Intel default + NVIDIA offload",
    "Subvolumes: \(.storage.subvolumes | join(", "))"
  ' <<<"$materialized_plan" >&2
  jq -r '"Packages: \(.packages | length); services: \(.services | join(", "))"' "$user_config" >&2
}

_ensure_finalizer_ports() {
  if ! declare -F finalize_target >/dev/null 2>&1 || ! declare -F verify_target_offline >/dev/null 2>&1; then
    if [[ ! -r "$_spawn_install_dir/finalize.sh" ]]; then
      die "finalizer module is unavailable" 70
      return $?
    fi
    # shellcheck source=/dev/null
    source "$_spawn_install_dir/finalize.sh"
  fi
}

_install_with_target_umask() {
  local previous_umask status

  previous_umask="$(umask)" || return $?
  umask 0022
  if "$@"; then
    status=0
  else
    status=$?
  fi
  umask "$previous_umask" || return $?
  return "$status"
}

_assert_plan_source() {
  local plan_json="$1"
  local source_root expected actual

  source_root="${SPAWN_SOURCE_ROOT:-${REPO_ROOT:-$(cd -- "$_spawn_install_dir/../.." && pwd -P)}}"
  expected="$(jq -r '.source.commit' <<<"$plan_json")" || return $?
  actual="$(source_commit_resolve "$source_root")" || return $?
  if [[ "$expected" != "$actual" ]]; then
    die "plan provenance does not match the executing source" 65
    return $?
  fi
}

_target_fingerprint_json() {
  local plan_json="$1"
  local target_root="$2"
  local storage mount_source luks_device btrfs_uuid luks_uuid inventory resolved_disk

  storage="$(target_storage_json "$target_root")" || return $?
  mount_source="$(jq -r '.canonical_mount_source' <<<"$storage")" || return $?
  if [[ "$(blkid -s TYPE -o value -- "$mount_source")" != btrfs ]]; then
    die "planned target root is not Btrfs" 65
    return $?
  fi
  btrfs_uuid="$(blkid -s UUID -o value -- "$mount_source")" || return $?
  luks_device="$(jq -r '.luks_device' <<<"$storage")" || return $?
  luks_uuid="$(jq -r '.luks_uuid' <<<"$storage")" || return $?

  inventory="$(disk_inventory_json)" || return $?
  resolved_disk="$(resolve_disk_identity "$(jq -c '.target.identity' <<<"$plan_json")" "$inventory")" || return $?
  if ! jq -e --arg disk "$resolved_disk" --arg luks_device "$luks_device" '
    .disks[] | select(.path == $disk) | (.descendant_paths // []) | index($luks_device)
  ' >/dev/null <<<"$inventory"; then
    die "LUKS device is not a child of the planned disk" 65
    return $?
  fi

  jq -n \
    --argjson identity "$(jq -c '.target.identity' <<<"$plan_json")" \
    --arg mount_source "$mount_source" \
    --arg luks_device "$luks_device" \
    --arg luks_uuid "$luks_uuid" \
    --arg btrfs_uuid "$btrfs_uuid" \
    '{
      identity: $identity,
      mount_source: $mount_source,
      luks_device: $luks_device,
      luks_uuid: $luks_uuid,
      btrfs_uuid: $btrfs_uuid
    }'
}

target_fingerprint_record() {
  local plan_json="$1"
  local target_root="$2"
  local fingerprint temporary path="$SPAWN_RUNTIME_DIR/target-fingerprint.json"

  fingerprint="$(_target_fingerprint_json "$plan_json" "$target_root")" || return $?
  temporary="$(mktemp "$path.tmp.XXXXXX")" || return $?
  chmod 0600 -- "$temporary"
  printf '%s\n' "$fingerprint" >"$temporary" || return $?
  atomic_replace "$temporary" "$path"
}

assert_resume_target() {
  local plan_json="$1"
  local target_root="$2"
  local stored current path="$SPAWN_RUNTIME_DIR/target-fingerprint.json"

  if [[ ! -r "$path" ]]; then
    die "target fingerprint is unavailable for resume" 65
    return $?
  fi
  stored="$(<"$path")"
  if ! jq -e --argjson identity "$(jq -c '.target.identity' <<<"$plan_json")" \
    '.identity == $identity' >/dev/null <<<"$stored"; then
    die "stored target identity differs from the plan" 65
    return $?
  fi
  current="$(_target_fingerprint_json "$plan_json" "$target_root")" || return $?
  if ! jq -e --argjson current "$current" '
    .identity == $current.identity and
    .mount_source == $current.mount_source and
    .luks_device == $current.luks_device and
    .luks_uuid == $current.luks_uuid and
    .btrfs_uuid == $current.btrfs_uuid
  ' >/dev/null <<<"$stored"; then
    die "mounted target no longer matches the completed Archinstall target" 65
    return $?
  fi
}

_install_normal() {
  local plan_path="${SPAWN_PLAN_PATH:-$SPAWN_RUNTIME_DIR/plan.json}"
  local target_root="${SPAWN_TARGET_ROOT:-/mnt}"
  local plan_json identity inventory live_source serial plan_hash
  local luks_password user_password luks_fd user_fd user_config credentials_config
  local child_pid archinstall_status materialize_status archinstall_console_log

  runtime_init || return $?
  if [[ ! -r "$plan_path" || "$(stat -c %a -- "$plan_path")" != 600 ]]; then
    die "install requires a mode-0600 plan at $plan_path" 65
    return $?
  fi
  plan_json="$(<"$plan_path")"
  _assert_plan_materializable "$plan_json" || return $?
  _assert_plan_source "$plan_json" || return $?
  _ensure_finalizer_ports || return $?
  doctor_assert_installable || return $?

  identity="$(jq -c '.target.identity' <<<"$plan_json")" || return $?
  inventory="$(disk_inventory_json)" || return $?
  live_source="${SPAWN_LIVE_SOURCE:-$(findmnt -n -o SOURCE --target /run/archiso/bootmnt 2>/dev/null || true)}"
  resolve_disk_identity "$identity" "$inventory" >/dev/null || return $?
  assert_disk_safe "$identity" "$inventory" "$live_source" >/dev/null || return $?

  plan_hash="$(sha256_file "$plan_path")" || return $?
  serial="$(jq -r '.serial' <<<"$identity")" || return $?
  confirm_disk_erase "$serial" || return $?
  state_create "$plan_hash" || return $?
  state_transition planned confirmed || return $?

  prompt_password_into luks_password 'LUKS passphrase' || return $?
  prompt_password_into user_password 'User password' || return $?
  exec {luks_fd}< <(printf '%s\n' "$luks_password")
  exec {user_fd}< <(printf '%s\n' "$user_password")
  unset luks_password user_password

  user_config="$SPAWN_RUNTIME_DIR/user_configuration.json"
  credentials_config="$SPAWN_RUNTIME_DIR/user_credentials.json"
  archinstall_user_config "$plan_json" "$user_config" || return $?
  if archinstall_credentials "$plan_json" "$credentials_config" "$luks_fd" "$user_fd"; then
    :
  else
    materialize_status=$?
    exec {luks_fd}<&-
    exec {user_fd}<&-
    return "$materialize_status"
  fi
  exec {luks_fd}<&-
  exec {user_fd}<&-
  archinstall_validate_materialized "$user_config" "$credentials_config" || return $?
  state_transition confirmed materialized || return $?

  inventory="$(disk_inventory_json)" || return $?
  resolve_disk_identity "$identity" "$inventory" >/dev/null || return $?
  assert_disk_safe "$identity" "$inventory" "$live_source" >/dev/null || return $?
  state_transition materialized archinstall_running || return $?

  archinstall_console_log="$SPAWN_RUNTIME_DIR/archinstall-console.log"
  install -m 0600 /dev/null "$archinstall_console_log" || return $?
  log_info "Archinstall running; detailed output is captured at $archinstall_console_log"
  (
    umask 0022
    exec archinstall --config "$user_config" --creds "$credentials_config" --silent
  ) >"$archinstall_console_log" 2>&1 &
  child_pid=$!
  runtime_track_child "$child_pid" || return $?
  if wait "$child_pid"; then
    archinstall_status=0
  else
    archinstall_status=$?
  fi
  runtime_clear_child
  if ((archinstall_status != 0)); then
    printf >&2 'spawn-arch: error: Archinstall failed (exit %d); sanitized log tail follows:\n' \
      "$archinstall_status"
    if ! python3 - "$archinstall_console_log" >&2 <<'PY'; then
import re
import sys

path = sys.argv[1]
with open(path, "rb") as stream:
    stream.seek(0, 2)
    stream.seek(max(0, stream.tell() - 1024 * 1024))
    text = stream.read().decode("utf-8", errors="replace")

text = text.replace("\r", "\n")
text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
text = "".join(
    character
    for character in text
    if character in "\n\t" or ord(character) >= 32
)
lines = [line.rstrip() for line in text.splitlines() if line.strip()]
for line in lines[-80:]:
    print(line)
PY
      printf >&2 'spawn-arch: error: could not render the Archinstall log tail; inspect %s\n' \
        "$archinstall_console_log"
    fi
    return "$archinstall_status"
  fi
  log_info 'Archinstall completed successfully'
  state_transition archinstall_running archinstall_complete || return $?

  if [[ ! -s "$target_root/etc/fstab" ]]; then
    die "Archinstall exited without producing target fstab" 70
    return $?
  fi
  target_fingerprint_record "$plan_json" "$target_root" || return $?
  state_transition archinstall_complete finalizing || return $?
  _install_with_target_umask finalize_target "$target_root" "$plan_path" || return $?
  verify_target_offline "$target_root" "$plan_path" || return $?
  state_transition finalizing verified || return $?
  state_transition verified complete || return $?
}

_install_resume_finalize() {
  local plan_path="${SPAWN_PLAN_PATH:-$SPAWN_RUNTIME_DIR/plan.json}"
  local target_root="${SPAWN_TARGET_ROOT:-/mnt}"
  local plan_json

  runtime_init || return $?
  [[ -r "$plan_path" ]] || return 65
  plan_json="$(<"$plan_path")"
  _assert_plan_materializable "$plan_json" || return $?
  _assert_plan_source "$plan_json" || return $?
  _ensure_finalizer_ports || return $?
  doctor_assert_installable || return $?
  if [[ ! -s "$target_root/etc/fstab" ]]; then
    die "resume target has no fstab" 65
    return $?
  fi
  assert_resume_target "$plan_json" "$target_root" || return $?
  state_resume_finalizing || return $?
  _install_with_target_umask finalize_target "$target_root" "$plan_path" || return $?
  verify_target_offline "$target_root" "$plan_path" || return $?
  state_transition finalizing verified || return $?
  state_transition verified complete || return $?
}

_install_failure_advisory() {
  local state phase failed_from

  [[ -r "$SPAWN_STATE_PATH" ]] || return 0
  state="$(<"$SPAWN_STATE_PATH")" || return 0
  phase="$(jq -r '.phase // empty' <<<"$state" 2>/dev/null || true)"
  failed_from="$(jq -r '.failed_from // empty' <<<"$state" 2>/dev/null || true)"

  [[ "$phase" == failed ]] || return 0
  case "$failed_from" in
    archinstall_running | archinstall_complete | finalizing) ;;
    *) return 0 ;;
  esac

  printf >&2 '%s\n' 'Do not reboot: the installed target is incomplete or unverified.'
  if [[ "$failed_from" == finalizing ]]; then
    printf >&2 '%s\n' \
      'Safe resume command:' \
      './spawn-arch install --resume-finalize'
  fi
  printf >&2 '%s\n' \
    'Diagnostic command:' \
    './spawn-arch verify /mnt'
}

cmd_install() {
  local status

  case "${1:-}" in
    '')
      if _install_normal; then status=0; else status=$?; fi
      ;;
    --resume-finalize)
      if (($# != 1)); then
        die_usage "--resume-finalize accepts no additional arguments"
        return $?
      fi
      if _install_resume_finalize; then status=0; else status=$?; fi
      ;;
    *)
      die_usage "unknown install option: $1"
      return $?
      ;;
  esac

  if ((status != 0)); then
    _runtime_mark_failed
  fi
  mount_journal_cleanup || status=$?
  credentials_destroy || status=$?
  if ((status != 0)); then
    _install_failure_advisory
  fi
  return "$status"
}
