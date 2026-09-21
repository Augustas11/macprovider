#!/usr/bin/env bash
# SPEC-037 KVS-02 — warm-swap same-family invalidation gate (FR-KVP13 / §6).
#
# Scenario: persist a conversation under model A, switch to a SAME-FAMILY model B
# (different model ID and model_sha256 — e.g., another Qwen3 4-bit variant),
# send a matching second-turn request → expect deterministic disk_miss_envelope,
# cached_prompt_tokens=0, fresh correct output. No old payload promoted into model
# memory. Control arm: same-model relaunch (model A) → disk_hit (KVS-01 sanity).
#
# This validates FR-KVP4 "model family / alias similarity is never sufficient"
# and FR-KVP4(a)4 (served model ID + exact model_sha256 must both match byte-for-byte).
#
# Pass contract (correctness — these always fail the run):
#   miss_envelope arm: code=disk_miss_envelope, cached_prompt_tokens=0, correctness=ok
#   control arm:       code=disk_hit,           cached_prompt_tokens>0,  correctness=ok
#
# This is harness CAPABILITY — it launches real models and MUST NOT run in CI.
# It refuses a production coordinator (§6 production fence).
#
# Required env:
#   KVS02_PROVIDER_CMD_A  foreground provider launch for model A (the persist model),
#                         kv_disk_cache.enabled=true, logging events to stderr.
#   KVS02_PROVIDER_CMD_B  foreground provider launch for model B (same family,
#                         different model ID and model_sha256), kv_disk_cache.enabled=true.
#
# Optional env:
#   KVS02_BASE            provider HTTP base (default http://127.0.0.1:18080)
#   KVS02_STORE           NDJSON output (default ~/.local/state/kvs-02/samples.ndjson)
#   KVS02_TOKEN_FILE      buyer token (default ~/.config/macprovider/buyer-api-key)
#   KVS02_PROMPT_TOKENS   synthetic prefix size (default 512; KVS-02 is a correctness
#                         gate, not a performance gate — short prefix suffices)
#   KVS02_READY_TIMEOUT   seconds to await provider readiness (default 300)
#   KVS02_WRITE_TIMEOUT   seconds to await disk_write_committed (default 60)
#   KVS02_CYCLES          cycles to run (default 1 smoke / 3 gate); --cycles N
#   KVS02_SMOKE           1 => smoke mode (1 cycle); --smoke flag
#   KVS02_KEEP_LOGS       path to copy provider logs after the run
#   KVS02_NODE_BIN        node binary path (default: node on PATH)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${KVS02_BASE:=http://127.0.0.1:18080}"
: "${KVS02_STORE:=$HOME/.local/state/kvs-02/samples.ndjson}"
: "${KVS02_TOKEN_FILE:=$HOME/.config/macprovider/buyer-api-key}"
: "${KVS02_PROMPT_TOKENS:=512}"
: "${KVS02_READY_TIMEOUT:=300}"
: "${KVS02_WRITE_TIMEOUT:=60}"
: "${KVS02_SMOKE:=0}"
: "${KVS02_CYCLES:=}"
GATE_MIN_SAMPLES=3

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cycles) KVS02_CYCLES="${2:?--cycles needs a number}"; shift 2 ;;
    --cycles=*) KVS02_CYCLES="${1#*=}"; shift ;;
    --smoke) KVS02_SMOKE=1; shift ;;
    *) echo "kvs-02: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [[ -z "$KVS02_CYCLES" ]]; then
  if [[ "$KVS02_SMOKE" == "1" ]]; then KVS02_CYCLES=1; else KVS02_CYCLES="$GATE_MIN_SAMPLES"; fi
fi
if ! [[ "$KVS02_CYCLES" =~ ^[0-9]+$ ]] || (( KVS02_CYCLES < 1 )); then
  echo "kvs-02: cycles must be a positive integer, got '$KVS02_CYCLES'" >&2; exit 2
fi
if [[ "$KVS02_SMOKE" == "1" ]] && (( KVS02_CYCLES > 2 )); then
  echo "kvs-02: --smoke allows at most 2 cycles (got $KVS02_CYCLES)" >&2; exit 2
