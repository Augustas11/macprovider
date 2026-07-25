#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/malibu-release.yml"
GUARD="$ROOT/scripts/malibu-release-workflow-guard.py"
TMP="$(mktemp -d)"
trap 'find "$TMP" -type f -delete; find "$TMP" -depth -type d -delete' EXIT

fail() {
  echo "test-malibu-release-workflow: $*" >&2
  exit 1
}

test -f "$WORKFLOW"
test -f "$GUARD"
python3 -m py_compile "$GUARD"
ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "$WORKFLOW"

python3 - "$WORKFLOW" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
required = (
    "workflow_dispatch:",
    "environment: production-release",
    "group: production-release",
    "PROVIDER_TAG: v1.8.40",
    "PROVIDER_COMMIT: 18638472fe3e885f3534eeac29ab89b4c7ffdd7a",
    "PROVIDER_SET_SHA256: fe17e7a3cca392edea185c304970ef6d6fb9f06ff65aa6cffed6c7d9325a161c",
    "scripts/malibu-release-envelope.py sign-envelope",
    "scripts/malibu-release-envelope.py sign-index",
    "scripts/malibu-release-envelope.py validate-envelope",
    "scripts/malibu-release-envelope.py validate-index",
    "scripts/install-malibu-app.sh",
    'only Malibu under \\`\\$HOME/Applications\\`',
    '"trust": {',
    '"keyring_generation": int(os.environ["KEYRING_GENERATION"])',
    '"revocations_generation": int(os.environ["REVOCATIONS_GENERATION"])',
    "--verify-tag --draft",
    "-f make_latest=false",
    "provider-publication-provenance.json",
    "publication-provenance.json",
    "jobs:\n  sign_publish:",
    "Revalidate protected single-job build before importing identities",
    'ref: ${{ github.event.inputs.source_commit }}',
    "Build unsigned Malibu app and embed exact public CLI bytes",
    "MALIBU_RELEASE_ENVELOPE_SIGNING_KEY_PEM",
    'Malibu-v$APP_VERSION-app-only-installer.pkg',
    'No second executable package is',
    "tech.malibu.app.transaction-installer",
    'productsign --sign "$INSTALLER_ID"',
    'spctl -a -vvv -t install "$installer_pkg"',
    'pkgutil --check-signature "$installer_pkg"',
    '"schema_version": "malibu-root-install-marker.v1"',
    '"helper_sha256": digest("malibu-app-transaction.py")',
    '"validator_sha256": digest("malibu-release-envelope.py")',
    '"schema_version": "malibu-recovery-selector.v1"',
    'pending-recovery.json',
    'Malibu requires the root-owned system /usr/bin/python3 runtime',
    'marker="/Library/Application Support/Malibu/AppInstaller/installed-marker.json"',
    'os.replace(temporary, marker_root / "installed-marker.json")',
    '/bin/chmod 0444 "$marker" "${retained[@]}"',
)
for value in required:
    if value not in text:
        raise SystemExit(f"missing fail-closed workflow invariant: {value}")

for forbidden in (
    "phase3-binary/dist/package.sh",
    "go build",
    'gh release create "$PROVIDER_TAG"',
    'test "$app_version" = "$PROVIDER_VERSION"',
    'test "$APP_VERSION" = "$PROVIDER_VERSION"',
    "make_latest=true",
    'Drag `Malibu.app` to `/Applications`',
    "MACPROVIDER_RELEASE_SIGNING_KEY_PEM",
    "malibu-build-handoff",
    "Malibu-unsigned.zip",
    "download-artifact@",
    'Malibu-v$APP_VERSION-app-only-installer.zip',
    "Extract it, then run",
    '/bin/rm -rf "$stage"',
    'Malibu-v$APP_VERSION-darwin-arm64.pkg',
):
    if forbidden in text:
        raise SystemExit(f"app-only workflow contains forbidden provider coupling/mutation: {forbidden}")

if text.count("verify-latest") < 3:
    raise SystemExit("generic provider latest is not checked before build, before promotion, and after promotion")
if text.index("--verify-tag --draft") > text.index("-f make_latest=false"):
    raise SystemExit("publication does not transition through a draft before promotion")
if text.rindex("verify-latest") < text.index("-f make_latest=false"):
    raise SystemExit("generic latest is not rechecked after promotion")
if 'provider_release_key_sha=' not in text or '"$actual_envelope_key_sha" != "$provider_release_key_sha"' not in text:
    raise SystemExit("Malibu release does not fail closed when its envelope key equals the provider key")
if text.index("Build unsigned Malibu app and embed exact public CLI bytes") > text.index("Import release signing identities"):
    raise SystemExit("protected signing identities are imported before the reviewed source rebuild")
if text.index("Generate and sign Malibu envelope") > text.index("authenticated app-only installer"):
    raise SystemExit("supported installer package is built before its signed sidecars exist")
selector_commit = text.index('os.replace(temporary, root / "pending-recovery.json")')
transaction_start = text.index('"$stage/install-malibu-app.sh"')
marker_commit = text.index('os.replace(temporary, marker_root / "installed-marker.json")')
selector_cleanup = text.index('/bin/rm -f "$selector"')
if not selector_commit < transaction_start < marker_commit < selector_cleanup:
    raise SystemExit("recovery selector and installed marker are not ordered around the user transaction")
selector_block = text[text.index("selector = {"):text.index("temporary = root /", text.index("selector = {"))]
for field in (
    '"app_build"', '"app_version"', '"envelope_sha256"', '"helper_path"',
    '"helper_sha256"', '"index_sha256"', '"keyring_sha256"',
    '"public_key_sha256"', '"revocations_sha256"', '"validator_sha256"',
):
    if field not in selector_block:
        raise SystemExit(f"pending recovery authority is not digest-complete: {field}")
