#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version_guard="$repo_root/scripts/test-coordinator-advertised-version.sh"
source_file="$repo_root/phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift"
app_project_file="$repo_root/phase3-binary/app/project.yml"
binary_version="$(sed -nE 's/^[[:space:]]*static let binaryVersion = "([^"]+)".*$/\1/p' "$source_file" | head -n 1)"
app_version="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION: "([^"]+)".*$/\1/p' "$app_project_file" | head -n 1)"
app_build="$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION: "?([0-9]+)"?.*$/\1/p' "$app_project_file" | head -n 1)"
future_cli_version="${binary_version%.*}.$((${binary_version##*.} + 1))"
future_app_version="${app_version%.*}.$((${app_version##*.} + 1))"
future_build="$((app_build + 1))"
binary_version_pattern="${binary_version//./\\.}"
app_version_pattern="${app_version//./\\.}"
future_app_version_pattern="${future_app_version//./\\.}"
work="$(mktemp -d "${TMPDIR:-/tmp}/release-version-independence.XXXXXX")"
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
  local label="$1"
  local pattern="$2"
  shift 2
  if bash "$fixture/scripts/test-coordinator-advertised-version.sh" "$@" >"$work/$label.out" 2>&1; then
    echo "version guard accepted invalid fixture: $label" >&2
    exit 1
  fi
  grep -q "$pattern" "$work/$label.out"
}

bash "$version_guard" "v$binary_version"
bash "$version_guard" "malibu-v$app_version"
bash "$version_guard" "v$binary_version" "malibu-v$app_version"

if bash "$version_guard" v999.999.999 >"$work/tag-drift.out" 2>&1; then
  echo "version guard accepted a release tag that differs from the CLI version" >&2
  exit 1
fi
grep -q "does not match CLI binary version" "$work/tag-drift.out"

if bash "$version_guard" malibu-v999.999.999 >"$work/app-tag-drift.out" 2>&1; then
  echo "version guard accepted a release tag that differs from Malibu's version" >&2
  exit 1
fi
grep -q "does not match app marketing version" "$work/app-tag-drift.out"

reset_fixture
printf '%s\n' '    static let binaryVersion = "9.9.9"' >> "$fixture/phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift"
expect_fixture_failure duplicate-cli 'exactly one binaryVersion definition (found 2)' "v$binary_version"

reset_fixture
printf '%s\n' '    MARKETING_VERSION: "9.9.9"' >> "$fixture/phase3-binary/app/project.yml"
expect_fixture_failure duplicate-marketing 'exactly one MARKETING_VERSION definition (found 2)' "malibu-v$app_version"

reset_fixture
printf '%s\n' '    CURRENT_PROJECT_VERSION: "999"' >> "$fixture/phase3-binary/app/project.yml"
expect_fixture_failure duplicate-build 'exactly one numeric CURRENT_PROJECT_VERSION definition (found 2)' "malibu-v$app_version"

# A future CLI release remains cohesive with the coordinator without forcing a
# Malibu marketing-version or build change.
reset_fixture
for path in \
  "$fixture/phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift" \
  "$fixture/phase4-coordinator/dist/coordinator.yaml" \
  "$fixture/phase4-coordinator/coordinator.yaml.example" \
  "$fixture/phase4-coordinator/dist/coordinator.yaml.example"; do
  sed "s/$binary_version_pattern/$future_cli_version/g" "$path" > "$path.next"
  mv "$path.next" "$path"
done
rm -rf "$fixture/phase3-binary/app"
bash "$fixture/scripts/test-coordinator-advertised-version.sh" "v$future_cli_version"

# A future Malibu release independently requires a new ledger entry and a
# strictly larger build, while the CLI/coordinator version stays unchanged.
reset_fixture
sed "s/$app_version_pattern/$future_app_version/g" "$fixture/phase3-binary/app/project.yml" > "$fixture/phase3-binary/app/project.yml.next"
mv "$fixture/phase3-binary/app/project.yml.next" "$fixture/phase3-binary/app/project.yml"
expect_fixture_failure future-app-missing-build "exactly one entry for $future_app_version" "v$binary_version" "malibu-v$future_app_version"

printf '%s\t%s\n' "$future_app_version" "$app_build" >> "$fixture/phase3-binary/app/release-builds.tsv"
expect_fixture_failure future-app-reused-build 'duplicate build' "v$binary_version" "malibu-v$future_app_version"

sed "s/${future_app_version_pattern}[[:space:]]*$app_build/$future_app_version $future_build/" "$fixture/phase3-binary/app/release-builds.tsv" > "$fixture/phase3-binary/app/release-builds.tsv.next"
mv "$fixture/phase3-binary/app/release-builds.tsv.next" "$fixture/phase3-binary/app/release-builds.tsv"
sed "s/CURRENT_PROJECT_VERSION: \"$app_build\"/CURRENT_PROJECT_VERSION: \"$future_build\"/" "$fixture/phase3-binary/app/project.yml" > "$fixture/phase3-binary/app/project.yml.next"
mv "$fixture/phase3-binary/app/project.yml.next" "$fixture/phase3-binary/app/project.yml"
bash "$fixture/scripts/test-coordinator-advertised-version.sh" "v$binary_version" "malibu-v$future_app_version"

echo "independent CLI/coordinator and Malibu version regression checks passed"