fi

# §6 production fence — never kill-cycle a production provider.
case "$KVS02_BASE" in
  *malibu.tech*|*coordinator.*|*api.*)
    if [[ "${KVS02_ALLOW_REMOTE:-0}" != "1" ]]; then
      echo "kvs-02: refusing non-local base '$KVS02_BASE' (§6 production fence)" >&2; exit 3
    fi ;;
esac

if [[ -z "${KVS02_PROVIDER_CMD_A:-}" ]]; then
  echo "kvs-02: set \$KVS02_PROVIDER_CMD_A (model A / persist model, tier enabled)" >&2; exit 2
fi
if [[ -z "${KVS02_PROVIDER_CMD_B:-}" ]]; then
  echo "kvs-02: set \$KVS02_PROVIDER_CMD_B (model B / same-family switch, tier enabled)" >&2; exit 2
fi

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
NODE_BIN="${KVS02_NODE_BIN:-$(command -v node || true)}"
if [[ -z "$NODE_BIN" ]]; then
  echo "kvs-02: node not found on PATH; set \$KVS02_NODE_BIN" >&2; exit 2
fi

if [[ -z "${MACPROVIDER_BUYER_TOKEN:-}" ]]; then
  if [[ -r "$KVS02_TOKEN_FILE" ]]; then
    MACPROVIDER_BUYER_TOKEN="$(tr -d '[:space:]' < "$KVS02_TOKEN_FILE")"
    export MACPROVIDER_BUYER_TOKEN
  else
    echo "kvs-02: no token in \$MACPROVIDER_BUYER_TOKEN and $KVS02_TOKEN_FILE not readable" >&2; exit 2
  fi
fi

mkdir -p "$(dirname "$KVS02_STORE")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kvs-02.XXXXXX")"
KEEP_LOGS="${KVS02_KEEP_LOGS:-}"
trap 'if [[ -n "$KEEP_LOGS" ]]; then mkdir -p "$KEEP_LOGS"; cp -f "$WORK"/provider-*.log "$KEEP_LOGS"/ 2>/dev/null || true; fi; rm -rf "$WORK"; [[ -n "${PROVIDER_PID:-}" ]] && kill -9 "$PROVIDER_PID" 2>/dev/null || true' EXIT

start_provider() { # $1=cmd $2=log
  bash -c "$1" >"$2" 2>&1 &
  PROVIDER_PID=$!
}

stop_provider() {
  # bash 3.2 + set -e: wait after SIGKILL returns 137 — disable -e for the reap.
  set +e
  if [[ -n "${PROVIDER_PID:-}" ]]; then
    pkill -9 -P "$PROVIDER_PID" 2>/dev/null
    kill -9 "$PROVIDER_PID" 2>/dev/null
    wait "$PROVIDER_PID" 2>/dev/null
    PROVIDER_PID=""
  fi
  set -e
  return 0
}

await_ready() {
  local deadline=$(( $(date +%s) + KVS02_READY_TIMEOUT ))
  while (( $(date +%s) < deadline )); do
    local body
    body="$(curl -fsS -m 5 "$KVS02_BASE/v1/status" 2>/dev/null || true)"
    if [[ -n "$body" ]] && "$NODE_BIN" -e '
      let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
        try {
          const d=JSON.parse(s);
          const loaded = d.model_loaded === true || d.model_loaded === "true";
          const ready = String(d.status||"").toLowerCase()==="ready";
          const model = d.model || d.model_id || d.currentModelID || (d.lifecycle&&d.lifecycle.model_id) || "";
          process.exit(loaded && ready && String(model).length ? 0 : 1);
        } catch { process.exit(1); }
      })
    ' <<<"$body"; then
      return 0
    fi
    if ! kill -0 "$PROVIDER_PID" 2>/dev/null; then echo "kvs-02: provider exited during startup" >&2; return 1; fi
    sleep 1
  done
  echo "kvs-02: provider not ready within ${KVS02_READY_TIMEOUT}s" >&2; return 1
}

