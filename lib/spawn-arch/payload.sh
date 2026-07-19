#!/usr/bin/env bash

if ! declare -F die >/dev/null 2>&1; then
  _spawn_payload_module_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  # shellcheck source=lib/spawn-arch/common.sh
  source "$_spawn_payload_module_dir/common.sh"
  unset _spawn_payload_module_dir
fi

payload_install() {
  local target_root="$1"
  local repository_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
  local payload_root="$repository_root/payload"

  if [[ ! -d "$target_root" || ! -d "$payload_root/etc" ]]; then
    die "target root or payload tree is unavailable" 65
    return $?
  fi
  if [[ -e "$target_root/etc/sudoers.d/10-wheel" ]]; then
    chmod u+w -- "$target_root/etc/sudoers.d/10-wheel" || return $?
  fi
  cp -a -- "$payload_root/." "$target_root/" || return $?
  chmod 0440 -- "$target_root/etc/sudoers.d/10-wheel" || return $?
  if [[ -e "$target_root/usr/local/bin/spawn-arch" ]]; then
    chmod 0755 -- "$target_root/usr/local/bin/spawn-arch" || return $?
  fi
  if [[ -d "$target_root/usr/local/lib/spawn-arch" ]]; then
    find "$target_root/usr/local/lib/spawn-arch" -type f -name '*.sh' -exec chmod 0644 -- {} + || return $?
    if [[ -e "$target_root/usr/local/lib/spawn-arch/preserve-uki.sh" ]]; then
      chmod 0755 -- "$target_root/usr/local/lib/spawn-arch/preserve-uki.sh" || return $?
    fi
  fi
}
