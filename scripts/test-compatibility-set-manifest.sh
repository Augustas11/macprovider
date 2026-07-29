#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tool="$root/scripts/compatibility-set-manifest.py"
schema="$root/schemas/compatibility-set-manifest-v1.schema.json"
rollback_schema="$root/schemas/updater-rollback-v1.schema.json"
catalog="$root/phase3-binary/catalog/autotune"
catalog_feeds="$root/phase3-binary/dist/static"
work="$(mktemp -d "${TMPDIR:-/tmp}/compatibility-set-manifest.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() {
  printf 'test-compatibility-set-manifest: %s\n' "$*" >&2
  exit 1
}

tag="v1.8.42"
provider_cli_version="1.8.40"
malibu_app_version="1.8.41"
commit="0123456789abcdef0123456789abcdef01234567"
manifest="$work/compatibility-set.json"
second="$work/compatibility-set-second.json"
local_artifacts="$work/local-artifacts"
payload="$work/payload"
mkdir -p "$local_artifacts" "$payload/catalog-release"
cp "$root/phase3-binary/dist/install.sh" "$local_artifacts/install.sh"
cp "$root/ops/macprovider-watchdog/watchdog.sh" "$local_artifacts/watchdog.sh"
cp "$root/phase3-binary/dist/compatibility-set-assets/"*.template "$local_artifacts/"
cp "$root/phase3-binary/dist/compatibility-set-assets/updater-rollback.json" "$local_artifacts/"
cp -R "$local_artifacts" "$payload/compatibility-set-local"
cp "$catalog/release.json" "$catalog/trusted-keys.json" "$catalog/tier2-catalog.json" "$payload/catalog-release/"
cp "$catalog_feeds/autotune-candidates.json" "$catalog_feeds/autotune-candidates.json.sig" \
  "$catalog_feeds/demand-rank.json" "$catalog_feeds/demand-rank.json.sig" \
  "$catalog_feeds/rate-card.json" "$catalog_feeds/rate-card.json.sig" "$payload/catalog-release/"

python3 "$tool" generate \
  --tag "$tag" \
  --commit "$commit" \
  --provider-cli-version "$provider_cli_version" \
  --malibu-app-version "$malibu_app_version" \
  --provider-admission-policy bridge_required \
  --catalog-directory "$catalog" \
  --catalog-feed-directory "$catalog_feeds" \
  --local-artifacts-directory "$local_artifacts" \
  --output "$manifest"
python3 "$tool" generate \
  --tag "$tag" \
  --commit "$commit" \
  --provider-cli-version "$provider_cli_version" \
  --malibu-app-version "$malibu_app_version" \
  --provider-admission-policy bridge_required \
  --catalog-directory "$catalog" \
  --catalog-feed-directory "$catalog_feeds" \
  --local-artifacts-directory "$local_artifacts" \
  --output "$second"
cmp "$manifest" "$second"
python3 "$tool" validate \
  --input "$manifest" \
  --expected-tag "$tag" \
  --expected-commit "$commit" \
  --expected-provider-cli-version "$provider_cli_version" \
  --expected-malibu-app-version "$malibu_app_version" \
  --expected-provider-admission-policy bridge_required
cp "$manifest" "$payload/compatibility-set.json"
python3 "$tool" validate --input "$manifest" --payload-directory "$payload"

python3 - "$schema" "$rollback_schema" "$manifest" "$local_artifacts" \
  "$provider_cli_version" "$malibu_app_version" <<'PY'
import hashlib
import json
import pathlib
import sys

