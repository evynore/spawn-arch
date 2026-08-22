#!/usr/bin/env bats

load ../helpers/load

setup() {
  load_lib preflight
}

@test "kernel gate requires Linux 7.2 or newer" {
  run assert_linux_kernel_version 7.2
  [ "$status" -eq 0 ]

  run assert_linux_kernel_version 7.2.0
  [ "$status" -eq 0 ]

  run assert_linux_kernel_version 7.2.1.arch1-1
  [ "$status" -eq 0 ]

  run assert_linux_kernel_version 7.1.5-arch1-2
  [ "$status" -eq 65 ]
  [[ "$output" == *"required Linux kernel >= 7.2.0"* ]]
}

@test "doctor rejects a stable Linux kernel below 7.2 before planning" {
  FAKE_EFI_DIR="$BATS_TEST_TMPDIR/efi"
  FAKE_EFIVARFS_DIR="$FAKE_EFI_DIR/efivars"
  mkdir -p "$FAKE_EFIVARFS_DIR"
  FAKE_EUID=0
  FAKE_NETWORK_OK=true
  FAKE_CLOCK_EPOCH=1784160000
  FAKE_ARCHINSTALL_VERSION=4.4
  FAKE_LINUX_KERNEL_VERSION=7.1.5-arch1-2
  FAKE_REQUIRED_COMMANDS_OK=true
  FAKE_UNAME_M=x86_64

  run doctor_assert_installable

  [ "$status" -eq 69 ]
  [[ "$output" == *"linux_kernel"* ]]
}

@test "doctor keeps JSON valid when Linux repository metadata refresh fails" {
  FAKE_EFI_DIR="$BATS_TEST_TMPDIR/efi"
  FAKE_EFIVARFS_DIR="$FAKE_EFI_DIR/efivars"
  mkdir -p "$FAKE_EFIVARFS_DIR"
  FAKE_EUID=0
  FAKE_NETWORK_OK=true
  FAKE_CLOCK_EPOCH=1784160000
  FAKE_ARCHINSTALL_VERSION=4.4
  FAKE_REQUIRED_COMMANDS_OK=true
  FAKE_UNAME_M=x86_64
  pacman() {
    printf '%s\n' 'simulated package metadata failure' >&2
    return 1
  }
  export -f pacman

  run doctor_collect_json

  [ "$status" -eq 0 ]
  jq -e '.checks.linux_kernel == {
    ok: false,
    required: true,
    detail: "unavailable"
  }' <<<"$output"
}

@test "kernel candidate refreshes package metadata before reporting stable linux" {
  pacman() {
    case "$*" in
      '-Sy --noconfirm') PACMAN_WAS_SYNCED=true ;;
      '-Si linux')
        if [[ "${PACMAN_WAS_SYNCED:-false}" == true ]]; then
          printf '%s\n' 'Version         : 7.2.1.arch1-1'
        else
          printf '%s\n' 'Version         : 7.1.5-arch1-2'
        fi
        ;;
      *) return 1 ;;
    esac
  }
  export -f pacman

  run _linux_kernel_available_version

  [ "$status" -eq 0 ]
  [ "$output" = '7.2.1.arch1-1' ]
}

@test "accepts official Archinstall 4.4 and package-style 4.4.x versions" {
  run assert_archinstall_version 4.4
  [ "$status" -eq 0 ]
  run assert_archinstall_version 4.4.0
  [ "$status" -eq 0 ]
  run assert_archinstall_version 4.4.9
  [ "$status" -eq 0 ]
  run assert_archinstall_version 4.4.0-1
  [ "$status" -eq 0 ]

  run assert_archinstall_version 4.3.9
  [ "$status" -ne 0 ]
  run assert_archinstall_version 4.5.0
  [ "$status" -ne 0 ]
  run assert_archinstall_version v4.4.0
  [ "$status" -ne 0 ]
}

@test "extracts official and package-style Archinstall 4.4 CLI versions" {
  archinstall() {
    printf '%s\n' 'archinstall 4.4'
  }
  export -f archinstall

  run _archinstall_version

  [ "$status" -eq 0 ]
  [ "$output" = "4.4" ]

  archinstall() {
    printf '%s\n' 'archinstall 4.4.0-1'
  }
  export -f archinstall

  run _archinstall_version

  [ "$status" -eq 0 ]
  [ "$output" = "4.4.0-1" ]
}

@test "version fixture documents every compatibility boundary" {
  while IFS=$'\t' read -r version expected; do
    [[ "$version" == \#* ]] && continue
    run assert_archinstall_version "$version"
    if [[ "$expected" == accept ]]; then
      [ "$status" -eq 0 ]
    else
      [ "$status" -ne 0 ]
    fi
  done <"$REPO_ROOT/tests/fixtures/preflight/archinstall-versions.tsv"
}

@test "doctor rejects legacy boot and a non-root caller" {
  FAKE_EFI_DIR="$BATS_TEST_TMPDIR/missing"
  FAKE_EFIVARFS_DIR="$BATS_TEST_TMPDIR/missing"
  FAKE_EUID=1000
  FAKE_NETWORK_OK=true
  FAKE_CLOCK_EPOCH=1784160000
  FAKE_ARCHINSTALL_VERSION=4.4
  FAKE_REQUIRED_COMMANDS_OK=true
  FAKE_UNAME_M=x86_64

  run doctor_assert_installable

  [ "$status" -ne 0 ]
  [[ "$output" == *"root"* ]]
  [[ "$output" == *"uefi"* ]]
}

@test "doctor report exposes all hard gates and hardware hints" {
  FAKE_EFI_DIR="$BATS_TEST_TMPDIR/efi"
  FAKE_EFIVARFS_DIR="$FAKE_EFI_DIR/efivars"
  mkdir -p "$FAKE_EFIVARFS_DIR"
  FAKE_EUID=0
  FAKE_NETWORK_OK=true
  FAKE_CLOCK_EPOCH=1784160000
  FAKE_ARCHINSTALL_VERSION=4.4
  FAKE_LINUX_KERNEL_VERSION=7.2.1.arch1-1
  FAKE_REQUIRED_COMMANDS_OK=true
  FAKE_UNAME_M=x86_64

  run doctor_collect_json

  [ "$status" -eq 0 ]
  jq -e '
    [.checks | keys[]] as $keys |
    [
      "root", "uefi", "efivarfs", "network", "clock",
      "archinstall_version", "linux_kernel", "required_commands", "x86_64",
      "intel_cpu_hint", "intel_gpu_hint", "nvidia_gpu_hint",
      "memory_64g_hint", "target_model_hint"
    ] - $keys | length == 0
  ' <<<"$output"
}
