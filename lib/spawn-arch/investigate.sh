#!/usr/bin/env bash

if ! declare -F die >/dev/null 2>&1; then
  _spawn_investigate_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  # shellcheck source=lib/spawn-arch/common.sh
  source "$_spawn_investigate_dir/common.sh"
  unset _spawn_investigate_dir
fi

_investigate_positive_integer() {
  local name="$1"
  local value="$2"

  if [[ ! "$value" =~ ^[0-9]+$ ]] || ((10#$value < 1)); then
    die "$name must be a positive integer" 64
    return $?
  fi
}

_investigate_redact() {
  # shellcheck disable=SC2016 # Match a literal yescrypt prefix.
  sed -E \
    -e 's/([Aa]uthorization[[:space:]]*:[[:space:]]*)[^[:space:]]+[[:space:]]+[^[:space:]]+/\1<redacted>/g' \
    -e "s/(([Pp]assword|[Pp]assphrase|[Tt]oken|[Aa][Pp][Ii][_-]?[Kk]ey)[\"']?[[:space:]]*[:=][[:space:]]*)[\"']?[^\"',[:space:]]+[\"']?/\\1<redacted>/g" \
    -e 's/\$y\$[^[:space:]",]+/<redacted>/g' \
    -e "s/(([Ss][Ee][Rr][Ii][Aa][Ll])[\"']?[[:space:]]*[:=][[:space:]]*)[\"']?[^\"',[:space:]]+[\"']?/\\1<redacted>/g" \
    -e "s/(([Ww][Ww][Nn]|[Ww][Ww][Ii][Dd]|[Ee][Uu][Ii])[\"']?[[:space:]]*[:=][[:space:]]*)[\"']?[^\"',[:space:]]+[\"']?/\\1<redacted>/g" \
    -e 's/([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}/<redacted>/g'
}

_investigate_normalize_utf8() {
  if command -v iconv >/dev/null 2>&1; then
    iconv -f UTF-8 -t UTF-8 -c |
      LC_ALL=C sed -E $'s/\033\\[[0-?]*[ -\\/]*[@-~]//g' |
      LC_ALL=C tr -d '\000-\010\013\014\016-\037\177'
  else
    LC_ALL=C sed -E $'s/\033\\[[0-?]*[ -\\/]*[@-~]//g' |
      LC_ALL=C tr -cd '\11\12\15\40-\176'
  fi
}

_investigate_add_collector() {
  local name="$1"
  local status="$2"
  local truncated="$3"
  local output_path="$4"
  local record
  local ok=false

  ((status == 0)) && ok=true
  record="$(jq -cn \
    --argjson ok "$ok" \
    --argjson exit_code "$status" \
    --argjson truncated "$truncated" \
    --rawfile output "$output_path" \
    '{ok:$ok, exit_code:$exit_code, output:$output, truncated:$truncated}')" || return $?
  INVESTIGATE_COLLECTORS="$(jq -c --arg name "$name" --argjson record "$record" \
    '. + {($name): $record}' <<<"$INVESTIGATE_COLLECTORS")" || return $?
}

_investigate_capture() {
  local name="$1"
  shift
  local raw="$INVESTIGATE_TEMP_DIR/$name.raw"
  local clean="$INVESTIGATE_TEMP_DIR/$name.clean"
  local status size truncated=false

  if timeout --signal=TERM --kill-after=1 "${INVESTIGATE_TIMEOUT_SECONDS}s" "$@" >"$raw" 2>&1; then
    status=0
  else
    status=$?
  fi
  size="$(wc -c <"$raw")" || return $?
  if ((size > INVESTIGATE_MAX_BYTES)); then
    truncated=true
  fi
  head -c "$INVESTIGATE_MAX_BYTES" "$raw" |
    _investigate_normalize_utf8 |
    _investigate_redact >"$clean" || return $?
  _investigate_add_collector "$name" "$status" "$truncated" "$clean"
}

_investigate_capture_shell() {
  local name="$1"
  local script="$2"
  shift 2
  _investigate_capture "$name" bash -o pipefail -c "$script" _ "$@"
}

_investigate_source_commit() {
  local source_file="${REPO_ROOT:-.}/SOURCE_COMMIT"
  local commit=""

  if [[ -r "$source_file" ]]; then
    IFS= read -r commit <"$source_file" || true
  elif command -v git >/dev/null 2>&1; then
    commit="$(git -C "${REPO_ROOT:-.}" rev-parse HEAD 2>/dev/null || true)"
  fi
  if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
    commit="unknown"
  fi
  printf '%s\n' "$commit"
}

cmd_investigate() (
  if (($# != 0)); then
    die_usage "investigate accepts no arguments"
    exit $?
  fi

  INVESTIGATE_TIMEOUT_SECONDS="${SPAWN_INVESTIGATE_TIMEOUT_SECONDS:-5}"
  INVESTIGATE_TAIL_LINES="${SPAWN_INVESTIGATE_TAIL_LINES:-200}"
  INVESTIGATE_MAX_BYTES="${SPAWN_INVESTIGATE_MAX_BYTES:-65536}"
  _investigate_positive_integer SPAWN_INVESTIGATE_TIMEOUT_SECONDS "$INVESTIGATE_TIMEOUT_SECONDS" || exit $?
  _investigate_positive_integer SPAWN_INVESTIGATE_TAIL_LINES "$INVESTIGATE_TAIL_LINES" || exit $?
  _investigate_positive_integer SPAWN_INVESTIGATE_MAX_BYTES "$INVESTIGATE_MAX_BYTES" || exit $?
  require_command jq || exit $?
  require_command timeout || exit $?

  local output_dir now compact timestamp_base report readable index candidate_base source_commit
  local destination_json destination_readable candidate_json candidate_readable
  output_dir="$(pwd -P)" || exit $?
  now="${SPAWN_INVESTIGATE_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  if [[ ! "$now" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    die "investigation timestamp must be UTC ISO-8601" 64
    exit $?
  fi
  compact="${now//-/}"
  compact="${compact//:/}"
  timestamp_base="spawn-arch-investigation-$compact"
  INVESTIGATE_TEMP_DIR="$(mktemp -d "$output_dir/.spawn-arch-investigation.tmp.XXXXXX")" || exit $?
  chmod 0700 "$INVESTIGATE_TEMP_DIR" || exit $?
  trap 'rm -rf -- "$INVESTIGATE_TEMP_DIR"' EXIT
  INVESTIGATE_COLLECTORS='{}'

  local runtime_dir="${SPAWN_RUNTIME_DIR:-/run/spawn-arch}"
  local archinstall_log="${SPAWN_ARCHINSTALL_LOG_PATH:-/var/log/archinstall/install.log}"
  local console_log="$runtime_dir/archinstall-console.log"

  _investigate_capture state jq -c \
    '{schema_version, phase, failed_from, last_completed_phase, created_at, updated_at, resume_count, plan_sha256}' \
    "$runtime_dir/install-state.json"
  _investigate_capture plan jq -c '
    {
      schema_version,
      created_at,
      target: {device_at_plan_time: .target.device_at_plan_time},
      storage,
      system: {keymap: .system.keymap, locale: .system.locale},
      archinstall,
      source
    }
  ' "$runtime_dir/plan.json"
  _investigate_capture archinstall_console tail -n "$INVESTIGATE_TAIL_LINES" -- "$console_log"
  _investigate_capture archinstall_log tail -n "$INVESTIGATE_TAIL_LINES" -- "$archinstall_log"
  # shellcheck disable=SC2016 # $1 belongs to the bounded child shell.
  _investigate_capture_shell dmesg 'dmesg --color=never 2>&1 | tail -n "$1"' "$INVESTIGATE_TAIL_LINES"
  _investigate_capture lsblk lsblk --bytes --json \
    -o NAME,KNAME,PATH,TYPE,SIZE,LOG-SEC,MODEL,SERIAL,WWN,RO,RM,MOUNTPOINTS,PKNAME
  _investigate_capture findmnt_target findmnt --json --target /mnt
  _investigate_capture findmnt_live findmnt --json --target /run/archiso/bootmnt
  _investigate_capture mounts findmnt --json --submounts /mnt
  # shellcheck disable=SC2016 # Variables belong to the bounded child shell.
  _investigate_capture_shell luks_status '
    findmnt -rn -o SOURCE 2>/dev/null |
      sed "s/\\[.*$//" |
      grep "^/dev/mapper/" |
      sort -u |
      while IFS= read -r source; do
        cryptsetup status "${source#/dev/mapper/}"
      done
  '
  _investigate_capture machinectl machinectl list --no-legend --no-pager
  _investigate_capture_shell processes '
    ps -eo pid,ppid,stat,etimes,comm,args |
      grep -E "spawn-arch|archinstall|systemd-nspawn|systemd-run|pacman|arch-chroot" |
      grep -v "grep -E"
  '
  _investigate_capture_shell versions '
    printf "archinstall: "; archinstall --version 2>&1 || true
    printf "lsblk: "; lsblk --version 2>&1 | head -n 1 || true
    printf "cryptsetup: "; cryptsetup --version 2>&1 || true
    printf "systemd: "; systemd --version 2>&1 | head -n 1 || true
    printf "kernel: "; uname -sr 2>&1 || true
    printf "bash: "; bash --version 2>&1 | head -n 1 || true
  '

  source_commit="$(_investigate_source_commit)" || exit $?
  report="$INVESTIGATE_TEMP_DIR/report.json"
  jq -n \
    --argjson schema_version 1 \
    --argjson ok true \
    --arg created_at "$now" \
    --arg source_commit "$source_commit" \
    --argjson collectors "$INVESTIGATE_COLLECTORS" \
    '{schema_version:$schema_version, ok:$ok, created_at:$created_at, source_commit:$source_commit, collectors:$collectors}' \
    >"$report" || exit $?
  chmod 0600 "$report" || exit $?
  readable="$INVESTIGATE_TEMP_DIR/report.txt"
  jq -r '
    "spawn-arch investigation\ncreated_at=\(.created_at)\nsource_commit=\(.source_commit)\n",
    (
      .collectors
      | to_entries[]
      | "===== \(.key) | ok=\(.value.ok) exit=\(.value.exit_code) truncated=\(.value.truncated) =====\n\(.value.output)"
    )
  ' "$report" >"$readable" || exit $?
  chmod 0600 "$readable" || exit $?
  sync -f "$report" || exit $?
  sync -f "$readable" || exit $?

  destination_json=""
  destination_readable=""
  for ((index = 0; index < 1000; index++)); do
    candidate_base="$output_dir/$timestamp_base"
    ((index == 0)) || candidate_base="$output_dir/$timestamp_base-$index"
    candidate_json="$candidate_base.json"
    candidate_readable="$candidate_base.txt"
    if [[ -e "$candidate_json" || -e "$candidate_readable" ]]; then
      continue
    fi
    if ! ln -- "$report" "$candidate_json" 2>/dev/null; then
      if [[ -e "$candidate_json" || -e "$candidate_readable" ]]; then
        continue
      fi
      die "cannot create investigation report: $candidate_json" 73
      exit $?
    fi
    if ln -- "$readable" "$candidate_readable" 2>/dev/null; then
      destination_json="$candidate_json"
      destination_readable="$candidate_readable"
      break
    fi
    rm -f -- "$candidate_json"
    if [[ -e "$candidate_readable" ]]; then
      continue
    fi
    die "cannot create investigation report: $candidate_readable" 73
    exit $?
  done
  if [[ -z "$destination_json" || -z "$destination_readable" ]]; then
    die "cannot allocate a unique investigation report name" 73
    exit $?
  fi
  sync -f "$output_dir" || exit $?
  printf 'readable_report=%s\n' "$destination_readable"
  printf 'json_report=%s\n' "$destination_json"
)
