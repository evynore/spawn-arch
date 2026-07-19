#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly REPO_ROOT
readonly RELEASE_REPOSITORY=https://github.com/evynore/spawn-arch
WORK_DIR=""

die() {
  printf 'spawn-arch release: %s\n' "$1" >&2
  return "${2:-1}"
}

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}
trap cleanup EXIT

main() {
  local tag="${1:-}"
  local tag_type commit head status epoch archive_root
  local dist archive_name checksum_name install_name base_url
  local staging tracked_tar temporary_archive temporary_checksum temporary_install

  (($# == 1)) || {
    die 'usage: scripts/build-release-archive.sh vMAJOR.MINOR.PATCH' 64
    return $?
  }
  [[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
    die 'release tag must be vMAJOR.MINOR.PATCH' 64
    return $?
  }
  tag_type="$(git -C "$REPO_ROOT" cat-file -t "refs/tags/$tag" 2>/dev/null || true)"
  [[ "$tag_type" == tag ]] || {
    die "$tag must exist as an annotated tag" 65
    return $?
  }
  commit="$(git -C "$REPO_ROOT" rev-parse --verify "$tag^{commit}")" || return $?
  head="$(git -C "$REPO_ROOT" rev-parse --verify HEAD)" || return $?
  [[ "$commit" =~ ^[0-9a-f]{40}$ && "$commit" == "$head" ]] || {
    die "$tag must point at HEAD" 65
    return $?
  }
  status="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal)" || return $?
  [[ -z "$status" ]] || {
    die 'release archive requires a clean tree' 65
    return $?
  }
  epoch="$(git -C "$REPO_ROOT" show -s --format=%ct "$commit")" || return $?
  [[ "$epoch" =~ ^[1-9][0-9]*$ ]] || return 65

  archive_root="spawn-arch-$tag"
  dist="$REPO_ROOT/dist"
  archive_name="$archive_root.tar.gz"
  checksum_name="$archive_name.sha256"
  install_name="$archive_root-INSTALL.txt"
  base_url="$RELEASE_REPOSITORY/releases/download/$tag"
  install -d -m 0755 -- "$dist" || return $?
  WORK_DIR="$(mktemp -d "$dist/.build-release.XXXXXX")" || return $?
  staging="$WORK_DIR/staging"
  tracked_tar="$WORK_DIR/tracked.tar"
  temporary_archive="$WORK_DIR/$archive_name"
  temporary_checksum="$WORK_DIR/$checksum_name"
  temporary_install="$WORK_DIR/$install_name"
  install -d -m 0700 -- "$staging" || return $?

  git -C "$REPO_ROOT" archive --format=tar --prefix="$archive_root/" "$commit" >"$tracked_tar" || return $?
  tar -xf "$tracked_tar" -C "$staging" || return $?
  printf '%s\n' "$commit" >"$staging/$archive_root/SOURCE_COMMIT"
  chmod 0644 -- "$staging/$archive_root/SOURCE_COMMIT"
  touch -d "@$epoch" -- "$staging/$archive_root/SOURCE_COMMIT"
  tar \
    --sort=name \
    --format=ustar \
    --mtime="@$epoch" \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    -cf - -C "$staging" "$archive_root" | gzip -9 -n >"$temporary_archive"
  chmod 0644 -- "$temporary_archive"
  (
    cd -- "$WORK_DIR"
    sha256sum "$archive_name" >"$checksum_name"
  )
  chmod 0644 -- "$temporary_checksum"

  cat >"$temporary_install" <<EOF
Download the fixed $tag release artifacts:

curl --fail --location --remote-name $base_url/$archive_name
curl --fail --location --remote-name $base_url/$checksum_name
sha256sum -c $checksum_name
tar -xzf $archive_name
cd $archive_root

Publishing this release is an explicit operator action after QEMU and physical acceptance pass.
EOF
  chmod 0644 -- "$temporary_install"

  mv -f -- "$temporary_archive" "$dist/$archive_name"
  mv -f -- "$temporary_checksum" "$dist/$checksum_name"
  mv -f -- "$temporary_install" "$dist/$install_name"
  printf '%s\n%s\n%s\n' \
    "$dist/$archive_name" \
    "$dist/$checksum_name" \
    "$dist/$install_name"
}

main "$@"
