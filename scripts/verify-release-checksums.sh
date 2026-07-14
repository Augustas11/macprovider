#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[verify-release-checksums] ERROR: %s\n' "$*" >&2
  exit 1
}

allow_partial=false
acceptance_candidate=false
acceptance_metadata=""
acceptance_run_id=""
acceptance_run_attempt=""
acceptance_control_commit=""
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --allow-partial)
      allow_partial=true
      shift
      ;;
    --acceptance-candidate)
      [[ "$#" -ge 5 ]] || die "--acceptance-candidate requires METADATA RUN_ID RUN_ATTEMPT CONTROL_COMMIT"
      acceptance_candidate=true
      acceptance_metadata="$2"
      acceptance_run_id="$3"
      acceptance_run_attempt="$4"
      acceptance_control_commit="$5"
      shift 5
      ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ "$#" -ge 7 ]] || die "usage: [--allow-partial] [--acceptance-candidate METADATA RUN_ID RUN_ATTEMPT CONTROL_COMMIT] CHECKSUMS SIGNATURE PROVENANCE REPOSITORY TAG COMMIT ASSET..."
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

public_key="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/release-public-key.XXXXXX.pem")"
cleanup() {
  rm -f "$public_key"
}
trap cleanup EXIT
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
    --candidate-commit "$commit" \
    --control-commit "$acceptance_control_commit" \
    --run-id "$acceptance_run_id" \
    --run-attempt "$acceptance_run_attempt"
  python3 - "$acceptance_metadata" "$artifact_index" "$repository" "$tag" "$commit" <<'PY'
import json
import pathlib
import sys

metadata_path, index_path, repository, tag, commit = sys.argv[1:]
metadata = json.loads(pathlib.Path(metadata_path).read_text(encoding="utf-8"))
index = json.loads(pathlib.Path(index_path).read_text(encoding="utf-8"))
set_id = f"{repository}:{tag}@{commit}"
if metadata.get("compatibility_set_id") != set_id:
    raise SystemExit("acceptance metadata compatibility set differs")
if index.get("repository") != repository or index.get("tag") != tag or index.get("commit") != commit:
    raise SystemExit("compatibility artifact index identity differs")
if index.get("compatibility_set_id") != set_id:
    raise SystemExit("compatibility artifact index compatibility set differs")
PY
else
  openssl dgst -sha256 -verify "$public_key" -signature "$signature" "$checksums" >/dev/null ||
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
  printf '[verify-release-checksums] ok: domain-separated acceptance candidate verified for %s at %s (run %s/%s; control %s)\n' \
    "$tag" "$commit" "$acceptance_run_id" "$acceptance_run_attempt" "$acceptance_control_commit"
else
  printf '[verify-release-checksums] ok: canonical production signature and release set verified for %s\n' "$tag"
fi
