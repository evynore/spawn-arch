#!/usr/bin/env bats

load ../helpers/load

setup() {
  export SPAWN_BOOT_ROOT="$BATS_TEST_TMPDIR/boot"
  export SPAWN_ETC_ROOT="$BATS_TEST_TMPDIR/etc"
  export SPAWN_INSTALLED_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
  export SPAWN_EFIVAR_PATH="$BATS_TEST_TMPDIR/LoaderEntrySelected"
  export SPAWN_PROC_ROOT="$BATS_TEST_TMPDIR/proc"
  export SPAWN_VAR_LIB_ROOT="$BATS_TEST_TMPDIR/var/lib/spawn-arch"
  export SPAWN_VAR_LOG_ROOT="$BATS_TEST_TMPDIR/var/log"
  export FAKE_SECTIONS_JSON="$REPO_ROOT/tests/fixtures/uki/sections.json"
  export FAKE_SNAPPER_JSON="$REPO_ROOT/tests/fixtures/snapper/list.json"
  export FAKE_FAIL=none
  mkdir -p \
    "$SPAWN_BOOT_ROOT/EFI/Linux" "$SPAWN_BOOT_ROOT/loader" \
    "$SPAWN_ETC_ROOT/kernel" "$SPAWN_ETC_ROOT/spawn-arch" \
    "$SPAWN_ETC_ROOT/xdg/autostart" \
    "$SPAWN_ETC_ROOT/mkinitcpio.conf.d" "$SPAWN_ETC_ROOT/plymouth" \
    "$SPAWN_ETC_ROOT/systemd/system/docker.service.d" \
    "$SPAWN_ETC_ROOT/systemd/system/systemd-pcrlogin@.service.d" \
    "$SPAWN_INSTALLED_RUNTIME_DIR" "$SPAWN_PROC_ROOT/1234" "$SPAWN_VAR_LIB_ROOT" \
    "$SPAWN_VAR_LOG_ROOT/journal"
  jq -r '.cmdline' "$FAKE_SECTIONS_JSON" >"$SPAWN_ETC_ROOT/kernel/cmdline"
  jq -r '.osrel_last_good' "$FAKE_SECTIONS_JSON" >"$SPAWN_ETC_ROOT/spawn-arch/uki-last-good.os-release"
  cp "$REPO_ROOT/payload/etc/mkinitcpio.conf.d/spawn-arch.conf" "$SPAWN_ETC_ROOT/mkinitcpio.conf.d/spawn-arch.conf"
  cp "$REPO_ROOT/payload/etc/plymouth/plymouthd.conf" "$SPAWN_ETC_ROOT/plymouth/plymouthd.conf"
  printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Exec=firewall-applet' \
    >"$SPAWN_ETC_ROOT/xdg/autostart/firewall-applet.desktop"
  cp "$REPO_ROOT/payload/etc/systemd/system/docker.service.d/10-spawn-arch-ordering.conf" \
    "$SPAWN_ETC_ROOT/systemd/system/docker.service.d/10-spawn-arch-ordering.conf"
  cp "$REPO_ROOT/payload/etc/systemd/system/systemd-pcrlogin@.service.d/10-spawn-arch-disable.conf" \
    "$SPAWN_ETC_ROOT/systemd/system/systemd-pcrlogin@.service.d/10-spawn-arch-disable.conf"
  printf 'fixture-current-uki\n' >"$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-current.efi"
  printf 'fixture-last-good-uki\n' >"$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-last-good.efi"
  printf '%s\0' \
    'XDG_RUNTIME_DIR=/run/user/1000' \
    'WAYLAND_DISPLAY=wayland-0' \
    'DISPLAY=:0' \
    'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus' \
    'SSH_AUTH_SOCK=/run/user/1000/ssh-agent.socket' \
    'SSH_ASKPASS=/usr/bin/ksshaskpass' \
    'SSH_ASKPASS_REQUIRE=prefer' \
    'STARSHIP_CONFIG=/etc/starship.toml' \
    >"$SPAWN_PROC_ROOT/1234/environ"
  make_command_fakes
  # shellcheck source=/dev/null
  source "$REPO_ROOT/payload/usr/local/lib/spawn-arch/verify.sh"
  write_state blessed
  decode_hex_fixture "$REPO_ROOT/tests/fixtures/efi/loader-entry-current.bin" "$SPAWN_EFIVAR_PATH"
}

