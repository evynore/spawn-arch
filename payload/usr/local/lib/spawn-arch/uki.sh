#!/usr/bin/env bash

_spawn_uki_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if ! declare -F safe_basename >/dev/null 2>&1; then
  # shellcheck source=payload/usr/local/lib/spawn-arch/common.sh
  source "$_spawn_uki_dir/common.sh"
fi

boot_selected_entry() {
  local efivar_path="${SPAWN_EFIVAR_PATH:-/sys/firmware/efi/efivars/LoaderEntrySelected-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f}"

  python3 - "$efivar_path" <<'PY'
import pathlib
import sys

raw = pathlib.Path(sys.argv[1]).read_bytes()
if len(raw) < 6 or (len(raw) - 4) % 2:
    raise SystemExit(65)
try:
    value = raw[4:].decode("utf-16-le")
except UnicodeDecodeError:
    raise SystemExit(65)
if value.endswith("\0"):
    value = value[:-1]
if "\0" in value or value not in {"spawn-arch-current", "spawn-arch-last-good"}:
    raise SystemExit(65)
print(value)
PY
}

_uki_section_text() {
  python3 - "$1" <<'PY'
import pathlib
import sys

value = pathlib.Path(sys.argv[1]).read_bytes().rstrip(b"\0\n")
try:
    print(value.decode("utf-8"), end="")
except UnicodeDecodeError:
    raise SystemExit(65)
PY
}

_uki_cmdline_text() {
  python3 - "$1" <<'PY'
import pathlib
import sys

value = pathlib.Path(sys.argv[1]).read_bytes().rstrip(b"\0\t\n\r ")
try:
    print(value.decode("utf-8"), end="")
except UnicodeDecodeError:
    raise SystemExit(65)
PY
}

_uki_osrel_value() {
  local osrel_path="$1"
  local key="$2"

  python3 - "$osrel_path" "$key" <<'PY'
import pathlib
import shlex
import sys

try:
    text = pathlib.Path(sys.argv[1]).read_bytes().rstrip(b"\0\t\n\r ").decode("utf-8")
except UnicodeDecodeError:
    raise SystemExit(65)
for raw_line in text.splitlines():
    if not raw_line or raw_line.startswith("#") or "=" not in raw_line:
        continue
    name, raw_value = raw_line.split("=", 1)
    if name == sys.argv[2]:
        try:
            values = shlex.split(raw_value)
        except ValueError:
            raise SystemExit(65)
        if len(values) != 1:
            raise SystemExit(65)
        print(values[0])
        raise SystemExit(0)
raise SystemExit(65)
PY
}

_uki_osrel_set_version() {
  local source_path="$1"
  local destination_path="$2"
  local version="$3"

  python3 - "$source_path" "$destination_path" "$version" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
version = sys.argv[3]
if re.fullmatch(r"[0-9A-Za-z._+~-]+", version) is None:
    raise SystemExit(65)
lines = source.read_text(encoding="utf-8").splitlines()
matches = 0
for index, line in enumerate(lines):
    if line.split("=", 1)[0] == "VERSION_ID":
        lines[index] = f"VERSION_ID={version}"
        matches += 1
if matches != 1:
    raise SystemExit(65)
destination.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

_uki_version_slot_tag() {
  case "$1" in
    current) printf 'current\n' ;;
    last-good) printf 'lg\n' ;;
    *) return 65 ;;
  esac
}

uki_section_read() {
  local uki_path="$1"
  local section="$2"
  local work_dir inspection_path section_path status

  case "$section" in
    .linux | .initrd | .cmdline | .osrel | .uname) ;;
    *) return 64 ;;
  esac
  [[ -s "$uki_path" ]] || return 65
  install -d -m 0700 -- "${SPAWN_INSTALLED_RUNTIME_DIR:-/run/spawn-arch}" || return $?
  work_dir="$(mktemp -d "${SPAWN_INSTALLED_RUNTIME_DIR:-/run/spawn-arch}/uki-section.XXXXXX")" || return $?
  inspection_path="$work_dir/$(basename -- "$uki_path")"
  section_path="$work_dir/${section#.}"
  if cp --reflink=auto --sparse=always -- "$uki_path" "$inspection_path" &&
    objcopy --dump-section "$section=$section_path" "$inspection_path" && [[ -s "$section_path" ]]; then
    if [[ "$section" == .cmdline ]]; then
      _uki_cmdline_text "$section_path"
    else
      _uki_section_text "$section_path"
    fi
    status=$?
  else
    status=65
  fi
  rm -rf -- "$work_dir"
  return "$status"
}

