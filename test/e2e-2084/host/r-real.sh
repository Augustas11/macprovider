#!/usr/bin/env bash
# R (host): a REAL Swift shard group on this Mac, a head and a stage-1 member
# as two `macprovider-cli serve` processes, joining the VM coordinator through
# the Lima forward (127.0.0.1:28444), serving a paid Trusted Pool request
# through the VM gateway (127.0.0.1:29443) with X-MacProvider-Pool-Select.
#
#   E2E_REAL_CLI=<dir holding the lab-harness release macprovider-cli and its
#                 mlx metallib bundle>  bash test/e2e-2084/host/r-real.sh
#
# Needs a VM pass that left the new coordinator/gateway pair (steps B1 B2 U P).
# The model is a lab copy of the local Llama-3.2-3B-Instruct-4bit snapshot with
# one non-weight file changed, so its snapshot-manifest hash is not a catalog
# identity (SPEC-051 v0.2 serves only pool-scoped entries).
#
# The live provider on this Mac: paused before any GPU work (live-ctl.py), the
# script waits for 0 in-flight, an EXIT trap and an independent 900 s watchdog
# resume it, and the script waits for buyer_serving again. It is never stopped
# or restarted.
set -uo pipefail
. "$(dirname "$0")/../env.sh"
CLI_DIR="${E2E_REAL_CLI:?set E2E_REAL_CLI to the lab-harness release build directory}"
CLI="$CLI_DIR/macprovider-cli"
LIVE_CTL="${E2E_LIVE_CTL:-$HOME/macprovider-poc/scripts/lab/cb-studio/live-ctl.py}"
LIVE_STATUS="${E2E_LIVE_STATUS:-http://127.0.0.1:61920/v1/status}"
SRC_MODEL="${E2E_REAL_SRC_MODEL:-$HOME/Library/Application Support/macprovider/models/mlx-community--Llama-3.2-3B-Instruct-4bit/7f0dc925e0d0afb0322d96f9255cfddf2ba5636e/e7e5bff4248768b4db7a53afb3b514ba5867b800f63d1abd0330eaf08e54aa90}"
MODEL_REF=mlx-community/Llama-3.2-3B-Instruct-4bit
R="$E2E_WORK/real"; EV="$R/evidence"; mkdir -p "$R" "$EV"; chmod 700 "$R"
HEAD=e2e-real-head; M1=e2e-real-m1
COORD="ws://127.0.0.1:28444/ws/provider"; GW="http://127.0.0.1:29443"
results="$EV/results.jsonl"; : >"$results"
result() { python3 -c 'import json,sys,datetime;print(json.dumps({"scenario":sys.argv[1],"result":sys.argv[2],"detail":sys.argv[3],"ts":datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}))' "$1" "$2" "$3" >>"$results"; e2e_log "[$1] $2: $3"; }

# ---- lab model copy (not a catalog identity) ---------------------------------------
# The durable-store layout <root>/<org--repo>/<revision>/<sha256>/ outside
# the durable root (serve verifies it against model_artifact_sha256).
LAB_ROOT="$R/models"; LAB_REV="$LAB_ROOT/mlx-community--Llama-3.2-3B-Instruct-4bit/7f0dc925e0d0afb0322d96f9255cfddf2ba5636e"
manifest_hash() { python3 - "$1" <<'PY'
import hashlib, os, sys
root = sys.argv[1]; entries = []
for d, _, files in os.walk(root):
    for f in files:
        p = os.path.join(d, f); rel = os.path.relpath(p, root)
        h = hashlib.sha256(open(p, "rb").read()).hexdigest()
        entries.append((rel, os.path.getsize(p), h))
print(hashlib.sha256("".join("%s\n%d\n%s\n" % e for e in sorted(entries)).encode()).hexdigest())
PY
}
if [ ! -s "$R/model-hash" ]; then
  rm -rf "$LAB_ROOT"; mkdir -p "$LAB_REV/tmp"
  cp -Rc "$SRC_MODEL/." "$LAB_REV/tmp/"
  printf '\n<!-- e2e-2084 lab copy: not a catalog artifact -->\n' >>"$LAB_REV/tmp/README.md"
  h="$(manifest_hash "$LAB_REV/tmp")"; mv "$LAB_REV/tmp" "$LAB_REV/$h"; echo "$h" >"$R/model-hash"
