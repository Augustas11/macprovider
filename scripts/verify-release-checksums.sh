#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[verify-release-checksums] ERROR: %s\n' "$*" >&2
  exit 1
}

allow_partial=false
acceptance_candidate=false
acceptance_metadata=""
acceptance_candidate_ref=""
acceptance_run_id=""
acceptance_run_attempt=""
acceptance_control_commit=""
openssl_bin=""
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --allow-partial)
      allow_partial=true
      shift
      ;;
    --openssl)
      [[ "$#" -ge 2 ]] || die "--openssl requires an absolute executable path"
      openssl_bin="$2"
      shift 2
      ;;
    --acceptance-candidate)
      [[ "$#" -ge 6 ]] ||
        die "--acceptance-candidate requires METADATA CANDIDATE_REF RUN_ID RUN_ATTEMPT CONTROL_COMMIT"
      acceptance_candidate=true
      acceptance_metadata="$2"
      acceptance_candidate_ref="$3"
      acceptance_run_id="$4"
      acceptance_run_attempt="$5"
      acceptance_control_commit="$6"
      shift 6
      ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ "$#" -ge 7 ]] || die "usage: [--allow-partial] [--openssl ABSOLUTE_PATH] [--acceptance-candidate METADATA CANDIDATE_REF RUN_ID RUN_ATTEMPT CONTROL_COMMIT] CHECKSUMS SIGNATURE PROVENANCE REPOSITORY TAG COMMIT ASSET..."
[[ "$acceptance_candidate" == false || "$allow_partial" == false ]] ||
  die "acceptance candidate verification must cover the complete release set"
