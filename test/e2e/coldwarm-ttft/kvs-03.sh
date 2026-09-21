#!/usr/bin/env bash
# SPEC-037 KVS-03 — model_sha256 change invalidation gate (FR-KVP13 / §6).
#
# Scenario: persist a conversation under model-id X with artifact sha256 Y1 (cmd A),
# then relaunch with the SAME model-id X but a DIFFERENT artifact sha256 Y2 (cmd B —
# a second snapshot or revision of the same HF model ID) → expect zero old-generation
# hits: disk_miss_envelope, cached_prompt_tokens=0, fresh correct output. No stale
# payload is promoted into model memory.
#
# This validates FR-KVP4(a)4 "served canonical identity: served model ID, exact
# model_sha256 (SPEC-010 canonical artifact hash), and catalog revision" — the same
# model ID with a different sha is still an envelope miss.
#
# Pass contract (correctness — these always fail the run):
#   miss_envelope arm: code=disk_miss_envelope, cached_prompt_tokens=0, correctness=ok
#
# NOTE — second snapshot required:
#   KVS03_PROVIDER_CMD_A and KVS03_PROVIDER_CMD_B MUST differ in the underlying
#   model_sha256 served (i.e., they point to different physical artifact directories).
#   They should serve the SAME model-id (e.g., mlx-community/Qwen3-Coder-30B-A3B-
#   Instruct-4bit) at two different HuggingFace revisions.
#   If only one snapshot of the model exists on the host, the harness will refuse to
#   run unless the operator confirms the two commands differ in sha (checked at runtime
#   by comparing /v1/status model_sha256 before the persist step; if they match the
#   run aborts with exit 4 and a clear message).
#
# This is harness CAPABILITY — it launches real models and MUST NOT run in CI.
# It refuses a production coordinator (§6 production fence).
#
# Required env:
#   KVS03_PROVIDER_CMD_A  foreground provider launch: model-id X, sha256 Y1,
#                         kv_disk_cache.enabled=true, events to stderr.
#   KVS03_PROVIDER_CMD_B  foreground provider launch: SAME model-id X, sha256 Y2
#                         (MUST be a different physical artifact, not a symlink or alias
#                         to the same content — confirmed by comparing /v1/status
#                         model_sha256 at runtime).
#
# Optional env:
#   KVS03_BASE            provider HTTP base (default http://127.0.0.1:18080)
#   KVS03_STORE           NDJSON output (default ~/.local/state/kvs-03/samples.ndjson)
#   KVS03_TOKEN_FILE      buyer token (default ~/.config/macprovider/buyer-api-key)
#   KVS03_PROMPT_TOKENS   synthetic prefix size (default 512; correctness gate, not perf)
#   KVS03_READY_TIMEOUT   seconds to await provider readiness (default 300)
#   KVS03_WRITE_TIMEOUT   seconds to await disk_write_committed (default 60)
#   KVS03_CYCLES          cycles to run (default 1 smoke / 3 gate); --cycles N
#   KVS03_SMOKE           1 => smoke mode (1 cycle); --smoke flag
#   KVS03_KEEP_LOGS       path to copy provider logs after the run
#   KVS03_NODE_BIN        node binary path (default: node on PATH)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${KVS03_BASE:=http://127.0.0.1:18080}"
: "${KVS03_STORE:=$HOME/.local/state/kvs-03/samples.ndjson}"
: "${KVS03_TOKEN_FILE:=$HOME/.config/macprovider/buyer-api-key}"
: "${KVS03_PROMPT_TOKENS:=512}"
: "${KVS03_READY_TIMEOUT:=300}"
: "${KVS03_WRITE_TIMEOUT:=60}"
: "${KVS03_SMOKE:=0}"
: "${KVS03_CYCLES:=}"
GATE_MIN_SAMPLES=3

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cycles) KVS03_CYCLES="${2:?--cycles needs a number}"; shift 2 ;;
    --cycles=*) KVS03_CYCLES="${1#*=}"; shift ;;
    --smoke) KVS03_SMOKE=1; shift ;;
    *) echo "kvs-03: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [[ -z "$KVS03_CYCLES" ]]; then
  if [[ "$KVS03_SMOKE" == "1" ]]; then KVS03_CYCLES=1; else KVS03_CYCLES="$GATE_MIN_SAMPLES"; fi
fi
if ! [[ "$KVS03_CYCLES" =~ ^[0-9]+$ ]] || (( KVS03_CYCLES < 1 )); then
  echo "kvs-03: cycles must be a positive integer, got '$KVS03_CYCLES'" >&2; exit 2
