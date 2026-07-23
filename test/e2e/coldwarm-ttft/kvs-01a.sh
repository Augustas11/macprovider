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
#   4. restored turn: the same prefix + one new suffix token, within the
#      eligibility window — expected to promote from disk (disk_hit) and report a
#      positive cached_prompt_tokens by the unchanged LCP rule;
#   5. record the §6 fields (hit/miss reason, cached/full tokens, TTFT, restore
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
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${KVS01A_BASE:=http://127.0.0.1:8080}"
: "${KVS01A_STORE:=$HOME/.local/state/kvs-01a/samples.ndjson}"
: "${KVS01A_TOKEN_FILE:=$HOME/.config/macprovider/buyer-api-key}"
: "${KVS01A_PROMPT_TOKENS:=2500}"
: "${KVS01A_READY_TIMEOUT:=300}"
: "${KVS01A_WRITE_TIMEOUT:=60}"

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

# A fresh synthetic key per cycle. The raw key is local-only and never logged raw.
CONVERSATION="conv:kvs-synth:$(uuidgen | tr 'A-Z' 'a-z')"
SUFFIX_TOKEN="$RANDOM$RANDOM"

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

echo "kvs-01a: warm turn (persist) key_hash_prefix=$(printf '%s' "$CONVERSATION" | shasum -a 256 | cut -c1-8)" >&2

LOG1="$WORK/provider-1.log"
start_provider "$LOG1"
await_ready
MODEL="$(resolve_model)"

WARM_JSON="$("$NODE_BIN" "$HERE/kvs-01a-probe.mjs" \
  --base "$KVS01A_BASE" --conversation "$CONVERSATION" --model "$MODEL" \
  --regime kvs01a_persist --arm persist --prompt-tokens "$KVS01A_PROMPT_TOKENS" || true)"

# Persist barrier: the KVS-01a contract kills only AFTER disk_write_committed.
WRITE_LINE="$(await_log "$LOG1" 'code=disk_write_committed' "$KVS01A_WRITE_TIMEOUT" || true)"
if [[ -z "$WRITE_LINE" ]]; then
  echo "kvs-01a: no disk_write_committed within ${KVS01A_WRITE_TIMEOUT}s — aborting (nothing persisted)" >&2
  exit 4
fi
COMMIT_BYTES="$(field "$WRITE_LINE" serialized_bytes)"
COMMIT_MS="$(field "$WRITE_LINE" write_ms)"

echo "kvs-01a: kill + relaunch" >&2
kill -9 "$PROVIDER_PID" 2>/dev/null || true
wait "$PROVIDER_PID" 2>/dev/null || true
PROVIDER_PID=""

LOG2="$WORK/provider-2.log"
start_provider "$LOG2"
await_ready

# Restored turn: same prefix + one new suffix token → LCP is the whole prefix.
RESTORED_JSON="$("$NODE_BIN" "$HERE/kvs-01a-probe.mjs" \
  --base "$KVS01A_BASE" --conversation "$CONVERSATION" --model "$MODEL" \
  --regime kvs01a_restored --arm restored --prompt-tokens "$KVS01A_PROMPT_TOKENS" \
  --suffix-token "$SUFFIX_TOKEN" || true)"

# Scrape the disk-side §6 fields from the relaunched provider's stderr.
HIT_LINE="$(await_log "$LOG2" 'code=disk_(hit|promote_rejected|miss_[a-z]+)' 30 || true)"
HIT_CODE="$(sed -nE 's/.*code=([a-z_]+).*/\1/p' <<<"$HIT_LINE" | tail -1)"
RESTORE_BYTES="$(field "$HIT_LINE" restore_bytes)"
RESTORE_MS="$(field "$HIT_LINE" decrypt_ms)"
STAGING_PEAK="$(field "$HIT_LINE" peak_staging_bytes)"

# Merge probe + disk-side fields into one §6 record and append to the store.
"$NODE_BIN" -e '
  const [restored, hitCode, restoreBytes, restoreMs, stagingPeak, commitBytes, commitMs, promptTokens] = process.argv.slice(1);
  let rec = {}; try { rec = JSON.parse(restored); } catch {}
  rec.disk_reason = hitCode || null;
  rec.restore_bytes = restoreBytes ? Number(restoreBytes) : null;
  rec.restore_ms = restoreMs ? Number(restoreMs) : null;
  rec.staging_peak_bytes = stagingPeak ? Number(stagingPeak) : null;
  rec.commit_serialized_bytes = commitBytes ? Number(commitBytes) : null;
  rec.commit_latency_ms = commitMs ? Number(commitMs) : null;
  rec.prompt_class_tokens = Number(promptTokens);
  process.stdout.write(JSON.stringify(rec) + "\n");
' "$RESTORED_JSON" "$HIT_CODE" "$RESTORE_BYTES" "$RESTORE_MS" "$STAGING_PEAK" "$COMMIT_BYTES" "$COMMIT_MS" "$KVS01A_PROMPT_TOKENS" \
  | tee -a "$KVS01A_STORE"

echo "kvs-01a: recorded disk_reason=${HIT_CODE:-none} → $KVS01A_STORE" >&2