fi
H_REAL="$(cat "$R/model-hash")"; MODEL_DIR="$LAB_REV/$H_REAL"
[ "$H_REAL" != e7e5bff4248768b4db7a53afb3b514ba5867b800f63d1abd0330eaf08e54aa90 ] || e2e_die "lab copy hashes to the catalog identity"
e2e_log "lab model $MODEL_DIR ($H_REAL)"

# ---- VM: pool R naming the real head --------------------------------------------------
out="$(vm_script "$H_REAL" < <(printf 'bash /root/e2e/h84/vm/r-pool.sh "$1"\n'))" || e2e_die "pool R: $out"
POOL_ID="$(echo "$out" | sed -n 's/.*POOL_ID=\([^ ]*\).*/\1/p')"; POOL_MODEL="$(echo "$out" | sed -n 's/.*POOL_MODEL=\([^ ]*\).*/\1/p')"
[ -n "$POOL_ID" ] && result R-pool PASS "pool $POOL_ID entry $POOL_MODEL with pool_shard_groups/v1 naming $HEAD" || e2e_die "no pool id: $out"

# ---- provider configs, credentials imported the supported way ------------------------
for role in h m; do
  pid=$HEAD; port=18090; [ $role = m ] && { pid=$M1; port=18091; }
  d="$R/$role"; mkdir -p "$d"; chmod 700 "$d"
  tok="$(vm_get /root/e2e/token-$pid)"
  umask 077
  cat >"$d/config.yaml" <<YAML
provider_id: $pid
provider_token: $tok
credential_store: protected_file
enable_receipts: true
coordinator_url: $COORD
model: $MODEL_DIR
model_artifact_path: $MODEL_DIR
model_artifact_sha256: $H_REAL
pool_model_id: $POOL_MODEL
YAML
  umask 022
  if [ ! -d "$d/protected-credentials" ]; then
    "$CLI" credentials import --config "$d/config.yaml" >"$EV/import-$role.log" 2>&1 || e2e_die "credentials import $role: $(tail -3 "$EV/import-$role.log")"
  fi
done
pubkey() { python3 - "$1" "$2" <<'PY'
import hashlib, os, sys, subprocess, base64, tempfile
root, pid = sys.argv[1], sys.argv[2]
p = os.path.join(root, "protected-credentials", "identity-keys", hashlib.sha256(pid.encode()).hexdigest(), hashlib.sha256(b"com.malibu.provider.receipt-key").hexdigest())
raw = open(p, "rb").read()
seed = raw[:32] if len(raw) in (32, 64) else base64.b64decode(raw.strip())[:32]
der = bytes.fromhex("302e020100300506032b657004220420") + seed
with tempfile.NamedTemporaryFile(suffix=".der") as f:
    f.write(der); f.flush()
    pub = subprocess.run(["openssl", "pkey", "-inform", "DER", "-in", f.name, "-pubout", "-outform", "DER"], check=True, capture_output=True).stdout[-32:]
print(base64.b64encode(pub).decode())
PY
}
HPUB="$(pubkey "$R/h" $HEAD)"; MPUB="$(pubkey "$R/m" $M1)"
SUP='{"heartbeat_interval_ms":100,"heartbeat_miss_limit":3,"decode_hop_deadline_ms":500,"prefill_chunk_deadline_ms":3000,"replay_deadline_ms":10000}'
cat >"$R/m/shard.json" <<JSON
{"schema":"macprovider.shard-member-config.v1","group_provider_id":"$HEAD","group_epoch":1,"role":"stage","stage_index":1,"layer_start":14,"layer_end":28,"listen":"127.0.0.1:47101","interconnect_class":"thunderbolt-ip","frame_protection":"crc32c","max_sequences":2,"max_context_tokens":8192,"upstream_public_key":"$HPUB","supervision":$SUP}
JSON
cat >"$R/h/group.json" <<JSON
{"schema":"macprovider.shard-group-config.v1","group_epoch":1,"interconnect_class":"thunderbolt-ip","frame_protection":"crc32c","pool_model_id":"$POOL_MODEL","head_layer_end":14,"stages":[{"member_device_id":"$M1","endpoint":"127.0.0.1:47101","layer_start":14,"layer_end":28,"member_public_key":"$MPUB"}],"max_concurrency":2,"supervision":$SUP}
JSON

