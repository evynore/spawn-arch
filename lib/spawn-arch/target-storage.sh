#!/usr/bin/env bash

if ! declare -F die >/dev/null 2>&1; then
  _spawn_target_storage_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  # shellcheck source=lib/spawn-arch/common.sh
  source "$_spawn_target_storage_dir/common.sh"
  unset _spawn_target_storage_dir
fi

_target_mapper_name() {
  local mount_source="$1"
  local canonical_mount_source="$2"
  local mapper_name kernel_name name_path alias_canonical

  if [[ "$mount_source" == /dev/mapper/* ]]; then
    mapper_name="${mount_source#/dev/mapper/}"
  elif [[ "$canonical_mount_source" == /dev/dm-[0-9]* ]]; then
    kernel_name="${canonical_mount_source##*/}"
    name_path="${SPAWN_SYS_CLASS_BLOCK_DIR:-/sys/class/block}/$kernel_name/dm/name"
    if [[ ! -r "$name_path" ]] || ! IFS= read -r mapper_name <"$name_path"; then
      die "cannot recover mapper name for mounted device: $canonical_mount_source" 65
      return $?
    fi
  else
    die "target root is not mounted from device-mapper: $mount_source" 65
    return $?
  fi

  if [[ ! "$mapper_name" =~ ^[A-Za-z0-9+_.-]+$ ]]; then
    die "target mapper name is invalid" 65
    return $?
  fi
  alias_canonical="$(readlink -f -- "/dev/mapper/$mapper_name" 2>/dev/null || true)"
  if [[ "$alias_canonical" != "$canonical_mount_source" ]]; then
    die "target mapper alias does not resolve to mounted device: /dev/mapper/$mapper_name" 65
    return $?
  fi
  printf '%s\n' "$mapper_name"
}

target_storage_json() {
  local target_root="$1"
  local mount_source canonical_mount_source mapper_name status_output
  local luks_device luks_uuid

  mount_source="$(findmnt -n -o SOURCE --target "$target_root" 2>/dev/null)" || {
    die "cannot discover target root mount source: $target_root" 65
    return $?
  }
  mount_source="${mount_source%%\[*}"
  if [[ "$mount_source" != /dev/* ]]; then
    die "target root mount source is not a block device: $mount_source" 65
    return $?
  fi
  canonical_mount_source="$(readlink -f -- "$mount_source" 2>/dev/null || true)"
  if [[ ! "$canonical_mount_source" =~ ^/dev/dm-[0-9]+$ ]]; then
    die "target root does not resolve to a dm kernel device: $mount_source" 65
    return $?
  fi
  mapper_name="$(_target_mapper_name "$mount_source" "$canonical_mount_source")" || return $?
  status_output="$(cryptsetup status "$mapper_name" 2>/dev/null)" || {
    die "cryptsetup cannot inspect target mapper: $mapper_name" 65
    return $?
  }
  luks_device="$(awk '$1 == "device:" {print $2; exit}' <<<"$status_output")"
  if [[ "$luks_device" != /dev/* ]]; then
    die "cryptsetup reported no backing device for target mapper: $mapper_name" 65
    return $?
  fi
  luks_device="$(readlink -f -- "$luks_device" 2>/dev/null || true)"
  if [[ -z "$luks_device" || "$(blkid -s TYPE -o value -- "$luks_device" 2>/dev/null || true)" != crypto_LUKS ]]; then
    die "target mapper backing device is not LUKS: $mapper_name" 65
    return $?
  fi
  luks_uuid="$(blkid -s UUID -o value -- "$luks_device" 2>/dev/null)" || {
    die "cannot read target LUKS UUID: $luks_device" 65
    return $?
  }
  if [[ ! "$luks_uuid" =~ ^[0-9A-Fa-f-]+$ ]]; then
    die "target LUKS UUID is invalid: $luks_device" 65
    return $?
  fi

  jq -n \
    --arg mount_source "$mount_source" \
    --arg canonical_mount_source "$canonical_mount_source" \
    --arg mapper_name "$mapper_name" \
    --arg luks_device "$luks_device" \
    --arg luks_uuid "$luks_uuid" \
    '{
      mount_source: $mount_source,
      canonical_mount_source: $canonical_mount_source,
      mapper_name: $mapper_name,
      luks_device: $luks_device,
      luks_uuid: $luks_uuid
    }'
}
