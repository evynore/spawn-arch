#!/usr/bin/env bash

if ! declare -F die >/dev/null 2>&1; then
  _spawn_prompt_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  # shellcheck source=lib/spawn-arch/common.sh
  source "$_spawn_prompt_dir/common.sh"
  unset _spawn_prompt_dir
fi

validate_hostname() {
  local hostname="$1"
  local label
  local -a labels=()

  if ((${#hostname} == 0 || ${#hostname} > 253)); then
    die "hostname length is invalid" 65
    return $?
  fi
  IFS=. read -r -a labels <<<"$hostname"
  for label in "${labels[@]}"; do
    if ((${#label} == 0 || ${#label} > 63)) || [[ ! "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
      die "invalid Linux hostname: $hostname" 65
      return $?
    fi
  done
}

validate_username() {
  local username="$1"

  if [[ "$username" == root ]] || [[ ! "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    die "invalid non-root username: $username" 65
    return $?
  fi
}

validate_timezone() {
  local timezone="$1"
  local root="${SPAWN_ZONEINFO_ROOT:-/usr/share/zoneinfo}"
  local root_real candidate

  if [[ ! "$timezone" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)+$ ]]; then
    die "invalid timezone name: $timezone" 65
    return $?
  fi
  root_real="$(readlink -f -- "$root" 2>/dev/null || true)"
  candidate="$(readlink -f -- "$root/$timezone" 2>/dev/null || true)"
  if [[ -z "$root_real" || -z "$candidate" || "$candidate" != "$root_real"/* || ! -f "$candidate" ]]; then
    die "timezone does not exist: $timezone" 65
    return $?
  fi
}

validate_keymap() {
  local keymap="$1"
  local root="${SPAWN_KEYMAP_ROOT:-/usr/share/kbd/keymaps}"

  if [[ ! "$keymap" =~ ^[A-Za-z0-9_-]+$ ]] ||
    [[ -z "$(find "$root" -type f \( -name "$keymap.map" -o -name "$keymap.map.gz" \) -print -quit 2>/dev/null)" ]]; then
    die "keymap does not exist: $keymap" 65
    return $?
  fi
}

validate_locale() {
  local locale="$1"
  local locale_gen="${SPAWN_LOCALE_GEN:-/etc/locale.gen}"
  local escaped

  if [[ ! "$locale" =~ ^[A-Za-z][A-Za-z0-9_@.-]*$ ]]; then
    die "invalid locale name: $locale" 65
    return $?
  fi
  escaped="${locale//./\\.}"
  if ! grep -Eq "^[#[:space:]]*${escaped}[[:space:]]+UTF-8([[:space:]]|$)" "$locale_gen" 2>/dev/null; then
    die "locale is unavailable: $locale" 65
    return $?
  fi
}

generated_locales_json() {
  local primary="$1"

  validate_locale "$primary" || return $?
  printf '%s\n%s\n' "$primary" ru_RU.UTF-8 | jq -Rsc \
    'split("\n") | map(select(length > 0)) | unique'
}

prompt_value_into() {
  local output_name="$1"
  local label="$2"
  local default_value="$3"
  local tty_path="${SPAWN_TTY_PATH:-/dev/tty}"
  local value

  if [[ ! "$output_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    die "invalid prompt output variable name" 64
    return $?
  fi
  printf '%s [%s]: ' "$label" "$default_value" >&2
  if ! IFS= read -r value <"$tty_path"; then
    die "input ended while reading $label" 65
    return $?
  fi
  [[ -n "$value" ]] || value="$default_value"
  printf -v "$output_name" '%s' "$value"
}

prompt_password_into() {
  local output_name="$1"
  local label="$2"
  local tty_path="${SPAWN_TTY_PATH:-/dev/tty}"
  local first second tty_fd

  set +x
  if [[ ! "$output_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    die "invalid password output variable name" 64
    return $?
  fi
  if ! exec {tty_fd}<"$tty_path"; then
    die "cannot open terminal for password input" 65
    return $?
  fi
  printf '%s: ' "$label" >&2
  IFS= read -r -s first <&"$tty_fd" || true
  printf '\nConfirm %s: ' "$label" >&2
  IFS= read -r -s second <&"$tty_fd" || true
  printf '\n' >&2
  exec {tty_fd}<&-

  if [[ -z "$first" || "$first" != "$second" ]]; then
    unset first second
    die "passwords are empty or do not match" 65
    return $?
  fi
  printf -v "$output_name" '%s' "$first"
  unset first second
}
