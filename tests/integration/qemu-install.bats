#!/usr/bin/env bats

load helpers/load

@test "isolated UEFI guest installs without changing the sentinel disk" {
  run "$QEMU_HARNESS" install

  [ "$status" -eq 0 ]
  assert_scenario_result install '
    .sentinel.unchanged == true and
    .sentinel.before_sha256 == .sentinel.after_sha256 and
    .installer == {
      doctor: true,
      planned: true,
      exact_confirmation: true,
      installed: true,
      luks_prompt_seen: true,
      luks_unlocked: true
    } and
    .first_boot.luks_version == 2 and
    .first_boot.dynamic_default_root == true and
    .first_boot.subvolumes == ["@", "@home", "@log", "@pkg", "@snapshots"] and
    .first_boot.zram_only == true and
    .first_boot.ukis == ["spawn-arch-current", "spawn-arch-last-good"] and
    .first_boot.snapper_root == true and
    .first_boot.services == [
      "NetworkManager", "bluetooth", "firewalld", "plasmalogin",
      "switcheroo-control", "power-profiles-daemon", "docker", "arch-audit.timer"
    ] and
    .first_boot.security_baseline == {
      docker_active: true,
      firewall_log_denied: "unicast",
      firewall_zone: "spawn-workstation",
      journal_persistent: true,
      ssh_agent_global: true,
      sshd_disabled: true,
      sysctl: true
    } and
    .first_boot.developer_session_baseline == {
      kwallet_ssh: true,
      login_shell: "/usr/bin/zsh",
      starship_preset: "plain-text-symbols",
      font: "FiraCode Nerd Font Mono",
      user_dotfiles_untouched: true
    }
  '
}
