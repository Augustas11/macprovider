#!/usr/bin/env bash
# F: the fake shard group on pool S (left available by P), speaking the real
# SPEC-051 wire with real Ed25519 receipt keys. Every buyer request enters
# through nginx -> gateway -> coordinator unless a step says "direct" (pins).
#   F1  R016/R020 paid pool traffic served by the head, settled at the entry
#       price, every receipt with a verified group attestation (R019)
#   F2  R016/R009 never global, never a member, pins refused
#   F3  R015 availability reasons (head view, member view, sessions, owner)
#   F4  R019 attestation faults (+ R3-A1 coverage probe) and buyer cancel
#   F5  R021 pre-first-token failure, R022 mid-stream failure accounting
#   F6  slot-queue shard gate (R016)
#   F7  R3-C03/R3-A2 record pool model vs bound pool model
#   F8  R028 extension removed / restored by rotation, R030 omitted
#   F9  coordinator restart mid-session (persistence, epoch floor)
#   F10 SIGHUP of shard_groups
#   F11 R024 catalog traffic unchanged, members never dispatched
#   F12 R023/R005 epoch bump, member_not_joined, takeover attestation,
#       registration budget, epoch retention
set -uo pipefail
. /root/e2e/h/vm/lib.sh; . $E2E_H/vm/lib-deploy.sh; . $E2E_H/vm/lib-scn.sh; . /root/e2e/h16/vm/lib-1816.sh; . /root/e2e/h84/vm/lib-2084.sh
EV=$E2E_EVIDENCE/p$PASS_ID-f; mkdir -p "$EV"
[ "$(sides)" = new/new ] || die "F needs the new pair"
MS="$(pmid S shard-s)"
ACCT="$(gwsql "SELECT account_id FROM accounts LIMIT 1")"
GST="$(sed -n 's/^GATEWAY_SERVICE_TOKEN=//p' /etc/macprovider/coordinator.env)"
EPOCH_FILE=/root/e2e/shard-epoch; [ -s $EPOCH_FILE ] || echo 1 >$EPOCH_FILE
epoch() { cat $EPOCH_FILE; }

wait_head true "" 90 >/dev/null || { result F0-precondition FAIL "group not available at start: $(head_state)"; exit 1; }
result F0-precondition PASS "group available: $(head_state)"

# req <label> [stream] [pool S|""] [model] [curl args]: buyer request through
# nginx; sets CODE (HTTP status), RID (client request id) and CID
# (coordinator request id) in the calling shell.
req() {
  local label="$1" stream="${2:-false}" pool="${3-S}" model="${4:-$MS}"; shift 4 2>/dev/null || shift $#
  # the gateway keeps a client X-Request-ID only when it is a UUID
  RID="$(cat /proc/sys/kernel/random/uuid)"
  local hdr=() bk; bk="$(cat /root/e2e/buyer-api-key)"
  [ -n "$pool" ] && hdr=(-H "X-MacProvider-Pool-Select: $(pool_id "$pool")")
  CODE="$(curl_bearer "$bk" -s -o "$EV/$label.body" -D "$EV/$label.headers" -w '%{http_code}' --max-time 120 https://api.malibu.tech/v1/chat/completions \
    -H 'Content-Type: application/json' -H "X-Request-ID: $RID" "${hdr[@]}" "$@" \
    -d "{\"model\":\"$model\",\"stream\":$stream,\"max_tokens\":64,\"messages\":[{\"role\":\"user\",\"content\":\"shard e2e $label $RID\"}]}")"
  echo "$label $RID" >>"$EV/request-ids.txt"
  CID=""; local i; for i in 1 2 3 4 5; do CID="$(csql "SELECT request_id FROM request_log WHERE external_request_id='$RID' ORDER BY rowid DESC LIMIT 1")"; [ -n "$CID" ] && break; sleep 1; done
}
# direct <label> <model> [headers...]: straight to the coordinator buyer mux
# the way the gateway sends it (service token, account), for pin headers the
# gateway does not forward.
direct() {
  local label="$1" model="$2"; shift 2
  curl_bearer "$GST" -s -o "$EV/$label.body" -D "$EV/$label.headers" -w '%{http_code}' --max-time 60 http://127.0.0.1:8443/v1/chat/completions \
    -H "X-MacProvider-Account: $ACCT" -H "X-Request-ID: $label-$(date +%s%N)" -H 'Content-Type: application/json' "$@" \
    -d "{\"model\":\"$model\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"pin $label\"}]}"
}
errcode() { python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1])); e=d.get("error") or {}
    print(e.get("code") or e.get("type") or "" if isinstance(e,dict) else e)
