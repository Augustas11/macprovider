#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
generator="$root/scripts/generate-malibu-appcast.sh"
signature_verifier="$root/scripts/verify-malibu-sparkle-signature.py"
trust_anchor_helper="$root/scripts/prepare-malibu-bootstrap-trust-anchor.py"
set_verifier="$root/scripts/verify-malibu-publication-set.sh"
current_set_verifier="$root/scripts/verify-malibu-current-publication-set.sh"
publisher="$root/scripts/publish-malibu-latest-dmg.sh"
independent_publisher="$root/scripts/publish-independent-malibu-latest-dmg.sh"
independent_recovery="$root/scripts/recover-independent-malibu-publication.sh"
installer="$root/scripts/install-malibu-publication.sh"
public_verifier="$root/scripts/verify-malibu-bootstrap-publication.sh"
ssh_helper="$root/scripts/malibu-download-ssh.sh"
known_hosts="$root/scripts/dist/malibu-download-known_hosts"
legacy_key="$root/scripts/dist/malibu-v1.8.32-sparkle-public-key"
frozen_bridge_appcast="$root/scripts/dist/malibu-frozen-bridge-appcast.xml"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for script in "$generator" "$set_verifier" "$current_set_verifier" "$publisher" "$independent_publisher" "$independent_recovery" "$installer" "$public_verifier" "$ssh_helper"; do
  [[ -f "$script" ]] || fail "missing $script"
  bash -n "$script"
done
PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile \
  "$signature_verifier" "$trust_anchor_helper"
[[ -f "$known_hosts" && -f "$legacy_key" && -f "$frozen_bridge_appcast" ]] ||
  fail "bridge trust anchors are missing"

work="$(mktemp -d "${TMPDIR:-/tmp}/malibu-bootstrap-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Sparkle 2.6.4 writes version fields as item children, not enclosure
# attributes. Prove the structural verifier reaches the cryptographic gate for
# that exact legacy-client format.
printf 'unsigned structural fixture\n' > "$work/structural.dmg"
python3 - "$work/structural.dmg" "$work/structural-appcast.xml" <<'PY'
import base64
import pathlib
import sys

dmg = pathlib.Path(sys.argv[1])
appcast = pathlib.Path(sys.argv[2])
signature = base64.b64encode(bytes(64)).decode("ascii")
appcast.write_text(
    f'''<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel><item>
    <sparkle:version>39</sparkle:version>
    <sparkle:shortVersionString>1.8.39</sparkle:shortVersionString>
    <enclosure url="https://download.malibu.tech/Malibu-v1.8.39.dmg"
      length="{dmg.stat().st_size}" type="application/octet-stream"
      sparkle:edSignature="{signature}"/>
  </item></channel>
</rss>
''',
    encoding="utf-8",
)
PY
if python3 "$signature_verifier" v1.8.39 \
  "$work/structural.dmg" "$work/structural-appcast.xml" "$legacy_key" \
  >"$work/structural.out" 2>&1; then
  fail "unsigned structural fixture unexpectedly verified"
fi
grep -q 'signature does not verify' "$work/structural.out" ||
  fail "Sparkle item-level version fields did not reach the cryptographic gate"

create_test_app() {
  local destination="$1"
  local version="$2"
  local build="$3"
  local legacy_key="${4:-}"

  python3 - "$destination" "$version" "$build" "$legacy_key" <<'PY'
import pathlib
import plistlib
import sys

destination = pathlib.Path(sys.argv[1])
destination.joinpath("Contents", "MacOS").mkdir(parents=True)
destination.joinpath("Contents", "Resources").mkdir(parents=True)
destination.joinpath("Contents", "MacOS", "Malibu").write_bytes(b"test executable\n")
document = {
    "CFBundleIdentifier": "tech.malibu.app",
    "CFBundleExecutable": "Malibu",
    "CFBundleShortVersionString": sys.argv[2],
    "CFBundleVersion": sys.argv[3],
}
if sys.argv[4]:
    document["SUPublicEDKey"] = sys.argv[4]
with destination.joinpath("Contents", "Info.plist").open("wb") as output:
    plistlib.dump(document, output)
PY
}

