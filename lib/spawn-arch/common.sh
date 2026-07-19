#!/usr/bin/env bash

log_info() {
  printf 'spawn-arch: %s\n' "$*" >&2
}

log_warn() {
  printf 'spawn-arch: warning: %s\n' "$*" >&2
}

die() {
  local message="$1"
  local status="${2:-1}"
  printf 'spawn-arch: error: %s\n' "$message" >&2
  return "$status"
}

die_usage() {
  die "$1" 64
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    die "required command not found: $command_name" 69
    return $?
  fi
}

sha256_file() {
  sha256sum -- "$1" | awk '{print $1}'
}

btrfs_subvolume_id_from_show() {
  local output="$1"
  local subvolume_id

  subvolume_id="$(awk '$1 == "Subvolume" && $2 == "ID:" && $3 ~ /^[1-9][0-9]*$/ {print $3; exit}' <<<"$output")"
  [[ "$subvolume_id" =~ ^[1-9][0-9]*$ ]] || return 65
  printf '%s\n' "$subvolume_id"
}

atomic_replace() {
  local source_path="$1"
  local destination_path="$2"

  sync -f "$source_path"
  mv -f -- "$source_path" "$destination_path"
  sync -f "$(dirname -- "$destination_path")"
}
