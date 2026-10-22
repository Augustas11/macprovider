#!/usr/bin/env bash
# shellcheck disable=SC2034
# Recover the designated disconnected signed Air 1.8.258 onto released 1.8.260,
# then persist its qualified qwen3-8b adoption after a provider-attributed proof.
# Usage: scripts/ops/air-provider.sh status | next [--run]
# Private ops.env supplies AIR_SSH, AIR_INSTALL_DIR, AIR_CONFIG, AIR_JOURNAL,
# AIR_STATUS_PORT, AIR_PROVIDER_SHA256 and AIR_HANDOFF_SHA256. The fleet buyer runner stays active.
# No new binary is built; no coordinator configuration is changed.
set -euo pipefail
OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_NAME=air-provider
. "$OPS_DIR/lib/common.sh"
. "$OPS_DIR/lib/published-provider-identity.sh"
OPS_SCOPE=air-qwen8-adoption
PROFILE=air-qwen8-adoption
VERSION=1.8.260
MODEL=qwen3-8b
HELPER="$OPS_DIR/lib/qwen-provider-transaction.py"
PROBE="$OPS_DIR/lib/studio-owner-pin-probe.py"
RUNNER_HELPER="$OPS_DIR/lib/buyer-runner-target.py"
RUNNER_JOURNAL=/var/lib/macprovider-ops/air-qwen8-runner.json