# ---- pause the live provider, with an EXIT trap and an independent watchdog ----------
live_inflight() { curl -fsS --max-time 5 "$LIVE_STATUS" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("requests_in_flight",0))' 2>/dev/null || echo "?"; }
live_state() { curl -fsS --max-time 5 "$LIVE_STATUS" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("network_state",""))' 2>/dev/null; }
PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  sleep 2; for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done
  python3 "$LIVE_CTL" resume >"$EV/live-resume.txt" 2>&1 || true
  [ -n "${WATCHDOG:-}" ] && kill "$WATCHDOG" 2>/dev/null
  local t=0; while [ $t -lt 300 ] && [ "$(live_state)" != buyer_serving ]; do sleep 10; t=$((t + 10)); done
  e2e_log "live provider after resume: $(live_state) (waited ${t}s)"
  echo "$(live_state)" >"$EV/live-final-state.txt"
}
trap cleanup EXIT
( sleep 900; python3 "$LIVE_CTL" resume >/dev/null 2>&1 ) & WATCHDOG=$!
python3 "$LIVE_CTL" pause >"$EV/live-pause.txt" 2>&1 || e2e_die "live pause refused: $(cat "$EV/live-pause.txt")"
t=0; while [ "$(live_inflight)" != 0 ] && [ $t -lt 300 ]; do sleep 5; t=$((t + 5)); done
[ "$(live_inflight)" = 0 ] || e2e_die "live provider still has requests in flight after 300 s"
e2e_log "live provider paused, 0 in flight"

# ---- start the member, then the head ----------------------------------------------------
common=(--isolate-lifecycle --credential-store protected_file --enable-receipts --lab-loopback-interconnect)
"$CLI" serve --config "$R/m/config.yaml" --port 18091 "${common[@]}" --shard-member "$R/m/shard.json" >"$EV/member.log" 2>&1 & PIDS+=($!)
sleep 20
"$CLI" serve --config "$R/h/config.yaml" --port 18090 --max-context 8192 "${common[@]}" --shard-group "$R/h/group.json" >"$EV/head.log" 2>&1 & PIDS+=($!)