except Exception: print(open(sys.argv[1],errors="replace").read()[:120].replace("\n"," "))' "$EV/$1.body"; }
disp() { counter $HEAD dispatches; }
swu() { counter $HEAD served_while_unavailable; }
memd() { echo "$(counter $M1 member_dispatches)/$(counter $SPARE member_dispatches)"; }
# set_epoch <n> [stage1] [spares-json]: bump the shared group file
set_epoch() { echo "$1" >$EPOCH_FILE; write_group "$@"; }
reg_result_for() {  # reg_result_for <epoch> [max]: wait until the head has a register_result for that epoch; prints accepted:reason
  local e="$1" max="${2:-30}" t=0 r
  while [ "$t" -le "$max" ]; do
    r="$(shard_status $HEAD | python3 -c 'import json,sys
r=json.load(sys.stdin)["shard"].get("register_result") or {}
print("%s:%s:%s" % (r.get("group_epoch",""), str(r.get("accepted","")).lower(), r.get("reason","")))' 2>/dev/null)"
    [ "${r%%:*}" = "$e" ] && { echo "${r#*:}"; return 0; }
    sleep 1; t=$((t + 1))
  done
  echo "none:$r"; return 1
}

# ---- F1 paid pool traffic ----------------------------------------------------------
d0="$(disp)"
run="$(run_id f1)"
POOL_TRAFFIC_EXTRA=(--read-to-eof)
pool_traffic "$run" S "$MS" "" "ns=3,st=3" 2 >/dev/null
POOL_TRAFFIC_EXTRA=()
pool_check F1-pool-traffic-settles "$run" --expect ns=settled,st=settled --min-settled 6 --pool-model-id "$MS" --rates $S_RATES --tokens 8,12 \
  --usage-source coordinator_observed --token-source coordinator_observed --provider $HEAD
ids="$(python3 -c 'import json,sys;print(",".join("\x27%s\x27" % json.loads(l)["rid"] for l in open(sys.argv[1])))' "$E2E_EVIDENCE/$run.load.jsonl")"
att="$(csql "SELECT COUNT(*)||'/'||SUM(a.verdict='verified') FROM request_log r JOIN shard_group_attestations a ON a.request_id=r.request_id WHERE r.external_request_id IN ($ids) AND r.status=200")"
n200="$(csql "SELECT COUNT(DISTINCT request_id) FROM request_log WHERE external_request_id IN ($ids) AND status=200")"
[ "$att" = "$n200/$n200" ] && [ "$n200" -ge 6 ] && result F1-attestations-verified PASS "$n200 head-served 200s, each with a verified stored group attestation ($att)" \
  || result F1-attestations-verified FAIL "200s served by head=$n200, attestations total/verified=$att"
# A buyer that closes the moment it reads [DONE], before the head's terminal
# frame reached the coordinator (finding V-3, every WS-tunnelled stream).
run="$(run_id f1done)"
pool_traffic "$run" S "$MS" "" "st=3" 1 >/dev/null
DRAIN_MAX=420 pool_check F1-stream-buyer-closes-at-done "$run" --expect st=settled --min-settled 3 --pool-model-id "$MS" --rates $S_RATES --tokens 8,12 \
  --usage-source coordinator_observed --token-source coordinator_observed --provider $HEAD
[ "$(memd)" = "0/0" ] && result F1-member-never-routed PASS "member and spare sessions received no buyer work; head dispatches $d0 -> $(disp)" || result F1-member-never-routed FAIL "member/spare dispatches $(memd)"

