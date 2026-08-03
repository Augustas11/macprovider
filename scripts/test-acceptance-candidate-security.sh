#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
workflow="$root/.github/workflows/acceptance-candidate.yml"
metadata="$root/scripts/acceptance-candidate-metadata.py"
signer="$root/scripts/sign-acceptance-candidate.sh"
keychain_helper="$root/scripts/acceptance-signing-keychain.sh"
source_guard="$root/scripts/verify-acceptance-candidate-source.sh"
remote_guard="$root/scripts/verify-acceptance-remote-state.sh"
provisioner="$root/scripts/provision-acceptance-signing-key.sh"
release_discovery="$root/scripts/build-release-discovery-head.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/acceptance-security.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() {
  printf '[test-acceptance-candidate-security] ERROR: %s\n' "$*" >&2
  exit 1
}

python3 - "$workflow" "$metadata" "$signer" "$keychain_helper" "$provisioner" "$root/schemas/acceptance-candidate-v1.schema.json" "$release_discovery" <<'PY'
import ast
import pathlib
import re
import sys

workflow = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
metadata = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
signer = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
keychain_helper = pathlib.Path(sys.argv[4]).read_text(encoding="utf-8")
provisioner = pathlib.Path(sys.argv[5]).read_text(encoding="utf-8")
schema = __import__("json").loads(pathlib.Path(sys.argv[6]).read_text(encoding="utf-8"))
release_discovery = pathlib.Path(sys.argv[7])

if "\n  workflow_dispatch:\n" not in workflow or "\n  push:" in workflow:
    raise SystemExit("acceptance workflow must be manual dispatch only")
build = workflow.split("\n  build_candidate:\n", 1)[1].split("\n  sign_acceptance:\n", 1)[0]
protected = workflow.split("\n  sign_acceptance:\n", 1)[1]
if "secrets." in build or "contents: write" in build or "environment:" in build:
    raise SystemExit("unprivileged candidate build gained a secret, write permission, or environment")
if "environment: production-release" not in protected:
    raise SystemExit("protected signer lacks the production-release environment gate")
permissions = protected.split("    steps:\n", 1)[0]
if "contents: read" not in permissions or "actions: read" not in permissions or "contents: write" in permissions:
    raise SystemExit("protected signer permissions are not read-only")
for forbidden in ("gh release", "git push", "contents: write", "checksums.txt.sig", "/releases/", "releases/tags"):
    if forbidden in protected or forbidden in signer:
        raise SystemExit(f"acceptance signer contains a publication capability: {forbidden}")
if "ref: ${{ github.sha }}" not in protected:
    raise SystemExit("protected signer is not pinned to the main workflow commit")
if "Checkout candidate as untrusted build data" in protected or "bash candidate/" in protected:
    raise SystemExit("candidate code is checked out or executed in the protected signer")
if protected.find("verify-acceptance-remote-state.sh") > protected.find("Sign, notarize, and bind"):
    raise SystemExit("candidate ref/tag drift gate is late")
if protected.count("verify-acceptance-remote-state.sh") != 2:
    raise SystemExit("candidate ref/tag must be checked both before secrets and before export")
if "scripts/verify-github-release-posture.sh" not in protected:
    raise SystemExit("protected signer does not fail closed on environment-policy drift")
if protected.find("verify-acceptance-remote-state.sh") > protected.find("RELEASE_POSTURE_TOKEN"):
    raise SystemExit("a protected token is imported before the post-approval candidate drift gate")
if 'MACPROVIDER_PROVIDER_ADMISSION_POLICY="$PROVIDER_ADMISSION_POLICY"' not in build:
    raise SystemExit("candidate package does not receive the exact admission policy input")
if re.search(r'^\s*strings\s+.*\|\s*grep\s+.*-q', build, re.MULTILINE):
    raise SystemExit("candidate binary version checks can fail under pipefail when grep exits early")
for value in (
    'strings "$RUNNER_TEMP/coordinator-linux-amd64" > "$RUNNER_TEMP/coordinator-strings.txt"',
    'strings "$RUNNER_TEMP/gateway-linux-amd64" > "$RUNNER_TEMP/gateway-strings.txt"',
    'grep -Fq "$TAG" "$RUNNER_TEMP/coordinator-strings.txt"',
    'grep -Fq "$TAG" "$RUNNER_TEMP/gateway-strings.txt"',
    'provider_version="$("$payload/macprovider-cli" --version)"',
    '--expected-provider-cli-version "$provider_version"',
    '--expected-malibu-app-version "$malibu_version"',
):
    if value not in build:
        raise SystemExit(f"candidate binary version check is incomplete: {value}")
