#!/usr/bin/env bash
# SPEC-037 KVS-01a — restart-survival gate (FR-KVP13 / §6), the runnable v1 gate.
# It exercises the encrypted KV disk tier end to end against LOCAL providers you own
# across FOUR interleaved arms, one sample per arm per cycle, and applies the §6
# warm-relative pass contract.
#
# The five-step per-cycle sequence:
#   1. persist turn: a synthetic conv:kvs-synth: prefix (~2.5k tokens) sent as ONE
#      user turn over the direct-HTTP operator path, which the FR-KVP11 gate persists.
#      Its assistant response is captured so later arms can replay a genuine second
#      turn. Wait for `disk_write_committed` before proceeding.
#   2. kill the provider (SIGKILL — models a crash/deploy) and relaunch the EXACT same
#      build/model with the tier ENABLED.
#   3. geometry-seed turn on a DIFFERENT throwaway conv:kvs-synth: key, to teach the
#      freshly-restarted adapter the live-model geometry template BEFORE the measured
#      restored turn (load-time config-derived geometry capture is a documented
#      residual — see the README).
#   4. the four measured arms against the relaunched (enabled) provider, plus a clean
#      disk-DISABLED restart:
#        A) restored  — genuine second turn ([user:BASE, assistant:<persist response>,
#                       user:<suffix>]) on the persisted key: expected disk_hit with
#                       cached_prompt_tokens EXACTLY equal to the persisted prefix
#                       length (persist prompt + completion) by the unchanged LCP rule;
#        B) warm      — a genuine THIRD turn (full committed transcript + a new suffix)
#                       in the SAME process: an in-RAM hot-tier hit with nonzero
#                       cached_prompt_tokens, the paired warm control. (Repeating the
#                       exact restored request would be nothing_new — LCP == incoming.)
#        C) miss      — the genuine-second-turn shape on a FRESH never-persisted key,
#                       tier enabled: a disk miss / full prefill baseline;
#        D) disabled  — the restored request after a clean restart with the tier
#                       DISABLED (KVS01A_PROVIDER_CMD_NODISK): no survival, full prefill.
#   5. record every §6 field (regime/arm, hit/miss reason, cached/full tokens, TTFT,
#      restore bytes/ms, staging peak, commit-latency delta, prompt/input hashes,
#      model id + hash, catalog/format ids, kvBits, host/build metadata, correctness)
#      to an append-only NDJSON store, following the coldwarm-ttft regime-label style.
#
# Pass contract (§6): the CORRECTNESS gates fail the run — EVERY restored sample must
# record disk_hit with the exact expected cached_prompt_tokens and correctness=ok (a
# violation is exit 5). The warm-relative PERCENTILE thresholds (restored p95 within
# KVS01A_WARM_RATIO_P95× of warm p95; restored p95 < miss p50 and < disabled p50) are
# ADVISORY for KVS-01a (~2.5k) per §6 — recorded/reported but they only fail the run
# (exit 6) under an explicit perf-gate mode (--perf-gate / KVS01A_PERF_GATE=1). They are
# normative only for KVS-01b (8k). Gate mode requires >= 30 samples/arm; --smoke allows
# 1–2 cycles (correctness only).
#
# This is harness CAPABILITY, not a CI run — it launches real models and MUST NOT run
# in CI. It refuses a production coordinator (local provider only, §6 production fence).
#
# Required env:
#   KVS01A_PROVIDER_CMD         foreground provider launch command with the tier
#                               ENABLED (kv_disk_cache.enabled=true), logging
#                               kv_disk_cache events to stderr.
#   KVS01A_PROVIDER_CMD_NODISK  same, but with the tier DISABLED — drives arm D. In
#                               --smoke arm D is skipped when this is unset; in gate
#                               mode it is required.
# Optional env:
#   KVS01A_BASE           provider HTTP base (default http://127.0.0.1:8080)
#   KVS01A_STORE          NDJSON output (default ~/.local/state/kvs-01a/samples.ndjson)
#   KVS01A_TOKEN_FILE     buyer token file (default ~/.config/macprovider/buyer-api-key)
#   KVS01A_MODEL          served model id (default: auto from /v1/status)
#   KVS01A_PROMPT_TOKENS  synthetic prefix size (default 2500 — the v1 allowlist class
#                         under the 256 MiB promotion ceiling; 8k is KVS-01b)
#   KVS01A_READY_TIMEOUT  seconds to await provider readiness (default 300)
#   KVS01A_WRITE_TIMEOUT  seconds to await disk_write_committed (default 60)
#   KVS01A_CYCLES         cycles to run (default 1 smoke / 30 gate); --cycles N flag
#   KVS01A_SMOKE          1 ⇒ smoke mode (1–2 cycles, correctness-only); --smoke flag
#   KVS01A_WARM_RATIO_P95 restored p95 <= warm p95 × this (default 3.0; advisory for 01a)
#   KVS01A_PERF_GATE      1 ⇒ enforce the warm-relative percentile thresholds (exit 6 on
#                         breach). Default 0 for KVS-01a (advisory). Also: --perf-gate.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${KVS01A_BASE:=http://127.0.0.1:8080}"
: "${KVS01A_STORE:=$HOME/.local/state/kvs-01a/samples.ndjson}"
: "${KVS01A_TOKEN_FILE:=$HOME/.config/macprovider/buyer-api-key}"
: "${KVS01A_PROMPT_TOKENS:=2500}"
: "${KVS01A_READY_TIMEOUT:=300}"
: "${KVS01A_WRITE_TIMEOUT:=60}"
: "${KVS01A_SMOKE:=0}"
: "${KVS01A_WARM_RATIO_P95:=3.0}"
: "${KVS01A_CYCLES:=}"
# MEDIUM-6: for KVS-01a (~2.5k correctness stage) the warm-relative percentile
# thresholds are ADVISORY per SPEC-037 §6 — they are recorded/reported but do NOT
# fail the run. They are normative only for KVS-01b (8k). Opt into enforcing them
# with KVS01A_PERF_GATE=1 or --perf-gate. Correctness gates always fail the run.
: "${KVS01A_PERF_GATE:=0}"
GATE_MIN_SAMPLES=30