fi
if [[ "$KVS03_SMOKE" == "1" ]] && (( KVS03_CYCLES > 2 )); then
  echo "kvs-03: --smoke allows at most 2 cycles (got $KVS03_CYCLES)" >&2; exit 2
fi

# §6 production fence — never kill-cycle a production provider.
case "$KVS03_BASE" in
  *malibu.tech*|*coordinator.*|*api.*)
    if [[ "${KVS03_ALLOW_REMOTE:-0}" != "1" ]]; then
      echo "kvs-03: refusing non-local base '$KVS03_BASE' (§6 production fence)" >&2; exit 3
    fi ;;
esac

if [[ -z "${KVS03_PROVIDER_CMD_A:-}" ]]; then
  echo "kvs-03: set \$KVS03_PROVIDER_CMD_A (model-id X, sha Y1, tier enabled)" >&2; exit 2
fi
if [[ -z "${KVS03_PROVIDER_CMD_B:-}" ]]; then
  echo "kvs-03: set \$KVS03_PROVIDER_CMD_B (same model-id X, sha Y2 — different artifact)" >&2; exit 2
fi

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
NODE_BIN="${KVS03_NODE_BIN:-$(command -v node || true)}"
if [[ -z "$NODE_BIN" ]]; then
  echo "kvs-03: node not found on PATH; set \$KVS03_NODE_BIN" >&2; exit 2
fi

if [[ -z "${MACPROVIDER_BUYER_TOKEN:-}" ]]; then
  if [[ -r "$KVS03_TOKEN_FILE" ]]; then
    MACPROVIDER_BUYER_TOKEN="$(tr -d '[:space:]' < "$KVS03_TOKEN_FILE")"
    export MACPROVIDER_BUYER_TOKEN
  else
    echo "kvs-03: no token in \$MACPROVIDER_BUYER_TOKEN and $KVS03_TOKEN_FILE not readable" >&2; exit 2
  fi
fi

mkdir -p "$(dirname "$KVS03_STORE")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kvs-03.XXXXXX")"
KEEP_LOGS="${KVS03_KEEP_LOGS:-}"
trap 'if [[ -n "$KEEP_LOGS" ]]; then mkdir -p "$KEEP_LOGS"; cp -f "$WORK"/provider-*.log "$KEEP_LOGS"/ 2>/dev/null || true; fi; rm -rf "$WORK"; [[ -n "${PROVIDER_PID:-}" ]] && kill -9 "$PROVIDER_PID" 2>/dev/null || true' EXIT

start_provider() { # $1=cmd $2=log
  bash -c "$1" >"$2" 2>&1 &
  PROVIDER_PID=$!
}

stop_provider() {
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
  local deadline=$(( $(date +%s) + KVS03_READY_TIMEOUT ))
  while (( $(date +%s) < deadline )); do
    local body
    body="$(curl -fsS -m 5 "$KVS03_BASE/v1/status" 2>/dev/null || true)"
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
    if ! kill -0 "$PROVIDER_PID" 2>/dev/null; then echo "kvs-03: provider exited during startup" >&2; return 1; fi
    sleep 1
  done
  echo "kvs-03: provider not ready within ${KVS03_READY_TIMEOUT}s" >&2; return 1
}

resolve_model() {
  curl -fsS -m 5 "$KVS03_BASE/v1/status" 2>/dev/null \
    | "$NODE_BIN" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const d=JSON.parse(s);console.log(d.model||d.model_id||d.currentModelID||(d.lifecycle&&d.lifecycle.model_id)||"")}catch{console.log("")}})' || echo ""
}

resolve_sha256() {
  # Extract model_sha256 from /v1/status (provider may expose it in the status body).
  # Fall back to model_artifact_sha256 or model_catalog_sha256 if the field name differs.
  curl -fsS -m 5 "$KVS03_BASE/v1/status" 2>/dev/null \
    | "$NODE_BIN" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const d=JSON.parse(s);const v=d.model_sha256||d.model_artifact_sha256||d.model_catalog_sha256||(d.lifecycle&&(d.lifecycle.model_sha256||d.lifecycle.model_artifact_sha256))||"";process.stdout.write(v)}catch{process.stdout.write("")}})' || echo ""
}

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

