#!/usr/bin/env bash
# The parameterized export scripts live one directory below the registry.
# Sourcing dirname/$0/registry.sh passes a text-only workflow test and fails
# on a real dispatch, after signing. This runs the scripts.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

tmp="$(mktemp -d)"
probe_redacted="$root/journeys/evidence/.export-registry-probe.redacted.json"
probe_envelope="$root/journeys/evidence/.export-registry-probe.journey-result.signed.json"
cleanup() {
  rm -rf "$tmp"
  rm -f "$probe_redacted" "$probe_envelope"
}
trap cleanup EXIT

must_fail() {
  local expect="$1"
  shift
  set +e
  local out rc
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    printf 'expected failure: %s\n' "$*" >&2
    exit 1
  fi
  printf '%s\n' "$out" | grep -q "$expect" || {
    printf 'missing %s in:\n%s\n' "$expect" "$out" >&2
    exit 1
  }
  if printf '%s\n' "$out" | grep -q 'No such file or directory'; then
    printf 'registry did not load:\n%s\n' "$out" >&2
    exit 1
  fi
}

must_fail 'journey is not valid for this job' \
  env JOURNEY=buyer-enforce EXPECTED_MODE=evidence \
  bash scripts/signed-journeys/promote/export.sh
must_fail 'unknown signed journey' \
  env JOURNEY=not-a-journey EXPECTED_MODE=promote \
  bash scripts/signed-journeys/promote/export.sh
must_fail 'journey is not valid for this job' \
  env JOURNEY=trusted-pool-creator-mvp EXPECTED_MODE=promote \
  bash scripts/signed-journeys/evidence/export.sh

printf '%s\n' '{}' > "$probe_redacted"
printf '%s\n' '{}' > "$probe_envelope"

run_export() {
  local script="$1" journey="$2" mode="$3"
  env \
    JOURNEY="$journey" \
    EXPECTED_MODE="$mode" \
    RUNNER_TEMP="$tmp" \
    SOURCE_SHA='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    EVIDENCE_SHA='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
    REDACTED='journeys/evidence/.export-registry-probe.redacted.json' \
    ENVELOPE='journeys/evidence/.export-registry-probe.journey-result.signed.json' \
    REQUIREMENT_IDS='SPEC-001-R001' \
    REQUIREMENT_SLUG='spec-001-r001' \
    GITHUB_RUN_ID='1' \
    GITHUB_RUN_ATTEMPT='1' \
    bash "$script"
}

run_export scripts/signed-journeys/promote/export.sh buyer-enforce promote
promote_dir="$tmp/signed-buyer-enforce-journey-promotion"
[ -f "$promote_dir/specs/CONFORMANCE.json" ]
python3 - "$promote_dir/promotion-manifest.json" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
assert manifest["journey_id"] == "JOURNEY-BUYER-ENFORCE", manifest["journey_id"]
assert manifest["schema_version"] == "macprovider.signed-buyer-enforce-journey-promotion.v1"
assert "conformance_sha256" in manifest
PY

run_export scripts/signed-journeys/evidence/export.sh trusted-pool-creator-mvp evidence
evidence_dir="$tmp/signed-trusted-pool-creator-mvp-journey-evidence"
[ ! -e "$evidence_dir/specs/CONFORMANCE.json" ]
python3 - "$evidence_dir/evidence-manifest.json" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
assert manifest["journey_id"] == "JOURNEY-TRUSTED-POOL-CREATOR-MVP", manifest["journey_id"]
assert manifest["schema_version"] == "macprovider.signed-trusted-pool-creator-mvp-journey-evidence.v1"
assert "conformance_sha256" not in manifest
PY

printf '[test-signed-journey-export] ok: export scripts load the closed registry\n'
