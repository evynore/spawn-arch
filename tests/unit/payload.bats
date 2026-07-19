#!/usr/bin/env bats

load ../helpers/load

setup() {
  PAYLOAD_ETC="$REPO_ROOT/payload/etc"
}

@test "wheel sudo requires a password" {
  run grep -Fx '%wheel ALL=(ALL:ALL) ALL' "$PAYLOAD_ETC/sudoers.d/10-wheel"
  [ "$status" -eq 0 ]
  run grep -R -E 'NOPASSWD|!authenticate' "$PAYLOAD_ETC/sudoers.d"
  [ "$status" -eq 1 ]
}

@test "zram policy is exactly half RAM with zstd at priority 100" {
  diff -u <(printf '%s\n' \
    '[zram0]' \
    'zram-size = ram / 2' \
    'compression-algorithm = zstd' \
    'swap-priority = 100') \
    "$PAYLOAD_ETC/systemd/zram-generator.conf"
}

@test "Btrfs scrub is monthly persistent and randomized by at most six hours" {
  grep -Fx 'ExecStart=/usr/bin/btrfs scrub start -B /' \
    "$PAYLOAD_ETC/systemd/system/spawn-arch-btrfs-scrub.service"
  grep -Fx 'OnCalendar=monthly' "$PAYLOAD_ETC/systemd/system/spawn-arch-btrfs-scrub.timer"
  grep -Fx 'Persistent=true' "$PAYLOAD_ETC/systemd/system/spawn-arch-btrfs-scrub.timer"
  grep -Fx 'RandomizedDelaySec=6h' "$PAYLOAD_ETC/systemd/system/spawn-arch-btrfs-scrub.timer"
  [ ! -e "$PAYLOAD_ETC/systemd/system/spawn-arch-fstrim.timer" ]
}

@test "Snapper is root-only numeric cleanup without qgroups or timeline" {
  local config="$PAYLOAD_ETC/snapper/configs/root"
  grep -Fx 'SUBVOLUME="/"' "$config"
  grep -Fx 'TIMELINE_CREATE="no"' "$config"
  grep -Fx 'TIMELINE_CLEANUP="no"' "$config"
  grep -Fx 'NUMBER_LIMIT="20"' "$config"
  grep -Fx 'NUMBER_LIMIT_IMPORTANT="10"' "$config"
  grep -Fx 'NUMBER_MIN_AGE="3600"' "$config"
  grep -Fx 'QGROUP=""' "$config"
  [ ! -e "$PAYLOAD_ETC/snapper/configs/home" ]
  grep -Fx 'important_packages = ["linux", "linux-firmware", "intel-ucode", "nvidia-open", "nvidia-utils", "mkinitcpio", "systemd", "cryptsetup", "btrfs-progs"]' \
    "$PAYLOAD_ETC/snap-pac.ini"
}

@test "UKI metadata names current and last-good while keeping identity stable" {
  local current="$PAYLOAD_ETC/spawn-arch/uki-current.os-release"
  local last_good="$PAYLOAD_ETC/spawn-arch/uki-last-good.os-release"
  grep -Fx 'PRETTY_NAME="Spawn Arch (current)"' "$current"
  grep -Fx 'VERSION_ID="current"' "$current"
  grep -Fx 'PRETTY_NAME="Spawn Arch (last-good)"' "$last_good"
  grep -Fx 'VERSION_ID="lg"' "$last_good"
  diff -u <(grep -Ev '^(PRETTY_NAME|VERSION_ID)=' "$current") \
    <(grep -Ev '^(PRETTY_NAME|VERSION_ID)=' "$last_good")
}

@test "mkinitcpio uses Breeze Plymouth before sd-encrypt without forcing GPU modules" {
  local config="$PAYLOAD_ETC/mkinitcpio.conf.d/spawn-arch.conf"
  grep -Fx 'MODULES=()' "$config"
  grep -Fx 'HOOKS=(base systemd plymouth autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)' "$config"
  diff -u <(printf '%s\n' \
    '[Daemon]' \
    'Theme=breeze' \
    'DeviceScale=2') \
    "$PAYLOAD_ETC/plymouth/plymouthd.conf"
  run grep -Ei 'MODULES=.*(nvidia|i915|xe)' "$config"
  [ "$status" -eq 1 ]
}

@test "power profile relies on daemon defaults and persisted user choice without a custom boot unit" {
  [ ! -e "$PAYLOAD_ETC/systemd/system/spawn-arch-initial-power-profile.service" ]
}

@test "Docker starts after firewalld and network-online while both remain wanted" {
  local dropin="$PAYLOAD_ETC/systemd/system/docker.service.d/10-spawn-arch-ordering.conf"
  diff -u <(printf '%s\n' \
    '[Unit]' \
    'Wants=network-online.target firewalld.service' \
    'After=network-online.target firewalld.service') \
    "$dropin"
}

@test "unused systemd pcrlogin is conditionally disabled without changing TPM state" {
  local dropin="$PAYLOAD_ETC/systemd/system/systemd-pcrlogin@.service.d/10-spawn-arch-disable.conf"
  diff -u <(printf '%s\n' \
    '[Unit]' \
    'ConditionPathExists=/var/lib/spawn-arch/enable-pcrlogin') \
    "$dropin"
}

