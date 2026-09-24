#!/usr/bin/env bash
# #1690 benchmark: llama.cpp llama-server vs native MLX on one catalog key.
# Runs on a DRAINED lab Mac only. It refuses to start while another
# llama-server or any unpaused macprovider-cli serve process is running,
# because contention invalidates the numbers and must never degrade a live
# provider. Pausing is strictly opt-in: only with PAUSE_PROVIDER=1 plus
# PAUSE_PROVIDER_SOCKET and PAUSE_PROVIDER_PORT does the script drain one live
# provider through its control socket (operator pause: the provider drains
# in-flight work, the coordinator stops routing to it, the watchdog leaves it
# alone). The resume handler is installed before the pause is sent, retries,
# and verifies the provider reports unpaused; on failure it says so loudly and
# the script exits non-zero. PPL_ONLY=1 never pauses anything.
#
# Usage:
#   CLI=/path/to/run/macprovider-cli   # release build with mlx.metallib beside it
#   LLAMA_DIR=/path/to/llama-bNNNN     # prebuilt llama.cpp release dir
#   MLX_MODEL=/path/to/mlx/snapshot    # local MLX snapshot of the catalog model
#   GGUFS="/path/a-Q4_K_M.gguf ..."    # one or more GGUF quants of the same model
#   TEXT=/path/to/wiki.test.raw        # perplexity text (wikitext-2-raw test)
#   OUT=/path/to/results-dir
#   bash bench-1690-loopback-vs-native.sh
set -euo pipefail

: "${CLI:?}" "${LLAMA_DIR:?}" "${MLX_MODEL:?}" "${GGUFS:?}" "${TEXT:?}" "${OUT:?}"
PORT="${PORT:-8191}"
PROMPT_TOKENS="${PROMPT_TOKENS:-1024}"
DECODE_TOKENS="${DECODE_TOKENS:-256}"
RUNS="${RUNS:-5}"
CONCURRENCY="${CONCURRENCY:-1 4 8}"
PPL_CTX="${PPL_CTX:-512}"
PPL_CHUNKS="${PPL_CHUNKS:-}"

provider_control() {
  python3 - "$PAUSE_PROVIDER_SOCKET" "$1" <<'PY'
import json, socket, sys
path, frame = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(300)
s.connect(path)
s.sendall((json.dumps({"type": frame}) + "\n").encode())
buf = b""
while b"\n" not in buf:
    chunk = s.recv(4096)
    if not chunk:
        break
    buf += chunk
ack = json.loads(buf.split(b"\n", 1)[0] or b"{}")
print(json.dumps(ack))
sys.exit(0 if ack.get("accepted") is True else 1)
PY
}

# Prints paused, running, or unknown (status endpoint unreachable/garbled).
provider_pause_state() {
  local body
  body=$(curl -fsS --max-time 5 "http://127.0.0.1:$1/v1/status" 2>/dev/null) || { echo unknown; return 0; }
  printf '%s' "$body" | python3 -c 'import json,sys
try:
    l = json.load(sys.stdin).get("lifecycle") or {}
except Exception:
    print("unknown")
else:
    print("paused" if l.get("operator_paused") is True else "running")' 2>/dev/null || echo unknown
}

provider_paused() {
  [[ "$(provider_pause_state "$1")" == "paused" ]]
}

# Set before the pause is sent, so every exit path after that point resumes.
pause_sent=0
server_pid=""

resume_provider() {
  local attempt
  for attempt in $(seq 1 "${RESUME_ATTEMPTS:-10}"); do
    # A refused resume is fine when the provider was never paused; only a
    # status that positively reads running counts as resumed.
    provider_control resume_request >&2 || true
    if [[ "$(provider_pause_state "$PAUSE_PROVIDER_PORT")" == "running" ]]; then
      echo "bench-1690: provider on port $PAUSE_PROVIDER_PORT resumed" >&2
      return 0
    fi
    sleep "${RESUME_RETRY_SECONDS:-5}"
  done
  return 1
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if (( pause_sent == 1 )); then
    if ! resume_provider; then
      echo "bench-1690: !!! RESUME FAILED: the provider on port $PAUSE_PROVIDER_PORT may still be PAUSED." >&2
      echo "bench-1690: !!! Resume it by hand now (resume_request on $PAUSE_PROVIDER_SOCKET)." >&2
      (( status == 0 )) && status=6
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ -n "${PAUSE_PROVIDER_SOCKET:-}${PAUSE_PROVIDER_PORT:-}" && "${PAUSE_PROVIDER:-0}" != "1" ]]; then
  echo "bench-1690: PAUSE_PROVIDER_SOCKET/PAUSE_PROVIDER_PORT are set but PAUSE_PROVIDER=1 is not; refusing to pause a live provider implicitly" >&2
  exit 2
