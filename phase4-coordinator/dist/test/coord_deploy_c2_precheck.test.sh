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

local_count=$(grep -c 'bash "$CHECK_SCRIPT" "${CHECK_ARGS\[@\]}"' "$DEPLOY_SH" || true)
if [ "$local_count" != "1" ]; then
  fail "local GATEWAY_CONFIG C2 path should appear exactly once inside --dry-run-local, got $local_count"
fi

grep -q 'bash "$CHECK_SCRIPT" "$DEPLOY_CONFIG" "$GATEWAY_REMOTE_CONFIG_TMP"' "$DEPLOY_SH" ||
  fail "production C2 path does not validate the effective coordinator config with the installed Pearl gateway config copy"
grep -q 'COORDINATOR_REMOTE_OVERLAY="/etc/macprovider/coordinator.pearl-overlays.yaml"' "$DEPLOY_SH" ||
  fail "production C2 path does not look for the Pearl coordinator overlay"
grep -q -- '--config-overlay /etc/macprovider/coordinator.pearl-overlays.yaml' "$SCRIPT_DIR/../macprovider-coordinator.service" ||
  fail "coordinator service unit must load the same Pearl overlay that production C2 validates"
grep -q 'python3 "$MERGE_OVERLAY_SCRIPT" "$DEPLOY_CONFIG" "$COORDINATOR_EFFECTIVE_OVERLAY_TMP"' "$DEPLOY_SH" ||
  fail "production C2 path does not merge live coordinator base + overlay before validation"
grep -q 'C2_TIMER_CONFIG_MIGRATION="${C2_TIMER_CONFIG_MIGRATION:-0}"' "$DEPLOY_SH" ||
  fail "deploy script does not declare the reviewed C2 timer migration switch"
grep -q 'RATE_CARD_CONFIG_MIGRATION_SCRIPT=' "$DEPLOY_SH" ||
  fail "deploy script does not declare the reviewed rate-card config migration helper"
grep -q 'python3 "$C2_TIMER_MIGRATION_SCRIPT" "${LIVE_COORDINATOR_CONFIG_RAW_TMP:-$DEPLOY_CONFIG}" "$CONFIG"' "$DEPLOY_SH" ||
  fail "production C2 path does not render the field-scoped base timer migration from raw config input"
grep -q 'python3 "$C2_TIMER_MIGRATION_SCRIPT" --only-existing "$COORDINATOR_OVERLAY_CONFIG_RAW_TMP" "$CONFIG"' "$DEPLOY_SH" ||
  fail "production C2 path does not render the field-scoped overlay timer migration from raw overlay input"
grep -q 'python3 "$RATE_CARD_CONFIG_MIGRATION_SCRIPT" "$RATE_CARD_MIGRATION_INPUT" "$CONFIG"' "$DEPLOY_SH" ||
  fail "production path does not render the field-scoped base rate-card migration from raw config input"
grep -q 'python3 "$RATE_CARD_CONFIG_MIGRATION_SCRIPT" --only-static-feed-overlays "$RATE_CARD_OVERLAY_MIGRATION_INPUT" "$CONFIG"' "$DEPLOY_SH" ||
  fail "production path does not render the field-scoped overlay rate-card migration from raw overlay input"
grep -q 'reject_redacted_install_candidate "$C2_TIMER_MIGRATED_CONFIG_TMP" "coordinator.yaml"' "$DEPLOY_SH" ||
  fail "production C2 path does not reject redacted base install candidates"
grep -q 'reject_redacted_install_candidate "$C2_TIMER_MIGRATED_OVERLAY_TMP" "coordinator.pearl-overlays.yaml"' "$DEPLOY_SH" ||
  fail "production C2 path does not reject redacted overlay install candidates"
grep -q 'reject_redacted_install_candidate "$RATE_CARD_MIGRATED_CONFIG_TMP" "coordinator.yaml"' "$DEPLOY_SH" ||
  fail "production rate-card path does not reject redacted base install candidates"
grep -q 'reject_redacted_install_candidate "$RATE_CARD_MIGRATED_OVERLAY_TMP" "coordinator.pearl-overlays.yaml"' "$DEPLOY_SH" ||
  fail "production rate-card path does not reject redacted overlay install candidates"
grep -q 'coordinator.c2-timer-migration.yaml' "$DEPLOY_SH" ||
  fail "deploy script does not stage the migrated coordinator config for remote install"
grep -q 'coordinator.rate-card-migration.yaml' "$DEPLOY_SH" ||
  fail "deploy script does not stage the migrated rate-card coordinator config for remote install"
grep -q 'if \[ "${RATE_CARD_MIGRATION_OVERLAY_ACTIVE:-0}" = "1" \]; then' "$DEPLOY_SH" &&
  grep -q 'coordinator.pearl-overlays.rate-card-migration.yaml' "$DEPLOY_SH" ||
  fail "deploy script does not independently stage an overlay-only rate-card migration"