for value in (
    'package_resolution_args=(archive)',
    'if [ -f Package.resolved ]; then',
    'package_resolution_args+=(-onlyUsePackageVersionsFromResolvedFile)',
    '"${package_resolution_args[@]}"',
):
    if value not in build:
        raise SystemExit(f"candidate Malibu dependency handling is incomplete: {value}")
if re.search(r'^\s*cp Package\.resolved ', build, re.MULTILINE) and 'if [ -f Package.resolved ]; then' not in build:
    raise SystemExit("candidate Malibu build requires a removed optional lockfile")
if re.search(r'^\s*archive\s*\\$', build, re.MULTILINE):
    raise SystemExit("candidate Malibu build can expand an empty array under macOS Bash 3.2")
if "retention-days: 1" not in protected or "actions/upload-artifact@043fb46d" not in protected:
    raise SystemExit("private acceptance artifact is not short-lived and action-pinned")
for secret in (
    "MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM",
    "MACPROVIDER_RELEASE_SIGNING_KEY_PEM",
    "APPLE_DEVELOPER_ID_CERT_P12_BASE64",
    "APPLE_NOTARY_PASSWORD",
):
    if secret not in protected:
        raise SystemExit(f"protected signer secret contract is incomplete: {secret}")
if "--private-key \"$release_private_key\"" not in signer or "--public-key \"$release_public_key\"" not in signer:
    raise SystemExit("inner compatibility manifest is not main-owned and production-key verified")
if (
    "pearl-release.json.sig" not in signer
    or 'pearl_signing_key="$private_key"' not in signer
    or 'pearl_signing_key="$release_private_key"' not in signer
    or 'pearl_verification_key="$derived_public_key"' not in signer
    or 'pearl_verification_key="$release_public_key"' not in signer
):
    raise SystemExit("Pearl metadata does not select the acceptance or production trust anchor explicitly")
if (
    '"$promotion_ready" == true' not in signer
    or "pearl_channel=production" not in signer
    or "release_prerelease=false" not in signer
):
    raise SystemExit("promotion-ready acceptance does not bind stable release provenance")
if '--compatibility-manifest "$output_dir/compatibility-set.json"' not in signer:
    raise SystemExit("acceptance-only Pearl metadata is not bound to the signed compatibility manifest")
for value in (
    'release_discovery="$root/scripts/build-release-discovery-head.py"',
    '"$release_discovery"',
    '--attempt "$run_attempt"',
    '--target-artifact-index "$output_dir/compatibility-artifact-index.json"',
    '--private-key "$release_private_key"',
    '--public-key "$release_public_key"',
    '--output "$output_dir/macprovider-release-discovery.json"',
    '--signature "$output_dir/macprovider-release-discovery.json.sig"',
):
    if value not in signer:
        raise SystemExit(f"acceptance signer release-discovery contract is incomplete: {value}")
if not release_discovery.is_file() or release_discovery.is_symlink():
    raise SystemExit("main-owned release-discovery builder is absent or unsafe")
release_asset_block = signer.split("release_assets=(", 1)[1].split("\n)", 1)[0]
for value in (
    '"$output_dir/macprovider-release-discovery.json"',
    '"$output_dir/macprovider-release-discovery.json.sig"',
):
    if value not in release_asset_block:
        raise SystemExit(f"release-discovery asset is omitted from the signed checksum selector: {value}")
if 'tar -czf "$provider_asset" -C "$cli_work" .' in signer:
    raise SystemExit("acceptance signer can emit an ambiguous provider archive root")
for value in (
    "provider_archive_members=(",
    'tar -czf "$provider_asset" -C "$cli_work" "${provider_archive_members[@]}"',
    'validate-archive --input "$provider_asset" --forbid-links',
):
    if value not in signer:
        raise SystemExit(f"acceptance signer final provider archive validation is incomplete: {value}")
if '"$output_dir/release-assets.txt"' not in signer:
    raise SystemExit("acceptance signer does not export the verifier asset selector")
if signer.find('release_assets+=("$output_dir/release-provenance.json")') > signer.find('"$output_dir/release-assets.txt"'):
    raise SystemExit("acceptance asset selector is emitted before the provenance asset is included")
if signer.find('"$output_dir/release-assets.txt"') > signer.find('build-checksums'):
    raise SystemExit("acceptance asset selector is emitted after signed checksum construction")
if re.search(r'\$cli_work/macprovider-cli["}]?\s+--', signer):
    raise SystemExit("protected signer executes the candidate CLI")
