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

# Gateway deploy must invoke the exception gate before SKIP_C2_CHECK.
grep -qF 'check-production-exceptions.py' \
  phase5-gateway/dist/deploy-pearl-vps.sh \
  || fail "gateway deploy does not reference the exception checker"
exc_line="$(grep -nF 'check-production-exceptions.py' phase5-gateway/dist/deploy-pearl-vps.sh | head -n1 | cut -d: -f1)"
skip_line="$(grep -nF 'elif [ "${SKIP_C2_CHECK:-0}" = "1" ]' phase5-gateway/dist/deploy-pearl-vps.sh | head -n1 | cut -d: -f1)"
[ -n "$exc_line" ] && [ -n "$skip_line" ] && [ "$exc_line" -lt "$skip_line" ] ||
  fail "gateway exception gate must precede SKIP_C2_CHECK branch (exc=$exc_line skip=$skip_line)"

# Stable promotion workflow must invoke the reusable promote gate helper.
grep -qF 'scripts/gate-production-exceptions-promote.sh' \
  .github/workflows/promote-acceptance-candidate.yml \
  || fail "promote-acceptance-candidate.yml missing exception promote helper"
grep -qF 'gate --mode=promote' \
  scripts/gate-production-exceptions-promote.sh \
  || fail "promote helper missing gate --mode=promote"
grep -qF 'origin/main' \
  scripts/gate-production-exceptions-promote.sh \
  || fail "promote helper must bind to origin/main"
grep -qF 'Re-check production exceptions before draft creation' \
  .github/workflows/promote-acceptance-candidate.yml \
  || fail "promote workflow missing pre-draft exception recheck"
grep -qF 'Re-check production exceptions before undraft publish' \
  .github/workflows/promote-acceptance-candidate.yml \
  || fail "promote workflow missing pre-undraft exception recheck"

# sync-check CLI (documented form with --tombstones after subcommand).
work="$(mktemp -d "${TMPDIR:-/tmp}/exception-sync.XXXXXX")"
python3 - "$work" <<'PY'
import json, pathlib, sys
work = pathlib.Path(sys.argv[1])
removed = {
  "$schema": "./production-exceptions.schema.json",
  "schema_version": "macprovider-production-exceptions-v1",
  "updated_at": "2026-07-22T00:00:00Z",
  "updated_by": "test",
  "environment": "pearl-production",
  "exceptions": [{
    "id": "exc-sync-removed",
    "status": "removed",
    "environment": "pearl-production",
    "component": "other",
    "policy_delta": "gone",
    "authority_surface": "test",
    "reason": "test",
    "owner": "ops/test",
    "issue": "https://github.com/Augustas11/macprovider/issues/615",
    "created_at": "2026-07-01T00:00:00Z",
    "expires_at": "2026-08-01T00:00:00Z",
    "scope": "test",
    "removal_condition": "done",
    "rollback_command": "echo",
    "post_removal_validation": "echo",
    "blocks_stable_promotion": False,
    "evidence": ["https://github.com/Augustas11/macprovider/issues/615"],
  }],
  "open_questions": [],
}
active = json.loads(json.dumps(removed))
active["exceptions"][0]["status"] = "active"
tombs = {
  "schema_version": "macprovider-removed-exception-tombstones-v1",
  "updated_at": "2026-07-22T00:00:00Z",
  "updated_by": "test",
  "environment": "pearl-production",
  "tombstones": [{
    "id": "exc-sync-removed",
    "removed_at": "2026-07-20T00:00:00Z",
    "removal_evidence": "test",
    "authority_surface": "test",
  }],
}
(work / "current.json").write_text(json.dumps(removed))
(work / "stale.json").write_text(json.dumps(active))
(work / "tombs.json").write_text(json.dumps(tombs))
PY
if python3 scripts/check-production-exceptions.py sync-check \
  --current "$work/current.json" \
  --stale "$work/stale.json" \
  --tombstones "$work/tombs.json"; then
  fail "sync-check unexpectedly passed on resurrecting stale register"
fi
rm -rf "$work"

bash phase5-gateway/dist/test/gateway_deploy_c2_precheck.test.sh \
  || fail "gateway deploy C2/exception precheck failed"

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_production_exceptions

printf '[test-production-exceptions] OK\n'
