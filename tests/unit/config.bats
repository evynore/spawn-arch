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

@test "package set contains the approved Hyprland workstation baseline and no KDE desktop" {
  run bash -c '
    for package in \
      nvidia-open vulkan-intel power-profiles-daemon \
      pipewire pipewire-audio pipewire-alsa pipewire-pulse wireplumber \
      rtkit wireless-regdb plymouth breeze-plymouth \
      git openssh \
      zsh zsh-completions starship inter-font ttf-jetbrains-mono \
      docker docker-compose nvidia-container-toolkit pacman-contrib arch-audit \
      hyprland uwsm greetd greetd-regreet cage \
      quickshell hyprlauncher hyprlock hypridle hyprpolkitagent \
      xdg-desktop-portal xdg-desktop-portal-hyprland xdg-desktop-portal-gtk \
      swaync cliphist wl-clipboard hyprshot hyprpaper foot \
      zed telegram-desktop chromium vivaldi vivaldi-ffmpeg-codecs \
      thunar gvfs tumbler firewall-config brightnessctl openai-codex \
      nodejs rust protobuf; do
      grep -Fx "$package" "$1" || exit 1
    done
  ' _ "$REPO_ROOT/config/packages.txt"
  [ "$status" -eq 0 ]

  run grep -E '^(plasma-meta|plasma-login-manager|dolphin|konsole|kate|ark|spectacle|yakuake|xdg-desktop-portal-kde|ksshaskpass|kwallet-pam)$' "$REPO_ROOT/config/packages.txt"
  [ "$status" -eq 1 ]

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
