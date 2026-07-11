#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_SH="$SCRIPT_DIR/../deploy-pearl-vps.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bash -n "$DEPLOY_SH"

grep -q 'STATIC_SMOKE_DIR=$(umask 077 && mktemp -d -t macprovider-autotune-probe.XXXXXXXX)' "$DEPLOY_SH" ||
  fail "static feed smoke does not use mktemp -d"

grep -q 'rm -rf "${STATIC_SMOKE_DIR:-}"' "$DEPLOY_SH" ||
  fail "EXIT trap does not clean static smoke temp dir"

if grep -q '/tmp/macprovider-autotune-probe' "$DEPLOY_SH"; then
  fail "static feed smoke still writes a predictable /tmp probe path"
fi

grep -q 'verify-directory --directory "$STATIC_SMOKE_DIR"' "$DEPLOY_SH" ||
  fail "static feed smoke does not verify exact hashes and signatures"

grep -q 'cmp -s "$STATIC_EXPECTED" "$STATIC_SMOKE_BODY"' "$DEPLOY_SH" ||
  fail "static feed smoke does not compare served bytes to staged bytes"

echo "PASS: coordinator static feed smoke uses unpredictable cleaned temp dir"
