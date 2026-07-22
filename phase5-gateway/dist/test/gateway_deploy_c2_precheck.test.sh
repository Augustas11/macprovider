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

grep -q "validating installed Pearl config: .*sha256=" "$DEPLOY_SH" ||
  fail "deploy script does not log installed config SHA-256"

grep -q 'cat '"'"'\$GATEWAY_REMOTE_CONFIG'"'" "$DEPLOY_SH" ||
  fail "deploy script does not read installed Pearl gateway config over SSH"

local_count=$(grep -c 'bash "$CHECK_SCRIPT" "$COORD_CONFIG" "$GATEWAY_CONFIG"' "$DEPLOY_SH" || true)
if [ "$local_count" != "1" ]; then
  fail "local GATEWAY_CONFIG C2 path should appear exactly once inside --dry-run-local, got $local_count"
fi

grep -q 'bash "$CHECK_SCRIPT" "$COORD_CONFIG" "$GATEWAY_REMOTE_CONFIG_TMP"' "$DEPLOY_SH" ||
  fail "production C2 path does not validate the installed Pearl config copy"

grep -qF 'check-production-exceptions.py' "$DEPLOY_SH" ||
  fail "gateway deploy does not invoke the #615 exception gate"
grep -qF 'gate --mode=deploy' "$DEPLOY_SH" ||
  fail "gateway deploy missing exception deploy gate mode"
# Exception gate must appear before SKIP_C2_CHECK branching so the opt-out
# cannot suppress registered-row enforcement.
exc_line="$(grep -nF 'check-production-exceptions.py' "$DEPLOY_SH" | head -n1 | cut -d: -f1)"
skip_line="$(grep -nF 'elif [ "${SKIP_C2_CHECK:-0}" = "1" ]' "$DEPLOY_SH" | head -n1 | cut -d: -f1)"
[ -n "$exc_line" ] && [ -n "$skip_line" ] && [ "$exc_line" -lt "$skip_line" ] ||
  fail "exception gate must run before SKIP_C2_CHECK branch (exc=$exc_line skip=$skip_line)"

echo "PASS: gateway deploy C2 precheck reads installed VPS config by default"
