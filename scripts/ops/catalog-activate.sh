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
#   2 revocation_slots        native-bound: publish revocations when the live batch
#                             covers < 7 days (publish-native-mtp-revocations.sh --deploy)
#   3 nginx_routes            every feed the release binds is routed to the coordinator
#   4 coordinator_native_keys coordinator.yaml autotune native_mtp_* keys + pool canary
#   5 catalog_preflight       catalog-content-release.sh --preflight (read-only)
#   6 catalog_activation      catalog-content-release.sh --deploy (content lane), or the
#                             full deploy-pearl-vps.sh activation when the gate names another lane
#   7 coordinator_restart     native-bound release loaded by SIGHUP after boot: restart,
#                             because the canary self-test bank is read at boot only
#                             (phase4-coordinator/internal/ws/server.go loadNativeMTPCanaryBank)
#   8 provider_restart        canary/Studio provider reports the new catalog release
#   9 live_probe              provider /v1/status: native_mtp enabled+eligible|active,
#                             continuous_batching active
#  10 gateway_proof           one real buyer request through the gateway that moves the
#                             target provider's mtp_forwards (or requests_total with CB
#                             active); expires after 24 h
#
# Env (or ~/.config/macprovider/ops.env): COORDINATOR_URL, GATEWAY_URL,
# PEARL_SSH (+ PEARL_SSH_IDENTITY/PEARL_SSH_KNOWN_HOSTS for the repo scripts),
# REMOTE_REVOCATION_DIR, STUDIO_SSH, STUDIO_SSH_KEY, STUDIO_STATUS_PORT,
# BUYER_TOKEN_FILE, PROBE_MODEL, CATALOG_CANARY_* (as catalog-content-release.sh),
# MACPROVIDER_OPS_OWNER (for --run).
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
REVOCATION_MIN_DAYS="${REVOCATION_MIN_DAYS:-7}"
REVOCATION_BATCH_DAYS="${NATIVE_MTP_REVOCATION_DAYS:-14}"

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
  local main_sha head_sha R native_bound=false bank_rid verify_ok=false
  main_sha="$(origin_main_sha)"
  head_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  R="$(json_field "$REPO_ROOT/$AUTOTUNE/release.json" 'd["release_id"]')"
  [ -n "$R" ] || die "cannot read $AUTOTUNE/release.json"
  OPS_SCOPE="catalog-$R"
  fact origin_main_sha "$main_sha"
  fact checkout_is_origin_main "$([ "$head_sha" = "$main_sha" ] && echo true || echo false)"
  fact committed_release_id "$R"
  if [ -n "$(json_field "$REPO_ROOT/$AUTOTUNE/release.json" 'd["feeds"]["native-mtp-admission.json"]["sha256"]')" ]; then
    native_bound=true
  fi
  fact native_bound "$native_bound"
  bank_rid="$(json_field "$REPO_ROOT/$AUTOTUNE/native-mtp-selftest-bank.json" 'd["release_id"]')"
  fact committed_bank_release_id "$bank_rid"
  if python3 "$REPO_ROOT/scripts/catalog-release.py" verify > "$OPS_TMP_DIR/verify.out" 2>&1; then
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
  local adm_code="" live_bank_rid="" slot_exp="" slot_current=false
  if [ "$native_bound" = true ] && [ -n "$base" ]; then
    adm_code="$(http_get "$base/v1/native-mtp-admission" "$OPS_TMP_DIR/adm.json")"
    http_get "$base/v1/native-mtp-selftest-bank" "$OPS_TMP_DIR/bank.json" >/dev/null
    live_bank_rid="$(json_field "$OPS_TMP_DIR/bank.json" 'd["release_id"]')"
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
  local p_rid="" p_mtp_enabled="" p_mtp_mode="" p_cb_active="" p_connected=""
  if [ -n "${STUDIO_SSH:-}" ] && [ -n "${STUDIO_STATUS_PORT:-}" ]; then
    case "$STUDIO_STATUS_PORT" in *[!0-9]*) die "STUDIO_STATUS_PORT must be numeric" ;; esac
    studio_ssh "curl -s -m 10 http://127.0.0.1:$STUDIO_STATUS_PORT/v1/status" > "$OPS_TMP_DIR/pstatus.json" 2>/dev/null || true
    p_rid="$(json_field "$OPS_TMP_DIR/pstatus.json" 'd["catalog"]["release_id"]')"
    p_mtp_enabled="$(json_field "$OPS_TMP_DIR/pstatus.json" 'd["native_mtp"]["enabled"]')"
    p_mtp_mode="$(json_field "$OPS_TMP_DIR/pstatus.json" 'd["native_mtp"]["mode"]')"
    p_cb_active="$(json_field "$OPS_TMP_DIR/pstatus.json" 'd["continuous_batching"]["active"]')"
    p_connected="$(json_field "$OPS_TMP_DIR/pstatus.json" 'd["coordinator"]["connected"]')"
  fi
  fact provider_catalog_release_id "$p_rid"
  fact provider_native_mtp_enabled "$p_mtp_enabled"
  fact provider_native_mtp_mode "$p_mtp_mode"
  fact provider_continuous_batching_active "$p_cb_active"
  fact provider_coordinator_connected "$p_connected"

  # ---- decide, in runbook order ----
  NEXT_RUNBOOK="$MTP_DOC"

  if [ "$verify_ok" = true ] && { [ "$native_bound" = false ] || [ "$bank_rid" = "$R" ]; }; then
    step catalog_verify "done" "catalog-release.py verify ok"
  else
    step catalog_verify blocked "$(tail -n 1 "$OPS_TMP_DIR/verify.out")"
    set_next catalog_verify blocked "Fix the committed catalog release" "python3 scripts/catalog-release.py verify" \
      "verify=$verify_ok; native-bound bank release_id '$bank_rid' must equal '$R'"
  fi
  if [ -z "$base" ]; then
    set_next live_state blocked "Read live coordinator state" "" "COORDINATOR_URL is unset"
  fi

  if [ "$native_bound" != true ]; then
    step revocation_slots "done" "release is not native-bound"
  elif [ -n "$coverage_days" ] && python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)' "$coverage_days" "$REVOCATION_MIN_DAYS"; then
    step revocation_slots "done" "live batch covers $coverage_days days"
  elif [ -z "$coverage_days" ]; then
    step revocation_slots unknown "live slot current=$slot_current; batch coverage unreadable"
    set_next revocation_slots blocked "Read revocation batch coverage" "" \
      "PEARL_SSH and REMOTE_REVOCATION_DIR must be set to read the live revocation batch (read-only readlink)"
  else
    step revocation_slots pending "live batch covers $coverage_days days (< $REVOCATION_MIN_DAYS)"
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

  local verdict="$OPS_STATE_DIR/$OPS_SCOPE/preflight-$main_sha.json" fresh=false go="" pricing="" lane_detail=""
  if [ -f "$verdict" ] && [ -n "$(find "$verdict" -mmin -60 2>/dev/null)" ]; then
    fresh=true
    go="$(json_field "$verdict" 'd["go"]')"
    pricing="$(json_field "$verdict" '(d.get("pricing") or {}).get("pricing_diff_sha256")')"
    lane_detail="$(json_field "$verdict" 'next((c["detail"] for c in d["checks"] if c["name"] == "content_gate" and not c["ok"]), "")')"
  fi
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
      else
        set_next catalog_preflight read "Preflight content release $R at $main_sha (no mutation)" \