# CLI: --cycles N, --smoke, --perf-gate.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cycles) KVS01A_CYCLES="${2:?--cycles needs a number}"; shift 2 ;;
    --cycles=*) KVS01A_CYCLES="${1#*=}"; shift ;;
    --smoke) KVS01A_SMOKE=1; shift ;;
    --perf-gate) KVS01A_PERF_GATE=1; shift ;;
    *) echo "kvs-01a: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# Default cycle count: 1 in smoke, the gate minimum otherwise.
if [[ -z "$KVS01A_CYCLES" ]]; then
  if [[ "$KVS01A_SMOKE" == "1" ]]; then KVS01A_CYCLES=1; else KVS01A_CYCLES="$GATE_MIN_SAMPLES"; fi
fi
if ! [[ "$KVS01A_CYCLES" =~ ^[0-9]+$ ]] || (( KVS01A_CYCLES < 1 )); then
  echo "kvs-01a: cycles must be a positive integer, got '$KVS01A_CYCLES'" >&2
  exit 2
fi
if [[ "$KVS01A_SMOKE" == "1" ]]; then
  if (( KVS01A_CYCLES > 2 )); then
    echo "kvs-01a: --smoke allows at most 2 cycles (got $KVS01A_CYCLES)" >&2; exit 2
  fi
else
  if (( KVS01A_CYCLES < GATE_MIN_SAMPLES )); then
    echo "kvs-01a: gate mode requires >= $GATE_MIN_SAMPLES samples/arm; use --cycles >= $GATE_MIN_SAMPLES or --smoke" >&2
    exit 2
  fi
fi

# §6 production fence — never kill-cycle a production coordinator/provider.
case "$KVS01A_BASE" in
  *streamvc.live*|*coordinator.*|*api.*)
    if [[ "${KVS01A_ALLOW_REMOTE:-0}" != "1" ]]; then
      echo "kvs-01a: refusing non-local base '$KVS01A_BASE' (§6 production fence)" >&2
      exit 3
    fi ;;
esac

if [[ -z "${KVS01A_PROVIDER_CMD:-}" ]]; then
  echo "kvs-01a: set \$KVS01A_PROVIDER_CMD to the tier-ENABLED foreground provider launch command" >&2
  exit 2