uki_validate() {
  local uki_path="$1"
  local expected_cmdline="$2"
  local expected_slot="$3"
  local require_visibility="${4:-true}"
  local work_dir inspection_path actual_cmdline uname version_id version_slot_tag pretty_name filename boot_list section

  [[ -s "$uki_path" ]] || return 65
  [[ "$expected_slot" == current || "$expected_slot" == last-good ]] || return 65
  version_slot_tag="$(_uki_version_slot_tag "$expected_slot")" || return $?
  if [[ "$expected_cmdline" == *rootflags=subvol* || "$expected_cmdline" == *subvolid=* ]]; then
    return 65
  fi
  install -d -m 0700 -- "${SPAWN_INSTALLED_RUNTIME_DIR:-/run/spawn-arch}" || return $?
  work_dir="$(mktemp -d "${SPAWN_INSTALLED_RUNTIME_DIR:-/run/spawn-arch}/uki-validate.XXXXXX")" || return $?
  inspection_path="$work_dir/$(basename -- "$uki_path")"
  if ! cp --reflink=auto --sparse=always -- "$uki_path" "$inspection_path" || ! objcopy \
    --dump-section ".linux=$work_dir/linux" \
    --dump-section ".initrd=$work_dir/initrd" \
    --dump-section ".cmdline=$work_dir/cmdline" \
    --dump-section ".osrel=$work_dir/osrel" \
    --dump-section ".uname=$work_dir/uname" \
    "$inspection_path"; then
    rm -rf -- "$work_dir"
    return 65
  fi
  for section in linux initrd cmdline osrel uname; do
    [[ -s "$work_dir/$section" ]] || {
      rm -rf -- "$work_dir"
      return 65
    }
  done
  actual_cmdline="$(_uki_cmdline_text "$work_dir/cmdline")" || {
    rm -rf -- "$work_dir"
    return 65
  }
  if [[ "$actual_cmdline" != "$expected_cmdline" || "$actual_cmdline" == *rootflags=subvol* || "$actual_cmdline" == *subvolid=* ]]; then
    rm -rf -- "$work_dir"
    return 65
  fi
  uname="$(_uki_section_text "$work_dir/uname")" || {
    rm -rf -- "$work_dir"
    return 65
  }
  [[ "$uname" =~ ^[0-9A-Za-z._+~-]+$ ]] || {
    rm -rf -- "$work_dir"
    return 65
  }
  version_id="$(_uki_osrel_value "$work_dir/osrel" VERSION_ID)" || {
    rm -rf -- "$work_dir"
    return 65
  }
  pretty_name="$(_uki_osrel_value "$work_dir/osrel" PRETTY_NAME)" || {
    rm -rf -- "$work_dir"
    return 65
  }
  if [[ "$version_id" != "$uname~$version_slot_tag" || "$pretty_name" != *"($expected_slot)" ]]; then
    rm -rf -- "$work_dir"
    return 65
  fi
  filename="$(basename -- "$uki_path")"
  if [[ "$expected_slot" == current ]]; then
    [[ "$filename" == spawn-arch-current.efi || "$filename" == .spawn-arch-current.efi.new.* ]] || {
      rm -rf -- "$work_dir"
      return 65
    }
    filename=spawn-arch-current.efi
  else
    [[ "$filename" == spawn-arch-last-good.efi || "$filename" == .spawn-arch-last-good.efi.new.* ]] || {
      rm -rf -- "$work_dir"
      return 65
    }
    filename=spawn-arch-last-good.efi
  fi
  rm -rf -- "$work_dir"
  if [[ "$require_visibility" == true ]]; then
    boot_list="$(bootctl --esp-path="$(_boot_root)" --json=short list)" || return 65
    jq -e --arg id "$filename" 'any(.[]; .id == $id)' >/dev/null <<<"$boot_list"
  elif [[ "$require_visibility" != false ]]; then
    return 64
  fi
}

