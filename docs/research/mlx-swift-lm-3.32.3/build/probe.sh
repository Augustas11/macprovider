#!/bin/bash
# Start one lab serve, wait for HTTP, capture probe lines and /v1/status, stop it.
# usage: probe.sh <name> <port> [VAR=value ...]   (CFG env selects config)
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=<studio-home>/lab-332; N=$1; PORT=$2; shift 2; O=$L/runs2/$N; rm -rf $O; mkdir -p $O
P=$($L/lab-serve.sh $O $PORT "$@"); echo $P > $O/pid
for i in $(seq 1 180); do curl -sf http://127.0.0.1:$PORT/v1/models >/dev/null 2>&1 && break; kill -0 $P 2>/dev/null || { echo DIED; break; }; sleep 5; done
curl -s http://127.0.0.1:$PORT/v1/status > $O/status.json
echo "== $N ready_after=$((i*5))s"
grep -E "\[paged-kv\] (parity|batched-isolation|measure|runtime-identity)|paged_kv_attach" $O/serve-$PORT.log
python3 -c "import json;d=json.load(open('$O/status.json'))['continuous_batching'];print('status: active=%s paged=%s unsupported=%s proof=%s slots=%s'%(d['active'],d['paged_kv_decision'],d['unsupported_reason'],d['policy']['local_proof_result'],d['scheduler']['slots_total']))"
[ "${KEEP:-0}" = 1 ] || { kill $P; sleep 6; }