schema = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
rollback_schema = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
manifest = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
assert schema["$id"].endswith("compatibility-set-manifest-v1.schema.json")
assert set(schema["required"]) == {"schema_version", "signatures", "signed"}
assert manifest["signatures"] == []
assert manifest["signed"]["transaction"]["activation"] == "crash_recoverable_local_activation_group"
assert manifest["signed"]["transaction"]["membership"] == {
    "local_activation_group": ["catalog", "launchd", "malibu_app", "provider_cli", "release_resources", "updater_rollback", "watchdog"],
    "required_external_gates": ["coordinator_admission"],
    "preserved_state_invariants": ["credentials", "identity", "operator_config"],
}
assert manifest["signed"]["artifact_binding"]["embedded_container_hashes"] == "excluded_to_avoid_self_reference"
assert rollback_schema["properties"]["rollback_order"]["const"] == [
    "release_resources", "catalog", "updater_rollback", "watchdog", "launchd", "malibu_app", "provider_cli"
]
local = pathlib.Path(sys.argv[4])
provider_cli_version = sys.argv[5]
malibu_app_version = sys.argv[6]
rollback_plan = json.loads((local / "updater-rollback.json").read_text(encoding="utf-8"))
assert rollback_plan["activation_checkpoints"][-2:] == ["binary_activated", "malibu_app_activated"]
assert rollback_plan["rollback_order"] == rollback_schema["properties"]["rollback_order"]["const"]
assert manifest["signed"]["components"]["launchd"]["install_contract"]["sha256"] == hashlib.sha256((local / "install.sh").read_bytes()).hexdigest()
assert manifest["signed"]["components"]["watchdog"]["script"]["sha256"] == hashlib.sha256((local / "watchdog.sh").read_bytes()).hexdigest()
assert manifest["signed"]["components"]["coordinator_admission"]["activation"] == "required_remote_gate"
assert manifest["signed"]["components"]["coordinator_admission"]["handshake"] == "accepted_set_echo_v1"
assert manifest["signed"]["components"]["coordinator_admission"]["scope"] == "remote_coordinator_policy"
assert manifest["signed"]["components"]["malibu_app"]["activation"] == "cli_owned_if_installed"
assert manifest["signed"]["components"]["provider_cli"]["version"] == provider_cli_version
assert manifest["signed"]["components"]["malibu_app"]["version"] == malibu_app_version
assert manifest["signed"]["release"]["version"] == "1.8.42"
assert manifest["signed"]["components"]["coordinator_admission"]["version"] == "1.8.42"
serialized = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
for forbidden in ("tar_sha256", "pkg_sha256", "dmg_sha256", "app_sha256", "cli_sha256"):
    assert forbidden not in serialized
PY

python3 - "$root" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
package = (root / "phase3-binary/dist/package.sh").read_text(encoding="utf-8")
workflow = (root / ".github/workflows/release.yml").read_text(encoding="utf-8")
installer = (root / "phase3-binary/dist/install.sh").read_text(encoding="utf-8")
artifact_checker = (root / "scripts/check-tier2-provider-artifact.sh").read_text(encoding="utf-8")
for required in (
    'PACKAGE_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macprovider-package.XXXXXX")"',
    'COMPATIBILITY_SET_MANIFEST="$PACKAGE_WORK_DIR/compatibility-set.json"',
    'LOCAL_COMPATIBILITY_SET_DIR="$PACKAGE_WORK_DIR/compatibility-set-local"',
    'trap cleanup EXIT',
    'BUILD_LOG="$PACKAGE_WORK_DIR/package-build.log"',
    'NOTICES_FILE="$PACKAGE_WORK_DIR/THIRD-PARTY-NOTICES.txt"',
    'STAGE_DIR="$PACKAGE_WORK_DIR/stage"',
    'cp "$COMPATIBILITY_SET_MANIFEST" "$STAGE_DIR/compatibility-set.json"',
    'cp "$PHASE3_DIR/catalog/autotune/tier2-catalog.json" "$STAGE_DIR/catalog-release/"',
    'cp "$PHASE3_DIR/dist/static/rate-card.json" "$STAGE_DIR/catalog-release/"',
    '--provider-cli-version "$PROVIDER_CLI_VERSION"',
    '--malibu-app-version "$MALIBU_APP_VERSION"',
    'cp -R "$LOCAL_COMPATIBILITY_SET_DIR" "$STAGE_DIR/compatibility-set-local"',
    'archive_members=(',
    'tar czf "$TARBALL" -C "$STAGE_DIR" "${archive_members[@]}"',
    'compatibility-set envelope',
):
    assert required in package, required
