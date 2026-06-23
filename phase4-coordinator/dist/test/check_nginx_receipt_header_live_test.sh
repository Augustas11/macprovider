#!/usr/bin/env bash
set -euo pipefail

if [ -z "${SPEC015_NGINX_ECHO_URL:-}" ]; then
  echo "skip: set SPEC015_NGINX_ECHO_URL to an nginx-fronted echo endpoint to verify a 4096-byte X-MacProvider-Receipt header"
  exit 0
fi

HEADERS="$(mktemp -t spec015-nginx-headers.XXXXXX)"
cleanup() { rm -f "$HEADERS"; }
trap cleanup EXIT

VALUE="$(python3 - <<'VALUEPY'
print("r" * 4096, end="")
VALUEPY
)"

curl --http1.1 -fsS -o /dev/null -D "$HEADERS" \
  -H "X-MacProvider-Receipt: $VALUE" \
  "$SPEC015_NGINX_ECHO_URL"

python3 - "$HEADERS" "$VALUE" <<'CHECKPY'
from pathlib import Path
import sys

headers = Path(sys.argv[1]).read_text(encoding="latin-1")
expected = sys.argv[2]
seen = []
for raw_line in headers.splitlines():
    if raw_line.lower().startswith("x-macprovider-receipt:"):
        seen.append(raw_line.split(":", 1)[1].strip())
if not seen:
    raise SystemExit("FAIL: response did not include X-MacProvider-Receipt")
if seen[-1] != expected:
    raise SystemExit(f"FAIL: X-MacProvider-Receipt length/content mismatch: got {len(seen[-1])}, want {len(expected)}")
print("ok: deployed nginx echoed 4096-byte X-MacProvider-Receipt without truncation")
CHECKPY
