#!/usr/bin/env bash
# Catalog / continuous-batching / native-MTP activation entry point.
#
# Usage:
#   scripts/ops/catalog-activate.sh status          read-only; one JSON object on stdout,
#                                                   human summary on stderr
#   scripts/ops/catalog-activate.sh next            print the next documented step
#   scripts/ops/catalog-activate.sh next --run      run exactly that one step
#   scripts/ops/catalog-activate.sh next --done STEP --evidence TEXT
#                                                   record an operator-owned step as done
#
# Order (docs/runbooks/native-mtp-enablement.md steps 5, 8, 9;
# docs/runbooks/pearl-coordinator-rollout.md "Catalog activation";
# docs/runbooks/catalog-release-decision-tree.md "Content lane"):
#   1 catalog_verify          committed release passes catalog-release.py verify;
#                             a native-bound release's self-test bank names its release_id
#   2 revocation_slots        native-bound: publish revocations when no signed slot
#                             is served (publish-native-mtp-revocations.sh --deploy)
#   3 nginx_routes            every feed the release binds is routed to the coordinator
#   4 coordinator_native_keys coordinator.yaml autotune native_mtp_* keys + pool canary
#   5 catalog_preflight       catalog-content-release.sh --preflight (read-only)
#   6 catalog_activation      catalog-content-release.sh --deploy (content lane; a pricing
#                             release runs with CATALOG_PRICING_ACK=<the verdict's
#                             pricing_diff_sha256>), or the full deploy-pearl-vps.sh activation
#                             when the gate names another lane. Refused while the canary is
#                             operator-paused: its custody proof and evidence (c) need it
#                             buyer_serving
#   7 canary_bank             native-bound: the coordinator canary holds the release's
#                             self-test bank. A coordinator that reports
#                             native_mtp_canary_bank_reloads on /healthz reloads the bank
#                             with the release (SPEC-031-R033 v0.3.9), so this step only
#                             checks native_mtp_canary_bank_release_id == the release and
#                             native_mtp_canary_bank_sha256 == the SHA-256 of the served
#                             /v1/native-mtp-selftest-bank bytes; one that predates it
#                             read the bank at boot, and the step restarts it before the
#                             activation can be done
#   8 provider_restart        canary/Studio provider reports the new catalog release
#   9 live_probe              provider /v1/status: continuous_batching active;
#                             native_mtp enabled+eligible|active unless explicitly
#                             selecting a CB-only proof below
#  10 gateway_proof           one real buyer request through the gateway that moves the
#                             target provider's active serving-path counter
#                             (CB shared_forward_calls when CB is active);
#                             expires after 24 h
#  11 buyer_serving_e2e       evidence (e) an activation recorded as owed (SPEC-023-R017
#                             5(e)): no connected provider served the newly buyer-serving
#                             model, so the provider release that first serves it owes a
#                             canary restart onto the live release, one buyer request through
#                             the gateway attributed to that canary, and its settlement row.
#                             One ledger entry per model and hash (ops-state
#                             catalog-owed-e2e/), written before the deploy and again from its
#                             output, open until a buyer_serving_e2e record carries the exact
#                             token model=<model_id>@<sha256>; it outlives later releases, and
#                             a malformed entry blocks. Unreadable canary status blocks the
#                             preflight and the activation like an operator pause
#
# Env (or ~/.config/macprovider/ops.env): COORDINATOR_URL, GATEWAY_URL,
# PEARL_SSH (+ PEARL_SSH_IDENTITY/PEARL_SSH_KNOWN_HOSTS for the repo scripts),
# REMOTE_REVOCATION_DIR, STUDIO_SSH, STUDIO_SSH_KEY, STUDIO_STATUS_PORT,
# BUYER_TOKEN_FILE, PROBE_MODEL, CATALOG_REQUIRE_NATIVE_MTP_FORWARD=true (native
# MTP proof) or explicitly false (CB-only live probe), CATALOG_CANARY_* (as
# catalog-content-release.sh),
# CATALOG_PRICING_ACK (the reviewed price table's digest), MACPROVIDER_OPS_OWNER (for --run).
set -euo pipefail
# shellcheck source-path=SCRIPTDIR disable=SC2034  # OPS_NAME/NEXT_* are read by lib/common.sh

OPS_NAME=catalog-activate
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() { sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

AUTOTUNE="phase3-binary/catalog/autotune"
MTP_DOC="docs/runbooks/native-mtp-enablement.md"
ROLLOUT_DOC="docs/runbooks/pearl-coordinator-rollout.md"
TREE_DOC="docs/runbooks/catalog-release-decision-tree.md"
REVOCATION_BATCH_DAYS="${NATIVE_MTP_REVOCATION_DAYS:-14}"
QWEN_NATIVE_MODEL=qwen/qwen3.6-35b-a3b
QWEN_NATIVE_PROFILE=qwen36-native-mtp

qwen_journal_probe() {
  "$OPS_DIR/qwen-opencode-e2e.sh" _catalog-qwen36-journal
}

qwen_intent_probe() {
  "$OPS_DIR/qwen-opencode-e2e.sh" _catalog-qwen36-intent
}

qwen_scratch_probe() {
  "$OPS_DIR/qwen-opencode-e2e.sh" _catalog-qwen36-scratch
}

live_lock_purpose() {
  "$OPS_DIR/live-lock.sh" status 2>/dev/null |
    python3 -c 'import json,sys; print((json.load(sys.stdin).get("lock") or {}).get("purpose", ""))'
}

qwen_native_intent_present() {
  [ -n "${OPS_STATE_DIR:-}" ] || return 1
  local path="$OPS_STATE_DIR/qwen-native-mtp-transaction-intent.json"
  [ -e "$path" ] || [ -L "$path" ]
}

qwen_native_journal_recovered() {
  local probe="$1" scratch_probe="$OPS_TMP_DIR/qwen-recovered-scratch.json"
  ! qwen_native_intent_present || return 1
  [ -n "${QWEN_E2E_JOURNAL:-}" ] || return 1
  qwen_journal_probe > "$probe" 2>/dev/null || return 1
  [ "$(json_field "$probe" 'd.get("profile")')" = "$QWEN_NATIVE_PROFILE" ] &&
    [ "$(json_field "$probe" 'd.get("status")')" = restored ] &&
    [ "$(json_field "$probe" 'd.get("restore_required")')" = false ] &&
    qwen_scratch_probe > "$scratch_probe" 2>/dev/null &&
    [ "$(json_field "$scratch_probe" 'd.get("scratch_absent")')" = true ]
}

reconcile_qwen_restore_lock() {
  [ "${MACPROVIDER_OPS_ENTRYPOINT:-}" = 1 ] && [ -n "${MACPROVIDER_OPS_OWNER:-}" ] ||
    refuse "Qwen restoration lock reconciliation is callable only by catalog next --run"
  [ "$(live_lock_purpose 2>/dev/null || true)" = catalog-activate:qwen_restore ] ||
    refuse "Qwen restoration lock is no longer durable"
  qwen_native_journal_recovered "$OPS_TMP_DIR/qwen-lock-reconcile.json" ||
    refuse "exact native Qwen restoration is not proven complete"
}

# Once the fixed Qwen transaction has armed its remote journal, keep the global
# lock durable until the exact incumbent has restarted and the journal reaches
# restored. An unreadable journal under the restoration purpose fails closed.
release_live_lock() {
  [ -n "$OPS_LOCK_OWNER" ] || return 0
  local owner="$OPS_LOCK_OWNER" probe="$OPS_TMP_DIR/qwen-lock-journal.json" purpose=""
  purpose="$(live_lock_purpose 2>/dev/null || true)"
  if qwen_native_intent_present; then
    if [ "$purpose" != catalog-activate:qwen_restore ]; then
      "$OPS_DIR/live-lock.sh" acquire "$owner" \
        --purpose catalog-activate:qwen_restore >&2 ||
        log "Qwen transaction intent survives; live-ops lock could not be refreshed but will not be released"
    fi
    log "retaining the durable live-ops lock until the Qwen transaction intent is cleared"
    OPS_LOCK_OWNER=""
    return 0
  fi
  if [ "$purpose" = catalog-activate:qwen_restore ]; then
    if ! qwen_native_journal_recovered "$probe"; then
      log "retaining the durable live-ops lock because native Qwen restoration is not proven complete"
      OPS_LOCK_OWNER=""
      return 0
    fi
    OPS_LOCK_OWNER=""
    "$OPS_DIR/live-lock.sh" release "$owner" >&2 || true
    return 0
  fi
  if [ -n "${QWEN_E2E_JOURNAL:-}" ]; then
    if qwen_journal_probe > "$probe" 2>/dev/null; then
      if [ "$(json_field "$probe" 'd.get("profile")')" = "$QWEN_NATIVE_PROFILE" ] &&
         [ "$(json_field "$probe" 'd.get("restore_required")')" = true ]; then
        if [ "$purpose" != catalog-activate:qwen_restore ]; then
          "$OPS_DIR/live-lock.sh" acquire "$owner" \
            --purpose catalog-activate:qwen_restore >&2 ||
            log "Qwen journal is armed; live-ops lock could not be refreshed but will not be released"
        fi
        log "retaining the durable live-ops lock until the Qwen transaction restores GLM"
        OPS_LOCK_OWNER=""
        return 0
      fi
    fi
  fi
  OPS_LOCK_OWNER=""
  "$OPS_DIR/live-lock.sh" release "$owner" >&2 || true
}

acquire_live_lock_for_step() {
  if [ "$NEXT_ID" = qwen_restore ] || [ "$NEXT_ID" = qwen_prejournal_reconcile ]; then
    "$OPS_DIR/live-lock.sh" acquire "$MACPROVIDER_OPS_OWNER" \
      --purpose catalog-activate:qwen_restore >&2
  elif [ "$(live_lock_purpose 2>/dev/null || true)" = catalog-activate:qwen_restore ]; then
    qwen_native_journal_recovered "$OPS_TMP_DIR/qwen-lock-recovered.json" ||
      refuse "durable Qwen restoration lock requires a valid restored native journal"
    "$OPS_DIR/live-lock.sh" acquire "$MACPROVIDER_OPS_OWNER" \
      --purpose catalog-activate:qwen_restore >&2
  else
    "$OPS_DIR/live-lock.sh" acquire "$MACPROVIDER_OPS_OWNER" \
      --purpose "$OPS_NAME:$NEXT_ID" --bind-pid >&2
  fi
}

# Feeds the release binds -> public route. Revocations are keyed by signer.
feed_route() {
  case "$1" in
    autotune-artifacts.json) echo /v1/catalog-artifacts ;;
    autotune-candidates.json) echo /v1/autotune-candidates ;;
    continuous-batching-policy.json) echo /v1/continuous-batching-policy ;;
    demand-rank.json) echo /v1/demand-rank ;;
    rate-card.json) echo /v1/rate-card ;;
    native-mtp-admission.json) echo /v1/native-mtp-admission ;;
    *) echo "" ;;
  esac
}

