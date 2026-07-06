#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_SH="$SCRIPT_DIR/../deploy-pearl-vps.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bash -n "$DEPLOY_SH"

grep -q 'REMOTE_GATEWAY_DB_PATH="$(read_gateway_db_path_from_file "$GATEWAY_REMOTE_CONFIG_TMP")"' "$DEPLOY_SH" ||
  fail "deploy script does not derive DB path from installed config"

if grep -q 'DB=/var/lib/macprovider/gateway.db' "$DEPLOY_SH"; then
  fail "deploy script still snapshots hardcoded /var/lib/macprovider/gateway.db"
fi

grep -q 'DB=.*REMOTE_GATEWAY_DB_PATH' "$DEPLOY_SH" ||
  fail "remote snapshot block does not use derived REMOTE_GATEWAY_DB_PATH"

grep -Fq 'sudo rm -f $REMOTE_GATEWAY_DB_PATH-wal $REMOTE_GATEWAY_DB_PATH-shm' "$DEPLOY_SH" ||
  fail "rollback recipe does not remove WAL/SHM for derived DB path"

grep -q 'sudo install -o macprovider -g macprovider -m 0600 .*REMOTE_GATEWAY_DB_PATH' "$DEPLOY_SH" ||
  fail "rollback recipe does not restore derived DB path"

echo "PASS: gateway deploy snapshot/rollback uses installed storage.db_path"
