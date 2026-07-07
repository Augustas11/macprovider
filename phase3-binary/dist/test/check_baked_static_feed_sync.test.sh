#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/../.."
SWIFT="$ROOT/Sources/macprovider-cli/AutotuneRecommend.swift"
STATIC_DIR="$SCRIPT_DIR/../static"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

python3 - "$SWIFT" "$STATIC_DIR" <<'PY'
import hashlib, pathlib, re, sys

swift_path = pathlib.Path(sys.argv[1])
static_dir = pathlib.Path(sys.argv[2])
swift = swift_path.read_text()

def extract(const: str) -> bytes:
    match = re.search(rf'static let {const} = """\n(.*?)"""', swift, re.S)
    if not match:
        raise SystemExit(f"missing {const}")
    lines = [ln[4:] if ln.startswith("    ") else ln for ln in match.group(1).split("\n")]
    return "\n".join(lines).strip("\n").encode()

pairs = [
    ("bakedCandidateCatalogJSON", static_dir / "autotune-candidates.json"),
    ("bakedDemandRankJSON", static_dir / "demand-rank.json"),
]
for const, path in pairs:
    baked = extract(const)
    dist = path.read_bytes().strip()
    if baked != dist:
        raise SystemExit(
            f"{const} drift: baked sha256={hashlib.sha256(baked).hexdigest()} "
            f"dist sha256={hashlib.sha256(dist).hexdigest()}"
        )
print("PASS: baked static feeds mirror dist/static byte-for-byte")
PY
