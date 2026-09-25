#!/bin/bash
# Lab round for SPEC-038 AC-6b (sampled batched rows) on the Studio.
# One isolated --no-join serve on :18080 next to the live :8080 provider,
# context capped at 32768, MLX cache capped at 2 GB. Stops the serve at the end.
set -uo pipefail
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=/Users/a1/lab-cb-sampling; OUT=$LAB/out; BIN=$LAB/bin
SRC=/Users/a1/macprovider-cb-sampling/phase3-binary/.build/release/macprovider-cli
mkdir -p $BIN $OUT
if lsof -nP -iTCP:18080 -sTCP:LISTEN -t >/dev/null 2>&1; then echo "port 18080 busy"; exit 3; fi
rm -f $BIN/macprovider-cli $BIN/mlx.metallib
cp $SRC $BIN/macprovider-cli
cp /Users/a1/lab-ac25-m2/mlx.metallib $BIN/mlx.metallib
MSHA=$(shasum -a 256 $BIN/mlx.metallib | cut -d' ' -f1)
/usr/bin/python3 - "$BIN/config.yaml" "$MSHA" <<'PY'
import re, sys
src = open("/Users/a1/lab-ac25-m2/q36/config.yaml").read()
src = re.sub(r"^port: .*$", "port: 18080", src, flags=re.M)
src = re.sub(r"^max_context_override: .*$", "max_context_override: 32768", src, flags=re.M)
src = re.sub(r"^continuous_batch_queue_wait_timeout_ms: .*\n", "", src, flags=re.M)
if "mlx_cache_limit_mb" not in src:
    src += "mlx_cache_limit_mb: 2048\n"
src = src.replace('hardware_class: "apple-silicon:Apple M3 Ultra:ram-256gb"',
                  'hardware_class: "apple-silicon:Apple M3 Ultra:ram-256gb"\n'
                  f'    metallib_sha256: {sys.argv[2]}\n'
                  '    kernel_identifier: macprovider_paged_kv_gather_v1')
open(sys.argv[1], "w").write(src)
PY
cd $BIN
(nohup ./macprovider-cli serve --config $BIN/config.yaml --no-join > $OUT/serve.out.log 2> $OUT/serve.err.log < /dev/null &)
for i in $(seq 1 120); do lsof -nP -iTCP:18080 -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 3; done
SPID=$(lsof -nP -t -iTCP:18080 -sTCP:LISTEN)
[ -n "$SPID" ] || { echo "lab serve did not start"; tail -20 $OUT/serve.err.log; exit 4; }
echo "pid=$SPID sha=$(shasum -a 256 $BIN/macprovider-cli | cut -d' ' -f1) metallib=$MSHA" > $OUT/binary.txt
( while kill -0 $SPID 2>/dev/null; do echo "$(date -u +%H:%M:%S) $(/usr/bin/footprint $SPID 2>/dev/null | grep -o 'Footprint: [0-9.]* [KMG]B')"; sleep 15; done ) > $OUT/footprint.txt &
for i in $(seq 1 60); do grep -q "measure OK\|measure nil\|batched-isolation.*proven=" $OUT/serve.err.log && break; sleep 5; done
grep -E "\[paged-kv\] (parity|batched-isolation|measure|runtime-identity)" $OUT/serve.err.log | tail -6 > $OUT/startup-probe.txt
curl -s --max-time 5 http://127.0.0.1:18080/v1/status | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); print('cb', d.get('continuous_batching'))" >> $OUT/startup-probe.txt
echo "round start $(date -u +%T)"
/usr/bin/python3 $LAB/sampling_q36.py 18080 $OUT > $OUT/stdout.json 2> $OUT/stderr.txt
grep -aE "batching_forward_failed|batching_prefill_failed" $OUT/serve.err.log | sort | uniq -c > $OUT/failures.txt
grep -ac "event=batching_admitted" $OUT/serve.err.log > $OUT/admitted.txt
kill $SPID 2>/dev/null
echo "ROUND_DONE $(date -u +%T)"
