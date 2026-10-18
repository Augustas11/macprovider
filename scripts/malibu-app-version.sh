#!/usr/bin/env bash
# Derive the Malibu.app bundle version from the release tag.
#
# The release tag (which production keeps equal to the CLI binaryVersion) is
# the single source of truth for the shipped app version. project.yml carries
# only a development default; every release, candidate, and independent
# Malibu build passes the values printed here to xcodebuild as
# MARKETING_VERSION and CURRENT_PROJECT_VERSION (SPEC-025 §3.3).
# CFBundleVersion is the tag's patch component, the convention every Malibu
# release since v1.8.26 already used.
set -euo pipefail

tag="${1:-}"
if [[ ! "$tag" =~ ^v((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.([1-9][0-9]*))$ ]]; then
  printf '[malibu-app-version] ERROR: release tag %s is not v<major>.<minor>.<patch> with a positive patch\n' \
    "$tag" >&2
  exit 1
fi
printf "MALIBU_APP_VERSION='%s'\n" "${BASH_REMATCH[1]}"
printf "MALIBU_APP_BUILD='%s'\n" "${BASH_REMATCH[4]}"
