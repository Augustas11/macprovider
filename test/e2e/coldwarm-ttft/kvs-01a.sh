#!/usr/bin/env bash
# SPEC-037 KVS-01a — restart-survival harness cycle (the runnable v1 gate,
# FR-KVP13 / §6). It exercises the encrypted KV disk tier end to end against a
# LOCAL provider you own:
#
#   1. warm turn: a synthetic conv:kvs-synth: prefix (~2.5k tokens) over the
#      direct-HTTP operator path, which the FR-KVP11 gate persists;
#   2. persist barrier: wait for `disk_write_committed` in the provider stderr;
#   3. kill the provider (SIGKILL — models a crash/deploy), then relaunch the
#      EXACT same build/model;
#   4. template-seed turn: a warm turn on a DIFFERENT throwaway conv:kvs-synth:
#      key, to teach the freshly-restarted adapter the live-model geometry
#      template BEFORE the measured restored turn. This is belt-and-braces for
#      HIGH-3: load-time config-derived geometry capture (fix a) is a documented
#      residual (see README), so the harness seeds the template explicitly rather
#      than depending on the first post-restart commit having already happened.
#   5. restored turn: the same persisted prefix + one new suffix token, within the
#      eligibility window — expected to promote from disk (disk_hit) and report a
#      cached_prompt_tokens EQUAL to the persisted prefix's prompt_tokens by the
#      unchanged LCP rule. The harness EXITS NONZERO if the restored arm does not
#      record disk_hit with the exact expected cached_prompt_tokens.
#   6. record the §6 fields (hit/miss reason, cached/full tokens, TTFT, restore
#      bytes/ms, staging peak, commit-latency delta) to an append-only NDJSON
#      store, following the coldwarm-ttft regime-label convention.
#
# This is harness CAPABILITY, not a CI run — it launches a real model and MUST
# NOT run in CI. It refuses a production coordinator (local provider only, §6
# production fence).
#
# Required env:
#   KVS01A_PROVIDER_CMD   shell command that starts the provider in the
#                         FOREGROUND, logging kv_disk_cache events to stderr
#                         (e.g. "macprovider-cli serve --config …"). The tier
#                         MUST be enabled (kv_disk_cache.enabled=true) for the
#                         provider identity under test.
# Optional env:
#   KVS01A_BASE           provider HTTP base (default http://127.0.0.1:8080)
#   KVS01A_STORE          NDJSON output (default ~/.local/state/kvs-01a/samples.ndjson)
#   KVS01A_TOKEN_FILE     buyer token file (default ~/.config/macprovider/buyer-api-key)
#   KVS01A_MODEL          served model id (default: auto from /v1/status)
#   KVS01A_PROMPT_TOKENS  synthetic prefix size (default 2500 — the v1 allowlist
#                         class under the 256 MiB promotion ceiling; 8k is KVS-01b)
#   KVS01A_READY_TIMEOUT  seconds to await provider readiness (default 300)
#   KVS01A_WRITE_TIMEOUT  seconds to await disk_write_committed (default 60)
#   KVS01A_CYCLES         number of full cycles to run (default 1); >1 interleaves
#                         the arms and prints a nearest-rank percentile summary.
#                         --cycles N is an equivalent CLI flag.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${KVS01A_BASE:=http://127.0.0.1:8080}"
: "${KVS01A_STORE:=$HOME/.local/state/kvs-01a/samples.ndjson}"
: "${KVS01A_TOKEN_FILE:=$HOME/.config/macprovider/buyer-api-key}"
: "${KVS01A_PROMPT_TOKENS:=2500}"
: "${KVS01A_READY_TIMEOUT:=300}"
: "${KVS01A_WRITE_TIMEOUT:=60}"
: "${KVS01A_CYCLES:=1}"

# CLI: --cycles N (overrides KVS01A_CYCLES).
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cycles) KVS01A_CYCLES="${2:?--cycles needs a number}"; shift 2 ;;
    --cycles=*) KVS01A_CYCLES="${1#*=}"; shift ;;
    *) echo "kvs-01a: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
if ! [[ "$KVS01A_CYCLES" =~ ^[0-9]+$ ]] || (( KVS01A_CYCLES < 1 )); then
  echo "kvs-01a: KVS01A_CYCLES must be a positive integer, got '$KVS01A_CYCLES'" >&2
  exit 2
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
  echo "kvs-01a: set \$KVS01A_PROVIDER_CMD to the foreground provider launch command" >&2
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

start_provider() {
  local log="$1"
  bash -c "$KVS01A_PROVIDER_CMD" >"$log" 2>&1 &
  PROVIDER_PID=$!
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

# await a kv_disk_cache reason code in the provider stderr log; echoes the last
# matching line so the §6 disk-side fields can be scraped.
await_log() {
  local log="$1" pattern="$2" timeout="$3"
  local deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    local hit; hit="$(grep -aE "$pattern" "$log" | tail -1 || true)"
    if [[ -n "$hit" ]]; then echo "$hit"; return 0; fi
    sleep 1
  done
  return 1
}

# Scrape a `key=value` token from a kv_disk_cache log line.
field() { sed -nE "s/.*[[:space:]]$2=([^[:space:]]+).*/\1/p" <<<"$1" | tail -1; }

# Extract a numeric JSON field from a probe record.
json_num() { "$NODE_BIN" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const v=JSON.parse(s)[process.argv[1]];process.stdout.write(v==null?"":String(v))}catch{process.stdout.write("")}})' "$1"; }

