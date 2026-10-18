#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version_guard="$repo_root/scripts/test-coordinator-advertised-version.sh"
policy_guard="$repo_root/scripts/release-staged-version-policy.sh"
source_file="$repo_root/phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift"
app_project_file="$repo_root/phase3-binary/app/project.yml"
binary_version="$(sed -nE 's/^[[:space:]]*static let binaryVersion = "([^"]+)".*$/\1/p' "$source_file" | head -n 1)"
app_version="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION: "([^"]+)".*$/\1/p' "$app_project_file" | head -n 1)"
app_build="$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION: "?([0-9]+)"?.*$/\1/p' "$app_project_file" | head -n 1)"
work="$(mktemp -d "${TMPDIR:-/tmp}/release-version-cohesion.XXXXXX")"
trap 'rm -rf "$work"' EXIT

policy_file="$work/release-policy.env"
bash "$policy_guard" "v$binary_version" > "$policy_file"
source "$policy_file"
if [[ "$MACPROVIDER_RELEASE_STAGED" == true ]]; then
  staged_coordinator_policy="--allow-previous-stable=$MACPROVIDER_RELEASE_PREVIOUS_STABLE_VERSION"
  staged_candidate_policy="--staged-candidate=$MACPROVIDER_RELEASE_CANDIDATE_VERSION"
else
  [[ -z "$MACPROVIDER_RELEASE_PREVIOUS_STABLE_VERSION" ]]
  previous_patch="$(python3 - "$binary_version" <<'PY'
import sys

major, minor, patch = (int(part) for part in sys.argv[1].split("."))
if patch <= 0:
    raise SystemExit("cannot synthesize a previous stable patch version")
print(f"{major}.{minor}.{patch - 1}")
PY
)"
  staged_coordinator_policy="--allow-previous-stable=$previous_patch"
  staged_candidate_policy="--staged-candidate=$binary_version"
fi

run_version_guard() {
  if [[ "$MACPROVIDER_RELEASE_STAGED" == true ]]; then
    bash "$version_guard" "v$binary_version" "$staged_coordinator_policy" "$staged_candidate_policy"
  else
    bash "$version_guard" "v$binary_version"
  fi
}

fixture="$work/repo"
reset_fixture() {
  rm -rf "$fixture"
  mkdir -p \
    "$fixture/scripts" \
    "$fixture/phase3-binary/Sources/macprovider-cli" \
    "$fixture/phase3-binary/app" \
    "$fixture/phase4-coordinator/dist"
  cp "$version_guard" "$fixture/scripts/test-coordinator-advertised-version.sh"
  cp "$source_file" "$fixture/phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift"
  cp "$app_project_file" "$fixture/phase3-binary/app/project.yml"
  cp "$repo_root/scripts/malibu-app-version.sh" "$fixture/scripts/malibu-app-version.sh"
  cp "$repo_root/phase4-coordinator/dist/coordinator.yaml" "$fixture/phase4-coordinator/dist/coordinator.yaml"
  cp "$repo_root/phase4-coordinator/coordinator.yaml.example" "$fixture/phase4-coordinator/coordinator.yaml.example"
  cp "$repo_root/phase4-coordinator/dist/coordinator.yaml.example" "$fixture/phase4-coordinator/dist/coordinator.yaml.example"
}

run_fixture_guard() {
  if [[ "$MACPROVIDER_RELEASE_STAGED" == true ]]; then
    bash "$fixture/scripts/test-coordinator-advertised-version.sh" "v$binary_version" "$staged_coordinator_policy" "$staged_candidate_policy"
  else
    bash "$fixture/scripts/test-coordinator-advertised-version.sh" "v$binary_version"
  fi
}

expect_fixture_failure() {
  label="$1"
  pattern="$2"
  if run_fixture_guard >"$work/$label.out" 2>&1; then
    echo "version guard accepted invalid fixture: $label" >&2
    exit 1
  fi
  grep -q "$pattern" "$work/$label.out"
}

if [[ "$MACPROVIDER_RELEASE_STAGED" == true ]]; then
  if bash "$version_guard" "v$binary_version" >"$work/strict-staging.out" 2>&1; then
    echo "strict version guard accepted an unpublished candidate against the previous recommendation" >&2
    exit 1
  fi
  grep -q "advertises $MACPROVIDER_RELEASE_PREVIOUS_STABLE_VERSION; expected $binary_version" "$work/strict-staging.out"
  base_output="$(run_version_guard)"
  grep -q "staged with previous stable coordinator recommendation $MACPROVIDER_RELEASE_PREVIOUS_STABLE_VERSION" <<<"$base_output"
else
  base_output="$(bash "$version_guard" "v$binary_version")"
  grep -q "CLI and coordinator advertised versions are aligned at $binary_version" <<<"$base_output"

  reset_fixture
  for config in \
    "$fixture/phase4-coordinator/dist/coordinator.yaml" \
    "$fixture/phase4-coordinator/coordinator.yaml.example" \
    "$fixture/phase4-coordinator/dist/coordinator.yaml.example"; do
    sed "s/latest_binary_version: \"$binary_version\"/latest_binary_version: \"$previous_patch\"/" "$config" > "$config.next"
    mv "$config.next" "$config"
  done
  if bash "$fixture/scripts/test-coordinator-advertised-version.sh" "v$binary_version" >"$work/strict-staging.out" 2>&1; then
    echo "strict version guard accepted an unpublished candidate against the previous recommendation" >&2
    exit 1
  fi
  grep -q "advertises $previous_patch; expected $binary_version" "$work/strict-staging.out"
  staged_output="$(bash "$fixture/scripts/test-coordinator-advertised-version.sh" "v$binary_version" "$staged_coordinator_policy" "$staged_candidate_policy")"
  grep -q "staged with previous stable coordinator recommendation $previous_patch" <<<"$staged_output"
fi

staged_fixture_guard="$version_guard"
if [[ "$MACPROVIDER_RELEASE_STAGED" == false ]]; then
  staged_fixture_guard="$fixture/scripts/test-coordinator-advertised-version.sh"
fi

if bash "$staged_fixture_guard" "v$binary_version" "$staged_coordinator_policy" --staged-candidate=1.8.91 >"$work/candidate-drift.out" 2>&1; then
  echo "version guard accepted a staged exception for a different candidate" >&2
  exit 1
fi
grep -q "does not match CLI binary" "$work/candidate-drift.out"

if bash "$version_guard" "v$binary_version" "$staged_candidate_policy" >"$work/missing-previous.out" 2>&1; then
  echo "version guard accepted a staged candidate without a previous stable policy" >&2
  exit 1
fi
grep -q "requires a previous stable coordinator policy" "$work/missing-previous.out"

if bash "$version_guard" v999.999.999 "$staged_coordinator_policy" "$staged_candidate_policy" >"$work/tag-drift.out" 2>&1; then
  echo "version guard accepted a release tag that differs from the CLI version" >&2
  exit 1
fi
grep -q "does not match CLI binary version" "$work/tag-drift.out"

reset_fixture
printf '%s\n' '    static let binaryVersion = "9.9.9"' >> "$fixture/phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift"
expect_fixture_failure duplicate-cli 'exactly one binaryVersion definition (found 2)'

reset_fixture
printf '%s\n' '    MARKETING_VERSION: "9.9.9"' >> "$fixture/phase3-binary/app/project.yml"
expect_fixture_failure duplicate-marketing 'exactly one MARKETING_VERSION definition (found 2)'

reset_fixture
printf '%s\n' '    CURRENT_PROJECT_VERSION: "999"' >> "$fixture/phase3-binary/app/project.yml"
expect_fixture_failure duplicate-build 'exactly one numeric CURRENT_PROJECT_VERSION definition (found 2)'

# SPEC-025 §3.3: a shipped app version comes from the release tag, so a
# hardcoded release version in project.yml is rejected.
reset_fixture
sed "s/MARKETING_VERSION: \"$app_version\"/MARKETING_VERSION: \"$binary_version\"/" "$fixture/phase3-binary/app/project.yml" > "$fixture/phase3-binary/app/project.yml.next"
mv "$fixture/phase3-binary/app/project.yml.next" "$fixture/phase3-binary/app/project.yml"
expect_fixture_failure hardcoded-marketing 'must keep the development default'

reset_fixture
sed "s/CURRENT_PROJECT_VERSION: \"$app_build\"/CURRENT_PROJECT_VERSION: \"${binary_version##*.}\"/" "$fixture/phase3-binary/app/project.yml" > "$fixture/phase3-binary/app/project.yml.next"
mv "$fixture/phase3-binary/app/project.yml.next" "$fixture/phase3-binary/app/project.yml"
expect_fixture_failure hardcoded-build 'must keep the development default'

reset_fixture
stamp_output="$(run_fixture_guard)"
grep -q "Malibu is stamped $binary_version build " <<<"$stamp_output"

# The stamp helper accepts only an exact release tag and derives a positive,
# strictly increasing build across patch, minor, and major bumps.
stamp_helper="$repo_root/scripts/malibu-app-version.sh"
[[ "$(bash "$stamp_helper" v1.8.251)" == "1.8.251 1008251" ]]
[[ "$(bash "$stamp_helper" v1.9.0)" == "1.9.0 1009000" ]]
[[ "$(bash "$stamp_helper" v2.0.0)" == "2.0.0 2000000" ]]
[[ "$(bash "$stamp_helper" v0.0.1)" == "0.0.1 1" ]]
previous_build=0
for ordered_tag in v0.0.1 v1.8.224 v1.8.251 v1.8.999 v1.9.0 v1.10.0 v2.0.0 v999.999.999; do
  read -r _ build <<<"$(bash "$stamp_helper" "$ordered_tag")"
  if (( build <= previous_build )); then
    echo "Malibu app build for $ordered_tag ($build) does not increase over $previous_build" >&2
    exit 1
  fi
  previous_build="$build"
done
for bad_tag in 1.8.251 v1.8 v1.8.251-rc1 v0.0.0 v01.8.2 v1.1000.0 "v1.8.2;id" "v1.8.2 x" ""; do
  if bash "$stamp_helper" "$bad_tag" >/dev/null 2>&1; then
    echo "Malibu app stamp helper accepted invalid tag: $bad_tag" >&2
    exit 1
  fi
done

echo "tag-stamped Malibu and CLI release-version regression checks passed"