# ---- F2 never global / never a member / pins -----------------------------------------
d0="$(disp)"
req f2-global-poolmodel false ""; c1="$CODE"; e1="$(errcode f2-global-poolmodel)"
req f2-global-execlabel false "" "$SHARD_MODEL"; c2="$CODE"; e2="$(errcode f2-global-execlabel)"
c3="$(direct f2-pin-member "$MS" -H "X-MacProvider-Pool: $(pool_id S)" -H "X-MacProvider-Provider: $M1")"; e3="$(errcode f2-pin-member)"
c4="$(direct f2-pin-head-global "$SHARD_MODEL" -H "X-MacProvider-Provider: $HEAD")"; e4="$(errcode f2-pin-head-global)"
d1="$(disp)"
if [ "$c1" != 200 ] && [ "$c2" != 200 ] && [ "$c3" != 200 ] && [ "$c4" != 200 ] && [ "$d0" = "$d1" ] && [ "$(memd)" = "0/0" ]; then
  result F2-never-global-never-member PASS "global pool-model $c1 $e1; global execution label $c2 $e2; pin member $c3 $e3; pin head on a global route $c4 $e4; head dispatches unchanged ($d1)"
else result F2-never-global-never-member FAIL "global $c1/$e1 label $c2/$e2 pin-member $c3/$e3 pin-head $c4/$e4 dispatches $d0->$d1 member $(memd)"; fi
# relay-blind and privacy-class requests: the gateway route for both needs a
# client-side sealed body; their exclusion is the coordinator binding gate
# (relayBlindBindable) covered by unit tests, so this step records the gap.
result F2-relay-blind-privacy GAP "relay-blind/privacy-class buyer requests need a SPEC-041/049 client; exclusion covered by buyer unit tests (relayBlindBindable), not driven here"

# ---- F3 availability reasons ------------------------------------------------------------
# reason_case <label> <reason> <setup> <teardown> [max-wait]
reason_case() {
  local label="$1" reason="$2" setup="$3" teardown="$4" max="${5:-30}" st c e d0 s0
  d0="$(disp)"; s0="$(swu)"
  eval "$setup"
  if st="$(wait_head false "$reason" "$max")"; then
    req "$label" false; c="$CODE"; e="$(errcode "$label")"
    if [ "$c" != 200 ] && [ "$(disp)" = "$d0" ] && [ "$(swu)" = "$s0" ]; then
      result "$label" PASS "group unavailable with $reason (status $st); pool request $c $e; head not dispatched"
    else result "$label" FAIL "unavailable ($st) but pool request $c $e; dispatches $d0->$(disp) served_while_unavailable $s0->$(swu)"; fi
  else result "$label" FAIL "expected reason $reason within ${max}s, head state $st; events: $(shard_events '3 min ago' | tail -3 | tr '\n' ' ' | head -c 500)"; fi
  eval "$teardown"
  st="$(wait_head true "" 150)" || result "$label-recovers" FAIL "did not return to available after teardown: $st"
}
reason_case F3-member-unhealthy member_unhealthy "knob $HEAD '{\"unhealthy_members\":[\"$M1\"]}'" "knob_clear $HEAD"
reason_case F3-link-interface-head-view link_interface_invalid "knob $HEAD '{\"link_interface\":\"wifi\"}'" "knob_clear $HEAD"
reason_case F3-link-rtt-exceeded link_rtt_exceeded "knob $HEAD '{\"link_rtt_p99_us\":2500}'" "knob_clear $HEAD"
reason_case F3-member-self-unhealthy member_self_unhealthy "knob $M1 '{\"self_healthy\":false,\"self_reason\":\"link_down\"}'" "knob_clear $M1"
reason_case F3-link-interface-member-view link_interface_invalid "knob $M1 '{\"health_interface\":\"vpn\"}'" "knob_clear $M1"
reason_case F3-member-session-missing member_session_missing "systemctl stop e2e-shardprov@12" "systemctl start e2e-shardprov@12"
reason_case F3-owner-mismatch owner_mismatch "csql \"UPDATE provider_ownership SET github_user_id=$OTHER_GH WHERE provider_id='$M1'\"" "csql \"UPDATE provider_ownership SET github_user_id=$OWNER_GH WHERE provider_id='$M1'\"" 45
reason_case F3-member-not-admissible member_not_admissible "shard_env 12 member $(printf 'e2e-2084 other snapshot' | sha256sum | cut -c1-64); systemctl restart e2e-shardprov@12" "shard_env 12 member; systemctl restart e2e-shardprov@12" 40
reason_case F3-group-heartbeat-stale group_heartbeat_stale "knob $HEAD '{\"heartbeat\":false}'" "knob_clear $HEAD" 150
reason_case F3-member-health-stale member_health_stale "knob $M1 '{\"health\":false}'" "knob_clear $M1" 150
# a spare's health and session never affect availability (R015)
knob $HEAD "{\"unhealthy_members\":[\"$SPARE\"],\"link_interface\":\"ethernet\"}"; systemctl stop e2e-shardprov@13; sleep 6
st="$(head_state)"; req f3-spare-down false; c="$CODE"
[ "${st%%:*}" = true ] && [ "$c" = 200 ] && result F3-spare-does-not-gate PASS "spare unhealthy and its session gone: group stays available ($st), pool request 200" \
  || result F3-spare-does-not-gate FAIL "state $st pool request $c $(errcode f3-spare-down)"
