#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[validate-release-inputs] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 2 ]] || die "usage: VERSION PRERELEASE"
version="$1"
prerelease="$2"

[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be vX.Y.Z"
case "$prerelease" in
  true|false) ;;
  *) die "prerelease must be exactly true or false" ;;
esac

printf '%s %s\n' "$version" "$prerelease"