assert 'tar czf "$TARBALL" -C "$STAGE_DIR" .' not in package
assert '"$WORK/macprovider-cli" release-payload-preflight' not in workflow
assert "Verify exact arm64 provider runtime" in workflow
assert 'provider_version="$("$provider_binary" --version)"' in workflow
assert "scripts/compatibility-set-manifest.py validate" in workflow
assert '"$provider_binary" release-payload-preflight' in artifact_checker
assert 'provider_version_at_least 1 8 39' in artifact_checker
archive_contract = re.search(
    r'archive_members=\(\n(?P<required>.*?)\n\)\n'
    r'swiftpm_bundle_count=0\n'
    r'for swiftpm_bundle in (?P<optional>[^;]+); do\n'
    r'(?P<body>.*?)\ndone',
    package,
    re.DOTALL,
)
assert archive_contract is not None
assert archive_contract.group("required").split() == [
    "macprovider-cli",
    "mlx.metallib",
    "THIRD-PARTY-NOTICES.txt",
    "compatibility-set.json",
    "compatibility-set-local",
    "catalog-release",
]
assert archive_contract.group("optional").split() == [
    "mlx-swift_Cmlx.bundle",
    "swift-nio_NIOPosix.bundle",
]
for required in (
    'if [ -d "$STAGE_DIR/$swiftpm_bundle" ]; then',
    'archive_members+=("$swiftpm_bundle")',
    'swiftpm_bundle_count=$((swiftpm_bundle_count + 1))',
):
    assert required in archive_contract.group("body"), required
assert '[ "$swiftpm_bundle_count" -gt 0 ]' in package
release_archive_contract = re.search(
    r'release_archive_members=\(\n(?P<required>.*?)\n\s+\)\n'
    r'\s+release_bundle_count=0\n'
    r'\s+for release_bundle in (?P<optional>[^;]+); do\n'
    r'(?P<body>.*?)\n\s+done',
    workflow,
    re.DOTALL,
)
assert release_archive_contract is not None
assert release_archive_contract.group("required").split() == [
    "macprovider-cli",
    "mlx.metallib",
    "THIRD-PARTY-NOTICES.txt",
    "compatibility-set.json",
    "compatibility-set-local",
    "catalog-release",
]
assert release_archive_contract.group("optional").split() == [
    "mlx-swift_Cmlx.bundle",
    "swift-nio_NIOPosix.bundle",
]
for required in (
    'if [ -d "$WORK/$release_bundle" ]; then',
    'release_archive_members+=("$release_bundle")',
    'release_bundle_count=$((release_bundle_count + 1))',
):
    assert required in release_archive_contract.group("body"), required
assert '[ "$release_bundle_count" -gt 0 ]' in workflow
assert 'tar czf "$src" -C "$WORK" "${release_archive_members[@]}"' in workflow
assert 'tar czf "$src" -C "$WORK" .' not in workflow
for required in (
    "scripts/compatibility-set-manifest.py sign",
    'cp "$WORK/compatibility-set.json" "$PKG_ROOT/compatibility-set.json"',
    '"$APP/Contents/Resources/compatibility-set.json"',
    'release_assets+=("$compatibility_manifest")',
    'cmp "$compatibility_manifest" "$compatibility_extract/compatibility-set.json"',
):
    assert required in workflow, required
for required in (
    'compatibility-set.json)',
    'cp "$staging_dir/compatibility-set.json" "$INSTALL_DIR/compatibility-set.json"',
    '"compatibility-set.json", "compatibility-set-local", "catalog-release"',
):
    assert required in installer, required
