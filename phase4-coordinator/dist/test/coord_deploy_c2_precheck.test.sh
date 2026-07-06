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

grep -q "validating installed Pearl gateway config: .*sha256=" "$DEPLOY_SH" ||
  fail "deploy script does not log installed gateway config SHA-256"

grep -q 'cat '"'"'\$GATEWAY_REMOTE_CONFIG'"'" "$DEPLOY_SH" ||
  fail "deploy script does not read installed Pearl gateway config over SSH"

local_count=$(grep -c 'bash "$CHECK_SCRIPT" "$CONFIG" "$GATEWAY_CONFIG"' "$DEPLOY_SH" || true)
if [ "$local_count" != "1" ]; then
  fail "local GATEWAY_CONFIG C2 path should appear exactly once inside --dry-run-local, got $local_count"
fi

grep -q 'bash "$CHECK_SCRIPT" "$CONFIG" "$GATEWAY_REMOTE_CONFIG_TMP"' "$DEPLOY_SH" ||
  fail "production C2 path does not validate the installed Pearl gateway config copy"

grep -q 'rm -f "${GATEWAY_REMOTE_CONFIG_TMP:-}"' "$DEPLOY_SH" ||
  fail "EXIT trap does not clean installed gateway config temp copy"

echo "PASS: coordinator deploy C2 precheck reads installed VPS gateway config by default"