if "codesign --force --deep" in signer:
    raise SystemExit("acceptance signer must preserve the already-signed embedded CLI bytes")
if signer.count('shasum -a 256 "$app/Contents/MacOS/macprovider-cli"') != 2:
    raise SystemExit("acceptance signer must prove embedded CLI bytes before and after outer app signing")
for value in (
    'keychain="acceptance-signing-${run_id}-${run_attempt}-${keychain_nonce}.keychain"',
    'acceptance_keychain_capture_default || die',
    'acceptance_keychain_create_and_select "$keychain" "$keychain_password"',
    'acceptance_keychain_cleanup "$keychain"',
):
    if value not in signer:
        raise SystemExit(f"acceptance signer keychain contract is incomplete: {value}")
if "$signing_tmp/acceptance-signing.keychain-db" in signer:
    raise SystemExit("acceptance signer places its codesigning keychain outside the user keychain directory")
for value in (
    'acceptance_keychain_restore_required=1',
    'security default-keychain -d user -s "$keychain"',
    'security default-keychain -d user -s "$acceptance_previous_default_keychain"',
    'if [[ "$acceptance_keychain_created" == 1 ]]',
    'security delete-keychain "$keychain"',
):
    if value not in keychain_helper:
        raise SystemExit(f"acceptance keychain helper contract is incomplete: {value}")
if keychain_helper.find('acceptance_keychain_restore_required=1') > keychain_helper.find('security default-keychain -d user -s "$keychain"'):
    raise SystemExit("acceptance keychain restore flag is set after default-keychain mutation")
if keychain_helper.find('security default-keychain -d user -s "$acceptance_previous_default_keychain"') > keychain_helper.find('security delete-keychain "$keychain"'):
    raise SystemExit("acceptance signer deletes the active keychain before restoring the prior default")
for value in (
    'SIGNING_DOMAIN = b"macprovider.acceptance-candidate.v1\\n"',
    '"candidate_ref"',
    '"control_commit"',
    '"run_attempt"',
    '"name": "checksums.txt"',
    'KEY_ID = "macprovider-acceptance-p256-v1"',
):
    if value not in metadata:
        raise SystemExit(f"acceptance metadata contract is missing: {value}")
if "gh secret set MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM" not in provisioner:
    raise SystemExit("provisioner does not target the dedicated environment secret")
if "< \"$private_key\"" not in provisioner or "cat \"$private_key\"" in provisioner:
    raise SystemExit("provisioner does not pipe private bytes directly to gh")
if "printf" in "\n".join(line for line in provisioner.splitlines() if "private_key" in line and "printf" in line):
    raise SystemExit("provisioner prints private key material")
if set(schema["required"]) != {
    "candidate_commit", "candidate_ref", "channel", "checksums", "compatibility_set_id",
    "control_commit", "expires_at", "issued_at", "repository", "run_attempt", "run_id",
    "schema_version", "signing", "tag",
}:
    raise SystemExit("acceptance schema fields differ from the canonical metadata contract")

tree = ast.parse(metadata)
if not tree.body:
    raise SystemExit("metadata module did not parse")

lines = workflow.splitlines()
for index, line in enumerate(lines):
    match = re.match(r"^(\s*)run:\s*\|", line)
    if not match:
        continue
    indent = len(match.group(1))
    block = []
    for candidate in lines[index + 1 :]:
        if candidate.strip() and len(candidate) - len(candidate.lstrip()) <= indent:
            break
        block.append(candidate)
    if any("${{" in row for row in block):
        raise SystemExit("GitHub expression is interpolated directly into a shell block")
PY

mkdir -p "$work/bin"
cat > "$work/bin/security" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$SECURITY_LOG"
case "$1" in
  default-keychain)
    if [[ "$*" == "default-keychain -d user" ]]; then
      [[ "$SECURITY_SCENARIO" != query_failure ]] || exit 71
      printf '    "/Users/fixture/Library/Keychains/login.keychain-db"\n'
    fi
    ;;
  create-keychain)
    [[ "$SECURITY_SCENARIO" != create_failure ]] || exit 72
    ;;
esac
SH
chmod 0755 "$work/bin/security"

query_failure_log="$work/query-failure.log"
if PATH="$work/bin:$PATH" SECURITY_LOG="$query_failure_log" SECURITY_SCENARIO=query_failure \
  bash -c 'source "$1"; acceptance_keychain_capture_default' _ "$keychain_helper"; then
  fail "keychain lifecycle accepted an unreadable prior default"