fi
if [[ "$KVS01A_SMOKE" != "1" && -z "${KVS01A_PROVIDER_CMD_NODISK:-}" ]]; then
  echo "kvs-01a: gate mode requires \$KVS01A_PROVIDER_CMD_NODISK (tier DISABLED) for arm D" >&2
  exit 2
fi

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
NODE_BIN="${KVS01A_NODE_BIN:-$(command -v node || true)}"
if [[ -z "$NODE_BIN" ]]; then
  echo "kvs-01a: node not found on PATH; set \$KVS01A_NODE_BIN" >&2
  exit 2
fi

if [[ -z "${MACPROVIDER_BUYER_TOKEN:-}" ]]; then
  if [[ -r "$KVS01A_TOKEN_FILE" ]]; then
    MACPROVIDER_BUYER_TOKEN="$(tr -d '[:space:]' < "$KVS01A_TOKEN_FILE")"
    export MACPROVIDER_BUYER_TOKEN
  else
    echo "kvs-01a: no token in \$MACPROVIDER_BUYER_TOKEN and $KVS01A_TOKEN_FILE not readable" >&2
    exit 2
  fi
fi

mkdir -p "$(dirname "$KVS01A_STORE")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kvs-01a.XXXXXX")"
trap 'rm -rf "$WORK"; [[ -n "${PROVIDER_PID:-}" ]] && kill -9 "$PROVIDER_PID" 2>/dev/null || true' EXIT

# Per-arm TTFT sample files (nearest-rank percentiles over the run).
for arm in restored warm miss disabled; do : >"$WORK/ttft.$arm.txt"; done

start_provider() { # $1=cmd $2=log
  bash -c "$1" >"$2" 2>&1 &
  PROVIDER_PID=$!
}

stop_provider() {
  [[ -n "${PROVIDER_PID:-}" ]] && { kill -9 "$PROVIDER_PID" 2>/dev/null || true; wait "$PROVIDER_PID" 2>/dev/null || true; PROVIDER_PID=""; }
}

await_ready() {
  local deadline=$(( $(date +%s) + KVS01A_READY_TIMEOUT ))
  while (( $(date +%s) < deadline )); do
    if curl -fsS -m 5 "$KVS01A_BASE/v1/status" >/dev/null 2>&1; then return 0; fi
    if ! kill -0 "$PROVIDER_PID" 2>/dev/null; then echo "kvs-01a: provider exited during startup" >&2; return 1; fi
    sleep 1
  done
  echo "kvs-01a: provider not ready within ${KVS01A_READY_TIMEOUT}s" >&2
  return 1
}

resolve_model() {
  if [[ -n "${KVS01A_MODEL:-}" ]]; then echo "$KVS01A_MODEL"; return; fi
  curl -fsS -m 5 "$KVS01A_BASE/v1/status" 2>/dev/null \
    | "$NODE_BIN" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).model_id||JSON.parse(s).currentModelID||"")}catch{console.log("")}})' || echo ""
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

# Scrape a `key=value` token from a kv_disk_cache log line.
field() { sed -nE "s/.*[[:space:]]$2=([^[:space:]]+).*/\1/p" <<<"$1" | tail -1; }

# Extract a JSON field (string or number) from a probe record.
json_get() { "$NODE_BIN" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const v=JSON.parse(s)[process.argv[1]];process.stdout.write(v==null?"":String(v))}catch{process.stdout.write("")}})' "$1"; }