"mkdir -p '$OPS_STATE_DIR/$OPS_SCOPE'
scripts/catalog-content-release.sh --preflight --commit $main_sha > '$verdict.tmp' || true
mv '$verdict.tmp' '$verdict'
python3 -m json.tool '$verdict'"
        next_meta catalog_preflight "$TREE_DOC#run"
      fi
    fi
    step catalog_activation pending ""
    local restore_cmd
    restore_cmd="$(render_runbook "$RB_CATALOG_RESTORE")"
    if [ "$fresh" = true ] && [ "$go" = true ] && [ -z "$pricing" ]; then
      set_next catalog_activation mutate "Activate content release $R" \
        "scripts/catalog-content-release.sh --deploy --commit $main_sha --preflight-verdict '$verdict'"
      next_meta catalog_activation "$TREE_DOC#run" \
        "none expected for buyers: SIGHUP reload; the canary provider restarts onto the release; a failed activation rolls back and can strand adopters for 3-11 min"
    elif [ "$fresh" = true ] && [ "$go" = true ]; then
      set_next catalog_activation manual "Review the price table, then activate $R with its acknowledgement digest" \
        "scripts/catalog-content-release.sh --deploy --commit $main_sha --pricing-diff-sha256 $pricing --preflight-verdict '$verdict'" \
        "a pricing release needs the operator's acknowledgement of the shown price table"
      next_meta catalog_activation "$TREE_DOC#preflight-and-the-price-table" "none expected for buyers: SIGHUP reload of rate card and release"
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
      set_next catalog_activation blocked "Activate $R" "python3 -m json.tool '$verdict'" \
        "preflight NO_GO: fix every failing check, then preflight again"
    fi
  fi

  # Boot-only canary bank: a SIGHUP-loaded native-bound release needs a restart.
  local restart_needed=false
  if [ "$native_bound" = true ] && [ "$live_rid" = "$R" ] && [ -n "$uptime" ] && [ -n "$verified_min" ]; then
    restart_needed="$(python3 - "$uptime" "$verified_min" <<'PY'
