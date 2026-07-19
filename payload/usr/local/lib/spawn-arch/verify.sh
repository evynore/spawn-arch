#!/usr/bin/env bash

_spawn_verify_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=payload/usr/local/lib/spawn-arch/boot-state.sh
source "$_spawn_verify_dir/boot-state.sh"
# shellcheck source=payload/usr/local/lib/spawn-arch/uki.sh
source "$_spawn_verify_dir/uki.sh"
# shellcheck source=payload/usr/local/lib/spawn-arch/hardware-verify.sh
source "$_spawn_verify_dir/hardware-verify.sh"

_verification_add_check() {
  local output_name="$1"
  local name="$2"
  local detail="$3"
  shift 3
  local ok current updated

  if "$@" >/dev/null 2>&1; then ok=true; else ok=false; fi
  current="${!output_name}"
  updated="$(jq -c --arg name "$name" --argjson ok "$ok" --arg detail "$detail" \
    '. + [{name: $name, ok: $ok, required: true, detail: $detail}]' <<<"$current")" || return $?
  printf -v "$output_name" '%s' "$updated"
}

verify_build_report() {
  local state expected_cmdline current_path current_hash root_observations session_observations checks report

  state="$(boot_state_read)" || return $?
  expected_cmdline="$(<"$(installed_etc_root)/kernel/cmdline")" || return $?
  current_path="$(_boot_efi_linux_dir)/spawn-arch-current.efi"
  current_hash="$(sha256_file "$current_path" 2>/dev/null || true)"
  root_observations="$(hardware_root_observations 2>/dev/null || printf '{}')"
  session_observations="$(hardware_session_observations 2>/dev/null || printf '{}')"
  checks='[]'

  _verification_add_check checks selected_entry 'firmware selected current UKI' hardware_check_selected_entry
  _verification_add_check checks current_uki 'current UKI sections, cmdline, and hash policy' \
    hardware_check_current_uki "$state" "$current_hash" "$expected_cmdline"
  _verification_add_check checks running_kernel 'running kernel matches UKI .uname' hardware_check_running_kernel
  _verification_add_check checks root_default 'active root is the dynamic Btrfs default' \
    hardware_check_root_default "$root_observations"
  _verification_add_check checks luks_mapping 'root mapper and embedded LUKS UUID agree' \
    hardware_check_luks_mapping "$expected_cmdline"
  _verification_add_check checks bootloader 'systemd-boot sees current and last-good' hardware_check_bootloader
  _verification_add_check checks plasma_wayland 'active local non-root Plasma Wayland session' \
    hardware_check_plasma_wayland "$session_observations"
  _verification_add_check checks intel_glx 'default OpenGL renderer is Intel' \
    hardware_check_intel_glx "$session_observations"
  _verification_add_check checks intel_vulkan 'default Vulkan renderer is Intel' \
    hardware_check_intel_vulkan "$session_observations"
  _verification_add_check checks nvidia_prime 'prime-run OpenGL renderer is NVIDIA' \
    hardware_check_nvidia_prime "$session_observations"
  _verification_add_check checks nvidia_smi 'NVIDIA management interface is healthy' hardware_check_nvidia_smi
  _verification_add_check checks power_profile 'initial power profile is balanced' hardware_check_power_profile
  _verification_add_check checks services 'network, firewall, login, and GPU switching services are active' hardware_check_services
  _verification_add_check checks boot_ui 'Breeze Plymouth and encrypted-root prompt policy are active' \
    hardware_check_boot_ui "$expected_cmdline"
  _verification_add_check checks service_policy 'Docker ordering and unused pcrlogin policy are active' \
    hardware_check_service_policy
  _verification_add_check checks audio 'PipeWire audio services are active in the Plasma session' \
    hardware_check_audio "$session_observations"
  _verification_add_check checks ssh_agent 'OpenSSH agent service and runtime socket are available' \
    hardware_check_ssh_agent "$session_observations"
  _verification_add_check checks ssh_wallet 'KWallet askpass environment and OpenSSH add-to-agent policy are active' \
    hardware_check_ssh_wallet "$session_observations"
  _verification_add_check checks shell 'global Zsh completion and Starship initialization work without user dotfiles' \
    hardware_check_shell "$session_observations"
  _verification_add_check checks docker 'local sudo-only Docker daemon and opt-in NVIDIA runtime are healthy' \
    hardware_check_docker "$session_observations"
  _verification_add_check checks firewall 'closed workstation firewalld zone is active' hardware_check_firewall
  _verification_add_check checks journal 'persistent journal exists and verifies cleanly' hardware_check_journal
  _verification_add_check checks package_audit 'Arch security audit timer is active' hardware_check_package_audit
  _verification_add_check checks sysctl 'approved low-risk kernel hardening is active' hardware_check_sysctl
  _verification_add_check checks zram 'zram is the only swap device at priority 100' hardware_check_zram
  _verification_add_check checks pending_snapshot 'pending Pacman pre-snapshot still exists' \
    hardware_check_pending_snapshot "$state"

  report="$(jq -n \
    --argjson generation "$(jq -r '.generation' <<<"$state")" \
    --argjson pending "$(jq -c '.pending' <<<"$state")" \
    --arg current_hash "$current_hash" \
    --argjson root "$root_observations" \
    --argjson checks "$checks" '{
      state_generation: $generation,
      pending: $pending,
      observed_current_sha256: $current_hash,
      root: $root,
      checks: $checks
    } | .ok = ([.checks[].ok] | all)')" || return $?
  printf '%s\n' "$report"
}

