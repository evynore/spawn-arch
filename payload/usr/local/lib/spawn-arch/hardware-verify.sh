#!/usr/bin/env bash

hardware_root_observations() {
  local filesystem source options active_output default_output active_id default_id

  filesystem="$(findmnt -n -o FSTYPE --target /)" || return $?
  source="$(findmnt -n -o SOURCE --target /)" || return $?
  options="$(findmnt -n -o OPTIONS --target /)" || return $?
  active_output="$(LC_ALL=C btrfs subvolume show /)" || return $?
  default_output="$(LC_ALL=C btrfs subvolume get-default /)" || return $?
  active_id="$(btrfs_subvolume_id_from_show "$active_output")" || return $?
  default_id="$(awk '$1 == "ID" {print $2; exit}' <<<"$default_output")"
  [[ "$filesystem" == btrfs ]] || return 65
  [[ "$active_id" =~ ^[1-9][0-9]*$ && "$default_id" == "$active_id" ]] || return 65
  [[ "$options" != *subvol=* && "$options" != *subvolid=* ]] || return 65
  source="${source%%\[*}"
  jq -n \
    --arg source "$source" \
    --argjson active "$active_id" \
    --argjson default "$default_id" \
    '{source: $source, active_subvolume_id: $active, default_subvolume_id: $default}'
}

_session_property() {
  local properties="$1"
  local key="$2"

  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' <<<"$properties"
}

hardware_session_observations() {
  local session_id properties active remote type class user desktop leader uid environment_path environment
  local matched='[]'
  local -a session_ids=()

  mapfile -t session_ids < <(loginctl list-sessions --no-legend --no-pager | awk 'NF {print $1}')
  for session_id in "${session_ids[@]}"; do
    [[ "$session_id" =~ ^[A-Za-z0-9_-]+$ ]] || continue
    properties="$(loginctl show-session "$session_id" \
      --property=Active --property=Remote --property=Type --property=Class \
      --property=Name --property=Desktop --property=Leader)" || continue
    active="$(_session_property "$properties" Active)"
    remote="$(_session_property "$properties" Remote)"
    type="$(_session_property "$properties" Type)"
    class="$(_session_property "$properties" Class)"
    user="$(_session_property "$properties" Name)"
    desktop="$(_session_property "$properties" Desktop)"
    leader="$(_session_property "$properties" Leader)"
    [[ "$active" == yes && "$remote" == no && "$type" == wayland && "$class" == user ]] || continue
    [[ "$user" =~ ^[a-z_][a-z0-9_-]*$ && "$user" != root ]] || continue
    [[ "$desktop" =~ ([Kk][Dd][Ee]|[Pp]lasma) && "$leader" =~ ^[1-9][0-9]*$ ]] || continue
    uid="$(id -u "$user")" || continue
    [[ "$uid" =~ ^[1-9][0-9]*$ ]] || continue
    environment_path="${SPAWN_PROC_ROOT:-/proc}/$leader/environ"
    [[ -r "$environment_path" ]] || continue
    environment="$(
      python3 - "$environment_path" "$uid" <<'PY'
import json
import pathlib
import re
import sys

values = {}
for item in pathlib.Path(sys.argv[1]).read_bytes().split(b"\0"):
    if not item or b"=" not in item:
        continue
    key, value = item.split(b"=", 1)
    if key.decode("ascii", "strict") in {
        "XDG_RUNTIME_DIR", "WAYLAND_DISPLAY", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS",
        "SSH_AUTH_SOCK", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "STARSHIP_CONFIG"
    }:
        values[key.decode("ascii")] = value.decode("utf-8", "strict")
runtime = f"/run/user/{sys.argv[2]}"
valid = (
    values.get("XDG_RUNTIME_DIR") == runtime
    and re.fullmatch(r"wayland-[0-9]+", values.get("WAYLAND_DISPLAY", ""))
    and re.fullmatch(r":[0-9]+(?:\.[0-9]+)?", values.get("DISPLAY", ""))
    and values.get("DBUS_SESSION_BUS_ADDRESS") == f"unix:path={runtime}/bus"
    and values.get("SSH_AUTH_SOCK") == f"{runtime}/ssh-agent.socket"
    and values.get("SSH_ASKPASS") == "/usr/bin/ksshaskpass"
    and values.get("SSH_ASKPASS_REQUIRE") == "prefer"
    and values.get("STARSHIP_CONFIG") == "/etc/starship.toml"
)
if not valid:
    raise SystemExit(65)
print(json.dumps(values, sort_keys=True, separators=(",", ":")))
PY
    )" || continue
    matched="$(jq -c \
      --arg session_id "$session_id" --arg user "$user" --argjson uid "$uid" \
      --argjson environment "$environment" \
      '. + [{session_id: $session_id, user: $user, uid: $uid, environment: $environment}]' \
      <<<"$matched")" || return $?
  done
  [[ "$(jq 'length' <<<"$matched")" == 1 ]] || return 65
  jq -c '.[0]' <<<"$matched"
}

