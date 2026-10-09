#!/bin/bash
# Issue #1906: our CLI serving through the existing omlx_loopback adapter
# (SPEC-046-R009) in front of oMLX 0.7.0, same cells as the runtime comparison.
# Run under bench.sh:  bench.sh omlx-adapter-1906.sh <out-dir> [smoke]
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=/Users/a1/lab-1906; R=$LAB/runtimes; OUT=$1; MODE=${2:-full}
OPORT=18098; PORT=18097; REF=qwen3.6-35b-a3b
A=$(readlink "$R/omlx-models/$REF")
B=/Users/a1/macprovider-1906-cb-depth/phase3-binary/.build-lab/release/macprovider-cli
mkdir -p "$OUT"; OP=; SP=
trap 'kill $SP $OP 2>/dev/null; sleep 5; kill -9 $SP $OP 2>/dev/null' EXIT
"$R/venv-omlx/bin/omlx" serve --model-dir "$R/omlx-models" --port $OPORT --max-concurrent-requests 32 --no-cache \
  > "$OUT/omlx.log" 2>&1 & OP=$!
for _ in $(seq 1 120); do curl -sf "http://127.0.0.1:$OPORT/v1/models" >/dev/null 2>&1 && break; sleep 2; done
curl -s --max-time 300 "http://127.0.0.1:$OPORT/v1/chat/completions" -H "Content-Type: application/json" \
  -d "{\"model\":\"$REF\",\"messages\":[{\"role\":\"user\",\"content\":\"warm up\"}],\"max_tokens\":8}" >/dev/null
cat > "$OUT/cfg.yaml" <<YAML
port: $PORT
model: "omlx:$REF"
loopback_origin: "http://127.0.0.1:$OPORT"
max_concurrency_override: 32
credential_store: protected_file
YAML
MACPROVIDER_OMLX_MODEL_PATH="$A" "$B" serve --config "$OUT/cfg.yaml" --port $PORT --no-join --autotune-candidate \
  --no-idle-prewarm > "$OUT/serve-adapter.log" 2>&1 & SP=$!
ok=
for _ in $(seq 1 90); do curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && { ok=1; break; }; kill -0 $SP 2>/dev/null || break; sleep 2; done
[ -n "$ok" ] || { echo "ADAPTER_NOT_READY"; tail -15 "$OUT/serve-adapter.log"; exit 3; }
MODEL=$(curl -s "http://127.0.0.1:$PORT/v1/models" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])")
echo "adapter ready model=$MODEL $(date -u +%T)"
R1=$(curl -s --max-time 120 "http://127.0.0.1:$PORT/v1/chat/completions" -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello.\"}],\"max_tokens\":16}")
echo "smoke: ${R1:0:300}"
[ "$MODE" = smoke ] && exit 0
for shape in "1536 256 prompt-heavy" "1800 1024 output-heavy"; do
  set -- $shape
  /usr/bin/python3 "$LAB/depth_sweep.py" --port $PORT --model "$MODEL" --depths 1,8,16 \
    --prompt-tokens $1 --max-tokens $2 --window 90 --warmup 30 --label "ours-via-omlx/$3" --out "$OUT/sweep.jsonl"
done
echo "ADAPTER_DONE $(date -u +%T)"
