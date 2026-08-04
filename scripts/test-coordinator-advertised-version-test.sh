#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version_guard="$repo_root/scripts/test-coordinator-advertised-version.sh"
source_file="$repo_root/phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift"
app_project_file="$repo_root/phase3-binary/app/project.yml"
binary_version="$(sed -nE 's/^[[:space:]]*static let binaryVersion = "([^"]+)".*$/\1/p' "$source_file" | head -n 1)"
app_version="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION: "([^"]+)".*$/\1/p' "$app_project_file" | head -n 1)"
app_build="$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION: "?([0-9]+)"?.*$/\1/p' "$app_project_file" | head -n 1)"
future_version="${app_version%.*}.$((${app_version##*.} + 1))"
future_build="$((app_build + 1))"
future_version_pattern="${future_version//./\\.}"
staged_coordinator_policy="--allow-previous-stable=1.8.81"
staged_candidate_policy="--staged-candidate=1.8.82"
work="$(mktemp -d "${TMPDIR:-/tmp}/release-version-cohesion.XXXXXX")"
trap 'rm -rf "$work"' EXIT

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
  cp "$repo_root/phase3-binary/app/release-builds.tsv" "$fixture/phase3-binary/app/release-builds.tsv"
  cp "$repo_root/phase4-coordinator/dist/coordinator.yaml" "$fixture/phase4-coordinator/dist/coordinator.yaml"
  cp "$repo_root/phase4-coordinator/coordinator.yaml.example" "$fixture/phase4-coordinator/coordinator.yaml.example"
  cp "$repo_root/phase4-coordinator/dist/coordinator.yaml.example" "$fixture/phase4-coordinator/dist/coordinator.yaml.example"
}

expect_fixture_failure() {
  label="$1"
  pattern="$2"
  if bash "$fixture/scripts/test-coordinator-advertised-version.sh" "v$binary_version" "$staged_coordinator_policy" "$staged_candidate_policy" >"$work/$label.out" 2>&1; then
    echo "version guard accepted invalid fixture: $label" >&2
    exit 1
  fi
  grep -q "$pattern" "$work/$label.out"
}

if bash "$version_guard" "v$binary_version" >"$work/strict-staging.out" 2>&1; then
  echo "strict version guard accepted an unpublished candidate against the previous recommendation" >&2
  exit 1
fi
grep -q "advertises 1.8.81; expected $binary_version" "$work/strict-staging.out"
base_output="$(bash "$version_guard" "v$binary_version" "$staged_coordinator_policy" "$staged_candidate_policy")"
grep -q "staged with previous stable coordinator recommendation 1.8.81" <<<"$base_output"

if bash "$version_guard" "v$binary_version" "$staged_coordinator_policy" --staged-candidate=1.8.83 >"$work/candidate-drift.out" 2>&1; then
  echo "version guard accepted a staged exception for a different candidate" >&2
  exit 1
fi
grep -q "does not match CLI binary" "$work/candidate-drift.out"

if bash "$version_guard" "v$binary_version" --staged-candidate=1.8.82 >"$work/missing-previous.out" 2>&1; then
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

# Malibu and the CLI release independently. A future Malibu release must append
# a new, strictly larger build without changing the CLI or coordinator version.
reset_fixture
sed "s/$app_version/$future_version/g" "$fixture/phase3-binary/app/project.yml" > "$fixture/phase3-binary/app/project.yml.next"
mv "$fixture/phase3-binary/app/project.yml.next" "$fixture/phase3-binary/app/project.yml"
if bash "$fixture/scripts/test-coordinator-advertised-version.sh" "v$binary_version" "$staged_coordinator_policy" "$staged_candidate_policy" >"$work/future-missing-build.out" 2>&1; then
  echo "version guard accepted a future release without a release-build ledger entry" >&2
  exit 1
fi
grep -q "exactly one entry for $future_version" "$work/future-missing-build.out"
printf '%s\t%s\n' "$future_version" "$app_build" >> "$fixture/phase3-binary/app/release-builds.tsv"
if bash "$fixture/scripts/test-coordinator-advertised-version.sh" "v$binary_version" "$staged_coordinator_policy" "$staged_candidate_policy" >"$work/future-reused-build.out" 2>&1; then
  echo "version guard accepted a future release that reused build $app_build" >&2
  exit 1
fi
grep -q 'duplicate build' "$work/future-reused-build.out"
sed "s/${future_version_pattern}[[:space:]]*$app_build/$future_version $future_build/" "$fixture/phase3-binary/app/release-builds.tsv" > "$fixture/phase3-binary/app/release-builds.tsv.next"
mv "$fixture/phase3-binary/app/release-builds.tsv.next" "$fixture/phase3-binary/app/release-builds.tsv"
sed "s/CURRENT_PROJECT_VERSION: \"$app_build\"/CURRENT_PROJECT_VERSION: \"$future_build\"/" "$fixture/phase3-binary/app/project.yml" > "$fixture/phase3-binary/app/project.yml.next"
mv "$fixture/phase3-binary/app/project.yml.next" "$fixture/phase3-binary/app/project.yml"
bash "$fixture/scripts/test-coordinator-advertised-version.sh" "v$binary_version" "$staged_coordinator_policy" "$staged_candidate_policy"

echo "independent Malibu and CLI release-version regression checks passed"