verify_run() {
  local report

  report="$(verify_build_report)" || return $?
  printf '%s\n' "$report"
  jq -e '.ok' >/dev/null <<<"$report"
}

verify_status() {
  local state selected transaction=false

  state="$(boot_state_read)" || return $?
  selected="$(boot_selected_entry 2>/dev/null || printf 'unknown')"
  [[ ! -e "$(_boot_transaction_path)" ]] || transaction=true
  jq -n --arg selected "$selected" --argjson transaction "$transaction" --argjson state "$state" \
    '{selected_entry: $selected, transaction_present: $transaction, state: $state}'
}

verify_commit_bless() {
  local report="$1"
  local lock_path state expected_generation expected_pending actual_pending current_path current_hash new_state status
  local seed_id safety_snapshot_id retired_state

  jq -e '.ok == true' >/dev/null <<<"$report" || return 65
  expected_generation="$(jq -r '.state_generation' <<<"$report")" || return $?
  expected_pending="$(jq -S -c '.pending' <<<"$report")" || return $?
  current_hash="$(jq -r '.observed_current_sha256' <<<"$report")" || return $?
  [[ "$current_hash" =~ ^[0-9a-f]{64}$ ]] || return 65

  _boot_prepare_directories || return $?
  lock_path="$(_boot_runtime_dir)/boot-state.lock"
  exec {bless_lock_fd}>"$lock_path" || return $?
  flock -x "$bless_lock_fd" || return $?
  state="$(boot_state_read)" || status=$?
  status="${status:-0}"
  if ((status == 0)); then
    actual_pending="$(jq -S -c '.pending' <<<"$state")" || status=$?
  fi
  if ((status == 0)) && { [[ "$(jq -r '.generation' <<<"$state")" != "$expected_generation" ]] || [[ "$actual_pending" != "$expected_pending" ]]; }; then
    status=75
  fi
  current_path="$(_boot_efi_linux_dir)/spawn-arch-current.efi"
  if ((status == 0)) && [[ "$(sha256_file "$current_path")" != "$current_hash" ]]; then
    status=75
  fi
  if ((status == 0)); then
    new_state="$(jq --arg hash "$current_hash" '
      .generation += 1 |
      .current.sha256 = $hash |
      .current.blessed = true |
      if .pending.kind == "rollback" then
        .seed.safety_snapshot_id = .pending.safety_snapshot_id
      else . end |
      .pending = null
    ' <<<"$state")" || status=$?
  fi
  if ((status == 0)); then
    _boot_state_write_locked "$new_state" || status=$?
  fi
  if ((status == 0)) && [[ "$(jq -r '.seed.retired' <<<"$new_state")" == false ]]; then
    seed_id="$(jq -r '.seed.subvolume_id' <<<"$new_state")"
    safety_snapshot_id="$(jq -r '.seed.safety_snapshot_id // empty' <<<"$new_state")"
    if [[ -n "$safety_snapshot_id" ]]; then
      if hardware_retire_seed "$seed_id" "$safety_snapshot_id" "$(jq -c '.root' <<<"$report")"; then
        retired_state="$(jq '.generation += 1 | .seed.retired = true' <<<"$new_state")" || status=$?
        if ((status == 0)); then
          _boot_state_write_locked "$retired_state" || status=$?
        fi
      else
        log_warn "seed retirement was not proven safe; the blessed boot is retained and the seed is left intact"
      fi
    fi
  fi
  flock -u "$bless_lock_fd" || true
  exec {bless_lock_fd}>&-
  if ((status == 0)); then
    install -d -m 0755 -- "${SPAWN_VAR_LIB_ROOT:-/var/lib/spawn-arch}" || return $?
    install -m 0644 /dev/null "${SPAWN_VAR_LIB_ROOT:-/var/lib/spawn-arch}/power-profile-verified" || return $?
  fi
  return "$status"
}

verify_and_bless() {
  local report

  report="$(verify_build_report)" || return $?
  if ! jq -e '.ok' >/dev/null <<<"$report"; then
    printf '%s\n' "$report"
    return 1
  fi
  verify_commit_bless "$report" || return $?
  jq '. + {blessed: true}' <<<"$report"
}