import datetime, sys
now = datetime.datetime.now(datetime.timezone.utc)
started = now - datetime.timedelta(seconds=int(sys.argv[1]))
verified = datetime.datetime.strptime(sys.argv[2], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
print("true" if verified - started > datetime.timedelta(seconds=120) else "false")
PY
)"
  fi
  fact coordinator_restart_needed_for_bank "$restart_needed"
  if [ "$restart_needed" = true ]; then
    step coordinator_restart pending "feeds were reloaded after boot; canary bank is boot-only"
    set_next coordinator_restart mutate "Restart the coordinator so the native canary loads the $R self-test bank" \
"ssh \"\$PEARL_SSH\" 'flock -n /run/lock/macprovider-pearl-updater.lock flock -n /opt/macprovider/.coordinator-deploy.lock systemctl restart macprovider-coordinator'
for i in \$(seq 1 24); do curl -sf -m 5 \"\$COORDINATOR_URL/healthz\" && exit 0; sleep 5; done; echo 'coordinator not healthy after 120 s' >&2; exit 1"
    next_meta coordinator_restart "$ROLLOUT_DOC" "coordinator restart: a few seconds of buyer outage"
  elif [ "$live_rid" = "$R" ]; then
    step coordinator_restart "done" "booted on or after the release load"
  else
    step coordinator_restart pending "after activation"
  fi

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

  if [ "$p_mtp_enabled" = true ] && { [ "$p_mtp_mode" = eligible ] || [ "$p_mtp_mode" = active ]; } && [ "$p_cb_active" = true ]; then
    step live_probe "done" "native_mtp $p_mtp_mode, continuous_batching active"
  else
    step live_probe pending "native_mtp enabled=$p_mtp_enabled mode=$p_mtp_mode cb_active=$p_cb_active"
    [ -z "$p_rid" ] || set_next live_probe manual "Turn the tuple on for the provider (native_mtp_mode: auto) and restart it" \
"# docs/runbooks/native-mtp-enablement.md step 9 (operator approval: restarts live.malibu.provider)
# set native_mtp_mode: auto in the provider config, restart, then confirm /v1/status
# native_mtp.enabled=true, mode eligible|active, continuous_batching.active=true"
    next_meta live_probe "$MTP_DOC#order"
  fi

  # The proof expires: a marker older than 24 h is re-verified.
  if marker_done "$OPS_SCOPE" gateway_proof &&
    [ -n "$(find "$(marker_path "$OPS_SCOPE" gateway_proof)" -mmin -1440 2>/dev/null)" ]; then
    step gateway_proof "done" "$(marker_field "$OPS_SCOPE" gateway_proof 'd.get("evidence")')"
  else
    step gateway_proof pending "$(marker_done "$OPS_SCOPE" gateway_proof && echo 'previous proof older than 24 h' || true)"
    set_next gateway_proof read "Send one real buyer request through the gateway" \
      "scripts/ops/catalog-activate.sh _gateway-proof"
    next_meta gateway_proof "AGENTS.md#hard-rules--activation-evidence-and-campaign-discipline"
  fi

  set_next "done" "done" "$R active and proven through the gateway" ""
}

# provider_counters FILE -> "mtp_forwards requests_total cb_active" from a
# provider /v1/status document; fails when the counters are absent.
provider_counters() {
  python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
mtp = (d.get("native_mtp") or {}).get("mtp_forwards")
req = d.get("requests_total")
cb = (d.get("continuous_batching") or {}).get("active") is True
if not isinstance(mtp, int) or not isinstance(req, int):
    sys.exit(1)
print(mtp, req, "true" if cb else "false")
PY
}

read_provider_status() {
  studio_ssh "curl -s -m 10 http://127.0.0.1:$STUDIO_STATUS_PORT/v1/status" > "$1" ||
    refuse "provider /v1/status not readable over STUDIO_SSH"
}

# proof_moved B_MTP B_REQ B_CB A_MTP A_REQ A_CB: the request moved the provider.
proof_moved() {
  [ $(($4 - $1)) -gt 0 ] || { [ "$3" = true ] && [ "$6" = true ] && [ $(($5 - $2)) -gt 0 ]; }
}