@test "Docker is local-only sudo-managed with an opt-in NVIDIA runtime and bounded logs" {
  jq -e '
    . == {
      "live-restore": true,
      "log-driver": "local",
      "log-opts": {"max-file": "3", "max-size": "20m"},
      "no-new-privileges": true,
      "runtimes": {
        "nvidia": {
          "args": [],
          "path": "nvidia-container-runtime"
        }
      }
    } and
    (has("hosts") | not) and
    (has("default-runtime") | not)
  ' "$PAYLOAD_ETC/docker/daemon.json"
}

@test "SSH agent and KWallet askpass use the managed session contract" {
  diff -u <(printf '%s\n' \
    'SSH_AUTH_SOCK=${XDG_RUNTIME_DIR}/ssh-agent.socket' \
    'SSH_ASKPASS=/usr/bin/ksshaskpass' \
    'SSH_ASKPASS_REQUIRE=prefer') \
    "$PAYLOAD_ETC/environment.d/10-ssh-agent.conf"

  diff -u <(printf '%s\n' \
    'Host *' \
    '    AddKeysToAgent yes') \
    "$PAYLOAD_ETC/ssh/ssh_config.d/20-spawn-arch-agent.conf"
}

@test "Zsh and Starship use immutable system configuration without user dotfiles" {
  diff -u <(printf '%s\n' 'STARSHIP_CONFIG=/etc/starship.toml') \
    "$PAYLOAD_ETC/environment.d/20-starship.conf"

  local zshrc="$PAYLOAD_ETC/zsh/zshrc"
  grep -Fx 'if [[ -o interactive ]]; then' "$zshrc"
  grep -F '${XDG_CACHE_HOME:-$HOME/.cache}/zsh' "$zshrc"
  grep -Fx '  autoload -Uz compinit' "$zshrc"
  grep -F 'compinit -d ' "$zshrc"
  grep -Fx '  eval "$(starship init zsh)"' "$zshrc"
  grep -Fx 'fi' "$zshrc"

  run grep -R -E -i \
    'oh-my-zsh|plugin manager|/home/[^/]+/\.zshrc|/root/\.zshrc|\.config/starship\.toml' \
    "$REPO_ROOT/payload"
  [ "$status" -eq 1 ]

  run sha256sum "$PAYLOAD_ETC/starship.toml"
  [ "$status" -eq 0 ]
  [[ "$output" == '04f185c124b48f0d4320adeed0f7471add110fcda6594b352ed464eb95bf1ed3 '* ]]
}

@test "firewalld ships a closed workstation zone" {
  local zone="$PAYLOAD_ETC/firewalld/zones/spawn-workstation.xml"

  grep -Fx '<zone target="DROP">' "$zone"
  grep -Fx '  <short>Spawn Workstation</short>' "$zone"
  run grep -E '<(service|port|source-port|forward-port|masquerade)([ >])' "$zone"
  [ "$status" -eq 1 ]
}

@test "journald is persistent compressed and bounded" {
  diff -u <(printf '%s\n' \
    '[Journal]' \
    'Storage=persistent' \
    'Compress=yes' \
    'SystemMaxUse=1G' \
    'SystemKeepFree=2G' \
    'MaxRetentionSec=30day' \
    'MaxFileSec=7day' \
    'ForwardToSyslog=no') \
    "$PAYLOAD_ETC/systemd/journald.conf.d/10-spawn-arch.conf"
}

@test "sysctl policy contains only the approved low-risk hardening" {
  diff -u <(printf '%s\n' \
    'kernel.dmesg_restrict = 1' \
    'kernel.kptr_restrict = 2' \
    'kernel.yama.ptrace_scope = 1' \
    'fs.suid_dumpable = 0' \
    'net.ipv4.conf.all.accept_redirects = 0' \
    'net.ipv4.conf.default.accept_redirects = 0' \
    'net.ipv6.conf.all.accept_redirects = 0' \
    'net.ipv6.conf.default.accept_redirects = 0' \
    'net.ipv4.conf.all.send_redirects = 0' \
    'net.ipv4.conf.default.send_redirects = 0') \
    "$PAYLOAD_ETC/sysctl.d/60-spawn-arch-security.conf"
}

@test "payload contains no deferred or scope-expanding policy" {
  run grep -R -E -i \
    '(^|[^[:alnum:]])tlp([^[:alnum:]]|$)|hibernate|resume=|tpm|secure[ -]?boot|nvidia.{0,20}primary|rootflags=|subvolid=|subvol=@' \
    "$PAYLOAD_ETC"
  [ "$status" -eq 1 ]
}

@test "payload installs only the pacman hook adapter as executable" {
  local target="$BATS_TEST_TMPDIR/target"

  mkdir -p "$target"
  load_lib payload
  payload_install "$target"

  [ -x "$target/usr/local/bin/spawn-arch" ]
  [ -x "$target/usr/local/lib/spawn-arch/preserve-uki.sh" ]
  [ ! -x "$target/usr/local/lib/spawn-arch/boot-state.sh" ]
  [ ! -x "$target/usr/local/lib/spawn-arch/hardware-verify.sh" ]
  [ ! -x "$target/usr/local/lib/spawn-arch/uki.sh" ]
  [ ! -x "$target/usr/local/lib/spawn-arch/verify.sh" ]
}
