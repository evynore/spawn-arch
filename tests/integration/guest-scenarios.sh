#!/usr/bin/env bash
set -Eeuo pipefail

readonly SOURCE_ROOT=/run/spawn-source
readonly EXCHANGE_ROOT=/run/spawn-exchange
readonly PLAN_PATH=/run/spawn-arch/plan.json
SCENARIO="${1:-unknown}"
readonly SCENARIO

scenario_exit() {
  local status="$?"

  printf '__SPAWN_GUEST_DONE__:%s:%s\n' "$SCENARIO" "$status"
}
trap scenario_exit EXIT

assert_file_mode() {
  local path="$1"
  local mode="$2"

  [[ "$(stat -c %a -- "$path")" == "$mode" ]]
}

live_install() {
  local target resolved cmdline seed

  [[ "$EUID" -eq 0 && -x "$SOURCE_ROOT/spawn-arch" && -d "$EXCHANGE_ROOT" ]]
  target=/dev/disk/by-id/virtio-SPAWNARCH-TARGET
  resolved="$(readlink -f -- "$target")"
  [[ "$resolved" == /dev/vda && "$(</sys/class/block/vda/serial)" == SPAWNARCH-TARGET ]]

  cd -- "$SOURCE_ROOT"
  ./spawn-arch doctor >"$EXCHANGE_ROOT/doctor.json"
  jq -e '.ok == true' "$EXCHANGE_ROOT/doctor.json" >/dev/null
  SPAWN_DISK_SELECTION=1 \
    SPAWN_HOSTNAME=spawn \
    SPAWN_USERNAME=evynore \
    SPAWN_TIMEZONE=Etc/UTC \
    SPAWN_KEYMAP=us \
    SPAWN_LOCALE=en_US.UTF-8 \
    SPAWN_PLAN_PATH="$PLAN_PATH" \
    ./spawn-arch plan >"$EXCHANGE_ROOT/plan-output.txt"
  assert_file_mode "$PLAN_PATH" 600
  jq -e '
    .target.identity.serial == "SPAWNARCH-TARGET" and
    .target.identity.by_id == "/dev/disk/by-id/virtio-SPAWNARCH-TARGET"
  ' "$PLAN_PATH" >/dev/null

  SPAWN_PLAN_PATH="$PLAN_PATH" ./spawn-arch install

  cmdline="$(</mnt/etc/kernel/cmdline)"
  [[ " $cmdline " != *' console='* ]]
  cmdline="$cmdline console=ttyS0,115200n8"
  printf '%s\n' "$cmdline" >/mnt/etc/kernel/cmdline.integration
  chmod 0644 /mnt/etc/kernel/cmdline.integration
  mv -f /mnt/etc/kernel/cmdline.integration /mnt/etc/kernel/cmdline
  arch-chroot /mnt mkinitcpio -p linux
  seed="$(jq -er '.seed.subvolume_id' /mnt/boot/loader/spawn-arch-state.json)"
  # shellcheck source=payload/usr/local/lib/spawn-arch/boot-state.sh
  source /mnt/usr/local/lib/spawn-arch/boot-state.sh
  boot_initialize /mnt "$seed" "$cmdline"
  SPAWN_PLAN_PATH="$PLAN_PATH" ./spawn-arch verify /mnt >/dev/null
  sync

  jq -n '{
    doctor: true,
    planned: true,
    exact_confirmation: true,
    installed: true,
    luks_prompt_seen: true
  }' >"$EXCHANGE_ROOT/install-live.json"
}

