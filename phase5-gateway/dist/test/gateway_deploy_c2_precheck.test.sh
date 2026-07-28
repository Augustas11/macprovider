#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_SH="$SCRIPT_DIR/../deploy-pearl-vps.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bash -n "$DEPLOY_SH"

grep -q -- '--dry-run-local' "$DEPLOY_SH" ||
  fail "deploy script lacks explicit --dry-run-local developer path"

grep -q "validating installed Pearl coordinator config: .*sha256=" "$DEPLOY_SH" ||
  fail "deploy script does not log installed coordinator config SHA-256"
grep -q "validating installed Pearl gateway config: .*sha256=" "$DEPLOY_SH" ||
  fail "deploy script does not log installed gateway config SHA-256"

grep -q 'cat '"'"'\$GATEWAY_REMOTE_CONFIG'"'" "$DEPLOY_SH" ||
  fail "deploy script does not read installed Pearl gateway config over SSH"
grep -q 'cat '"'"'\$COORD_REMOTE_CONFIG'"'" "$DEPLOY_SH" ||
  fail "deploy script does not read installed Pearl coordinator config over SSH"
grep -q 'COORD_REMOTE_OVERLAY="${COORD_REMOTE_OVERLAY:-/etc/macprovider/coordinator.pearl-overlays.yaml}"' "$DEPLOY_SH" ||
  fail "deploy script does not declare the installed Pearl coordinator overlay path"
grep -q 'cat '"'"'\$COORD_REMOTE_OVERLAY'"'" "$DEPLOY_SH" ||
  fail "deploy script does not read installed Pearl coordinator overlay over SSH"
grep -q 'python3 "$MERGE_OVERLAY_SCRIPT" "$COORD_REMOTE_CONFIG_TMP" "$COORD_REMOTE_OVERLAY_TMP"' "$DEPLOY_SH" ||
  fail "gateway deploy does not merge coordinator base + overlay for effective credential proof"

local_count=$(grep -c 'bash "$CHECK_SCRIPT" "$COORD_CONFIG" "$GATEWAY_CONFIG"' "$DEPLOY_SH" || true)
if [ "$local_count" != "1" ]; then
  fail "local GATEWAY_CONFIG C2 path should appear exactly once inside --dry-run-local, got $local_count"
fi

grep -q 'bash "$CHECK_SCRIPT" "${CHECK_ARGS\[0\]}" "$GATEWAY_REMOTE_CONFIG_TMP" "${CHECK_ARGS\[@\]:1}"' "$DEPLOY_SH" ||
  fail "production C2 path does not validate installed Pearl config plus optional coordinator overlay"

for proof in C2C_COORD_OPERATOR_KEY_SHA256 C2C_COORD_SERVICE_TOKEN_SHA256 C2C_GATEWAY_SERVICE_TOKEN_SHA256 C2C_GATEWAY_OPERATOR_KEY_SHA256; do
  grep -q "$proof=\"\$$proof\"" "$DEPLOY_SH" ||
    fail "production C2 path does not pass $proof to the shared gate"
  dry_run_assignment=$(printf '%s="${%s:-}"' "$proof" "$proof")
  grep -Fq "$dry_run_assignment" "$DEPLOY_SH" ||
    fail "dry-run C2 path does not explicitly accept $proof"
done
grep -q 'C2C_PROOF_SCRIPT=' "$DEPLOY_SH" ||
  fail "production C2 path does not declare the shared runtime proof helper"
grep -q '< "$C2C_PROOF_SCRIPT"' "$DEPLOY_SH" ||
  fail "production C2 path does not execute the shared runtime proof helper on Pearl"
grep -q 'python3 - gateway-deploy' "$DEPLOY_SH" ||
  fail "production C2 path does not attest future gateway state against the running coordinator"
[ -r "$SCRIPT_DIR/../../../phase4-coordinator/dist/lib/c2c_runtime_proof.py" ] ||
  fail "shared runtime proof helper is missing or unreadable"

grep -q 'rm -f "${COORD_REMOTE_CONFIG_TMP:-}"' "$DEPLOY_SH" ||
  fail "EXIT trap does not clean installed coordinator config temp copy"
grep -q 'rm -f "${COORD_REMOTE_OVERLAY_TMP:-}"' "$DEPLOY_SH" ||
  fail "EXIT trap does not clean installed coordinator overlay temp copy"
grep -q 'rm -f "${COORD_EFFECTIVE_CONFIG_TMP:-}"' "$DEPLOY_SH" ||
  fail "EXIT trap does not clean effective coordinator config temp copy"

grep -qF 'check-production-exceptions.py' "$DEPLOY_SH" ||
  fail "gateway deploy does not invoke the #615 exception gate"
grep -qF 'gate --mode=deploy' "$DEPLOY_SH" ||
  fail "gateway deploy missing exception deploy gate mode"
# Exception gate must appear before SKIP_C2_CHECK refusal so the old opt-out
# cannot suppress registered-row enforcement or the C2 credential proof.
exc_line="$(grep -nF 'check-production-exceptions.py' "$DEPLOY_SH" | head -n1 | cut -d: -f1)"
skip_line="$(grep -nF 'SKIP_C2_CHECK=1 is no longer supported' "$DEPLOY_SH" | head -n1 | cut -d: -f1)"
[ -n "$exc_line" ] && [ -n "$skip_line" ] && [ "$exc_line" -lt "$skip_line" ] ||
  fail "exception gate must run before SKIP_C2_CHECK refusal (exc=$exc_line skip=$skip_line)"
if grep -qF 'skipping timer/header assertions' "$DEPLOY_SH"; then
  fail "deploy script still advertises a SKIP_C2_CHECK timer/header bypass"
fi

echo "PASS: gateway deploy C2 precheck reads installed VPS config by default"
