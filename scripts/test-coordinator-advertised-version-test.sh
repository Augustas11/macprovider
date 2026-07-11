#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version_guard="$repo_root/scripts/test-coordinator-advertised-version.sh"
source_file="$repo_root/phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift"
app_project_file="$repo_root/phase3-binary/app/project.yml"
binary_version="$(sed -nE 's/^[[:space:]]*static let binaryVersion = "([^"]+)".*$/\1/p' "$source_file" | head -n 1)"
app_build="$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION: "?([0-9]+)"?.*$/\1/p' "$app_project_file" | head -n 1)"
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
  if bash "$fixture/scripts/test-coordinator-advertised-version.sh" "v$binary_version" >"$work/$label.out" 2>&1; then
    echo "version guard accepted invalid fixture: $label" >&2
    exit 1
  fi
  grep -q "$pattern" "$work/$label.out"
}

bash "$version_guard" "v$binary_version"

if bash "$version_guard" v999.999.999 >"$work/tag-drift.out" 2>&1; then
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

# A future release must append a new, strictly larger build to the committed
# ledger. Updating every SemVer source while retaining build 31 must fail.
reset_fixture
for path in \
  "$fixture/phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift" \
  "$fixture/phase3-binary/app/project.yml" \
  "$fixture/phase4-coordinator/dist/coordinator.yaml" \
  "$fixture/phase4-coordinator/coordinator.yaml.example" \
  "$fixture/phase4-coordinator/dist/coordinator.yaml.example"; do
  sed 's/1\.8\.31/1.8.32/g' "$path" > "$path.next"
  mv "$path.next" "$path"
done
if bash "$fixture/scripts/test-coordinator-advertised-version.sh" v1.8.32 >"$work/future-missing-build.out" 2>&1; then
  echo "version guard accepted a future release without a release-build ledger entry" >&2
  exit 1
fi
grep -q 'exactly one entry for 1.8.32' "$work/future-missing-build.out"
printf '%s\t%s\n' '1.8.32' '31' >> "$fixture/phase3-binary/app/release-builds.tsv"
if bash "$fixture/scripts/test-coordinator-advertised-version.sh" v1.8.32 >"$work/future-reused-build.out" 2>&1; then
  echo "version guard accepted a future release that reused build 31" >&2
  exit 1
fi
grep -q 'duplicate build' "$work/future-reused-build.out"
sed 's/1\.8\.32[[:space:]]*31/1.8.32 32/' "$fixture/phase3-binary/app/release-builds.tsv" > "$fixture/phase3-binary/app/release-builds.tsv.next"
mv "$fixture/phase3-binary/app/release-builds.tsv.next" "$fixture/phase3-binary/app/release-builds.tsv"
sed 's/CURRENT_PROJECT_VERSION: "31"/CURRENT_PROJECT_VERSION: "32"/' "$fixture/phase3-binary/app/project.yml" > "$fixture/phase3-binary/app/project.yml.next"
mv "$fixture/phase3-binary/app/project.yml.next" "$fixture/phase3-binary/app/project.yml"
bash "$fixture/scripts/test-coordinator-advertised-version.sh" v1.8.32

cat >"$work/current-appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item>
    <sparkle:version>$app_build</sparkle:version>
    <sparkle:shortVersionString>$binary_version</sparkle:shortVersionString>
    <enclosure url="https://download.malibu.tech/Malibu-v$binary_version.dmg" />
  </item></channel>
</rss>
EOF
bash "$version_guard" "v$binary_version" "$work/current-appcast.xml"

cat >"$work/stale-appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item>
    <sparkle:version>$app_build</sparkle:version>
    <sparkle:shortVersionString>0.0.1</sparkle:shortVersionString>
    <enclosure url="https://download.malibu.tech/Malibu-v0.0.1.dmg" />
  </item></channel>
</rss>
EOF
if bash "$version_guard" "v$binary_version" "$work/stale-appcast.xml" >"$work/appcast-drift.out" 2>&1; then
  echo "version guard accepted a stale Sparkle appcast version" >&2
  exit 1
fi
grep -q "generated Sparkle appcast .* advertises 0.0.1; expected $binary_version" "$work/appcast-drift.out"

cat >"$work/stale-build-appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item>
    <sparkle:version>1</sparkle:version>
    <sparkle:shortVersionString>$binary_version</sparkle:shortVersionString>
    <enclosure url="https://download.malibu.tech/Malibu-v$binary_version.dmg" />
  </item></channel>
</rss>
EOF
if bash "$version_guard" "v$binary_version" "$work/stale-build-appcast.xml" >"$work/appcast-build-drift.out" 2>&1; then
  echo "version guard accepted a stale Sparkle appcast build" >&2
  exit 1
fi
grep -q "generated Sparkle appcast .* advertises build 1; expected $app_build" "$work/appcast-build-drift.out"

cat >"$work/stale-enclosure-appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item>
    <sparkle:version>$app_build</sparkle:version>
    <sparkle:shortVersionString>$binary_version</sparkle:shortVersionString>
    <enclosure url="https://download.malibu.tech/Malibu-v0.0.1.dmg" />
  </item></channel>
</rss>
EOF
if bash "$version_guard" "v$binary_version" "$work/stale-enclosure-appcast.xml" >"$work/appcast-enclosure-drift.out" 2>&1; then
  echo "version guard accepted a stale Sparkle appcast enclosure" >&2
  exit 1
fi
grep -q "enclosure is .*Malibu-v0.0.1.dmg; expected .*Malibu-v$binary_version.dmg" "$work/appcast-enclosure-drift.out"

cat >"$work/duplicate-item-appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item><sparkle:version>$app_build</sparkle:version><sparkle:shortVersionString>$binary_version</sparkle:shortVersionString><enclosure url="https://download.malibu.tech/Malibu-v$binary_version.dmg" /></item>
    <item><sparkle:version>$app_build</sparkle:version><sparkle:shortVersionString>$binary_version</sparkle:shortVersionString><enclosure url="https://download.malibu.tech/Malibu-v$binary_version.dmg" /></item>
  </channel>
</rss>
EOF
if bash "$version_guard" "v$binary_version" "$work/duplicate-item-appcast.xml" >"$work/appcast-duplicate-item.out" 2>&1; then
  echo "version guard accepted an appcast with duplicate release items" >&2
  exit 1
fi
grep -q 'exactly one channel/item (found 2)' "$work/appcast-duplicate-item.out"

cat >"$work/duplicate-enclosure-appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item>
    <sparkle:version>$app_build</sparkle:version>
    <sparkle:shortVersionString>$binary_version</sparkle:shortVersionString>
    <enclosure url="https://download.malibu.tech/Malibu-v$binary_version.dmg" />
    <enclosure url="https://download.malibu.tech/Malibu-v$binary_version.dmg" />
  </item></channel>
</rss>
EOF
if bash "$version_guard" "v$binary_version" "$work/duplicate-enclosure-appcast.xml" >"$work/appcast-duplicate-enclosure.out" 2>&1; then
  echo "version guard accepted an appcast with duplicate enclosures" >&2
  exit 1
fi
grep -q 'exactly one enclosure (found 2)' "$work/appcast-duplicate-enclosure.out"

echo "release version cohesion regression checks passed"
