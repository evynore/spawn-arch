#!/usr/bin/env bats

load ../helpers/load

README="$REPO_ROOT/README.md"
RELEASE_SCRIPT="$REPO_ROOT/scripts/build-release-archive.sh"

init_release_repo() {
  local repo="$1"

  mkdir -p "$repo/scripts"
  cp "$RELEASE_SCRIPT" "$repo/scripts/build-release-archive.sh"
  chmod +x "$repo/scripts/build-release-archive.sh"
  printf 'dist/\n' >"$repo/.gitignore"
  printf 'payload\n' >"$repo/payload.txt"
  git -C "$repo" init -q
  git -C "$repo" config user.name 'Spawn Arch Tests'
  git -C "$repo" config user.email 'spawn-arch@example.invalid'
  git -C "$repo" add .
  GIT_AUTHOR_DATE=2026-07-16T00:00:00Z GIT_COMMITTER_DATE=2026-07-16T00:00:00Z \
    git -C "$repo" commit -q -m initial
}

@test "README presents the exact safe installation flow in order" {
  [ -s "$README" ]
  python3 - "$README" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
needles = [
    "iwctl",
    "timedatectl status",
    "releases/download/v0.1.0/spawn-arch-v0.1.0.tar.gz",
    "sha256sum -c spawn-arch-v0.1.0.tar.gz.sha256",
    "tar -xzf spawn-arch-v0.1.0.tar.gz",
    "./spawn-arch doctor",
    "./spawn-arch plan",
    "/run/spawn-arch/plan.json",
    "./spawn-arch install",
    "ERASE <serial-from-plan>",
    "./spawn-arch verify /mnt",
    "systemctl reboot",
    "LUKS passphrase",
    "Plasma Wayland",
    "sudo spawn-arch verify --bless",
]
position = -1
for needle in needles:
    found = text.find(needle, position + 1)
    if found < 0:
        raise SystemExit(f"missing or out of order: {needle}")
    position = found
PY

  run grep -Eiq 'curl[^\n|]*\|[[:space:]]*(ba)?sh|archive/refs/heads/main|easy-arch|CUDA|gaming setup' "$README"
  [ "$status" -eq 1 ]
  grep -Fq 'Do not reboot' "$README"
  grep -Fq './spawn-arch install --resume-finalize' "$README"
}

@test "README states the boot trust boundary and exact rescue commands" {
  grep -Fq 'root filesystem is encrypted with LUKS2' "$README"
  grep -Fq 'ESP, systemd-boot, UKIs, and boot-state JSON are unencrypted and unsigned' "$README"
  grep -Fq 'physical write access to the ESP can modify the boot chain' "$README"
  grep -Fq 'Secure Boot and TPM' "$README"
  grep -Fq 'installer never mounts or writes the Windows SSD' "$README"
  grep -Fq 'firmware boot menu' "$README"

  local command
  for command in \
    'sudo spawn-arch status' \
    'sudo spawn-arch snapshots list' \
    'sudo spawn-arch rollback latest' \
    'sudo spawn-arch rollback 7394' \
    'sudo spawn-arch verify' \
    'sudo spawn-arch verify --bless' \
    'sudo bootctl set-oneshot spawn-arch-last-good' \
    'systemctl reboot'; do
    grep -Fq "$command" "$README"
  done
  grep -Fq 'last-good does not switch the Btrfs root' "$README"
  grep -Fq 'default-subvolume transition' "$README"
}

@test "README documents explicit Windows boot sync and Breeze LUKS recovery" {
  grep -Fq 'sudo spawn-arch windows-boot sync' "$README"
  grep -Fq 'sudo spawn-arch windows-boot sync --source /dev/' "$README"
  grep -Fq 'read-only' "$README"
  grep -Fq 'EFI/Microsoft' "$README"
  grep -Fq 'already up to date' "$README"
  grep -Fq 'Microsoft UEFI CA' "$README"
  grep -Fq 'Breeze Plymouth' "$README"
  grep -Fq 'plymouth.enable=0 disablehooks=plymouth' "$README"
  grep -Fq 'wireless-regdb' "$README"
  grep -Fq 'rtkit' "$README"
  grep -Fq 'systemd-pcrlogin' "$README"
  grep -Fq 'network-online.target' "$README"
}