fi
printf '%s\n' 'default-keychain -d user' > "$work/query-failure.expected"
cmp "$work/query-failure.expected" "$query_failure_log"

create_failure_log="$work/create-failure.log"
PATH="$work/bin:$PATH" SECURITY_LOG="$create_failure_log" SECURITY_SCENARIO=create_failure \
  bash -c '
    source "$1"
    acceptance_keychain_capture_default
    if acceptance_keychain_create_and_select collision.keychain fixture; then
      exit 73
    fi
    acceptance_keychain_cleanup collision.keychain
  ' _ "$keychain_helper"
printf '%s\n' \
  'default-keychain -d user' \
  'create-keychain -p fixture collision.keychain' \
  > "$work/create-failure.expected"
cmp "$work/create-failure.expected" "$create_failure_log"

downstream_failure_log="$work/downstream-failure.log"
PATH="$work/bin:$PATH" SECURITY_LOG="$downstream_failure_log" SECURITY_SCENARIO=downstream_failure \
  bash -c '
    source "$1"
    acceptance_keychain_capture_default
    acceptance_keychain_create_and_select owned.keychain fixture
    acceptance_keychain_cleanup owned.keychain
  ' _ "$keychain_helper"
printf '%s\n' \
  'default-keychain -d user' \
  'create-keychain -p fixture owned.keychain' \
  'default-keychain -d user -s owned.keychain' \
  'unlock-keychain -p fixture owned.keychain' \
  'set-keychain-settings -lut 3600 owned.keychain' \
  'default-keychain -d user -s /Users/fixture/Library/Keychains/login.keychain-db' \
  'delete-keychain owned.keychain' \
  > "$work/downstream-failure.expected"
cmp "$work/downstream-failure.expected" "$downstream_failure_log"

# macOS runners still invoke Bash 3.2, where expanding an initialized empty
# array under `set -u` fails as an unbound variable. Keep the workflow's array
# non-empty in both dependency-free and resolved-package modes.
bash -u -c 'args=(archive); printf "%s\n" "${args[@]}"' > "$work/malibu-args-without-lockfile"
grep -Fxq archive "$work/malibu-args-without-lockfile"
bash -u -c 'args=(archive); args+=(-onlyUsePackageVersionsFromResolvedFile); printf "%s\n" "${args[@]}"' \
  > "$work/malibu-args-with-lockfile"
printf '%s\n' archive -onlyUsePackageVersionsFromResolvedFile > "$work/expected-malibu-args"
cmp -s "$work/expected-malibu-args" "$work/malibu-args-with-lockfile"

mkdir "$work/assets"
tag=v1.8.33
candidate_commit=1111111111111111111111111111111111111111
control_commit=2222222222222222222222222222222222222222
candidate_ref=refs/heads/fix/585-provider-lifecycle-option2
for name in \
  "phase3-binary-m4-${tag}.tar.gz" \
  Malibu.app.tar.gz \
  release-toolchain.json \
  coordinator-linux-amd64 \
  coordinator-cli-linux-amd64 \
  gateway-linux-amd64; do
  printf 'fixture:%s\n' "$name" > "$work/assets/$name"
done
unsigned_arguments=(
  --asset "phase3-binary-m4-${tag}.tar.gz=$work/assets/phase3-binary-m4-${tag}.tar.gz"
  --asset "Malibu.app.tar.gz=$work/assets/Malibu.app.tar.gz"
  --asset "release-toolchain.json=$work/assets/release-toolchain.json"
  --asset "coordinator-linux-amd64=$work/assets/coordinator-linux-amd64"
  --asset "coordinator-cli-linux-amd64=$work/assets/coordinator-cli-linux-amd64"
  --asset "gateway-linux-amd64=$work/assets/gateway-linux-amd64"
)
python3 "$metadata" build-unsigned \
  --repository Augustas11/macprovider \
  --tag "$tag" \
  --candidate-ref "$candidate_ref" \
  --candidate-commit "$candidate_commit" \
  --control-commit "$control_commit" \
  --provider-admission-policy strict_post_migration \
  --output "$work/unsigned.json" \
  "${unsigned_arguments[@]}"
python3 "$metadata" verify-unsigned \
  --repository Augustas11/macprovider \
  --tag "$tag" \
  --candidate-ref "$candidate_ref" \
  --candidate-commit "$candidate_commit" \
  --control-commit "$control_commit" \
  --provider-admission-policy strict_post_migration \
  --input "$work/unsigned.json" \
  "${unsigned_arguments[@]}"
