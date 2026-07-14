#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/acceptance-candidate-metadata.XXXXXX")"
trap 'rm -rf "$work"' EXIT

python3 - "$repo_root" "$work/committed-acceptance-public.pem" <<'PY'
import hashlib
import pathlib
import re
import sys
import textwrap

root = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
canonical = (root / "security/acceptance-candidate-signing-public.pem").read_bytes()
if hashlib.sha256(canonical).hexdigest() != "849e9c9bc53db1fb8e28d3b46ab431089b12cb50b398c5317ced682d39bdbd38":
    raise SystemExit("committed acceptance public key digest drifted")

installer = (root / "phase3-binary/dist/install.sh").read_text(encoding="utf-8")
swift = (root / "phase3-binary/Sources/macprovider-cli/AcceptanceCandidateMetadata.swift").read_text(encoding="utf-8")

def function_pem(name):
    function = re.search(rf"{name}\(\) \{{(.+?)\n\}}", installer, flags=re.DOTALL)
    blocks = re.findall(
        r"-----BEGIN PUBLIC KEY-----\n.+?\n-----END PUBLIC KEY-----",
        function.group(1) if function else "",
        flags=re.DOTALL,
    )
    if len(blocks) != 1:
        raise SystemExit(f"{name} must embed exactly one public key")
    return (blocks[0] + "\n").encode("ascii")

swift_match = re.search(
    r'static let signingPublicKeyPEM = """\n(?P<body>.*?)\n    """',
    swift,
    flags=re.DOTALL,
)
if swift_match is None:
    raise SystemExit("Swift acceptance public key literal is missing")
swift_pem = (textwrap.dedent(swift_match.group("body")) + "\n").encode("ascii")
installer_acceptance = function_pem("write_acceptance_public_key")
installer_production = function_pem("write_checksum_public_key")
if canonical != installer_acceptance or canonical != swift_pem:
    raise SystemExit("acceptance public key consumers drifted from the committed key")
if canonical == installer_production:
    raise SystemExit("acceptance and production signing keys must remain distinct")
output.write_bytes(canonical)
PY
openssl pkey -pubin -in "$work/committed-acceptance-public.pem" -noout >/dev/null

mirror="$work/repo"
mkdir -p "$mirror/scripts" "$mirror/phase3-binary/dist" "$mirror/security" "$work/assets"
cp "$repo_root/scripts/verify-release-checksums.sh" "$mirror/scripts/"
metadata_helper="${MACPROVIDER_ACCEPTANCE_METADATA_HELPER:-$repo_root/scripts/acceptance-candidate-metadata.py}"
cp "$metadata_helper" "$mirror/scripts/acceptance-candidate-metadata.py"

openssl ecparam -name prime256v1 -genkey -noout -out "$work/acceptance-private.pem"
openssl ec -in "$work/acceptance-private.pem" -pubout \
  -out "$mirror/security/acceptance-candidate-signing-public.pem" >/dev/null 2>&1
openssl ecparam -name prime256v1 -genkey -noout -out "$work/production-private.pem"
openssl ec -in "$work/production-private.pem" -pubout -out "$work/production-public.pem" >/dev/null 2>&1
{
  printf 'write_checksum_public_key() {\n'
  printf "  cat <<'EOF'\n"
  sed 's/^/  /' "$work/production-public.pem"
  printf 'EOF\n}\n'
} > "$mirror/phase3-binary/dist/install.sh"

repository="Augustas11/macprovider"
tag="v1.8.35"
candidate_commit="$(printf 'a%.0s' {1..40})"
control_commit="$(printf 'b%.0s' {1..40})"
run_id="123456789"
run_attempt="2"
artifact_index="$work/assets/compatibility-artifact-index.json"
payload="$work/assets/macprovider-cli-${tag}-darwin-arm64.tar.gz"
provenance="$work/assets/release-provenance.json"
checksums="$work/assets/checksums.txt"
printf 'candidate payload\n' > "$payload"

python3 - "$artifact_index" "$provenance" "$checksums" "$payload" \
  "$repository" "$tag" "$candidate_commit" <<'PY'
