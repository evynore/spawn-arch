#!/usr/bin/env bats

load ../helpers/load.bash

@test "defaults pin the approved workstation profile" {
  run jq -e '
    .hostname == "spawn" and
    .timezone == "Etc/UTC" and
    .keymap == "us" and
    .locale.primary == "en_US.UTF-8" and
    .locale.generated == ["en_US.UTF-8", "ru_RU.UTF-8"] and
    .archinstall.minimum == "4.4.0" and
    .archinstall.maximum_exclusive == "4.5.0" and
    .storage.esp_bytes == 2147483648 and
    .storage.btrfs_options == ["noatime", "compress=zstd:1", "nodiscard"]
  ' "$REPO_ROOT/config/defaults.json"

  [ "$status" -eq 0 ]
}

@test "package set contains the approved balanced workstation baseline and no expanded scope" {
  run bash -c '
    for package in \
      nvidia-open vulkan-intel power-profiles-daemon \
      pipewire pipewire-audio pipewire-alsa pipewire-pulse wireplumber \
      rtkit wireless-regdb plymouth breeze-plymouth \
      git openssh ksshaskpass kwallet-pam \
      zsh zsh-completions starship ttf-firacode-nerd \
      docker docker-compose nvidia-container-toolkit pacman-contrib arch-audit \
      zed telegram-desktop spectacle chromium \
      vivaldi vivaldi-ffmpeg-codecs yakuake \
      firewall-config firewall-applet openai-codex \
      nodejs rust protobuf; do
      grep -Fx "$package" "$1" || exit 1
    done
  ' _ "$REPO_ROOT/config/packages.txt"
  [ "$status" -eq 0 ]

  run grep -E '^(steam|wine|podman|cuda|dracut|tlp|auto-cpufreq|asusctl|openssh-server|oh-my-zsh)$' "$REPO_ROOT/config/packages.txt"
  [ "$status" -eq 1 ]
}

@test "package parser rejects duplicates" {
  load_lib config
  printf 'linux\nlinux\n' >"$BATS_TEST_TMPDIR/packages.txt"

  run packages_json "$BATS_TEST_TMPDIR/packages.txt"

  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate package: linux"* ]]
}