# head pool binding: the signed model-admission offer with the head's enrolled
# admission identity (the harness offer tool of the #1690/#1816 VM runs; the
# CLI's own `models offer` accepts only a wss/https coordinator, deviation D7).
seed_file() { python3 - "$1" "$2" "$3" <<'PY'
import base64, hashlib, os, sys
root, pid, out = sys.argv[1], sys.argv[2], sys.argv[3]
p = os.path.join(root, "protected-credentials", "identity-keys", hashlib.sha256(pid.encode()).hexdigest(), hashlib.sha256(b"com.malibu.provider.bootstrap-identity-key").hexdigest())
raw = open(p, "rb").read()
seed = raw[:32] if len(raw) in (32, 64) else base64.b64decode(raw.strip())[:32]
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, (base64.b64encode(seed).decode() + "\n").encode())
os.close(fd)
PY
}
FAKEPROV="$R/fakeprov"
[ -x "$FAKEPROV" ] || (cd "$E2E_HARNESS/../e2e-1690/fakeprov" && go build -trimpath -o "$FAKEPROV" .) || e2e_die "fakeprov build"
sleep 30
# Every member offers too: a single provider serving this pool entry needs the
# binding (SPEC-051-R003), and without it the member's catalog model id with a
# non-catalog hash is excluded by the Tier-2 hash requirement.
# A pool entry is admitted only for a model id that is not a catalog id
# (SPEC-032-R004 pool_entry mode), so the lab copy is served by its path; the
# offer binds the artifact pair (its served_model_ref is the upstream repo).
SERVED_ID="$(vm ". /root/e2e/h/vm/lib.sh; curl_bearer \"\$(opkey)\" -s http://127.0.0.1:8444/admin/providers/$HEAD" | python3 -c 'import json,sys;d=json.load(sys.stdin);print((d.get("provider") or d).get("model_id",""))')"
e2e_log "served model id: $SERVED_ID"
for role in h m; do
  pid=$HEAD; [ $role = m ] && pid=$M1
  seed_file "$R/$role" $pid "$R/$role/admission-seed"
  vm_get /root/e2e/token-$pid >"$R/$role/token"; chmod 600 "$R/$role/token"
  "$FAKEPROV" offer -coord-http http://127.0.0.1:28444 -provider-id $pid -token-file "$R/$role/token" -admission-key-file "$R/$role/admission-seed" \
    -runtime-source mlx_cache -served-model-ref "$MODEL_REF" -catalog-key "" -artifact-hash-algorithm macprovider.snapshot-manifest.v1 -artifact-hash "$H_REAL" \
    -out "$EV/offer-$role.json" >"$EV/offer-$role.txt" 2>&1 \
    && result R-offer-$role PASS "$pid: $(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));b=d.get("pool_binding") or {};print(d.get("admission_state"), b.get("binding_scope"), b.get("pool_model_id"))' "$EV/offer-$role.json" 2>&1)" \
    || result R-offer-$role FAIL "$pid: $(tail -3 "$EV/offer-$role.txt" | tr '\n' ' ' | head -c 500)"
  rm -f "$R/$role/admission-seed" "$R/$role/token"
done

avail() { vm "journalctl -u macprovider-coordinator --since '10 min ago' -o cat | grep '\"event\":\"shard_group_status\"' | grep '\"provider_id\":\"$HEAD\"' | tail -1"; }
t=0; st=""
while [ $t -lt 240 ]; do st="$(avail)"; echo "$st" | grep -q '"available":true' && break; sleep 5; t=$((t + 5)); done
echo "$st" | grep -q '"available":true' && result R-group-available PASS "real head + member registered and available after ${t}s: $(echo "$st" | head -c 300)" \
  || result R-group-available FAIL "not available after ${t}s: last status $(echo "$st" | head -c 300); head log: $(grep -i 'shard' "$EV/head.log" | tail -4 | tr '\n' ' ' | head -c 600)"

# Both sessions as the coordinator's operator surface shows them (state,
# admission and Tier-2 flags), for the record and for any refusal above.
for pid in $HEAD $M1; do
  vm ". /root/e2e/h/vm/lib.sh; curl_bearer \"\$(opkey)\" -s http://127.0.0.1:8444/admin/providers/$pid" >"$EV/admin-$pid.json" 2>&1 || true