printf 'tamper\n' >> "$work/assets/gateway-linux-amd64"
if python3 "$metadata" verify-unsigned \
  --repository Augustas11/macprovider \
  --tag "$tag" \
  --candidate-ref "$candidate_ref" \
  --candidate-commit "$candidate_commit" \
  --control-commit "$control_commit" \
  --provider-admission-policy strict_post_migration \
  --input "$work/unsigned.json" \
  "${unsigned_arguments[@]}" >"$work/tamper.out" 2>&1; then
  echo "unsigned manifest accepted tampered candidate bytes" >&2
  exit 1
fi
grep -q 'digest mismatch for gateway-linux-amd64' "$work/tamper.out"

mkdir -p "$work/provider/catalog-release" "$work/provider/compatibility-set-local"
for name in THIRD-PARTY-NOTICES.txt compatibility-set.json macprovider-cli mlx.metallib; do
  printf 'fixture:%s\n' "$name" > "$work/provider/$name"
done
chmod 755 "$work/provider/macprovider-cli"
for name in release.json trusted-keys.json tier2-catalog.json autotune-candidates.json autotune-candidates.json.sig demand-rank.json demand-rank.json.sig rate-card.json rate-card.json.sig; do
  printf 'fixture:%s\n' "$name" > "$work/provider/catalog-release/$name"
done
for name in install.sh provider-launch-agent.plist.template updater-rollback.json watchdog-launch-agent.plist.template watchdog.sh; do
  printf 'fixture:%s\n' "$name" > "$work/provider/compatibility-set-local/$name"
done
python3 "$metadata" validate-provider-payload --directory "$work/provider"
printf 'unexpected\n' > "$work/provider/unreviewed-hook.sh"
if python3 "$metadata" validate-provider-payload --directory "$work/provider" >"$work/extra-provider.out" 2>&1; then
  echo "provider payload validator accepted an unexpected executable" >&2
  exit 1
fi
grep -q 'unexpected top-level members' "$work/extra-provider.out"

# Catalog release manifests have their own deterministic pretty-JSON contract.
# The acceptance signer must preserve and parse those exact bytes rather than
# imposing the compact acceptance-envelope format on them.
mkdir "$work/pearl-catalog"
python3 "$root/scripts/catalog-release.py" verify
cp "$root/phase3-binary/catalog/autotune/release.json" \
  "$root/phase3-binary/catalog/autotune/trusted-keys.json" \
  "$root/phase3-binary/catalog/autotune/tier2-catalog.json" \
  "$root/phase3-binary/dist/static/autotune-candidates.json" \
  "$root/phase3-binary/dist/static/autotune-candidates.json.sig" \
  "$root/phase3-binary/dist/static/demand-rank.json" \
  "$root/phase3-binary/dist/static/demand-rank.json.sig" \
  "$root/phase3-binary/dist/static/rate-card.json" \
  "$root/phase3-binary/dist/static/rate-card.json.sig" \
  "$work/pearl-catalog/"
cat > "$work/pearl-compatibility.json.tmp" <<EOF
{"schema_version":"macprovider.compatibility-set-envelope.v1","signatures":[{"algorithm":"fixture"}],"signed":{"compatibility_set_id":"Augustas11/macprovider:${tag}@${candidate_commit}","components":{"provider_cli":{"version":"1.8.31"}},"release":{"commit":"${candidate_commit}","repository":"Augustas11/macprovider","tag":"${tag}","version":"1.8.33"}}}
EOF
python3 - "$work/pearl-compatibility.json.tmp" "$work/pearl-compatibility.json" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text())
pathlib.Path(sys.argv[2]).write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
PY
python3 "$metadata" build-pearl \
  --repository Augustas11/macprovider \
  --tag "$tag" \
  --commit "$candidate_commit" \
  --compatibility-manifest "$work/pearl-compatibility.json" \
  --provider-admission-policy strict_post_migration \
  --catalog-directory "$work/pearl-catalog" \
  --coordinator "$work/assets/coordinator-linux-amd64" \
  --coordinator-cli "$work/assets/coordinator-cli-linux-amd64" \
  --gateway "$work/assets/gateway-linux-amd64" \
  --output "$work/pearl-release.json"
python3 - "$work/pearl-catalog/release.json" "$work/pearl-release.json" <<'PY'
import json
import pathlib
import sys

catalog = json.loads(pathlib.Path(sys.argv[1]).read_text())
pearl = json.loads(pathlib.Path(sys.argv[2]).read_text())
if pearl["catalog"]["release_id"] != catalog["release_id"]:
    raise SystemExit("Pearl metadata did not preserve the verified catalog release ID")