expect_anchor_failure() {
  local label="$1"
  local pattern="$2"
  shift 2
  if python3 "$trust_anchor_helper" "$@" >"$work/$label.out" 2>&1; then
    fail "$label unexpectedly succeeded"
  fi
  grep -q "$pattern" "$work/$label.out" || fail "$label rejection was unclear"
}

# Released targets must carry exactly the old client's public key so Sparkle
# can validate the extracted bundle, while source remains free of Sparkle
# runtime and feed authority.
create_test_app "$work/bridge.app" 1.8.39 39
python3 "$trust_anchor_helper" prepare v1.8.39 \
  "$work/bridge.app" "$legacy_key" >/dev/null
python3 "$trust_anchor_helper" verify \
  "$work/bridge.app" "$legacy_key" >/dev/null
python3 - "$work/bridge.app/Contents/Info.plist" "$legacy_key" <<'PY'
import pathlib
import plistlib
import sys

document = plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
values = [
    line.strip()
    for line in pathlib.Path(sys.argv[2]).read_text(encoding="ascii").splitlines()
    if line.strip() and not line.lstrip().startswith("#")
]
assert document["SUPublicEDKey"] == values[0]
assert sorted(key for key in document if key.startswith("SU")) == ["SUPublicEDKey"]
PY

create_test_app "$work/later.app" 1.8.65 65
cp "$work/later.app/Contents/Info.plist" "$work/later.Info.plist"
python3 "$trust_anchor_helper" preflight v1.8.65 \
  "$work/later.app" "$legacy_key" >/dev/null
cmp "$work/later.Info.plist" "$work/later.app/Contents/Info.plist" ||
  fail "candidate preflight mutated independently versioned Malibu"
python3 "$trust_anchor_helper" prepare v1.8.65 \
  "$work/later.app" "$legacy_key" >/dev/null
python3 "$trust_anchor_helper" verify \
  "$work/later.app" "$legacy_key" >/dev/null
python3 - "$work/later.app/Contents/Info.plist" "$legacy_key" <<'PY'
import pathlib
import plistlib
import sys

document = plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
values = [
    line.strip()
    for line in pathlib.Path(sys.argv[2]).read_text(encoding="ascii").splitlines()
    if line.strip() and not line.lstrip().startswith("#")
]
assert document["SUPublicEDKey"] == values[0]
assert sorted(key for key in document if key.startswith("SU")) == ["SUPublicEDKey"]
PY

create_test_app "$work/wrong-bridge-version.app" 1.8.45 45
expect_anchor_failure wrong-bridge-version 'bundle version 1.8.45 does not match release tag v1.8.39' \
  preflight v1.8.39 "$work/wrong-bridge-version.app" "$legacy_key"

create_test_app "$work/missing-anchor.app" 1.8.39 39
expect_anchor_failure missing-anchor 'must contain only the exact frozen' \
  verify "$work/missing-anchor.app" "$legacy_key"

frozen_key="$(grep -v '^[[:space:]]*#' "$legacy_key" | sed '/^[[:space:]]*$/d')"
create_test_app "$work/preexisting.app" 1.8.39 39 "$frozen_key"
expect_anchor_failure preexisting 'source Malibu app unexpectedly contains' \
  prepare v1.8.39 "$work/preexisting.app" "$legacy_key"

create_test_app "$work/feed.app" 1.8.39 39
python3 - "$work/feed.app/Contents/Info.plist" <<'PY'
import pathlib
import plistlib
import sys

path = pathlib.Path(sys.argv[1])
document = plistlib.loads(path.read_bytes())
document["SUFeedURL"] = "https://updates.example.invalid/appcast.xml"
path.write_bytes(plistlib.dumps(document))
PY
expect_anchor_failure feed 'legacy update keys: SUFeedURL' \
  prepare v1.8.39 "$work/feed.app" "$legacy_key"

create_test_app "$work/sparkle-runtime.app" 1.8.39 39
mkdir -p "$work/sparkle-runtime.app/Contents/Frameworks/Sparkle.framework"
expect_anchor_failure sparkle-runtime 'contains Sparkle runtime paths' \
  prepare v1.8.39 "$work/sparkle-runtime.app" "$legacy_key"