# One bounded buyer request through the gateway, tied to the target provider:
# its native_mtp.mtp_forwards (or, with continuous batching active, its
# requests_total) must increase across the request, the response must carry
# a request id, and the gateway's X-Provider-Id (phase5-gateway
# internal/router/chat_proxy.go emitProviderAttribution) must equal the
# provider_id the canary reports in /v1/status, so other traffic on the
# provider cannot satisfy the proof. Prints status, request id and counter
# deltas only; the provider id itself is never printed.
gateway_proof() {
  local gw model token_file
  gw="$(gateway_url)"
  [ -n "$gw" ] || refuse "GATEWAY_URL is unset"
  token_file="${BUYER_TOKEN_FILE:-}"
  [ -n "$token_file" ] && [ -f "$token_file" ] || refuse "BUYER_TOKEN_FILE must name a readable buyer token file"
  require_studio_ssh
  case "${STUDIO_STATUS_PORT:-}" in ""|*[!0-9]*) refuse "STUDIO_STATUS_PORT must be set and numeric" ;; esac
  model="${PROBE_MODEL:-$(json_field "$REPO_ROOT/$AUTOTUNE/native-mtp-admission.json" 'd["entries"][0]["model_key"]')}"
  [ -n "$model" ] || refuse "PROBE_MODEL is unset and no admission model_key was found"

  local before after b_mtp b_req b_cb a_mtp a_req a_cb
  read_provider_status "$OPS_TMP_DIR/before.json"
  before="$(provider_counters "$OPS_TMP_DIR/before.json")" || refuse "provider status lacks native_mtp.mtp_forwards/requests_total"
  read -r b_mtp b_req b_cb <<< "$before"
  local canary_pid
  canary_pid="$(json_field "$OPS_TMP_DIR/before.json" 'd["provider_id"]')"
  [ -n "$canary_pid" ] || refuse "provider /v1/status reports no provider_id; cannot tie the proof to it"

  local body="$OPS_TMP_DIR/proof.json" headers="$OPS_TMP_DIR/proof.headers" code sent_rid payload
  sent_rid="ops-proof-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
  payload="$(python3 -c 'import json,sys; print(json.dumps({"model": sys.argv[1], "max_tokens": 32, "messages": [{"role": "user", "content": "Reply with the word ok."}]}))' "$model")"
  # The bearer goes through curl --config on stdin, never argv.
  code="$(printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '\r\n' < "$token_file")" |
    curl -sS -m 120 --config - -D "$headers" -o "$body" -w '%{http_code}' \
      -H 'Content-Type: application/json' -H "X-Request-ID: $sent_rid" \
      -d "$payload" "$gw/v1/chat/completions")" || code=000
  local rid
  rid="$(awk -F': ' 'tolower($1)=="x-request-id"{gsub("\r","",$2); print $2}' "$headers" | head -n1)"
  [ "$code" = "200" ] || die "gateway returned HTTP $code for $model (request id ${rid:-none})"
  [ -n "$rid" ] || die "gateway response carries no X-Request-ID"
  local served_pid
  served_pid="$(awk -F': ' 'tolower($1)=="x-provider-id"{gsub("\r","",$2); print $2}' "$headers" | head -n1)"
  [ -n "$served_pid" ] || die "gateway response carries no X-Provider-Id (request $rid)"
  [ "$served_pid" = "$canary_pid" ] || die "request $rid was served by another provider, not the canary"
  [ -n "$(json_field "$body" 'd["choices"][0]["message"]["content"]')" ] || die "gateway 200 without completion content"

  local i
  for i in 1 2 3 4 5 6; do
    read_provider_status "$OPS_TMP_DIR/after.json"
    after="$(provider_counters "$OPS_TMP_DIR/after.json")" || refuse "provider status lacks counters after the request"
    read -r a_mtp a_req a_cb <<< "$after"
    proof_moved "$b_mtp" "$b_req" "$b_cb" "$a_mtp" "$a_req" "$a_cb" && break
    [ "$i" -lt 6 ] && sleep "${PROOF_POLL_SECONDS:-2}"
  done
  proof_moved "$b_mtp" "$b_req" "$b_cb" "$a_mtp" "$a_req" "$a_cb" ||
    die "request $rid did not move the target provider: mtp_forwards +$((a_mtp - b_mtp)), requests_total +$((a_req - b_req)) (cb_active=$a_cb)"
  local evidence="HTTP 200 model=$model request_id=$rid served_by=canary mtp_forwards+$((a_mtp - b_mtp)) requests_total+$((a_req - b_req)) cb_active=$a_cb"
  log "gateway proof: $evidence"
  mark_done "$OPS_SCOPE" gateway_proof "$evidence" \
    "$(python3 -c 'import json,sys; import hashlib; print(json.dumps({"request_id": sys.argv[1], "sent_request_id": sys.argv[2], "mtp_forwards_delta": int(sys.argv[3]), "requests_total_delta": int(sys.argv[4]), "served_by_canary": True, "provider_id_sha256": hashlib.sha256(sys.argv[5].encode()).hexdigest()}))' "$rid" "$sent_rid" "$((a_mtp - b_mtp))" "$((a_req - b_req))" "$served_pid")"
}

internal() {
  case "$1" in
    _gateway-proof)
      R="$(json_field "$REPO_ROOT/$AUTOTUNE/release.json" 'd["release_id"]')"
      OPS_SCOPE="catalog-$R"
      gateway_proof ;;
    *) usage >&2; exit 2 ;;
  esac
}

ops_main "$@"
