#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[verify-release-checksums] ERROR: %s\n' "$*" >&2
  exit 1
}

allow_partial=false
if [[ "${1:-}" == "--allow-partial" ]]; then
  allow_partial=true
  shift
fi
[[ "$#" -ge 7 ]] || die "usage: [--allow-partial] CHECKSUMS SIGNATURE PROVENANCE REPOSITORY TAG COMMIT ASSET..."
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
for path in "$checksums" "$signature" "$provenance" "${assets[@]}"; do
  [[ -f "$path" && ! -L "$path" ]] || die "release input is not a regular file: $path"
done

public_key="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/release-public-key.XXXXXX.pem")"
trap 'rm -f "$public_key"' EXIT
python3 - "$repo_root/phase3-binary/dist/install.sh" "$public_key" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
blocks = re.findall(
    r"-----BEGIN PUBLIC KEY-----\n.+?\n-----END PUBLIC KEY-----",
    source,
    flags=re.DOTALL,
)
if len(blocks) != 1:
    raise SystemExit("install.sh must embed exactly one canonical release public key")
pathlib.Path(sys.argv[2]).write_text(blocks[0] + "\n", encoding="ascii")
PY
openssl dgst -sha256 -verify "$public_key" -signature "$signature" "$checksums" >/dev/null ||
  die "checksums signature verification failed against the canonical installer key"

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

printf '[verify-release-checksums] ok: canonical signature and release set verified for %s\n' "$tag"