# Merge one probe record with the disk-side §6 fields from BOTH the promotion event
# (disk_hit — restore bytes/ms/peak + identity) and the persist event
# (disk_write_committed — commit-latency delta + serialized bytes + identity), append to
# the store, and echo the merged record on stdout so callers can read it back. Identity/
# format fields come from either event (the persist event is authoritative — it is the
# turn whose commit-latency delta §6 measures).
merge_record() { # $1=probe json $2=hit-line(disk_hit/miss) $3=write-line(disk_write_committed) $4=cycle $5=prompt_tokens
  "$NODE_BIN" -e '
    const [probe, hitLine, writeLine, cyc, promptClass] = process.argv.slice(1);
    let rec = {}; try { rec = JSON.parse(probe); } catch {}
    const scan = (line, k) => { if (!line) return null; const m = line.match(new RegExp("(?:^|\\s)" + k + "=([^\\s]+)")); return m ? m[1] : null; };
    const either = (k) => scan(writeLine, k) ?? scan(hitLine, k);
    const numHit = (k) => { const v = scan(hitLine, k); return v == null ? null : Number(v); };
    const numWrite = (k) => { const v = scan(writeLine, k); return v == null ? null : Number(v); };
    rec.cycle = Number(cyc);
    rec.disk_reason = (hitLine.match(/code=([a-z_]+)/) || [])[1] || null;
    // promotion (restore) metrics from the disk_hit line:
    rec.restore_bytes = numHit("restore_bytes");
    rec.restore_ms = numHit("decrypt_ms");
    rec.staging_peak_bytes = numHit("peak_staging_bytes");
    // persist (commit-latency delta) metrics from the disk_write_committed line:
    rec.commit_serialized_bytes = numWrite("serialized_bytes");
    rec.commit_latency_ms = numWrite("write_ms");
    // §6 identity/build/format fields (from either event; persist preferred):
    rec.model_sha256 = either("model_sha256");
    rec.catalog_revision = either("catalog_revision");
    rec.format_schema_id = either("schema_id") || either("format_schema_id");
    rec.format_codec_id = either("codec_id");
    const kb = either("kv_bits");
    rec.kv_bits = (kb == null || kb === "null") ? null : Number(kb);  // null = v1 unquantized
    rec.prompt_class_tokens = Number(promptClass);
    process.stdout.write(JSON.stringify(rec) + "\n");
  ' "$1" "$2" "$3" "$4" "$5"
}

# Reject a restored record missing any REQUIRED §6 evidence field (kv_bits null is a
# legitimate unquantized value and is not required). Exits nonzero on the first miss.
six_ok() { # $1=merged json
  "$NODE_BIN" -e '
    let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
      let r = {}; try { r = JSON.parse(s); } catch { process.exit(1); }
      const req = ["model_sha256","catalog_revision","format_schema_id","format_codec_id",
                   "restore_bytes","restore_ms","staging_peak_bytes",
                   "commit_serialized_bytes","commit_latency_ms"];
      for (const k of req) { if (r[k] == null) { process.stderr.write("kvs-01a: restored record missing §6 field " + k + "\n"); process.exit(1); } }
      process.exit(0);
    });
  ' <<<"$1"
}