gather() {
  local main_sha head_sha R native_bound=false bank_rid verify_ok=false qwen_lock_purpose="" qwen_local_intent=false
  main_sha="$(origin_main_sha)"
  head_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  R="$(json_field "$REPO_ROOT/$AUTOTUNE/release.json" 'd["release_id"]')"
  [ -n "$R" ] || die "cannot read $AUTOTUNE/release.json"
  OPS_SCOPE="catalog-$R"

  # A remote Qwen profile journal is authoritative. No catalog step, proof, or
  # activation is allowed to run ahead of restoration.
  qwen_lock_purpose="$(live_lock_purpose 2>/dev/null || true)"
  local qwen_intent_path=""
  [ -z "${OPS_STATE_DIR:-}" ] || qwen_intent_path="$OPS_STATE_DIR/qwen-native-mtp-transaction-intent.json"
  if [ -n "$qwen_intent_path" ] && { [ -e "$qwen_intent_path" ] || [ -L "$qwen_intent_path" ]; }; then
    if ! qwen_intent_probe > "$OPS_TMP_DIR/qwen-intent.json" 2>/dev/null; then
      step qwen_prejournal_reconcile blocked "native transaction intent is malformed or its journal is unreadable"
      set_next qwen_prejournal_reconcile blocked "Recover the Qwen3.6 transaction intent" "" \
        "the durable intent must be reviewed before catalog work can continue"
      return
    fi
    qwen_local_intent=true
    local qwen_intent_journal
    qwen_intent_journal="$(json_field "$OPS_TMP_DIR/qwen-intent.json" 'd.get("journal_path")')"
    if [ -n "${QWEN_E2E_JOURNAL:-}" ] && [ "$QWEN_E2E_JOURNAL" != "$qwen_intent_journal" ]; then
      step qwen_prejournal_reconcile blocked "native transaction intent journal path mismatches configuration"
      set_next qwen_prejournal_reconcile blocked "Recover the Qwen3.6 transaction intent" "" \
        "the durable intent and configured journal must be reviewed before catalog work can continue"
      return
    fi
    export QWEN_E2E_JOURNAL="$qwen_intent_journal"
  fi
  if [ -n "${QWEN_E2E_JOURNAL:-}" ] || [ "$qwen_lock_purpose" = catalog-activate:qwen_restore ]; then
    local qwen_probe="$OPS_TMP_DIR/qwen-journal.json" qwen_restore=false qwen_profile="" qwen_status="" qwen_intent=false qwen_scratch_absent=false
    if [ -n "${QWEN_E2E_JOURNAL:-}" ] && qwen_journal_probe > "$qwen_probe" 2>/dev/null; then
      qwen_restore="$(json_field "$qwen_probe" 'd.get("restore_required")')"
      qwen_profile="$(json_field "$qwen_probe" 'd.get("profile")')"
      qwen_status="$(json_field "$qwen_probe" 'd.get("status")')"
      if [ "$qwen_local_intent" != true ] && ! qwen_intent_probe > "$OPS_TMP_DIR/qwen-intent.json" 2>/dev/null; then
        step qwen_prejournal_reconcile blocked "native transaction intent is malformed or mismatches the journal"
        set_next qwen_prejournal_reconcile blocked "Recover the Qwen3.6 transaction intent" "" \
          "the durable intent and remote journal must be reviewed before catalog work can continue"
        return
      fi
      [ "$(json_field "$OPS_TMP_DIR/qwen-intent.json" 'd.get("status")')" = absent ] || qwen_intent=true
      if [ "$qwen_status" = absent ] && [ "$qwen_restore" = false ]; then
        if [ "$qwen_intent" = true ]; then
          step qwen_prejournal_reconcile pending "clear the interrupted pre-journal Qwen transaction intent"
          set_next qwen_prejournal_reconcile mutate "Reconcile the interrupted pre-journal Qwen transaction" \
            "$OPS_DIR/qwen-opencode-e2e.sh _catalog-qwen36-prejournal-reconcile"
          return
        fi
      fi
      if [ "$qwen_restore" = true ] && [ "$qwen_profile" = "$QWEN_NATIVE_PROFILE" ]; then
        fact qwen_transaction_profile "$qwen_profile"
        fact qwen_restore_required true
        step qwen_restore pending "restore exact signed GLM incumbent before catalog work"
        set_next qwen_restore mutate "Restore GLM from the active Qwen3.6 transaction" \
          "$OPS_DIR/qwen-opencode-e2e.sh _catalog-qwen36-restore"
        NEXT_DOWNTIME="Studio provider buyer traffic is unavailable during the bounded GLM restart and model-load window; Pearl is not restarted"
        return
      fi
      if [ "$qwen_intent" = true ] && [ "$qwen_profile" = "$QWEN_NATIVE_PROFILE" ] &&
         [ "$qwen_status" = restored ] && [ "$qwen_restore" = false ]; then
        step qwen_restore pending "clear the restored Qwen transaction intent before releasing the lock"
        set_next qwen_restore mutate "Finalize the restored Qwen3.6 transaction" \
          "$OPS_DIR/qwen-opencode-e2e.sh _catalog-qwen36-restore"
        return
      fi
      if [ "$qwen_profile" = "$QWEN_NATIVE_PROFILE" ] && [ "$qwen_status" = restored ] &&
         [ "$qwen_restore" = false ]; then
        if qwen_scratch_probe > "$OPS_TMP_DIR/qwen-scratch.json" 2>/dev/null; then
          qwen_scratch_absent="$(json_field "$OPS_TMP_DIR/qwen-scratch.json" 'd.get("scratch_absent")')"
        fi
        if [ "$qwen_scratch_absent" != true ]; then
          step qwen_restore pending "remove the protected Qwen transaction scratch before releasing the lock"
          set_next qwen_restore mutate "Finalize the restored Qwen3.6 transaction" \
            "$OPS_DIR/qwen-opencode-e2e.sh _catalog-qwen36-restore"
          return
        fi
      fi
      if [ "$qwen_lock_purpose" = catalog-activate:qwen_restore ] &&
         { [ "$qwen_profile" != "$QWEN_NATIVE_PROFILE" ] || [ "$qwen_status" != restored ] || [ "$qwen_restore" != false ]; }; then
        fact qwen_restore_required unknown
        step qwen_restore blocked "durable restoration lock lacks a valid recovered native journal"
        set_next qwen_restore blocked "Recover the Qwen3.6 restoration journal" "" \
          "the durable restoration lock prevents all ordinary catalog steps until exact native restoration is proven"
        return
      fi
      if [ "$qwen_lock_purpose" = catalog-activate:qwen_restore ]; then
        fact qwen_restore_required false
        step qwen_lock_reconcile pending "release the recovered durable Qwen restoration lock"
        set_next qwen_lock_reconcile mutate "Reconcile the recovered Qwen restoration lock" \
          "$OPS_DIR/catalog-activate.sh _qwen-lock-reconcile"
        return
      fi
    elif [ "$qwen_lock_purpose" = catalog-activate:qwen_restore ]; then
      fact qwen_restore_required unknown
      step qwen_restore blocked "active Qwen restoration journal is unreadable"
      set_next qwen_restore blocked "Recover the Qwen3.6 restoration journal" "" \
        "the durable restoration lock prevents all ordinary catalog steps until the journal is readable"
      return
    fi
  fi
  fact origin_main_sha "$main_sha"
  fact checkout_is_origin_main "$([ "$head_sha" = "$main_sha" ] && echo true || echo false)"
  fact committed_release_id "$R"
  if [ -n "$(json_field "$REPO_ROOT/$AUTOTUNE/release.json" 'd["feeds"]["native-mtp-admission.json"]["sha256"]')" ]; then
    native_bound=true
  fi
  fact native_bound "$native_bound"
  bank_rid="$(json_field "$REPO_ROOT/$AUTOTUNE/native-mtp-selftest-bank.json" 'd["release_id"]')"
  fact committed_bank_release_id "$bank_rid"
  if MACPROVIDER_REQUIRED_CB_BASELINE=studio-qwen3.6-a3b-v1 python3 "$REPO_ROOT/scripts/catalog-release.py" verify > "$OPS_TMP_DIR/verify.out" 2>&1; then
    verify_ok=true
  fi
  fact catalog_release_verify "$verify_ok"

  # Live coordinator state.
  local base live_rid="" live_status="" uptime="" verified_min=""
  base="$(coordinator_url)"
  if fetch_coordinator_health; then
    uptime="$(json_field "$OPS_TMP_DIR/healthz.json" 'd["uptime_s"]')"
  fi
  fact coordinator_uptime_s "$uptime"
  if [ -n "$base" ] && [ "$(http_get "$base/v1/autotune-release" "$OPS_TMP_DIR/release.json")" = "200" ]; then
    live_rid="$(json_field "$OPS_TMP_DIR/release.json" 'd["release_id"]')"
    live_status="$(json_field "$OPS_TMP_DIR/release.json" 'd["status"]')"
    verified_min="$(json_field "$OPS_TMP_DIR/release.json" 'min(f["verified_at"][:19] + "Z" for f in d["feeds"].values())')"
  fi
  fact live_release_id "$live_rid"
  fact live_release_status "$live_status"
  fact live_feeds_verified_at "$verified_min"

  # Routes: a 200, or a JSON 404 from the coordinator itself, proves nginx
  # forwards the path; an nginx HTML 404 means the location block is missing.
  local missing="" feed route code
  for feed in $(json_field "$REPO_ROOT/$AUTOTUNE/release.json" '" ".join(sorted(d["feeds"]))'); do
    route="$(feed_route "$feed")"
    [ -n "$route" ] || continue
    set -- "$route" "$route.sig"
    [ "$feed" != native-mtp-admission.json ] ||
      set -- "$@" /v1/native-mtp-artifact-manifest /v1/native-mtp-selftest-bank /v1/native-mtp-selftest-bank.sig
    for route in "$@"; do
      [ -n "$base" ] || continue
      code="$(http_get "$base$route" "$OPS_TMP_DIR/route.body")"
      if [ "$code" != "200" ] && ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$OPS_TMP_DIR/route.body" 2>/dev/null; then
        missing="$missing $route"
      fi
    done
  done
  fact nginx_missing_routes "${missing# }"

  # Native feeds.
  local adm_code="" live_bank_rid="" live_bank_sha="" slot_exp="" slot_current=false
  if [ "$native_bound" = true ] && [ -n "$base" ]; then
    adm_code="$(http_get "$base/v1/native-mtp-admission" "$OPS_TMP_DIR/adm.json")"
    if [ "$(http_get "$base/v1/native-mtp-selftest-bank" "$OPS_TMP_DIR/bank.json")" = "200" ]; then
      live_bank_rid="$(json_field "$OPS_TMP_DIR/bank.json" 'd["release_id"]')"
      live_bank_sha="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$OPS_TMP_DIR/bank.json")"
    fi
    local key_id
    key_id="$(json_field "$REPO_ROOT/$AUTOTUNE/native-mtp-admission.json" 'd["revocation_signer_key_id"]')"
    if [ "$(http_get "$base/v1/native-mtp-revocations.$key_id.json" "$OPS_TMP_DIR/rev.json")" = "200" ]; then
      slot_exp="$(json_field "$OPS_TMP_DIR/rev.json" 'd["expires_at"]')"
      python3 -c 'import datetime,sys; e=datetime.datetime.strptime(sys.argv[1],"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc); sys.exit(0 if e>datetime.datetime.now(datetime.timezone.utc) else 1)' "$slot_exp" 2>/dev/null &&
        slot_current=true
    fi
  fi
  fact live_native_admission_http "$adm_code"
  fact live_selftest_bank_release_id "$live_bank_rid"
  fact live_selftest_bank_sha256 "$live_bank_sha"
  fact live_revocation_slot_expires_at "$slot_exp"
  fact live_revocation_slot_current "$slot_current"

  # Revocation batch coverage, read-only over ssh when configured.
  local coverage_days=""
  if [ "$native_bound" = true ] && [ -n "${PEARL_SSH:-}" ] && [ -n "${REMOTE_REVOCATION_DIR:-}" ]; then
    local batch
    batch="$(pearl_ssh "readlink '$REMOTE_REVOCATION_DIR/current'" 2>/dev/null || true)"
    coverage_days="$(python3 - "$batch" "$REVOCATION_BATCH_DAYS" <<'PY' 2>/dev/null || true
