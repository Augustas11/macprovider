# shellcheck shell=bash
# #2084 in-VM helpers (SPEC-051 shard groups). Source after the shared #1690
# lib.sh, lib-deploy.sh, lib-scn.sh and the #1816 lib-1816.sh. Run as root
# inside the fake-Pearl VM.
E2E_H84=/root/e2e/h84
export E2E_POOLS=/root/e2e/pools84
export E2E_CREATOR=acct-e2e-2084-creator
PM="python3 $E2E_H16/tools/pool-models.py"
pool_id() { cat "$E2E_POOLS/$1/pool_id" 2>/dev/null; }
pmid() { echo "pool/$(pool_id "$1")/$2"; }
# pool_traffic from lib-1816 reads /root/e2e/pools16; redefine on pools84.
pool_traffic() {
  local run="$1" pool="$2" model="$3" engine="${4:-}" mix="${5:-ns=3,st=3}" workers="${6:-2}"
  local hdr=(--header "X-MacProvider-Pool-Select:$(pool_id "$pool")")
  [ -n "$engine" ] && hdr+=(--header "X-MacProvider-Engine-Select:$engine")
  MODEL="$model" traffic "$run" "$mix" "${hdr[@]}" --workers "$workers" "${POOL_TRAFFIC_EXTRA[@]}"
}
POOL_TRAFFIC_EXTRA=()

# Fake shard group identities (e2e-prov-1x, so the shared live-config and
# naming stay uniform). 11 = head (group provider identity, stage 0),
# 12 = stage-1 member, 13 = spare for stage 1, 14 = a second owner's Mac.
HEAD=e2e-prov-11; M1=e2e-prov-12; SPARE=e2e-prov-13; OTHER=e2e-prov-14
SHARD_IDS="$HEAD $M1 $SPARE $OTHER"
# Real Swift providers (scenario R, run on the host Mac).
RHEAD=e2e-real-head; RM1=e2e-real-m1
OWNER_GH=208400001; OTHER_GH=208400002
SHARD_MODEL=e2e-shard-model
H_SHARD=$(printf 'e2e-2084 non-catalog mlx snapshot S' | sha256sum | cut -c1-64)
S_RATES="300000,75000,1500000"
SG_DIR=/run/e2e-shard
GROUP_FILE=$SG_DIR/group.json

# coordinator-observed group events (journal)
shard_events() { journalctl -u macprovider-coordinator --since "${1:-10 min ago}" --no-pager -o cat 2>/dev/null | grep -E '"event":"shard_group_(status|register|attestation_failed)"|"event":"shard_member_hello"'; }

