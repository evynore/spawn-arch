#!/usr/bin/env bash

if ! declare -F die >/dev/null 2>&1; then
  _spawn_geometry_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  # shellcheck source=lib/spawn-arch/common.sh
  source "$_spawn_geometry_dir/common.sh"
  unset _spawn_geometry_dir
fi

partition_geometry_json() {
  local disk_bytes="$1"
  local logical_sector_bytes="$2"
  local alignment=1048576
  local esp_start esp_size=2147483648 root_start root_end root_size
  local minimum_root_bytes=34359738368
  local boundary

  if [[ ! "$disk_bytes" =~ ^[0-9]+$ ]] || [[ ! "$logical_sector_bytes" =~ ^[0-9]+$ ]]; then
    die "disk and sector sizes must be positive integers" 65
    return $?
  fi
  if ((disk_bytes <= 0 || logical_sector_bytes <= 0 || disk_bytes > 9223372036854775807)); then
    die "disk or sector size is outside the supported integer range" 65
    return $?
  fi

  esp_start=$alignment
  root_start=$((esp_start + esp_size))
  if ((disk_bytes <= root_start + alignment)); then
    die "disk is too small for the approved partition layout" 65
    return $?
  fi
  root_end=$((((disk_bytes - alignment) / alignment) * alignment))
  root_size=$((root_end - root_start))

  for boundary in "$esp_start" "$esp_size" "$root_start" "$root_end" "$root_size"; do
    if ((boundary % logical_sector_bytes != 0)); then
      die "partition boundary $boundary is not divisible by sector size $logical_sector_bytes" 65
      return $?
    fi
  done
  if ((root_size < minimum_root_bytes)); then
    die "root partition would be smaller than 32 GiB" 65
    return $?
  fi

  jq -n \
    --argjson esp_start "$esp_start" \
    --argjson esp_size "$esp_size" \
    --argjson root_start "$root_start" \
    --argjson root_size "$root_size" \
    --argjson disk_bytes "$disk_bytes" \
    --argjson sector_bytes "$logical_sector_bytes" \
    '{
      disk_bytes: $disk_bytes,
      logical_sector_bytes: $sector_bytes,
      esp: {start_bytes: $esp_start, size_bytes: $esp_size},
      root: {start_bytes: $root_start, size_bytes: $root_size}
    }'
}