# Run one full KVS-01a cycle. Appends the §6 record to $KVS01A_STORE and echoes
# the restored-arm TTFT (ms) on fd 3 for the percentile summary. Returns nonzero
# if the restored arm did not record disk_hit with the exact expected cached
# prompt tokens.
run_one_cycle() {
  local cycle="$1"
  local CONVERSATION="conv:kvs-synth:$(uuidgen | tr 'A-Z' 'a-z')"
  local SEED_CONVERSATION="conv:kvs-synth:seed-$(uuidgen | tr 'A-Z' 'a-z')"
  local SUFFIX_TOKEN="$RANDOM$RANDOM"

  echo "kvs-01a[c$cycle]: warm turn (persist) key_hash_prefix=$(printf '%s' "$CONVERSATION" | shasum -a 256 | cut -c1-8)" >&2

  local LOG1="$WORK/provider-1-$cycle.log"
  start_provider "$LOG1"
  await_ready
  local MODEL; MODEL="$(resolve_model)"

  # (1) warm/persist turn — NO masking: a probe failure fails the cycle.
  local WARM_JSON
  WARM_JSON="$("$NODE_BIN" "$HERE/kvs-01a-probe.mjs" \
    --base "$KVS01A_BASE" --conversation "$CONVERSATION" --model "$MODEL" \
    --regime kvs01a_persist --arm persist --prompt-tokens "$KVS01A_PROMPT_TOKENS")"
  local WARM_PROMPT_TOKENS; WARM_PROMPT_TOKENS="$(json_num prompt_tokens <<<"$WARM_JSON")"

  # (2) persist barrier: kill only AFTER disk_write_committed.
  local WRITE_LINE
  WRITE_LINE="$(await_log "$LOG1" 'code=disk_write_committed' "$KVS01A_WRITE_TIMEOUT" || true)"
  if [[ -z "$WRITE_LINE" ]]; then
    echo "kvs-01a[c$cycle]: no disk_write_committed within ${KVS01A_WRITE_TIMEOUT}s — nothing persisted" >&2
    return 4
  fi
  local COMMIT_BYTES COMMIT_MS
  COMMIT_BYTES="$(field "$WRITE_LINE" serialized_bytes)"
  COMMIT_MS="$(field "$WRITE_LINE" write_ms)"

  # (3) kill + relaunch the exact same build/model.
  echo "kvs-01a[c$cycle]: kill + relaunch" >&2
  kill -9 "$PROVIDER_PID" 2>/dev/null || true
  wait "$PROVIDER_PID" 2>/dev/null || true
  PROVIDER_PID=""

  local LOG2="$WORK/provider-2-$cycle.log"
  start_provider "$LOG2"
  await_ready

  # (4) template-seed turn on a DIFFERENT throwaway key, BEFORE the measured
  # restored turn (HIGH-3 belt-and-braces — see the header + README). It teaches
  # the freshly-restarted adapter the live-model geometry template so the restored
  # turn can promote even though load-time config-derived capture is deferred.
  "$NODE_BIN" "$HERE/kvs-01a-probe.mjs" \
    --base "$KVS01A_BASE" --conversation "$SEED_CONVERSATION" --model "$MODEL" \
    --regime kvs01a_seed --arm seed --prompt-tokens "$KVS01A_PROMPT_TOKENS" >/dev/null
  # Barrier: wait until the seed's geometry template is committed (disk_write_committed),
  # so the subsequent restored turn's promotion has a template to validate against.
  await_log "$LOG2" 'code=disk_write_committed' "$KVS01A_WRITE_TIMEOUT" >/dev/null || true

  # (5) restored turn: same persisted prefix + one new suffix token → LCP is the
  # whole prefix. NO masking.
  local RESTORED_JSON
  RESTORED_JSON="$("$NODE_BIN" "$HERE/kvs-01a-probe.mjs" \
    --base "$KVS01A_BASE" --conversation "$CONVERSATION" --model "$MODEL" \
    --regime kvs01a_restored --arm restored --prompt-tokens "$KVS01A_PROMPT_TOKENS" \
    --suffix-token "$SUFFIX_TOKEN")"

  # Scrape the disk-side §6 fields from the relaunched provider's stderr.
  local HIT_LINE HIT_CODE RESTORE_BYTES RESTORE_MS STAGING_PEAK
  HIT_LINE="$(await_log "$LOG2" 'code=disk_(hit|promote_rejected|miss_[a-z]+)' 30 || true)"
  HIT_CODE="$(sed -nE 's/.*code=([a-z_]+).*/\1/p' <<<"$HIT_LINE" | tail -1)"
  RESTORE_BYTES="$(field "$HIT_LINE" restore_bytes)"
  RESTORE_MS="$(field "$HIT_LINE" decrypt_ms)"
  STAGING_PEAK="$(field "$HIT_LINE" peak_staging_bytes)"

  # Merge probe + disk-side fields into one §6 record and append to the store.
  "$NODE_BIN" -e '
    const [restored, hitCode, restoreBytes, restoreMs, stagingPeak, commitBytes, commitMs, promptTokens, cyc] = process.argv.slice(1);
    let rec = {}; try { rec = JSON.parse(restored); } catch {}
    rec.cycle = Number(cyc);
    rec.disk_reason = hitCode || null;
    rec.restore_bytes = restoreBytes ? Number(restoreBytes) : null;
    rec.restore_ms = restoreMs ? Number(restoreMs) : null;
    rec.staging_peak_bytes = stagingPeak ? Number(stagingPeak) : null;
    rec.commit_serialized_bytes = commitBytes ? Number(commitBytes) : null;
    rec.commit_latency_ms = commitMs ? Number(commitMs) : null;
    rec.prompt_class_tokens = Number(promptTokens);
    process.stdout.write(JSON.stringify(rec) + "\n");
  ' "$RESTORED_JSON" "$HIT_CODE" "$RESTORE_BYTES" "$RESTORE_MS" "$STAGING_PEAK" "$COMMIT_BYTES" "$COMMIT_MS" "$KVS01A_PROMPT_TOKENS" "$cycle" \
    | tee -a "$KVS01A_STORE"

  # Strict pass/fail: the restored arm MUST promote from disk with the exact
  # expected cached_prompt_tokens (= the persisted prefix's prompt_tokens).
  local RESTORED_CACHED RESTORED_TTFT
  RESTORED_CACHED="$(json_num cached_prompt_tokens <<<"$RESTORED_JSON")"
  RESTORED_TTFT="$(json_num ttft_ms <<<"$RESTORED_JSON")"
  if [[ "$HIT_CODE" != "disk_hit" ]]; then
    echo "kvs-01a[c$cycle]: FAIL restored arm did not disk_hit (disk_reason=${HIT_CODE:-none})" >&2
    return 5
  fi
  if [[ -z "$WARM_PROMPT_TOKENS" || -z "$RESTORED_CACHED" || "$RESTORED_CACHED" != "$WARM_PROMPT_TOKENS" ]]; then
    echo "kvs-01a[c$cycle]: FAIL restored cached_prompt_tokens=${RESTORED_CACHED:-none} != persisted prompt_tokens=${WARM_PROMPT_TOKENS:-none}" >&2
    return 5
  fi

  echo "kvs-01a[c$cycle]: PASS disk_hit cached_prompt_tokens=$RESTORED_CACHED ttft_ms=${RESTORED_TTFT:-none}" >&2
  [[ -n "$RESTORED_TTFT" ]] && echo "$RESTORED_TTFT" >&3 || true
  return 0
}