@test "README includes the complete GU606AX physical acceptance gate" {
  local command
  for command in \
    'uname -a' \
    'bootctl status' \
    'cat /proc/cmdline' \
    'findmnt --verify' \
    'findmnt -no SOURCE,FSTYPE,OPTIONS /' \
    'btrfs subvolume get-default /' \
    'swapon --show' \
    'powerprofilesctl get' \
    "loginctl show-session \"\$XDG_SESSION_ID\" -p Type -p Desktop" \
    'glxinfo -B' \
    'vulkaninfo --summary' \
    'prime-run glxinfo -B' \
    'nvidia-smi' \
    'systemctl --failed' \
    'journalctl -b -p warning'; do
    grep -Fq "$command" "$README"
  done
  grep -Fq 'Intel is the default renderer' "$README"
  grep -Fq 'NVIDIA works through PRIME offload' "$README"
  grep -Fq 'zram is the only swap' "$README"
  grep -Fq 'Do not bless the boot' "$README"
}

@test "README documents KWallet first use and the managed Zsh override boundary" {
  grep -Fq 'ksshaskpass' "$README"
  grep -Fq 'Remember password' "$README"
  grep -Fq 'password-based Plasma login' "$README"
  grep -Fq 'fingerprint-only login' "$README"
  grep -Fq 'AddKeysToAgent yes' "$README"
  grep -Fq '/etc/zsh/zshrc' "$README"
  grep -Fq '/etc/starship.toml' "$README"
  grep -Fq '~/.zshrc' "$README"
  grep -Fq 'FiraCode Nerd Font Mono' "$README"
  grep -Fq 'not selected automatically' "$README"
}

@test "release builder creates deterministic tagged archives with provenance" {
  local repo="$BATS_TEST_TMPDIR/release" archive first_hash second_hash commit
  init_release_repo "$repo"
  GIT_COMMITTER_DATE=2026-07-16T00:00:00Z git -C "$repo" tag -a v0.1.0 -m v0.1.0

  run "$repo/scripts/build-release-archive.sh" v0.1.0
  [ "$status" -eq 0 ]

  archive="$repo/dist/spawn-arch-v0.1.0.tar.gz"
  [ -s "$archive" ]
  [ -s "$archive.sha256" ]
  [ -s "$repo/dist/spawn-arch-v0.1.0-INSTALL.txt" ]
  (cd "$repo/dist" && sha256sum -c spawn-arch-v0.1.0.tar.gz.sha256)
  commit="$(git -C "$repo" rev-parse HEAD)"
  [ "$(tar -xOf "$archive" spawn-arch-v0.1.0/SOURCE_COMMIT)" = "$commit" ]
  grep -Fq "https://github.com/evynore/spawn-arch/releases/download/v0.1.0/spawn-arch-v0.1.0.tar.gz" \
    "$repo/dist/spawn-arch-v0.1.0-INSTALL.txt"
  first_hash="$(sha256sum "$archive" | awk '{print $1}')"

  "$repo/scripts/build-release-archive.sh" v0.1.0 >/dev/null
  second_hash="$(sha256sum "$archive" | awk '{print $1}')"
  [ "$first_hash" = "$second_hash" ]
  [ -z "$(git -C "$repo" status --porcelain --untracked-files=normal)" ]
}

@test "release builder rejects lightweight tags dirty trees and tags away from HEAD" {
  local repo="$BATS_TEST_TMPDIR/rejections"
  init_release_repo "$repo"
  git -C "$repo" tag v0.1.0

  run "$repo/scripts/build-release-archive.sh" v0.1.0
  [ "$status" -ne 0 ]
  [[ "$output" == *'annotated tag'* ]]

  git -C "$repo" tag -d v0.1.0 >/dev/null
  GIT_COMMITTER_DATE=2026-07-16T00:00:00Z git -C "$repo" tag -a v0.1.0 -m v0.1.0
  printf 'dirty\n' >>"$repo/payload.txt"
  run "$repo/scripts/build-release-archive.sh" v0.1.0
  [ "$status" -ne 0 ]
  [[ "$output" == *'clean tree'* ]]

  git -C "$repo" restore payload.txt
  printf 'second\n' >"$repo/second.txt"
  git -C "$repo" add second.txt
  GIT_AUTHOR_DATE=2026-07-16T00:00:01Z GIT_COMMITTER_DATE=2026-07-16T00:00:01Z \
    git -C "$repo" commit -q -m second
  run "$repo/scripts/build-release-archive.sh" v0.1.0
  [ "$status" -ne 0 ]
  [[ "$output" == *'point at HEAD'* ]]
}
