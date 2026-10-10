#!/bin/bash
# Start one lab serve, wait for HTTP, capture the startup probe lines and
# /v1/status, stop it. usage: probe.sh <name> <port> [VAR=value ...]
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=<studio-home>/lab-hw; N=$1; PORT=$2; shift 2; O=$L/runs/probes/$N; rm -rf $O; mkdir -p $O
echo "binary_sha256 $(shasum -a 256 ${BIN:-$L/serve/phase3-binary/.build/release/macprovider-cli} | cut -d' ' -f1) cfg=${CFG:-a3b} env=$*" > $O/header.txt
P=$($L/lab-serve.sh $O $PORT "$@"); echo $P > $O/pid
for i in $(seq 1 240); do curl -sf http://127.0.0.1:$PORT/v1/models >/dev/null 2>&1 && break; kill -0 $P 2>/dev/null || { echo DIED; break; }; sleep 5; done
curl -s http://127.0.0.1:$PORT/v1/status > $O/status.json
echo "== $N ready_after=$((i*5))s"
grep -E "\[paged-kv\] (parity|batched-isolation|measure|runtime-identity|moe-isolation)|paged_kv_attach" $O/serve-$PORT.log | cut -c1-600
python3 -c "import json;d=json.load(open('$O/status.json'))['continuous_batching'];print('status: active=%s paged=%s unsupported=%s proof=%s slots=%s'%(d['active'],d['paged_kv_decision'],d['unsupported_reason'],d['policy']['local_proof_result'],d['scheduler']['slots_total']))"
kill $P; for _ in $(seq 1 30); do kill -0 $P 2>/dev/null || break; sleep 1; done; kill -9 $P 2>/dev/null
