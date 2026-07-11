#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[validate-release-inputs] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 3 ]] || die "usage: VERSION PRERELEASE CANDIDATE"
version="$1"
prerelease="$2"
candidate="$3"

[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be vX.Y.Z"
case "$prerelease" in
  true|false) ;;
  *) die "prerelease must be exactly true or false" ;;
esac
case "$candidate" in
  true|false) ;;
  *) die "candidate must be exactly true or false" ;;
esac

printf '%s %s %s\n' "$version" "$prerelease" "$candidate"