mkdir -p "$work/redirected-macos"
create_test_app "$work/symlink-macos.app" 1.8.39 39
rm -rf "$work/symlink-macos.app/Contents/MacOS"
ln -s "$work/redirected-macos" "$work/symlink-macos.app/Contents/MacOS"
expect_anchor_failure symlink-macos 'Contents/MacOS must be a non-symlink directory' \
  prepare v1.8.39 "$work/symlink-macos.app" "$legacy_key"

create_test_app "$work/nested-symlink.app" 1.8.39 39
ln -s "$work/redirected-macos" \
  "$work/nested-symlink.app/Contents/Resources/redirect"
expect_anchor_failure nested-symlink 'contains symlink paths' \
  prepare v1.8.39 "$work/nested-symlink.app" "$legacy_key"

create_test_app "$work/wrong-build.app" 1.8.39 40
expect_anchor_failure wrong-build 'requires bundle version/build' \
  prepare v1.8.39 "$work/wrong-build.app" "$legacy_key"

printf '%s\n%s\n' "$frozen_key" "$frozen_key" > "$work/multiline-key"
expect_anchor_failure multiline-key 'exactly one non-comment value' \
  prepare v1.8.39 "$work/missing-anchor.app" "$work/multiline-key"
printf 'not-base64!\n' > "$work/malformed-key"
expect_anchor_failure malformed-key 'not canonical base64' \
  prepare v1.8.39 "$work/missing-anchor.app" "$work/malformed-key"
ln -s "$legacy_key" "$work/symlink-key"
expect_anchor_failure symlink-key 'regular non-symlink file' \
  prepare v1.8.39 "$work/missing-anchor.app" "$work/symlink-key"

grep -q 'StrictHostKeyChecking=yes' "$ssh_helper" || fail "Pearl SSH must fail closed"
grep -q 'malibu-download-known_hosts' "$ssh_helper" || fail "Pearl SSH host key is not pinned"
grep -q '/root/\.malibu-publish/stage\.XXXXXXXX' "$publisher" || fail "remote staging is predictable"
grep -q '/root/\.malibu-publish/stage\.XXXXXXXX' "$independent_publisher" || fail "independent remote staging is predictable"
grep -q "stat -c '%u:%g:%a:%h:%F'" "$publisher" || fail "remote transfer metadata is not verified"
grep -q "stat -c '%u:%g:%a:%h:%F'" "$independent_publisher" || fail "independent remote transfer metadata is not verified"
grep -q 'verify-malibu-bootstrap-publication.sh' "$publisher" || fail "public bytes are not verified"
grep -q 'verify-malibu-bootstrap-publication.sh' "$independent_publisher" || fail "independent public bytes are not verified"
grep -q 'verify-malibu-current-publication-set.sh' "$independent_publisher" ||
  fail "independent publication does not verify the current manifest"
grep -q 'frozen-bridge' "$publisher" || fail "current provider publisher lacks frozen appcast mode"
grep -q 'malibu-frozen-bridge-appcast.xml' "$set_verifier" ||
  fail "current provider verifier does not pin the frozen bridge appcast"
grep -q 'current provider publication must not bind a release appcast asset' "$installer" ||
  fail "current provider installer accepts release appcast drift"
if grep -q -- '--resolve' "$public_verifier" || grep -q 'MALIBU_DOWNLOAD_RESOLVE_IP' "$publisher" || grep -q 'MALIBU_DOWNLOAD_RESOLVE_IP' "$independent_publisher"; then
  fail "public verification can bypass client DNS resolution"
fi
grep -q 'same-tag publication drift refused' "$installer" || fail "same-tag drift is not refused"
grep -q 'single same-filesystem rename is the public transaction boundary' "$installer" ||
  fail "DMG and appcast do not share one atomic switch"

mkdir -p "$work/input" "$work/webroot"
printf 'signed dmg bytes\n' > "$work/input/Malibu-v1.8.39.dmg"
printf 'signed appcast bytes\n' > "$work/input/appcast.xml"
printf 'artifact index bytes\n' > "$work/input/compatibility-artifact-index.json"
dmg_sha="$(shasum -a 256 "$work/input/Malibu-v1.8.39.dmg" | awk '{print $1}')"
printf '%s  Malibu-v1.8.39.dmg\n' "$dmg_sha" > "$work/input/Malibu-v1.8.39.dmg.sha256"

