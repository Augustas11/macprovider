#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_SH="$SCRIPT_DIR/../deploy-pearl-vps.sh"
TMP="$(umask 077 && mktemp -d "$SCRIPT_DIR/coordinator-tier2-gate-test.XXXXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

gate_tmp="$TMP/gate.sh"
awk '/^_tier2_migration_gate_remote_script\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$DEPLOY_SH" >"$gate_tmp"
grep -qF '_tier2_migration_gate_remote_script()' "$gate_tmp" ||
  fail "deploy must keep an extractable Tier-2 migration gate"
# shellcheck disable=SC1090
. "$gate_tmp"

ROOT="$TMP/opt/macprovider"

gate_script() {
  _tier2_migration_gate_remote_script | python3 -c '
import sys

root = sys.argv[1]
uid = sys.argv[2]
script = sys.stdin.read()
script = script.replace("ROOT = \"/opt/macprovider\"", f"ROOT = {root!r}")
script = script.replace("REQUIRED_UID = 0", f"REQUIRED_UID = {uid}")
print(script, end="")
' "$ROOT" "$(id -u)"
}

run_gate() {
  sh -c "$(gate_script)"
}

reset_root() {
  rm -rf "$ROOT"
  mkdir -p "$ROOT/autotune/releases/current-release"
}

reset_root
run_gate || fail "absent legacy Tier-2 bridge must allow future single-authority deploy"

reset_root
printf catalog-v1 >"$ROOT/autotune/releases/current-release/tier2-catalog.json"
ln -sfn releases/current-release "$ROOT/autotune/current"
printf catalog-v1 >"$ROOT/tier2-catalog.json"
run_gate || fail "matching legacy bridge and active current release must pass"

reset_root
printf catalog-v1 >"$ROOT/autotune/releases/current-release/tier2-catalog.json"
ln -sfn releases/current-release "$ROOT/autotune/current"
printf catalog-v2 >"$ROOT/tier2-catalog.json"
if run_gate >/dev/null 2>&1; then
  fail "mismatched legacy bridge must abort before mutation"
fi

reset_root
printf catalog-v1 >"$ROOT/tier2-catalog.json"
if run_gate >/dev/null 2>&1; then
  fail "legacy bridge without active current release must abort before mutation"
fi

reset_root
printf catalog-v1 >"$ROOT/autotune/releases/current-release/tier2-catalog.json"
ln -sfn releases/../../escape "$ROOT/autotune/current"
printf catalog-v1 >"$ROOT/tier2-catalog.json"
if run_gate >/dev/null 2>&1; then
  fail "unsafe current symlink target must abort before mutation"
fi

reset_root
mkdir -p "$ROOT/autotune/releases/nested/release"
printf catalog-v1 >"$ROOT/autotune/releases/nested/release/tier2-catalog.json"
ln -sfn releases/nested/release "$ROOT/autotune/current"
printf catalog-v1 >"$ROOT/tier2-catalog.json"
if run_gate >/dev/null 2>&1; then
  fail "nested current target must abort before mutation"
fi

reset_root
mkdir -p "$ROOT/elsewhere"
printf catalog-v1 >"$ROOT/elsewhere/tier2-catalog.json"
ln -sfn "$ROOT/elsewhere" "$ROOT/autotune/releases/current-release"
ln -sfn releases/current-release "$ROOT/autotune/current"
printf catalog-v1 >"$ROOT/tier2-catalog.json"
if run_gate >/dev/null 2>&1; then
  fail "symlinked release directory must abort before mutation"
fi

reset_root
printf catalog-v1 >"$ROOT/autotune/releases/current-release/tier2-catalog.json"
ln -sfn releases/current-release "$ROOT/autotune/current"
printf catalog-v1 >"$ROOT/tier2-catalog.json"
chmod 0777 "$ROOT/autotune"
if run_gate >/dev/null 2>&1; then
  fail "group/other-writable autotune tree must abort before mutation"
fi

reset_root
printf catalog-v1 >"$ROOT/autotune/releases/current-release/tier2-catalog.json"
ln -sfn releases/current-release "$ROOT/autotune/current"
printf catalog-v1 >"$ROOT/tier2-catalog.json"
ln "$ROOT/tier2-catalog.json" "$ROOT/tier2-catalog.hardlink"
if run_gate >/dev/null 2>&1; then
  fail "hardlinked legacy Tier-2 bridge must abort before mutation"
fi

reset_root
printf catalog-v1 >"$ROOT/autotune/releases/current-release/tier2-catalog.json"
ln -sfn releases/current-release "$ROOT/autotune/current"
ln -s autotune/releases/current-release/tier2-catalog.json "$ROOT/tier2-catalog.json"
if run_gate >/dev/null 2>&1; then
  fail "planted legacy Tier-2 symlink must abort before mutation"
fi

reset_root
printf catalog-v1 >"$ROOT/autotune/releases/current-release/tier2-catalog.json"
ln -sfn releases/current-release "$ROOT/autotune/current"
printf catalog-v1 >"$ROOT/tier2-catalog.json"
ln -s releases/current-release "$ROOT/autotune/current.next"
if run_gate >/dev/null 2>&1; then
  fail "planted current.next symlink must abort before mutation"
fi

reset_root
printf catalog-v1 >"$ROOT/autotune/releases/current-release/tier2-catalog.json"
ln -sfn releases/current-release "$ROOT/autotune/current"
printf catalog-v1 >"$ROOT/tier2-catalog.json"
ln -s releases/current-release "$ROOT/autotune/.previous-target"
if run_gate >/dev/null 2>&1; then
  fail "planted .previous-target symlink must abort before mutation"
fi

echo "PASS: Tier-2 migration gate rejects unsafe or mismatched legacy bridge state"