uki_prepare_last_good() {
  local current_path="$1"
  local destination_path="$2"
  local expected_cmdline="$3"
  local efi_dir staged_path updated_path osrel_template osrel_path uname status

  efi_dir="$(dirname -- "$destination_path")"
  [[ "$efi_dir" == "$(dirname -- "$current_path")" ]] || return 65
  osrel_template="${SPAWN_ETC_ROOT:-/etc}/spawn-arch/uki-last-good.os-release"
  [[ -r "$osrel_template" ]] || return 65
  uname="$(uki_section_read "$current_path" .uname)" || return $?
  [[ "$uname" =~ ^[0-9A-Za-z._+~-]+$ ]] || return 65
  install -d -m 0700 -- "${SPAWN_INSTALLED_RUNTIME_DIR:-/run/spawn-arch}" || return $?
  osrel_path="$(mktemp "${SPAWN_INSTALLED_RUNTIME_DIR:-/run/spawn-arch}/uki-last-good-osrel.XXXXXX")" || return $?
  _uki_osrel_set_version "$osrel_template" "$osrel_path" "$uname~lg" || {
    rm -f -- "$osrel_path"
    return 65
  }
  staged_path="$(mktemp "$efi_dir/.spawn-arch-last-good.efi.new.XXXXXX")" || {
    status=$?
    rm -f -- "$osrel_path"
    return "$status"
  }
  updated_path="$staged_path.updated"
  cp -- "$current_path" "$staged_path" || {
    status=$?
    rm -f -- "$staged_path" "$osrel_path"
    return "$status"
  }
  if ! objcopy --update-section ".osrel=$osrel_path" "$staged_path" "$updated_path"; then
    rm -f -- "$staged_path" "$updated_path" "$osrel_path"
    return 65
  fi
  rm -f -- "$osrel_path"
  mv -f -- "$updated_path" "$staged_path" || {
    status=$?
    rm -f -- "$staged_path" "$updated_path"
    return "$status"
  }
  chmod 0600 -- "$staged_path" || {
    status=$?
    rm -f -- "$staged_path"
    return "$status"
  }
  sync -f -- "$staged_path" || {
    status=$?
    rm -f -- "$staged_path"
    return "$status"
  }
  uki_validate "$staged_path" "$expected_cmdline" last-good false || {
    rm -f -- "$staged_path"
    return 65
  }
  printf '%s\n' "$staged_path"
}

uki_copy_as_last_good() {
  local current_path="$1"
  local destination_path="$2"
  local expected_cmdline staged_path previous_path temporary

  expected_cmdline="$(<"${SPAWN_ETC_ROOT:-/etc}/kernel/cmdline")" || return $?
  staged_path="$(uki_prepare_last_good "$current_path" "$destination_path" "$expected_cmdline")" || return $?
  previous_path="$(dirname -- "$destination_path")/.spawn-arch-last-good.efi.previous"
  if [[ -e "$destination_path" ]]; then
    temporary="$(mktemp "$(dirname -- "$destination_path")/.spawn-arch-last-good.previous.XXXXXX")" || return $?
    cp -- "$destination_path" "$temporary" || return $?
    atomic_replace_same_directory "$temporary" "$previous_path" || return $?
  fi
  atomic_replace_same_directory "$staged_path" "$destination_path" || return $?
  if ! uki_validate "$destination_path" "$expected_cmdline" last-good; then
    if [[ -e "$previous_path" ]]; then
      atomic_replace_same_directory "$previous_path" "$destination_path" || true
    fi
    return 65
  fi
  rm -f -- "$previous_path"
  sync -f -- "$(dirname -- "$destination_path")"
}