first_boot_assert() {
  local luks_version root_options active_id default_id mount_dir swap_json boot_list snapper_json
  local pam_file service subvolume
  local -a services=(
    NetworkManager bluetooth firewalld plasmalogin
    switcheroo-control power-profiles-daemon docker arch-audit.timer
  )
  local -a expected_subvolumes=(@ @home @log @pkg @snapshots)

  [[ "$EUID" -eq 0 && -d "$EXCHANGE_ROOT" ]]
  findmnt --verify >/dev/null
  cryptsetup isLuks --type luks2 /dev/vda2
  luks_version=2
  root_options="$(findmnt -no OPTIONS /)"
  [[ ",$root_options," != *,subvol=* && ",$root_options," != *,subvolid=* ]]
  active_id="$(btrfs_subvolume_id_from_show "$(LC_ALL=C btrfs subvolume show /)")"
  default_id="$(btrfs subvolume get-default / | awk '$1 == "ID" {print $2; exit}')"
  [[ "$active_id" =~ ^[1-9][0-9]*$ && "$active_id" == "$default_id" ]]

  mount_dir="$(mktemp -d /run/spawn-arch-top.XXXXXX)"
  mount -t btrfs -o subvolid=5 -- /dev/mapper/cryptroot "$mount_dir"
  for subvolume in "${expected_subvolumes[@]}"; do
    btrfs subvolume show "$mount_dir/$subvolume" >/dev/null
  done
  umount "$mount_dir"
  rmdir "$mount_dir"

  swap_json="$(swapon --show --json)"
  jq -e '
    .swapdevices | length == 1 and
    .[0].name == "/dev/zram0" and
    (.[0].prio | tonumber) == 100
  ' <<<"$swap_json" >/dev/null
  boot_list="$(bootctl --json=short list)"
  jq -e '
    any(.[]; .id == "spawn-arch-current.efi") and
    any(.[]; .id == "spawn-arch-last-good.efi")
  ' <<<"$boot_list" >/dev/null
  snapper_json="$(snapper -c root --jsonout list)"
  jq -e '.root | type == "array" and length >= 1' <<<"$snapper_json" >/dev/null
  for service in "${services[@]}"; do
    systemctl is-enabled "$service" >/dev/null
  done
  systemctl is-active --quiet docker.service
  systemctl --global is-enabled ssh-agent.service >/dev/null
  ! systemctl is-enabled sshd.service >/dev/null 2>&1
  pacman -Q ksshaskpass kwallet-pam zsh zsh-completions starship ttf-firacode-nerd >/dev/null
  grep -Fx 'SSH_AUTH_SOCK=${XDG_RUNTIME_DIR}/ssh-agent.socket' /etc/environment.d/10-ssh-agent.conf
  grep -Fx 'SSH_ASKPASS=/usr/bin/ksshaskpass' /etc/environment.d/10-ssh-agent.conf
  grep -Fx 'SSH_ASKPASS_REQUIRE=prefer' /etc/environment.d/10-ssh-agent.conf
  grep -Fx 'STARSHIP_CONFIG=/etc/starship.toml' /etc/environment.d/20-starship.conf
  [[ "$(getent passwd evynore | cut -d: -f7)" == /usr/bin/zsh ]]
  [[ -x /usr/bin/ksshaskpass && -x /usr/bin/zsh ]]
  [[ -r /usr/share/fonts/TTF/FiraCodeNerdFontMono-Regular.ttf ]]
  [[ ! -e /home/evynore/.zshrc ]]
  [[ ! -e /home/evynore/.config/starship.toml ]]
  zsh -n /etc/zsh/zshrc
  printf '%s  %s\n' \
    '04f185c124b48f0d4320adeed0f7471add110fcda6594b352ed464eb95bf1ed3' \
    '/etc/starship.toml' | sha256sum -c -
  ssh -G example.invalid | grep -Fxq 'addkeystoagent yes'
  if [[ -r /etc/pam.d/plasmalogin ]]; then
    pam_file=/etc/pam.d/plasmalogin
  else
    pam_file=/usr/lib/pam.d/plasmalogin
  fi
  grep -Eq '^[[:space:]]*-?auth[[:space:]].*pam_kwallet5\.so([[:space:]]|$)' "$pam_file"
  grep -Eq '^[[:space:]]*-?session[[:space:]].*pam_kwallet5\.so([[:space:]]|$)' "$pam_file"
  [[ "$(firewall-cmd --get-default-zone)" == spawn-workstation ]]
  [[ "$(firewall-cmd --get-log-denied)" == unicast ]]
  [[ -d /var/log/journal ]]
  [[ "$(sysctl -n kernel.dmesg_restrict)" == 1 ]]
  [[ "$(sysctl -n kernel.kptr_restrict)" == 2 ]]
  [[ "$(sysctl -n kernel.yama.ptrace_scope)" == 1 ]]
  [[ "$(sysctl -n fs.suid_dumpable)" == 0 ]]
  /usr/local/bin/spawn-arch status >/dev/null

  jq -n \
    --argjson luks_version "$luks_version" \
    --argjson subvolumes '["@", "@home", "@log", "@pkg", "@snapshots"]' \
    --argjson services '[
      "NetworkManager", "bluetooth", "firewalld", "plasmalogin",
      "switcheroo-control", "power-profiles-daemon", "docker", "arch-audit.timer"
    ]' '{
      luks_version: $luks_version,
      dynamic_default_root: true,
      subvolumes: $subvolumes,
      zram_only: true,
      ukis: ["spawn-arch-current", "spawn-arch-last-good"],
      snapper_root: true,
      services: $services,
      security_baseline: {
        docker_active: true,
        firewall_log_denied: "unicast",
        firewall_zone: "spawn-workstation",
        journal_persistent: true,
        ssh_agent_global: true,
        sshd_disabled: true,
        sysctl: true
      },
      developer_session_baseline: {
        kwallet_ssh: true,
        login_shell: "/usr/bin/zsh",
        starship_preset: "plain-text-symbols",
        font: "FiraCode Nerd Font Mono",
        user_dotfiles_untouched: true
      }
    }' >"$EXCHANGE_ROOT/first-boot.json"
  sync -f "$EXCHANGE_ROOT/first-boot.json"
}