if pearl.get("channel") != "private_acceptance":
    raise SystemExit("Pearl metadata did not declare the private acceptance channel")
if pearl["provider_advertised_version"] != "1.8.31":
    raise SystemExit("Pearl metadata did not use the signed provider CLI component version")
PY
python3 "$metadata" build-pearl \
  --repository Augustas11/macprovider \
  --tag "$tag" \
  --commit "$candidate_commit" \
  --compatibility-manifest "$work/pearl-compatibility.json" \
  --provider-admission-policy strict_post_migration \
  --channel production \
  --catalog-directory "$work/pearl-catalog" \
  --coordinator "$work/assets/coordinator-linux-amd64" \
  --coordinator-cli "$work/assets/coordinator-cli-linux-amd64" \
  --gateway "$work/assets/gateway-linux-amd64" \
  --output "$work/pearl-production.json"
python3 - "$work/pearl-production.json" <<'PY'
import json
import pathlib
import sys

pearl = json.loads(pathlib.Path(sys.argv[1]).read_text())
if pearl.get("channel") != "production":
    raise SystemExit("promotion-ready Pearl metadata did not declare the production channel")
PY
python3 "$metadata" build-pearl \
  --repository Augustas11/macprovider \
  --tag "$tag" \
  --commit "$candidate_commit" \
  --provider-admission-policy strict_post_migration \
  --runtime-only \
  --coordinator "$work/assets/coordinator-linux-amd64" \
  --coordinator-cli "$work/assets/coordinator-cli-linux-amd64" \
  --gateway "$work/assets/gateway-linux-amd64" \
  --output "$work/pearl-runtime-only.json"
python3 - "$work/pearl-runtime-only.json" "$tag" <<'PY'
import json
import pathlib
import sys

pearl = json.loads(pathlib.Path(sys.argv[1]).read_text())
tag = sys.argv[2]
if pearl.get("release_lane") != "pearl_runtime":
    raise SystemExit("runtime-only Pearl metadata did not declare the runtime lane")
if pearl.get("catalog") is not None:
    raise SystemExit("runtime-only Pearl metadata bound catalog state")
if "provider_advertised_version" in pearl:
    raise SystemExit("runtime-only Pearl metadata carried provider version authority")
PY
if python3 "$metadata" build-pearl \
  --repository Augustas11/macprovider \
  --tag "$tag" \
  --commit "$candidate_commit" \
  --provider-admission-policy strict_post_migration \
  --provider-advertised-version 1.8.31 \
  --runtime-only \
  --coordinator "$work/assets/coordinator-linux-amd64" \
  --coordinator-cli "$work/assets/coordinator-cli-linux-amd64" \
  --gateway "$work/assets/gateway-linux-amd64" \
  --output "$work/pearl-runtime-only-with-provider-version.json" >"$work/runtime-only-provider-version.out" 2>&1; then
  echo "Pearl metadata builder accepted runtime-only provider version binding" >&2
  exit 1
fi
grep -q -- '--runtime-only cannot bind --provider-advertised-version' "$work/runtime-only-provider-version.out"
if python3 "$metadata" build-pearl \
  --repository Augustas11/macprovider \
  --tag "$tag" \
  --commit "$candidate_commit" \
  --provider-admission-policy bridge_required \
  --runtime-only \
  --coordinator "$work/assets/coordinator-linux-amd64" \
  --coordinator-cli "$work/assets/coordinator-cli-linux-amd64" \
  --gateway "$work/assets/gateway-linux-amd64" \
  --output "$work/pearl-runtime-only-with-bridge.json" >"$work/runtime-only-bridge.out" 2>&1; then
  echo "Pearl metadata builder accepted runtime-only provider bridge binding" >&2
  exit 1
fi
grep -q -- '--runtime-only cannot bind provider admission bridge policy' "$work/runtime-only-bridge.out"
if python3 "$metadata" build-pearl \
  --repository Augustas11/macprovider \
  --tag "$tag" \
  --commit "$candidate_commit" \
  --compatibility-manifest "$work/pearl-compatibility.json" \
  --provider-admission-policy bridge_required \
  --runtime-only \
  --coordinator "$work/assets/coordinator-linux-amd64" \
  --coordinator-cli "$work/assets/coordinator-cli-linux-amd64" \
  --gateway "$work/assets/gateway-linux-amd64" \
  --output "$work/pearl-runtime-only-with-compatibility.json" >"$work/runtime-only-compatibility.out" 2>&1; then
  echo "Pearl metadata builder accepted runtime-only compatibility binding" >&2
  exit 1