PY

archive_fixture="$work/archive-fixture"
mkdir -p "$archive_fixture/compatibility-set-local" "$archive_fixture/catalog-release" \
  "$archive_fixture/mlx-swift_Cmlx.bundle/Contents/Resources"
printf 'fixture\n' > "$archive_fixture/macprovider-cli"
printf 'fixture\n' > "$archive_fixture/mlx.metallib"
printf 'fixture\n' > "$archive_fixture/THIRD-PARTY-NOTICES.txt"
printf 'fixture\n' > "$archive_fixture/compatibility-set.json"
printf 'fixture\n' > "$archive_fixture/compatibility-set-local/install.sh"
printf 'fixture\n' > "$archive_fixture/catalog-release/release.json"
printf 'fixture\n' > "$archive_fixture/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
archive_members=(
  macprovider-cli
  mlx.metallib
  THIRD-PARTY-NOTICES.txt
  compatibility-set.json
  compatibility-set-local
  catalog-release
  mlx-swift_Cmlx.bundle
)
tar czf "$work/provider.tar.gz" -C "$archive_fixture" "${archive_members[@]}"
python3 "$root/scripts/acceptance-candidate-metadata.py" validate-archive \
  --input "$work/provider.tar.gz" --forbid-links
tar tzf "$work/provider.tar.gz" > "$work/provider-archive-members.txt"
if grep -Fxq . "$work/provider-archive-members.txt"; then
  fail "provider archive contains an ambiguous root member"
fi
tar czf "$work/provider-with-root.tar.gz" -C "$archive_fixture" .
if python3 "$root/scripts/acceptance-candidate-metadata.py" validate-archive \
  --input "$work/provider-with-root.tar.gz" --forbid-links \
  > "$work/provider-with-root.out" 2>&1; then
  fail "acceptance archive validation accepted an ambiguous root member"
fi
grep -Fq "archive: unsafe member path" "$work/provider-with-root.out"

openssl ecparam -name prime256v1 -genkey -noout -out "$work/private.pem" >/dev/null 2>&1
openssl pkey -in "$work/private.pem" -pubout -out "$work/public.pem" >/dev/null 2>&1
python3 "$tool" sign --input "$manifest" --private-key "$work/private.pem"
python3 "$tool" validate \
  --input "$manifest" \
  --require-signature \
  --public-key "$work/public.pem" \
  --expected-tag "$tag" \
  --expected-commit "$commit" \
  --expected-provider-cli-version "$provider_cli_version" \
  --expected-malibu-app-version "$malibu_app_version" \
  --expected-provider-admission-policy bridge_required

if python3 "$tool" validate \
  --input "$manifest" \
  --expected-provider-cli-version 1.8.39 \
  >"$work/provider-version-mismatch.out" 2>&1; then
  fail "manifest validation accepted the wrong provider CLI component version"
fi
grep -q "provider CLI version mismatch" "$work/provider-version-mismatch.out"

if python3 "$tool" validate \
  --input "$manifest" \
  --expected-malibu-app-version 1.8.40 \
  >"$work/malibu-version-mismatch.out" 2>&1; then
  fail "manifest validation accepted the wrong Malibu component version"
fi
grep -q "Malibu app version mismatch" "$work/malibu-version-mismatch.out"

cp -R "$payload" "$work/payload-tampered"
printf '\n' >> "$work/payload-tampered/compatibility-set-local/watchdog.sh"
if python3 "$tool" validate --input "$manifest" --payload-directory "$work/payload-tampered" \
  >"$work/local-artifact-tampered.out" 2>&1; then
  fail "payload validation accepted a mutated local activation artifact"
fi
grep -q 'payload artifact digest mismatch' "$work/local-artifact-tampered.out"

