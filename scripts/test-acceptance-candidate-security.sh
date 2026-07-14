#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
workflow="$root/.github/workflows/acceptance-candidate.yml"
metadata="$root/scripts/acceptance-candidate-metadata.py"
signer="$root/scripts/sign-acceptance-candidate.sh"
source_guard="$root/scripts/verify-acceptance-candidate-source.sh"
remote_guard="$root/scripts/verify-acceptance-remote-state.sh"
provisioner="$root/scripts/provision-acceptance-signing-key.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/acceptance-security.XXXXXX")"
trap 'rm -rf "$work"' EXIT

python3 - "$workflow" "$metadata" "$signer" "$provisioner" "$root/schemas/acceptance-candidate-v1.schema.json" <<'PY'
import ast
import pathlib
import re
import sys

workflow = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
metadata = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
signer = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
provisioner = pathlib.Path(sys.argv[4]).read_text(encoding="utf-8")
schema = __import__("json").loads(pathlib.Path(sys.argv[5]).read_text(encoding="utf-8"))

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
):
    if value not in build:
        raise SystemExit(f"candidate binary version check is incomplete: {value}")
if "retention-days: 1" not in protected or "actions/upload-artifact@ea165f8d" not in protected:
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
if "pearl-release.json.sig" not in signer or "-sign \"$private_key\"" not in signer:
    raise SystemExit("acceptance-only Pearl metadata is not separately signed")
if re.search(r'\$cli_work/macprovider-cli["}]?\s+--', signer):
    raise SystemExit("protected signer executes the candidate CLI")
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
for name in release.json trusted-keys.json autotune-candidates.json autotune-candidates.json.sig demand-rank.json demand-rank.json.sig; do
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
GITHUB_EVENT_NAME=workflow_dispatch \
GITHUB_REF=refs/heads/main \
GITHUB_SHA="$(git -C "$root" rev-parse HEAD)" \
GITHUB_REPOSITORY=Augustas11/macprovider \
  bash "$source_guard" "$root" "$work/candidate" "file://$work/bare.git" \
    refs/heads/candidate "$candidate_sha" v9.9.9

git clone -q "file://$work/bare.git" "$work/control"
git -C "$work/control" checkout -q main
control_sha="$(git -C "$work/control" rev-parse HEAD)"
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
  GITHUB_SHA="$(git -C "$root" rev-parse HEAD)" \
  GITHUB_REPOSITORY=Augustas11/macprovider \
    bash "$source_guard" "$root" "$work/candidate" "file://$work/bare.git" \
      refs/heads/candidate "$candidate_sha" v9.9.9 >"$work/existing-tag.out" 2>&1; then
  echo "source guard accepted an existing production tag" >&2
  exit 1
fi
grep -q 'candidate tag already exists' "$work/existing-tag.out"

bash -n "$signer" "$source_guard" "$remote_guard" "$provisioner"
printf '[test-acceptance-candidate-security] ok: read-only signer, exact source, expiry, domain separation, and no publication\n'