decode_hex_fixture() {
  local source="$1"
  local destination="$2"
  local hex index

  hex="$(tr -d '[:space:]' <"$source")"
  : >"$destination"
  for ((index = 0; index < ${#hex}; index += 2)); do
    printf '%b' "\\x${hex:index:2}" >>"$destination"
  done
}

write_state() {
  local mode="$1"
  local current_hash last_good_hash pending blessed generation state

  current_hash="$(sha256sum "$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-current.efi" | awk '{print $1}')"
  last_good_hash="$(sha256sum "$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-last-good.efi" | awk '{print $1}')"
  pending=null
  blessed=true
  generation=1
  if [[ "$mode" == pending ]]; then
    blessed=false
    generation=2
    pending="$(jq -n --arg hash "$current_hash" '{
      kind: "pacman", pre_snapshot_id: 7394,
      previous_current_sha256: $hash,
      packages: ["linux", "systemd"],
      created_at: "2026-07-16T00:00:00Z"
    }')"
  fi
  state="$(jq -n \
    --arg current "$current_hash" --arg last_good "$last_good_hash" \
    --argjson pending "$pending" --argjson blessed "$blessed" --argjson generation "$generation" '{
      schema_version: 1,
      generation: $generation,
      current: {entry: "spawn-arch-current", sha256: $current, blessed: $blessed},
      last_good: {entry: "spawn-arch-last-good", sha256: $last_good},
      pending: $pending,
      seed: {subvolume_id: 256, retired: false, safety_snapshot_id: null}
    }')"
  jq -S . <<<"$state" >"$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json"
  chmod 0600 "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json"
}

write_rollback_state() {
  local current_hash last_good_hash state

  current_hash="$(sha256sum "$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-current.efi" | awk '{print $1}')"
  last_good_hash="$(sha256sum "$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-last-good.efi" | awk '{print $1}')"
  state="$(jq -n --arg current "$current_hash" --arg last_good "$last_good_hash" '{
    schema_version: 1,
    generation: 2,
    current: {entry: "spawn-arch-current", sha256: $current, blessed: false},
    last_good: {entry: "spawn-arch-last-good", sha256: $last_good},
    pending: {
      kind: "rollback",
      target_snapshot_id: 7394,
      new_default_subvolume_id: 256,
      previous_default_subvolume_id: 111,
      safety_snapshot_id: 7401,
      previous_current_sha256: $current,
      created_at: "2026-07-16T00:00:00Z"
    },
    seed: {subvolume_id: 111, retired: false, safety_snapshot_id: null}
  }')"
  jq -S . <<<"$state" >"$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json"
  chmod 0600 "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json"
}

make_command_fakes() {
  local fake_bin="$BATS_TEST_TMPDIR/bin"
  local command_name

  mkdir -p "$fake_bin"
  cat >"$fake_bin/objcopy" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$FAKE_FAIL" != uki ]] || exit 1
args=("$@")
input="${args[${#args[@]} - 1]}"
slot=current
[[ "$input" == *last-good* ]] && slot=last_good
for argument in "${args[@]}"; do
  case "$argument" in
    .linux=*) jq -r '.linux' "$FAKE_SECTIONS_JSON" >"${argument#*=}" ;;
    .initrd=*) jq -r '.initrd' "$FAKE_SECTIONS_JSON" >"${argument#*=}" ;;
    .uname=*) jq -r '.uname' "$FAKE_SECTIONS_JSON" >"${argument#*=}" ;;
    .cmdline=*) jq -r '.cmdline' "$FAKE_SECTIONS_JSON" >"${argument#*=}" ;;
    .osrel=*) jq -r ".osrel_${slot}" "$FAKE_SECTIONS_JSON" >"${argument#*=}" ;;
  esac
done
FAKE
  cat >"$fake_bin/fake-command" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
