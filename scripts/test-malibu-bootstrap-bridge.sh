#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
generator="$root/scripts/generate-malibu-appcast.sh"
signature_verifier="$root/scripts/verify-malibu-sparkle-signature.py"
trust_anchor_helper="$root/scripts/prepare-malibu-bootstrap-trust-anchor.py"
set_verifier="$root/scripts/verify-malibu-publication-set.sh"
publisher="$root/scripts/publish-malibu-latest-dmg.sh"
installer="$root/scripts/install-malibu-publication.sh"
public_verifier="$root/scripts/verify-malibu-bootstrap-publication.sh"
ssh_helper="$root/scripts/malibu-download-ssh.sh"
known_hosts="$root/scripts/dist/malibu-download-known_hosts"
legacy_key="$root/scripts/dist/malibu-v1.8.32-sparkle-public-key"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for script in "$generator" "$set_verifier" "$publisher" "$installer" "$public_verifier" "$ssh_helper"; do
  [[ -f "$script" ]] || fail "missing $script"
  bash -n "$script"
done
PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile \
  "$signature_verifier" "$trust_anchor_helper"
[[ -f "$known_hosts" && -f "$legacy_key" ]] || fail "bridge trust anchors are missing"

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

# The released v1.8.39 target must carry exactly the old client's public key,
# while source and every later app remain free of Sparkle update authority.
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

create_test_app "$work/later.app" 1.8.45 45
cp "$work/later.app/Contents/Info.plist" "$work/later.Info.plist"
python3 "$trust_anchor_helper" preflight v1.8.65 \
  "$work/later.app" "$legacy_key" >/dev/null
cmp "$work/later.Info.plist" "$work/later.app/Contents/Info.plist" ||
  fail "candidate preflight mutated independently versioned Malibu"
python3 "$trust_anchor_helper" prepare v1.8.65 \
  "$work/later.app" "$legacy_key" >/dev/null
cmp "$work/later.Info.plist" "$work/later.app/Contents/Info.plist" ||
  fail "non-bridge preparation mutated independently versioned Malibu"
python3 "$trust_anchor_helper" verify \
  "$work/later.app" "$legacy_key" >/dev/null

create_test_app "$work/wrong-bridge-version.app" 1.8.45 45
expect_anchor_failure wrong-bridge-version 'bundle version 1.8.45 does not match release tag v1.8.39' \
  preflight v1.8.39 "$work/wrong-bridge-version.app" "$legacy_key"

create_test_app "$work/reserved-bridge-version.app" 1.8.39 39
expect_anchor_failure reserved-bridge-version 'reserved for the v1.8.39 trust-anchor release' \
  preflight v1.8.65 "$work/reserved-bridge-version.app" "$legacy_key"

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
grep -q "stat -c '%u:%g:%a:%h:%F'" "$publisher" || fail "remote transfer metadata is not verified"
grep -q 'verify-malibu-bootstrap-publication.sh' "$publisher" || fail "public bytes are not verified"
if grep -q -- '--resolve' "$public_verifier" || grep -q 'MALIBU_DOWNLOAD_RESOLVE_IP' "$publisher"; then
  fail "public verification can bypass client DNS resolution"
fi
grep -q 'same-tag publication drift refused' "$installer" || fail "same-tag drift is not refused"
grep -q 'single same-filesystem rename is the public transaction boundary' "$installer" ||
  fail "DMG and appcast do not share one atomic switch"

mkdir -p "$work/input" "$work/webroot"
printf 'signed dmg bytes\n' > "$work/input/Malibu-v1.8.39.dmg"
printf 'signed appcast bytes\n' > "$work/input/appcast.xml"
printf 'artifact index bytes\n' > "$work/input/compatibility-artifact-index.json"

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
dmg_sha="$(shasum -a 256 "$work/input/Malibu-v1.8.39.dmg" | awk '{print $1}')"
printf '%s  Malibu-v1.8.39.dmg\n' "$dmg_sha" > "$work/input/Malibu-v1.8.39.dmg.sha256"

MALIBU_PUBLICATION_TESTING=1 bash "$installer" \
  "$work/webroot" v1.8.39 "$publication_id" \
  "$work/input/publication-manifest.json" "$work/input/Malibu-v1.8.39.dmg" \
  "$work/input/appcast.xml" "$work/input/Malibu-v1.8.39.dmg.sha256" \
  '' ''

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
  '' '' \
  >"$work/drift.out" 2>&1; then
  fail "same-tag publication drift was accepted"
fi
grep -q 'same-tag publication drift refused' "$work/drift.out" || fail "drift rejection was unclear"

create_manifest "$work/input/prerelease.json" \
  "$work/input/Malibu-v1.8.39.dmg" "$work/input/appcast.xml" \
  "$work/input/compatibility-artifact-index.json" true >/dev/null
if MALIBU_PUBLICATION_TESTING=1 bash "$installer" \
  "$work/prerelease-webroot" v1.8.39 "$publication_id" \
  "$work/input/prerelease.json" "$work/input/Malibu-v1.8.39.dmg" \
  "$work/input/appcast.xml" "$work/input/Malibu-v1.8.39.dmg.sha256" \
  '' '' \
  >"$work/prerelease.out" 2>&1; then
  fail "prerelease bridge was accepted"
fi
grep -q 'prerelease must not publish' "$work/prerelease.out" || fail "prerelease rejection was unclear"

# The appcast generator stays frozen to v1.8.39, so a later tag must still be
# rejected there even though the download promotion itself is generalized.
if bash "$generator" v1.8.40 >"$work/generator.out" 2>&1; then
  fail "bridge generator accepted a later tag"
fi
grep -q 'frozen to v1.8.39' "$work/generator.out" || fail "generator tag rejection was unclear"