resolve_model() {
  curl -fsS -m 5 "$KVS02_BASE/v1/status" 2>/dev/null \
    | "$NODE_BIN" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const d=JSON.parse(s);console.log(d.model||d.model_id||d.currentModelID||(d.lifecycle&&d.lifecycle.model_id)||"")}catch{console.log("")}})' || echo ""
}

# Await a kv_disk_cache reason code in the provider stderr log; echoes the last match.
await_log() { # $1=log $2=pattern $3=timeout
  local deadline=$(( $(date +%s) + $3 ))
  while (( $(date +%s) < deadline )); do
    local hit; hit="$(grep -aE "$2" "$1" | tail -1 || true)"
    if [[ -n "$hit" ]]; then echo "$hit"; return 0; fi
    sleep 1
  done
  return 1
}

json_get() { "$NODE_BIN" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const v=JSON.parse(s)[process.argv[1]];process.stdout.write(v==null?"":String(v))}catch{process.stdout.write("")}})' "$1"; }

# Append one §6 record to the store, augmented with KVS-02-specific fields.
record_sample() { # $1=probe-json $2=log-line $3=write-line $4=cycle $5=model-a $6=model-b $7=arm
  "$NODE_BIN" -e '
    const [probe, hitLine, writeLine, cyc, modelA, modelB, armLabel] = process.argv.slice(1);
    let rec = {}; try { rec = JSON.parse(probe); } catch {}
    const scan = (line, k) => { if (!line) return null; const m = line.match(new RegExp("(?:^|\\s)" + k + "=([^\\s]+)")); return m ? m[1] : null; };
    rec.cycle = Number(cyc);
    rec.disk_reason = (hitLine.match(/code=([a-z_]+)/) || [])[1] || null;
    rec.model_a = modelA;
    rec.model_b = modelB;
    rec.arm = armLabel;
    rec.model_sha256_persist = scan(writeLine, "model_sha256");
    rec.model_sha256_read = scan(hitLine, "model_sha256");
    rec.catalog_revision_persist = scan(writeLine, "catalog_revision");
    rec.catalog_revision_read = scan(hitLine, "catalog_revision");
    rec.kvs_gate = "KVS-02";
    process.stdout.write(JSON.stringify(rec) + "\n");
  ' "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

# ---------------------------------------------------------------- one cycle ---------
run_one_cycle() { # $1=cycle
  local cycle="$1"
  local CONVERSATION="conv:kvs-synth:kvs02-$(uuidgen | tr 'A-Z' 'a-z')"
  local SEED_CONV="conv:kvs-synth:kvs02-seed-$(uuidgen | tr 'A-Z' 'a-z')"
  local RESP="$WORK/response-$cycle.txt"
  local SUFFIX="kvs02-switch-$RANDOM"
  local ok=0

  echo "kvs-02[c$cycle]: ── (1) persist under model A ──" >&2

  # (1) Start model A (tier enabled), persist a synthetic conversation, await
  #     disk_write_committed, then kill.
  local LOG_A1="$WORK/provider-a1-$cycle.log"
  start_provider "$KVS02_PROVIDER_CMD_A" "$LOG_A1"
  await_ready
  local MODEL_A; MODEL_A="$(resolve_model)"

  local PERSIST_JSON
  PERSIST_JSON="$("$NODE_BIN" "$HERE/kvs-01a-probe.mjs" \
    --base "$KVS02_BASE" --conversation "$CONVERSATION" --model "$MODEL_A" \
    --regime kvs02_persist --arm persist --prompt-tokens "$KVS02_PROMPT_TOKENS" \
    --response-out "$RESP" || true)"

  local P_PROMPT P_COMPLETION
  P_PROMPT="$(json_get prompt_tokens <<<"$PERSIST_JSON")"
  P_COMPLETION="$(json_get completion_tokens <<<"$PERSIST_JSON")"
  if [[ -z "$P_PROMPT" || -z "$P_COMPLETION" ]]; then
    echo "kvs-02[c$cycle]: persist turn returned no usage; aborting cycle" >&2; return 4
  fi
  local EXPECTED_CACHED=$(( P_PROMPT + P_COMPLETION ))

  local WRITE_LINE
  WRITE_LINE="$(await_log "$LOG_A1" 'code=disk_write_committed' "$KVS02_WRITE_TIMEOUT" || true)"
  if [[ -z "$WRITE_LINE" ]]; then
    echo "kvs-02[c$cycle]: no disk_write_committed within ${KVS02_WRITE_TIMEOUT}s — nothing persisted" >&2; return 4
  fi

  record_sample "$PERSIST_JSON" "" "$WRITE_LINE" "$cycle" "$MODEL_A" "" "persist" \
    | tee -a "$KVS02_STORE" >/dev/null || true

  echo "kvs-02[c$cycle]: disk_write_committed. kill model A → launch model B (same-family switch)" >&2
  stop_provider

  # (2) Start model B (same family, different model ID + sha256).
  #     Send the same-conversation second turn → expect disk_miss_envelope.
  local LOG_B="$WORK/provider-b-$cycle.log"
  start_provider "$KVS02_PROVIDER_CMD_B" "$LOG_B"
  await_ready
  local MODEL_B; MODEL_B="$(resolve_model)"

  # SIGKILL model B as soon as the miss reason is logged, BEFORE its post-turn
  # disk_write_committed. Index is HMAC(conversation key) only — B would otherwise
  # last-writer-wins overwrite A's blob, and the control arm would false-FAIL.
  local MISS_JSON MISS_LINE MISS_JSON_FILE="$WORK/miss-$cycle.json"
  "$NODE_BIN" "$HERE/kvs-01a-probe.mjs" \
    --base "$KVS02_BASE" --conversation "$CONVERSATION" --model "$MODEL_B" \
    --regime kvs02_miss_envelope --arm miss_envelope \
    --prompt-tokens "$KVS02_PROMPT_TOKENS" \
    --assistant-file "$RESP" --suffix "$SUFFIX" \
    >"$MISS_JSON_FILE" 2>/dev/null &
  local MISS_PROBE_PID=$!
  # Wait for the probe to exit (full streaming response received by the probe,
  # i.e., kv_cache_request_completed has fired on model B's side), then
  # SIGKILL model B before disk_write_committed fires (~62ms async after response).
  # Using probe-exit as the kill signal avoids polling jitter and gives ~62ms margin.
  set +e
  wait "$MISS_PROBE_PID" 2>/dev/null
  set -e
  stop_provider
  MISS_JSON="$(cat "$MISS_JSON_FILE" 2>/dev/null || true)"
  MISS_LINE="$(grep -aE 'code=disk_(hit|promote_rejected|miss_[a-z_]+)' "$LOG_B" 2>/dev/null | tail -1 || true)"

  local MISS_CODE MISS_CACHED MISS_CORRECT
  MISS_CODE="$(sed -nE 's/.*code=([a-z_]+).*/\1/p' <<<"$MISS_LINE" | tail -1)"
  MISS_CACHED="$(json_get cached_prompt_tokens <<<"$MISS_JSON")"
  MISS_CORRECT="$(json_get correctness <<<"$MISS_JSON")"

  record_sample "$MISS_JSON" "$MISS_LINE" "$WRITE_LINE" "$cycle" "$MODEL_A" "$MODEL_B" "miss_envelope" \
    | tee -a "$KVS02_STORE" >/dev/null || true

  # Pass: disk_miss_envelope AND cached=0 AND fresh correct output (not partial reuse).
  if [[ "$MISS_CODE" == "disk_miss_envelope" \
     && ( -z "$MISS_CACHED" || "$MISS_CACHED" == "0" || "$MISS_CACHED" == "null" ) \
     && "$MISS_CORRECT" == "ok" ]]; then
    echo "kvs-02[c$cycle]: PASS miss_envelope: code=$MISS_CODE cached=${MISS_CACHED:-0} correctness=$MISS_CORRECT modelA=$MODEL_A modelB=$MODEL_B" >&2
    ok=1
  else
    echo "kvs-02[c$cycle]: FAIL miss_envelope: code=${MISS_CODE:-none} cached=${MISS_CACHED:-none} correctness=${MISS_CORRECT:-none} (expected disk_miss_envelope cached=0 correctness=ok)" >&2
  fi

  # (3) Control arm: kill model B, relaunch model A with the tier enabled, send the
  #     same-conversation second turn → expect disk_hit (KVS-01 sanity check: we
  #     didn't break the store by running model B against it).
  echo "kvs-02[c$cycle]: kill model B → relaunch model A (control arm — expect disk_hit)" >&2
  stop_provider
  local LOG_A2="$WORK/provider-a2-$cycle.log"
  start_provider "$KVS02_PROVIDER_CMD_A" "$LOG_A2"
  await_ready
  local MODEL_A2; MODEL_A2="$(resolve_model)"

  # Geometry-seed turn on a throwaway key (documented residual — see KVS-01a README).
  "$NODE_BIN" "$HERE/kvs-01a-probe.mjs" \
    --base "$KVS02_BASE" --conversation "$SEED_CONV" --model "$MODEL_A2" \
    --regime kvs02_seed --arm seed --prompt-tokens "$KVS02_PROMPT_TOKENS" >/dev/null || true
  await_log "$LOG_A2" 'code=disk_write_committed' "$KVS02_WRITE_TIMEOUT" >/dev/null || true

  local CTRL_JSON CTRL_LINE
  CTRL_JSON="$("$NODE_BIN" "$HERE/kvs-01a-probe.mjs" \
    --base "$KVS02_BASE" --conversation "$CONVERSATION" --model "$MODEL_A2" \
    --regime kvs02_control --arm control_hit \
    --prompt-tokens "$KVS02_PROMPT_TOKENS" \
    --assistant-file "$RESP" --suffix "$SUFFIX" || true)"
  CTRL_LINE="$(await_log "$LOG_A2" 'code=disk_(hit|promote_rejected|miss_[a-z_]+)' 30 || true)"

  local CTRL_CODE CTRL_CACHED CTRL_CORRECT
  CTRL_CODE="$(sed -nE 's/.*code=([a-z_]+).*/\1/p' <<<"$CTRL_LINE" | tail -1)"
  CTRL_CACHED="$(json_get cached_prompt_tokens <<<"$CTRL_JSON")"
  CTRL_CORRECT="$(json_get correctness <<<"$CTRL_JSON")"

  record_sample "$CTRL_JSON" "$CTRL_LINE" "" "$cycle" "$MODEL_A2" "" "control_hit" \
    | tee -a "$KVS02_STORE" >/dev/null || true

  if [[ "$CTRL_CODE" == "disk_hit" && "$CTRL_CORRECT" == "ok" ]]; then
    echo "kvs-02[c$cycle]: PASS control: code=$CTRL_CODE cached=${CTRL_CACHED:-?} correctness=$CTRL_CORRECT (disk_hit expected=$EXPECTED_CACHED)" >&2
  else
    echo "kvs-02[c$cycle]: FAIL control: code=${CTRL_CODE:-none} cached=${CTRL_CACHED:-none} correctness=${CTRL_CORRECT:-none} (expected disk_hit correctness=ok)" >&2
    ok=0
  fi

  stop_provider
  if (( ok == 1 )); then return 0; fi
  return 5
}

# ------------------------------------------------------------------- driver ---------
FAILS=0
for (( c = 1; c <= KVS02_CYCLES; c++ )); do
  if ! run_one_cycle "$c"; then FAILS=$(( FAILS + 1 )); fi
  stop_provider
done

if (( FAILS > 0 )); then
  echo "kvs-02: $FAILS/$KVS02_CYCLES cycle(s) FAILED the warm-swap invalidation contract" >&2; exit 5
fi
echo "kvs-02: all $KVS02_CYCLES cycle(s) passed → $KVS02_STORE" >&2