name="$(basename "$0")"
case "$name:$*" in
  "uname:-r")
    [[ "$FAKE_FAIL" != kernel ]] || { printf 'wrong-kernel\n'; exit 0; }
    printf '6.15.7-arch1-1\n'
    ;;
  "findmnt:-n -o FSTYPE --target /")
    [[ "$FAKE_FAIL" != root ]] || { printf 'ext4\n'; exit 0; }
    printf 'btrfs\n'
    ;;
  "findmnt:-n -o SOURCE --target /") printf '/dev/mapper/cryptroot\n' ;;
  "findmnt:-n -o OPTIONS --target /") printf 'rw,noatime,compress=zstd:1,nodiscard\n' ;;
  "findmnt:-rn -t btrfs -o TARGET") printf '/\n' ;;
  "btrfs:subvolume show /")
    [[ "$FAKE_FAIL" != root ]] || exit 1
    printf 'Subvolume ID:\t\t256\n'
    ;;
  "btrfs:subvolume get-default /")
    [[ "$FAKE_FAIL" != root ]] || exit 1
    printf 'ID 256 gen 1 top level 5 path @\n'
    ;;
  "btrfs:subvolume show "*"/seed-retire."*"/@")
    [[ ! -e "$BATS_TEST_TMPDIR/seed-deleted" ]] || exit 1
    [[ "$FAKE_FAIL" != seed_cleanup ]] || { printf 'Subvolume ID:\t\t999\n'; exit 0; }
    printf 'Subvolume ID:\t\t111\n'
    ;;
  "btrfs:subvolume list "*"/seed-retire."*)
    [[ ! -e "$BATS_TEST_TMPDIR/seed-deleted" && "$FAKE_FAIL" == seed_cleanup ]] && printf 'ID 111 gen 1 top level 5 path @\n'
    ;;
  "btrfs:subvolume delete "*"/seed-retire."*"/@")
    touch "$BATS_TEST_TMPDIR/seed-deleted"
    rmdir -- "${*: -1}"
    ;;
  "cryptsetup:status cryptroot")
    [[ "$FAKE_FAIL" != luks ]] || exit 1
    printf '%s\n' '/dev/mapper/cryptroot is active' '  device: /dev/nvme0n1p2'
    ;;
  "blkid:-s UUID -o value -- /dev/nvme0n1p2") printf '11111111-2222-3333-4444-555555555555\n' ;;
  "bootctl:"*"status")
    [[ "$FAKE_FAIL" != bootloader ]] || exit 1
    printf 'Product: systemd-boot 258\n'
    ;;
  "bootctl:"*"is-installed") [[ "$FAKE_FAIL" != bootloader ]] ;;
  "bootctl:"*"--json=short"*"list")
    [[ "$FAKE_FAIL" != bootloader ]] || exit 1
    printf '%s\n' '[{"type":"type2","source":"uki","id":"spawn-arch-current.efi","path":"/boot/EFI/Linux/spawn-arch-current.efi"},{"type":"type2","source":"uki","id":"spawn-arch-last-good.efi","path":"/boot/EFI/Linux/spawn-arch-last-good.efi"}]'
    ;;
  "bootctl:"*"list")
    [[ "$FAKE_FAIL" != bootloader ]] || exit 1
    printf '%s\n' 'Boot Loader Entries:' '  type: Boot Loader Specification Type #2 (.efi)' '    id: spawn-arch-current.efi' 'source: /boot/EFI/Linux/spawn-arch-current.efi' '  type: Boot Loader Specification Type #2 (.efi)' '    id: spawn-arch-last-good.efi' 'source: /boot/EFI/Linux/spawn-arch-last-good.efi'
    ;;
  "systemctl:is-active --quiet docker.service") [[ "$FAKE_FAIL" != docker ]] ;;
  "systemctl:is-active --quiet firewalld.service") [[ "$FAKE_FAIL" != firewall ]] ;;
  "systemctl:is-active --quiet arch-audit.timer") [[ "$FAKE_FAIL" != package_audit ]] ;;
  "systemctl:is-active --quiet"*) [[ "$FAKE_FAIL" != services ]] ;;
  "systemctl:show --property=After --value docker.service")
    [[ "$FAKE_FAIL" != service_policy ]] && printf 'network-online.target firewalld.service basic.target\n' || printf 'basic.target\n'
    ;;
  "systemctl:show --property=Wants --value docker.service")
    printf 'network-online.target firewalld.service\n'
    ;;
  "plymouth-set-default-theme:")
    [[ "$FAKE_FAIL" != boot_ui ]] && printf 'breeze\n' || printf 'details\n'
    ;;
  "docker:info --format {{json .Runtimes}}")
    [[ "$FAKE_FAIL" != docker ]] && printf '{"io.containerd.runc.v2":{},"nvidia":{}}\n'
    ;;
  "docker:info") [[ "$FAKE_FAIL" != docker ]] ;;
  "firewall-cmd:--get-default-zone")
    [[ "$FAKE_FAIL" != firewall ]] && printf 'spawn-workstation\n' || printf 'public\n'
    ;;
  "firewall-cmd:--get-log-denied") printf 'unicast\n' ;;
  "firewall-cmd:--zone=spawn-workstation --list-services" | \
  "firewall-cmd:--zone=spawn-workstation --list-ports") printf '\n' ;;
  "journalctl:--verify") [[ "$FAKE_FAIL" != journal ]] ;;
  "sysctl:-n kernel.dmesg_restrict") [[ "$FAKE_FAIL" != sysctl ]] && printf '1\n' || printf '0\n' ;;
  "sysctl:-n kernel.kptr_restrict") printf '2\n' ;;
  "sysctl:-n kernel.yama.ptrace_scope") printf '1\n' ;;
  "sysctl:-n fs.suid_dumpable") printf '0\n' ;;
  "sysctl:-n net.ipv4.conf.all.accept_redirects" | \
  "sysctl:-n net.ipv4.conf.default.accept_redirects" | \
  "sysctl:-n net.ipv6.conf.all.accept_redirects" | \
  "sysctl:-n net.ipv6.conf.default.accept_redirects" | \
  "sysctl:-n net.ipv4.conf.all.send_redirects" | \
  "sysctl:-n net.ipv4.conf.default.send_redirects") printf '0\n' ;;
  "swapon:--show --json --bytes")
    if [[ "$FAKE_FAIL" == zram ]]; then
      printf '{"swapdevices":[{"name":"/dev/nvme0n1p3","type":"partition","prio":-2}]}\n'
    else
      printf '{"swapdevices":[{"name":"/dev/zram0","type":"partition","prio":100}]}\n'
    fi
    ;;
  "powerprofilesctl:get")
    [[ "$FAKE_FAIL" != power ]] && printf 'balanced\n' || printf 'performance\n'
    ;;
  "snapper:"*)
    if [[ "$FAKE_FAIL" == pending_snapshot ]]; then
      printf '{"root":[]}\n'
    else
      cat "$FAKE_SNAPPER_JSON"
    fi
    ;;
  "loginctl:list-sessions --no-legend --no-pager") printf '7 1000 evynore seat0 tty2\n' ;;
  "loginctl:show-session 7"*)
    if [[ "$FAKE_FAIL" == session ]]; then
      printf '%s\n' 'Active=yes' 'Remote=no' 'Type=x11' 'Class=user' 'Name=evynore' 'Desktop=KDE' 'Leader=1234'
    else
      printf '%s\n' 'Active=yes' 'Remote=no' 'Type=wayland' 'Class=user' 'Name=evynore' 'Desktop=KDE' 'Leader=1234'
    fi
    ;;
  "id:-u evynore") printf '1000\n' ;;
  "id:-nG -- evynore") printf 'wheel\n' ;;
  "runuser:"*)
    if [[ "$*" == *"systemctl --user is-active --quiet pipewire.service pipewire-pulse.service wireplumber.service"* ]]; then
      [[ "$FAKE_FAIL" != audio ]]
    elif [[ "$*" == *"systemctl --user is-active --quiet ssh-agent.service"* ]]; then
      [[ "$FAKE_FAIL" != ssh_agent ]]
    elif [[ "$*" == *"ssh-add -l"* ]]; then
      [[ "$FAKE_FAIL" != ssh_agent ]] || exit 2
      exit 1
    elif [[ "$*" == *"ssh -G example.invalid"* ]]; then
      [[ "$FAKE_FAIL" != ssh_wallet ]] || exit 1
      printf 'addkeystoagent yes\n'
    elif [[ "$*" == *"zsh -lic"* ]]; then
      [[ "$FAKE_FAIL" != shell ]]
    elif [[ "$*" == *"prime-run glxinfo -B"* ]]; then
      [[ "$FAKE_FAIL" != prime ]] && printf 'OpenGL renderer string: NVIDIA GeForce RTX 5090\n' || printf 'OpenGL renderer string: Intel\n'
    elif [[ "$*" == *"vulkaninfo --summary"* ]]; then
      [[ "$FAKE_FAIL" != intel_vulkan ]] && printf 'deviceName = Intel Graphics\n' || printf 'deviceName = llvmpipe\n'
    else
      [[ "$FAKE_FAIL" != intel_glx ]] && printf 'OpenGL renderer string: Mesa Intel Graphics\n' || printf 'OpenGL renderer string: llvmpipe\n'
    fi
    ;;
  "nvidia-smi:"*) [[ "$FAKE_FAIL" != nvidia ]] ;;
  "mount:-t btrfs -o subvolid=5 -- "*) mkdir -p -- "${*: -1}/@" ;;
  "umount:-- "*) exit 0 ;;
  *) exit 0 ;;