fi
grep -q -- '--runtime-only cannot bind --compatibility-manifest' "$work/runtime-only-compatibility.out"
python3 - "$work/pearl-catalog/release.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(json.dumps(json.loads(path.read_text()), sort_keys=True, separators=(",", ":")) + "\n")
PY
if python3 "$metadata" build-pearl \
  --repository Augustas11/macprovider \
  --tag "$tag" \
  --commit "$candidate_commit" \
  --compatibility-manifest "$work/pearl-compatibility.json" \
  --provider-admission-policy strict_post_migration \
  --catalog-directory "$work/pearl-catalog" \
  --coordinator "$work/assets/coordinator-linux-amd64" \
  --coordinator-cli "$work/assets/coordinator-cli-linux-amd64" \
  --gateway "$work/assets/gateway-linux-amd64" \
  --output "$work/noncanonical-pearl-release.json" >"$work/noncanonical-catalog.out" 2>&1; then
  echo "Pearl metadata builder accepted a noncanonical catalog release" >&2
  exit 1
fi
grep -q 'catalog release: must be canonical' "$work/noncanonical-catalog.out"

cat > "$work/compatibility.json.tmp" <<EOF
{"schema_version":"macprovider.compatibility-set-envelope.v1","signatures":[],"signed":{"compatibility_set_id":"Augustas11/macprovider:${tag}@${candidate_commit}","release":{"commit":"${candidate_commit}","repository":"Augustas11/macprovider","tag":"${tag}","version":"1.8.33"}}}
EOF
python3 - "$work/compatibility.json.tmp" "$work/compatibility.json" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text())
pathlib.Path(sys.argv[2]).write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
PY
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  artifact\n' > "$work/checksums.txt"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$work/private.pem" >/dev/null 2>&1
openssl pkey -in "$work/private.pem" -pubout -out "$work/public.pem" >/dev/null 2>&1
python3 "$metadata" sign \
  --repository Augustas11/macprovider \
  --tag "$tag" \
  --candidate-ref "$candidate_ref" \
  --candidate-commit "$candidate_commit" \
  --control-commit "$control_commit" \
  --run-id 987654321 \
  --run-attempt 2 \
  --compatibility-manifest "$work/compatibility.json" \
  --checksums "$work/checksums.txt" \
  --issued-at 2026-07-14T12:00:00Z \
  --expires-at 2026-07-15T12:00:00Z \
  --private-key "$work/private.pem" \
  --output "$work/acceptance-candidate.json" \
  --signature "$work/acceptance-candidate.json.sig"
python3 "$metadata" verify \
  --input "$work/acceptance-candidate.json" \
  --signature "$work/acceptance-candidate.json.sig" \
  --public-key "$work/public.pem" \
  --checksums "$work/checksums.txt" \
  --repository Augustas11/macprovider \
  --tag "$tag" \
  --candidate-ref "$candidate_ref" \
  --candidate-commit "$candidate_commit" \
  --control-commit "$control_commit" \
  --run-id 987654321 \
  --run-attempt 2 \
  --now 2026-07-14T12:00:00Z
if python3 "$metadata" verify \
  --input "$work/acceptance-candidate.json" \
  --signature "$work/acceptance-candidate.json.sig" \
  --public-key "$work/public.pem" \
  --checksums "$work/checksums.txt" \
  --now 2026-07-15T12:00:01Z >"$work/expired.out" 2>&1; then
  echo "expired acceptance envelope was accepted" >&2
  exit 1
fi
grep -q 'candidate has expired' "$work/expired.out"

base64 -d < "$work/acceptance-candidate.json.sig" > "$work/raw-signature.der"
if python3 "$metadata" verify \
  --input "$work/acceptance-candidate.json" \
  --signature "$work/raw-signature.der" \
  --public-key "$work/public.pem" \
  --checksums "$work/checksums.txt" \
  --now 2026-07-14T12:00:00Z >"$work/raw-signature.out" 2>&1; then
  echo "metadata verifier accepted a non-base64 signature file" >&2
  exit 1
fi
grep -q 'invalid base64' "$work/raw-signature.out"

python3 - "$work/acceptance-candidate.json" "$work/noncanonical-acceptance.json" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text())
pathlib.Path(sys.argv[2]).write_text(json.dumps(value, indent=2) + "\n")
PY
if python3 "$metadata" verify \
  --input "$work/noncanonical-acceptance.json" \
  --signature "$work/acceptance-candidate.json.sig" \
  --public-key "$work/public.pem" \
  --checksums "$work/checksums.txt" \
  --now 2026-07-14T12:00:00Z >"$work/noncanonical.out" 2>&1; then
  echo "metadata verifier accepted noncanonical JSON" >&2
  exit 1
