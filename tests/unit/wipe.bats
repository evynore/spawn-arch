#!/usr/bin/env bats

load ../helpers/load.bash

setup() {
  # shellcheck source=../../wipe.sh
  source "$REPO_ROOT/wipe.sh"

  CALL_LOG="$BATS_TEST_TMPDIR/calls.log"
  NVME_LOG_FILE="$BATS_TEST_TMPDIR/nvme-log-count"
  : >"$CALL_LOG"
  printf '0\n' >"$NVME_LOG_FILE"

  require_root() {
    :
  }

  lsblk() {
    if [[ "$*" == *'--output TRAN'* ]]; then
      printf '%s\n' "${DISK_TRANSPORT:-sata}"
      return 0
    fi

    cat <<'EOF'
/dev/nvme0n1 476.9G nvme Samsung SSD
/dev/sda 931.5G sata Crucial MX500
EOF
  }

  blockdev() {
    [[ "$1" == --getsize64 ]]
    printf '1073741824\n'
  }

  dd() {
    printf 'dd %s\n' "$*" >>"$CALL_LOG"
  }

  sync() {
    printf 'sync\n' >>"$CALL_LOG"
  }

  hdparm() {
    if [[ "$1" == -I ]]; then
      if [[ "${SATA_IDENTIFY_STATE:-normal}" == frozen ]]; then
        cat <<'EOF'
Security:
        supported
        frozen
EOF
      else
        cat <<'EOF'
Security:
        supported
        not frozen
EOF
      fi
      return 0
    fi

    printf 'hdparm %s\n' "$*" >>"$CALL_LOG"
  }

  nvme() {
    case "$1" in
      id-ctrl)
        printf '{"sanicap": %s}\n' "${NVME_SANICAP:-4}"
        ;;
      sanitize)
        printf 'nvme %s\n' "$*" >>"$CALL_LOG"
        ;;
      sanitize-log)
        local log_calls

        log_calls="$(<"$NVME_LOG_FILE")"
        log_calls=$((log_calls + 1))
        printf '%s\n' "$log_calls" >"$NVME_LOG_FILE"
        if [[ "${NVME_STATUS_MODE:-success}" == failed ]]; then
          cat <<'EOF'
Sanitize Progress                       (SPROG) : 32767
Sanitize Status                         (SSTAT) : 0x3
EOF
        elif ((log_calls == 1)); then
          cat <<'EOF'
Sanitize Progress                       (SPROG) : 32767
Sanitize Status                         (SSTAT) : 0x2
EOF
        else
          cat <<'EOF'
Sanitize Progress                       (SPROG) : 65535
Sanitize Status                         (SSTAT) : 0x1
EOF
        fi
        ;;
      *)
        return 1
        ;;
    esac
  }

  sleep() {
    :
  }
}

@test "empty confirmation aborts the wipe" {
  if printf '\n' | confirm_wipe; then
    false
  fi
}

@test "zero mode writes exactly the selected disk size and syncs" {
  zero_wipe /dev/sda

  run cat "$CALL_LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *'dd if=/dev/zero of=/dev/sda bs=64M count=1073741824 iflag=count_bytes status=progress conv=fsync'* ]]
  [[ "$output" == *sync* ]]
}

@test "rejected confirmation never calls dd" {
  main <<<$'1\n1\nn\n'

  [ ! -s "$CALL_LOG" ]
}

@test "invalid disk selection retries" {
  run bash -c 'printf "%s" "$1"' _ "$(main <<<$'9\n1\n1\nn\n' 2>&1)"

  [ "$status" -eq 0 ]
  [[ "$output" == *'Invalid selection'* ]]
}

@test "SATA firmware wipe runs security setup before erase" {
  sata_secure_erase /dev/sda

  run cat "$CALL_LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *'hdparm --user-master u --security-set-pass spawn-arch-wipe /dev/sda'* ]]
  [[ "$output" == *'hdparm --user-master u --security-erase spawn-arch-wipe /dev/sda'* ]]
}

@test "frozen SATA sends no security command" {
  SATA_IDENTIFY_STATE=frozen
  if sata_secure_erase /dev/sda; then
    false
  fi

  [ ! -s "$CALL_LOG" ]
}

@test "firmware wipe rejects USB before calling hdparm" {
  DISK_TRANSPORT=usb
  if firmware_wipe /dev/sda; then
    false
  fi

  [ ! -s "$CALL_LOG" ]
}

@test "NVMe overwrite sanitize uses the controller and completes" {
  nvme_secure_erase /dev/nvme0n1

  run cat "$CALL_LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *'nvme sanitize /dev/nvme0 --sanact=start-overwrite'* ]]
}

@test "NVMe without overwrite support never starts sanitize" {
  NVME_SANICAP=0
  if nvme_secure_erase /dev/nvme0n1; then
    false
  fi

  [ ! -s "$CALL_LOG" ]
}

@test "failed NVMe sanitize returns an error" {
  NVME_STATUS_MODE=failed
  if nvme_secure_erase /dev/nvme0n1; then
    false
  fi
}