esac
FAKE
  chmod +x "$fake_bin/objcopy" "$fake_bin/fake-command"
  for command_name in \
    blkid bootctl btrfs cryptsetup docker findmnt firewall-cmd id journalctl loginctl nvidia-smi \
    mount plymouth-set-default-theme powerprofilesctl runuser snapper swapon sysctl systemctl umount uname; do
    ln -s fake-command "$fake_bin/$command_name"
  done
  export PATH="$fake_bin:$PATH"
}

@test "healthy baseline emits an all-green named report" {
  run verify_run

  [ "$status" -eq 0 ]
  jq -e '
    .ok == true and .state_generation == 1 and
    ([.checks[] | select(.ok == false)] | length == 0) and
    ([.checks[].name] | length == 26) and
    any(.checks[]; .name == "ssh_wallet" and .ok == true) and
    any(.checks[]; .name == "shell" and .ok == true) and
    any(.checks[]; .name == "boot_ui" and .ok == true) and
    any(.checks[]; .name == "service_policy" and .ok == true)
  ' <<<"$output"
}

@test "every hard-check failure is named and independently prevents blessing" {
  local failure check
  local -a matrix=(
    'kernel:running_kernel'
    'uki:current_uki'
    'root:root_default'
    'luks:luks_mapping'
    'bootloader:bootloader'
    'session:plasma_wayland'
    'intel_glx:intel_glx'
    'intel_vulkan:intel_vulkan'
    'prime:nvidia_prime'
    'nvidia:nvidia_smi'
    'power:power_profile'
    'services:services'
    'boot_ui:boot_ui'
    'service_policy:service_policy'
    'zram:zram'
    'audio:audio'
    'ssh_agent:ssh_agent'
    'ssh_wallet:ssh_wallet'
    'shell:shell'
    'docker:docker'
    'firewall:firewall'
    'journal:journal'
    'package_audit:package_audit'
    'sysctl:sysctl'
  )

  for item in "${matrix[@]}"; do
    failure="${item%%:*}"
    check="${item#*:}"
    export FAKE_FAIL="$failure"
    run verify_build_report
    [ "$status" -eq 0 ]
    jq -e --arg check "$check" '.ok == false and any(.checks[]; .name == $check and .ok == false)' <<<"$output"
  done

  export FAKE_FAIL=none
  decode_hex_fixture "$REPO_ROOT/tests/fixtures/efi/loader-entry-last-good.bin" "$SPAWN_EFIVAR_PATH"
  run verify_build_report
  jq -e '.ok == false and any(.checks[]; .name == "selected_entry" and .ok == false)' <<<"$output"

  decode_hex_fixture "$REPO_ROOT/tests/fixtures/efi/loader-entry-current.bin" "$SPAWN_EFIVAR_PATH"
  write_state pending
  export FAKE_FAIL=pending_snapshot
  run verify_build_report
  jq -e '.ok == false and any(.checks[]; .name == "pending_snapshot" and .ok == false)' <<<"$output"
}

