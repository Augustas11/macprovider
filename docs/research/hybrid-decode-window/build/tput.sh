#!/bin/bash
# Hybrid decode window 16 vs 1 throughput on the served A3B, isolated loopback
# serve of the lab-harness build (window 1 via the lab-only override), the
# #1906 runtime-compare method: depth_sweep.py, depths 1/8/16, prompt-heavy
# 1536/256 and output-heavy 1800/1024, 30 s warmup, 90 s window. Run under
# bench.sh. sampler.sh records live requests_in_flight and other heavy
# processes every 2 s. Before each cell the run waits for 20 s of quiet; a
# cell with any live request in flight or any other process at >= 5% CPU in
# its span is contaminated and rerun (up to 3 attempts); only CLEAN cells count.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=<studio-home>/lab-hw; OUT=$1; PORT=18193; MODEL=qwen/qwen3.6-35b-a3b
SWEEP=<studio-home>/macprovider-hybrid-window/scripts/lab/cb-studio/depth_sweep.py
BIN=$L/lab/phase3-binary/.build/release/macprovider-cli
mkdir -p "$OUT"
echo "binary_sha256 $(shasum -a 256 $BIN | cut -d' ' -f1) source=$(cat $L/source-commit.txt) started=$(date -u +%FT%TZ)" | tee "$OUT/header.txt"
$L/sampler.sh > "$OUT/samples.log" 2>&1 &
SAMPLER=$!
SP=
cleanup() { kill $SAMPLER 2>/dev/null; [ -n "$SP" ] && { kill $SP 2>/dev/null; sleep 5; kill -9 $SP 2>/dev/null; }; }
trap cleanup EXIT
verdict() { # start end -> CLEAN|CONTAMINATED with counts
  /usr/bin/python3 - "$OUT/samples.log" "$1" "$2" <<'PY'
import sys
path, s, e = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
rows = []
for line in open(path):
    p = line.split()
    if len(p) >= 3 and p[0].isdigit() and s <= int(p[0]) <= e:
        rows.append((int(p[1]), int(p[2]), p[3] if len(p) > 3 else "-"))
live = sum(1 for r in rows if r[0] != 0)
other = sum(1 for r in rows if r[1] >= 5)
ok = rows and live == 0 and other == 0
print(f"{'CLEAN' if ok else 'CONTAMINATED'} samples={len(rows)} live_nonzero={live} other_busy={other} other_max_cpu={max([r[1] for r in rows] or [0])}")
PY
}
wait_quiet() {
  for _ in $(seq 1 300); do
    q=$(tail -10 "$OUT/samples.log" | awk '$2 != 0 || $3 >= 5 {b=1} END {print b+0}')
    [ "$q" = 0 ] && [ $(wc -l < "$OUT/samples.log") -ge 10 ] && return 0
    sleep 2
  done
  return 1
}
for arm in w16 w1; do
  if [ $arm = w1 ]; then ENVW="MACPROVIDER_LAB_HYBRID_DECODE_WINDOW=1"; else ENVW="HW_ARM=w16"; fi
  SP=$(BIN=$BIN $L/lab-serve.sh "$OUT/serve-$arm" $PORT $ENVW)
  for _ in $(seq 1 240); do curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && break; sleep 2; done
  echo "arm $arm ready $(date -u +%T) $(curl -s http://127.0.0.1:$PORT/v1/status | /usr/bin/python3 -c "import sys,json;d=json.load(sys.stdin)['continuous_batching'];print('cb_active=%s paged=%s slots=%s'%(d['active'],d['paged_kv_decision'],d['scheduler']['slots_total']))")"
  curl -s --max-time 300 "http://127.0.0.1:$PORT/v1/chat/completions" -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"warm up\"}],\"max_tokens\":16}" >/dev/null
  for shape in "1536 256 prompt-heavy" "1800 1024 output-heavy"; do
    set -- $shape
    for depth in 1 8 16; do
      for attempt in 1 2 3; do
        wait_quiet || echo "no quiet period before $arm $3 $depth attempt $attempt"
        s=$(date +%s)
        /usr/bin/python3 $SWEEP --port $PORT --model $MODEL --depths $depth --prompt-tokens $1 --max-tokens $2 \
          --window 90 --warmup 30 --label "$arm/$3/attempt$attempt" --out "$OUT/sweep.jsonl"
        e=$(date +%s); v=$(verdict $s $e)
        echo "$arm $3 $depth $attempt $s $e $v" | tee -a "$OUT/cells.txt"
        case $v in CLEAN*) break ;; esac
      done
    done
  done
  kill $SP; for _ in $(seq 1 30); do kill -0 $SP 2>/dev/null || break; sleep 1; done; kill -9 $SP 2>/dev/null; SP=
done
echo "TPUT_DONE $(date -u +%T)"