knob_clear $HEAD; systemctl start e2e-shardprov@13; sleep 5
wait_head true "" 60 >/dev/null

# ---- F4 attestation verification ----------------------------------------------------------
att_case() {  # att_case <mode> <want-verdict> <want-fault> <want-member>
  local mode="$1" vw="$2" fw="$3" mw="$4" c row
  knob $HEAD "{\"attest\":\"$mode\"}"
  req "f4-$mode" false; c="$CODE"; sleep 2
  row="$(attestation_row "$CID")"
  local rv; rv="$(csql "SELECT group_concat(receipt_result||'/'||settlement_outcome, ' ') FROM settlement_receipt_verdicts WHERE request_id='$CID'")"
  if [ "$row" = "$vw|$fw|$mw|0|" ] && { [ "$vw" = verified ] || ! echo "$rv" | grep -q '^verified/'; }; then
    result "F4-attest-$mode" PASS "buyer $c; stored verdict $row; receipt verdict [$rv]"
  else result "F4-attest-$mode" FAIL "buyer $c cid=$CID; stored [$row] want [$vw|$fw|$mw|0|]; receipt verdict [$rv]"; fi
}
att_case ok verified "" ""
att_case missing failed attestation_missing $HEAD
att_case bad_head_signature failed head_signature_invalid $HEAD
att_case receipt_mismatch failed receipt_mismatch $HEAD
att_case chain_break failed digest_chain_break $M1
att_case coverage failed coverage_invalid $M1
att_case stage_mismatch failed stage_mismatch $M1
att_case wrong_key failed key_mismatch $M1
att_case member_signature failed member_signature_invalid $M1
att_case unknown_epoch failed epoch_unknown $HEAD
att_case two_segments failed segments_invalid $HEAD
att_case takeover_bad_reason failed takeover_invalid $HEAD
# R3-A1: the receipt's v0.4 usage counts 12 output tokens; the attestation's
# step_end says 1. SPEC-051-R019 item 7 makes that coverage_invalid.
att_case coverage_tokens_out failed coverage_invalid $HEAD
knob_clear $HEAD
# buyer cancel mid-stream: the cancelled terminal's receipt is verified like any other
knob $HEAD '{"chunk_delay_ms":400}'
req f4-cancel true S "$MS" --max-time 2; sleep 6
row="$(attestation_row "$CID")"
[ -n "$CID" ] && [ "${row%%|*}" = verified ] && result F4-buyer-cancel-attested PASS "buyer cancel: cancelled terminal attestation stored verified ($row)" \
  || result F4-buyer-cancel-attested FAIL "cid=$CID attestation [$row] verdict [$(csql "SELECT receipt_result||'/'||reason FROM settlement_receipt_verdicts WHERE request_id='$CID'")]"
