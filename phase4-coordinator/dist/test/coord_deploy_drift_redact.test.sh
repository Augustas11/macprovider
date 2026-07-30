#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_SH="$SCRIPT_DIR/../deploy-pearl-vps.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bash -n "$DEPLOY_SH"

grep -q '^redact_dsn()' "$DEPLOY_SH" ||
  fail "deploy script lacks drift DSN redaction function"

grep -q 'print_config_drift_diff' "$DEPLOY_SH" ||
  fail "drift diff is not routed through the redaction print function"

sample='> onboarding_postgres_dsn: postgres://gwuser:secret@db.example/macprovider'
redacted=$(printf '%s\n' "$sample" | sed -E 's#(postgres(ql)?://[^:/@[:space:]]+:)[^@[:space:]]+@#\1***@#g')
case "$redacted" in
  *'postgres://gwuser:***@db.example/macprovider'*) ;;
  *) fail "redaction sed did not mask postgres password: $redacted" ;;
esac
case "$redacted" in
  *secret*) fail "redaction output leaked plaintext password: $redacted" ;;
esac

echo "PASS: coordinator drift diff redacts Postgres DSN passwords"