_hardware_run_in_session() {
  local session="$1"
  shift
  local user runtime wayland display dbus ssh_auth_sock ssh_askpass ssh_askpass_require starship_config

  user="$(jq -r '.user' <<<"$session")"
  runtime="$(jq -r '.environment.XDG_RUNTIME_DIR' <<<"$session")"
  wayland="$(jq -r '.environment.WAYLAND_DISPLAY' <<<"$session")"
  display="$(jq -r '.environment.DISPLAY' <<<"$session")"
  dbus="$(jq -r '.environment.DBUS_SESSION_BUS_ADDRESS' <<<"$session")"
  ssh_auth_sock="$(jq -r '.environment.SSH_AUTH_SOCK' <<<"$session")"
  ssh_askpass="$(jq -r '.environment.SSH_ASKPASS' <<<"$session")"
  ssh_askpass_require="$(jq -r '.environment.SSH_ASKPASS_REQUIRE' <<<"$session")"
  starship_config="$(jq -r '.environment.STARSHIP_CONFIG' <<<"$session")"
  runuser -u "$user" -- env -i \
    "XDG_RUNTIME_DIR=$runtime" \
    "WAYLAND_DISPLAY=$wayland" \
    "DISPLAY=$display" \
    "DBUS_SESSION_BUS_ADDRESS=$dbus" \
    "SSH_AUTH_SOCK=$ssh_auth_sock" \
    "SSH_ASKPASS=$ssh_askpass" \
    "SSH_ASKPASS_REQUIRE=$ssh_askpass_require" \
    "STARSHIP_CONFIG=$starship_config" \
    "$@"
}

hardware_check_selected_entry() {
  [[ "$(boot_selected_entry)" == spawn-arch-current ]]
}

hardware_check_current_uki() {
  local state="$1"
  local current_hash="$2"
  local expected_cmdline="$3"
  local current_path pending_kind

  current_path="$(_boot_efi_linux_dir)/spawn-arch-current.efi"
  [[ "$current_hash" =~ ^[0-9a-f]{64}$ ]] || return 65
  uki_validate "$current_path" "$expected_cmdline" current false || return $?
  pending_kind="$(jq -r '.pending.kind // empty' <<<"$state")"
  case "$pending_kind" in
    pacman)
      [[ "$(jq -r '.current.blessed' <<<"$state")" == false ]] || return 65
      [[ "$(jq -r '.current.sha256' <<<"$state")" == "$(jq -r '.pending.previous_current_sha256' <<<"$state")" ]]
      ;;
    rollback)
      [[ "$(jq -r '.current.blessed' <<<"$state")" == false ]] || return 65
      [[ "$(jq -r '.current.sha256' <<<"$state")" == "$current_hash" ]]
      ;;
    '') [[ "$(jq -r '.current.sha256' <<<"$state")" == "$current_hash" ]] ;;
    *) return 65 ;;
  esac
}

hardware_check_running_kernel() {
  local current_path embedded running

  current_path="$(_boot_efi_linux_dir)/spawn-arch-current.efi"
  embedded="$(uki_section_read "$current_path" .uname)" || return $?
  running="$(uname -r)" || return $?
  [[ "$embedded" == "$running" ]]
}

hardware_check_root_default() {
  local observations="$1"

  jq -e '
    (.active_subvolume_id | type == "number" and . >= 1) and
    .active_subvolume_id == .default_subvolume_id and
    (.source | type == "string" and length > 0)
  ' >/dev/null <<<"$observations"
}