knob_clear $HEAD

# ---- F5 failure accounting --------------------------------------------------------------
knob $HEAD '{"fail_before_first_token":true}'
req f5-prefirst false; c="$CODE"; e="$(errcode f5-prefirst)"; sleep 3
rows="$(csql "SELECT group_concat(l.attempt_n||':'||l.provider_id||'/'||l.status||'/'||coalesce(l.fault_flag,'')||'/'||l.gross_credits||'/'||l.provider_credits, ' ') FROM ledger_request_credits l WHERE l.request_id IN (SELECT request_id FROM request_log WHERE external_request_id='$RID')" 2>&1)"
paid="$(csql "SELECT COALESCE(SUM(provider_credits),0) FROM ledger_request_credits WHERE request_id IN (SELECT request_id FROM request_log WHERE external_request_id='$RID')")"
deb="$(gwsql "SELECT status||'/'||coalesce(settled_tokens,0) FROM quota_reservations WHERE request_id='$RID'")"
if [ "$c" != 200 ] && ! echo "$deb" | grep -q '^settled/[1-9]' && [ "${paid:-0}" = 0 ]; then
  result F5-pre-first-token PASS "buyer $c $e; attempt rows [$rows]; gateway reservation $deb (no debit)"
else result F5-pre-first-token FAIL "buyer $c $e rows [$rows] reservation $deb"; fi
knob $HEAD '{"fail_after_chunks":3}'
req f5-midstream true; c="$CODE"; sleep 3
dl="$(grep -c '"content"' "$EV/f5-midstream.body")"
deb="$(gwsql "SELECT status||'/'||coalesce(settled_tokens,0) FROM quota_reservations WHERE request_id='$RID'")"
tok="$(gwsql "SELECT coalesce(SUM(total_tokens),0) FROM usage_events WHERE request_id='$RID'")"
if [ "$dl" -le 3 ] && [ "${tok:-0}" -le 11 ]; then
  result F5-mid-stream PASS "buyer $c with $dl content events then an error; debit $tok tokens <= prompt 8 + delivered 3; reservation $deb"
else result F5-mid-stream FAIL "buyer $c delivered events $dl, debited $tok (reservation $deb) body tail: $(tail -c 300 "$EV/f5-midstream.body" | tr '\n' ' ')"; fi
knob_clear $HEAD
drain "$(run_id f1)" 60 >/dev/null 2>&1 || true

# ---- F6 slot queue gate --------------------------------------------------------------------
knob $HEAD '{"chunk_delay_ms":500}'
d0="$(disp)"
for i in 1 2 3; do (req "f6-queue-ok-$i" true; echo "$CODE" >"$EV/f6-queue-ok-$i.code") & sleep 0.3; done; wait
codes="$(cat "$EV"/f6-queue-ok-*.code | tr '\n' ' ')"
[ "$codes" = "200 200 200 " ] && [ $(( $(disp) - d0 )) -eq 3 ] && result F6-slot-queue-serves-head PASS "3 streams on a 2-slot head: all 200 (one queued), dispatches +3" \
  || result F6-slot-queue-serves-head FAIL "codes [$codes] dispatches $d0 -> $(disp)"
d0="$(disp)"; s0="$(swu)"
for i in 1 2 3; do (req "f6-queue-gate-$i" true; echo "$CODE" >"$EV/f6-queue-gate-$i.code") & sleep 0.3; done
sleep 1.5; knob $HEAD "{\"chunk_delay_ms\":500,\"unhealthy_members\":[\"$M1\"]}"; wait
codes="$(cat "$EV"/f6-queue-gate-*.code | tr '\n' ' ')"
if [ $(( $(disp) - d0 )) -le 2 ] && [ "$(swu)" = "$s0" ]; then
  result F6-slot-queue-gate PASS "group went unavailable while a request was queued: dispatches +$(( $(disp) - d0 )), none while unavailable; codes [$codes]"
