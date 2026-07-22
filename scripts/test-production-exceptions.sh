#!/usr/bin/env bash
# Guard the #615 production exception register validator, report, and gates.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$root"

fail() {
  printf '[test-production-exceptions] ERROR: %s\n' "$*" >&2
  exit 1
}

python3 -m json.tool ops/exceptions/production-exceptions.json >/dev/null
python3 -m json.tool ops/exceptions/production-exceptions.schema.json >/dev/null
python3 -m json.tool ops/exceptions/removed-exception-tombstones.json >/dev/null

python3 scripts/check-production-exceptions.py \
  --now 2026-07-22T12:00:00Z \
  validate \
  || fail "committed register failed validate"

report="$(mktemp "${TMPDIR:-/tmp}/exception-report.XXXXXX")"
python3 scripts/check-production-exceptions.py \
  --now 2026-07-22T12:00:00Z \
  report \
  -o "$report" \
  || fail "report generation failed"
python3 - "$report" <<'PY'
import json, sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
assert report.get("secrets_redacted") is True
assert isinstance(report.get("exceptions"), list) and report["exceptions"]
assert report["validation"]["ok"] is True
forbidden = ("Bearer ", "BEGIN ", "ghp_", "sk-", "password=")
blob = json.dumps(report)
for token in forbidden:
    if token in blob:
        raise SystemExit(f"report leaked secret-like token {token!r}")
PY
rm -f "$report"

# Default-safe deploy gate must pass on the committed inventory (warnings OK).
python3 scripts/check-production-exceptions.py \
  --now 2026-07-22T12:00:00Z \
  gate --mode=deploy --no-enforce \
  || fail "default-safe deploy gate failed unexpectedly"

# Promote mode must fail closed while expired/unbounded exceptions remain.
if python3 scripts/check-production-exceptions.py \
  --now 2026-07-22T12:00:00Z \
  gate --mode=promote; then
  fail "promote gate unexpectedly passed while expired/unbounded exceptions remain"
fi

# Deploy tooling must invoke the exception gate.
grep -qF 'check-production-exceptions.py' \
  phase4-coordinator/dist/check-deploy-config.sh \
  || fail "check-deploy-config.sh does not reference the exception checker"
grep -qE 'gate --mode=deploy' \
  phase4-coordinator/dist/check-deploy-config.sh \
  || fail "check-deploy-config.sh does not invoke the exception deploy gate"

# Stable promotion workflow must invoke the promote gate.
grep -qF 'check-production-exceptions.py gate --mode=promote' \
  .github/workflows/promote-acceptance-candidate.yml \
  || fail "promote-acceptance-candidate.yml missing exception promote gate"

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_production_exceptions

printf '[test-production-exceptions] OK\n'
