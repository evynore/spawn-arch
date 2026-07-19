#!/usr/bin/env bats

load ../helpers/load

setup() {
  load_lib preflight
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
  FAKE_REQUIRED_COMMANDS_OK=true
  FAKE_UNAME_M=x86_64

  run doctor_collect_json

  [ "$status" -eq 0 ]
  jq -e '
    [.checks | keys[]] as $keys |
    [
      "root", "uefi", "efivarfs", "network", "clock",
      "archinstall_version", "required_commands", "x86_64",
      "intel_cpu_hint", "intel_gpu_hint", "nvidia_gpu_hint",
      "memory_64g_hint", "target_model_hint"
    ] - $keys | length == 0
  ' <<<"$output"
}
