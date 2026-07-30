#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_SH="$SCRIPT_DIR/../deploy-pearl-vps.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bash -n "$DEPLOY_SH"

grep -q 'CONFIG_MODE="${CONFIG_MODE:-preserve-live}"' "$DEPLOY_SH" ||
  fail "deploy script must default CONFIG_MODE to preserve-live"

grep -q 'ALLOW_CONFIG_DRIFT=1 is no longer a safe deploy bypass' "$DEPLOY_SH" ||
  fail "deploy script must reject broad ALLOW_CONFIG_DRIFT=1"

grep -q 'LIVE_COORDINATOR_CONFIG_TMP=.*macprovider-coordinator-live-config' "$DEPLOY_SH" ||
  fail "preserve-live mode must read Pearl live coordinator config into a temp validation copy"

grep -q 'sanitize_live_config_for_local_validation < "$LIVE_COORDINATOR_CONFIG_RAW_TMP" > "$LIVE_COORDINATOR_CONFIG_TMP"' "$DEPLOY_SH" ||
  fail "live coordinator config temp copy must be sanitized before local validation"

sanitizer_tmp="$(mktemp)"
trap 'rm -f "$sanitizer_tmp"' EXIT
awk 'f && /^print_config_drift_diff\(\) \{/{exit} /^redact_dsn\(\) \{/{f=1} f{print}' "$DEPLOY_SH" > "$sanitizer_tmp"
# shellcheck disable=SC1090
. "$sanitizer_tmp"
sanitized_sample="$(sanitize_live_config_for_local_validation <<'EOF'
auth:
  operator_key: |
    block-top-level-secret
  api_secret: plain-top-level-secret
    plain-top-level-continuation
  quoted_secret: "quoted-top-level-secret
    quoted-top-level-continuation"
  gateway_service_token: env:COORDINATOR_SERVICE_TOKEN
    env-token-continuation
  operator_keys:
    alice: inline-named-operator-secret
    bob: env:BOB_OPERATOR_KEY
      env-operator-continuation
    carol: >
      block-named-operator-secret
    charlie: plain-operator-secret
      plain-operator-continuation
    dave: "quoted-operator-secret
      quoted-operator-continuation"
    erin: 'single-quoted-operator-secret
      single-quoted-operator-continuation'
tier2:
  catalog_public_key: public-ed25519-key
referrals:
  hmac_keys:
    current: inline-referral-hmac-secret
    next: env:REFERRAL_HMAC_KEY
      env-referral-continuation
    future: |
      block-referral-hmac-secret
    later: plain-referral-hmac-secret
      plain-referral-hmac-continuation
    after: "quoted-referral-hmac-secret
      quoted-referral-hmac-continuation"
stats:
  onboarding_postgres_dsn: postgres://writer:plaintext@db.example/macprovider
EOF
)"
case "$sanitized_sample" in
  *'operator_key: <MASKED>'*) ;;
  *) fail "sanitizer must mask inline secret-shaped keys" ;;
esac
case "$sanitized_sample" in
  *'gateway_service_token: env:COORDINATOR_SERVICE_TOKEN'*) ;;
  *) fail "sanitizer must preserve env:NAME references for runtime proof" ;;
esac
case "$sanitized_sample" in
  *'alice: <MASKED>'*'bob: env:BOB_OPERATOR_KEY'*) ;;
  *) fail "sanitizer must mask inline auth.operator_keys children and preserve env children" ;;
esac
case "$sanitized_sample" in
  *'catalog_public_key: public-ed25519-key'*) ;;
  *) fail "sanitizer must preserve public catalog key required for catalog verification" ;;
esac
case "$sanitized_sample" in
  *'current: <MASKED>'*'next: env:REFERRAL_HMAC_KEY'*) ;;
  *) fail "sanitizer must mask inline referrals.hmac_keys children and preserve env children" ;;
esac
case "$sanitized_sample" in
  *'onboarding_postgres_dsn: <MASKED>'*) ;;
  *) fail "sanitizer must mask inline DSN fields" ;;
esac
case "$sanitized_sample" in
  *block-top-level-secret*|*plain-top-level-secret*|*plain-top-level-continuation*|*quoted-top-level-secret*|*quoted-top-level-continuation*|*env-token-continuation*|*inline-named-operator-secret*|*env-operator-continuation*|*block-named-operator-secret*|*plain-operator-secret*|*plain-operator-continuation*|*quoted-operator-secret*|*quoted-operator-continuation*|*single-quoted-operator-secret*|*single-quoted-operator-continuation*|*inline-referral-hmac-secret*|*env-referral-continuation*|*block-referral-hmac-secret*|*plain-referral-hmac-secret*|*plain-referral-hmac-continuation*|*quoted-referral-hmac-secret*|*quoted-referral-hmac-continuation*|*plaintext*) fail "sanitizer leaked inline secret material" ;;