import hashlib
import json
import pathlib
import sys

index_path, provenance_path, checksums_path, payload_path, repository, tag, commit = sys.argv[1:]
index = {
    "artifacts": {},
    "commit": commit,
    "compatibility_manifest_sha256": "c" * 64,
    "compatibility_set_id": f"{repository}:{tag}@{commit}",
    "repository": repository,
    "schema_version": "macprovider.compatibility-artifact-index.v1",
    "tag": tag,
}
canonical = lambda value: (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
pathlib.Path(index_path).write_bytes(canonical(index))
assets = {
    pathlib.Path(index_path).name: hashlib.sha256(pathlib.Path(index_path).read_bytes()).hexdigest(),
    pathlib.Path(payload_path).name: hashlib.sha256(pathlib.Path(payload_path).read_bytes()).hexdigest(),
}
provenance = {
    "assets": assets,
    "commit": commit,
    "repository": repository,
    "schema_version": 1,
    "tag": tag,
}
pathlib.Path(provenance_path).write_bytes(canonical(provenance))
rows = dict(assets)
rows[pathlib.Path(provenance_path).name] = hashlib.sha256(pathlib.Path(provenance_path).read_bytes()).hexdigest()
pathlib.Path(checksums_path).write_text(
    "".join(f"{digest}  {name}\n" for name, digest in sorted(rows.items())),
    encoding="ascii",
)
PY

metadata="$work/assets/acceptance-candidate.json"
signature_payload="$work/acceptance-signature-payload"
signature="$work/assets/acceptance-candidate.json.sig"
signature_der="$work/acceptance-candidate.der"
mkdir -p "$work/wrong-domain" "$work/expired"
expired="$work/expired/acceptance-candidate.json"
python3 - "$metadata" "$expired" "$checksums" "$repository" "$tag" \
  "$candidate_commit" "$control_commit" "$run_id" "$run_attempt" <<'PY'
import datetime as dt
import hashlib
import json
import pathlib
import sys

metadata_path, expired_path, checksums_path, repository, tag, candidate_commit, control_commit, run_id, run_attempt = sys.argv[1:]

def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()

def metadata(issued_at, expires_at):
    return {
        "candidate_commit": candidate_commit,
        "candidate_ref": "refs/heads/fix/585-provider-lifecycle-option2",
        "channel": "acceptance",
        "checksums": {
            "name": "checksums.txt",
            "sha256": hashlib.sha256(pathlib.Path(checksums_path).read_bytes()).hexdigest(),
        },
        "compatibility_set_id": f"{repository}:{tag}@{candidate_commit}",
        "control_commit": control_commit,
        "expires_at": expires_at,
        "issued_at": issued_at,
        "repository": repository,
        "run_id": run_id,
        "run_attempt": int(run_attempt),
        "schema_version": "macprovider.acceptance-candidate.v1",
        "signing": {
            "algorithm": "ecdsa-p256-sha256",
            "key_id": "macprovider-acceptance-p256-v1",
        },
        "tag": tag,
    }

now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
format_timestamp = lambda value: value.strftime("%Y-%m-%dT%H:%M:%SZ")
pathlib.Path(metadata_path).write_bytes(canonical(metadata(
    format_timestamp(now),
    format_timestamp(now + dt.timedelta(minutes=10)),
)))
pathlib.Path(expired_path).write_bytes(canonical(metadata(
    "2020-01-01T00:00:00Z",
    "2020-01-01T00:05:00Z",
)))
PY
{
  printf 'macprovider.acceptance-candidate.v1\n'
  cat "$metadata"
} > "$signature_payload"
openssl dgst -sha256 -sign "$work/acceptance-private.pem" \
  -out "$signature_der" "$signature_payload"
python3 - "$signature_der" "$signature" <<'PY'
import base64, pathlib, sys
pathlib.Path(sys.argv[2]).write_bytes(base64.b64encode(pathlib.Path(sys.argv[1]).read_bytes()) + b"\n")
PY

assets=("$artifact_index" "$payload" "$provenance")
bash "$mirror/scripts/verify-release-checksums.sh" \
  --acceptance-candidate "$metadata" "$run_id" "$run_attempt" "$control_commit" \
  "$checksums" "$signature" "$provenance" "$repository" "$tag" "$candidate_commit" \
  "${assets[@]}" >/dev/null

cp "$signature" "$work/canonical-acceptance-signature"
printf '\n' >> "$signature"
if bash "$mirror/scripts/verify-release-checksums.sh" \
  --acceptance-candidate "$metadata" "$run_id" "$run_attempt" "$control_commit" \
  "$checksums" "$signature" "$provenance" "$repository" "$tag" "$candidate_commit" \
  "${assets[@]}" >/dev/null 2>&1; then
  printf 'acceptance verifier accepted a noncanonical signature encoding\n' >&2
  exit 1
fi
mv "$work/canonical-acceptance-signature" "$signature"

if bash "$mirror/scripts/verify-release-checksums.sh" \
  "$checksums" "$signature" "$provenance" "$repository" "$tag" "$candidate_commit" \
  "${assets[@]}" >/dev/null 2>&1; then
  printf 'production verifier accepted an acceptance signature\n' >&2
  exit 1
fi

if bash "$mirror/scripts/verify-release-checksums.sh" \
  --acceptance-candidate "$metadata" 987654321 "$run_attempt" "$control_commit" \
  "$checksums" "$signature" "$provenance" "$repository" "$tag" "$candidate_commit" \
  "${assets[@]}" >/dev/null 2>&1; then
  printf 'acceptance verifier accepted replay under a different run id\n' >&2
  exit 1
fi

wrong_domain_payload="$work/wrong-domain-payload"
wrong_domain_signature="$work/wrong-domain/acceptance-candidate.json.sig"
wrong_domain_der="$work/wrong-domain.der"
{
  printf 'macprovider.production-release.v1\n'
  cat "$metadata"
} > "$wrong_domain_payload"
openssl dgst -sha256 -sign "$work/acceptance-private.pem" \
  -out "$wrong_domain_der" "$wrong_domain_payload"
python3 - "$wrong_domain_der" "$wrong_domain_signature" <<'PY'
import base64, pathlib, sys
pathlib.Path(sys.argv[2]).write_bytes(base64.b64encode(pathlib.Path(sys.argv[1]).read_bytes()) + b"\n")
PY
if bash "$mirror/scripts/verify-release-checksums.sh" \
  --acceptance-candidate "$metadata" "$run_id" "$run_attempt" "$control_commit" \
  "$checksums" "$wrong_domain_signature" "$provenance" "$repository" "$tag" "$candidate_commit" \
  "${assets[@]}" >/dev/null 2>&1; then
  printf 'acceptance verifier accepted a signature from the wrong cryptographic domain\n' >&2
  exit 1
fi

expired_payload="$work/expired-payload"
expired_signature="$work/expired/acceptance-candidate.json.sig"
expired_der="$work/expired.der"
{
  printf 'macprovider.acceptance-candidate.v1\n'
  cat "$expired"
} > "$expired_payload"
openssl dgst -sha256 -sign "$work/acceptance-private.pem" \
  -out "$expired_der" "$expired_payload"
python3 - "$expired_der" "$expired_signature" <<'PY'
import base64, pathlib, sys
pathlib.Path(sys.argv[2]).write_bytes(base64.b64encode(pathlib.Path(sys.argv[1]).read_bytes()) + b"\n")
PY
if bash "$mirror/scripts/verify-release-checksums.sh" \
  --acceptance-candidate "$expired" "$run_id" "$run_attempt" "$control_commit" \
  "$checksums" "$expired_signature" "$provenance" "$repository" "$tag" "$candidate_commit" \
  "${assets[@]}" >/dev/null 2>&1; then
  printf 'acceptance verifier accepted expired metadata\n' >&2
  exit 1
fi

printf '[acceptance-candidate-metadata-test] passed\n'
