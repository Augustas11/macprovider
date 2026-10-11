#!/bin/bash
# Decode-isolation throughput on an isolated lab serve, #1906/#1953 method:
# depth_sweep.py output-heavy 1800/1024, warmup 20 s, window 60 s, one depth per
# cell. sampler.sh (started by the window driver) logs live requests_in_flight
# and other inference CPU every 2 s; a cell with any nonzero/unreadable live
# count or other process >= 5% CPU is CONTAMINATED and rerun (2 attempts).
# usage: tput.sh <out> <arm> <tree> <cfg> <depths> [VAR=value ...]
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=<studio-home>/lab-di; OUT=$1; ARM=$2; T=$3; C=$4; DEPTHS=$5; shift 5; PORT=18199
MODEL=$([ "$C" = q27b ] && echo qwen/qwen3.6-27b || echo qwen/qwen3.6-35b-a3b)
SAMPLES=$OUT/samples.log; O=$OUT/$ARM; mkdir -p $O
verdict() { /usr/bin/python3 - "$SAMPLES" "$1" "$2" <<'PY'
import sys
path, s, e = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
rows = []
for line in open(path):
    p = line.split()
    if len(p) >= 3 and p[0].isdigit() and s <= int(p[0]) <= e:
        rows.append((int(p[1]), int(p[2])))
live = sum(1 for r in rows if r[0] != 0)
other = sum(1 for r in rows if r[1] >= 5)
ok = rows and live == 0 and other == 0
print(f"{'CLEAN' if ok else 'CONTAMINATED'} samples={len(rows)} live_nonzero={live} other_busy={other} live_max={max([r[0] for r in rows] or [0])}")
PY
}
wait_quiet() { for _ in $(seq 1 150); do q=$(tail -8 "$SAMPLES" | awk '$2 != 0 || $3 >= 5 {b=1} END {print b+0}'); [ "$q" = 0 ] && return 0; sleep 2; done; return 1; }
SP=$($L/serve.sh $O $PORT $T $C "$@")
trap 'kill $SP 2>/dev/null; for _ in $(seq 1 30); do kill -0 $SP 2>/dev/null || break; sleep 1; done; kill -9 $SP 2>/dev/null' EXIT
for _ in $(seq 1 240); do curl -sf http://127.0.0.1:$PORT/v1/models >/dev/null 2>&1 && break; sleep 2; done
echo "arm $ARM ready $(date -u +%T) binary=$(shasum -a 256 $L/src-$T/.build/release/macprovider-cli | cut -c1-16) env=$* $(curl -s http://127.0.0.1:$PORT/v1/status | /usr/bin/python3 -c "import sys,json;d=json.load(sys.stdin)['continuous_batching'];print('cb_active=%s paged=%s slots=%s'%(d['active'],d['paged_kv_decision'],d['scheduler']['slots_total']))")" | tee -a $OUT/arms.txt
grep -hE "continuous_batch_decode_row_bound|served_slots|batched-isolation.*proven" $O/serve.log | cut -c1-200 | tee -a $OUT/arms.txt
curl -s --max-time 300 http://127.0.0.1:$PORT/v1/chat/completions -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"warm up\"}],\"max_tokens\":16}" >/dev/null
for d in $(echo $DEPTHS | tr , ' '); do
  for attempt in 1 2; do
    wait_quiet || echo "no quiet period before $ARM $d attempt $attempt"
    s=$(date +%s)
    set -- ${SHAPE:-1800 1024 60 20}
    /usr/bin/python3 ${SWEEP:-<studio-home>/lab-1906/depth_sweep.py} --port $PORT --model $MODEL --depths $d --prompt-tokens $1 \
      --max-tokens $2 --window $3 --warmup $4 --label "$ARM/d$d/a$attempt" --out $OUT/sweep.jsonl > /dev/null 2>&1
    e=$(date +%s); v=$(verdict $s $e)
    echo "$ARM $d $attempt $s $e $v" | tee -a $OUT/cells.txt
    case $v in CLEAN*) break ;; esac
  done
done
curl -s http://127.0.0.1:$PORT/v1/status | /usr/bin/python3 -c "import sys,json;print(json.dumps(json.load(sys.stdin)['continuous_batching'].get('self_check')))" > $O/self_check.json