done
BK="$(vm_get /root/e2e/buyer-api-key)"
buy() {  # buy <label> <stream> [max-time] [max-tokens] [prompt]
  local rid; rid="$(uuidgen | tr 'A-Z' 'a-z')"
  curl -s -o "$EV/$1.body" -D "$EV/$1.headers" -w '%{http_code}' --max-time "${3:-120}" "$GW/v1/chat/completions" \
    -H @<(printf 'Authorization: Bearer %s\n' "$BK") -H 'Content-Type: application/json' -H "X-Request-ID: $rid" -H "X-MacProvider-Pool-Select: $POOL_ID" \
    -d "{\"model\":\"$POOL_MODEL\",\"stream\":$2,\"max_tokens\":${4:-48},\"temperature\":0,\"messages\":[{\"role\":\"user\",\"content\":\"${5:-Name three colours.} ($rid)\"}]}"
  echo " $rid" >"$EV/$1.rid"
}
c="$(buy paid-ns false)"; rid_ns="$(awk '{print $1}' "$EV/paid-ns.rid")"
c2="$(buy paid-st true)"; rid_st="$(awk '{print $1}' "$EV/paid-st.rid")"
sleep 5
check="$(vm_script "$rid_ns" "$rid_st" "$POOL_MODEL" < <(cat <<'SH'
. /root/e2e/h/vm/lib.sh
for rid in "$1" "$2"; do
  cid="$(csql "SELECT request_id FROM request_log WHERE external_request_id='$rid' ORDER BY rowid DESC LIMIT 1")"
  echo "rid=$rid cid=$cid log=$(csql "SELECT status FROM request_log WHERE request_id='$cid' ORDER BY rowid DESC LIMIT 1") att=$(csql "SELECT verdict||'/'||fault_kind||'/'||fault_member_device_id FROM shard_group_attestations WHERE request_id='$cid'") verdict=$(csql "SELECT receipt_result||'/'||settlement_outcome FROM settlement_receipt_verdicts WHERE request_id='$cid'") credit=$(csql "SELECT provider_id||'/'||gross_credits||'/'||provider_credits FROM ledger_request_credits WHERE request_id='$cid'") snap=$(csql "SELECT json_extract(route_snapshot_json,'\$.pool_model_id') FROM settlement_route_snapshots WHERE request_id='$cid'") gw=$(gwsql "SELECT status||'/'||coalesce(settled_tokens,0) FROM quota_reservations WHERE request_id='$rid'")"
done
SH
))"
echo "$check" >"$EV/paid-check.txt"
if [ "$c" = 200 ] && [ "$c2" = 200 ] && [ "$(grep -c 'att=verified//' "$EV/paid-check.txt")" = 2 ] && grep -q "snap=$POOL_MODEL" "$EV/paid-check.txt"; then
  result R-paid-request PASS "non-stream $c, stream $c2 through the VM gateway; $(tr '\n' ' ' <"$EV/paid-check.txt" | head -c 900)"
else result R-paid-request FAIL "non-stream $c, stream $c2; $(tr '\n' ' ' <"$EV/paid-check.txt" | head -c 900); body $(head -c 300 "$EV/paid-ns.body")"; fi

# ---- kill the member mid-stream, then before the first token -----------------------------
(buy kill-mid true 120 400 "Count from 1 to 400, one number per line." >"$EV/kill-mid.code") & BUY=$!
# kill the member once the stream is under way (first bytes at the buyer)
for i in $(seq 1 100); do [ "$(grep -c '^data:' "$EV/kill-mid.body" 2>/dev/null || echo 0)" -ge 5 ] && break; sleep 0.1; done
kill -9 "${PIDS[0]}" 2>/dev/null; wait $BUY
c="$(cat "$EV/kill-mid.code" | awk '{print $1}')"
result R-member-killed-mid-stream INFO "buyer $c; tail: $(tail -c 400 "$EV/kill-mid.body" | tr '\n' ' ')"
c="$(buy kill-before false 60)"
result R-member-down-before-first-token INFO "buyer $c $(head -c 300 "$EV/kill-before.body")"
rid_mid="$(awk '{print $1}' "$EV/kill-mid.rid")"; rid_bef="$(awk '{print $1}' "$EV/kill-before.rid")"
sleep 5
vm_script "$rid_mid" "$rid_bef" < <(cat <<'SH'
. /root/e2e/h/vm/lib.sh
for rid in "$1" "$2"; do
  echo "rid=$rid attempts=[$(csql "SELECT group_concat(attempt_n||':'||status||'/'||coalesce(fault_flag,'')||'/'||gross_credits||'/'||provider_credits, ' ') FROM ledger_request_credits WHERE request_id IN (SELECT request_id FROM request_log WHERE external_request_id='$rid')")] gw=$(gwsql "SELECT status||'/'||coalesce(settled_tokens,0) FROM quota_reservations WHERE request_id='$rid'")"
done
SH
) >"$EV/kill-check.txt"
result R-failure-accounting INFO "$(tr '\n' ' ' <"$EV/kill-check.txt" | head -c 800)"
e2e_log "scenario R done; evidence $EV"