if [[ "$acceptance_candidate" == false ]]; then
  [[ "$openssl_bin" == /* && -f "$openssl_bin" && ! -L "$openssl_bin" && -x "$openssl_bin" ]] ||
    die "production verification requires --openssl with an absolute regular non-symlink executable"
elif [[ -n "$openssl_bin" ]]; then
  die "--openssl is not valid for domain-separated acceptance verification"
fi
checksums="$1"
signature="$2"
provenance="$3"
repository="$4"
tag="$5"
commit="$6"
shift 6
assets=("$@")
repo_root="$(cd "$(dirname "$0")/.." && pwd)"

[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid repository"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid tag"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "invalid commit"
[[ "$acceptance_candidate" == false || "$acceptance_candidate_ref" =~ ^refs/heads/[A-Za-z0-9._/-]+$ ]] ||
  die "invalid acceptance candidate ref"
[[ "$acceptance_candidate" == false || "$acceptance_run_id" =~ ^[1-9][0-9]{0,19}$ ]] ||
  die "invalid acceptance run id"
[[ "$acceptance_candidate" == false || "$acceptance_run_attempt" =~ ^[1-9][0-9]{0,9}$ ]] ||
  die "invalid acceptance run attempt"
[[ "$acceptance_candidate" == false || "$acceptance_control_commit" =~ ^[0-9a-f]{40}$ ]] ||
  die "invalid acceptance control commit"
inputs=("$checksums" "$signature" "$provenance" "${assets[@]}")
if [[ "$acceptance_candidate" == true ]]; then
  inputs+=("$acceptance_metadata")
  [[ "$(basename "$acceptance_metadata")" == "acceptance-candidate.json" ]] ||
    die "acceptance metadata must be named acceptance-candidate.json"
  [[ "$(basename "$signature")" == "acceptance-candidate.json.sig" ]] ||
    die "acceptance signature must be named acceptance-candidate.json.sig"
  for path in "${assets[@]}"; do
    [[ "$(basename "$path")" != "checksums.txt.sig" ]] ||
      die "acceptance candidate must not contain production checksums.txt.sig"
  done
fi
for path in "${inputs[@]}"; do
  [[ -f "$path" && ! -L "$path" ]] || die "release input is not a regular file: $path"
done

snapshot_root="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/release-verification.XXXXXX")"
chmod 700 "$snapshot_root"
public_key="$snapshot_root/release-public-key.pem"
cleanup() {
  rm -rf "$snapshot_root"
}
trap cleanup EXIT

snapshot_input() {
  local label="$1"
  local source="$2"
  python3 - "$snapshot_root" "$label" "$source" <<'PY'
import os
import pathlib
import stat
import sys

root, label, source = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
destination_directory = root / label
destination_directory.mkdir(mode=0o700)
destination = destination_directory / source.name
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
try:
    source_fd = os.open(source, flags)
except OSError as exc:
    raise SystemExit(f"cannot open release input safely: {source}: {exc}")
try:
    info = os.fstat(source_fd)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise SystemExit(f"release input must be a regular non-symlink single-link file: {source}")
    destination_fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o400)
    try:
        while True:
            chunk = os.read(source_fd, 1024 * 1024)
            if not chunk:
                break
            view = memoryview(chunk)
            while view:
                written = os.write(destination_fd, view)
                view = view[written:]
        os.fsync(destination_fd)
    finally:
        os.close(destination_fd)
finally:
    os.close(source_fd)
print(destination)
PY
}

checksums="$(snapshot_input checksums "$checksums")"
signature="$(snapshot_input signature "$signature")"
provenance="$(snapshot_input provenance "$provenance")"
if [[ "$acceptance_candidate" == true ]]; then
  acceptance_metadata="$(snapshot_input acceptance-metadata "$acceptance_metadata")"
fi
snapshot_assets=()
asset_number=0
for path in "${assets[@]}"; do
  snapshot_assets+=("$(snapshot_input "asset-$asset_number" "$path")")
  asset_number=$((asset_number + 1))
done
assets=("${snapshot_assets[@]}")

if [[ "$acceptance_candidate" == true ]]; then
  acceptance_public_key="$repo_root/security/acceptance-candidate-signing-public.pem"
  [[ -f "$acceptance_public_key" && ! -L "$acceptance_public_key" ]] ||
    die "canonical acceptance-candidate signing public key is missing"
  cp "$acceptance_public_key" "$public_key"
else
python3 - "$repo_root/phase3-binary/dist/install.sh" "$public_key" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
function = re.search(
    r"write_checksum_public_key\(\) \{(.+?)\n\}",
    source,
    flags=re.DOTALL,
)
blocks = re.findall(
    r"-----BEGIN PUBLIC KEY-----\n.+?\n-----END PUBLIC KEY-----",
    function.group(1) if function else "",
    flags=re.DOTALL,
)
if len(blocks) != 1:
    raise SystemExit("install.sh must embed exactly one canonical release public key")
pathlib.Path(sys.argv[2]).write_text(blocks[0] + "\n", encoding="ascii")
PY
fi
if [[ "$acceptance_candidate" == true ]]; then
  artifact_index=""
  for path in "${assets[@]}"; do
    if [[ "$(basename "$path")" == "compatibility-artifact-index.json" ]]; then
      [[ -z "$artifact_index" ]] || die "duplicate compatibility artifact index"
      artifact_index="$path"
    fi
  done
  [[ -n "$artifact_index" ]] || die "acceptance verification requires compatibility-artifact-index.json"
  artifact_mapping_file="$snapshot_root/artifact-mappings.tsv"
  python3 - "$artifact_index" "$artifact_mapping_file" <<'PY'
import json
import pathlib
import re
import sys

source, output = map(pathlib.Path, sys.argv[1:])
data = source.read_bytes()

def reject_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise SystemExit(f"artifact index contains duplicate key: {key!r}")
        result[key] = value
    return result

try:
    value = json.loads(data.decode("utf-8"), object_pairs_hook=reject_pairs)
except (UnicodeDecodeError, json.JSONDecodeError) as exc:
    raise SystemExit(f"invalid artifact index JSON: {exc}")
rows = value.get("artifacts") if isinstance(value, dict) else None
if not isinstance(rows, dict):
    raise SystemExit("artifact index is missing artifact role mappings")
safe = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,255}")
lines = []
for role, row in sorted(rows.items()):
    name = row.get("name") if isinstance(row, dict) else None
    if not isinstance(role, str) or not safe.fullmatch(role) or not isinstance(name, str) or not safe.fullmatch(name):
        raise SystemExit("artifact index contains an unsafe role mapping")
    lines.append(f"{role}\t{name}\n")
output.write_text("".join(lines), encoding="ascii")
PY
  artifact_arguments=()
  compatibility_manifest=""
  while IFS=$'\t' read -r role asset_name; do
    matched_asset=""
    for path in "${assets[@]}"; do
      if [[ "$(basename "$path")" == "$asset_name" ]]; then
        [[ -z "$matched_asset" ]] || die "duplicate release asset basename: $asset_name"
        matched_asset="$path"
      fi
    done
    [[ -n "$matched_asset" ]] || die "artifact index references an absent release asset: $asset_name"
    artifact_arguments+=(--artifact "$role=$matched_asset")
    if [[ "$role" == compatibility_manifest ]]; then
      compatibility_manifest="$matched_asset"
    fi
  done < "$artifact_mapping_file"
  [[ -n "$compatibility_manifest" ]] || die "artifact index lacks the compatibility manifest role"
  python3 - "$signature" <<'PY' || die "acceptance signature must be canonical base64 DER with one trailing newline"
import base64
import pathlib
import sys

encoded_with_newline = pathlib.Path(sys.argv[1]).read_bytes()
if not encoded_with_newline.endswith(b"\n") or b"\n" in encoded_with_newline[:-1]:
    raise SystemExit(1)
encoded = encoded_with_newline[:-1]
try:
    signature = base64.b64decode(encoded, validate=True)
except ValueError:
    raise SystemExit(1)
if base64.b64encode(signature) != encoded or not 64 <= len(signature) <= 80:
    raise SystemExit(1)
PY
  python3 "$repo_root/scripts/acceptance-candidate-metadata.py" verify \
    --input "$acceptance_metadata" \
    --signature "$signature" \
    --public-key "$public_key" \
    --checksums "$checksums" \
    --repository "$repository" \
    --tag "$tag" \
    --candidate-ref "$acceptance_candidate_ref" \
    --candidate-commit "$commit" \
    --control-commit "$acceptance_control_commit" \
    --run-id "$acceptance_run_id" \
    --run-attempt "$acceptance_run_attempt"
  python3 "$repo_root/scripts/compatibility-artifact-index.py" validate \
    --input "$artifact_index" \
    --compatibility-manifest "$compatibility_manifest" \
    --repository "$repository" \
    --tag "$tag" \
    --commit "$commit" \
    "${artifact_arguments[@]}"
else
  "$openssl_bin" dgst -sha256 -verify "$public_key" -signature "$signature" "$checksums" >/dev/null ||
    die "checksums signature verification failed against the canonical installer key"
fi

python3 - "$allow_partial" "$checksums" "$provenance" "$repository" "$tag" "$commit" "${assets[@]}" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

allow_partial = sys.argv[1] == "true"
checksums_path = pathlib.Path(sys.argv[2])
provenance_path = pathlib.Path(sys.argv[3])
repository, tag, commit = sys.argv[4:7]
asset_paths = [pathlib.Path(value) for value in sys.argv[7:]]

provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
if provenance.get("schema_version") != 1:
    raise SystemExit("unsupported provenance schema")
if provenance.get("repository") != repository:
    raise SystemExit("provenance repository differs from reviewed release")
if provenance.get("tag") != tag:
    raise SystemExit("provenance tag differs from reviewed release")
if provenance.get("commit") != commit:
    raise SystemExit("provenance commit differs from reviewed release")

signed_assets = provenance.get("assets")
if not isinstance(signed_assets, dict) or not all(
    isinstance(name, str)
    and re.fullmatch(r"[A-Za-z0-9._-]+", name)
    and isinstance(digest, str)
    and re.fullmatch(r"[0-9a-f]{64}", digest)
    for name, digest in signed_assets.items()
):
    raise SystemExit("invalid signed provenance asset map")

local = {}
for path in asset_paths:
    if path.name in local:
        raise SystemExit(f"duplicate local release asset: {path.name}")
    local[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
expected_local_names = set(signed_assets) | {provenance_path.name}
if not set(local) <= expected_local_names or (not allow_partial and set(local) != expected_local_names):
    raise SystemExit("local release assets differ from the signed provenance set")
for name, digest in local.items():
    expected = (
        hashlib.sha256(provenance_path.read_bytes()).hexdigest()
        if name == provenance_path.name
        else signed_assets[name]
    )
    if digest != expected:
        raise SystemExit(f"local asset differs from signed provenance: {name}")

rows = {}
for number, raw in enumerate(checksums_path.read_text(encoding="utf-8").splitlines(), 1):
    fields = raw.split()
    if len(fields) != 2 or not re.fullmatch(r"[0-9a-f]{64}", fields[0]) or not re.fullmatch(
        r"[A-Za-z0-9._-]+", fields[1]
    ):
        raise SystemExit(f"invalid checksums row {number}")
    if fields[1] in rows:
        raise SystemExit(f"duplicate checksums asset: {fields[1]}")
    rows[fields[1]] = fields[0]
expected_rows = dict(signed_assets)
expected_rows[provenance_path.name] = hashlib.sha256(provenance_path.read_bytes()).hexdigest()
if rows != expected_rows:
    raise SystemExit("signed checksums do not exactly cover the reviewed release assets")
PY

if [[ "$acceptance_candidate" == true ]]; then
  printf '[verify-release-checksums] ok: domain-separated acceptance candidate verified for %s at %s (ref %s; run %s/%s; control %s)\n' \
    "$tag" "$commit" "$acceptance_candidate_ref" "$acceptance_run_id" "$acceptance_run_attempt" "$acceptance_control_commit"
else
  printf '[verify-release-checksums] ok: canonical production signature and release set verified for %s\n' "$tag"
fi
