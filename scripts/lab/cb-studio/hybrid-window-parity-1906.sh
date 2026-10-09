#!/bin/bash
# Issue #1906: greedy parity of hybrid decode window 16 vs 1. Window 1 runs
# twice to measure the natural run-to-run divergence. Correctness only; does
# not need live paused.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=/Users/a1/lab-1906
B=/Users/a1/macprovider-1906-cb-depth/phase3-binary/.build-lab/release/macprovider-cli
OUT=$1; PORT=18091
mkdir -p "$OUT"
SP=
trap 'kill $SP 2>/dev/null; sleep 5; kill -9 $SP 2>/dev/null' EXIT
for run in w1a w1b w16; do
  w=${run#w}; w=${w%[ab]}
  sed "s/^port: .*/port: $PORT/" "$LAB/cfg/config.yaml" > "$OUT/cfg.yaml"
  MACPROVIDER_LAB_HYBRID_DECODE_WINDOW=$w "$B" serve --config "$OUT/cfg.yaml" --port $PORT --no-join \
    --autotune-candidate --no-idle-prewarm > "$OUT/serve-$run.log" 2>&1 &
  SP=$!
  for _ in $(seq 1 180); do curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && break; sleep 2; done
  /usr/bin/python3 "$LAB/hybrid_window_parity.py" $PORT "$OUT/$run.json" 16
  kill $SP; for _ in $(seq 1 30); do kill -0 $SP 2>/dev/null || break; sleep 1; done; kill -9 $SP 2>/dev/null; SP=
done
python3 - "$OUT" <<'PY'
import json,sys,os
d=sys.argv[1]; L=lambda n: json.load(open(os.path.join(d,n+".json")))
def cmp(a,b):
    exact=0; first=[]
    for k in a:
        ta=(a[k]["reasoning"] or "")+(a[k]["content"] or ""); tb=(b[k]["reasoning"] or "")+(b[k]["content"] or "")
        if ta==tb: exact+=1
        else: first.append(next((i for i,(x,y) in enumerate(zip(ta,tb)) if x!=y), min(len(ta),len(tb))))
    return exact,len(a),sorted(first)
w1a,w1b,w16=L("w1a"),L("w1b"),L("w16")
print("w1a vs w1b exact=%d/%d first_divergence_chars=%s"%cmp(w1a,w1b))
print("w16 vs w1a exact=%d/%d first_divergence_chars=%s"%cmp(w16,w1a))
print("w16 vs w1b exact=%d/%d first_divergence_chars=%s"%cmp(w16,w1b))
PY
echo PARITY_DONE
