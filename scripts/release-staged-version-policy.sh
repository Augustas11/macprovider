#!/usr/bin/env bash
# Derive the release's staged coordinator recommendation policy from source.
#
# During a stable release, checked-in coordinator configs intentionally keep
# advertising the previous stable provider CLI until immutable assets are public
# and the external Pearl recommendation step advances. This helper prevents the
# release workflows from carrying per-release hardcoded previous/candidate
# literals that go stale after the next cut.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_file="$repo_root/phase3-binary/Sources/malibu-cli/CoordinatorClient.swift"
expected_version="${1:-}"
expected_version="${expected_version#v}"

fail() {
  printf '[release-staged-version-policy] ERROR: %s\n' "$*" >&2
  exit 1
}

semver_re='^[0-9]+\.[0-9]+\.[0-9]+$'

binary_version="$(sed -nE 's/^[[:space:]]*static let binaryVersion[[:space:]]*=[[:space:]]*"([^"]+)".*$/\1/p' "$source_file")"
[[ "$binary_version" =~ $semver_re ]] || fail "CLI binary version is not semver: $binary_version"
if [[ -n "$expected_version" && "$expected_version" != "$binary_version" ]]; then
  fail "release tag v$expected_version does not match CLI binary version $binary_version"
fi

config_files=(
  "$repo_root/phase4-coordinator/dist/coordinator.yaml"
  "$repo_root/phase4-coordinator/coordinator.yaml.example"
  "$repo_root/phase4-coordinator/dist/coordinator.yaml.example"
)

advertised_version=""
for config_file in "${config_files[@]}"; do
  [[ -f "$config_file" ]] || fail "missing coordinator config: $config_file"
  version_lines="$(grep -E '^[[:space:]]*latest_binary_version:' "$config_file" || true)"
  version_count="$(printf '%s\n' "$version_lines" | awk 'NF { count++ } END { print count + 0 }')"
  [[ "$version_count" -eq 1 ]] ||
    fail "$config_file must contain exactly one latest_binary_version (found $version_count)"
  row="$(printf '%s\n' "$version_lines" | sed -nE 's/^[[:space:]]*latest_binary_version:[[:space:]]*"([^"]+)".*$/\1/p')"
  [[ "$row" =~ $semver_re ]] || fail "$config_file latest_binary_version is not semver: $row"
  if [[ -z "$advertised_version" ]]; then
    advertised_version="$row"
  elif [[ "$row" != "$advertised_version" ]]; then
    fail "coordinator configs disagree: $config_file advertises $row, first config advertises $advertised_version"
  fi
done

if [[ "$advertised_version" == "$binary_version" ]]; then
  staged=false
  previous_stable=""
else
  python3 - "$advertised_version" "$binary_version" <<'PY'
import sys
previous, candidate = sys.argv[1:]
def parse(value):
    return tuple(int(part) for part in value.split('.'))
if parse(previous) >= parse(candidate):
    raise SystemExit(
        f"checked-in coordinator recommendation {previous} must be older than candidate {candidate}"
    )
PY
  staged=true
  previous_stable="$advertised_version"
fi

printf "MACPROVIDER_RELEASE_CANDIDATE_VERSION='%s'\n" "$binary_version"
printf "MACPROVIDER_RELEASE_COORDINATOR_RECOMMENDATION='%s'\n" "$advertised_version"
printf "MACPROVIDER_RELEASE_STAGED='%s'\n" "$staged"
printf "MACPROVIDER_RELEASE_PREVIOUS_STABLE_VERSION='%s'\n" "$previous_stable"
