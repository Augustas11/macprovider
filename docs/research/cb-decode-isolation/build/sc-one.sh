#!/bin/bash
# FR-CB10 self-check (#1947, read-only use) on one build: lab serve without
# --autotune-candidate so the self-check runs; wait for its decision (cap $5 s);
# capture probe + self-check lines and /v1/status. usage: sc-one.sh <name> <port> <tree> <cfg> <cap> [VAR=value ...]
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=<studio-home>/lab-di; N=$1; PORT=$2; T=$3; C=$4; CAP=$5; shift 5; O=$L/runs/sc/$N; rm -rf $O; mkdir -p $O
echo "binary_sha256 $(shasum -a 256 $L/src-$T/.build/release/macprovider-cli | cut -d" " -f1) tree=$T cfg=$C env=$* started=$(date -u +%FT%TZ)" > $O/header.txt
P=$(NOAT=1 $L/serve.sh $O $PORT $T $C "$@")
end=$(( $(date +%s) + CAP ))
while [ $(date +%s) -lt $end ]; do
  grep -q "event=cb_self_check action=applied\|event=cb_self_check action=kept_prior" $O/serve.log 2>/dev/null && break
  kill -0 $P 2>/dev/null || { echo DIED; break; }
  sleep 5
done
curl -s --max-time 5 http://127.0.0.1:$PORT/v1/status > $O/status.json
echo "== $N ended=$(date -u +%T)"
grep -E "served_slots|event=cb_self_check|continuous_batch_decode_row_bound|\[paged-kv\] (parity|batched-isolation model.*proven)" $O/serve.log | cut -c1-300
kill $P; for _ in $(seq 1 30); do kill -0 $P 2>/dev/null || break; sleep 1; done; kill -9 $P 2>/dev/null
