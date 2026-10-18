#!/usr/bin/env bash
# Derive the Malibu.app bundle version from the release tag.
#
# Usage: scripts/malibu-app-version.sh vX.Y.Z
# Prints one line: "<CFBundleShortVersionString> <CFBundleVersion>".
#
# The release tag (which production keeps equal to the CLI binaryVersion) is
# the single source of truth for the shipped app version. project.yml carries
# only a development default; every release, candidate, and independent
# Malibu build passes these values to xcodebuild as MARKETING_VERSION and
# CURRENT_PROJECT_VERSION, and release verification compares the built bundle
# with them (SPEC-025 §3.3).
#
# CFBundleVersion is X*1000000 + Y*1000 + Z: a positive decimal that strictly
# increases with the tag across patch, minor, and major bumps (1.8.252 ->
# 1008252, 2.0.0 -> 2000000) and stays above every ledger build shipped
# before v0.31 (at most 224).
set -euo pipefail

tag="${1:-}"
if [[ "$#" -ne 1 || ! "$tag" =~ ^v(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]]; then
  printf '[malibu-app-version] ERROR: release tag %s is not v<major>.<minor>.<patch> with components 0-999\n' \
    "$tag" >&2
  exit 1
fi
major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"
build=$((major * 1000000 + minor * 1000 + patch))
if [[ "$build" -le 0 ]]; then
  printf '[malibu-app-version] ERROR: release tag %s yields no positive build\n' "$tag" >&2
  exit 1
fi
printf '%s.%s.%s %s\n' "$major" "$minor" "$patch" "$build"