grep -q "if \\[ '\\\${RATE_CARD_MIGRATION_OVERLAY_ACTIVE:-0}' = '1' \\]; then" "$DEPLOY_SH" ||
  fail "remote install does not independently apply an overlay-only rate-card migration"
base_upload_line=$(grep -nF '$SCP "$RATE_CARD_MIGRATED_CONFIG_TMP"' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
overlay_upload_line=$(grep -nF '$SCP "$RATE_CARD_MIGRATED_OVERLAY_TMP"' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
c2_base_upload_line=$(grep -nF '$SCP "$C2_TIMER_MIGRATED_CONFIG_TMP"' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
[ -n "$base_upload_line" ] && [ -n "$overlay_upload_line" ] && [ -n "$c2_base_upload_line" ] &&
  [ "$base_upload_line" -lt "$overlay_upload_line" ] &&
  [ "$c2_base_upload_line" -lt "$overlay_upload_line" ] ||
  fail "overlay migration upload must be independent after base config upload choices"
base_install_line=$(grep -nF 'install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.rate-card-migration.yaml /opt/macprovider/coordinator.yaml' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
overlay_install_line=$(grep -nF 'install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.pearl-overlays.rate-card-migration.yaml /etc/macprovider/coordinator.pearl-overlays.yaml' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
c2_base_install_line=$(grep -nF 'install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.c2-timer-migration.yaml /opt/macprovider/coordinator.yaml' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
[ -n "$base_install_line" ] && [ -n "$overlay_install_line" ] && [ -n "$c2_base_install_line" ] &&
  [ "$base_install_line" -lt "$overlay_install_line" ] &&
  [ "$c2_base_install_line" -lt "$overlay_install_line" ] ||
  fail "overlay migration install must be independent after base config install choices"

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
grep -q 'python3 - coordinator-deploy' "$DEPLOY_SH" ||
  fail "production C2 path does not attest future coordinator state against the running gateway"
[ -r "$SCRIPT_DIR/../lib/c2c_runtime_proof.py" ] ||
  fail "shared runtime proof helper is missing or unreadable"

grep -q 'rm -f "${LIVE_COORDINATOR_CONFIG_RAW_TMP:-}"' "$DEPLOY_SH" ||
  fail "EXIT trap does not clean raw installed coordinator config temp copy"
grep -q 'rm -f "${GATEWAY_REMOTE_CONFIG_TMP:-}"' "$DEPLOY_SH" ||
  fail "EXIT trap does not clean installed gateway config temp copy"
grep -q 'rm -f "${COORDINATOR_OVERLAY_CONFIG_RAW_TMP:-}"' "$DEPLOY_SH" ||
  fail "EXIT trap does not clean raw installed coordinator overlay temp copy"
grep -q 'rm -f "${COORDINATOR_OVERLAY_CONFIG_TMP:-}"' "$DEPLOY_SH" ||
  fail "EXIT trap does not clean installed coordinator overlay temp copy"
grep -q 'rm -f "${DEPLOY_EFFECTIVE_CONFIG_TMP:-}"' "$DEPLOY_SH" ||
  fail "EXIT trap does not clean merged effective coordinator temp copy"
grep -q 'rm -f "${C2_TIMER_MIGRATED_CONFIG_TMP:-}"' "$DEPLOY_SH" ||
  fail "EXIT trap does not clean C2 timer migrated coordinator temp copy"
grep -q 'rm -f "${C2_TIMER_MIGRATED_CONFIG_VALIDATION_TMP:-}"' "$DEPLOY_SH" ||
  fail "EXIT trap does not clean sanitized C2 timer migrated coordinator temp copy"
grep -q 'rm -f "${C2_TIMER_MIGRATED_OVERLAY_TMP:-}"' "$DEPLOY_SH" ||
  fail "EXIT trap does not clean C2 timer migrated overlay temp copy"
grep -q 'rm -f "${C2_TIMER_MIGRATED_OVERLAY_VALIDATION_TMP:-}"' "$DEPLOY_SH" ||
  fail "EXIT trap does not clean sanitized C2 timer migrated overlay temp copy"
grep -q 'rm -f "${RATE_CARD_MIGRATED_CONFIG_TMP:-}"' "$DEPLOY_SH" ||
  fail "EXIT trap does not clean rate-card migrated coordinator temp copy"
grep -q 'rm -f "${RATE_CARD_MIGRATED_CONFIG_VALIDATION_TMP:-}"' "$DEPLOY_SH" ||
  fail "EXIT trap does not clean sanitized rate-card migrated coordinator temp copy"
grep -q 'rm -f "${RATE_CARD_MIGRATED_OVERLAY_TMP:-}"' "$DEPLOY_SH" ||
  fail "EXIT trap does not clean rate-card migrated overlay temp copy"
grep -q 'rm -f "${RATE_CARD_MIGRATED_OVERLAY_VALIDATION_TMP:-}"' "$DEPLOY_SH" ||
  fail "EXIT trap does not clean sanitized rate-card migrated overlay temp copy"

echo "PASS: coordinator deploy C2 precheck reads installed VPS gateway config by default"