# ------------------------------------------------------------------ one cycle -------
# Appends four §6 records to $KVS01A_STORE and four per-arm TTFT samples. Returns
# nonzero if the restored arm did not disk_hit with the exact expected cached tokens
# (correctness), which fails the whole gate regardless of percentiles.
run_one_cycle() { # $1=cycle
  local cycle="$1"
  local CONVERSATION="conv:kvs-synth:$(uuidgen | tr 'A-Z' 'a-z')"
  local SEED_CONVERSATION="conv:kvs-synth:seed-$(uuidgen | tr 'A-Z' 'a-z')"
  local MISS_CONVERSATION="conv:kvs-synth:miss-$(uuidgen | tr 'A-Z' 'a-z')"
  local SUFFIX="continue-$RANDOM"
  local SUFFIX2="continue2-$RANDOM"
  local RESP="$WORK/response-$cycle.txt"
  local RESP2="$WORK/response2-$cycle.txt"

  echo "kvs-01a[c$cycle]: persist turn key_hash=$(printf '%s' "$CONVERSATION" | shasum -a 256 | cut -c1-8)" >&2

  local LOG1="$WORK/provider-1-$cycle.log"
  start_provider "$KVS01A_PROVIDER_CMD" "$LOG1"
  await_ready
  local MODEL; MODEL="$(resolve_model)"

  # (1) persist turn — one user turn; capture the assistant response for the 2nd turn.
  local PERSIST_JSON
  PERSIST_JSON="$("$NODE_BIN" "$HERE/kvs-01a-probe.mjs" \
    --base "$KVS01A_BASE" --conversation "$CONVERSATION" --model "$MODEL" \
    --regime kvs01a_persist --arm persist --prompt-tokens "$KVS01A_PROMPT_TOKENS" \
    --response-out "$RESP")"
  local P_PROMPT P_COMPLETION
  P_PROMPT="$(json_get prompt_tokens <<<"$PERSIST_JSON")"
  P_COMPLETION="$(json_get completion_tokens <<<"$PERSIST_JSON")"
  if [[ -z "$P_PROMPT" || -z "$P_COMPLETION" ]]; then
    echo "kvs-01a[c$cycle]: persist turn returned no usage; aborting cycle" >&2; return 4
  fi
  # The persisted canonical is prompt_token_ids ‖ generated; the restored render carries
  # both as an exact prefix, so the expected cached count is prompt + completion.
  local EXPECTED_CACHED=$(( P_PROMPT + P_COMPLETION ))

  # (2) persist barrier + kill + relaunch (tier enabled).
  local WRITE_LINE
  WRITE_LINE="$(await_log "$LOG1" 'code=disk_write_committed' "$KVS01A_WRITE_TIMEOUT" || true)"
  if [[ -z "$WRITE_LINE" ]]; then
    echo "kvs-01a[c$cycle]: no disk_write_committed within ${KVS01A_WRITE_TIMEOUT}s — nothing persisted" >&2; return 4
  fi
  echo "kvs-01a[c$cycle]: kill + relaunch (enabled)" >&2
  stop_provider
  local LOG2="$WORK/provider-2-$cycle.log"
  start_provider "$KVS01A_PROVIDER_CMD" "$LOG2"
  await_ready

  # (3) geometry-seed turn on a throwaway key (documented residual — see README).
  "$NODE_BIN" "$HERE/kvs-01a-probe.mjs" \
    --base "$KVS01A_BASE" --conversation "$SEED_CONVERSATION" --model "$MODEL" \
    --regime kvs01a_seed --arm seed --prompt-tokens "$KVS01A_PROMPT_TOKENS" >/dev/null
  await_log "$LOG2" 'code=disk_write_committed' "$KVS01A_WRITE_TIMEOUT" >/dev/null || true

  local ok=0

  # (4A) restored arm — genuine second turn on the persisted key → disk_hit. Capture ITS
  # assistant response (RESP2) so the warm arm can form a genuine THIRD turn.
  local R_JSON R_HIT R_MERGED R_TTFT R_CACHED R_CORRECT
  R_JSON="$("$NODE_BIN" "$HERE/kvs-01a-probe.mjs" \
    --base "$KVS01A_BASE" --conversation "$CONVERSATION" --model "$MODEL" \
    --regime kvs01a_restored --arm restored --prompt-tokens "$KVS01A_PROMPT_TOKENS" \
    --assistant-file "$RESP" --suffix "$SUFFIX" --response-out "$RESP2")"
  R_HIT="$(await_log "$LOG2" 'code=disk_(hit|promote_rejected|miss_[a-z_]+)' 30 || true)"
  # Merge the promotion (disk_hit) AND the persist (WRITE_LINE) §6 fields into one record.
  R_MERGED="$(merge_record "$R_JSON" "$R_HIT" "$WRITE_LINE" "$cycle" "$KVS01A_PROMPT_TOKENS")"
  printf '%s' "$R_MERGED" | tee -a "$KVS01A_STORE" >/dev/null
  R_TTFT="$(json_get ttft_ms <<<"$R_JSON")"
  R_CACHED="$(json_get cached_prompt_tokens <<<"$R_JSON")"
  R_CORRECT="$(json_get correctness <<<"$R_JSON")"
  local R_CODE; R_CODE="$(sed -nE 's/.*code=([a-z_]+).*/\1/p' <<<"$R_HIT" | tail -1)"
  [[ -n "$R_TTFT" ]] && echo "$R_TTFT" >>"$WORK/ttft.restored.txt"
  local R_SIX_OK=1
  if [[ "$KVS01A_SMOKE" != "1" ]] && ! six_ok "$R_MERGED"; then R_SIX_OK=0; fi
  if [[ "$R_CODE" == "disk_hit" && "$R_CORRECT" == "ok" && -n "$R_CACHED" && "$R_CACHED" == "$EXPECTED_CACHED" && "$R_SIX_OK" == "1" ]]; then
    echo "kvs-01a[c$cycle]: PASS restored disk_hit cached=$R_CACHED (=$EXPECTED_CACHED) ttft=${R_TTFT:-none}ms" >&2
    ok=1
  else
    echo "kvs-01a[c$cycle]: FAIL restored code=${R_CODE:-none} correctness=${R_CORRECT:-none} cached=${R_CACHED:-none} expected=$EXPECTED_CACHED six_ok=$R_SIX_OK" >&2
  fi

  # (4B) warm arm — a genuine THIRD turn (full committed transcript + new suffix) in the
  # SAME process → in-RAM hot hit with nonzero cached_prompt_tokens (the paired control).
  # Repeating the exact restored request would be nothing_new (LCP == incoming length).
  local W_JSON W_TTFT W_CACHED
  W_JSON="$("$NODE_BIN" "$HERE/kvs-01a-probe.mjs" \
    --base "$KVS01A_BASE" --conversation "$CONVERSATION" --model "$MODEL" \
    --regime kvs01a_warm --arm warm --prompt-tokens "$KVS01A_PROMPT_TOKENS" \
    --assistant-file "$RESP" --suffix "$SUFFIX" --assistant-file2 "$RESP2" --suffix2 "$SUFFIX2")"
  merge_record "$W_JSON" "" "" "$cycle" "$KVS01A_PROMPT_TOKENS" | tee -a "$KVS01A_STORE" >/dev/null
  W_TTFT="$(json_get ttft_ms <<<"$W_JSON")"
  W_CACHED="$(json_get cached_prompt_tokens <<<"$W_JSON")"
  [[ -n "$W_TTFT" ]] && echo "$W_TTFT" >>"$WORK/ttft.warm.txt"
  if [[ -z "$W_CACHED" ]] || (( W_CACHED <= 0 )); then
    echo "kvs-01a[c$cycle]: FAIL warm arm cached=${W_CACHED:-none} (expected nonzero hot hit — turn-3 control)" >&2
    ok=0
  fi

  # (4C) miss arm — fresh never-persisted key, tier enabled → disk miss / full prefill.
  local M_JSON M_HIT M_TTFT
  M_JSON="$("$NODE_BIN" "$HERE/kvs-01a-probe.mjs" \
    --base "$KVS01A_BASE" --conversation "$MISS_CONVERSATION" --model "$MODEL" \
    --regime kvs01a_miss --arm miss --prompt-tokens "$KVS01A_PROMPT_TOKENS" \
    --assistant-file "$RESP" --suffix "$SUFFIX")"
  M_HIT="$(await_log "$LOG2" 'code=disk_(hit|miss_[a-z_]+)' 15 || true)"
  merge_record "$M_JSON" "$M_HIT" "" "$cycle" "$KVS01A_PROMPT_TOKENS" | tee -a "$KVS01A_STORE" >/dev/null
  M_TTFT="$(json_get ttft_ms <<<"$M_JSON")"
  [[ -n "$M_TTFT" ]] && echo "$M_TTFT" >>"$WORK/ttft.miss.txt"

  # (4D) disabled arm — clean restart with the tier DISABLED → no survival, full prefill.
  if [[ -n "${KVS01A_PROVIDER_CMD_NODISK:-}" ]]; then
    echo "kvs-01a[c$cycle]: kill + relaunch (disabled)" >&2
    stop_provider
    local LOG3="$WORK/provider-3-$cycle.log"
    start_provider "$KVS01A_PROVIDER_CMD_NODISK" "$LOG3"
    await_ready
    local D_JSON D_TTFT
    D_JSON="$("$NODE_BIN" "$HERE/kvs-01a-probe.mjs" \
      --base "$KVS01A_BASE" --conversation "$CONVERSATION" --model "$MODEL" \
      --regime kvs01a_disabled --arm disabled --prompt-tokens "$KVS01A_PROMPT_TOKENS" \
      --assistant-file "$RESP" --suffix "$SUFFIX")"
    merge_record "$D_JSON" "" "" "$cycle" "$KVS01A_PROMPT_TOKENS" | tee -a "$KVS01A_STORE" >/dev/null
    D_TTFT="$(json_get ttft_ms <<<"$D_JSON")"
    [[ -n "$D_TTFT" ]] && echo "$D_TTFT" >>"$WORK/ttft.disabled.txt"
  fi

  stop_provider
  (( ok == 1 )) && return 0 || return 5
}

