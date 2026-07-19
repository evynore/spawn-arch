#!/usr/bin/env bash

log_warn() {
  printf 'spawn-arch: warning: %s\n' "$*" >&2
}

die() {
  local message="$1"
  local status="${2:-1}"

  printf 'spawn-arch: error: %s\n' "$message" >&2
  return "$status"
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

sync_file_and_directory() {
  local path="$1"

  sync -f -- "$path"
  sync -f -- "$(dirname -- "$path")"
}

atomic_replace_same_directory() {
  local source_path="$1"
  local destination_path="$2"

  [[ "$(dirname -- "$source_path")" == "$(dirname -- "$destination_path")" ]] || {
    die "atomic replacement must stay on one filesystem" 65
    return $?
  }
  sync -f -- "$source_path" || return $?
  mv -f -- "$source_path" "$destination_path" || return $?
  sync -f -- "$(dirname -- "$destination_path")"
}

safe_basename() {
  local value="$1"

  [[ -n "$value" && "$value" != . && "$value" != .. && "$value" != */* ]]
}

installed_etc_root() {
  printf '%s\n' "${SPAWN_ETC_ROOT:-/etc}"
}
