#!/usr/bin/env bash
# #1690 benchmark: llama.cpp llama-server vs native MLX on one catalog key.
# Runs on a DRAINED lab Mac only. It refuses to start while any
# macprovider-cli serve process or another llama-server is running, because
# contention invalidates the numbers and must never degrade a live provider.
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

if pgrep -f "macprovider-cli serve" >/dev/null || pgrep -x llama-server >/dev/null; then
  echo "bench-1690: refusing to run: a provider serve process or llama-server is running" >&2
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
  echo "prompt_tokens=$PROMPT_TOKENS decode_tokens=$DECODE_TOKENS runs=$RUNS concurrency=$CONCURRENCY ppl_ctx=$PPL_CTX"
} > "$OUT/env.txt"

# Native: msb-throughput reports production serial (the c=1 native number and
# the serial-serve rate at any concurrency) plus contiguous batched aggregate
# for rows=c. The issue compares llama-server against the better of the two.
for c in $CONCURRENCY; do
  (( c < 2 )) && rows=2 || rows=$c
  "$CLI" msb-throughput --model "$MLX_MODEL" --engine contiguous --rows "$rows" \
    --prompt-tokens "$PROMPT_TOKENS" --decode-tokens "$DECODE_TOKENS" --runs "$RUNS" \
    --output "$OUT/native-rows$rows.json" 2> "$OUT/native-rows$rows.err"
done

# --no-mmap keeps the weights in anonymous memory so the server's phys
# footprint is comparable to native (mmapped file pages are not counted).
for g in $GGUFS; do
  tag=$(basename "$g" .gguf)
  "$LLAMA_DIR/llama-server" -m "$g" --host 127.0.0.1 --port "$PORT" \
    -np "$max_c" -c $(( slot_ctx * max_c )) -ngl 999 -fa on --no-mmap --no-webui \
    > "$OUT/llama-server-$tag.log" 2>&1 &
  server_pid=$!
  trap 'kill "$server_pid" 2>/dev/null || true' EXIT
  for _ in $(seq 1 300); do
    curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && break
    sleep 1
  done
  # shellcheck disable=SC2086
  "$CLI" msb-loopback --endpoint "http://127.0.0.1:$PORT" --server-pid "$server_pid" \
    --concurrency $CONCURRENCY --prompt-tokens "$PROMPT_TOKENS" --decode-tokens "$DECODE_TOKENS" \
    --runs "$RUNS" --label "$tag" --output "$OUT/loopback-$tag.json" 2> "$OUT/loopback-$tag.err"
  kill "$server_pid"
  wait "$server_pid" 2>/dev/null || true
  trap - EXIT

  chunk_args=()
  [[ -n "$PPL_CHUNKS" ]] && chunk_args=(--chunks "$PPL_CHUNKS")
  "$LLAMA_DIR/llama-perplexity" -m "$g" -f "$TEXT" -c "$PPL_CTX" -ngl 999 "${chunk_args[@]}" \
    > "$OUT/ppl-$tag.log" 2>&1
done

native_chunk_args=()
[[ -n "$PPL_CHUNKS" ]] && native_chunk_args=(--max-chunks "$PPL_CHUNKS")
"$CLI" msb-perplexity --model "$MLX_MODEL" --text-file "$TEXT" --ctx "$PPL_CTX" \
  "${native_chunk_args[@]}" --output "$OUT/ppl-native.json" > /dev/null 2> "$OUT/ppl-native.err"

echo "bench-1690: done; results in $OUT" >&2