else result F6-slot-queue-gate FAIL "dispatches $d0 -> $(disp), served_while_unavailable $s0 -> $(swu), codes [$codes]"; fi
knob_clear $HEAD; wait_head true "" 60 >/dev/null

# ---- F7 record pool model vs bound pool model (R3-C03 / R3-A2) -------------------------------
e=$(( $(epoch) + 1 )); set_epoch $e
other="pool/$(pool_id S)/not-the-bound-entry"
knob $HEAD "{\"record_override\":{\"model\":{\"model_id\":\"$SHARD_MODEL\",\"pool_model_id\":\"$other\",\"artifact_hash_algorithm\":\"macprovider.snapshot-manifest.v1\",\"artifact_hash\":\"$H_SHARD\"}}}"
r="$(reg_result_for $e 30)"; sleep 4
st="$(head_state)"; d0="$(disp)"; req f7-record-model-mismatch false; c="$CODE"
if [ "$c" != 200 ] && [ "$(disp)" = "$d0" ]; then
  result F7-record-pool-model-binds-route PASS "record epoch $e names $other (register $r, state $st); request for the bound $MS refused $c $(errcode f7-record-model-mismatch)"
else result F7-record-pool-model-binds-route FAIL "record epoch $e names $other (register $r, state $st) but the head served $MS ($c, dispatches $d0 -> $(disp)): SPEC-051-R016 'only for the pool model the group record names'"; fi
knob_clear $HEAD
e=$(( $(epoch) + 1 )); set_epoch $e; reg_result_for $e 30 >/dev/null
wait_head true "" 60 "$e" >/dev/null || result F7-restore FAIL "group not available again at epoch $e: $(head_state)"

# ---- F8 R028 extension removed by rotation, then restored ------------------------------------
$PM stage S --unshard $HEAD >/dev/null
out="$($PM manifest S 2>&1)"; v="$(echo "$out" | sed -n 's/^accepted v\([0-9]*\) .*/\1/p')"
if [ -n "$v" ] && wait_window S "$v"; then
  sleep 3; d0="$(disp)"; req f8-unauthorized false; c="$CODE"
  curl_bearer "$GST" -s -H "X-MacProvider-Account: $ACCT" "http://127.0.0.1:8443/v1/trust-pools/$(pool_id S)/pool_policy.json" >"$EV/f8-policy.json"
  if [ "$c" != 200 ] && [ "$(disp)" = "$d0" ] && ! grep -q multi_mac_serving "$EV/f8-policy.json"; then
    result F8-extension-removed PASS "core v$v without pool_shard_groups/v1 active: pool request $c $(errcode f8-unauthorized), head not selected, disclosure omitted (R030)"
  else result F8-extension-removed FAIL "v$v active: request $c dispatches $d0 -> $(disp) disclosure-present=$(grep -c multi_mac_serving "$EV/f8-policy.json")"; fi
else result F8-extension-removed FAIL "unshard manifest: $out"; fi
$PM stage S --shard-group $HEAD shard-s 3 >/dev/null
out="$($PM manifest S 2>&1)"; v="$(echo "$out" | sed -n 's/^accepted v\([0-9]*\) .*/\1/p')"
if [ -n "$v" ] && wait_window S "$v"; then
  sleep 3; req f8-restored false; c="$CODE"
  [ "$c" = 200 ] && result F8-extension-restored PASS "core v$v names the group again: pool request 200" || result F8-extension-restored FAIL "v$v: request $c $(errcode f8-restored)"
else result F8-extension-restored FAIL "reshard manifest: $out"; fi

