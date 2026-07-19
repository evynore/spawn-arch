#!/usr/bin/env bash

if ! declare -F die >/dev/null 2>&1; then
  _spawn_config_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  # shellcheck source=lib/spawn-arch/common.sh
  source "$_spawn_config_dir/common.sh"
  unset _spawn_config_dir
fi

packages_json() {
  local package_file="$1"
  local line package
  local -a packages=()
  local -A seen=()

  if [[ ! -r "$package_file" ]]; then
    die "package file is not readable: $package_file"
    return $?
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    package="${line%%#*}"
    package="${package//[[:space:]]/}"
    [[ -n "$package" ]] || continue
    if [[ ! "$package" =~ ^[a-z0-9@._+-]+$ ]]; then
      die "invalid package name: $package"
      return $?
    fi
    if [[ -n "${seen[$package]:-}" ]]; then
      die "duplicate package: $package"
      return $?
    fi
    seen[$package]=1
    packages+=("$package")
  done <"$package_file"

  if ((${#packages[@]} == 0)); then
    die "package file is empty: $package_file"
    return $?
  fi
  printf '%s\n' "${packages[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))'
}
