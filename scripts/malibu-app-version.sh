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
# CFBundleVersion is the tag's patch component, the contract that
# scripts/prepare-malibu-bootstrap-trust-anchor.py already enforces on every
# release (positive decimal equal to the patch), so a patch of 0 is rejected.
set -euo pipefail

tag="${1:-}"
if [[ "$#" -ne 1 || ! "$tag" =~ ^v((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.([1-9][0-9]*))$ ]]; then
  printf '[malibu-app-version] ERROR: release tag %s is not v<major>.<minor>.<patch> with a positive patch\n' \
    "$tag" >&2
  exit 1
fi
printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[4]}"