q() { [[ "$1" =~ ^[A-Za-z0-9._/@:+-]+$ ]] || refuse "unsafe Air argument"; printf "'%s'" "$1"; }
settings() {
  local name
  for name in AIR_SSH AIR_INSTALL_DIR AIR_CONFIG AIR_JOURNAL AIR_STATUS_PORT AIR_PROVIDER_SHA256 AIR_HANDOFF_SHA256; do
    [ -n "${!name:-}" ] || refuse "$name is required"
    q "${!name}" >/dev/null
  done
  [ "$AIR_SSH" != local ] || refuse "Air operations require the designated SSH host"
  [[ "$AIR_PROVIDER_SHA256" =~ ^[0-9a-f]{64}$ ]] || refuse "invalid Air provider binding"
  [[ "$AIR_HANDOFF_SHA256" =~ ^[0-9a-f]{64}$ ]] || refuse "invalid written Air handoff binding"
  [[ "$AIR_STATUS_PORT" =~ ^[0-9]+$ ]] || refuse "invalid Air status port"
  for name in AIR_INSTALL_DIR AIR_CONFIG AIR_JOURNAL; do
    [[ "${!name}" = /* ]] && [[ "${!name}" != *'/../'* ]] || refuse "Air paths must be absolute and canonical"
  done
  export STUDIO_SSH="$AIR_SSH" STUDIO_STATUS_PORT="$AIR_STATUS_PORT"
  [ -z "${AIR_SSH_KEY:-}" ] || export STUDIO_SSH_KEY="$AIR_SSH_KEY"
  # common.sh has already exported the private profile. Nested entrypoints
  # must not load its Studio defaults over this operation's exact Air target.
  export MACPROVIDER_OPS_ENV=/dev/null
}

remote_cli() {
  local args="" item
  for item in "$AIR_INSTALL_DIR/macprovider-cli" "$@"; do args="$args $(q "$item")"; done
  studio_ssh "$args"
}

helper() {
  local args="" item
  for item in "$@"; do args="$args $(q "$item")"; done
  studio_ssh "python3 - $args" < "$HELPER"
}

runner() {
  local command="$1" provider args
  # Read identity from the serving Air, never from arbitrary enrollment input.
  remote_cli status --json --config "$AIR_CONFIG" > "$OPS_TMP_DIR/runner-air-status.json" || return 6
  provider="$(json_field "$OPS_TMP_DIR/runner-air-status.json" 'd["provider_id"]')"
  [ "$(printf '%s' "$provider" | shasum -a 256 | awk '{print $1}')" = "$AIR_PROVIDER_SHA256" ] || return 6
  args="$command --path /opt/malibu-buyer-runner/targets.json --journal $RUNNER_JOURNAL --provider-id $(q "$provider") --model $MODEL --slots 4"
  pearl_ssh "python3 - $args" < "$RUNNER_HELPER"
}

probe() {
  studio_ssh "python3 - --install-dir $(q "$AIR_INSTALL_DIR") --config $(q "$AIR_CONFIG") --journal $(q "$AIR_JOURNAL.identity-probe") --port $(q "$AIR_STATUS_PORT") --label live.malibu.provider" < "$PROBE" > "$OPS_TMP_DIR/air-probe.json"
  python3 - "$OPS_TMP_DIR/air-probe.json" "$AIR_PROVIDER_SHA256" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
if d.get("hardware_model") != "Mac15,12" or d["status"].get("provider_id_sha256") != sys.argv[2]:
    raise SystemExit("designated Air identity mismatch")
if d["status"].get("lifecycle.operator_paused") is True:
    raise SystemExit("operator pause takes precedence")
PY
}

signed_identity() {
  published_provider_identity_ok "$1" "$(< "$OPS_TMP_DIR/air-probe.json")" "$AIR_INSTALL_DIR"
}

gather() {
  settings
  # A missing controller result is not permission to adopt a model over an
  # interrupted detached payload swap. Preserve its backup/log for recovery.
  if marker_done "cli-release-$VERSION" air_recovery_dispatch; then
    local payload_result
    local payload_stage
    payload_stage="$(marker_field "cli-release-$VERSION" air_recovery_dispatch 'd.get("stage")')"
    q "$payload_stage" >/dev/null
    payload_result=""
    if [ "$(marker_field "cli-release-$VERSION" air_recovery_result 'd.get("stage")')" = "$payload_stage" ] &&
       [ "$(marker_field "cli-release-$VERSION" air_recovery_result 'd.get("provider_id_sha256")')" = "$AIR_PROVIDER_SHA256" ]; then
      case "$(marker_field "cli-release-$VERSION" air_recovery_result 'd.get("action")')" in
        recover-air) payload_result="$(marker_field "cli-release-$VERSION" air_recovery_result 'd.get("exit_code")')" ;;
        restore-air) [ "$(marker_field "cli-release-$VERSION" air_recovery_result 'd.get("exit_code")')" != 5 ] || payload_result=5 ;;
      esac
    fi
    case "$payload_result" in
      0|4|5) ;;
      *)
        payload_result="$(studio_ssh "cat $(q "$payload_stage/result.restored") 2>/dev/null || cat $(q "$payload_stage/result") 2>/dev/null" || true)" ;;
    esac
    # A terminal file is published before the detached process drops its lock.
    # Never overlap adoption with even that final shutdown window.
    if studio_ssh 'p=$(cat "$HOME/.macprovider-canary-swap.lock/pid" 2>/dev/null) && kill -0 "$p" 2>/dev/null'; then
      payload_result=""
    fi
    case "$payload_result" in
      0|4|5) ;;
      *) set_next payload_recovery mutate "Restore the authenticated signed Air incumbent after interruption" "scripts/ops/air-provider.sh _restore-payload"; return ;;
    esac
  fi
  # Recovery must remain available without a running provider or market feeds.
  helper inspect --journal "$AIR_JOURNAL" > "$OPS_TMP_DIR/air-journal.json" || {
    set_next recovery blocked "Inspect the existing Air journal" "" "journal cannot be authenticated"; return;
  }
  local phase
  phase="$(json_field "$OPS_TMP_DIR/air-journal.json" 'd.get("status")')"
  if [ "$phase" != absent ] && [ "$phase" != restored ] && [ "$phase" != committed ]; then
    set_next restore mutate "Restore the interrupted Air model adoption" "scripts/ops/air-provider.sh _restore"; return
  fi
  probe || { set_next identity blocked "Refuse unidentified Air" "" "exact host/provider/process probe failed"; return; }
  local installed
  installed="$(json_field "$OPS_TMP_DIR/air-probe.json" 'd["installed"]["binary_version"]')"
  signed_identity "$installed" || { set_next signature blocked "Refuse unpublished Air bytes" "" "installed release signature/byte identity failed"; return; }
  if [ "$installed" = 1.8.258 ]; then
    set_next recover mutate "Recover the disconnected signed Air onto released 1.8.260" "scripts/ops/air-provider.sh _recover"
  elif [ "$installed" != "$VERSION" ]; then
    set_next version blocked "Refuse unsupported Air version" "" "only the reviewed 1.8.258 to 1.8.260 transition is supported"
  elif [ "$phase" = committed ]; then
    target_ready || { set_next readiness blocked "Inspect committed Air readiness" "" "committed target no longer matches live four-slot tuple"; return; }
    if runner status > "$OPS_TMP_DIR/runner.json" && [ "$(json_field "$OPS_TMP_DIR/runner.json" 'd.get("runner_active")')" = true ] && [ "$(json_field "$OPS_TMP_DIR/runner.json" 'd.get("enrollment_matches")')" = true ]; then
      set_next complete "done" "Signed Air serves Qwen3-8B at four slots with paid proof and active buyer runner" ""
    else
      set_next enroll mutate "Enroll the qualified Air target in the active Pearl buyer runner" "scripts/ops/air-provider.sh _enroll"
    fi
  else
    set_next adopt mutate "Adopt the qualified Qwen3-8B model and prove paid service" "scripts/ops/air-provider.sh _adopt"
  fi
  NEXT_DOWNTIME="Air provider restart/model load; no Pearl restart"
}

target_ready() {
  python3 - "$OPS_TMP_DIR/air-probe.json" "$REPO_ROOT/phase3-binary/catalog/autotune/continuous-batching-policy.json" <<'PY'
import hashlib, json, sys
d=json.load(open(sys.argv[1]))["status"]
raw=open(sys.argv[2],"rb").read(); p=json.loads(raw)
rows=[x for x in p["entries"] if x["model_key"]=="qwen3-8b"]
if len(rows)!=1 or rows[0].get("max_served_slots")!=4: raise SystemExit(1)
expected={"binary_version":"1.8.260","model":"qwen3-8b","model_loaded":True,
"network_state":"buyer_serving","coordinator.connected":True,
"continuous_batching.active":True,"continuous_batching.policy.authorized":True,
"continuous_batching.policy.load_status":"live_verified",
"continuous_batching.policy.policy_sha256":hashlib.sha256(raw).hexdigest(),
"continuous_batching.policy.release_id":p["release_id"],
"continuous_batching.policy.tuple_sha256":rows[0]["tuple_sha256"],
"continuous_batching.self_check.served_slots":4,"continuous_batching.scheduler.slots_total":4,
"capacity.max_concurrency":4}
if any(d.get(k)!=v for k,v in expected.items()): raise SystemExit(1)
PY
}

recover() {
  probe && signed_identity 1.8.258 || refuse "Air incumbent signed identity changed"
  export AIR_RECOVERY_PROVIDER_SHA256="$AIR_PROVIDER_SHA256" AIR_RECOVERY_CONFIG="$AIR_CONFIG"
  export AIR_RECOVERY_BINARY_SHA256="$BINARY_SHA" CANARY_INSTALL_DIR="$AIR_INSTALL_DIR"
  AIR_RECOVERY_CONFIG_SHA256="$(json_field "$OPS_TMP_DIR/air-probe.json" 'd["config_sha256"]')"
  export AIR_RECOVERY_CONFIG_SHA256
  export CANARY_RUNNER_STOP_CMD=none CANARY_RUNNER_START_CMD=none
  "$OPS_DIR/canary-swap.sh" recover-air --version "$VERSION"
}

restore_payload() {
  export AIR_RECOVERY_PROVIDER_SHA256="$AIR_PROVIDER_SHA256" AIR_RECOVERY_CONFIG="$AIR_CONFIG"
  AIR_RECOVERY_BINARY_SHA256="$(marker_field "cli-release-$VERSION" air_recovery_dispatch 'd.get("incumbent_binary_sha256")')"
  [[ "$AIR_RECOVERY_BINARY_SHA256" =~ ^[0-9a-f]{64}$ ]] || refuse "payload restore lacks authenticated incumbent digest"
  export AIR_RECOVERY_BINARY_SHA256 CANARY_INSTALL_DIR="$AIR_INSTALL_DIR"
  AIR_RECOVERY_CONFIG_SHA256="$(marker_field "cli-release-$VERSION" air_recovery_dispatch 'd.get("config_sha256")')"
  export AIR_RECOVERY_CONFIG_SHA256
  export CANARY_RUNNER_STOP_CMD=none CANARY_RUNNER_START_CMD=none
  local rc=0
  "$OPS_DIR/canary-swap.sh" restore-air --version "$VERSION" || rc=$?
  case "$rc" in 0|5) return 0 ;; *) return 6 ;; esac
}

restore() {
  # The journal binds the recovery executable independently of current feeds.
  helper inspect --journal "$AIR_JOURNAL" > "$OPS_TMP_DIR/air-journal.json"
  helper authenticate-air-recovery --config "$AIR_CONFIG" --journal "$AIR_JOURNAL" --validator "$AIR_INSTALL_DIR/macprovider-cli" --provider-sha256 "$AIR_PROVIDER_SHA256" > "$OPS_TMP_DIR/recovery-identity.json" || return 6
  helper restore --config "$AIR_CONFIG" --journal "$AIR_JOURNAL" --validator "$AIR_INSTALL_DIR/macprovider-cli" || return 6
  helper restart-service --config "$AIR_CONFIG" --validator "$AIR_INSTALL_DIR/macprovider-cli" || return 6
  local attempt baseline
  baseline="$(json_field "$OPS_TMP_DIR/recovery-identity.json" 'd["baseline_model"]')"
  for attempt in $(seq 1 240); do
    if probe >/dev/null 2>&1 && [ "$(json_field "$OPS_TMP_DIR/air-probe.json" 'd["status"]["model"]')" = "$baseline" ] && [ "$(json_field "$OPS_TMP_DIR/air-probe.json" 'd["status"]["network_state"]')" = buyer_serving ]; then
      helper finish-restore --config "$AIR_CONFIG" --journal "$AIR_JOURNAL" || return 6
      return 0
    fi
    sleep 5
  done
  return 6
}

adopt() {
  # Preparation expands only the local warm-swap allowlist. The released CLI
  # retains authority over artifact, hardware, memory and signed catalog inputs.
  probe && signed_identity "$VERSION" || refuse "Air signed identity changed"
  local scratch rec catalog_hash catalog_version rate_version provider pid transaction proof_hash before_pid before_start
  scratch="$(studio_ssh 'umask 077; mktemp -d "$HOME/.config/macprovider/macprovider-qwen-e2e.XXXXXX"')" || return 6
  q "$scratch" >/dev/null || return 6
  rec="$scratch/recommendation.json"
  transaction="$(uuidgen | tr '[:upper:]' '[:lower:]')" || return 6
  # Released signed-catalog preparation verifies/reuses installed bytes and
  # downloads missing bytes; it never copies an isolated lab registry.
  remote_cli models prepare-catalog "$MODEL" --transaction-id "$transaction" --json --config "$AIR_CONFIG" > "$OPS_TMP_DIR/preparation.jsonl" || return 6
  remote_cli status --json --config "$AIR_CONFIG" > "$OPS_TMP_DIR/raw-status.json" || return 6
  catalog_hash="$(json_field "$OPS_TMP_DIR/raw-status.json" 'd["catalog"]["digest"]')"
  catalog_version="$(json_field "$OPS_TMP_DIR/raw-status.json" 'd["catalog"]["release_id"]')"
  provider="$(json_field "$OPS_TMP_DIR/raw-status.json" 'd["provider_id"]')"
  pid="$(json_field "$OPS_TMP_DIR/raw-status.json" 'd["service_instance"]["pid"]')"
  remote_cli autotune --recommend --check-only --installed-only --candidate-models "$MODEL" --json --no-submit-hardware-evidence --config "$AIR_CONFIG" > "$OPS_TMP_DIR/recommendation.json" || return 6
  rate_version="$(json_field "$OPS_TMP_DIR/recommendation.json" 'd["inputs"]["rate_card_version"]')"
  studio_ssh "umask 077; cat > $(q "$rec")" < "$OPS_TMP_DIR/recommendation.json" || return 6
  helper verify-recommendation --profile "$PROFILE" --target "$MODEL" --recommendation "$rec" --binary-version "$VERSION" --catalog-version "$catalog_version" --catalog-hash "$catalog_hash" --rate-card-version "$rate_version" >/dev/null || return 6
  helper prepare --profile "$PROFILE" --config "$AIR_CONFIG" --journal "$AIR_JOURNAL" --validator "$AIR_INSTALL_DIR/macprovider-cli" --transaction-id "$transaction" --binary-version "$VERSION" --provider-id "$provider" --cli-sha256 "$BINARY_SHA" --code-cdhash "$CDHASH" --team-id "$TEAM_ID" --signing-identifier "$SIGNING_IDENTIFIER" --written-handoff-sha256 "$AIR_HANDOFF_SHA256" --baseline-catalog-version "$catalog_version" --baseline-catalog-hash "$catalog_hash" --baseline-pid "$pid" --rate-card-version "$rate_version" --remote-scratch "$scratch" >/dev/null || return 6
  # Air is not enrolled until adoption is proven; the fleet runner stays up.
  helper restart-service --config "$AIR_CONFIG" --validator "$AIR_INSTALL_DIR/macprovider-cli" >/dev/null || return 6
  local attempt
  for attempt in $(seq 1 120); do
    remote_cli models status --config "$AIR_CONFIG" --json >/dev/null 2>&1 && break
    sleep 5
  done
  helper begin-adoption --profile "$PROFILE" --config "$AIR_CONFIG" --journal "$AIR_JOURNAL" --phase adopting_target --target "$MODEL" --recommendation "$rec" --binary-version "$VERSION" --catalog-version "$catalog_version" --catalog-hash "$catalog_hash" --rate-card-version "$rate_version" >/dev/null || return 6
  remote_cli models adopt-recommendation --json --config "$AIR_CONFIG" --recommendation-json "$rec" > "$OPS_TMP_DIR/adoption.jsonl" || return 6
  helper checkpoint --profile "$PROFILE" --config "$AIR_CONFIG" --journal "$AIR_JOURNAL" --phase serving_target --target "$MODEL" --recommendation "$rec" --binary-version "$VERSION" --catalog-version "$catalog_version" --catalog-hash "$catalog_hash" --rate-card-version "$rate_version" >/dev/null || return 6
  remote_cli provider context set 8192 --preflight --config "$AIR_CONFIG" --port "$AIR_STATUS_PORT" >/dev/null || return 6
  helper air-context --action begin --config "$AIR_CONFIG" --journal "$AIR_JOURNAL" >/dev/null || return 6
  remote_cli provider context set 8192 --apply --config "$AIR_CONFIG" --port "$AIR_STATUS_PORT" >/dev/null || return 6
  helper air-context --action finish --config "$AIR_CONFIG" --journal "$AIR_JOURNAL" >/dev/null || return 6
  for attempt in $(seq 1 240); do
    if probe >/dev/null 2>&1 && target_ready; then break; fi
    [ "$attempt" != 240 ] || return 6
    sleep 5
  done
  signed_identity "$VERSION" || return 6
  before_pid="$(json_field "$OPS_TMP_DIR/air-probe.json" 'd["launch"]["pid"]')"
  before_start="$(json_field "$OPS_TMP_DIR/air-probe.json" 'd["launch"]["process_start_us"]')"
  CATALOG_REQUIRE_NATIVE_MTP_FORWARD=false PROBE_MODEL="$MODEL" "$OPS_DIR/catalog-activate.sh" _gateway-proof > "$OPS_TMP_DIR/paid-proof.txt" 2>&1 || return 6
  proof_hash="$(shasum -a 256 "$OPS_TMP_DIR/paid-proof.txt" | awk '{print $1}')"
  probe && signed_identity "$VERSION" && target_ready || return 6
  [ "$(json_field "$OPS_TMP_DIR/air-probe.json" 'd["launch"]["pid"]')" = "$before_pid" ] || return 6
  [ -n "$before_start" ] && [ "$(json_field "$OPS_TMP_DIR/air-probe.json" 'd["launch"]["process_start_us"]')" = "$before_start" ] || return 6
  helper checkpoint --profile "$PROFILE" --config "$AIR_CONFIG" --journal "$AIR_JOURNAL" --phase proof_complete --target "$MODEL" --recommendation "$rec" --binary-version "$VERSION" --catalog-version "$catalog_version" --catalog-hash "$catalog_hash" --rate-card-version "$rate_version" >/dev/null || return 6
  helper commit-adoption --config "$AIR_CONFIG" --journal "$AIR_JOURNAL" --paid-proof-sha256 "$proof_hash" >/dev/null || return 6
  return 0
}

internal() {
  [ "${MACPROVIDER_OPS_ENTRYPOINT:-}" = 1 ] || refuse "internal action requires next --run"
  settings
  case "$1" in
    _recover) recover ;;
    _restore-payload) restore_payload ;;
    _restore) restore ;;
    _enroll)
      helper inspect --journal "$AIR_JOURNAL" > "$OPS_TMP_DIR/air-journal.json"
      [ "$(json_field "$OPS_TMP_DIR/air-journal.json" 'd.get("status")')" = committed ] || refuse "runner enrollment requires committed paid adoption"
      probe && signed_identity "$VERSION" && target_ready || refuse "Air target is not ready for runner enrollment"
      runner enroll ;;
    _adopt)
      if adopt; then return; fi
      log "Air adoption failed; restoring journaled incumbent"
      restore || return 6
      return 5 ;;
    *) refuse "unknown Air action" ;;
  esac
}
ops_main "$@"