# --- Driver: N cycles, interleaved, with a nearest-rank percentile summary. ---
TTFT_FILE="$WORK/restored-ttft.txt"
: >"$TTFT_FILE"
FAILS=0
for (( c = 1; c <= KVS01A_CYCLES; c++ )); do
  if ! { run_one_cycle "$c" 3>>"$TTFT_FILE"; }; then
    FAILS=$(( FAILS + 1 ))
  fi
  # Tear down between cycles so the next cycle starts clean.
  [[ -n "${PROVIDER_PID:-}" ]] && { kill -9 "$PROVIDER_PID" 2>/dev/null || true; wait "$PROVIDER_PID" 2>/dev/null || true; PROVIDER_PID=""; }
done

if (( KVS01A_CYCLES > 1 )); then
  echo "kvs-01a: restored-arm TTFT percentiles (nearest-rank) over $KVS01A_CYCLES cycles:" >&2
  "$NODE_BIN" -e '
    const fs = require("fs");
    const xs = fs.readFileSync(process.argv[1], "utf8").split("\n").map(Number).filter(x => Number.isFinite(x)).sort((a,b)=>a-b);
    if (!xs.length) { process.stderr.write("  (no successful restored TTFT samples)\n"); process.exit(0); }
    // Nearest-rank percentile: ceil(p/100 * N), 1-based.
    const nr = p => xs[Math.min(xs.length - 1, Math.max(0, Math.ceil(p/100 * xs.length) - 1))];
    process.stderr.write(`  n=${xs.length} p50=${nr(50)}ms p90=${nr(90)}ms p99=${nr(99)}ms min=${xs[0]}ms max=${xs[xs.length-1]}ms\n`);
  ' "$TTFT_FILE"
fi

if (( FAILS > 0 )); then
  echo "kvs-01a: $FAILS/$KVS01A_CYCLES cycle(s) FAILED" >&2
  exit 5
fi
echo "kvs-01a: all $KVS01A_CYCLES cycle(s) passed → $KVS01A_STORE" >&2
