#!/usr/bin/env bash
set -euo pipefail

if [ -z "${SPEC015_NGINX_ECHO_URL:-}" ]; then
  # Round-2 audit M-R2: previously the script exited 0 silently when no
  # echo URL was configured, which made `make test-dist` and the AC-15
  # manifest claim coverage they did not actually provide in CI. The
  # static buffer check (check_nginx_receipt_buffers_test.sh) remains the
  # load-bearing assertion in CI. This live check is the operator-runbook
  # smoke against a real nginx; it must either be wired with an echo
  # endpoint, or explicitly opted out via SPEC015_NGINX_LIVE_OPTIONAL=1
  # so the silent-skip behavior is a deliberate choice.
  if [ "${SPEC015_NGINX_LIVE_OPTIONAL:-}" = "1" ]; then
    echo "skip: SPEC015_NGINX_LIVE_OPTIONAL=1 — operator-runbook smoke not exercised in this run"
    exit 0
  fi
  echo "FAIL: SPEC015_NGINX_ECHO_URL is unset (set it to an nginx-fronted echo endpoint, or pass SPEC015_NGINX_LIVE_OPTIONAL=1 to opt out)" >&2
  exit 1
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