# Public DNS/HTTPS is part of the client path. A failed ordinary fetch must
# fail the gate instead of retrying against a forced origin address.
mkdir -p "$work/no-dns-bin"
cat > "$work/no-dns-bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_CURL_CALLS"
exit 6
SH
chmod +x "$work/no-dns-bin/curl"
if MOCK_CURL_CALLS="$work/no-dns-curl.calls" \
  PATH="$work/no-dns-bin:$PATH" \
  bash "$public_verifier" v1.8.39 \
    "$work/input/Malibu-v1.8.39.dmg" "$work/input/appcast.xml" \
    "$work/input/Malibu-v1.8.39.dmg.sha256" \
    >"$work/no-dns.out" 2>&1; then
  fail "public verifier accepted failed DNS/client routing"
fi
[[ "$(wc -l < "$work/no-dns-curl.calls" | tr -d ' ')" == 1 ]] ||
  fail "public verifier retried through a non-client route"
grep -qv -- '--resolve' "$work/no-dns-curl.calls" ||
  fail "public verifier forced an origin address after DNS failure"

create_manifest() {
  python3 - "$@" <<'PY'
import hashlib
import json
import pathlib
import sys

output, dmg_name, appcast_name, index_name, prerelease = sys.argv[1:]
paths = [pathlib.Path(value) for value in (dmg_name, appcast_name, index_name)]
digests = {
    "Malibu-v1.8.39.dmg": hashlib.sha256(paths[0].read_bytes()).hexdigest(),
    "appcast.xml": hashlib.sha256(paths[1].read_bytes()).hexdigest(),
    "compatibility-artifact-index.json": hashlib.sha256(paths[2].read_bytes()).hexdigest(),
}
identity = hashlib.sha256(json.dumps({
    "appcast_sha256": digests["appcast.xml"],
    "compatibility_artifact_index_sha256": digests["compatibility-artifact-index.json"],
    "dmg_sha256": digests["Malibu-v1.8.39.dmg"],
}, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
manifest = {
    "schema_version": 1,
    "repository": "Augustas11/macprovider",
    "tag": "v1.8.39",
    "commit": "a" * 40,
    "prerelease": prerelease == "true",
    "release_id": 101,
    "publication_id": identity,
    "assets": {
        name: {"id": 200 + index, "sha256": digest}
        for index, (name, digest) in enumerate(digests.items(), 1)
    },
}
pathlib.Path(output).write_text(json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n")
print(identity)
PY
}

publication_id="$(create_manifest \
  "$work/input/publication-manifest.json" \
  "$work/input/Malibu-v1.8.39.dmg" "$work/input/appcast.xml" \
  "$work/input/compatibility-artifact-index.json" false)"

MALIBU_PUBLICATION_TESTING=1 bash "$installer" \
  "$work/webroot" v1.8.39 "$publication_id" \
  "$work/input/publication-manifest.json" "$work/input/Malibu-v1.8.39.dmg" \
  "$work/input/appcast.xml" "$work/input/Malibu-v1.8.39.dmg.sha256"

[[ -L "$work/webroot/.malibu-current" ]] || fail "current pointer is not atomic"
[[ "$(cat "$work/webroot/latest.dmg")" == 'signed dmg bytes' ]] || fail "latest DMG differs"
[[ "$(cat "$work/webroot/appcast.xml")" == 'signed appcast bytes' ]] || fail "appcast differs"
[[ "$(cat "$work/webroot/Malibu-v1.8.39.dmg")" == 'signed dmg bytes' ]] ||
  fail "versioned DMG differs"

printf 'drifted appcast\n' > "$work/input/appcast-drift.xml"
drift_id="$(create_manifest \
  "$work/input/publication-manifest-drift.json" \
  "$work/input/Malibu-v1.8.39.dmg" "$work/input/appcast-drift.xml" \
  "$work/input/compatibility-artifact-index.json" false)"
if MALIBU_PUBLICATION_TESTING=1 bash "$installer" \
  "$work/webroot" v1.8.39 "$drift_id" \
  "$work/input/publication-manifest-drift.json" "$work/input/Malibu-v1.8.39.dmg" \
  "$work/input/appcast-drift.xml" "$work/input/Malibu-v1.8.39.dmg.sha256" \
  >"$work/drift.out" 2>&1; then
  fail "same-tag publication drift was accepted"
fi
grep -q 'same-tag publication drift refused' "$work/drift.out" || fail "drift rejection was unclear"

mkdir -p "$work/provider-current"
printf 'current provider dmg bytes\n' > "$work/provider-current/Malibu-v1.8.88.dmg"
cp "$frozen_bridge_appcast" "$work/provider-current/appcast.xml"
provider_dmg_sha="$(shasum -a 256 "$work/provider-current/Malibu-v1.8.88.dmg" | awk '{print $1}')"
printf '%s  Malibu-v1.8.88.dmg\n' "$provider_dmg_sha" > "$work/provider-current/Malibu-v1.8.88.dmg.sha256"
provider_publication_id="$(python3 - "$work/provider-current/publication-manifest.json" \
  "$work/provider-current/Malibu-v1.8.88.dmg" <<'PY'
import hashlib
import json
import pathlib
import sys

manifest_path, dmg_path = map(pathlib.Path, sys.argv[1:])
tag = "v1.8.88"
dmg_sha = hashlib.sha256(dmg_path.read_bytes()).hexdigest()
identity = hashlib.sha256(json.dumps({
    "compatibility_artifact_index_sha256": "0" * 64,
    "dmg_sha256": dmg_sha,
    "release_sequence": 188,
}, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
manifest_path.write_text(json.dumps({
    "schema_version": 1,
    "repository": "Augustas11/macprovider",
    "tag": tag,
    "commit": "c" * 40,
    "prerelease": False,
    "release_id": 501,
    "release_sequence": 188,
    "publication_id": identity,
    "assets": {
        dmg_path.name: {"id": 601, "sha256": dmg_sha},
    },
}, sort_keys=True) + "\n")
print(identity)
PY
)"

MALIBU_PUBLICATION_TESTING=1 bash "$installer" \
  "$work/provider-current-webroot" v1.8.88 "$provider_publication_id" \
  "$work/provider-current/publication-manifest.json" "$work/provider-current/Malibu-v1.8.88.dmg" \
  "$work/provider-current/appcast.xml" "$work/provider-current/Malibu-v1.8.88.dmg.sha256"
[[ "$(cat "$work/provider-current-webroot/latest.dmg")" == 'current provider dmg bytes' ]] ||
  fail "current provider latest DMG differs"
cmp -s "$frozen_bridge_appcast" "$work/provider-current-webroot/appcast.xml" ||
  fail "current provider appcast is not the frozen bridge appcast"

python3 - "$work/provider-current-webroot/.malibu-current/publication-manifest.json" \
  "$work/provider-current-webroot/.malibu-tag-manifests/v1.8.88.json" <<'PY'
import json
import pathlib
import sys

for raw_path in sys.argv[1:]:
    path = pathlib.Path(raw_path)
    manifest = json.loads(path.read_text())
    manifest.pop("release_sequence", None)
    path.write_text(json.dumps(manifest, sort_keys=True) + "\n")
PY
printf 'newer provider dmg bytes\n' > "$work/provider-current/Malibu-v1.8.89.dmg"
newer_provider_dmg_sha="$(shasum -a 256 "$work/provider-current/Malibu-v1.8.89.dmg" | awk '{print $1}')"
printf '%s  Malibu-v1.8.89.dmg\n' "$newer_provider_dmg_sha" > "$work/provider-current/Malibu-v1.8.89.dmg.sha256"
newer_provider_publication_id="$(python3 - "$work/provider-current/publication-manifest-newer.json" \
  "$work/provider-current/Malibu-v1.8.89.dmg" <<'PY'
import hashlib
import json
import pathlib
import sys

manifest_path, dmg_path = map(pathlib.Path, sys.argv[1:])
tag = "v1.8.89"
dmg_sha = hashlib.sha256(dmg_path.read_bytes()).hexdigest()
identity = hashlib.sha256(json.dumps({
    "compatibility_artifact_index_sha256": "0" * 64,
    "dmg_sha256": dmg_sha,
    "release_sequence": 189,
}, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
manifest_path.write_text(json.dumps({
    "schema_version": 1,
    "repository": "Augustas11/macprovider",
    "tag": tag,
    "commit": "e" * 40,
    "prerelease": False,
    "release_id": 502,
    "release_sequence": 189,
    "publication_id": identity,
    "assets": {
        dmg_path.name: {"id": 602, "sha256": dmg_sha},
    },
}, sort_keys=True) + "\n")
print(identity)
PY
)"
MALIBU_PUBLICATION_TESTING=1 bash "$installer" \
  "$work/provider-current-webroot" v1.8.89 "$newer_provider_publication_id" \
  "$work/provider-current/publication-manifest-newer.json" "$work/provider-current/Malibu-v1.8.89.dmg" \
  "$work/provider-current/appcast.xml" "$work/provider-current/Malibu-v1.8.89.dmg.sha256"
[[ "$(cat "$work/provider-current-webroot/latest.dmg")" == 'newer provider dmg bytes' ]] ||
  fail "legacy current sequence fallback did not publish the newer provider DMG"

printf 'older provider dmg bytes\n' > "$work/provider-current/Malibu-v1.8.87.dmg"
older_provider_dmg_sha="$(shasum -a 256 "$work/provider-current/Malibu-v1.8.87.dmg" | awk '{print $1}')"
printf '%s  Malibu-v1.8.87.dmg\n' "$older_provider_dmg_sha" > "$work/provider-current/Malibu-v1.8.87.dmg.sha256"
older_provider_publication_id="$(python3 - "$work/provider-current/publication-manifest-older.json" \
  "$work/provider-current/Malibu-v1.8.87.dmg" <<'PY'
import hashlib
import json
import pathlib
import sys

manifest_path, dmg_path = map(pathlib.Path, sys.argv[1:])
tag = "v1.8.87"
dmg_sha = hashlib.sha256(dmg_path.read_bytes()).hexdigest()
identity = hashlib.sha256(json.dumps({
    "compatibility_artifact_index_sha256": "0" * 64,
    "dmg_sha256": dmg_sha,
    "release_sequence": 187,
}, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
manifest_path.write_text(json.dumps({
    "schema_version": 1,
    "repository": "Augustas11/macprovider",
    "tag": tag,
    "commit": "d" * 40,
    "prerelease": False,
    "release_id": 500,
    "release_sequence": 187,
    "publication_id": identity,
    "assets": {
        dmg_path.name: {"id": 600, "sha256": dmg_sha},
    },
}, sort_keys=True) + "\n")
print(identity)
PY
)"
if MALIBU_PUBLICATION_TESTING=1 bash "$installer" \
  "$work/provider-current-webroot" v1.8.87 "$older_provider_publication_id" \
  "$work/provider-current/publication-manifest-older.json" "$work/provider-current/Malibu-v1.8.87.dmg" \
  "$work/provider-current/appcast.xml" "$work/provider-current/Malibu-v1.8.87.dmg.sha256" \
  >"$work/provider-current-replay.out" 2>&1; then
  fail "current provider installer accepted a sequence rollback"
fi
grep -q 'publication sequence did not advance' "$work/provider-current-replay.out" ||
  fail "current provider sequence rollback rejection was unclear"

mkdir -p "$work/provider-history-webroot/.malibu-tag-manifests"
printf '{}\n' > "$work/provider-history-webroot/.malibu-tag-manifests/v1.8.87.json"
if MALIBU_PUBLICATION_TESTING=1 bash "$installer" \
  "$work/provider-history-webroot" v1.8.88 "$provider_publication_id" \
  "$work/provider-current/publication-manifest.json" "$work/provider-current/Malibu-v1.8.88.dmg" \
  "$work/provider-current/appcast.xml" "$work/provider-current/Malibu-v1.8.88.dmg.sha256" \
  >"$work/provider-history.out" 2>&1; then
  fail "current provider installer accepted history without current pointer"
fi
grep -q 'publication history exists without current pointer' "$work/provider-history.out" ||
  fail "history-without-current rejection was unclear"

mkdir -p "$work/provider-dangling-webroot"
ln -s .malibu-releases/missing "$work/provider-dangling-webroot/.malibu-current"
if MALIBU_PUBLICATION_TESTING=1 bash "$installer" \
  "$work/provider-dangling-webroot" v1.8.88 "$provider_publication_id" \
  "$work/provider-current/publication-manifest.json" "$work/provider-current/Malibu-v1.8.88.dmg" \
  "$work/provider-current/appcast.xml" "$work/provider-current/Malibu-v1.8.88.dmg.sha256" \
  >"$work/provider-dangling.out" 2>&1; then
  fail "current provider installer accepted dangling current pointer"
fi
grep -q 'current publication pointer lacks a manifest' "$work/provider-dangling.out" ||
  fail "dangling-current rejection was unclear"

printf 'current provider appcast drift\n' > "$work/provider-current/appcast-drift.xml"
if MALIBU_PUBLICATION_TESTING=1 bash "$installer" \
  "$work/provider-current-drift-webroot" v1.8.88 "$provider_publication_id" \
  "$work/provider-current/publication-manifest.json" "$work/provider-current/Malibu-v1.8.88.dmg" \
  "$work/provider-current/appcast-drift.xml" "$work/provider-current/Malibu-v1.8.88.dmg.sha256" \
  >"$work/provider-current-drift.out" 2>&1; then
  fail "current provider installer accepted appcast drift"
fi
grep -q 'current provider publication must use the committed frozen bridge appcast' \
  "$work/provider-current-drift.out" || fail "current provider appcast drift rejection was unclear"

mkdir -p "$work/frozen-public-bin"
cat > "$work/frozen-public-bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""
url=""
while (($#)); do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    http*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
printf '%s\n' "$url" >> "$MOCK_CURL_CALLS"
case "$url" in
  *appcast.xml*)
    cp "$FROZEN_APPCAST_FIXTURE" "$out"
    ;;
  *Malibu-v1.8.88.dmg.sha256*)
    cp "$CURRENT_SHA_FIXTURE" "$out"
    ;;
  *latest.dmg*|*Malibu-v1.8.88.dmg*)
    cp "$CURRENT_DMG_FIXTURE" "$out"
    ;;
  *Malibu-v1.8.39.dmg*)
    printf 'legacy bridge dmg bytes\n' > "$out"
    ;;
  *)
    printf 'unexpected URL: %s\n' "$url" >&2
    exit 1
    ;;
esac
SH
cat > "$work/frozen-public-bin/python3" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_PYTHON_CALLS"
[[ "$1" == *verify-malibu-sparkle-signature.py && "$2" == v1.8.39 ]]
SH
chmod +x "$work/frozen-public-bin/curl" "$work/frozen-public-bin/python3"
MOCK_CURL_CALLS="$work/frozen-public-curl.calls" \
MOCK_PYTHON_CALLS="$work/frozen-public-python.calls" \
FROZEN_APPCAST_FIXTURE="$work/provider-current/appcast.xml" \
CURRENT_DMG_FIXTURE="$work/provider-current/Malibu-v1.8.88.dmg" \
CURRENT_SHA_FIXTURE="$work/provider-current/Malibu-v1.8.88.dmg.sha256" \
MALIBU_DOWNLOAD_HOST=download.example.invalid \
PATH="$work/frozen-public-bin:$PATH" \
  bash "$public_verifier" v1.8.88 \
    "$work/provider-current/Malibu-v1.8.88.dmg" \
    "$work/provider-current/appcast.xml" \
    "$work/provider-current/Malibu-v1.8.88.dmg.sha256"
grep -q 'Malibu-v1.8.39.dmg' "$work/frozen-public-curl.calls" ||
  fail "frozen public verifier does not fetch the legacy bridge DMG"
grep -q ' v1.8.39 ' "$work/frozen-public-python.calls" ||
  fail "frozen public verifier does not verify the legacy bridge signature"

mkdir -p "$work/current"
printf 'current signed dmg bytes\n' > "$work/current/Malibu-v1.8.65.dmg"
printf 'current signed appcast bytes\n' > "$work/current/appcast.xml"
current_dmg_sha="$(shasum -a 256 "$work/current/Malibu-v1.8.65.dmg" | awk '{print $1}')"
printf '%s  Malibu-v1.8.65.dmg\n' "$current_dmg_sha" > "$work/current/Malibu-v1.8.65.dmg.sha256"
python3 - "$work/current/release.json" "$work/current/publication-manifest.json" \
  "$work/current/Malibu-v1.8.65.dmg" "$work/current/appcast.xml" \
  "$work/current/Malibu-v1.8.65.dmg.sha256" <<'PY'
import hashlib
import json
import pathlib
import sys

release_path, manifest_path, dmg_path, appcast_path, checksum_path = map(pathlib.Path, sys.argv[1:])
tag = "v1.8.65"
commit = "b" * 40
local = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in (dmg_path, appcast_path, checksum_path)}
identity = hashlib.sha256(json.dumps({
    "appcast_sha256": local["appcast.xml"],
    "dmg_sha256": local[dmg_path.name],
    "sha256_sidecar_sha256": local[checksum_path.name],
}, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
assets = [
    {"id": 401, "name": dmg_path.name, "digest": "sha256:" + local[dmg_path.name]},
    {"id": 402, "name": "appcast.xml", "digest": "sha256:" + local["appcast.xml"]},
    {"id": 403, "name": checksum_path.name, "digest": "sha256:" + local[checksum_path.name]},
]
release_path.write_text(json.dumps({
    "id": 301,
    "tag_name": tag,
    "target_commitish": commit,
    "draft": False,
    "prerelease": False,
    "immutable": True,
    "assets": assets,
}, sort_keys=True) + "\n")
manifest_path.write_text(json.dumps({
    "schema_version": 1,
    "repository": "Augustas11/macprovider",
    "tag": tag,
    "commit": commit,
    "prerelease": False,
    "release_id": 301,
    "publication_id": identity,
    "assets": {
        asset["name"]: {"id": asset["id"], "sha256": local[asset["name"]]}
        for asset in assets
    },
}, sort_keys=True) + "\n")
PY
printf 'stale current appcast bytes\n' > "$work/current/appcast.xml"
if bash "$current_set_verifier" \
  "$work/current/release.json" "$work/current/publication-manifest.json" \
  "$work/current/Malibu-v1.8.65.dmg" "$work/current/appcast.xml" \
  "$work/current/Malibu-v1.8.65.dmg.sha256" \
  >"$work/current-drift.out" 2>&1; then
  fail "current Malibu verifier accepted stale appcast bytes"
fi
grep -q 'publication manifest does not bind appcast.xml' "$work/current-drift.out" ||
  fail "current stale appcast rejection was unclear"

create_manifest "$work/input/prerelease.json" \
  "$work/input/Malibu-v1.8.39.dmg" "$work/input/appcast.xml" \
  "$work/input/compatibility-artifact-index.json" true >/dev/null
if MALIBU_PUBLICATION_TESTING=1 bash "$installer" \
  "$work/prerelease-webroot" v1.8.39 "$publication_id" \
  "$work/input/prerelease.json" "$work/input/Malibu-v1.8.39.dmg" \
  "$work/input/appcast.xml" "$work/input/Malibu-v1.8.39.dmg.sha256" \
  >"$work/prerelease.out" 2>&1; then
  fail "prerelease bridge was accepted"
fi
grep -q 'prerelease must not publish' "$work/prerelease.out" || fail "prerelease rejection was unclear"

if MALIBU_PUBLICATION_TESTING=1 bash "$installer" \
  "$work/other-webroot" v1.8.40 "$publication_id" \
  "$work/input/publication-manifest.json" "$work/input/Malibu-v1.8.39.dmg" \
  "$work/input/appcast.xml" "$work/input/Malibu-v1.8.39.dmg.sha256" \
  >"$work/tag.out" 2>&1; then
  fail "installer accepted mismatched publication identity"
fi
grep -q 'publication manifest identity mismatch' "$work/tag.out" || fail "tag rejection was unclear"

if bash "$generator" v1.8.40 >"$work/generator.out" 2>&1; then
  fail "generator accepted a missing later DMG"
fi
grep -q 'missing dmg:' "$work/generator.out" || fail "generator later-tag path was unclear"

echo 'Malibu bootstrap bridge regression checks passed'