# ------------------------------------------------------------------- driver --------
FAILS=0
for (( c = 1; c <= KVS01A_CYCLES; c++ )); do
  if ! run_one_cycle "$c"; then FAILS=$(( FAILS + 1 )); fi
  stop_provider
done

# Nearest-rank percentile summary + warm-relative pass contract.
"$NODE_BIN" -e '
  const fs = require("fs");
  const work = process.argv[1], ratioP95 = Number(process.argv[2]), smoke = process.argv[3] === "1", perfGate = process.argv[4] === "1";
  const read = (arm) => { try { return fs.readFileSync(`${work}/ttft.${arm}.txt`, "utf8").split("\n").map(Number).filter(Number.isFinite).sort((a,b)=>a-b); } catch { return []; } };
  const nr = (xs, p) => xs.length ? xs[Math.min(xs.length-1, Math.max(0, Math.ceil(p/100*xs.length)-1))] : null;
  const arms = ["restored","warm","miss","disabled"];
  const pct = {};
  for (const a of arms) { const xs = read(a); pct[a] = { n: xs.length, p50: nr(xs,50), p95: nr(xs,95), min: xs[0] ?? null, max: xs[xs.length-1] ?? null }; }
  process.stderr.write("kvs-01a: nearest-rank TTFT percentiles (ms):\n");
  for (const a of arms) { const p = pct[a]; process.stderr.write(`  ${a.padEnd(9)} n=${p.n} p50=${p.p50 ?? "-"} p95=${p.p95 ?? "-"} min=${p.min ?? "-"} max=${p.max ?? "-"}\n`); }
  if (smoke) { process.stderr.write("kvs-01a: smoke mode — percentile thresholds skipped (correctness only)\n"); process.exit(0); }
  // MEDIUM-6: warm-relative thresholds are ADVISORY for KVS-01a (~2.5k) — recorded and
  // reported, but they only FAIL the run under an explicit perf-gate mode. They are
  // normative only for KVS-01b (8k). Correctness gates fail the run regardless (exit 5).
  let fail = 0;
  const r = pct.restored, w = pct.warm, m = pct.miss, d = pct.disabled;
  const tag = perfGate ? "THRESHOLD FAIL" : "THRESHOLD ADVISORY";
  const note = (msg) => { process.stderr.write(`kvs-01a: ${tag} ${msg}\n`); if (perfGate) fail = 1; };
  // restored must skip prefill just like the in-RAM warm control.
  if (r.p95 != null && w.p95 != null && r.p95 > w.p95 * ratioP95) { note(`restored p95 ${r.p95} > warm p95 ${w.p95} × ${ratioP95}`); }
  // restored (disk survival) must beat a disk-enabled miss (cold prefill).
  if (r.p95 != null && m.p50 != null && !(r.p95 < m.p50)) { note(`restored p95 ${r.p95} !< miss p50 ${m.p50}`); }
  // ... and a clean disk-disabled restart.
  if (r.p95 != null && d.p50 != null && !(r.p95 < d.p50)) { note(`restored p95 ${r.p95} !< disabled p50 ${d.p50}`); }
  if (!perfGate) { process.stderr.write("kvs-01a: percentile thresholds are advisory for KVS-01a (pass --perf-gate to enforce)\n"); }
  process.exit(fail);
' "$WORK" "$KVS01A_WARM_RATIO_P95" "$KVS01A_SMOKE" "$KVS01A_PERF_GATE" || THRESHOLD_FAIL=1

if (( FAILS > 0 )); then
  echo "kvs-01a: $FAILS/$KVS01A_CYCLES cycle(s) FAILED the restored correctness contract" >&2
  exit 5
fi
if [[ "${THRESHOLD_FAIL:-0}" == "1" ]]; then
  # Only reachable under --perf-gate / KVS01A_PERF_GATE=1 (MEDIUM-6): for KVS-01a the
  # warm-relative thresholds are advisory and never set THRESHOLD_FAIL otherwise.
  echo "kvs-01a: restored correctness held but the warm-relative percentile thresholds failed (perf-gate)" >&2
  exit 6
fi
echo "kvs-01a: all $KVS01A_CYCLES cycle(s) passed → $KVS01A_STORE" >&2
