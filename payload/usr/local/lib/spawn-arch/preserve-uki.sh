#!/usr/bin/env bash

_spawn_preserve_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=payload/usr/local/lib/spawn-arch/boot-state.sh
source "$_spawn_preserve_dir/boot-state.sh"
# shellcheck source=payload/usr/local/lib/spawn-arch/uki.sh
source "$_spawn_preserve_dir/uki.sh"

_preserve_read_targets() {
  local output_name="$1"
  local target serialized
  local -a targets=()
  local -A allowed=(
    [linux]=1 ["linux-firmware"]=1 ["intel-ucode"]=1 ["nvidia-open"]=1
    ["nvidia-utils"]=1 [mkinitcpio]=1 [systemd]=1 [cryptsetup]=1 ["btrfs-progs"]=1
  )

  mapfile -t targets
  ((${#targets[@]} > 0)) || return 65
  for target in "${targets[@]}"; do
    [[ -n "$target" && -n "${allowed[$target]:-}" ]] || return 65
  done
  serialized="$(jq -cn --args '$ARGS.positional | unique | sort' "${targets[@]}")" || return $?
  printf -v "$output_name" '%s' "$serialized"
}

_preserve_validate_pre_snapshot() {
  local snapshot_id="$1"
  local csv_path

  csv_path="$(mktemp "$(_boot_runtime_dir)/snapper-pre.XXXXXX.csv")" || return $?
  if ! LC_ALL=C snapper -c root --csvout --no-headers --columns number,pre-number list --type pre-post >"$csv_path"; then
    rm -f -- "$csv_path"
    return 65
  fi
  if ! python3 - "$csv_path" "$snapshot_id" <<'PY'; then
import csv
import pathlib
import sys

rows = list(csv.reader(pathlib.Path(sys.argv[1]).open(encoding="utf-8", newline="")))
matches = [row for row in rows if len(row) == 2 and row[0] == sys.argv[2] and row[1] == ""]
raise SystemExit(0 if len(matches) == 1 else 65)
PY
    rm -f -- "$csv_path"
    return 65
  fi
  rm -f -- "$csv_path"
}

_preserve_build_transaction() {
  local state="$1"
  local packages_json="$2"
  local snapshot_id="$3"
  local staged_path="$4"
  local new_hash="$5"
  local operation_id old_hash new_state created_at

  operation_id="$(</proc/sys/kernel/random/uuid)" || return $?
  old_hash="$(jq -r '.last_good.sha256' <<<"$state")" || return $?
  created_at="${SPAWN_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  new_state="$(jq \
    --arg hash "$new_hash" \
    --arg created_at "$created_at" \
    --argjson snapshot_id "$snapshot_id" \
    --argjson packages "$packages_json" '
      .generation += 1 |
      .current.blessed = false |
      .last_good.sha256 = $hash |
      .pending = {
        kind: "pacman",
        pre_snapshot_id: $snapshot_id,
        previous_current_sha256: .current.sha256,
        packages: $packages,
        created_at: $created_at
      }
    ' <<<"$state")" || return $?
  jq -n \
    --arg operation_id "$operation_id" \
    --argjson base_generation "$(jq -r '.generation' <<<"$state")" \
    --arg temp_basename "$(basename -- "$staged_path")" \
    --arg previous_basename ".spawn-arch-last-good.efi.previous-$operation_id" \
    --arg old_hash "$old_hash" \
    --arg new_hash "$new_hash" \
    --argjson new_state "$new_state" '{
      schema_version: 1,
      operation_id: $operation_id,
      kind: "preserve",
      base_generation: $base_generation,
      phase: "prepared",
      old_btrfs_default: null,
      artifacts: [{
        temp_basename: $temp_basename,
        final_basename: "spawn-arch-last-good.efi",
        previous_basename: $previous_basename,
        old_sha256: $old_hash,
        new_sha256: $new_hash
      }],
      new_state: $new_state
    }'
}

preserve_uki_main() {
  local packages_json state selected current_path last_good_path expected_cmdline
  local current_hash last_good_hash snapshot_id staged_path new_hash transaction status

  _boot_prepare_directories || return $?
  if [[ -e "$(_boot_loader_dir)/spawn-arch-rollback.json" ]]; then
    # shellcheck source=payload/usr/local/lib/spawn-arch/rollback.sh
    source "$_spawn_preserve_dir/rollback.sh"
    rollback_recover || return $?
  fi
  boot_transaction_recover || return $?
  _preserve_read_targets packages_json || {
    die "pacman supplied an invalid boot-critical target set" 65
    return $?
  }
  state="$(boot_state_read)" || return $?
  if [[ "$(jq -r '.current.blessed' <<<"$state")" != true || "$(jq -r '.pending == null' <<<"$state")" != true ]]; then
    die "a blessed current boot with no pending operation is required" 75
    return $?
  fi
  selected="$(boot_selected_entry)" || return $?
  [[ "$selected" == spawn-arch-current ]] || {
    die "boot-critical updates are allowed only from current" 75
    return $?
  }

  current_path="$(_boot_efi_linux_dir)/spawn-arch-current.efi"
  last_good_path="$(_boot_efi_linux_dir)/spawn-arch-last-good.efi"
  expected_cmdline="$(<"$(installed_etc_root)/kernel/cmdline")" || return $?
  current_hash="$(sha256_file "$current_path")" || return $?
  last_good_hash="$(sha256_file "$last_good_path")" || return $?
  [[ "$current_hash" == "$(jq -r '.current.sha256' <<<"$state")" ]] || {
    die "current UKI differs from its blessed hash" 75
    return $?
  }
  [[ "$last_good_hash" == "$(jq -r '.last_good.sha256' <<<"$state")" ]] || {
    die "last-good UKI differs from durable state" 75
    return $?
  }
  uki_validate "$current_path" "$expected_cmdline" current || return $?
  uki_validate "$last_good_path" "$expected_cmdline" last-good || return $?

  [[ -r "${SPAWN_SNAP_PAC_PREFILE:-/tmp/snap-pac-pre_root}" ]] || return 75
  snapshot_id="$(<"${SPAWN_SNAP_PAC_PREFILE:-/tmp/snap-pac-pre_root}")"
  [[ "$snapshot_id" =~ ^[1-9][0-9]*$ ]] || return 75
  _preserve_validate_pre_snapshot "$snapshot_id" || return $?

  staged_path="$(uki_prepare_last_good "$current_path" "$last_good_path" "$expected_cmdline")" || return $?
  _boot_test_pause_checkpoint last_good_temp || return $?
  new_hash="$(sha256_file "$staged_path")" || return $?
  transaction="$(_preserve_build_transaction "$state" "$packages_json" "$snapshot_id" "$staged_path" "$new_hash")" || return $?
  boot_transaction_begin "$transaction" || return $?
  if boot_transaction_recover; then
    status=0
  else
    status=$?
    if ! boot_transaction_abort; then
      die "UKI preservation failed and automatic restoration is incomplete" 70
      return $?
    fi
    return "$status"
  fi
  uki_validate "$last_good_path" "$expected_cmdline" last-good || return $?
  state="$(boot_state_read)" || return $?
  jq -e --arg hash "$new_hash" --argjson snapshot_id "$snapshot_id" '
    .current.blessed == false and .last_good.sha256 == $hash and
    .pending.kind == "pacman" and .pending.pre_snapshot_id == $snapshot_id
  ' >/dev/null <<<"$state"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
  if ((EUID != 0)); then
    die "UKI preservation requires root" 77
    exit $?
  fi
  preserve_uki_main
fi