record_sample() { # $1=probe-json $2=log-line $3=write-line $4=cycle $5=model-a $6=sha-a $7=sha-b $8=arm
  "$NODE_BIN" -e '
    const [probe, hitLine, writeLine, cyc, modelA, shaA, shaB, armLabel] = process.argv.slice(1);
    let rec = {}; try { rec = JSON.parse(probe); } catch {}
    const scan = (line, k) => { if (!line) return null; const m = line.match(new RegExp("(?:^|\\s)" + k + "=([^\\s]+)")); return m ? m[1] : null; };
    rec.cycle = Number(cyc);
    rec.disk_reason = (hitLine.match(/code=([a-z_]+)/) || [])[1] || null;
    rec.model_id = modelA;
    rec.model_sha256_cmd_a = shaA;
    rec.model_sha256_cmd_b = shaB;
    rec.arm = armLabel;
    rec.model_sha256_persist = scan(writeLine, "model_sha256");
    rec.model_sha256_read = scan(hitLine, "model_sha256");
    rec.catalog_revision_persist = scan(writeLine, "catalog_revision");
    rec.kvs_gate = "KVS-03";
    process.stdout.write(JSON.stringify(rec) + "\n");
  ' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
}

# ---------------------------------------------------------------- one cycle ---------
run_one_cycle() { # $1=cycle
  local cycle="$1"
  local CONVERSATION="conv:kvs-synth:kvs03-$(uuidgen | tr 'A-Z' 'a-z')"
  local SEED_CONV="conv:kvs-synth:kvs03-seed-$(uuidgen | tr 'A-Z' 'a-z')"
  local RESP="$WORK/response-$cycle.txt"
  local SUFFIX="kvs03-sha-$RANDOM"
  local ok=0

  echo "kvs-03[c$cycle]: ── (1) verify sha256 differs between cmd A and cmd B ──" >&2

  # Pre-flight: start cmd A, resolve its sha256, start cmd B, resolve its sha256,
  # abort if they are the same (KVS-03 is meaningless without a real sha change).
  local LOG_PRE_A="$WORK/provider-pre-a-$cycle.log"
  start_provider "$KVS03_PROVIDER_CMD_A" "$LOG_PRE_A"
  await_ready
  local MODEL_A; MODEL_A="$(resolve_model)"
  local SHA_A; SHA_A="$(resolve_sha256)"
  stop_provider

  local LOG_PRE_B="$WORK/provider-pre-b-$cycle.log"
  start_provider "$KVS03_PROVIDER_CMD_B" "$LOG_PRE_B"
  await_ready
  local MODEL_B; MODEL_B="$(resolve_model)"
  local SHA_B; SHA_B="$(resolve_sha256)"
  stop_provider

  if [[ -z "$SHA_A" || -z "$SHA_B" ]]; then
    echo "kvs-03[c$cycle]: SKIP — could not resolve model_sha256 from /v1/status for cmd A ('${SHA_A:-empty}') or cmd B ('${SHA_B:-empty}'). Ensure the provider exposes model_sha256 in /v1/status." >&2
    return 4
  fi
  if [[ "$SHA_A" == "$SHA_B" ]]; then
    echo "kvs-03[c$cycle]: ABORT — cmd A and cmd B report the same model_sha256 ($SHA_A). KVS-03 requires two different artifact sha256 values. Download a second snapshot/revision and point KVS03_PROVIDER_CMD_B at it." >&2
    return 4
  fi
  echo "kvs-03[c$cycle]: sha256 confirmed distinct: A=$SHA_A B=$SHA_B model=$MODEL_A" >&2

  # (2) Persist under cmd A.
  echo "kvs-03[c$cycle]: ── (2) persist under cmd A (sha Y1=$SHA_A) ──" >&2
  local LOG_A="$WORK/provider-a-$cycle.log"
  start_provider "$KVS03_PROVIDER_CMD_A" "$LOG_A"
  await_ready

  local PERSIST_JSON
  PERSIST_JSON="$("$NODE_BIN" "$HERE/kvs-01a-probe.mjs" \
    --base "$KVS03_BASE" --conversation "$CONVERSATION" --model "$MODEL_A" \
    --regime kvs03_persist --arm persist --prompt-tokens "$KVS03_PROMPT_TOKENS" \
    --response-out "$RESP" || true)"

  local P_PROMPT P_COMPLETION
  P_PROMPT="$(json_get prompt_tokens <<<"$PERSIST_JSON")"
  P_COMPLETION="$(json_get completion_tokens <<<"$PERSIST_JSON")"
  if [[ -z "$P_PROMPT" || -z "$P_COMPLETION" ]]; then
    echo "kvs-03[c$cycle]: persist turn returned no usage; aborting cycle" >&2; return 4
  fi

  local WRITE_LINE
  WRITE_LINE="$(await_log "$LOG_A" 'code=disk_write_committed' "$KVS03_WRITE_TIMEOUT" || true)"
  if [[ -z "$WRITE_LINE" ]]; then
    echo "kvs-03[c$cycle]: no disk_write_committed within ${KVS03_WRITE_TIMEOUT}s" >&2; return 4
  fi

  record_sample "$PERSIST_JSON" "" "$WRITE_LINE" "$cycle" "$MODEL_A" "$SHA_A" "$SHA_B" "persist" \
    | tee -a "$KVS03_STORE" >/dev/null || true

  echo "kvs-03[c$cycle]: disk_write_committed (sha=$SHA_A). kill → launch cmd B (same model-id, sha Y2=$SHA_B)" >&2
  stop_provider

  # (3) Relaunch with cmd B (same model-id, different sha256).
  #     Geometry-seed on a throwaway key first, then send the same-conversation
  #     second turn. Expect disk_miss_envelope.
  local LOG_B="$WORK/provider-b-$cycle.log"
  start_provider "$KVS03_PROVIDER_CMD_B" "$LOG_B"
  await_ready

  # Geometry-seed turn on a throwaway key (documented residual — see KVS-01a README).
  "$NODE_BIN" "$HERE/kvs-01a-probe.mjs" \
    --base "$KVS03_BASE" --conversation "$SEED_CONV" --model "$MODEL_B" \
    --regime kvs03_seed --arm seed --prompt-tokens "$KVS03_PROMPT_TOKENS" >/dev/null || true
  await_log "$LOG_B" 'code=disk_write_committed' "$KVS03_WRITE_TIMEOUT" >/dev/null || true

  local MISS_JSON MISS_LINE
  MISS_JSON="$("$NODE_BIN" "$HERE/kvs-01a-probe.mjs" \
    --base "$KVS03_BASE" --conversation "$CONVERSATION" --model "$MODEL_B" \
    --regime kvs03_miss_envelope --arm miss_envelope \
    --prompt-tokens "$KVS03_PROMPT_TOKENS" \
    --assistant-file "$RESP" --suffix "$SUFFIX" || true)"
  MISS_LINE="$(await_log "$LOG_B" 'code=disk_(hit|promote_rejected|miss_[a-z_]+)' 30 || true)"

  local MISS_CODE MISS_CACHED MISS_CORRECT
  MISS_CODE="$(sed -nE 's/.*code=([a-z_]+).*/\1/p' <<<"$MISS_LINE" | tail -1)"
  MISS_CACHED="$(json_get cached_prompt_tokens <<<"$MISS_JSON")"
  MISS_CORRECT="$(json_get correctness <<<"$MISS_JSON")"

  record_sample "$MISS_JSON" "$MISS_LINE" "$WRITE_LINE" "$cycle" "$MODEL_B" "$SHA_A" "$SHA_B" "miss_envelope" \
    | tee -a "$KVS03_STORE" >/dev/null || true

  if [[ "$MISS_CODE" == "disk_miss_envelope" \
     && ( -z "$MISS_CACHED" || "$MISS_CACHED" == "0" || "$MISS_CACHED" == "null" ) \
     && "$MISS_CORRECT" == "ok" ]]; then
    echo "kvs-03[c$cycle]: PASS miss_envelope: code=$MISS_CODE cached=${MISS_CACHED:-0} correctness=$MISS_CORRECT shaA=$SHA_A shaB=$SHA_B" >&2
    ok=1
  else
    echo "kvs-03[c$cycle]: FAIL miss_envelope: code=${MISS_CODE:-none} cached=${MISS_CACHED:-none} correctness=${MISS_CORRECT:-none} (expected disk_miss_envelope cached=0 correctness=ok)" >&2
  fi

  stop_provider
  if (( ok == 1 )); then return 0; fi
  return 5
}

# ------------------------------------------------------------------- driver ---------
FAILS=0
for (( c = 1; c <= KVS03_CYCLES; c++ )); do
  if ! run_one_cycle "$c"; then FAILS=$(( FAILS + 1 )); fi
  stop_provider
done

if (( FAILS > 0 )); then
  echo "kvs-03: $FAILS/$KVS03_CYCLES cycle(s) FAILED the sha256-change invalidation contract" >&2; exit 5
fi
echo "kvs-03: all $KVS03_CYCLES cycle(s) passed → $KVS03_STORE" >&2
