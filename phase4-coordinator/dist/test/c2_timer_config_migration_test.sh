#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MIGRATE="$DIST_DIR/c2-timer-config-migration.py"
CHECK_SH="$DIST_DIR/check-deploy-config.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed" >&2; exit 0; }
[ -x "$MIGRATE" ] || fail "missing executable migration helper: $MIGRATE"
[ -x "$CHECK_SH" ] || fail "missing executable C2 gate: $CHECK_SH"

wd="$(mktemp -d -t c2-timer-config-migration-test.XXXXXX)"
trap 'rm -rf "$wd"' EXIT

HEX64=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
HEX64B=fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210

cat > "$wd/live.yaml" <<EOF
auth:
  operator_key: "$HEX64"
  gateway_service_token: "$HEX64B"
  require_provider_tokens: true
  allow_tokenless_provisional_bootstrap: true
referrals:
  require_for_registration: true
  campaign: prebeta_test
  policy_version: v1
  current_key_id: current
  hmac_keys:
    current: inline-referral-secret-that-is-long-enough
stats:
  reader_dsn: postgres://reader:secret-pass@db.example/macprovider
pool:
  heartbeat_interval_s: 30
  heartbeat_miss_threshold_s: 90
  warmup_gate_enabled: false
routing:
  request_timeout_s: 280
provider_http:
  timeout_s: 300
EOF

cat > "$wd/tracked.yaml" <<EOF
routing:
  request_timeout_s: 900
provider_http:
  timeout_s: 900
EOF

cat > "$wd/gateway.yaml" <<EOF
coordinator:
  operator_key: "$HEX64"
  service_token: "$HEX64B"
timeouts:
  coordinator_request_seconds: 300
  coordinator_header_timeout_seconds: 960
  coordinator_admission_seconds: 120
  stream_ceiling_max_seconds: 900
  non_stream_request_seconds: 960
EOF

python3 "$MIGRATE" "$wd/live.yaml" "$wd/tracked.yaml" > "$wd/migrated.yaml"
grep -q 'request_timeout_s: 900' "$wd/migrated.yaml" || fail "request_timeout_s was not raised to 900"
grep -q 'timeout_s: 900' "$wd/migrated.yaml" || fail "provider_http.timeout_s was not raised to 900"
grep -q 'current: inline-referral-secret' "$wd/migrated.yaml" ||
  fail "migration did not preserve unrelated inline referral secret"
grep -q 'reader_dsn: postgres://reader:secret-pass@db.example/macprovider' "$wd/migrated.yaml" ||
  fail "migration did not preserve unrelated inline stats DSN"
if grep -Eq '(<MASKED>|postgres(ql)?://[^[:space:]]+:\*\*\*@)' "$wd/migrated.yaml"; then
  fail "migration output contains redaction sentinel from a validation copy"
fi

cat > "$wd/noop-overlay.yaml" <<'EOF'
# comment must survive an unchanged overlay migration
pool:
  warmup_gate_enabled: false
EOF
python3 "$MIGRATE" --only-existing "$wd/noop-overlay.yaml" "$wd/tracked.yaml" > "$wd/noop-overlay.out.yaml"
cmp -s "$wd/noop-overlay.yaml" "$wd/noop-overlay.out.yaml" ||
  fail "unchanged overlay migration should preserve bytes and remain inactive"

if bash "$CHECK_SH" "$wd/live.yaml" "$wd/gateway.yaml" >/tmp/c2-timer-live.out 2>&1; then
  fail "unmigrated live 280/300 config unexpectedly passed C2"
fi
grep -q 'request_timeout_s (280) is BELOW gateway stream_ceiling_max_seconds (900)' /tmp/c2-timer-live.out ||
  fail "unmigrated live output did not identify request wall violation"

bash "$CHECK_SH" "$wd/migrated.yaml" "$wd/gateway.yaml" >/tmp/c2-timer-migrated.out 2>&1 ||
  { sed 's/^/  | /' /tmp/c2-timer-migrated.out >&2; fail "migrated config did not pass C2 gate"; }

echo "PASS: C2 timer field-scoped migration raises documented Pearl 280/300 posture to C2-safe 900/900"