import datetime, re, sys
m = re.search(r"batch-(\d{8}T\d{6}Z)", sys.argv[1])
start = datetime.datetime.strptime(m.group(1), "%Y%m%dT%H%M%SZ").replace(tzinfo=datetime.timezone.utc)
end = start + datetime.timedelta(days=int(sys.argv[2]))
print("%.2f" % ((end - datetime.datetime.now(datetime.timezone.utc)).total_seconds() / 86400))
PY
)"
  fi
  fact revocation_coverage_days "$coverage_days"

  # Provider (canary/Studio) status, read-only over ssh when configured.
  local p_rid="" p_digest="" p_mtp_enabled="" p_mtp_mode="" p_cb_active="" p_connected="" p_lifecycle="" p_paused=false
  if [ -n "${STUDIO_SSH:-}" ] && [ -n "${STUDIO_STATUS_PORT:-}" ]; then
    case "$STUDIO_STATUS_PORT" in *[!0-9]*) die "STUDIO_STATUS_PORT must be numeric" ;; esac
    studio_ssh "curl -s -m 10 http://127.0.0.1:$STUDIO_STATUS_PORT/v1/status" > "$OPS_TMP_DIR/pstatus.json" 2>/dev/null || true
    p_rid="$(json_field "$OPS_TMP_DIR/pstatus.json" 'd["catalog"]["release_id"]')"
    p_digest="$(json_field "$OPS_TMP_DIR/pstatus.json" 'd["catalog"]["digest"]')"
    p_mtp_enabled="$(json_field "$OPS_TMP_DIR/pstatus.json" 'd["native_mtp"]["enabled"]')"
    p_mtp_mode="$(json_field "$OPS_TMP_DIR/pstatus.json" 'd["native_mtp"]["mode"]')"
    p_cb_active="$(json_field "$OPS_TMP_DIR/pstatus.json" 'd["continuous_batching"]["active"]')"
    p_connected="$(json_field "$OPS_TMP_DIR/pstatus.json" 'd["coordinator"]["connected"]')"
    p_lifecycle="$(json_field "$OPS_TMP_DIR/pstatus.json" 'd["lifecycle"]["state"]')"
  fi
  # An operator pause (a Studio bench window) survives restarts and keeps the
  # canary out of buyer_serving: the custody proof (canary_reachable) and
  # activation evidence (c) cannot pass until it is resumed.
  [ "$p_lifecycle" = paused_by_operator ] && p_paused=true
  # Unreadable status is unknown, never "not paused".
  local p_status_ok=false
  [ -n "$(json_field "$OPS_TMP_DIR/pstatus.json" 'd["provider_id"] if isinstance(d.get("provider_id"), str) and d["provider_id"] else None')" ] && p_status_ok=true
  fact provider_catalog_release_id "$p_rid"
  fact provider_native_mtp_enabled "$p_mtp_enabled"
  fact provider_native_mtp_mode "$p_mtp_mode"
  fact provider_continuous_batching_active "$p_cb_active"
  fact provider_coordinator_connected "$p_connected"
  fact provider_lifecycle_state "$p_lifecycle"
  local paused_why="the canary provider status is unreadable (set STUDIO_SSH and STUDIO_STATUS_PORT): whether it is operator-paused is unknown, and its custody proof and the activation's canary restart need it buyer_serving"
  [ "$p_status_ok" = false ] || paused_why="the canary provider is operator-paused (lifecycle paused_by_operator, e.g. a Studio bench window): its custody proof needs it buyer_serving and the activation restarts it onto the release, which a pause outlives; run this after the pause window ends and the provider is resumed"

  # ---- decide, in runbook order ----
  NEXT_RUNBOOK="$MTP_DOC"

  if [ "$verify_ok" = true ] && { [ "$native_bound" = false ] || [ "$bank_rid" = "$R" ]; }; then
    step catalog_verify "done" "catalog-release.py verify ok"
  else
    step catalog_verify blocked "$(tail -n 1 "$OPS_TMP_DIR/verify.out")"
    set_next catalog_verify blocked "Fix the committed catalog release" "MACPROVIDER_REQUIRED_CB_BASELINE=studio-qwen3.6-a3b-v1 python3 scripts/catalog-release.py verify" \
      "verify=$verify_ok; native-bound bank release_id '$bank_rid' must equal '$R'"
  fi
  if [ -z "$base" ]; then
    set_next live_state blocked "Read live coordinator state" "" "COORDINATOR_URL is unset"
  fi

  # #1938 (SPEC-023 v0.22.23): providers keep the newest verified revocation
  # body in force after it ages, and the coordinator keeps serving the newest
  # issued slot, so any served slot is enough. A batch is published only when
  # none is served; batch age is reported, never a reason to republish.
  if [ "$native_bound" != true ]; then
    step revocation_slots "done" "release is not native-bound"
  elif [ -n "$slot_exp" ]; then
    step revocation_slots "done" "a signed slot is served (expires_at $slot_exp; batch coverage ${coverage_days:-unknown} days)"
  else
    step revocation_slots pending "no revocation slot is served"
    set_next revocation_slots mutate "Publish 14 days of native-MTP revocation slots" \
      "scripts/publish-native-mtp-revocations.sh --deploy"
    next_meta revocation_slots "$MTP_DOC" "none expected: atomic batch symlink swap; the coordinator rescans within 10 s"
  fi

  if [ -n "$missing" ]; then
    step nginx_routes pending "missing:$missing"
    set_next nginx_routes manual "Add the missing nginx location blocks on the coordinator host" \
"# Copy ONLY the missing blocks from phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf:
#  $missing
# Diff against the live vhost (Pearl nginx lags the repo), then: nginx -t && systemctl reload nginx
# Never run the gateway deploy-pearl-vps.sh."
    next_meta nginx_routes "$ROLLOUT_DOC#before-running" "none expected: nginx reload"
  else
    step nginx_routes "done" "every bound feed reaches the coordinator"
  fi

  if [ "$native_bound" != true ] || [ "$adm_code" = "200" ]; then
    step coordinator_native_keys "done" "coordinator serves /v1/native-mtp-admission"
  else
    step coordinator_native_keys pending "/v1/native-mtp-admission http=$adm_code"
    set_next coordinator_native_keys manual "Add the native_mtp_* keys and the pool canary to coordinator.yaml" \