fi
grep -q 'canonical sorted compact JSON' "$work/noncanonical.out"

base64 -d < "$work/acceptance-candidate.json.sig" > "$work/signature.der"
{
  printf 'macprovider.acceptance-candidate.v1\n'
  cat "$work/acceptance-candidate.json"
} > "$work/domain-message"
openssl dgst -sha256 -verify "$work/public.pem" -signature "$work/signature.der" "$work/domain-message" >/dev/null
if openssl dgst -sha256 -verify "$work/public.pem" -signature "$work/signature.der" \
  "$work/acceptance-candidate.json" >/dev/null 2>&1; then
  echo "acceptance signature verified without the domain prefix" >&2
  exit 1
fi

mkdir "$work/source" "$work/bare.git"
git -C "$work/bare.git" init --bare -q
git -C "$work/source" init -q
git -C "$work/source" config user.name acceptance-test
git -C "$work/source" config user.email acceptance-test@example.invalid
printf 'main\n' > "$work/source/value"
git -C "$work/source" add value
git -C "$work/source" commit -qm main
git -C "$work/source" branch -M main
git -C "$work/source" remote add origin "file://$work/bare.git"
git -C "$work/source" push -q -u origin main
printf 'candidate\n' >> "$work/source/value"
git -C "$work/source" checkout -qb candidate
git -C "$work/source" add value
git -C "$work/source" commit -qm candidate
candidate_sha="$(git -C "$work/source" rev-parse HEAD)"
git -C "$work/source" push -q -u origin candidate
git clone -q "file://$work/bare.git" "$work/candidate"
git -C "$work/candidate" checkout -q "$candidate_sha"
git clone -q "file://$work/bare.git" "$work/control"
git -C "$work/control" checkout -q main
control_sha="$(git -C "$work/control" rev-parse HEAD)"
GITHUB_EVENT_NAME=workflow_dispatch \
GITHUB_REF=refs/heads/main \
GITHUB_SHA="$control_sha" \
GITHUB_REPOSITORY=Augustas11/macprovider \
  bash "$source_guard" "$work/control" "$work/candidate" "file://$work/bare.git" \
    refs/heads/candidate "$candidate_sha" v9.9.9
test "$(git -C "$work/candidate" rev-parse refs/remotes/origin/main)" = "$control_sha"

(
  cd "$work/control"
  GITHUB_EVENT_NAME=workflow_dispatch \
  GITHUB_REF=refs/heads/main \
  GITHUB_SHA="$control_sha" \
    bash "$remote_guard" refs/heads/candidate "$candidate_sha" v9.9.9
)
git -C "$work/source" tag v9.9.9 "$candidate_sha"
git -C "$work/source" push -q origin v9.9.9
if GITHUB_EVENT_NAME=workflow_dispatch \
  GITHUB_REF=refs/heads/main \
  GITHUB_SHA="$control_sha" \
  GITHUB_REPOSITORY=Augustas11/macprovider \
    bash "$source_guard" "$work/control" "$work/candidate" "file://$work/bare.git" \
      refs/heads/candidate "$candidate_sha" v9.9.9 >"$work/existing-tag.out" 2>&1; then
  echo "source guard accepted an existing production tag" >&2
  exit 1
fi
grep -q 'candidate tag already exists' "$work/existing-tag.out"
git -C "$work/source" tag -d v9.9.9 >/dev/null
git -C "$work/source" push -q origin :refs/tags/v9.9.9

git -C "$work/source" checkout -q main
printf 'drift\n' >> "$work/source/value"
git -C "$work/source" add value
git -C "$work/source" commit -qm drift-main
git -C "$work/source" push -q origin main
if (
  cd "$work/control"
  GITHUB_EVENT_NAME=workflow_dispatch \
  GITHUB_REF=refs/heads/main \
  GITHUB_SHA="$control_sha" \
    bash "$remote_guard" refs/heads/candidate "$candidate_sha" v9.9.9
) >"$work/main-drift.out" 2>&1; then
  echo "protected remote guard accepted a drifted main control branch" >&2
  exit 1
fi
grep -q 'main control branch drifted after dispatch' "$work/main-drift.out"

bash -n "$signer" "$source_guard" "$remote_guard" "$provisioner"
printf '[test-acceptance-candidate-security] ok: read-only signer, exact source, expiry, domain separation, and no publication\n'
