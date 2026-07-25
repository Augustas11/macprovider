#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/acceptance-candidate-metadata.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() {
  printf '[acceptance-candidate-metadata-test] ERROR: %s\n' "$*" >&2
  exit 1
}

canonical_public_key="$repo_root/security/acceptance-candidate-signing-public.pem"
python3 - "$canonical_public_key" <<'PY'
import hashlib
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if path.is_symlink() or not path.is_file():
    raise SystemExit("committed acceptance public key is not a regular file")
if hashlib.sha256(path.read_bytes()).hexdigest() != "849e9c9bc53db1fb8e28d3b46ab431089b12cb50b398c5317ced682d39bdbd38":
    raise SystemExit("committed acceptance public key digest drifted")
PY
openssl pkey -pubin -in "$canonical_public_key" -noout >/dev/null

# Candidate-only consumers must embed the same reviewed acceptance key while
# remaining distinct from the production checksum key.
python3 - "$repo_root" "$canonical_public_key" <<'PY'
import pathlib
import re
import sys
import textwrap

root = pathlib.Path(sys.argv[1])
canonical = pathlib.Path(sys.argv[2]).read_bytes()
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
if canonical != function_pem("write_acceptance_public_key") or canonical != swift_pem:
    raise SystemExit("acceptance public key consumers drifted from the committed key")
if canonical == function_pem("write_checksum_public_key"):
    raise SystemExit("acceptance and production signing keys must remain distinct")
PY

# Exercise the immutable verifier path with an ephemeral test key by copying
# the reviewed scripts into an isolated mirror. Production has no key override.
mirror="$work/repo"
mkdir -p "$mirror/scripts" "$mirror/phase3-binary/dist" "$mirror/security" "$work/assets"
cp "$repo_root/scripts/verify-release-checksums.sh" "$mirror/scripts/"
cp "$repo_root/scripts/acceptance-candidate-metadata.py" "$mirror/scripts/"
cp "$repo_root/scripts/compatibility-artifact-index.py" "$mirror/scripts/"

openssl ecparam -name prime256v1 -genkey -noout -out "$work/acceptance-private.pem"
openssl ec -in "$work/acceptance-private.pem" -pubout \
  -out "$mirror/security/acceptance-candidate-signing-public.pem" >/dev/null 2>&1
openssl ecparam -name prime256v1 -genkey -noout -out "$work/production-private.pem"
openssl ec -in "$work/production-private.pem" -pubout -out "$work/production-public.pem" >/dev/null 2>&1
{
  printf 'write_checksum_public_key() {\n'
  printf "  cat <<'EOF'\n"
  cat "$work/production-public.pem"
  printf 'EOF\n}\n'
} > "$mirror/phase3-binary/dist/install.sh"

repository="Augustas11/macprovider"
tag="v1.8.35"
candidate_ref="refs/heads/fix/585-provider-lifecycle-option2"
candidate_commit="$(printf 'a%.0s' {1..40})"
control_commit="$(printf 'b%.0s' {1..40})"
run_id="123456789"
run_attempt="2"
artifact_index="$work/assets/compatibility-artifact-index.json"
payload="$work/assets/macprovider-cli-${tag}-darwin-arm64.tar.gz"
provenance="$work/assets/release-provenance.json"
checksums="$work/assets/checksums.txt"
compatibility_manifest="$work/assets/compatibility-set.json"
release_asset_list="$work/release-assets.list"

python3 - "$work/assets" "$artifact_index" "$provenance" "$checksums" \
  "$compatibility_manifest" "$release_asset_list" "$repository" "$tag" "$candidate_commit" <<'PY'
import hashlib
import json
import pathlib
import sys