@test "bless records the observed hash and rejects a generation race" {
  local report raced

  report="$(verify_build_report)"
  verify_commit_bless "$report"
  jq -e '.generation == 2 and .current.blessed == true and .pending == null' \
    "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json"
  [ -e "$SPAWN_VAR_LIB_ROOT/power-profile-verified" ]

  report="$(verify_build_report)"
  raced="$(jq '.generation += 1' "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json")"
  boot_state_write "$raced"
  run verify_commit_bless "$report"
  [ "$status" -ne 0 ]
  jq -e '.generation == 3' "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json"
}

@test "pending pacman boot may change current hash and is blessed only after checks" {
  local new_hash

  write_state pending
  printf 'updated-current-uki\n' >"$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-current.efi"
  new_hash="$(sha256sum "$SPAWN_BOOT_ROOT/EFI/Linux/spawn-arch-current.efi" | awk '{print $1}')"

  run verify_and_bless

  [ "$status" -eq 0 ]
  jq -e --arg hash "$new_hash" '
    .generation == 3 and .current.sha256 == $hash and
    .current.blessed == true and .pending == null
  ' "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json"
}

@test "rollback blessing retires the seed only after every conservative proof" {
  write_rollback_state

  run verify_and_bless

  [ "$status" -eq 0 ]
  [ -e "$BATS_TEST_TMPDIR/seed-deleted" ]
  jq -e '
    .generation == 4 and .current.blessed == true and .pending == null and
    .seed == {subvolume_id: 111, retired: true, safety_snapshot_id: 7401}
  ' "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json"
}

@test "failed seed proof leaves it intact without invalidating a healthy blessing" {
  write_rollback_state
  export FAKE_FAIL=seed_cleanup

  run verify_and_bless

  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/seed-deleted" ]
  jq -e '
    .generation == 3 and .current.blessed == true and .pending == null and
    .seed == {subvolume_id: 111, retired: false, safety_snapshot_id: 7401}
  ' "$SPAWN_BOOT_ROOT/loader/spawn-arch-state.json"
}
