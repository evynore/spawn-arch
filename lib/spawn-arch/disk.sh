#!/usr/bin/env bash

if ! declare -F die >/dev/null 2>&1; then
  _spawn_disk_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  # shellcheck source=lib/spawn-arch/common.sh
  source "$_spawn_disk_dir/common.sh"
  unset _spawn_disk_dir
fi

_by_id_map_json() {
  local by_id_dir="${SPAWN_BY_ID_DIR:-/dev/disk/by-id}"
  local link target map='{}'

  if [[ ! -d "$by_id_dir" ]]; then
    printf '{}\n'
    return 0
  fi

  while IFS= read -r -d '' link; do
    target="$(readlink -f -- "$link" 2>/dev/null || true)"
    [[ -n "$target" ]] || continue
    map="$(jq -c --arg target "$target" --arg link "$link" \
      '.[$target] = ((.[$target] // []) + [$link] | unique | sort)' <<<"$map")"
  done < <(find "$by_id_dir" -mindepth 1 -maxdepth 1 -type l -print0)

  printf '%s\n' "$map"
}

_holders_map_json() {
  local sys_block_dir="${SPAWN_SYS_BLOCK_DIR:-/sys/class/block}"
  local block_path holder_path kname holder map='{}'

  if [[ ! -d "$sys_block_dir" ]]; then
    printf '{}\n'
    return 0
  fi

  for block_path in "$sys_block_dir"/*; do
    [[ -e "$block_path" ]] || continue
    kname="$(basename -- "$block_path")"
    for holder_path in "$block_path"/holders/*; do
      [[ -e "$holder_path" ]] || continue
      holder="/dev/$(basename -- "$holder_path")"
      map="$(jq -c --arg kname "$kname" --arg holder "$holder" \
        '.[$kname] = ((.[$kname] // []) + [$holder] | unique | sort)' <<<"$map")"
    done
  done

  printf '%s\n' "$map"
}

_live_devices_json() {
  local mount_target source ancestor
  local -a live_devices=()

  for mount_target in /run/archiso/bootmnt /; do
    source="$(findmnt -n -o SOURCE --target "$mount_target" 2>/dev/null || true)"
    source="${source%%\[*}"
    [[ "$source" == /dev/* ]] || continue
    source="$(readlink -f -- "$source" 2>/dev/null || true)"
    [[ -n "$source" ]] || continue
    live_devices+=("$source")
    while IFS= read -r ancestor; do
      [[ "$ancestor" == /dev/* ]] && live_devices+=("$ancestor")
    done < <(lsblk -s -n -o PATH -- "$source" 2>/dev/null || true)
  done

  if ((${#live_devices[@]} == 0)); then
    printf '[]\n'
  else
    printf '%s\n' "${live_devices[@]}" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique | sort'
  fi
}

disk_inventory_json() {
  local raw by_ids holders live_devices

  require_command lsblk || return $?
  require_command jq || return $?
  require_command readlink || return $?
  require_command findmnt || return $?

  raw="$(lsblk --bytes --json \
    -o NAME,KNAME,PATH,TYPE,SIZE,LOG-SEC,MODEL,SERIAL,WWN,RO,RM,MOUNTPOINTS,PKNAME)" || return $?
  by_ids="$(_by_id_map_json)" || return $?
  holders="$(_holders_map_json)" || return $?
  live_devices="$(_live_devices_json)" || return $?

  jq -n \
    --argjson raw "$raw" \
    --argjson by_ids "$by_ids" \
    --argjson holders "$holders" \
    --argjson live_devices "$live_devices" '
      def null_if_empty:
        if . == null or . == "" then null else . end;
      def eui_from_wwn:
        if type == "string" then
          if startswith("eui.") then ltrimstr("eui.") else null end
        else null
        end;
      {
        disks: [
          $raw.blockdevices[]
          | select(.type == "disk")
          | . as $disk
          | {
              path: $disk.path,
              kname: $disk.kname,
              size_bytes: $disk.size,
              logical_sector_bytes: $disk["log-sec"],
              model: ($disk.model | null_if_empty),
              serial: ($disk.serial | null_if_empty),
              wwn: ($disk.wwn | null_if_empty),
              eui: ($disk.wwn | eui_from_wwn),
              read_only: ($disk.ro == true or $disk.ro == 1 or $disk.ro == "1"),
              removable: ($disk.rm == true or $disk.rm == 1 or $disk.rm == "1"),
              mountpoints: ([
                $disk | recurse(.children[]?)
                | (.mountpoints // [])[]?
                | select(type == "string" and length > 0)
              ] | unique | sort),
              descendant_paths: ([
                $disk | recurse(.children[]?)
                | .path
                | select(type == "string" and length > 0)
              ] | unique | sort),
              holders: ([
                $disk | recurse(.children[]?)
                | $holders[.kname][]?
              ] | unique | sort),
              by_id: ($by_ids[$disk.path] // [])
            }
        ],
        live_devices: $live_devices
      }
    '
}

disk_identity_json() {
  local device="$1"
  local inventory_json="$2"
  local disk identity

  if ! disk="$(jq -ce --arg device "$device" \
    '[.disks[] | select(.path == $device)] | if length == 1 then .[0] else empty end' \
    <<<"$inventory_json")"; then
    die "disk is absent or ambiguous in inventory: $device" 65
    return $?
  fi

  identity="$(jq -c '
    def stable_wwn:
      if (.eui // "") != "" then .eui
      elif (.wwn // "") != "" then .wwn
      else null
      end;
    {
      serial: .serial,
      wwn_or_eui: stable_wwn,
      size_bytes: .size_bytes,
      by_id: ([.by_id[]? | select(test("-part[0-9]+$") | not)] | unique | sort | .[0] // null),
      logical_sector_bytes: .logical_sector_bytes
    }
  ' <<<"$disk")" || return $?

  if ! jq -e '
    (.serial | type == "string" and length > 0) and
    (.size_bytes | type == "number" and . > 0) and
    (.by_id | type == "string" and startswith("/dev/disk/by-id/")) and
    (.logical_sector_bytes | type == "number" and . > 0) and
    (.wwn_or_eui == null or (.wwn_or_eui | type == "string" and length > 0))
  ' >/dev/null <<<"$identity"; then
    die "disk lacks a complete stable identity: $device" 65
    return $?
  fi

  printf '%s\n' "$identity"
}

resolve_disk_identity() {
  local identity_json="$1"
  local inventory_json="$2"
  local matches count

  if ! jq -e 'type == "object"' >/dev/null <<<"$identity_json"; then
    die "invalid disk identity JSON" 65
    return $?
  fi

  matches="$(jq -c --argjson identity "$identity_json" '
    def stable_wwn:
      if (.eui // "") != "" then .eui
      elif (.wwn // "") != "" then .wwn
      else null
      end;
    [
      .disks[]
      | select(.serial == $identity.serial)
      | select(.size_bytes == $identity.size_bytes)
      | select(.logical_sector_bytes == $identity.logical_sector_bytes)
      | select((.by_id // []) | index($identity.by_id))
      | select(
          $identity.wwn_or_eui == null or
          stable_wwn == $identity.wwn_or_eui
        )
    ]
  ' <<<"$inventory_json")" || return $?
  count="$(jq 'length' <<<"$matches")"

  if [[ "$count" != 1 ]]; then
    die "stable disk identity resolved to $count devices" 65
    return $?
  fi

  jq -r '.[0].path' <<<"$matches"
}

assert_disk_safe() {
  local identity_json="$1"
  local inventory_json="$2"
  local live_source="$3"
  local device reasons

  device="$(resolve_disk_identity "$identity_json" "$inventory_json")" || return $?
  reasons="$(jq -r --arg device "$device" --arg live "$live_source" '
    . as $inventory
    | .disks[]
    | select(.path == $device)
    | (.descendant_paths // [.path]) as $paths
    | (($inventory.live_devices // []) + [$live]) as $live_devices
    | [
        if .read_only then "read-only" else empty end,
        if .removable then "removable" else empty end,
        if ((.mountpoints // []) | length) > 0 then "mounted" else empty end,
        if ((.holders // []) | length) > 0 then "has holders" else empty end,
        if ([
          $paths[] as $path
          | $live_devices[]
          | select(. == $path)
        ] | length) > 0 then "contains live media" else empty end
      ]
    | join(", ")
  ' <<<"$inventory_json")" || return $?

  if [[ -n "$reasons" ]]; then
    die "unsafe target disk $device: $reasons" 65
    return $?
  fi

  printf '%s\n' "$device"
}

eligible_disks_json() {
  local inventory_json="$1"
  local live_source="$2"
  local disk identity device
  local -a eligible=()

  while IFS= read -r disk; do
    identity="$(disk_identity_json "$(jq -r '.path' <<<"$disk")" "$inventory_json" 2>/dev/null)" || continue
    device="$(assert_disk_safe "$identity" "$inventory_json" "$live_source" 2>/dev/null)" || continue
    eligible+=("$(jq -c --arg device "$device" --argjson identity "$identity" \
      '{device: $device, identity: $identity, model: .model}' <<<"$disk")")
  done < <(jq -c '.disks[]' <<<"$inventory_json")

  if ((${#eligible[@]} == 0)); then
    printf '[]\n'
  else
    printf '%s\n' "${eligible[@]}" | jq -sc '.'
  fi
}

confirm_disk_erase() {
  local serial="$1"
  local tty_path="${SPAWN_TTY_PATH:-/dev/tty}"
  local reply

  printf 'Type ERASE %s to destroy the selected disk: ' "$serial" >&2
  if ! IFS= read -r reply <"$tty_path"; then
    die "disk erasure confirmation was not received" 65
    return $?
  fi
  if [[ "$reply" != "ERASE $serial" ]]; then
    die "disk erasure confirmation did not match exactly" 65
    return $?
  fi
}
