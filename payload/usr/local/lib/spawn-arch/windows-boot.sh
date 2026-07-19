#!/usr/bin/env bash

if ! declare -F die >/dev/null 2>&1; then
  _windows_boot_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  # shellcheck source=/dev/null
  source "$_windows_boot_lib_dir/common.sh"
  unset _windows_boot_lib_dir
fi

SPAWN_WINDOWS_BOOT_ESP=/boot
SPAWN_WINDOWS_BOOT_RUNTIME=/run/spawn-arch/windows-boot
readonly WINDOWS_BOOT_ESP_PARTTYPE='c12a7328-f81f-11d2-ba4b-00a0c93ec93b'

windows_boot_log_info() {
  printf 'spawn-arch: %s\n' "$*" >&2
}

windows_boot_atomic_replace() {
  local source_path="$1"
  local destination_path="$2"

  [[ "$(dirname -- "$source_path")" == "$(dirname -- "$destination_path")" ]] || return 65
  sync -f -- "$source_path" || return $?
  mv -f -- "$source_path" "$destination_path" || return $?
  sync -f -- "$(dirname -- "$destination_path")"
}

windows_boot_candidates_from_json() {
  local lsblk_json="$1"
  local active_esp="${2:-}"

  jq -er --arg active "$active_esp" --arg esp "$WINDOWS_BOOT_ESP_PARTTYPE" '
    [
      .. | objects
      | select(
          .type == "part" and
          ((.fstype // "") | ascii_downcase) == "vfat" and
          ((.parttype // "") | ascii_downcase) == $esp and
          .path != $active
        )
      | .path
    ]
    | unique[]
  ' <<<"$lsblk_json"
}

windows_boot_validate_tree() {
  local root="$1"

  windows_boot_validate_microsoft_tree "$root/EFI/Microsoft"
}

windows_boot_validate_microsoft_tree() {
  local tree="$1"
  local manager="$tree/Boot/bootmgfw.efi"
  local bcd="$tree/Boot/BCD"

  [[ -s "$manager" ]] || {
    die 'Windows ESP is missing EFI/Microsoft/Boot/bootmgfw.efi' 65
    return $?
  }
  [[ -s "$bcd" ]] || {
    die 'Windows ESP is missing EFI/Microsoft/Boot/BCD' 65
    return $?
  }
  [[ "$(head -c 2 -- "$manager")" == MZ ]] || {
    die 'Windows boot manager is not a PE/COFF image' 65
    return $?
  }
  if find "$tree" -mindepth 1 ! -type d ! -type f -print -quit | grep -q .; then
    die 'Windows boot tree contains a symlink or special file' 65
    return $?
  fi
}

windows_boot_tree_manifest() {
  local tree="$1"
  local file relative hash

  [[ -d "$tree" ]] || return 66
  while IFS= read -r -d '' file; do
    relative="${file#"$tree"/}"
    [[ "$relative" != *$'\n'* ]] || return 65
    hash="$(sha256_file "$file")" || return $?
    printf '%s  %s\n' "$hash" "$relative"
  done < <(find "$tree" -type f -print0 | LC_ALL=C sort -z)
}

windows_boot_mount_source() {
  local device="$1"
  local mount_path="$2"

  install -d -m 0700 -- "$mount_path" || return $?
  mount --types vfat --options ro,nosuid,nodev,noexec -- "$device" "$mount_path"
}

windows_boot_unmount_source() {
  umount -- "$1"
}

windows_boot_lsblk_json() {
  lsblk --json --paths --output PATH,TYPE,FSTYPE,PARTTYPE
}

windows_boot_active_esp_source() {
  findmnt --noheadings --output SOURCE --target "$SPAWN_WINDOWS_BOOT_ESP"
}

windows_boot_probe_source() {
  local device="$1"
  local probe="$SPAWN_WINDOWS_BOOT_RUNTIME/probe"
  local status=0

  rmdir -- "$probe" 2>/dev/null || true
  windows_boot_mount_source "$device" "$probe" || return $?
  windows_boot_validate_tree "$probe" || status=$?
  windows_boot_unmount_source "$probe" || status=$?
  if ((status == 0)); then rmdir -- "$probe" || status=$?; fi
  return "$status"
}

windows_boot_discover_sources() {
  local active candidates json device

  install -d -m 0700 -- "$SPAWN_WINDOWS_BOOT_RUNTIME" || return $?
  active="$(windows_boot_active_esp_source)" || return $?
  json="$(windows_boot_lsblk_json)" || return $?
  candidates="$(windows_boot_candidates_from_json "$json" "$active")" || return $?
  while IFS= read -r device; do
    [[ -n "$device" ]] || continue
    if windows_boot_probe_source "$device"; then
      printf '%s\n' "$device"
    fi
  done <<<"$candidates"
}

windows_boot_validate_explicit_source() {
  local requested="$1"
  local active candidates json device found=false

  active="$(windows_boot_active_esp_source)" || return $?
  json="$(windows_boot_lsblk_json)" || return $?
  candidates="$(windows_boot_candidates_from_json "$json" "$active")" || return $?
  while IFS= read -r device; do
    if [[ "$device" == "$requested" ]]; then
      found=true
      break
    fi
  done <<<"$candidates"
  [[ "$found" == true ]] || {
    die "explicit Windows source is not a vfat GPT ESP: $requested" 65
    return $?
  }
  windows_boot_probe_source "$requested"
}

windows_boot_select_source() {
  local explicit_source="${1:-}"
  local discovered
  local -a candidates=()

  if [[ -n "$explicit_source" ]]; then
    windows_boot_validate_explicit_source "$explicit_source" || return $?
    printf '%s\n' "$explicit_source"
    return 0
  fi

  discovered="$(windows_boot_discover_sources)" || return $?
  if [[ -n "$discovered" ]]; then
    mapfile -t candidates <<<"$discovered"
  fi
  case "${#candidates[@]}" in
    0)
      die 'no Windows EFI System Partition was found; use --source after checking lsblk' 66
      return $?
      ;;
    1) printf '%s\n' "${candidates[0]}" ;;
    *)
      die "multiple Windows EFI System Partitions were found: ${candidates[*]}; use --source" 65
      return $?
      ;;
  esac
}

windows_boot_validate_destination() {
  local fstype

  [[ -d "$SPAWN_WINDOWS_BOOT_ESP" && -w "$SPAWN_WINDOWS_BOOT_ESP" ]] || {
    die "Linux ESP is unavailable or read-only: $SPAWN_WINDOWS_BOOT_ESP" 66
    return $?
  }
  fstype="$(findmnt --noheadings --output FSTYPE --target "$SPAWN_WINDOWS_BOOT_ESP")" || return $?
  [[ "$fstype" == vfat ]] || {
    die "Linux ESP is not vfat: $SPAWN_WINDOWS_BOOT_ESP" 65
    return $?
  }
  bootctl --esp-path="$SPAWN_WINDOWS_BOOT_ESP" is-installed >/dev/null
}

windows_boot_write_entry() {
  local entry="$SPAWN_WINDOWS_BOOT_ESP/loader/entries/windows.conf"
  local temporary="$entry.spawn-arch.new"

  install -d -m 0700 -- "$(dirname -- "$entry")" || return $?
  printf '%s\n' \
    'title Windows Boot Manager' \
    'efi /EFI/Microsoft/Boot/bootmgfw.efi' >"$temporary" || return $?
  chmod 0600 -- "$temporary" || return $?
  windows_boot_atomic_replace "$temporary" "$entry"
}

windows_boot_bootctl_has_windows() {
  local list

  list="$(bootctl --esp-path="$SPAWN_WINDOWS_BOOT_ESP" --json=short list)" || return $?
  jq -e 'any(.[]; .id == "windows.conf" or .id == "auto-windows")' >/dev/null <<<"$list"
}

windows_boot_restore_entry() {
  local entry="$1"
  local backup="$2"

  rm -f -- "$entry"
  if [[ -r "$backup" ]]; then
    mv -- "$backup" "$entry"
  fi
}

windows_boot_publish() {
  local source_root="$1"
  local destination="$SPAWN_WINDOWS_BOOT_ESP/EFI/Microsoft"
  local stage="$SPAWN_WINDOWS_BOOT_ESP/EFI/.spawn-arch-windows-stage.$$"
  local backup="$SPAWN_WINDOWS_BOOT_ESP/EFI/.spawn-arch-windows-backup.$$"
  local entry="$SPAWN_WINDOWS_BOOT_ESP/loader/entries/windows.conf"
  local entry_temporary="$entry.spawn-arch.new"
  local entry_backup="$SPAWN_WINDOWS_BOOT_RUNTIME/windows.conf.previous"
  local source_manifest stage_manifest destination_manifest
  local changed=true had_destination=false had_entry=false

  rm -rf -- "$stage" "$backup"
  rm -f -- "$entry_backup"
  install -d -m 0700 -- "$stage" || return $?
  cp -R -- "$source_root/EFI/Microsoft/." "$stage/" || return $?
  windows_boot_validate_microsoft_tree "$stage" || {
    rm -rf -- "$stage"
    return 65
  }
  source_manifest="$(windows_boot_tree_manifest "$source_root/EFI/Microsoft")" || {
    rm -rf -- "$stage"
    return 74
  }
  stage_manifest="$(windows_boot_tree_manifest "$stage")" || {
    rm -rf -- "$stage"
    return 74
  }
  [[ "$source_manifest" == "$stage_manifest" ]] || {
    rm -rf -- "$stage"
    die 'staged Windows boot tree does not match the source manifest' 74
    return $?
  }

  if [[ -d "$destination" ]]; then
    destination_manifest="$(windows_boot_tree_manifest "$destination")" || {
      rm -rf -- "$stage"
      return 74
    }
    [[ "$destination_manifest" != "$source_manifest" ]] || changed=false
  fi
  if [[ -r "$entry" ]]; then
    cp -- "$entry" "$entry_backup" || {
      rm -rf -- "$stage"
      return 74
    }
    had_entry=true
  fi
  if [[ "$changed" == false ]]; then
    if ! windows_boot_write_entry || ! windows_boot_bootctl_has_windows ||
      ! sync -f "$SPAWN_WINDOWS_BOOT_ESP"; then
      windows_boot_restore_entry "$entry" "$entry_backup"
      rm -rf -- "$stage"
      rm -f -- "$entry_temporary" "$entry_backup"
      return 74
    fi
    rm -rf -- "$stage"
    rm -f -- "$entry_backup"
    sync -f "$SPAWN_WINDOWS_BOOT_ESP" || return 74
    windows_boot_log_info 'Windows Boot Manager is already up to date'
    return 0
  fi

  if [[ -d "$destination" ]]; then
    mv -- "$destination" "$backup" || {
      rm -rf -- "$stage"
      rm -f -- "$entry_backup"
      return 74
    }
    had_destination=true
  fi
  if ! mv -- "$stage" "$destination" || ! windows_boot_write_entry ||
    ! windows_boot_bootctl_has_windows || ! sync -f "$SPAWN_WINDOWS_BOOT_ESP"; then
    rm -rf -- "$destination" "$stage"
    if [[ "$had_destination" == true ]]; then mv -- "$backup" "$destination"; fi
    if [[ "$had_entry" == true ]]; then
      windows_boot_restore_entry "$entry" "$entry_backup"
    else
      rm -f -- "$entry"
    fi
    rm -f -- "$entry_temporary" "$entry_backup"
    sync -f "$SPAWN_WINDOWS_BOOT_ESP" || true
    return 74
  fi
  rm -rf -- "$backup"
  rm -f -- "$entry_backup"
  sync -f "$SPAWN_WINDOWS_BOOT_ESP" || return 74
  windows_boot_log_info 'Windows Boot Manager synchronized to the Linux ESP'
}

windows_boot_sync() {
  local explicit_source="${1:-}"
  local source_device source_mount="$SPAWN_WINDOWS_BOOT_RUNTIME/source"
  local status=0

  windows_boot_validate_destination || return $?
  install -d -m 0700 -- "$SPAWN_WINDOWS_BOOT_RUNTIME" || return $?
  source_device="$(windows_boot_select_source "$explicit_source")" || return $?
  rmdir -- "$source_mount" 2>/dev/null || true
  windows_boot_mount_source "$source_device" "$source_mount" || return $?
  if ! windows_boot_validate_tree "$source_mount"; then
    status=65
  elif windows_boot_publish "$source_mount"; then
    status=0
  else
    status=$?
  fi
  windows_boot_unmount_source "$source_mount" || status=$?
  if ((status == 0)); then rmdir -- "$source_mount" || status=$?; fi
  return "$status"
}

cmd_windows_boot() {
  local command="${1:-}"
  local source_device=''

  [[ "$command" == sync ]] || {
    die 'windows-boot requires the sync subcommand' 64
    return $?
  }
  shift
  while (($# > 0)); do
    case "$1" in
      --source)
        (($# >= 2)) || {
          die '--source requires an absolute /dev path' 64
          return $?
        }
        source_device="$2"
        [[ "$source_device" == /dev/* ]] || {
          die '--source requires an absolute /dev path' 64
          return $?
        }
        shift 2
        ;;
      *)
        die "unknown windows-boot option: $1" 64
        return $?
        ;;
    esac
  done
  windows_boot_sync "$source_device"
}