hardware_check_luks_mapping() {
  local expected_cmdline="$1"
  local source status device uuid

  source="$(findmnt -n -o SOURCE --target /)" || return $?
  source="${source%%\[*}"
  [[ "$source" == /dev/mapper/cryptroot ]] || return 65
  status="$(cryptsetup status cryptroot)" || return $?
  device="$(awk '$1 == "device:" {print $2; exit}' <<<"$status")"
  [[ "$device" == /dev/* ]] || return 65
  uuid="$(blkid -s UUID -o value -- "$device")" || return $?
  [[ "$uuid" =~ ^[0-9A-Fa-f-]+$ ]] || return 65
  [[ " $expected_cmdline " == *" rd.luks.name=$uuid=cryptroot "* ]] || return 65
  [[ " $expected_cmdline " == *" rd.luks.options=$uuid=discard "* ]] || return 65
  [[ " $expected_cmdline " == *" root=/dev/mapper/cryptroot "* ]]
}

hardware_check_bootloader() {
  local list

  bootctl --esp-path="$(_boot_root)" is-installed >/dev/null || return $?
  list="$(bootctl --esp-path="$(_boot_root)" --json=short list)" || return $?
  jq -e '
    any(.[]; .id == "spawn-arch-current.efi") and
    any(.[]; .id == "spawn-arch-last-good.efi")
  ' >/dev/null <<<"$list"
}

hardware_check_plasma_wayland() {
  jq -e '.user != "root" and .uid >= 1 and (.environment.WAYLAND_DISPLAY | startswith("wayland-"))' >/dev/null <<<"$1"
}

hardware_check_intel_glx() {
  local output

  output="$(_hardware_run_in_session "$1" glxinfo -B)" || return $?
  grep -Eqi 'Intel' <<<"$output" || return 65
  ! grep -Eqi 'llvmpipe|NVIDIA' <<<"$output"
}

hardware_check_intel_vulkan() {
  local output

  output="$(_hardware_run_in_session "$1" vulkaninfo --summary)" || return $?
  grep -Eqi 'Intel' <<<"$output" || return 65
  ! grep -Eqi 'llvmpipe|NVIDIA' <<<"$output"
}

hardware_check_nvidia_prime() {
  local output

  output="$(_hardware_run_in_session "$1" prime-run glxinfo -B)" || return $?
  grep -Eqi 'NVIDIA' <<<"$output"
}

hardware_check_nvidia_smi() {
  nvidia-smi >/dev/null
}

hardware_check_power_profile() {
  local profile

  profile="$(powerprofilesctl get)" || return $?
  if [[ -e "${SPAWN_VAR_LIB_ROOT:-/var/lib/spawn-arch}/power-profile-verified" ]]; then
    return 0
  fi
  [[ "$profile" == balanced ]]
}

hardware_check_services() {
  systemctl is-active --quiet \
    NetworkManager.service firewalld.service plasmalogin.service switcheroo-control.service
}

hardware_check_boot_ui() {
  local expected_cmdline="$1"
  local etc_root theme

  etc_root="$(installed_etc_root)"
  [[ " $expected_cmdline " == *' quiet '* && " $expected_cmdline " == *' splash '* ]] || return 65
  theme="$(plymouth-set-default-theme)" || return $?
  [[ "$theme" == breeze ]] || return 65
  grep -Fxq \
    'HOOKS=(base systemd plymouth autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)' \
    "$etc_root/mkinitcpio.conf.d/spawn-arch.conf" || return 65
  grep -Fxq 'Theme=breeze' "$etc_root/plymouth/plymouthd.conf" || return 65
  grep -Fxq 'DeviceScale=2' "$etc_root/plymouth/plymouthd.conf"
}

hardware_check_service_policy() {
  local etc_root after wants

  etc_root="$(installed_etc_root)"
  after="$(systemctl show --property=After --value docker.service)" || return $?
  wants="$(systemctl show --property=Wants --value docker.service)" || return $?
  [[ " $after " == *' firewalld.service '* && " $after " == *' network-online.target '* ]] || return 65
  [[ " $wants " == *' firewalld.service '* && " $wants " == *' network-online.target '* ]] || return 65
  [[ ! -e "$etc_root/systemd/system/spawn-arch-initial-power-profile.service" ]] || return 65
  grep -Fxq 'ConditionPathExists=/var/lib/spawn-arch/enable-pcrlogin' \
    "$etc_root/systemd/system/systemd-pcrlogin@.service.d/10-spawn-arch-disable.conf"
}

hardware_check_audio() {
  _hardware_run_in_session "$1" systemctl --user is-active --quiet \
    pipewire.service pipewire-pulse.service wireplumber.service
}

hardware_check_ssh_agent() {
  local session="$1"
  local runtime status

  _hardware_run_in_session "$session" systemctl --user is-active --quiet ssh-agent.service || return $?
  runtime="$(jq -r '.environment.XDG_RUNTIME_DIR' <<<"$session")" || return $?
  if _hardware_run_in_session "$session" env \
    "SSH_AUTH_SOCK=$runtime/ssh-agent.socket" ssh-add -l >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  [[ "$status" -eq 0 || "$status" -eq 1 ]]
}

hardware_check_ssh_wallet() {
  local session="$1"
  local output

  jq -e '
    .environment.SSH_AUTH_SOCK == (.environment.XDG_RUNTIME_DIR + "/ssh-agent.socket") and
    .environment.SSH_ASKPASS == "/usr/bin/ksshaskpass" and
    .environment.SSH_ASKPASS_REQUIRE == "prefer"
  ' >/dev/null <<<"$session" || return 65
  output="$(_hardware_run_in_session "$session" ssh -G example.invalid)" || return $?
  grep -Fxq 'addkeystoagent yes' <<<"$output"
}

hardware_check_shell() {
  local session="$1"

  jq -e '.environment.STARSHIP_CONFIG == "/etc/starship.toml"' >/dev/null <<<"$session" || return 65
  # Values in this command must expand in the target user's shell.
  # shellcheck disable=SC2016
  _hardware_run_in_session "$session" sh -c '
    temporary="$(mktemp -d "$XDG_RUNTIME_DIR/spawn-arch-zdotdir.XXXXXX")" || exit
    ZDOTDIR="$temporary" zsh -lic '\''
      whence -w compdef >/dev/null &&
      [[ "$STARSHIP_SHELL" == zsh && "$STARSHIP_CONFIG" == /etc/starship.toml ]]
    '\''
    status=$?
    rmdir -- "$temporary" || status=$?
    exit "$status"
  '
}

hardware_check_docker() {
  local session="$1"
  local groups runtimes username

  systemctl is-active --quiet docker.service || return $?
  username="$(jq -r '.user' <<<"$session")" || return $?
  [[ -n "$username" && "$username" != root ]] || return 65
  groups="$(id -nG -- "$username")" || return $?
  [[ " $groups " != *' docker '* ]] || return 65
  docker info >/dev/null || return $?
  runtimes="$(docker info --format '{{json .Runtimes}}')" || return $?
  jq -e 'has("nvidia")' >/dev/null <<<"$runtimes"
}

hardware_check_firewall() {
  local applet etc_root services ports

  systemctl is-active --quiet firewalld.service || return $?
  [[ "$(firewall-cmd --get-default-zone)" == spawn-workstation ]] || return 65
  [[ "$(firewall-cmd --get-log-denied)" == unicast ]] || return 65
  services="$(firewall-cmd --zone=spawn-workstation --list-services)" || return $?
  ports="$(firewall-cmd --zone=spawn-workstation --list-ports)" || return $?
  [[ -z "$services" && -z "$ports" ]] || return 65
  etc_root="$(installed_etc_root)"
  applet="$etc_root/xdg/autostart/firewall-applet.desktop"
  [[ -r "$applet" ]] || return 65
  grep -Eq '^Exec=(/usr/bin/)?firewall-applet([[:space:]]|$)' "$applet" || return 65
  ! grep -Eqi '^Hidden[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$applet"
}

hardware_check_journal() {
  [[ -d "${SPAWN_VAR_LOG_ROOT:-/var/log}/journal" ]] || return 65
  journalctl --verify >/dev/null
}

hardware_check_package_audit() {
  systemctl is-active --quiet arch-audit.timer
}

hardware_check_sysctl() {
  local item key expected actual
  local -a policy=(
    kernel.dmesg_restrict=1
    kernel.kptr_restrict=2
    kernel.yama.ptrace_scope=1
    fs.suid_dumpable=0
    net.ipv4.conf.all.accept_redirects=0
    net.ipv4.conf.default.accept_redirects=0
    net.ipv6.conf.all.accept_redirects=0
    net.ipv6.conf.default.accept_redirects=0
    net.ipv4.conf.all.send_redirects=0
    net.ipv4.conf.default.send_redirects=0
  )

  for item in "${policy[@]}"; do
    key="${item%%=*}"
    expected="${item#*=}"
    actual="$(sysctl -n "$key")" || return $?
    [[ "$actual" == "$expected" ]] || return 65
  done
}

hardware_check_zram() {
  local swaps

  swaps="$(swapon --show --json --bytes)" || return $?
  jq -e '
    (.swapdevices | type == "array" and length == 1) and
    (.swapdevices[0].name | startswith("/dev/zram")) and
    .swapdevices[0].prio == 100
  ' >/dev/null <<<"$swaps"
}

hardware_check_pending_snapshot() {
  local state="$1"
  local snapshot_id snapshots

  [[ "$(jq -r '.pending.kind // empty' <<<"$state")" == pacman ]] || return 0
  snapshot_id="$(jq -r '.pending.pre_snapshot_id' <<<"$state")"
  snapshots="$(snapper -c root --jsonout list \
    --columns number,default,active,date,user,cleanup,description,userdata,read-only,pre-number,post-number)" || return $?
  jq -e --argjson id "$snapshot_id" '
    [.root[] | select(
      .number == $id and .["read-only"] == true and
      (.["pre-number"] == 0 or .["pre-number"] == null) and
      (.["post-number"] | type == "number" and . >= 1)
    )] | length == 1
  ' >/dev/null <<<"$snapshots"
}

hardware_retire_seed() {
  local seed_id="$1"
  local safety_snapshot_id="$2"
  local root_observations="$3"
  local snapshots target output mounted_id root_source top_level status list_output
  local -a mounted_targets=()

  [[ "$seed_id" =~ ^[1-9][0-9]*$ && "$safety_snapshot_id" =~ ^[1-9][0-9]*$ ]] || return 65
  jq -e --argjson seed "$seed_id" '
    .active_subvolume_id != $seed and .default_subvolume_id != $seed and
    .active_subvolume_id == .default_subvolume_id
  ' >/dev/null <<<"$root_observations" || return 65
  snapshots="$(snapper -c root --jsonout list \
    --columns number,default,active,date,user,cleanup,description,userdata,read-only,pre-number,post-number)" || return $?
  jq -e --argjson id "$safety_snapshot_id" '
    [.root[] | select(.number == $id and .["read-only"] == true)] | length == 1
  ' >/dev/null <<<"$snapshots" || return 65

  mapfile -t mounted_targets < <(findmnt -rn -t btrfs -o TARGET)
  for target in "${mounted_targets[@]}"; do
    output="$(LC_ALL=C btrfs subvolume show "$target" 2>/dev/null || true)"
    mounted_id="$(btrfs_subvolume_id_from_show "$output" 2>/dev/null || true)"
    [[ "$mounted_id" != "$seed_id" ]] || return 65
  done

  root_source="$(jq -r '.source' <<<"$root_observations")" || return $?
  [[ "$root_source" == /dev/* ]] || return 65
  install -d -m 0700 -- "${SPAWN_INSTALLED_RUNTIME_DIR:-/run/spawn-arch}" || return $?
  top_level="$(mktemp -d "${SPAWN_INSTALLED_RUNTIME_DIR:-/run/spawn-arch}/seed-retire.XXXXXX")" || return $?
  if ! mount -t btrfs -o subvolid=5 -- "$root_source" "$top_level"; then
    rmdir -- "$top_level"
    return 65
  fi
  status=0
  output="$(LC_ALL=C btrfs subvolume show "$top_level/@" 2>/dev/null || true)"
  mounted_id="$(btrfs_subvolume_id_from_show "$output" 2>/dev/null || true)"
  if [[ "$mounted_id" == "$seed_id" ]]; then
    btrfs subvolume delete "$top_level/@" || status=$?
    if ((status == 0)) && [[ -e "$top_level/@" ]]; then status=65; fi
  else
    list_output="$(btrfs subvolume list "$top_level" 2>/dev/null || true)"
    if grep -Eq "^ID[[:space:]]+$seed_id([[:space:]]|$)" <<<"$list_output"; then status=65; fi
  fi
  umount -- "$top_level" || status=$?
  rmdir -- "$top_level" || status=$?
  return "$status"
}
