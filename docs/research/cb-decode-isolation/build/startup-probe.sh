#!/bin/bash
# usage: startup-probe.sh <name> <port> <tree> <cfg> [VAR=value ...]  (KEEP=1 leaves it running)
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=<studio-home>/lab-di; N=$1; PORT=$2; O=$L/runs/$N; rm -rf $O; mkdir -p $O
P=$($L/serve.sh $O $PORT $3 $4 "${@:5}"); echo $P > $O/pid
for i in $(seq 1 240); do curl -sf http://127.0.0.1:$PORT/v1/models >/dev/null 2>&1 && break; kill -0 $P 2>/dev/null || { echo DIED; break; }; sleep 5; done
echo "== $N ready_after=$((i*5))s binary=$(shasum -a 256 $L/src-$3/.build/release/macprovider-cli | cut -c1-16)"
grep -E "\[paged-kv\] (parity|batched-isolation)|paged_kv_attach|continuous_batch_decode_row_bound|continuous_batch_prefill_grouping" $O/serve.log | cut -c1-300
curl -s http://127.0.0.1:$PORT/v1/status > $O/status.json
python3 -c "import json;d=json.load(open('$O/status.json'))['continuous_batching'];print('status: active=%s paged=%s slots=%s self_check=%s'%(d.get('active'),d.get('paged_kv_decision'),d.get('scheduler',{}).get('slots_total'),json.dumps(d.get('self_check'))))"
[ "${KEEP:-0}" = 1 ] || { kill $P; sleep 8; kill -9 $P 2>/dev/null; }