# ---- F9 coordinator restart mid-session ------------------------------------------------------
recs0="$(csql "SELECT COUNT(*) FROM shard_group_records WHERE group_provider_id='$HEAD'")"
att0="$(csql "SELECT COUNT(*) FROM shard_group_attestations")"
knob $HEAD '{"chunk_delay_ms":500}'
(req f9-inflight true; echo "$CODE" >"$EV/f9-inflight.code") & sleep 2
coord_restart >/dev/null 2>&1; wait
knob_clear $HEAD
if st="$(wait_head true "" 120 "$(epoch)")"; then
  # The head's pool-scoped binding is restored by the coordinator's pool
  # binding sweep after its new session, not at the reconnect itself.
  t0=$(date +%s); req f9-after false; c="$CODE"
  while [ "$c" != 200 ] && [ $(( $(date +%s) - t0 )) -lt 180 ]; do sleep 5; req f9-after false; c="$CODE"; done
  result F9-rebind-after-restart INFO "first routable pool request $(( $(date +%s) - t0 )) s after the group was available again (pool binding sweep)"
  sleep 2
  recs1="$(csql "SELECT COUNT(*) FROM shard_group_records WHERE group_provider_id='$HEAD'")"
  att1="$(csql "SELECT COUNT(*) FROM shard_group_attestations")"
  row="$(attestation_row "$CID")"
  [ "$c" = 200 ] && [ "$recs1" = "$recs0" ] && [ "$att1" -gt "$att0" ] && [ "${row%%|*}" = verified ] \
    && result F9-restart-persistence PASS "in-flight stream during restart: $(cat "$EV/f9-inflight.code"); group re-registered the same epoch without a new row ($recs0 records), available ($st), new request 200 with a verified attestation; attestations $att0 -> $att1" \
    || result F9-restart-persistence FAIL "after restart: request $c, records $recs0 -> $recs1, attestations $att0 -> $att1, last row [$row]"
else result F9-restart-persistence FAIL "group not available after the coordinator restart: $st; events $(shard_events '3 min ago' | tail -4 | tr '\n' ' ' | head -c 600)"; fi
knob $HEAD '{"record_override":{"group_epoch":1}}'
r="$(reg_result_for 1 20)"
[ "$r" = "false:epoch_not_increasing" ] && result F9-epoch-floor-survives-restart PASS "a record at epoch 1 after the restart is refused epoch_not_increasing (store floor)" \
  || result F9-epoch-floor-survives-restart FAIL "epoch-1 record after restart: $r"
knob_clear $HEAD; e=$(( $(epoch) + 1 )); set_epoch $e; reg_result_for $e 30 >/dev/null; wait_head true "" 60 "$e" >/dev/null

# ---- F10 SIGHUP of shard_groups --------------------------------------------------------------
cp /opt/macprovider/coordinator.yaml "$EV/coordinator.yaml.pre-sighup"
since="$(mark)"
coord_yaml_edit "c.setdefault('shard_groups', {}).update(max_link_rtt_p99_us=300)"
systemctl kill -s HUP macprovider-coordinator; sleep 8
journal_since macprovider-coordinator "$since" "$EV/sighup.log"
st="$(head_state)"
if [ "${st%%:*}" = false ] && echo "$st" | grep -q link_rtt_exceeded; then
  result F10-sighup-shard-groups PASS "SIGHUP applied shard_groups.max_link_rtt_p99_us=300: group unavailable with link_rtt_exceeded"
elif grep -qi 'shard_groups.*\(restart\|rejected\)\|\(restart\|rejected\).*shard_groups' "$EV/sighup.log"; then
  result F10-sighup-shard-groups PASS "SIGHUP refused the shard_groups change clearly: $(grep -i shard_groups "$EV/sighup.log" | tail -1 | head -c 300)"
else result F10-sighup-shard-groups FAIL "SIGHUP with shard_groups.max_link_rtt_p99_us=300 neither applied (state $st) nor refused with a log line; reload log: $(grep -i 'reload' "$EV/sighup.log" | tail -2 | tr '\n' ' ' | head -c 300)"; fi
install -o root -g root -m 0644 "$EV/coordinator.yaml.pre-sighup" /opt/macprovider/coordinator.yaml
coord_restart >/dev/null 2>&1; wait_head true "" 120 >/dev/null

# ---- F11 catalog traffic unchanged ------------------------------------------------------------
wait_providers 2 || true
run="$(run_id f11)"; MODEL=meta-llama/llama-3.2-3b-instruct traffic "$run" "ns=3,st=3" >/dev/null
settle_and_check F11-catalog-unchanged "$run" --expect ns=settled,st=settled
[ "$(memd)" = "0/0" ] && result F11-members-never-dispatched PASS "after every F step: member/spare dispatches 0/0" || result F11-members-never-dispatched FAIL "member/spare dispatches $(memd)"