"# On Pearl, under BOTH locks, edit coordinator.yaml IN PLACE; add only these keys.
# Under autotune: (after rate_card_sig_path)
$RB_NATIVE_AUTOTUNE_KEYS
# Under pool:
$RB_NATIVE_POOL_CANARY"
    next_meta coordinator_native_keys "$MTP_DOC#order" "none for the edit; the keys load at the activation restart"
  fi

  local verdict="$OPS_STATE_DIR/$OPS_SCOPE/preflight-$main_sha.json" fresh=false go="" pricing="" lane_detail="" failed="" owed_pf=""
  # Owed evidence (e) outlives the release that deferred it: one ledger entry
  # per owed model, open until a buyer_serving_e2e record names that model.
  local owed_dir="$OPS_STATE_DIR/catalog-owed-e2e" deploy_log="$OPS_STATE_DIR/$OPS_SCOPE/deploy-$main_sha.log"
  if [ -f "$verdict" ] && [ -n "$(find "$verdict" -mmin -60 2>/dev/null)" ]; then
    fresh=true
    go="$(json_field "$verdict" 'd["go"]')"
    pricing="$(json_field "$verdict" '(d.get("pricing") or {}).get("pricing_diff_sha256")')"
    lane_detail="$(json_field "$verdict" 'next((c["detail"] for c in d["checks"] if c["name"] == "content_gate" and not c["ok"]), "")')"
    failed="$(json_field "$verdict" '"; ".join("%s: %s" % (c["name"], c["detail"][:200]) for c in d["checks"] if not c["ok"] and not c["detail"].startswith("not run:"))')"
    owed_pf="$(json_field "$verdict" '", ".join(m["model_id"] for m in d.get("buyer_serving_e2e_owed") or [])')"
    # The digest reaches a step command: anything but a sha256 is refused.
    if [ -n "$pricing" ] && ! [[ "$pricing" =~ ^[0-9a-f]{64}$ ]]; then
      go=false
      failed="pricing: the verdict's pricing_diff_sha256 is not a sha256${failed:+; $failed}"
      pricing=""
    fi
  fi
  fact preflight_failed_checks "$failed"
  if [ "$live_rid" = "$R" ]; then
    step catalog_preflight "done" "live release is $R"
    step catalog_activation "done" "live release is $R ($live_status)"
  else
    if [ "$fresh" = true ]; then
      step catalog_preflight "done" "go=$go ($verdict)"
    else
      step catalog_preflight pending "live $live_rid != committed $R"
      if [ "$head_sha" != "$main_sha" ]; then
        set_next catalog_preflight blocked "Preflight the content release" "" \
          "run from a clean worktree whose HEAD is origin/main ($main_sha); tooling must match the commit"
      elif [ "$p_paused" = true ] || [ "$p_status_ok" = false ]; then
        set_next catalog_preflight blocked "Preflight content release $R" "" "$paused_why"
      else
        set_next catalog_preflight read "Preflight content release $R at $main_sha (no mutation)" \
"mkdir -p '$OPS_STATE_DIR/$OPS_SCOPE'
scripts/catalog-content-release.sh --preflight --commit $main_sha > '$verdict.tmp' || true
mv '$verdict.tmp' '$verdict'
python3 -m json.tool '$verdict'"
        next_meta catalog_preflight "$TREE_DOC#run"
      fi
    fi
    step catalog_activation pending "${owed_pf:+evidence (e) owed after activation: $owed_pf}"
    local restore_cmd deploy_cmd content_downtime
    restore_cmd="$(render_runbook "$RB_CATALOG_RESTORE")"
    # The deploy's own verdict line (sorted keys: buyer_serving_e2e_owed first)
    # records which (e) the activation left owed; only a successful deploy writes it.
    # Owed (e) is written to the ledger BEFORE the deploy from the preflight
    # verdict (fsynced), and again from the deploy's own verdict line (sorted
    # keys: buyer_serving_e2e_owed first): a deploy that goes live and then
    # loses its local output still leaves every owed model open.
    local owed_writer
    owed_writer="python3 -I -c 'import datetime, hashlib, json, os, sys