asset_dir, index_path, provenance_path, checksums_path, manifest_path, list_path = map(pathlib.Path, sys.argv[1:7])
repository, tag, commit = sys.argv[7:]
canonical = lambda value: (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
set_id = f"{repository}:{tag}@{commit}"
manifest = {
    "schema_version": "macprovider.compatibility-set-envelope.v1",
    "signatures": [],
    "signed": {
        "compatibility_set_id": set_id,
        "release": {"commit": commit, "repository": repository, "tag": tag, "version": tag.removeprefix("v")},
    },
}
manifest_path.write_bytes(canonical(manifest))
role_names = {
    "catalog_candidates": "autotune-candidates.json",
    "catalog_candidates_signature": "autotune-candidates.json.sig",
    "catalog_demand": "demand-rank.json",
    "catalog_demand_signature": "demand-rank.json.sig",
    "catalog_manifest": "release.json",
    "catalog_trusted_keys": "trusted-keys.json",
    "compatibility_manifest": manifest_path.name,
    "coordinator": "coordinator-linux-amd64",
    "coordinator_cli": "coordinator-cli-linux-amd64",
    "gateway": "gateway-linux-amd64",
    "pearl_metadata": "pearl-release.json",
    "pearl_metadata_signature": "pearl-release.json.sig",
    "provider_cli": f"macprovider-cli-{tag}-darwin-arm64.tar.gz",
}
role_paths = {}
for role, name in role_names.items():
    path = asset_dir / name
    if path != manifest_path:
        path.write_text(f"fixture:{role}\n", encoding="ascii")
    role_paths[role] = path
index = {
    "artifacts": {
        role: {"name": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
        for role, path in role_paths.items()
    },
    "commit": commit,
    "compatibility_manifest_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
    "compatibility_set_id": set_id,
    "repository": repository,
    "schema_version": "macprovider.compatibility-artifact-index.v1",
    "tag": tag,
}
index_path.write_bytes(canonical(index))
assets = {
    **{path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in role_paths.values()},
    index_path.name: hashlib.sha256(index_path.read_bytes()).hexdigest(),
}
provenance = {
    "assets": assets,
    "commit": commit,
    "repository": repository,
    "schema_version": 1,
    "tag": tag,
}
provenance_path.write_bytes(canonical(provenance))
rows = dict(assets)
rows[provenance_path.name] = hashlib.sha256(provenance_path.read_bytes()).hexdigest()
checksums_path.write_text(
    "".join(f"{digest}  {name}\n" for name, digest in sorted(rows.items())),
    encoding="ascii",
)
list_path.write_text("".join(f"{name}\n" for name in sorted([*assets, provenance_path.name])), encoding="ascii")
PY

python3 - "$work/timestamps" <<'PY'
import datetime as dt
import pathlib
import sys

now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
render = lambda value: value.strftime("%Y-%m-%dT%H:%M:%SZ")
pathlib.Path(sys.argv[1]).write_text(f"{render(now)}\n{render(now + dt.timedelta(minutes=10))}\n")
PY
issued_at="$(sed -n '1p' "$work/timestamps")"
expires_at="$(sed -n '2p' "$work/timestamps")"
metadata="$work/assets/acceptance-candidate.json"
signature="$work/assets/acceptance-candidate.json.sig"
python3 "$mirror/scripts/acceptance-candidate-metadata.py" sign \
  --repository "$repository" \
  --tag "$tag" \
  --candidate-ref "$candidate_ref" \
  --candidate-commit "$candidate_commit" \
  --control-commit "$control_commit" \
  --run-id "$run_id" \
  --run-attempt "$run_attempt" \
  --compatibility-manifest "$compatibility_manifest" \
  --checksums "$checksums" \
  --issued-at "$issued_at" \
  --expires-at "$expires_at" \
  --private-key "$work/acceptance-private.pem" \
  --output "$metadata" \
  --signature "$signature"

assets=()
while IFS= read -r release_asset; do
  test -n "$release_asset" && assets+=("$work/assets/$release_asset")
done < "$release_asset_list"
verify=(
  bash "$mirror/scripts/verify-release-checksums.sh"
  --acceptance-candidate "$metadata" "$candidate_ref" "$run_id" "$run_attempt" "$control_commit"
  "$checksums" "$signature" "$provenance" "$repository" "$tag" "$candidate_commit"
  "${assets[@]}"
)
"${verify[@]}" >/dev/null

verify_with_index() {
  local replacement_index="$1"
  local adjusted_assets=()
  local release_asset
  for release_asset in "${assets[@]}"; do
    if [[ "$(basename "$release_asset")" == compatibility-artifact-index.json ]]; then
      adjusted_assets+=("$replacement_index")
    else
      adjusted_assets+=("$release_asset")
    fi
  done
  bash "$mirror/scripts/verify-release-checksums.sh" \
    --acceptance-candidate "$metadata" "$candidate_ref" "$run_id" "$run_attempt" "$control_commit" \
    "$checksums" "$signature" "$provenance" "$repository" "$tag" "$candidate_commit" \
    "${adjusted_assets[@]}"
}

python3 - "$artifact_index" "$work/index-variants" <<'PY'
import json
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
value = json.loads(source.read_text(encoding="utf-8"))
canonical = lambda item: (json.dumps(item, sort_keys=True, separators=(",", ":")) + "\n").encode()

def write(name, item, *, canonical_form=True):
    directory = root / name
    directory.mkdir(parents=True)
    output = directory / source.name
    output.write_bytes(canonical(item) if canonical_form else (json.dumps(item, indent=2) + "\n").encode())

changed = json.loads(json.dumps(value))
changed["schema_version"] = "macprovider.compatibility-artifact-index.v2"
write("wrong-schema", changed)

changed = json.loads(json.dumps(value))
changed["compatibility_manifest_sha256"] = "0" * 64
write("wrong-manifest-digest", changed)

changed = json.loads(json.dumps(value))
changed["artifacts"].pop("provider_cli")
write("missing-role", changed)

changed = json.loads(json.dumps(value))
changed["artifacts"]["provider_binary"] = changed["artifacts"].pop("provider_cli")
write("relabelled-role", changed)

write("noncanonical", value, canonical_form=False)

directory = root / "duplicate-key"
directory.mkdir(parents=True)
raw = source.read_bytes()
(directory / source.name).write_bytes(raw.replace(b'{"artifacts":', b'{"artifacts":{},"artifacts":', 1))
PY

if verify_with_index "$work/index-variants/wrong-schema/compatibility-artifact-index.json" \
  >"$work/wrong-index-schema.out" 2>&1; then
  fail "acceptance verifier accepted an unsupported artifact-index schema"
fi
grep -q 'unsupported schema' "$work/wrong-index-schema.out"

if verify_with_index "$work/index-variants/wrong-manifest-digest/compatibility-artifact-index.json" \
  >"$work/wrong-manifest-digest.out" 2>&1; then
  fail "acceptance verifier accepted a false compatibility-manifest digest"
fi
grep -q 'compatibility manifest digest differs' "$work/wrong-manifest-digest.out"

if verify_with_index "$work/index-variants/missing-role/compatibility-artifact-index.json" \
  >"$work/missing-role.out" 2>&1; then
  fail "acceptance verifier accepted an artifact index with a missing role"
fi
grep -q 'artifact mappings do not contain the independent or legacy role set' "$work/missing-role.out"

if verify_with_index "$work/index-variants/relabelled-role/compatibility-artifact-index.json" \
  >"$work/relabelled-role.out" 2>&1; then
  fail "acceptance verifier accepted a relabelled artifact role"
fi
grep -q 'invalid or duplicate artifact mapping' "$work/relabelled-role.out"

if verify_with_index "$work/index-variants/noncanonical/compatibility-artifact-index.json" \
  >"$work/noncanonical-index.out" 2>&1; then
  fail "acceptance verifier accepted a noncanonical artifact index"
fi
grep -q 'canonical sorted compact JSON' "$work/noncanonical-index.out"

if verify_with_index "$work/index-variants/duplicate-key/compatibility-artifact-index.json" \
  >"$work/duplicate-index-key.out" 2>&1; then
  fail "acceptance verifier accepted a duplicate artifact-index key"
fi
grep -q 'duplicate key' "$work/duplicate-index-key.out"

ln "$payload" "$work/hard-linked-provider-cli"
if "${verify[@]}" >"$work/hard-link.out" 2>&1; then
  fail "acceptance verifier accepted a hard-linked release input"
fi
grep -q 'single-link file' "$work/hard-link.out"
rm "$work/hard-linked-provider-cli"

production_signature="$work/assets/checksums.txt.sig"
openssl dgst -sha256 -sign "$work/production-private.pem" \
  -out "$production_signature" "$checksums"
bash "$mirror/scripts/verify-release-checksums.sh" \
  "$checksums" "$production_signature" "$provenance" "$repository" "$tag" "$candidate_commit" \
  "${assets[@]}" >/dev/null

cp "$signature" "$work/canonical-acceptance-signature"
printf '\n' >> "$signature"
if "${verify[@]}" >"$work/noncanonical-signature.out" 2>&1; then
  fail "acceptance verifier accepted a noncanonical signature encoding"
fi
mv "$work/canonical-acceptance-signature" "$signature"

if bash "$mirror/scripts/verify-release-checksums.sh" \
  "$checksums" "$signature" "$provenance" "$repository" "$tag" "$candidate_commit" \
  "${assets[@]}" >"$work/production-domain.out" 2>&1; then
  fail "production verifier accepted an acceptance signature"
fi

if bash "$mirror/scripts/verify-release-checksums.sh" \
  --acceptance-candidate "$metadata" refs/heads/fix/different "$run_id" "$run_attempt" "$control_commit" \
  "$checksums" "$signature" "$provenance" "$repository" "$tag" "$candidate_commit" \
  "${assets[@]}" >"$work/wrong-ref.out" 2>&1; then
  fail "acceptance verifier accepted replay under a different candidate ref"
fi
grep -q 'candidate ref differs' "$work/wrong-ref.out"

if bash "$mirror/scripts/verify-release-checksums.sh" \
  --acceptance-candidate "$metadata" "$candidate_ref" 987654321 "$run_attempt" "$control_commit" \
  "$checksums" "$signature" "$provenance" "$repository" "$tag" "$candidate_commit" \
  "${assets[@]}" >"$work/wrong-run.out" 2>&1; then
  fail "acceptance verifier accepted replay under a different run id"
fi
grep -q 'run id differs' "$work/wrong-run.out"

if bash "$mirror/scripts/verify-release-checksums.sh" \
  --acceptance-candidate "$metadata" "$candidate_ref" "$run_id" 3 "$control_commit" \
  "$checksums" "$signature" "$provenance" "$repository" "$tag" "$candidate_commit" \
  "${assets[@]}" >"$work/wrong-attempt.out" 2>&1; then
  fail "acceptance verifier accepted replay under a different run attempt"
fi
grep -q 'run attempt differs' "$work/wrong-attempt.out"

wrong_control_commit="$(printf 'c%.0s' {1..40})"
if bash "$mirror/scripts/verify-release-checksums.sh" \
  --acceptance-candidate "$metadata" "$candidate_ref" "$run_id" "$run_attempt" "$wrong_control_commit" \
  "$checksums" "$signature" "$provenance" "$repository" "$tag" "$candidate_commit" \
  "${assets[@]}" >"$work/wrong-control.out" 2>&1; then
  fail "acceptance verifier accepted replay under a different control commit"
fi
grep -q 'control commit differs' "$work/wrong-control.out"

if bash "$mirror/scripts/verify-release-checksums.sh" \
  --allow-partial \
  --acceptance-candidate "$metadata" "$candidate_ref" "$run_id" "$run_attempt" "$control_commit" \
  "$checksums" "$signature" "$provenance" "$repository" "$tag" "$candidate_commit" \
  "$artifact_index" "$provenance" >"$work/partial.out" 2>&1; then
  fail "acceptance verifier allowed a partial signed release set"
fi
grep -q 'must cover the complete release set' "$work/partial.out"

if bash "$mirror/scripts/verify-release-checksums.sh" \
  --acceptance-candidate "$metadata" "$candidate_ref" "$run_id" "$run_attempt" "$control_commit" \
  "$checksums" "$signature" "$provenance" "$repository" "$tag" "$candidate_commit" \
  "$payload" "$provenance" >"$work/missing-index.out" 2>&1; then
  fail "acceptance verifier accepted a release without its artifact index"
fi
grep -q 'requires compatibility-artifact-index.json' "$work/missing-index.out"

wrong_domain_signature="$work/wrong-domain/acceptance-candidate.json.sig"
mkdir -p "$(dirname "$wrong_domain_signature")"
{
  printf 'macprovider.production-release.v1\n'
  cat "$metadata"
} > "$work/wrong-domain-payload"
openssl dgst -sha256 -sign "$work/acceptance-private.pem" \
  -out "$work/wrong-domain.der" "$work/wrong-domain-payload"
python3 - "$work/wrong-domain.der" "$wrong_domain_signature" <<'PY'
import base64
import pathlib
import sys

pathlib.Path(sys.argv[2]).write_bytes(base64.b64encode(pathlib.Path(sys.argv[1]).read_bytes()) + b"\n")
PY
if bash "$mirror/scripts/verify-release-checksums.sh" \
  --acceptance-candidate "$metadata" "$candidate_ref" "$run_id" "$run_attempt" "$control_commit" \
  "$checksums" "$wrong_domain_signature" "$provenance" "$repository" "$tag" "$candidate_commit" \
  "${assets[@]}" >"$work/wrong-domain.out" 2>&1; then
  fail "acceptance verifier accepted a signature from the production domain"
fi

expired_dir="$work/expired"
mkdir -p "$expired_dir"
python3 "$mirror/scripts/acceptance-candidate-metadata.py" sign \
  --repository "$repository" \
  --tag "$tag" \
  --candidate-ref "$candidate_ref" \
  --candidate-commit "$candidate_commit" \
  --control-commit "$control_commit" \
  --run-id "$run_id" \
  --run-attempt "$run_attempt" \
  --compatibility-manifest "$compatibility_manifest" \
  --checksums "$checksums" \
  --issued-at 2020-01-01T00:00:00Z \
  --expires-at 2020-01-01T00:05:00Z \
  --private-key "$work/acceptance-private.pem" \
  --output "$expired_dir/acceptance-candidate.json" \
  --signature "$expired_dir/acceptance-candidate.json.sig"
if bash "$mirror/scripts/verify-release-checksums.sh" \
  --acceptance-candidate "$expired_dir/acceptance-candidate.json" "$candidate_ref" "$run_id" "$run_attempt" "$control_commit" \
  "$checksums" "$expired_dir/acceptance-candidate.json.sig" "$provenance" "$repository" "$tag" "$candidate_commit" \
  "${assets[@]}" >"$work/expired.out" 2>&1; then
  fail "acceptance verifier accepted expired metadata"
fi
grep -q 'candidate has expired' "$work/expired.out"

bash -n "$repo_root/scripts/verify-release-checksums.sh" "$0"
printf '[acceptance-candidate-metadata-test] passed\n'