# --- Generalized (non-v1.8.39) download promotion ---------------------------
# A later stable tag is promoted with the committed frozen bridge appcast (which
# is not a per-release asset) beside the newer DMG, plus the signed
# acceptance-candidate produced by acceptance-candidate.yml.
gen_tag=v1.8.70
gen_dmg="$work/input/Malibu-${gen_tag}.dmg"
printf 'signed notarized 1.8.70 dmg bytes\n' > "$gen_dmg"
# Byte-identical to the committed frozen bridge appcast so its digest matches the
# pin embedded in install-malibu-publication.sh.
cp "$root/scripts/dist/malibu-frozen-bridge-appcast.xml" "$work/input/frozen-appcast.xml"
printf '{"schema_version":"macprovider.acceptance-candidate.v1"}\n' \
  > "$work/input/acceptance-candidate.json"
printf 'acceptance signature bytes\n' > "$work/input/acceptance-candidate.json.sig"

gen_publication_id="$(python3 - \
  "$work/input/publication-manifest-generalized.json" \
  "$gen_dmg" "$work/input/compatibility-artifact-index.json" "$gen_tag" <<'PY'
import hashlib
import json
import pathlib
import sys

output, dmg_name, index_name, tag = sys.argv[1:]
dmg_digest = hashlib.sha256(pathlib.Path(dmg_name).read_bytes()).hexdigest()
index_digest = hashlib.sha256(pathlib.Path(index_name).read_bytes()).hexdigest()
# Non-v1.8.39 promotions exclude the frozen bridge appcast from the manifest and
# publication_id, exactly like capture-release-publication.py.
identity = hashlib.sha256(json.dumps({
    "compatibility_artifact_index_sha256": index_digest,
    "dmg_sha256": dmg_digest,
}, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
manifest = {
    "schema_version": 1,
    "repository": "Augustas11/macprovider",
    "tag": tag,
    "commit": "b" * 40,
    "prerelease": False,
    "release_id": 505,
    "publication_id": identity,
    "assets": {
        f"Malibu-{tag}.dmg": {"id": 900, "sha256": dmg_digest},
        "compatibility-artifact-index.json": {"id": 901, "sha256": index_digest},
    },
}
pathlib.Path(output).write_text(json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n")
print(identity)
PY
)"
gen_dmg_sha="$(shasum -a 256 "$gen_dmg" | awk '{print $1}')"
printf '%s  Malibu-%s.dmg\n' "$gen_dmg_sha" "$gen_tag" > "$work/input/Malibu-${gen_tag}.dmg.sha256"

MALIBU_PUBLICATION_TESTING=1 bash "$installer" \
  "$work/generalized-webroot" "$gen_tag" "$gen_publication_id" \
  "$work/input/publication-manifest-generalized.json" "$gen_dmg" \
  "$work/input/frozen-appcast.xml" "$work/input/Malibu-${gen_tag}.dmg.sha256" \
  "$work/input/acceptance-candidate.json" "$work/input/acceptance-candidate.json.sig"

gen_release="$work/generalized-webroot/.malibu-current"
[[ -L "$gen_release" ]] || fail "generalized current pointer is not atomic"
[[ "$(cat "$work/generalized-webroot/latest.dmg")" == 'signed notarized 1.8.70 dmg bytes' ]] ||
  fail "generalized latest DMG differs"
[[ "$(cat "$work/generalized-webroot/Malibu-${gen_tag}.dmg")" == 'signed notarized 1.8.70 dmg bytes' ]] ||
  fail "generalized versioned DMG differs"
cmp -s "$work/generalized-webroot/appcast.xml" \
  "$root/scripts/dist/malibu-frozen-bridge-appcast.xml" ||
  fail "generalized promotion did not serve the frozen bridge appcast"
cmp -s "$gen_release/acceptance-candidate.json" "$work/input/acceptance-candidate.json" ||
  fail "generalized promotion did not place the acceptance-candidate"
cmp -s "$gen_release/acceptance-candidate.json.sig" "$work/input/acceptance-candidate.json.sig" ||
  fail "generalized promotion did not place the acceptance-candidate signature"

# A generalized promotion must reject an appcast that is not the frozen bridge.
printf 'not the frozen bridge appcast\n' > "$work/input/wrong-appcast.xml"
if MALIBU_PUBLICATION_TESTING=1 bash "$installer" \
  "$work/wrong-appcast-webroot" "$gen_tag" "$gen_publication_id" \
  "$work/input/publication-manifest-generalized.json" "$gen_dmg" \
  "$work/input/wrong-appcast.xml" "$work/input/Malibu-${gen_tag}.dmg.sha256" \
  "$work/input/acceptance-candidate.json" "$work/input/acceptance-candidate.json.sig" \
  >"$work/wrong-appcast.out" 2>&1; then
  fail "generalized promotion accepted a non-frozen appcast"
fi
grep -q 'not the frozen Malibu bridge appcast' "$work/wrong-appcast.out" ||
  fail "non-frozen appcast rejection was unclear"

# A generalized promotion must require the signed acceptance-candidate pair.
if MALIBU_PUBLICATION_TESTING=1 bash "$installer" \
  "$work/missing-acceptance-webroot" "$gen_tag" "$gen_publication_id" \
  "$work/input/publication-manifest-generalized.json" "$gen_dmg" \
  "$work/input/frozen-appcast.xml" "$work/input/Malibu-${gen_tag}.dmg.sha256" \
  '' '' \
  >"$work/missing-acceptance.out" 2>&1; then
  fail "generalized promotion accepted a missing acceptance-candidate"
fi
grep -q 'requires the staged acceptance-candidate pair' "$work/missing-acceptance.out" ||
  fail "missing acceptance-candidate rejection was unclear"

echo 'Malibu bootstrap bridge regression checks passed'