fi
if [[ "${PAUSE_PROVIDER:-0}" == "1" && "${PPL_ONLY:-0}" == "1" ]]; then
  echo "bench-1690: PPL_ONLY=1 never pauses a provider; unset PAUSE_PROVIDER" >&2
  exit 2
fi

if [[ "${PAUSE_PROVIDER:-0}" == "1" ]]; then
  : "${PAUSE_PROVIDER_SOCKET:?PAUSE_PROVIDER_SOCKET is required with PAUSE_PROVIDER=1}"
  : "${PAUSE_PROVIDER_PORT:?PAUSE_PROVIDER_PORT is required with PAUSE_PROVIDER=1}"
  echo "bench-1690: !!! PAUSING the live provider on port $PAUSE_PROVIDER_PORT (socket $PAUSE_PROVIDER_SOCKET); it is resumed on exit" >&2
  # The provider refuses a pause when in-flight work outlasts its drain
  # timeout (drain_timeout_s, default 30s); long buyer generations make that
  # common, so retry until one attempt lands in a gap. A refused attempt only
  # holds new work for one drain window, then the provider serves normally.
  pause_attempts="${PAUSE_ATTEMPTS:-10}"
  for attempt in $(seq 1 "$pause_attempts"); do
    pause_sent=1
    provider_control pause_request >&2 && break
    if (( attempt == pause_attempts )); then
      echo "bench-1690: provider refused pause $pause_attempts times; not running" >&2
      exit 4
    fi
    sleep "${PAUSE_RETRY_SECONDS:-90}"
  done
fi

# pgrep exits 1 when nothing matches, the normal case on a clean lab Mac.
serve_count=$({ pgrep -f "macprovider-cli serve" || true; } | wc -l | tr -d " ")
# Perplexity is contention-independent and never pauses a provider, so a
# live serving provider does not block PPL_ONLY runs; a stray llama-server does.
if [[ "${PPL_ONLY:-0}" == "1" ]]; then
  serve_count=0
fi
if pgrep -x llama-server >/dev/null || {
     [[ "$serve_count" -gt 0 ]] && ! {
       [[ "$serve_count" -eq 1 && -n "${PAUSE_PROVIDER_PORT:-}" ]] && provider_paused "$PAUSE_PROVIDER_PORT"
     }
   }; then
  echo "bench-1690: refusing to run: llama-server or an unpaused provider serve process is running" >&2
  pgrep -fl "macprovider-cli serve|llama-server" >&2 || true
  exit 3
fi

mkdir -p "$OUT"
max_c=0
for c in $CONCURRENCY; do (( c > max_c )) && max_c=$c; done
# Per-slot context: prompt + forced decode + headroom; llama-server splits -c
# evenly across -np slots.
slot_ctx=$(( PROMPT_TOKENS + DECODE_TOKENS + 64 ))

{
  echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host=$(hostname) chip=$(sysctl -n machdep.cpu.brand_string) mem_bytes=$(sysctl -n hw.memsize)"
  echo "os=$(sw_vers -productVersion)"
  echo "cli_sha256=$(shasum -a 256 "$CLI" | cut -c1-64)"
  echo "llama_version=$("$LLAMA_DIR/llama-server" --version 2>&1 | grep -m1 '^version')"
  echo "mlx_model=$MLX_MODEL"
  for g in $GGUFS; do echo "gguf=$(basename "$g") sha256=$(shasum -a 256 "$g" | cut -c1-64)"; done
  echo "text_sha256=$(shasum -a 256 "$TEXT" | cut -c1-64)"
  echo "paused_provider_port=${PAUSE_PROVIDER_PORT:-none}"
  echo "prompt_tokens=$PROMPT_TOKENS decode_tokens=$DECODE_TOKENS runs=$RUNS concurrency=$CONCURRENCY ppl_ctx=$PPL_CTX"
} > "$OUT/env.txt"