cp -R "$local_artifacts" "$work/local-artifacts-invalid-plan"
python3 - "$work/local-artifacts-invalid-plan/updater-rollback.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["rollback_order"].reverse()
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
if python3 "$tool" generate \
  --tag "$tag" \
  --commit "$commit" \
  --provider-admission-policy bridge_required \
  --catalog-directory "$catalog" \
  --catalog-feed-directory "$catalog_feeds" \
  --local-artifacts-directory "$work/local-artifacts-invalid-plan" \
  --output "$work/invalid-plan.json" >"$work/invalid-plan.out" 2>&1; then
  fail "manifest generator accepted an unsupported rollback order"
fi
grep -q 'unsupported execution contract' "$work/invalid-plan.out"

openssl ecparam -name prime256v1 -genkey -noout -out "$work/wrong-private.pem" >/dev/null 2>&1
openssl pkey -in "$work/wrong-private.pem" -pubout -out "$work/wrong-public.pem" >/dev/null 2>&1
if python3 "$tool" validate --input "$manifest" --require-signature --public-key "$work/wrong-public.pem" \
  >"$work/wrong-key.out" 2>&1; then
  fail "signature verified with an unrelated key"
fi
grep -q 'signature verification' "$work/wrong-key.out"

python3 - "$manifest" "$work/tampered.json" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
value["signed"]["transaction"]["readiness_proof"]["timeout_seconds"] = 1199
pathlib.Path(sys.argv[2]).write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
if python3 "$tool" validate --input "$work/tampered.json" --require-signature --public-key "$work/public.pem" \
  >"$work/tampered.out" 2>&1; then
  fail "signature accepted a modified semantic payload"
fi
grep -q 'signature verification' "$work/tampered.out"

python3 - "$manifest" "$work/duplicate.json" "$work/noncanonical.json" "$work/unknown.json" <<'PY'
import json
import pathlib
import sys

raw = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
pathlib.Path(sys.argv[2]).write_text(raw.replace('{"schema_version":', '{"schema_version":"duplicate","schema_version":', 1), encoding="utf-8")
value = json.loads(raw)
pathlib.Path(sys.argv[3]).write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
value["signed"]["tar_sha256"] = "0" * 64
pathlib.Path(sys.argv[4]).write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
for fixture in duplicate noncanonical unknown; do
  if python3 "$tool" validate --input "$work/$fixture.json" >"$work/$fixture.out" 2>&1; then
    fail "$fixture manifest unexpectedly passed"
  fi
done
grep -q 'duplicate object key' "$work/duplicate.out"
grep -q 'canonical sorted compact encoding' "$work/noncanonical.out"
grep -q 'unknown fields' "$work/unknown.out"

cp -R "$catalog_feeds" "$work/catalog-feeds-tampered"
printf '\n' >> "$work/catalog-feeds-tampered/demand-rank.json"
if python3 "$tool" generate \
  --tag "$tag" \
  --commit "$commit" \
  --provider-admission-policy bridge_required \
  --catalog-directory "$catalog" \
  --catalog-feed-directory "$work/catalog-feeds-tampered" \
  --local-artifacts-directory "$local_artifacts" \
  --output "$work/catalog-tampered.json" >"$work/catalog-tampered.out" 2>&1; then
  fail "manifest generator accepted a feed that differs from the catalog release"
fi
grep -q 'does not match packaged feed' "$work/catalog-tampered.out"
python3 "$tool" generate \
  --tag "$tag" \
  --commit "$commit" \
  --provider-admission-policy strict_post_migration \
  --catalog-directory "$catalog" \
  --catalog-feed-directory "$catalog_feeds" \
  --local-artifacts-directory "$local_artifacts" \
  --output "$work/strict.json"
python3 "$tool" validate \
  --input "$work/strict.json" \
  --expected-provider-admission-policy strict_post_migration
if cmp -s "$second" "$work/strict.json"; then
  fail "catalog or admission-policy change did not alter the manifest"
fi

printf 'test-compatibility-set-manifest: ok\n'
