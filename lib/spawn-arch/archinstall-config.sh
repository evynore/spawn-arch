#!/usr/bin/env bash

_spawn_archinstall_config_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if ! declare -F die >/dev/null 2>&1; then
  # shellcheck source=lib/spawn-arch/common.sh
  source "$_spawn_archinstall_config_dir/common.sh"
fi
if ! declare -F packages_json >/dev/null 2>&1; then
  # shellcheck source=lib/spawn-arch/config.sh
  source "$_spawn_archinstall_config_dir/config.sh"
fi

_spawn_uuid() {
  local uuid

  if ! IFS= read -r uuid </proc/sys/kernel/random/uuid; then
    die "kernel UUID generator is unavailable" 69
    return $?
  fi
  if [[ ! "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; then
    die "kernel returned an invalid UUID" 70
    return $?
  fi
  printf '%s\n' "$uuid"
}

_materialized_write() {
  local output_path="$1"
  local temporary="$2"

  install -d -m 0700 -- "$(dirname -- "$output_path")" || return $?
  chmod 0600 -- "$temporary" || return $?
  atomic_replace "$temporary" "$output_path"
}

_assert_plan_materializable() {
  local plan_json="$1"

  if ! jq -e '
    .schema_version == 1 and
    (.target.device_at_plan_time | type == "string" and startswith("/dev/")) and
    (.target.identity.logical_sector_bytes | type == "number" and . > 0) and
    (.storage.geometry.esp.start_bytes | type == "number" and . > 0) and
    (.storage.geometry.esp.size_bytes | type == "number" and . > 0) and
    (.storage.geometry.root.start_bytes | type == "number" and . > 0) and
    (.storage.geometry.root.size_bytes | type == "number" and . > 0) and
    .storage.subvolumes == ["@", "@home", "@log", "@pkg", "@snapshots"] and
    (.system.hostname | type == "string" and length > 0) and
    (.system.username | type == "string" and length > 0) and
    .archinstall.schema_commit == "3ece182d31dda7b14abd56d13abf3ff79a5717ae"
  ' >/dev/null <<<"$plan_json"; then
    die "plan is incomplete or incompatible with the Archinstall 4.4 materializer" 65
    return $?
  fi
}

archinstall_user_config() {
  local plan_json="$1"
  local output_path="$2"
  local esp_id root_id packages temporary

  _assert_plan_materializable "$plan_json" || return $?
  esp_id="$(_spawn_uuid)" || return $?
  root_id="$(_spawn_uuid)" || return $?
  packages="$(packages_json "${REPO_ROOT:-$_spawn_archinstall_config_dir/../..}/config/packages.txt")" || return $?
  temporary="$(mktemp "${output_path}.tmp.XXXXXX")" || return $?

  if ! jq -n \
    --argjson plan "$plan_json" \
    --argjson packages "$packages" \
    --arg esp_id "$esp_id" \
    --arg root_id "$root_id" '
      def size($value; $sector):
        {value: $value, unit: "B", sector_size: {value: $sector, unit: "B"}};
      ($plan.target.identity.logical_sector_bytes) as $sector
      | {
          "archinstall-language": "English",
          locale_config: {
            kb_layout: "",
            sys_enc: "UTF-8",
            sys_lang: ($plan.system.locale | sub("\\.UTF-8$"; ""))
          },
          bootloader_config: {
            bootloader: "Systemd-boot",
            uki: true,
            removable: false
          },
          network_config: {type: "nm"},
          profile_config: {
            gfx_driver: "Nvidia (open kernel module for newer GPUs, Turing+)",
            greeter: "plasma-login-manager",
            profile: {
              main: "Desktop",
              details: ["KDE Plasma"],
              custom_settings: {"KDE Plasma": {plasma_flavor: "plasma-meta"}}
            }
          },
          app_config: {
            bluetooth_config: {enabled: true},
            audio_config: {audio: "pipewire"},
            power_management_config: {power_management: "power-profiles-daemon"},
            firewall_config: {firewall: "firewalld"},
            fonts_config: {fonts: ["noto-fonts", "noto-fonts-emoji", "ttf-liberation"]}
          },
          disk_config: {
            config_type: "manual_partitioning",
            device_modifications: [
              {
                device: $plan.target.device_at_plan_time,
                wipe: true,
                partitions: [
                  {
                    obj_id: $esp_id,
                    status: "create",
                    type: "primary",
                    start: size($plan.storage.geometry.esp.start_bytes; $sector),
                    size: size($plan.storage.geometry.esp.size_bytes; $sector),
                    fs_type: "fat32",
                    mountpoint: "/boot",
                    mount_options: [],
                    flags: ["boot", "esp"],
                    dev_path: null,
                    btrfs: []
                  },
                  {
                    obj_id: $root_id,
                    status: "create",
                    type: "primary",
                    start: size($plan.storage.geometry.root.start_bytes; $sector),
                    size: size($plan.storage.geometry.root.size_bytes; $sector),
                    fs_type: "btrfs",
                    mountpoint: null,
                    mount_options: ["noatime", "compress=zstd:1", "nodiscard"],
                    flags: [],
                    dev_path: null,
                    btrfs: [
                      {name: "@", mountpoint: "/"},
                      {name: "@home", mountpoint: "/home"},
                      {name: "@log", mountpoint: "/var/log"},
                      {name: "@pkg", mountpoint: "/var/cache/pacman/pkg"},
                      {name: "@snapshots", mountpoint: "/.snapshots"}
                    ]
                  }
                ]
              }
            ],
            disk_encryption: {
              encryption_type: "luks",
              partitions: [$root_id],
              lvm_volumes: []
            }
          },
          hostname: $plan.system.hostname,
          kernels: ["linux"],
          ntp: true,
          packages: $packages,
          services: ["NetworkManager", "bluetooth", "firewalld", "power-profiles-daemon"],
          swap: {enabled: false, algorithm: "zstd"},
          timezone: $plan.system.timezone,
          custom_commands: []
        }
    ' >"$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi

  _materialized_write "$output_path" "$temporary"
}

_yescrypt_from_stdin() {
  python3 -c 'import sys; from archinstall.lib.crypt import crypt_yescrypt; print(crypt_yescrypt(sys.stdin.read()))'
}

archinstall_credentials() {
  local plan_json="$1"
  local output_path="$2"
  local luks_fd="$3"
  local user_password_fd="$4"
  local luks_password user_password user_hash username temporary

  set +x
  _assert_plan_materializable "$plan_json" || return $?
  if [[ ! "$luks_fd" =~ ^[0-9]+$ || ! "$user_password_fd" =~ ^[0-9]+$ ]]; then
    die "credential inputs must be open numeric file descriptors" 64
    return $?
  fi
  if ! IFS= read -r luks_password <&"$luks_fd" || [[ -z "$luks_password" ]]; then
    unset luks_password
    die "LUKS passphrase input is empty or unreadable" 65
    return $?
  fi
  if ! IFS= read -r user_password <&"$user_password_fd" || [[ -z "$user_password" ]]; then
    unset luks_password user_password
    die "user password input is empty or unreadable" 65
    return $?
  fi
  if ! user_hash="$(printf '%s' "$user_password" | _yescrypt_from_stdin)" || [[ ! "$user_hash" == \$y\$* ]]; then
    unset luks_password user_password user_hash
    die "Archinstall yescrypt hashing failed" 70
    return $?
  fi
  unset user_password
  username="$(jq -r '.system.username' <<<"$plan_json")" || return $?
  temporary="$(mktemp "${output_path}.tmp.XXXXXX")" || return $?

  if ! printf '%s\0%s\0%s' "$luks_password" "$username" "$user_hash" |
    jq -Rs '
      split("\u0000")
      | {
          encryption_password: .[0],
          users: [
            {
              username: .[1],
              enc_password: .[2],
              sudo: true,
              groups: ["wheel"]
            }
          ]
        }
    ' >"$temporary"; then
    rm -f -- "$temporary"
    unset luks_password user_hash
    return 1
  fi
  unset luks_password user_hash

  _materialized_write "$output_path" "$temporary" || return $?
  if declare -F credentials_register >/dev/null 2>&1; then
    credentials_register "$output_path" || return $?
  fi
}

archinstall_validate_materialized() {
  local user_config="$1"
  local credentials_config="$2"

  if [[ "$(stat -c %a -- "$user_config" 2>/dev/null || true)" != 600 ]] ||
    [[ "$(stat -c %a -- "$credentials_config" 2>/dev/null || true)" != 600 ]]; then
    die "materialized Archinstall files must use mode 0600" 65
    return $?
  fi
  if ! jq -e '
    (.custom_commands == []) and
    (.locale_config.kb_layout == "") and
    (has("debug") | not) and
    (has("encryption_password") | not) and
    (.disk_config.config_type == "manual_partitioning") and
    (.disk_config.device_modifications | length == 1) and
    (.disk_config.device_modifications[0].wipe == true) and
    (.disk_config.device_modifications[0].partitions | length == 2) and
    (.disk_config.device_modifications[0].partitions[0].flags == ["boot", "esp"]) and
    (.disk_config.device_modifications[0].partitions[1].mountpoint == null) and
    (.disk_config.device_modifications[0].partitions[1].btrfs | length == 5) and
    (.disk_config.disk_encryption.encryption_type == "luks") and
    (.disk_config.disk_encryption.lvm_volumes == []) and
    (.disk_config.disk_encryption.partitions == [
      .disk_config.device_modifications[0].partitions[1].obj_id
    ]) and
    (.swap == {enabled: false, algorithm: "zstd"})
  ' "$user_config" >/dev/null; then
    die "user configuration violates the pinned Archinstall contract" 65
    return $?
  fi
  if ! jq -e '
    (.encryption_password | type == "string" and length > 0) and
    (.users | length == 1) and
    (.users[0].username | type == "string" and length > 0) and
    (.users[0].enc_password | startswith("$y$")) and
    .users[0].sudo == true and
    .users[0].groups == ["wheel"] and
    (has("root_enc_password") | not)
  ' "$credentials_config" >/dev/null; then
    die "credential configuration violates the pinned Archinstall contract" 65
    return $?
  fi
}