cleanup = text[text.index('/bin/rm -f "$selector"'):text.index('exit 0\n          POSTINSTALL')]
for retained_name in (
    "malibu-app-transaction.py",
    "malibu-release-envelope.py",
    "malibu-release-keyring.json",
    "malibu-release-revocations.json",
    "release-signing-public.pem",
):
    if retained_name in cleanup:
        raise SystemExit(f"postinstall cleanup deletes retained rollback evidence: {retained_name}")
job_ids = re.findall(r"^  ([A-Za-z0-9_-]+):\s*$", text[text.index("jobs:"):], re.MULTILINE)
if job_ids != ["sign_publish"]:
    raise SystemExit(f"Malibu release must remain one protected build/sign job, found: {job_ids}")

uses = re.findall(r"^\s*uses:\s*(\S+)\s*$", text, re.MULTILINE)
if not uses:
    raise SystemExit("workflow contains no actions")
for action in uses:
    if re.fullmatch(r"[^@]+@[0-9a-f]{40}", action) is None:
        raise SystemExit(f"workflow action is not content pinned: {action}")
PY

python3 - "$GUARD" <<'PY'
import runpy
import sys

module = runpy.run_path(sys.argv[1], run_name="malibu_release_guard_test")
expected = {
    "macprovider-cli-v1.8.40-darwin-arm64.tar.gz": (
        478848746,
        "1eee4900109f958c95c66830f17295bfba4dfe93e0a72aa720f0ed20a9b2b918",
    ),
    "compatibility-set.json": (
        478848772,
        "fe17e7a3cca392edea185c304970ef6d6fb9f06ff65aa6cffed6c7d9325a161c",
    ),
    "checksums.txt": (
        478848792,
        "48c6c736a460d7f31e21c4ea0e779ce6cf1cf8542dd877c1df8ccaa14e33eaf1",
    ),
    "checksums.txt.sig": (
        478848796,
        "73719f4ccc28c3baf2a91f94461ce35f36ea27b79bbf68d32d0bf8bae901f207",
    ),
}
if module["PROVIDER_RELEASE_ID"] != 354899176 or module["PROVIDER_ASSETS"] != expected:
    raise SystemExit("immutable provider numeric provenance constants drifted")
PY

mkdir -p "$TMP/assets"
printf 'signed-app-bytes\n' > "$TMP/assets/Malibu-v1.8.41.dmg"
printf '%s\n' Malibu-v1.8.41.dmg > "$TMP/assets.txt"
printf '%s\n' '{"provider":{"commit":"18638472fe3e885f3534eeac29ab89b4c7ffdd7a","release_id":354899176,"tag":"v1.8.40"}}' > "$TMP/provider.json"

python3 - "$TMP" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
commit = "18638472fe3e885f3534eeac29ab89b4c7ffdd7a"
latest = {
    "id": 354899176,
    "tag_name": "v1.8.40",
    "target_commitish": commit,
    "draft": False,
    "prerelease": False,
    "immutable": True,
}
(root / "latest.json").write_text(json.dumps(latest), encoding="utf-8")

assets = []
for index, name in enumerate(("Malibu-v1.8.41.dmg",), 7001):
    digest = hashlib.sha256((root / "assets" / name).read_bytes()).hexdigest()
    assets.append({"id": index, "name": name, "digest": f"sha256:{digest}"})
draft = {
    "id": 9001,
    "tag_name": "malibu-v1.8.41",
    "target_commitish": commit,
    "draft": True,
    "prerelease": False,
    "immutable": False,
    "assets": assets,
}
(root / "draft.json").write_text(json.dumps(draft), encoding="utf-8")
tampered = dict(draft)
tampered["assets"] = [dict(row) for row in assets]
tampered["assets"][0]["digest"] = "sha256:" + "0" * 64
(root / "tampered.json").write_text(json.dumps(tampered), encoding="utf-8")
wrong_latest = dict(latest)
wrong_latest["tag_name"] = "malibu-v1.8.41"
(root / "wrong-latest.json").write_text(json.dumps(wrong_latest), encoding="utf-8")
PY

python3 "$GUARD" verify-latest --release-json "$TMP/latest.json"
if python3 "$GUARD" verify-latest --release-json "$TMP/wrong-latest.json" >/dev/null 2>&1; then
  fail "Malibu tag was accepted as generic provider latest"
fi
python3 "$GUARD" verify-app-release \
  --release-json "$TMP/draft.json" \
  --assets-dir "$TMP/assets" \
  --asset-names "$TMP/assets.txt" \
  --provider-provenance "$TMP/provider.json" \
  --tag malibu-v1.8.41 \
  --commit 18638472fe3e885f3534eeac29ab89b4c7ffdd7a \
  --draft \
  --output "$TMP/captured.json"
if python3 "$GUARD" verify-app-release \
  --release-json "$TMP/tampered.json" \
  --assets-dir "$TMP/assets" \
  --asset-names "$TMP/assets.txt" \
  --provider-provenance "$TMP/provider.json" \
  --tag malibu-v1.8.41 \
  --commit 18638472fe3e885f3534eeac29ab89b4c7ffdd7a \
  --draft \
  --output "$TMP/should-not-exist.json" >/dev/null 2>&1; then
  fail "tampered GitHub asset digest was accepted"
fi

echo "malibu release workflow tests passed"