pacman_reinstall_linux() {
  pacman -S --noconfirm linux
}

update_stage() {
  local state_before state_after current_before current_after pending_current last_good_hash snapshot_id
  local log_start snap_description preserve_description snap_line preserve_line

  state_before="$(sha256sum /boot/loader/spawn-arch-state.json | awk '{print $1}')"
  current_before="$(sha256sum /boot/EFI/Linux/spawn-arch-current.efi | awk '{print $1}')"
  log_start=$(($(wc -l </var/log/pacman.log) + 1))
  snap_description="$(awk -F= '$1 ~ /^Description[[:space:]]*$/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' /usr/share/libalpm/hooks/05-snap-pac-pre.hook)"
  preserve_description="$(awk -F= '$1 ~ /^Description[[:space:]]*$/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' /etc/pacman.d/hooks/06-spawn-arch-preserve-uki.hook)"
  [[ -n "$snap_description" && -n "$preserve_description" ]]

  pacman_reinstall_linux
  state_after="$(</boot/loader/spawn-arch-state.json)"
  snapshot_id="$(jq -er '.pending.pre_snapshot_id' <<<"$state_after")"
  jq -e '
    .current.blessed == false and .pending.kind == "pacman" and
    (.pending.packages | index("linux")) != null
  ' <<<"$state_after" >/dev/null
  snapper -c root --jsonout list | jq -e --argjson id "$snapshot_id" '
    any(.root[]; .number == $id and .pre_number == 0)
  ' >/dev/null
  last_good_hash="$(sha256sum /boot/EFI/Linux/spawn-arch-last-good.efi | awk '{print $1}')"
  pending_current="$(sha256sum /boot/EFI/Linux/spawn-arch-current.efi | awk '{print $1}')"
  [[ "$last_good_hash" == "$(jq -r '.pending.previous_current_sha256' <<<"$state_after")" ]]
  snap_line="$(awk -v start="$log_start" -v needle="$snap_description" '
    NR >= start && index($0, needle) {print NR - start + 1; exit}
  ' /var/log/pacman.log)"
  preserve_line="$(awk -v start="$log_start" -v needle="$preserve_description" '
    NR >= start && index($0, needle) {print NR - start + 1; exit}
  ' /var/log/pacman.log)"
  [[ "$snap_line" =~ ^[1-9][0-9]*$ && "$preserve_line" =~ ^[1-9][0-9]*$ && "$snap_line" -lt "$preserve_line" ]]

  if pacman_reinstall_linux; then
    return 70
  fi
  current_after="$(sha256sum /boot/EFI/Linux/spawn-arch-current.efi | awk '{print $1}')"
  [[ "$state_before" != "$(sha256sum /boot/loader/spawn-arch-state.json | awk '{print $1}')" ]]
  [[ "$current_before" != "$pending_current" && "$current_after" == "$pending_current" ]]
  [[ "$(sha256sum /boot/EFI/Linux/spawn-arch-last-good.efi | awk '{print $1}')" == "$last_good_hash" ]]
  [[ "$(jq -S -c . /boot/loader/spawn-arch-state.json)" == "$(jq -S -c . <<<"$state_after")" ]]

  jq -n \
    --argjson snapshot_id "$snapshot_id" \
    --arg last_good "$last_good_hash" '{
      hook_order: ["05-snap-pac-pre", "06-spawn-arch-preserve-uki"],
      pinned_pre_snapshot_id: $snapshot_id,
      last_good_sha256: $last_good,
      second_transaction_blocked: true
    }' >"$EXCHANGE_ROOT/update-stage.json"
  sync -f "$EXCHANGE_ROOT/update-stage.json"
}

