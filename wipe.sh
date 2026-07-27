#!/usr/bin/env bash
set -Eeuo pipefail

info() {
  printf '[ * ] %s\n' "$*"
}

error() {
  printf '[ ! ] %s\n' "$*" >&2
}

require_root() {
  if ((EUID != 0)); then
    error 'This script must be run as root.'
    return 1
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "Required command is unavailable: $1"
    return 1
  fi
}

list_disks() {
  lsblk --nodeps --paths --noheadings --output NAME,SIZE,TRAN,MODEL
}

disk_transport() {
  local disk="$1"
  local transport

  transport="$(lsblk --nodeps --noheadings --output TRAN "$disk")"
  printf '%s\n' "${transport//[[:space:]]/}"
}

choose_disk() {
  local -a disks=("$@")
  local choice index

  if ((${#disks[@]} == 0)); then
    error 'No disks found.'
    return 1
  fi

  info 'Available disks:'
  for index in "${!disks[@]}"; do
    printf '%d) %s\n' "$((index + 1))" "${disks[index]}"
  done

  while :; do
    printf 'Choose disk: ' >&2
    if ! read -r choice; then
      return 1
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#disks[@]})); then
      SELECTED_DISK="${disks[choice - 1]%% *}"
      return 0
    fi

    error 'Invalid selection.'
  done
}

choose_method() {
  local choice

  info 'Wipe methods:'
  printf '%s\n' '1) Full zero pass (dd)'
  printf '%s\n' '2) Firmware secure erase (SATA/NVMe)'

  while :; do
    printf 'Choose method: ' >&2
    if ! read -r choice; then
      return 1
    fi

    case "$choice" in
      1)
        SELECTED_METHOD=zero
        return 0
        ;;
      2)
        SELECTED_METHOD=firmware
        return 0
        ;;
      *)
        error 'Invalid selection.'
        ;;
    esac
  done
}

confirm_wipe() {
  local reply

  printf 'Proceed with irreversible wipe? [y/N] ' >&2
  read -r reply
  [[ "${reply,,}" == y || "${reply,,}" == yes ]]
}

zero_wipe() {
  local disk="$1"
  local bytes

  bytes="$(blockdev --getsize64 "$disk")"
  dd if=/dev/zero of="$disk" bs=64M "count=$bytes" \
    iflag=count_bytes status=progress conv=fsync
  sync
  info '100% - completed'
}

security_section() {
  awk '
    /^[[:space:]]*Security:[[:space:]]*$/ { in_security = 1; next }
    in_security && /^[^[:space:]]/ { exit }
    in_security { print }
  ' <<<"$1"
}

sata_secure_erase() {
  local disk="$1"
  local identify security

  require_command hdparm
  identify="$(hdparm -I "$disk")"
  security="$(security_section "$identify")"

  if ! grep -Eq '^[[:space:]]+supported[[:space:]]*$' <<<"$security"; then
    error 'ATA Secure Erase is not supported by this disk.'
    return 1
  fi

  if ! grep -Eq '^[[:space:]]+not frozen[[:space:]]*$' <<<"$security"; then
    error 'ATA security is frozen; power-cycle the machine and try again.'
    return 1
  fi

  hdparm --user-master u --security-set-pass spawn-arch-wipe "$disk"
  hdparm --user-master u --security-erase spawn-arch-wipe "$disk"
  info '100% - completed'
}

nvme_controller() {
  local namespace="$1"

  if [[ ! "$namespace" =~ ^(/dev/nvme[0-9]+)n[0-9]+$ ]]; then
    return 1
  fi

  printf '%s\n' "${BASH_REMATCH[1]}"
}

nvme_sanitize_action() {
  local controller="$1"
  local json sanicap

  json="$(nvme id-ctrl "$controller" --output-format=json)"
  sanicap="$(sed -nE \
    's/.*"sanicap"[[:space:]]*:[[:space:]]*"?((0x)?[0-9A-Fa-f]+)"?.*/\1/p' \
    <<<"$json")"

  [[ "$sanicap" =~ ^(0x)?[0-9A-Fa-f]+$ ]] || return 1
  if (((sanicap & 0x4) != 0)); then
    printf '%s\n' start-overwrite
  elif (((sanicap & 0x2) != 0)); then
    printf '%s\n' start-block-erase
  elif (((sanicap & 0x1) != 0)); then
    printf '%s\n' start-crypto-erase
  else
    return 1
  fi
}

wait_for_nvme_sanitize() {
  local controller="$1"
  local log sprog sstat percent status

  while :; do
    log="$(nvme sanitize-log "$controller")"
    sprog="$(sed -nE \
      's/.*\(SPROG\)[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' \
      <<<"$log")"
    sstat="$(sed -nE \
      's/.*\(SSTAT\)[[:space:]]*:[[:space:]]*(0x[0-9A-Fa-f]+|[0-9]+).*/\1/p' \
      <<<"$log")"

    if [[ ! "$sprog" =~ ^[0-9]+$ || ! "$sstat" =~ ^(0x)?[0-9A-Fa-f]+$ ]]; then
      error 'Could not parse NVMe sanitize status.'
      return 1
    fi

    percent=$((sprog * 100 / 65535))
    status=$((sstat & 0x7))
    printf '\r%3d%%' "$percent"

    case "$status" in
      1)
        printf '\n'
        info '100% - completed'
        return 0
        ;;
      2)
        sleep 1
        ;;
      3)
        printf '\n'
        error 'NVMe sanitize failed.'
        return 1
        ;;
      *)
        printf '\n'
        error "Unexpected NVMe sanitize status: $sstat"
        return 1
        ;;
    esac
  done
}

nvme_secure_erase() {
  local namespace="$1"
  local action controller

  require_command nvme
  if ! controller="$(nvme_controller "$namespace")"; then
    error "Could not determine an NVMe controller for $namespace."
    return 1
  fi

  if ! action="$(nvme_sanitize_action "$controller")"; then
    error 'NVMe controller does not support a sanitize operation.'
    return 1
  fi

  info "NVMe Sanitize action: ${action#start-}."
  nvme sanitize "$controller" "--sanact=$action"
  wait_for_nvme_sanitize "$controller"
}

firmware_wipe() {
  local disk="$1"
  local transport

  transport="$(disk_transport "$disk")"
  case "$transport" in
    sata)
      sata_secure_erase "$disk"
      ;;
    nvme)
      nvme_secure_erase "$disk"
      ;;
    *)
      error "Firmware secure erase is not supported for transport: ${transport:-unknown}"
      return 1
      ;;
  esac
}

main() {
  local -a disks

  require_root
  mapfile -t disks < <(list_disks)
  choose_disk "${disks[@]}"
  choose_method
  info "Selected disk: $SELECTED_DISK"
  info "Selected method: $SELECTED_METHOD"

  if ! confirm_wipe; then
    info 'Cancelled.'
    return 0
  fi

  case "$SELECTED_METHOD" in
    zero)
      zero_wipe "$SELECTED_DISK"
      ;;
    firmware)
      firmware_wipe "$SELECTED_DISK"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