# ---- F12 epochs: bump, member_not_joined, takeover, budget, retention -------------------------
knob $M1 '{"hello":false}'
e=$(( $(epoch) + 1 )); set_epoch $e
if st="$(wait_head false member_not_joined 30)"; then result F12-member-not-joined PASS "epoch $e registered, member hello withheld: $st"
else result F12-member-not-joined FAIL "epoch $e with member hello withheld: $st"; fi
knob_clear $M1
st="$(wait_head true "" 40 "$e")" && result F12-epoch-bump PASS "member hello for epoch $e accepted: available ($st)" || result F12-epoch-bump FAIL "$st"
# takeover: the spare replaces the stage-1 member in the next epoch
from=$e; e=$(( e + 1 )); set_epoch $e "$SPARE" "[{\"member_device_id\":\"$M1\",\"stage_index\":1}]"
if st="$(wait_head true "" 40 "$e")"; then
  knob $HEAD "{\"attest\":\"takeover\",\"takeover_from_epoch\":$from,\"takeover_reason\":\"peer_dead\"}"
  req f12-takeover false; c="$CODE"; sleep 2; row="$(attestation_row "$CID")"
  [ "$c" = 200 ] && [ "$row" = "verified|||$from|peer_dead" ] && result F12-takeover-attestation PASS "spare promoted at epoch $e; takeover attestation from $from verified and stored ($row)" \
    || result F12-takeover-attestation FAIL "buyer $c stored [$row] want [verified|||$from|peer_dead]"
  knob_clear $HEAD
else result F12-takeover-attestation FAIL "promoted spare epoch $e not available: $st"; fi
# registration budget: new epochs until refused
acc=0; refused=""
for i in $(seq 1 14); do
  e=$(( $(epoch) + 1 )); set_epoch $e "$SPARE" "[{\"member_device_id\":\"$M1\",\"stage_index\":1}]"
  r="$(reg_result_for $e 20)"
  case "$r" in true:*) acc=$((acc + 1)) ;; *) refused="$e:$r"; break ;; esac
done
if echo "$refused" | grep -q 'false:registration_rate_limited'; then
  result F12-registration-budget PASS "after $acc more new epochs the next ($refused) is refused before it is stored"
else result F12-registration-budget FAIL "accepted $acc more epochs; refusal [$refused]"; fi
last=$(csql "SELECT MAX(group_epoch) FROM shard_group_records WHERE group_provider_id='$HEAD'")
stored_refused=$(csql "SELECT COUNT(*) FROM shard_group_records WHERE group_provider_id='$HEAD' AND group_epoch=${refused%%:*}")
[ "$stored_refused" = 0 ] && result F12-refused-epoch-not-stored PASS "refused epoch ${refused%%:*} has no row; latest stored $last" || result F12-refused-epoch-not-stored FAIL "refused epoch stored"
# back to the last accepted epoch so head and coordinator agree
echo "$last" >$EPOCH_FILE; write_group "$last" "$SPARE" "[{\"member_device_id\":\"$M1\",\"stage_index\":1}]"
st="$(wait_head true "" 40 "$last")" || result F12-back-to-latest FAIL "$st"
knob $HEAD "{\"attest\":\"takeover\",\"takeover_from_epoch\":$from,\"takeover_reason\":\"peer_dead\"}"
req f12-retention false; c="$CODE"; sleep 2; row="$(attestation_row "$CID")"
result F12-epoch-retention INFO "takeover from epoch $from after $(csql "SELECT COUNT(*) FROM shard_group_records WHERE group_provider_id='$HEAD'") stored epochs (8 kept in memory): buyer $c, stored [$row]"
knob_clear $HEAD
result F-summary INFO "head dispatches $(disp), served_while_unavailable $(swu), member/spare dispatches $(memd), status history $(counter $HEAD status_history | head -c 400)"