install_qemu_hardware_adapter() {
  hardware_check_plasma_wayland() { return 0; }
  hardware_check_intel_glx() { return 0; }
  hardware_check_intel_vulkan() { return 0; }
  hardware_check_nvidia_prime() { return 0; }
  hardware_check_nvidia_smi() { return 0; }
}

update_bless() {
  local report state

  # shellcheck source=payload/usr/local/lib/spawn-arch/verify.sh
  source /usr/local/lib/spawn-arch/verify.sh
  install_qemu_hardware_adapter
  report="$(verify_build_report)"
  jq -e '
    .ok == true and
    ([.checks[] | select(.name != "plasma_wayland" and .name != "intel_glx" and
      .name != "intel_vulkan" and .name != "nvidia_prime" and .name != "nvidia_smi") |
      .ok] | all)
  ' <<<"$report" >/dev/null
  verify_commit_bless "$report"
  state="$(boot_state_read)"
  jq -e '.current.blessed == true and .pending == null' <<<"$state" >/dev/null
  jq -n '{non_gpu_checks_passed: true, blessed: true}' >"$EXCHANGE_ROOT/update-bless.json"
  sync -f "$EXCHANGE_ROOT/update-bless.json"
}

update_allow() {
  local state

  pacman_reinstall_linux
  state="$(</boot/loader/spawn-arch-state.json)"
  jq -e '.current.blessed == false and .pending.kind == "pacman"' <<<"$state" >/dev/null
  jq -n '{next_transaction_allowed: true}' >"$EXCHANGE_ROOT/update-allow.json"
  sync -f "$EXCHANGE_ROOT/update-allow.json"
}

power_trigger() {
  local phase="$1"
  local operation="$2"

  export SPAWN_TEST_PAUSE_PHASE="$phase"
  export SPAWN_TEST_PAUSE_MARKER="$EXCHANGE_ROOT/power-$phase.ready"
  rm -f -- "$SPAWN_TEST_PAUSE_MARKER"
  case "$operation" in
    update) pacman_reinstall_linux ;;
    rollback) /usr/local/bin/spawn-arch rollback latest ;;
    *) return 64 ;;
  esac
  return 70
}

power_inspect() {
  local phase="$1"
  local state_path=/boot/loader/spawn-arch-state.json
  local previous_path=/boot/loader/spawn-arch-state.json.previous
  local valid_state=false valid_previous=false current_valid=false last_good_valid=false expected_cmdline

  /usr/local/bin/spawn-arch status >/dev/null
  # shellcheck source=payload/usr/local/lib/spawn-arch/boot-state.sh
  source /usr/local/lib/spawn-arch/boot-state.sh
  # shellcheck source=payload/usr/local/lib/spawn-arch/uki.sh
  source /usr/local/lib/spawn-arch/uki.sh
  if [[ -r "$state_path" ]] && boot_state_validate "$(<"$state_path")"; then
    valid_state=true
  fi
  if [[ -r "$previous_path" ]] && boot_state_validate "$(<"$previous_path")"; then
    valid_previous=true
  fi
  expected_cmdline="$(</etc/kernel/cmdline)"
  uki_validate /boot/EFI/Linux/spawn-arch-current.efi "$expected_cmdline" current && current_valid=true
  uki_validate /boot/EFI/Linux/spawn-arch-last-good.efi "$expected_cmdline" last-good && last_good_valid=true
  [[ "$valid_state" == true || "$valid_previous" == true ]]
  [[ "$current_valid" == true || "$last_good_valid" == true ]]

  jq -n \
    --argjson valid_state "$valid_state" \
    --argjson valid_previous "$valid_previous" \
    --argjson current "$current_valid" \
    --argjson last_good "$last_good_valid" '{
      valid_state: $valid_state,
      valid_previous: $valid_previous,
      at_least_one_valid_uki: ($current or $last_good),
      two_valid_ukis: ($current and $last_good)
    }' >"$EXCHANGE_ROOT/power-$phase.json"
  sync -f "$EXCHANGE_ROOT/power-$phase.json"
}

