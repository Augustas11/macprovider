#!/usr/bin/env bash
# Regression: aa_install_helpers must ship EVERY catalog-verifier-bundle entry
# to Pearl. Real `ssh` reads its stdin even when the remote command does not,
# so an SSH call inside a `while read ... done < manifest` loop swallows the
# rest of the manifest (2026-09-23 weekly renewal: only catalog-release.py was
# shipped, and the under-lock continuity-check died on the missing
# openrouter_pricing_engine.py). The fake SSH below drains stdin like ssh does.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/scripts"
T="$(mktemp -d)"
LOCK_DIRS=""
cleanup() { rm -rf "$T"; for d in $LOCK_DIRS; do rm -rf "$d"; done; }
trap cleanup EXIT

fail() { echo "[test-autotune-install-helpers] FAIL: $*" >&2; exit 1; }
log() { :; }
fatal() { echo "fatal: $*" >&2; exit 1; }
PEARL_SSH="pearl.test"

# Runs the remote command locally, then drains stdin as real ssh would.
SSH() {
  local cmd="$1" rc=0
  cmd="${cmd//chown root:root/:}"
  bash -c "$cmd" || rc=$?
  cat >/dev/null
  return "$rc"
}

# shellcheck source=scripts/lib/autotune-activate.sh
. "$SCRIPT_DIR/lib/autotune-activate.sh"

aa_install_helpers </dev/null
LOCK_DIRS="$LOCK_HELPER_DIR"

count=0
while IFS= read -r entry || [ -n "$entry" ]; do
  case "$entry" in '#'*|'') continue ;; esac
  count=$((count + 1))
  [ -f "$LOCK_HELPER_DIR/$entry" ] || fail "bundle entry $entry was not shipped"
  cmp -s "$REPO_ROOT/$entry" "$LOCK_HELPER_DIR/$entry" || fail "bundle entry $entry differs from the reviewed copy"
done < "$SCRIPT_DIR/catalog-verifier-bundle.txt"
[ "$count" -ge 2 ] || fail "manifest parse found $count entries"
[ "$CONTINUITY_VERIFIER" = "$LOCK_HELPER_DIR/scripts/catalog-release.py" ] || fail "continuity verifier path"
python3 -I "$CONTINUITY_VERIFIER" --help >/dev/null || fail "shipped catalog-release.py cannot import its dependencies"

echo "[test-autotune-install-helpers] ok: all $count verifier bundle entries shipped and importable"