# write_group <epoch> [stage1-member] [spares-json]: the shared group file.
write_group() {
  local epoch="$1" s1="${2:-$M1}" spares="${3:-}"
  [ -n "$spares" ] || spares="[{\"member_device_id\":\"$SPARE\",\"stage_index\":1}]"
  install -d -m 0755 $SG_DIR
  python3 - "$epoch" "$s1" "$spares" "$(pmid S shard-s)" "$H_SHARD" "$HEAD" "$SHARD_MODEL" >"$GROUP_FILE.tmp" <<'PY'
import json, sys
epoch, s1, spares, pmid, h, head, model = sys.argv[1:8]
rec = {"schema": "macprovider.shard-group-record.v1", "group_provider_id": head, "group_epoch": int(epoch),
       "parallelism_mode": "pipeline", "interconnect_class": "ethernet", "frame_protection": "hmac-sha256", "transport_version": 1,
       "model": {"model_id": model, "pool_model_id": pmid, "artifact_hash_algorithm": "macprovider.snapshot-manifest.v1", "artifact_hash": h},
       "num_layers": 28, "max_concurrency": 2,
       "stages": [{"stage_index": 0, "member_device_id": head, "layer_start": 0, "layer_end": 14},
                  {"stage_index": 1, "member_device_id": s1, "layer_start": 14, "layer_end": 28}],
       "spares": json.loads(spares),
       "supervision": {"heartbeat_interval_ms": 100, "heartbeat_miss_limit": 3, "decode_hop_deadline_ms": 500,
                       "prefill_chunk_deadline_ms": 3000, "replay_deadline_ms": 10000}}
keys = {m: "/root/e2e/receipt-key-%s" % m for m in ("e2e-prov-12", "e2e-prov-13", "e2e-prov-14")}
print(json.dumps({"record": rec, "member_keys": keys}, indent=1))
PY
  mv "$GROUP_FILE.tmp" "$GROUP_FILE"
}
# knob <id> <json-object>: replace one process's fault knobs; knob_clear [id...]
knob() { install -d -m 0755 $SG_DIR; printf '%s\n' "$2" >"$SG_DIR/knobs-$1.json.tmp" && mv "$SG_DIR/knobs-$1.json.tmp" "$SG_DIR/knobs-$1.json"; }
knob_clear() { local i; for i in "${@:-$SHARD_IDS}"; do rm -f "$SG_DIR/knobs-$i.json"; done; }
sport() { echo $((19200 + ${1#e2e-prov-})); }
shard_status() { curl -fsS --max-time 5 "http://127.0.0.1:$(sport "$1")/v1/status"; }
shard_field() { shard_status "$1" | python3 -c 'import json,sys
d=json.load(sys.stdin)["shard"]
for p in sys.argv[1].split("."):
    d = d.get(p) if isinstance(d, dict) else None
print("" if d is None else (json.dumps(d) if isinstance(d,(dict,list)) else d))' "$2"; }
# head_state: "<available>:<reason>:<epoch>" from the head's last shard_group_status
head_state() { shard_status "$HEAD" | python3 -c 'import json,sys
s=(json.load(sys.stdin)["shard"].get("status") or {})
print("%s:%s:%s" % (str(s.get("available","")).lower(), s.get("reason",""), s.get("group_epoch","")))' 2>/dev/null; }
# wait_head <available true|false> <reason> [max-s] [epoch]: until the head's
# status says so; prints the state.
wait_head() {
  local want="$1:$2" max="${3:-45}" epoch="${4:-}" t=0 st
  while [ "$t" -le "$max" ]; do
    st="$(head_state)"
    if [ "${st%:*}" = "$want" ] && { [ -z "$epoch" ] || [ "${st##*:}" = "$epoch" ]; }; then echo "$st"; return 0; fi
    sleep 1; t=$((t + 1))
  done
  echo "$st"; return 1
}
counter() { shard_field "$1" "$2"; }

shardprov_unit() {
  cat >/etc/systemd/system/e2e-shardprov@.service <<'UNIT'
# #2084 e2e fake SPEC-051 shard provider %i (test scaffolding, never production).
[Unit]
Description=E2E fake shard provider %i
After=network-online.target

[Service]
Type=simple
EnvironmentFile=/root/e2e/shardprov-%i.env
ExecStart=/bin/sh -c 'exec /opt/macprovider/e2e-fakeprov -coord-ws ws://127.0.0.1:8444/ws/provider -provider-id e2e-prov-%i -token-file /root/e2e/token-e2e-prov-%i -status-listen 127.0.0.1:192%i -http-listen 127.0.0.1:193%i -omit-catalog -settlement -receipt-key-file /root/e2e/receipt-key-e2e-prov-%i -admission-key-file /root/e2e/admission-key-e2e-prov-%i -model-id $MODEL_ID -model-hash $MODEL_HASH -model-hash-algorithm macprovider.snapshot-manifest.v1 -trusted-pool -shard-role $ROLE -shard-group /run/e2e-shard/group.json -shard-knobs /run/e2e-shard/knobs-e2e-prov-%i.json -stream-chunks 12 -chunk-delay-ms 100 $EXTRA'
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
}
# shard_env <n> <role> [model-hash] [extra flags]
shard_env() { printf 'ROLE=%s\nMODEL_ID=%s\nMODEL_HASH=%s\nEXTRA=%s\n' "$2" "$SHARD_MODEL" "${3:-$H_SHARD}" "${4:-}" >/root/e2e/shardprov-$1.env; }

# shard_request <label> <pool-name|""> <model> [stream true|false] [extra curl args...]
# One buyer request through nginx; writes <label>.headers/.body under $EV and
# prints the HTTP status.
shard_request() {
  local label="$1" pool="$2" model="$3" stream="${4:-false}"; shift 4 2>/dev/null || shift $#
  local hdr=() bk
  bk="$(cat /root/e2e/buyer-api-key)"
  [ -n "$pool" ] && hdr=(-H "X-MacProvider-Pool-Select: $(pool_id "$pool")")
  curl_bearer "$bk" -s -o "$EV/$label.body" -D "$EV/$label.headers" -w '%{http_code}' --max-time 120 https://api.malibu.tech/v1/chat/completions \
    -H 'Content-Type: application/json' -H "X-Request-ID: $label-$(date +%s%N)" "${hdr[@]}" "$@" \
    -d "{\"model\":\"$model\",\"stream\":$stream,\"max_tokens\":64,\"messages\":[{\"role\":\"user\",\"content\":\"shard e2e $label $(date +%s%N)\"}]}"
}
attestation_row() { csql "SELECT verdict, fault_kind, fault_member_device_id, takeover_from_epoch, takeover_reason FROM shard_group_attestations WHERE request_id='$1'"; }
# keeper_on from lib-1816 runs under systemd-run without this harness's pool
# root; run it on pools84.
keeper_on() {
  systemctl reset-failed e2e-1816-keeper 2>/dev/null || true
  systemd-run --unit=e2e-1816-keeper --collect -E HOME=/root -E E2E_POOLS=$E2E_POOLS -E E2E_CREATOR=$E2E_CREATOR \
    bash -c "exec python3 $E2E_H16/tools/pool-models.py keeper --lead 50 >>/root/e2e/logs/keeper.log 2>&1" >/dev/null
}