rescue_stage() {
  local state pinned current_hash

  state="$(</boot/loader/spawn-arch-state.json)"
  pinned="$(jq -er '.pending.pre_snapshot_id' <<<"$state")"
  current_hash="$(sha256sum /boot/EFI/Linux/spawn-arch-current.efi | awk '{print $1}')"
  printf 'integration-corruption\n' >>/boot/EFI/Linux/spawn-arch-current.efi
  sync -f /boot/EFI/Linux/spawn-arch-current.efi
  [[ "$(sha256sum /boot/EFI/Linux/spawn-arch-current.efi | awk '{print $1}')" != "$current_hash" ]]
  bootctl set-oneshot spawn-arch-last-good
  jq -n --argjson pinned "$pinned" --arg hash "$current_hash" '{
    pinned_pre_snapshot_id: $pinned,
    saved_current_sha256: $hash,
    current_corrupted: true,
    oneshot_last_good: true
  }' >"$EXCHANGE_ROOT/rescue-stage.json"
  sync -f "$EXCHANGE_ROOT/rescue-stage.json"
}

rollback_execute() {
  local selected state pinned output new_state default_id

  # shellcheck source=payload/usr/local/lib/spawn-arch/boot-state.sh
  source /usr/local/lib/spawn-arch/boot-state.sh
  selected="$(boot_selected_entry)"
  [[ "$selected" == spawn-arch-last-good ]]
  state="$(boot_state_read)"
  pinned="$(jq -er '.pending.pre_snapshot_id' <<<"$state")"
  output="$(/usr/local/bin/spawn-arch rollback latest)"
  jq -e --argjson pinned "$pinned" '.ok == true and .target_snapshot_id == $pinned' <<<"$output" >/dev/null
  new_state="$(boot_state_read)"
  jq -e --argjson pinned "$pinned" '
    .current.blessed == false and .pending.kind == "rollback" and
    .pending.target_snapshot_id == $pinned
  ' <<<"$new_state" >/dev/null
  default_id="$(btrfs subvolume get-default / | awk '$1 == "ID" {print $2; exit}')"
  [[ "$default_id" == "$(jq -r '.pending.new_default_subvolume_id' <<<"$new_state")" ]]

  jq -n --argjson pinned "$pinned" --argjson default_id "$default_id" '{
    last_good_selected: true,
    latest_resolved_to_pinned_pre: true,
    target_snapshot_id: $pinned,
    new_default_subvolume_id: $default_id,
    default_subvolume_transitioned: true
  }' >"$EXCHANGE_ROOT/rollback.json"
  sync -f "$EXCHANGE_ROOT/rollback.json"
}

rollback_bless() {
  local report state observations

  # shellcheck source=payload/usr/local/lib/spawn-arch/verify.sh
  source /usr/local/lib/spawn-arch/verify.sh
  install_qemu_hardware_adapter
  report="$(verify_build_report)"
  jq -e '.ok == true and .pending.kind == "rollback"' <<<"$report" >/dev/null
  verify_commit_bless "$report"
  state="$(boot_state_read)"
  observations="$(hardware_root_observations)"
  jq -e '.current.blessed == true and .pending == null and .seed.retired == true' <<<"$state" >/dev/null
  jq -e '
    .active_subvolume_id == .default_subvolume_id and
    .active_subvolume_id > 0
  ' <<<"$observations" >/dev/null

  jq -n '{
    blessed: true,
    active_equals_default: true,
    seed_retired: true
  }' >"$EXCHANGE_ROOT/rollback-bless.json"
  sync -f "$EXCHANGE_ROOT/rollback-bless.json"
}

main() {
  case "$SCENARIO" in
    live-install) live_install ;;
    first-boot) first_boot_assert ;;
    update-stage) update_stage ;;
    update-bless) update_bless ;;
    update-allow) update_allow ;;
    power-state-temp) power_trigger state_temp update ;;
    power-last-good-temp) power_trigger last_good_temp update ;;
    power-current-candidate) power_trigger current_candidate rollback ;;
    power-post-snapper) power_trigger post_snapper_pre_state_commit rollback ;;
    inspect-state-temp) power_inspect state_temp ;;
    inspect-last-good-temp) power_inspect last_good_temp ;;
    inspect-current-candidate) power_inspect current_candidate ;;
    inspect-post-snapper) power_inspect post_snapper_pre_state_commit ;;
    rescue-stage) rescue_stage ;;
    rollback) rollback_execute ;;
    rollback-bless) rollback_bless ;;
    *) return 64 ;;
  esac
}

main
