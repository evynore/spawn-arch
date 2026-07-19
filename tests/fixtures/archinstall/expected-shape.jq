(."archinstall-language" == "English") and
(.locale_config == {kb_layout: "", sys_enc: "UTF-8", sys_lang: "en_US"}) and
(.bootloader_config == {bootloader: "Systemd-boot", uki: true, removable: false}) and
(.network_config == {type: "nm"}) and
(.profile_config == {
  gfx_driver: "Nvidia (open kernel module for newer GPUs, Turing+)",
  greeter: "plasma-login-manager",
  profile: {
    main: "Desktop",
    details: ["KDE Plasma"],
    custom_settings: {"KDE Plasma": {plasma_flavor: "plasma-meta"}}
  }
}) and
(.app_config == {
  bluetooth_config: {enabled: true},
  audio_config: {audio: "pipewire"},
  power_management_config: {power_management: "power-profiles-daemon"},
  firewall_config: {firewall: "firewalld"},
  fonts_config: {fonts: ["noto-fonts", "noto-fonts-emoji", "ttf-liberation"]}
}) and
(.swap == {enabled: false, algorithm: "zstd"}) and
(.custom_commands == []) and
(.kernels == ["linux"]) and
(.ntp == true) and
(.hostname == "spawn") and
(.timezone == "Etc/UTC") and
(.disk_config.config_type == "manual_partitioning") and
(.disk_config.device_modifications | length == 1) and
(.disk_config.device_modifications[0].device == "/dev/nvme1n1") and
(.disk_config.device_modifications[0].wipe == true) and
(.disk_config.device_modifications[0].partitions | length == 2) and
(.disk_config.device_modifications[0].partitions[0] |
  .status == "create" and .type == "primary" and .fs_type == "fat32" and
  .mountpoint == "/boot" and .flags == ["boot", "esp"] and
  .start == {value: 1048576, unit: "B", sector_size: {value: 512, unit: "B"}} and
  .size == {value: 2147483648, unit: "B", sector_size: {value: 512, unit: "B"}}) and
(.disk_config.device_modifications[0].partitions[1] |
  .status == "create" and .type == "primary" and .fs_type == "btrfs" and
  .mountpoint == null and .flags == [] and
  .mount_options == ["noatime", "compress=zstd:1", "nodiscard"] and
  .start == {value: 2148532224, unit: "B", sector_size: {value: 512, unit: "B"}} and
  .size == {value: 1998249263104, unit: "B", sector_size: {value: 512, unit: "B"}} and
  .btrfs == [
    {name: "@", mountpoint: "/"},
    {name: "@home", mountpoint: "/home"},
    {name: "@log", mountpoint: "/var/log"},
    {name: "@pkg", mountpoint: "/var/cache/pacman/pkg"},
    {name: "@snapshots", mountpoint: "/.snapshots"}
  ]) and
(.disk_config.disk_encryption.encryption_type == "luks") and
(.disk_config.disk_encryption.lvm_volumes == []) and
(.disk_config.disk_encryption.partitions == [
  .disk_config.device_modifications[0].partitions[1].obj_id
])