if [[ "${PPL_ONLY:-0}" == "1" ]]; then
  for g in $GGUFS; do
    tag=$(basename "$g" .gguf)
    chunk_args=()
    [[ -n "$PPL_CHUNKS" ]] && chunk_args=(--chunks "$PPL_CHUNKS")
    "$LLAMA_DIR/llama-perplexity" -m "$g" -f "$TEXT" -c "$PPL_CTX" -ngl 999 ${chunk_args[@]+"${chunk_args[@]}"} \
      > "$OUT/ppl-$tag.log" 2>&1
  done
  native_chunk_args=()
  [[ -n "$PPL_CHUNKS" ]] && native_chunk_args=(--max-chunks "$PPL_CHUNKS")
  "$CLI" msb-perplexity --model "$MLX_MODEL" --text-file "$TEXT" --ctx "$PPL_CTX" \
    ${native_chunk_args[@]+"${native_chunk_args[@]}"} --output "$OUT/ppl-native.json" > /dev/null 2> "$OUT/ppl-native.err"
  echo "bench-1690: perplexity-only run done; results in $OUT" >&2
  exit 0
fi

# Native: msb-throughput reports production serial (the c=1 native number and
# the serial-serve rate at any concurrency) plus contiguous batched aggregate
# for rows=c. The issue compares llama-server against the better of the two.
for c in $CONCURRENCY; do
  (( c < 2 )) && rows=2 || rows=$c
  "$CLI" msb-throughput --model "$MLX_MODEL" --engine contiguous --rows "$rows" \
    --prompt-tokens "$PROMPT_TOKENS" --decode-tokens "$DECODE_TOKENS" --runs "$RUNS" \
    --output "$OUT/native-rows$rows.json" 2> "$OUT/native-rows$rows.err"
done

# --load-mode none (no mmap) keeps the weights in anonymous memory so the
# server's phys footprint is comparable to native (mmapped file pages are not
# counted). Older llama.cpp builds spelled this --no-mmap.
for g in $GGUFS; do
  tag=$(basename "$g" .gguf)
  "$LLAMA_DIR/llama-server" -m "$g" --host 127.0.0.1 --port "$PORT" \
    -np "$max_c" -c $(( slot_ctx * max_c )) -ngl 999 -fa on --load-mode none --no-webui \
    > "$OUT/llama-server-$tag.log" 2>&1 &
  server_pid=$!
  healthy=0
  for _ in $(seq 1 300); do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      echo "bench-1690: llama-server exited during startup; see llama-server-$tag.log" >&2
      exit 5
    fi
    curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && { healthy=1; break; }
    sleep 1
  done
  if (( healthy == 0 )); then
    echo "bench-1690: llama-server not healthy after 300s" >&2
    exit 5
  fi
  # shellcheck disable=SC2086
  "$CLI" msb-loopback --endpoint "http://127.0.0.1:$PORT" --server-pid "$server_pid" \
    --concurrency $CONCURRENCY --prompt-tokens "$PROMPT_TOKENS" --decode-tokens "$DECODE_TOKENS" \
    --runs "$RUNS" --label "$tag" --output "$OUT/loopback-$tag.json" 2> "$OUT/loopback-$tag.err"
  kill "$server_pid"
  wait "$server_pid" 2>/dev/null || true
  server_pid=""

  chunk_args=()
  [[ -n "$PPL_CHUNKS" ]] && chunk_args=(--chunks "$PPL_CHUNKS")
  "$LLAMA_DIR/llama-perplexity" -m "$g" -f "$TEXT" -c "$PPL_CTX" -ngl 999 ${chunk_args[@]+"${chunk_args[@]}"} \
    > "$OUT/ppl-$tag.log" 2>&1
done

native_chunk_args=()
[[ -n "$PPL_CHUNKS" ]] && native_chunk_args=(--max-chunks "$PPL_CHUNKS")
"$CLI" msb-perplexity --model "$MLX_MODEL" --text-file "$TEXT" --ctx "$PPL_CTX" \
  ${native_chunk_args[@]+"${native_chunk_args[@]}"} --output "$OUT/ppl-native.json" > /dev/null 2> "$OUT/ppl-native.err"

echo "bench-1690: done; results in $OUT" >&2