esac
normalized_sample="$(printf '%s\n' "$sanitized_sample" | normalize_yaml)"
case "$normalized_sample" in
  *public-ed25519-key*|*inline-named-operator-secret*|*env-operator-continuation*|*block-named-operator-secret*|*plain-operator-secret*|*plain-operator-continuation*|*quoted-operator-secret*|*quoted-operator-continuation*|*single-quoted-operator-secret*|*single-quoted-operator-continuation*|*inline-referral-hmac-secret*|*env-referral-continuation*|*block-referral-hmac-secret*|*plain-referral-hmac-secret*|*plain-referral-hmac-continuation*|*quoted-referral-hmac-secret*|*quoted-referral-hmac-continuation*) fail "drift normalizer leaked key material" ;;
esac
case "$normalized_sample" in
  *'catalog_public_key: <MASKED>'*) ;;
  *) fail "drift normalizer must mask public-key-shaped values before diff output" ;;
esac
case "$normalized_sample" in
  *'alice: <MASKED>'*) ;;
  *) fail "drift normalizer must mask auth.operator_keys children before diff output" ;;
esac
case "$normalized_sample" in
  *'current: <MASKED>'*) ;;
  *) fail "drift normalizer must mask referrals.hmac_keys children before diff output" ;;
esac

grep -q 'DEPLOY_CONFIG="$LIVE_COORDINATOR_CONFIG_TMP"' "$DEPLOY_SH" ||
  fail "preserve-live mode must validate against the live coordinator config copy"
grep -q 'LIVE_COORDINATOR_CONFIG_RAW_TMP=' "$DEPLOY_SH" &&
  grep -q 'sanitize_live_config_for_local_validation < "$LIVE_COORDINATOR_CONFIG_RAW_TMP" > "$LIVE_COORDINATOR_CONFIG_TMP"' "$DEPLOY_SH" ||
  fail "preserve-live mode must keep separate raw install input and sanitized validation config"

stats_guard_line=$(grep -nF 'assert_stats_required_matches_effective_config' "$DEPLOY_SH" | tail -n1 | cut -d: -f1)
deploy_config_line=$(grep -nF 'DEPLOY_CONFIG="$LIVE_COORDINATOR_CONFIG_TMP"' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
upload_line=$(grep -nF '$SCP "$BINARY"' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
[ -n "$stats_guard_line" ] && [ -n "$deploy_config_line" ] && [ -n "$upload_line" ] &&
  [ "$deploy_config_line" -lt "$stats_guard_line" ] &&
  [ "$stats_guard_line" -lt "$upload_line" ] ||
  fail "STATS_REQUIRED guard must run after effective config selection and before deploy uploads"

grep -q 'rm -f "${LIVE_COORDINATOR_CONFIG_TMP:-}"' "$DEPLOY_SH" ||
  fail "EXIT trap must clean the sanitized live coordinator config temp copy"
grep -q 'rm -f "${LIVE_COORDINATOR_CONFIG_RAW_TMP:-}"' "$DEPLOY_SH" ||
  fail "EXIT trap must clean the raw live coordinator config temp copy"

grep -q 'CONFIG_MODE=preserve-live — not uploading tracked coordinator.yaml' "$DEPLOY_SH" ||
  fail "preserve-live mode must not upload tracked coordinator.yaml"

grep -q 'CONFIG_MODE=preserve-live — skipping coordinator.yaml backup because no config overwrite will occur' "$DEPLOY_SH" ||
  fail "preserve-live mode must not create overwrite-oriented coordinator.yaml backups"

grep -q "if \\[ '\\\$CONFIG_MODE' = 'apply-tracked' \\]; then" "$DEPLOY_SH" ||
  fail "remote install must guard coordinator.yaml replacement on CONFIG_MODE=apply-tracked"

grep -q 'install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.yaml /opt/macprovider/coordinator.yaml' "$DEPLOY_SH" ||
  fail "apply-tracked mode must retain the explicit coordinator.yaml install path"

install_line=$(grep -nF 'install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.yaml /opt/macprovider/coordinator.yaml' "$DEPLOY_SH" | tail -n1 | cut -d: -f1)
guard_line=$(grep -nF "if [ '\$CONFIG_MODE' = 'apply-tracked' ]; then" "$DEPLOY_SH" | tail -n1 | cut -d: -f1)
[ -n "$install_line" ] && [ -n "$guard_line" ] ||
  fail "could not locate coordinator.yaml install guard or install line"
[ "$guard_line" -lt "$install_line" ] && [ $((install_line - guard_line)) -le 2 ] ||
  fail "coordinator.yaml install is not immediately guarded by CONFIG_MODE=apply-tracked"

grep -q 'CONFIG_MODE=apply-tracked may install tracked coordinator.yaml only when it already matches live' "$DEPLOY_SH" ||
  fail "apply-tracked drift path must fail closed instead of recommending ALLOW_CONFIG_DRIFT"

grep -q 'CONFIG_MODE=apply-tracked requires exact live/tracked coordinator.yaml byte equality' "$DEPLOY_SH" ||
  fail "apply-tracked mode must require exact live/tracked config hashes before install"

echo "PASS: coordinator deploy preserves live config by default and refuses broad drift override"