src, out, rel = sys.argv[1:4]
lines = [l for l in open(src) if l.startswith(\"{\")]
docs = [json.loads(l) for l in lines if l.startswith(\"{\\\"buyer_serving_e2e_owed\\\"\")]
now = datetime.datetime.now(datetime.timezone.utc).strftime(\"%Y-%m-%dT%H:%M:%SZ\")
for m in (docs[-1] if docs else {}).get(\"buyer_serving_e2e_owed\") or []:
    rec = {\"model_id\": m[\"model_id\"], \"sha256\": m[\"sha256\"], \"release_id\": rel, \"recorded_at\": now}
    name = hashlib.sha256((m[\"model_id\"] + \" \" + m[\"sha256\"]).encode()).hexdigest()
    final = os.path.join(out, name + \".json\")
    if os.path.exists(final):
        continue
    tmp = final + \".tmp\"
    with open(tmp, \"w\") as f:
        json.dump(rec, f, sort_keys=True)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, final)'"
    deploy_cmd="mkdir -p '$OPS_STATE_DIR/$OPS_SCOPE' '$owed_dir'
$owed_writer '$verdict' '$owed_dir' '$R'
scripts/catalog-content-release.sh --deploy --commit $main_sha ${pricing:+--pricing-diff-sha256 $pricing }--preflight-verdict '$verdict' | tee '$deploy_log'
$owed_writer '$deploy_log' '$owed_dir' '$R'"
    content_downtime="no coordinator restart: one SIGHUP reloads the release${pricing:+ and the rate card}; the canary provider is drained and restarted onto the release, so the requests it would serve go to other providers of its model or wait for its restart and model load; a failed activation rolls back and can strand adopters for 3-11 min"
    if [ "$fresh" = true ] && { [ "$p_paused" = true ] || [ "$p_status_ok" = false ]; } &&
      { [ "$go" = true ] || printf '%s' "$lane_detail" | grep -q 'lane='; }; then
      set_next catalog_activation blocked "Activate content release $R" "" "$paused_why"
    elif [ "$fresh" = true ] && [ "$go" = true ] && [ -z "$pricing" ]; then
      set_next catalog_activation mutate "Activate content release $R${owed_pf:+ (evidence (e) owed: $owed_pf)}" "$deploy_cmd"
      next_meta catalog_activation "$TREE_DOC#run" "$content_downtime"
    elif [ "$fresh" = true ] && [ "$go" = true ] && [ "${CATALOG_PRICING_ACK:-}" = "$pricing" ]; then
      set_next catalog_activation mutate "Activate pricing release $R with the acknowledged price table $pricing${owed_pf:+ (evidence (e) owed: $owed_pf)}" "$deploy_cmd"
      next_meta catalog_activation "$TREE_DOC#preflight-and-the-price-table" "$content_downtime"
    elif [ "$fresh" = true ] && [ "$go" = true ]; then
      set_next catalog_activation blocked "Review the price table, then activate $R with its acknowledgement digest" \
        "python3 -m json.tool '$verdict'" \
        "a pricing release needs the operator's acknowledgement of the price table (the verdict's pricing object; the preflight printed it on stderr): after review, run with CATALOG_PRICING_ACK=$pricing"
      next_meta catalog_activation "$TREE_DOC#preflight-and-the-price-table" ""
    elif [ "$fresh" = true ] && printf '%s' "$lane_detail" | grep -q 'lane=' && ! printf '%s' "$lane_detail" | grep -q 'lane=catalog-content'; then
      set_next catalog_activation manual "Full catalog activation with deploy-pearl-vps.sh from the running tag" \
"# The content gate refused: $lane_detail
# docs/runbooks/pearl-coordinator-rollout.md 'Catalog activation (full deploy)': from a clean
# worktree at the RUNNING tag, after the nginx and coordinator.yaml prerequisites, chain the restore:
$restore_cmd
# As soon as public /v1/autotune-release reports $R, kickstart the canary provider and confirm
# its /v1/status catalog.release_id == $R (kickstart again at once if it came up on the old release)."
      next_meta catalog_activation "$ROLLOUT_DOC#catalog-activation-full-deploy" \
        "coordinator restart: seconds; a failed activation strands adopters for 3-11 min"
    elif [ "$fresh" = true ]; then
      local hint=""
      case "$failed" in *canary_reachable:*) [ "$p_paused" = false ] || hint=" ($paused_why)" ;; esac
      set_next catalog_activation blocked "Activate $R" "python3 -m json.tool '$verdict'" \
        "preflight NO_GO: ${failed:-see the verdict}$hint; fix every failing check, then preflight again"
    fi
  fi

  # SPEC-031-R033: the coordinator canary reloads its self-test bank with the
  # SIGHUP release reload and reports the bank it holds on /healthz, release
  # and SHA-256. Done needs both to match the served bank: the release id
  # alone would pass a stale bank re-labelled with the same release. A
  # runtime without that signal read the bank at boot only, so a
  # SIGHUP-loaded native-bound release still needs a restart, in this step.
  local bank_reloads canary_bank_rid canary_bank_sha restart_needed=false
  bank_reloads="$(json_field "$OPS_TMP_DIR/healthz.json" 'd.get("native_mtp_canary_bank_reloads")')"
  canary_bank_rid="$(json_field "$OPS_TMP_DIR/healthz.json" 'd.get("native_mtp_canary_bank_release_id")')"
  canary_bank_sha="$(json_field "$OPS_TMP_DIR/healthz.json" 'd.get("native_mtp_canary_bank_sha256")')"
  fact coordinator_canary_bank_reloads "${bank_reloads:-false}"
  fact coordinator_canary_bank_release_id "$canary_bank_rid"
  fact coordinator_canary_bank_sha256 "$canary_bank_sha"
  if [ "$native_bound" != true ]; then
    step canary_bank "done" "release is not native-bound"
  elif [ "$live_rid" != "$R" ]; then
    step canary_bank pending "after activation"
  elif [ "$bank_reloads" = true ]; then
    if [ "$canary_bank_rid" = "$R" ] && [ -n "$live_bank_sha" ] && [ "$canary_bank_sha" = "$live_bank_sha" ]; then
      step canary_bank "done" "canary holds the served $R self-test bank (sha256 $live_bank_sha), reloaded with the release"
    elif [ -z "$live_bank_sha" ]; then
      step canary_bank unknown "served /v1/native-mtp-selftest-bank unreadable; cannot compare the canary bank digest"
    else
      step canary_bank blocked "canary bank '${canary_bank_rid:-none}' sha256 '${canary_bank_sha:-none}' != served $R sha256 $live_bank_sha"
      set_next canary_bank blocked "Make the coordinator canary hold the served $R self-test bank" "" \
        "the coordinator reloads the canary bank with the release but holds '${canary_bank_rid:-none}' (sha256 '${canary_bank_sha:-none}'), not the served $R bank (sha256 $live_bank_sha): the pool native_mtp_canary block is missing or disabled, its keys do not verify the bank, or the coordinator predates the bank digest on /healthz (journal: 'native MTP canary'); a restart fixes neither"
      next_meta canary_bank "$MTP_DOC#order"
    fi
  elif [ -z "$uptime" ] || [ -z "$verified_min" ]; then
    step canary_bank unknown "coordinator /healthz or /v1/autotune-release unreadable"
  else
    restart_needed="$(python3 - "$uptime" "$verified_min" <<'PY'
import datetime, sys
now = datetime.datetime.now(datetime.timezone.utc)
started = now - datetime.timedelta(seconds=int(sys.argv[1]))
verified = datetime.datetime.strptime(sys.argv[2], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
print("true" if verified - started > datetime.timedelta(seconds=120) else "false")
PY
)"
    if [ "$restart_needed" = true ]; then
      step canary_bank pending "this coordinator reads the canary bank at boot only and loaded $R by SIGHUP"
      set_next canary_bank mutate "Restart the coordinator so the native canary loads the $R self-test bank" \
"ssh \"\$PEARL_SSH\" 'flock -n /run/lock/macprovider-pearl-updater.lock flock -n /opt/macprovider/.coordinator-deploy.lock systemctl restart macprovider-coordinator'
for i in \$(seq 1 24); do curl -sf -m 5 \"\$COORDINATOR_URL/healthz\" && exit 0; sleep 5; done; echo 'coordinator not healthy after 120 s' >&2; exit 1"
      next_meta canary_bank "$ROLLOUT_DOC" "coordinator restart: a few seconds of buyer outage"
    else
      step canary_bank "done" "booted on or after the release load"
    fi
  fi
  fact coordinator_restart_needed_for_bank "$restart_needed"

  if [ -z "$p_rid" ]; then
    step provider_restart unknown "STUDIO_SSH/STUDIO_STATUS_PORT unset or status unreadable"
    set_next provider_restart blocked "Read the canary provider status" "" \
      "STUDIO_SSH and STUDIO_STATUS_PORT must be set (read-only curl of the provider's local /v1/status)"
  elif [ "$p_rid" = "$R" ] && [ "$p_connected" = true ]; then
    step provider_restart "done" "provider on $R and connected"
  else
    step provider_restart pending "provider on $p_rid (connected=$p_connected)"
    set_next provider_restart manual "Restart the canary provider onto $R (operator approval)" \
"ssh \"\$STUDIO_SSH\" 'launchctl kickstart -k gui/\$(id -u)/live.malibu.provider'
# then: ssh \"\$STUDIO_SSH\" 'curl -s http://127.0.0.1:\$STUDIO_STATUS_PORT/v1/status' -> catalog.release_id == $R,
# connected: true; if it came up on the old release, kickstart again right away."
    next_meta provider_restart "$ROLLOUT_DOC#run-with-an-automatic-restore"
  fi

  # Dense CB-only models have no native-MTP heads. An explicit CB-only proof
  # must not require that unrelated capability. Preserve the historical native
  # probe when unset; the gateway proof still requires shared-forward movement.
  if [ "$p_cb_active" = true ] && { [ "${CATALOG_REQUIRE_NATIVE_MTP_FORWARD:-}" = false ] ||
       { [ "$p_mtp_enabled" = true ] && { [ "$p_mtp_mode" = eligible ] || [ "$p_mtp_mode" = active ]; }; }; }; then
    step live_probe "done" "continuous_batching active, native_mtp $p_mtp_mode (forward requirement=${CATALOG_REQUIRE_NATIVE_MTP_FORWARD:-default})"
  else
    step live_probe pending "native_mtp enabled=$p_mtp_enabled mode=$p_mtp_mode cb_active=$p_cb_active"
    if [ "${CATALOG_REQUIRE_NATIVE_MTP_FORWARD:-}" = false ]; then
      [ -z "$p_rid" ] || set_next live_probe manual "Verify the signed CB policy and local self-check grant for the target provider" \
"# Confirm /v1/status continuous_batching.active=true after the signed policy and local self-check grant.
# Do not enable native MTP on a model without qualified MTP heads."
      next_meta live_probe "specs/SPEC-038-continuous-batching.md"
    else
      [ -z "$p_rid" ] || set_next live_probe manual "Turn the tuple on for the provider (native_mtp_mode: auto) and restart it" \
"# docs/runbooks/native-mtp-enablement.md step 9 (operator approval: restarts live.malibu.provider)
# set native_mtp_mode: auto in the provider config, restart, then confirm /v1/status
# native_mtp.enabled=true, mode eligible|active, continuous_batching.active=true"
      next_meta live_probe "$MTP_DOC#order"
    fi
  fi

  # The proof expires, and legacy generic request-counter markers are not enough
  # once continuous batching is active: a fresh marker must carry the scheduler
  # shared_forward_calls delta from the provider-attributed buyer request.
  local require_mtp
  require_mtp="$(native_mtp_forward_requirement)"
  if [ "${PROBE_MODEL:-}" = "$QWEN_NATIVE_MODEL" ] && [ "$require_mtp" != true ]; then
    refuse "Qwen3.6 proof requires CATALOG_REQUIRE_NATIVE_MTP_FORWARD=true"
  fi
  if gateway_proof_marker_valid "$OPS_SCOPE" "$p_cb_active" "$require_mtp" \
       "${PROBE_MODEL:-}" "$R" "$p_digest"; then
    step gateway_proof "done" "$(marker_field "$OPS_SCOPE" gateway_proof 'd.get("evidence")')"
  else
    step gateway_proof pending "$(marker_done "$OPS_SCOPE" gateway_proof && echo 'previous proof older than 24 h or lacks active-path scheduler evidence' || true)"
    if [ "${PROBE_MODEL:-}" = "$QWEN_NATIVE_MODEL" ] && [ "$require_mtp" = true ]; then
      set_next gateway_proof mutate "Adopt Qwen3.6, prove one paid native-MTP request, and restore GLM" \
        "$OPS_DIR/qwen-opencode-e2e.sh _catalog-qwen36-proof"
      NEXT_DOWNTIME="Studio provider buyer traffic is unavailable during bounded Qwen/GLM restart and model-load windows; Pearl is not restarted"
    else
      set_next gateway_proof read "Send one real buyer request through the gateway" \
        "scripts/ops/catalog-activate.sh _gateway-proof"
    fi
    next_meta gateway_proof "AGENTS.md#hard-rules--activation-evidence-and-campaign-discipline"
  fi

  # Evidence (e) owed (SPEC-023-R017 5(e)): every ledger entry whose model no
  # buyer_serving_e2e record names yet. A malformed entry is unknown, not done.
  local owed_scan owed_models="" owed_bad=""
  owed_scan="$(python3 -I - "$owed_dir" "$OPS_STATE_DIR" <<'PY'
import glob, json, os, re, sys
owed_dir, state = sys.argv[1:3]
# A buyer_serving_e2e record proves exactly the model@sha256 pairs it names.
proved = set()
for path in glob.glob(os.path.join(state, "catalog-*", "buyer_serving_e2e.json")):
    try:
        text = str(json.load(open(path)).get("evidence", ""))
    except Exception:
        continue
    proved |= set(re.findall(r"(?:^|\s)model=(\S+)@([0-9A-Za-z]+)(?=\s|$|[,;])", text))
open_models, bad = [], []
for path in sorted(glob.glob(os.path.join(owed_dir, "*.json"))):
    try:
        rec = json.load(open(path))
        model, sha, rel = rec["model_id"], rec["sha256"], rec["release_id"]
        if not all(isinstance(v, str) and v and not any(c.isspace() for c in v) for v in (model, sha, rel)):
            raise ValueError
    except Exception:
        bad.append(os.path.basename(path))
        continue
    if (model, sha) not in proved:
        open_models.append("%s@%s (owed since %s)" % (model, sha, rel))
print("BAD " + " ".join(bad))
print("OPEN " + ", ".join(open_models))
PY
)"
  owed_bad="$(printf '%s\n' "$owed_scan" | sed -n 's/^BAD //p')"
  owed_models="$(printf '%s\n' "$owed_scan" | sed -n 's/^OPEN //p')"
  fact buyer_serving_e2e_owed "$owed_models"
  if [ -n "$owed_bad" ]; then
    step buyer_serving_e2e blocked "unreadable owed-evidence record(s): $owed_bad"
    set_next buyer_serving_e2e blocked "Read the owed evidence (e) records" "ls -l '$owed_dir'" \
      "owed evidence (e) record(s) in $owed_dir are malformed ($owed_bad); an owed proof is never assumed done"
  elif [ -n "$owed_models" ]; then
    step buyer_serving_e2e owed "$owed_models: owed by the provider release that first serves it (CLI train canary; #2016 live acceptance)"
    set_next buyer_serving_e2e manual "Owed evidence (e) for $owed_models: canary restart onto the live release, one buyer request through the gateway served by it, its settlement row" \
"# Owed by the provider release that first serves the model (the CLI train canary and the
# #2016 live acceptance): no connected provider served it when its release was activated.
# On that canary, while it is the only provider serving the model:
# 1. Provider restart onto the live release:
ssh \"\$STUDIO_SSH\" 'launchctl kickstart -k gui/\$(id -u)/live.malibu.provider'
#    then its /v1/status: catalog.release_id == the live release, network_state buyer_serving,
#    the model loaded; note safety_telemetry.coordinator_session_id.
# 2. One buyer request for the model through the gateway (the bearer rides curl --config on stdin):
#    printf 'header = \"Authorization: Bearer %s\"\\n' \"\$(cat \"\$BUYER_TOKEN_FILE\")\" | curl -sS --config - -D - \\
#      -H 'Content-Type: application/json' -H 'X-Request-ID: ops-e2e-<nonce>' \\
#      -d '{\"model\":\"<model>\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with ok.\"}]}' \\
#      \"\$GATEWAY_URL/v1/chat/completions\"   -> HTTP 200 and an X-Request-ID
# 3. On Pearl, read-only: its request_log row names the canary's coordinator session
#    (provider_assigned_id), and its settlement row carries the rate-card row's rates.
# Then: scripts/ops/catalog-activate.sh next --done buyer_serving_e2e --evidence 'model=<model_id>@<sha256> <request id, session match, rates, settlement row>'
# (one model=<model_id>@<sha256> token, exactly as listed above, per model it proves)" \
      "a release was activated with (e) owed because no connected provider served the model"
    next_meta buyer_serving_e2e "$TREE_DOC#evidence-after-activation" "the canary restart only: requests it would serve go to other providers of its model or wait for its restart and model load"
  elif [ "$live_rid" != "$R" ]; then
    step buyer_serving_e2e pending "${owed_pf:+owed after activation: $owed_pf}"
  else
    step buyer_serving_e2e "done" "no owed evidence (e) is open"
  fi

  set_next "done" "done" "$R active and proven through the gateway" ""
}

# provider_counters FILE -> "mtp_forwards requests_total cb_active cb_shared_forward_calls"
# from a provider /v1/status document; fails when the counters needed for the
# active serving mode are absent.
provider_counters() {
  python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
mtp = (d.get("native_mtp") or {}).get("mtp_forwards")
req = d.get("requests_total")
cb_doc = d.get("continuous_batching") or {}
cb = cb_doc.get("active") is True
scheduler = cb_doc.get("scheduler") or {}
shared = scheduler.get("shared_forward_calls")
if not isinstance(mtp, int) or not isinstance(req, int):
    sys.exit(1)
if cb and not isinstance(shared, int):
    sys.exit(1)
mtp_doc = d.get("native_mtp") or {}
# A provider that reports native MTP explicitly disabled serves on the serial path.
serial = mtp_doc.get("enabled") is False and not cb
print(mtp, req, "true" if cb else "false", shared if isinstance(shared, int) else 0, "true" if serial else "false")
PY
}

read_provider_status() {
  studio_ssh "curl -s -m 10 http://127.0.0.1:$STUDIO_STATUS_PORT/v1/status" > "$1" ||
    refuse "provider /v1/status not readable over STUDIO_SSH"
}

native_mtp_forward_requirement() {
  case "${CATALOG_REQUIRE_NATIVE_MTP_FORWARD:-false}" in
    false) echo false ;;
    true) echo true ;;
    *) refuse "CATALOG_REQUIRE_NATIVE_MTP_FORWARD must be true or false" ;;
  esac
}

require_qwen_proof_lock() {
  local status="$OPS_TMP_DIR/qwen-proof-lock.json"
  [ "${MACPROVIDER_OPS_ENTRYPOINT:-}" = 1 ] && [ -n "${MACPROVIDER_OPS_OWNER:-}" ] ||
    refuse "Qwen3.6 gateway proof is callable only from the catalog transaction"
  "$OPS_DIR/live-lock.sh" status > "$status" 2>/dev/null ||
    refuse "Qwen3.6 gateway proof cannot read the live-ops lock"
  python3 - "$status" "$MACPROVIDER_OPS_OWNER" <<'PY' ||
import json, sys
d=json.load(open(sys.argv[1])); lock=d.get("lock") or {}
raise SystemExit(0 if d.get("held") is True and lock.get("owner")==sys.argv[2]
                 and lock.get("purpose")=="catalog-activate:qwen_restore" else 3)
PY
    refuse "Qwen3.6 gateway proof requires the already-held durable restoration lock"
}

gateway_proof_marker_valid() {
  local scope="$1" cb_active="$2" require_mtp="$3" expected_model="${4:-}" expected_release="${5:-}" expected_digest="${6:-}" path
  path="$(marker_path "$scope" gateway_proof)"
  [ -f "$path" ] || return 1
  [ -n "$(find "$path" -mmin -1440 2>/dev/null)" ] || return 1
  python3 - "$path" "$cb_active" "$require_mtp" "$expected_model" "$expected_release" "$expected_digest" <<'PY'
import json, pathlib, sys
path, cb_active, require_mtp, model, release, digest = sys.argv[1:7]
try:
    d = json.load(open(path))
except Exception:
    sys.exit(1)
if d.get("step") != "gateway_proof" or d.get("served_by_canary") is not True:
    sys.exit(1)
if not isinstance(d.get("request_id"), str) or not d.get("request_id"):
    sys.exit(1)
if cb_active == "true":
    delta = d.get("cb_shared_forward_calls_delta")
else:
    delta = d.get("mtp_forwards_delta")
if type(delta) is not int or delta <= 0:
    sys.exit(1)
if require_mtp == "true":
    if d.get("native_mtp_forward_required") is not True:
        sys.exit(1)
    if type(d.get("mtp_forwards_delta")) is not int or d["mtp_forwards_delta"] <= 0:
        sys.exit(1)
if model == "qwen/qwen3.6-35b-a3b":
    pending = pathlib.Path(path).parent / "qwen-gateway-proof" / "qwen-gateway-proof.pending.json"
    if pending.exists() or pending.is_symlink():
        sys.exit(1)
    if d.get("proof_model") != model or d.get("catalog_release_id") != release:
        sys.exit(1)
    if not digest or d.get("catalog_digest") != digest:
        sys.exit(1)
    value = d.get("served_session_sha256")
    if not isinstance(value, str) or len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
        sys.exit(1)
PY
}

qwen_proof_pending_path() {
  printf '%s/%s/qwen-gateway-proof/qwen-gateway-proof.pending.json' "$OPS_STATE_DIR" "$OPS_SCOPE"
}

# Persist the request identity and the exact pre-request context before curl.
# The rename and parent-directory fsync make an interrupted send discoverable.
write_qwen_proof_intent() {
  python3 -I - "$@" <<'PY'
import json, os, pathlib, sys, tempfile, uuid
path, request_id, model, release, digest, session_hash, mtp, requests, cb, shared = sys.argv[1:]
try:
    parsed = uuid.UUID(request_id)
except ValueError:
    raise SystemExit(2)
if parsed.version != 4 or str(parsed) != request_id:
    raise SystemExit(2)
if model != "qwen/qwen3.6-35b-a3b" or not release or len(digest) != 64 or len(session_hash) != 64:
    raise SystemExit(2)
if any(c not in "0123456789abcdef" for c in digest + session_hash):
    raise SystemExit(2)
doc = {
    "schema_version": "macprovider.qwen_gateway_proof_pending.v1",
    "request_id": request_id,
    "model": model,
    "catalog_release_id": release,
    "catalog_digest": digest,
    "session_sha256": session_hash,
    "before_counters": {
        "mtp_forwards": int(mtp), "requests_total": int(requests),
        "cb_active": cb == "true", "cb_shared_forward_calls": int(shared),
    },
    }
parent = pathlib.Path(path).parent
parent.mkdir(mode=0o700, parents=True, exist_ok=True)
if parent.is_symlink() or not parent.is_dir():
    raise SystemExit(3)
os.chmod(parent, 0o700)
if pathlib.Path(path).exists() or pathlib.Path(path).is_symlink():
    raise SystemExit(3)
fd, tmp = tempfile.mkstemp(prefix=".qwen-proof.", dir=parent)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(doc, f, sort_keys=True, separators=(",", ":"))
        f.write("\n"); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, path)
    dfd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
    try: os.fsync(dfd)
    finally: os.close(dfd)
finally:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
PY
}

validate_qwen_proof_intent() {
  python3 -I - "$@" <<'PY'
import json, pathlib, sys, uuid
path, model, release, digest = sys.argv[1:]
try:
    p = pathlib.Path(path)
    if not p.is_file() or p.is_symlink() or p.stat().st_mode & 0o077:
        raise ValueError()
    d = json.load(open(p))
    expected_keys = {"schema_version", "request_id", "model", "catalog_release_id",
                     "catalog_digest", "session_sha256", "before_counters"}
    if set(d) != expected_keys or d["schema_version"] != "macprovider.qwen_gateway_proof_pending.v1":
        raise ValueError()
    rid = uuid.UUID(d["request_id"])
    if rid.version != 4 or str(rid) != d["request_id"]:
        raise ValueError()
    counters = d["before_counters"]
    if set(counters) != {"mtp_forwards", "requests_total", "cb_active",
                         "cb_shared_forward_calls"}:
        raise ValueError()
    if type(counters["cb_active"]) is not bool:
        raise ValueError()
    if any(type(counters[k]) is not int or counters[k] < 0 for k in
           ("mtp_forwards", "requests_total", "cb_shared_forward_calls")):
        raise ValueError()
    if d["model"] != model or d["catalog_release_id"] != release or d["catalog_digest"] != digest:
        raise ValueError()
    session_hash = d["session_sha256"]
    if not isinstance(session_hash, str) or len(session_hash) != 64 or any(
            c not in "0123456789abcdef" for c in session_hash):
        raise ValueError()
except Exception:
    raise SystemExit(3)
print(d["request_id"], session_hash)
PY
}

resolve_qwen_proof_intent() {
  python3 -I - "$@" <<'PY'
import json, os, pathlib, sys, tempfile, uuid
path, status = sys.argv[1:]
allowed = {"accepted_missing_counter_evidence", "wrong_provider", "request_log_missing",
           "accepted_with_counter_evidence"}
if status not in allowed:
    raise SystemExit(2)
p = pathlib.Path(path); parent = p.parent
try:
    if not p.is_file() or p.is_symlink() or p.stat().st_mode & 0o077:
        raise ValueError()
    intent = json.load(open(p))
    if set(intent) != {"schema_version", "request_id", "model", "catalog_release_id",
                       "catalog_digest", "session_sha256", "before_counters"}:
        raise ValueError()
    if intent["schema_version"] != "macprovider.qwen_gateway_proof_pending.v1":
        raise ValueError()
except Exception: raise SystemExit(3)
rid = intent.get("request_id", "")
try:
    parsed = uuid.UUID(rid)
    if parsed.version != 4 or str(parsed) != rid:
        raise ValueError()
except Exception:
    raise SystemExit(3)
archive_dir = parent / "qwen-gateway-proof-attempts"
archive_dir.mkdir(mode=0o700, exist_ok=True)
if archive_dir.is_symlink() or not archive_dir.is_dir():
    raise SystemExit(3)
os.chmod(archive_dir, 0o700)
archive = archive_dir / (rid + ".json")
doc = {"schema_version": "macprovider.qwen_gateway_proof_resolution.v1",
       "resolution": status, "intent": intent}
payload = json.dumps(doc, sort_keys=True, separators=(",", ":")) + "\n"
if archive.exists():
    try:
        existing = json.load(open(archive))
    except Exception:
        raise SystemExit(3)
    if (archive.is_symlink() or not archive.is_file() or archive.stat().st_mode & 0o077
            or set(existing) != {"schema_version", "resolution", "intent"}
            or existing["schema_version"] != "macprovider.qwen_gateway_proof_resolution.v1"
            or existing["resolution"] not in allowed or existing["intent"] != intent):
        raise SystemExit(3)
else:
    fd, tmp = tempfile.mkstemp(prefix=".attempt.", dir=archive_dir)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(payload); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, archive)
        dfd = os.open(archive_dir, os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(dfd)
        finally: os.close(dfd)
    finally:
        try: os.unlink(tmp)
        except FileNotFoundError: pass
p.unlink()
dfd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
try: os.fsync(dfd)
finally: os.close(dfd)
PY
}

discard_file_durably() {
  python3 -I - "$1" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1])
try: p.unlink()
except FileNotFoundError: pass
dfd = os.open(p.parent, os.O_RDONLY | os.O_DIRECTORY)
try: os.fsync(dfd)
finally: os.close(dfd)
PY
}

fsync_file_and_parent() {
  python3 -I - "$1" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.is_symlink() or not p.is_file():
    raise SystemExit(3)
fd = os.open(p, os.O_RDONLY)
try: os.fsync(fd)
finally: os.close(fd)
dfd = os.open(p.parent, os.O_RDONLY | os.O_DIRECTORY)
try: os.fsync(dfd)
finally: os.close(dfd)
PY
}

qwen_marker_matches_pending() {
  python3 -I - "$1" "$2" <<'PY'
import json, os, pathlib, stat, sys
pending, marker = map(pathlib.Path, sys.argv[1:])
try:
 pstat=marker.lstat()
 if marker.is_symlink() or not stat.S_ISREG(pstat.st_mode) or pstat.st_uid!=os.getuid() or pstat.st_nlink!=1 or pstat.st_mode & 0o022: raise ValueError()
 i=json.load(open(pending)); m=json.load(open(marker))
 if m.get("step")!="gateway_proof" or m.get("request_id")!=i["request_id"] or m.get("sent_request_id")!=i["request_id"]: raise ValueError()
 if m.get("proof_model")!=i["model"] or m.get("catalog_release_id")!=i["catalog_release_id"] or m.get("catalog_digest")!=i["catalog_digest"]: raise ValueError()
 if m.get("served_session_sha256")!=i["session_sha256"] or m.get("served_by_canary") is not True: raise ValueError()
 if m.get("native_mtp_forward_required") is not True or type(m.get("mtp_forwards_delta")) is not int or m["mtp_forwards_delta"]<=0: raise ValueError()
 if type(m.get("cb_shared_forward_calls_delta")) is not int or m["cb_shared_forward_calls_delta"]<=0: raise ValueError()
except Exception: raise SystemExit(3)
PY
}

qwen_resolution_status() {
  python3 -I - "$1" "$2" <<'PY'
import json, pathlib, sys
pending, archive = map(pathlib.Path, sys.argv[1:])
try:
 i=json.load(open(pending)); a=json.load(open(archive))
 allowed={"accepted_missing_counter_evidence","wrong_provider","request_log_missing","accepted_with_counter_evidence"}
 if set(a)!={"schema_version","resolution","intent"} or a["schema_version"]!="macprovider.qwen_gateway_proof_resolution.v1": raise ValueError()
 if a["resolution"] not in allowed or a["intent"]!=i: raise ValueError()
except Exception: raise SystemExit(3)
print(a["resolution"])
PY
}

reconcile_qwen_proof_intent() {
  local pending="$1" model="$2" release="$3" digest="$4" pdb="$5" psqlite="$6"
  local rid session_hash served_sid="" k status validated marker archive
  validated="$(validate_qwen_proof_intent "$pending" "$model" "$release" "$digest")" ||
    refuse "pending Qwen proof intent is malformed or does not match the current provider context"
  read -r rid session_hash <<< "$validated"
  marker="$(marker_path "$OPS_SCOPE" gateway_proof)"
  archive="$(dirname "$pending")/qwen-gateway-proof-attempts/$rid.json"
  if [ -e "$archive" ] || [ -L "$archive" ]; then
    status="$(qwen_resolution_status "$pending" "$archive")" ||
      refuse "pending Qwen proof has a malformed terminal resolution"
    if [ "$status" = accepted_with_counter_evidence ]; then
      qwen_marker_matches_pending "$pending" "$marker" ||
        refuse "accepted Qwen proof resolution lacks its exact durable success marker"
      resolve_qwen_proof_intent "$pending" "$status" || refuse "accepted Qwen proof pending state could not be cleared"
      printf '%s\n' recovered_success
      return
    fi
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      refuse "non-success Qwen proof resolution conflicts with a success marker"
    fi
    resolve_qwen_proof_intent "$pending" "$status" || refuse "Qwen proof pending state could not be cleared"
    printf '%s\n' fresh_allowed
    return
  fi
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    qwen_marker_matches_pending "$pending" "$marker" ||
      refuse "pending Qwen proof conflicts with a mismatched success marker"
    resolve_qwen_proof_intent "$pending" accepted_with_counter_evidence ||
      refuse "recovered successful Qwen proof could not be durably resolved"
    printf '%s\n' recovered_success
    return
  fi
  for k in 1 2 3 4 5 6; do
    served_sid="$(pearl_ssh "'$psqlite' -readonly '$pdb' \"SELECT provider_assigned_id FROM request_log WHERE external_request_id = '$rid' ORDER BY id DESC LIMIT 1;\"" 2>/dev/null)" ||
      refuse "pending Qwen proof request_log reconciliation failed"
    served_sid="$(printf '%s' "$served_sid" | tr -d '\r\n')"
    [ -n "$served_sid" ] && break
    [ "$k" -lt 6 ] && sleep "${PROOF_POLL_SECONDS:-2}"
  done
  if [ -z "$served_sid" ]; then
    status=request_log_missing
  elif [ "$(printf '%s' "$served_sid" | /usr/bin/shasum -a 256 | awk '{print $1}')" = "$session_hash" ]; then
    status=accepted_missing_counter_evidence
  else
    status=wrong_provider
  fi
  resolve_qwen_proof_intent "$pending" "$status" ||
    refuse "pending Qwen proof resolution could not be persisted"
  printf '%s\n' fresh_allowed
}

# proof_moved B_MTP B_REQ B_CB B_SHARED A_MTP A_REQ A_CB A_SHARED [A_SERIAL]: the
# request moved the provider on the active serving path. Continuous batching must
# prove scheduler admission/completion through shared_forward_calls; generic
# requests_total movement can be satisfied by a serial request and is not enough.
# A provider with neither CB active nor native MTP enabled (A_SERIAL=true) has
# only the serial path, so requests_total is its serving-path counter.
proof_moved() {
  if [ "$3" = true ] || [ "$7" = true ]; then
    [ "$3" = true ] && [ "$7" = true ] && [ $(($8 - $4)) -gt 0 ]
  elif [ "${9:-false}" = true ]; then
    [ $(($6 - $2)) -gt 0 ]
  else
    [ $(($5 - $1)) -gt 0 ]
  fi
}

# One bounded buyer request through the gateway, tied to the target provider:
# its native_mtp.mtp_forwards (or, with continuous batching active, its
# continuous_batching.scheduler.shared_forward_calls) must increase across the request, the response must carry
# a request id, and the coordinator request_log row for that request id (read
# on Pearl, read-only) must name the coordinator session the canary reports in
# /v1/status, so other traffic on the provider cannot satisfy the proof. Buyers
# never receive provider identity (SPEC-006 5.4, #1991), so the gateway
# response carries no attribution. Prints status, request id and counter
# deltas only; the session id itself is never printed.
gateway_proof() {
  local gw model token_file require_mtp
  gw="$(gateway_url)"
  [ -n "$gw" ] || refuse "GATEWAY_URL is unset"
  token_file="${BUYER_TOKEN_FILE:-}"
  [ -n "$token_file" ] && [ -f "$token_file" ] || refuse "BUYER_TOKEN_FILE must name a readable buyer token file"
  require_mtp="$(native_mtp_forward_requirement)"
  require_studio_ssh
  case "${STUDIO_STATUS_PORT:-}" in ""|*[!0-9]*) refuse "STUDIO_STATUS_PORT must be set and numeric" ;; esac

  local before after b_mtp b_req b_cb b_shared a_mtp a_req a_cb a_shared a_serial
  read_provider_status "$OPS_TMP_DIR/before.json"
  # The model the canary serves, as its /v1/status reports it: a request for
  # any other model cannot reach the canary (the gateway 404s a model no
  # provider serves). PROBE_MODEL overrides it.
  model="${PROBE_MODEL:-$(json_field "$OPS_TMP_DIR/before.json" 'd["model"]')}"
  [ -n "$model" ] || refuse "PROBE_MODEL is unset and the canary /v1/status reports no served model"
  if [ "$model" = "$QWEN_NATIVE_MODEL" ]; then
    require_qwen_proof_lock
    [ "$(json_field "$OPS_TMP_DIR/before.json" 'd["model"]')" = "$QWEN_NATIVE_MODEL" ] ||
      refuse "Qwen3.6 proof requires the target provider to serve the exact model"
    [ "$(json_field "$OPS_TMP_DIR/before.json" 'd["native_mtp"]["enabled"]')" = true ] &&
      case "$(json_field "$OPS_TMP_DIR/before.json" 'd["native_mtp"]["mode"]')" in eligible|active) : ;; *) false ;; esac &&
      [ "$(json_field "$OPS_TMP_DIR/before.json" 'd["continuous_batching"]["active"]')" = true ] ||
      refuse "Qwen3.6 proof requires native MTP eligible or active and continuous batching active"
  fi
  before="$(provider_counters "$OPS_TMP_DIR/before.json")" || refuse "provider status lacks native_mtp.mtp_forwards/requests_total or continuous_batching.scheduler.shared_forward_calls"
  read -r b_mtp b_req b_cb b_shared _ <<< "$before"
  local canary_sid canary_sid_hash catalog_release catalog_digest pdb psqlite pending=""
  canary_sid="$(json_field "$OPS_TMP_DIR/before.json" 'd["safety_telemetry"]["coordinator_session_id"]')"
  [ -n "$canary_sid" ] || refuse "provider /v1/status reports no safety_telemetry.coordinator_session_id; cannot tie the proof to it"
  canary_sid_hash="$(printf '%s' "$canary_sid" | /usr/bin/shasum -a 256 | awk '{print $1}')"
  catalog_release="$(json_field "$OPS_TMP_DIR/before.json" 'd["catalog"]["release_id"]')"
  catalog_digest="$(json_field "$OPS_TMP_DIR/before.json" 'd["catalog"]["digest"]')"
  pdb="${PEARL_COORDINATOR_DB:-}"
  psqlite="${PEARL_SQLITE3:-/opt/macprovider-tools/sqlite-3.53.2/bin/sqlite3}"
  [ -n "$pdb" ] || refuse "PEARL_COORDINATOR_DB must name the coordinator database on Pearl to attribute the proof request"
  [[ "$pdb" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$psqlite" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
    refuse "PEARL_COORDINATOR_DB and PEARL_SQLITE3 must be absolute plain paths"
  require_pearl_ssh

  if [ "$model" = "$QWEN_NATIVE_MODEL" ]; then
    pending="$(qwen_proof_pending_path)"
    if [ -e "$pending" ] || [ -L "$pending" ]; then
      local reconcile_outcome
      reconcile_outcome="$(reconcile_qwen_proof_intent "$pending" "$model" "$catalog_release" \
        "$catalog_digest" "$pdb" "$psqlite")"
      [ "$reconcile_outcome" != recovered_success ] || return 0
    fi
  fi

  local body="$OPS_TMP_DIR/proof.json" headers="$OPS_TMP_DIR/proof.headers" code sent_rid payload
  sent_rid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  # Include the generated request id in the prompt so this proof cannot be
  # answered from an earlier identical-prompt cache entry. It remains an opaque
  # buyer request nonce and reveals no provider attribution.
  # Greedy-only native tuples reject the API's default temperature of 1.0.
  payload="$(python3 -c 'import json,sys; print(json.dumps({"model": sys.argv[1], "max_tokens": 32, "temperature": 0, "top_p": 1, "messages": [{"role": "user", "content": "Proof nonce " + sys.argv[2] + ". Reply with the word ok."}]}))' "$model" "$sent_rid")"
  if [ "$model" = "$QWEN_NATIVE_MODEL" ]; then
    write_qwen_proof_intent "$pending" "$sent_rid" "$model" "$catalog_release" "$catalog_digest" \
      "$canary_sid_hash" "$b_mtp" "$b_req" "$b_cb" "$b_shared" ||
      refuse "could not durably persist the pending Qwen proof intent"
  fi
  # The bearer goes through curl --config on stdin, never argv.
  code="$(printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '\r\n' < "$token_file")" |
    curl -sS -m 120 --config - -D "$headers" -o "$body" -w '%{http_code}' \
      -H 'Content-Type: application/json' -H "X-Request-ID: $sent_rid" \
      -d "$payload" "$gw/v1/chat/completions")" || code=000
  local rid
  rid="$(awk -F': ' 'tolower($1)=="x-request-id"{gsub("\r","",$2); print $2}' "$headers" | head -n1)"
  [ "$code" = "200" ] || die "gateway returned HTTP $code for $model (request id ${rid:-none})"
  [ -n "$rid" ] || die "gateway response carries no X-Request-ID"
  [[ "$rid" =~ ^[A-Za-z0-9._-]+$ ]] || die "gateway request id has unexpected characters"
  [ "$rid" = "$sent_rid" ] || die "gateway response request id does not match the sent request id"
  local served_sid="" k
  for k in 1 2 3 4 5 6; do
    served_sid="$(pearl_ssh "'$psqlite' -readonly '$pdb' \"SELECT provider_assigned_id FROM request_log WHERE external_request_id = '$rid' ORDER BY id DESC LIMIT 1;\"" 2>/dev/null)" ||
      die "request_log read failed over PEARL_SSH (request $rid)"
    served_sid="$(printf '%s' "$served_sid" | tr -d '\r\n')"
    [ -n "$served_sid" ] && break
    [ "$k" -lt 6 ] && sleep "${PROOF_POLL_SECONDS:-2}"
  done
  [ -n "$served_sid" ] || die "coordinator request_log has no row for request $rid"
  [ "$served_sid" = "$canary_sid" ] || die "request $rid was served by another provider, not the canary"
  [ -n "$(json_field "$body" 'd["choices"][0]["message"]["content"]')" ] || die "gateway 200 without completion content"

  local i
  for i in 1 2 3 4 5 6; do
    read_provider_status "$OPS_TMP_DIR/after.json"
    after="$(provider_counters "$OPS_TMP_DIR/after.json")" || refuse "provider status lacks counters after the request"
    read -r a_mtp a_req a_cb a_shared a_serial <<< "$after"
    proof_moved "$b_mtp" "$b_req" "$b_cb" "$b_shared" "$a_mtp" "$a_req" "$a_cb" "$a_shared" "$a_serial" && break
    [ "$i" -lt 6 ] && sleep "${PROOF_POLL_SECONDS:-2}"
  done
  proof_moved "$b_mtp" "$b_req" "$b_cb" "$b_shared" "$a_mtp" "$a_req" "$a_cb" "$a_shared" "$a_serial" ||
    die "request $rid did not move the target provider on its active serving path: mtp_forwards +$((a_mtp - b_mtp)), requests_total +$((a_req - b_req)), cb_shared_forward_calls +$((a_shared - b_shared)) (cb_active=$a_cb serial=$a_serial)"
  if [ "$require_mtp" = true ] && [ $((a_mtp - b_mtp)) -le 0 ]; then
    die "request $rid did not increase native_mtp.mtp_forwards as required: mtp_forwards +$((a_mtp - b_mtp))"
  fi
  local evidence="HTTP 200 model=$model request_id=$rid served_by=canary mtp_forwards+$((a_mtp - b_mtp)) requests_total+$((a_req - b_req)) cb_shared_forward_calls+$((a_shared - b_shared)) cb_active=$a_cb serial=$a_serial"
  log "gateway proof: $evidence"
  mark_done "$OPS_SCOPE" gateway_proof "$evidence" \
    "$(python3 -c 'import json,sys; import hashlib; print(json.dumps({"request_id": sys.argv[1], "sent_request_id": sys.argv[2], "mtp_forwards_delta": int(sys.argv[3]), "requests_total_delta": int(sys.argv[4]), "cb_shared_forward_calls_delta": int(sys.argv[5]), "native_mtp_forward_required": sys.argv[6] == "true", "served_by_canary": True, "served_session_sha256": hashlib.sha256(sys.argv[7].encode()).hexdigest(), "proof_model": sys.argv[8], "catalog_release_id": sys.argv[9], "catalog_digest": sys.argv[10]}))' "$rid" "$sent_rid" "$((a_mtp - b_mtp))" "$((a_req - b_req))" "$((a_shared - b_shared))" "$require_mtp" "$served_sid" "$model" "$catalog_release" "$catalog_digest")"
  if [ "$model" = "$QWEN_NATIVE_MODEL" ]; then
    fsync_file_and_parent "$(marker_path "$OPS_SCOPE" gateway_proof)" ||
      refuse "successful Qwen proof marker could not be made durable"
    if ! resolve_qwen_proof_intent "$pending" accepted_with_counter_evidence; then
      discard_file_durably "$(marker_path "$OPS_SCOPE" gateway_proof)" ||
        refuse "Qwen proof intent resolution failed and its success marker could not be discarded"
      refuse "successful Qwen proof intent could not be durably resolved"
    fi
  fi
}

internal() {
  case "$1" in
    _qwen-lock-reconcile) reconcile_qwen_restore_lock ;;
    _gateway-proof)
      R="$(json_field "$REPO_ROOT/$AUTOTUNE/release.json" 'd["release_id"]')"
      OPS_SCOPE="catalog-$R"
      gateway_proof ;;
    *) usage >&2; exit 2 ;;
  esac
}

ops_main "$@"
