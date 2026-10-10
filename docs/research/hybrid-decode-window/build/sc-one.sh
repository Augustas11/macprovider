#!/bin/bash
# One model: lab serve of the #1953 build (no join, no autotune-candidate, so
# the FR-CB10 self-check runs), wait for its decision (cap $3 s), capture the
# probe and self-check lines and /v1/status, stop it.
# usage: sc-one.sh <name> <port> <cap-seconds>   (CFG selects the config)
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=<studio-home>/lab-hw; N=$1; PORT=$2; CAP=$3; O=$L/runs/sc/$N; rm -rf $O; mkdir -p $O
BIN=$L/sc/phase3-binary/.build/release/macprovider-cli
echo "binary_sha256 $(shasum -a 256 $BIN | cut -d" " -f1) source=$(cat $L/sc-commit.txt) cfg=$(basename $CFG) started=$(date -u +%FT%TZ)" > $O/header.txt
P=$(BIN=$BIN $L/lab-serve-noat.sh $O $PORT)
end=$(( $(date +%s) + CAP ))
while [ $(date +%s) -lt $end ]; do
  grep -q "event=cb_self_check action=applied\|event=cb_self_check action=kept_prior" $O/serve-$PORT.log 2>/dev/null && break
  kill -0 $P 2>/dev/null || { echo DIED; break; }
  sleep 5
done
curl -s --max-time 5 http://127.0.0.1:$PORT/v1/status > $O/status.json
echo "== $N ended=$(date -u +%T)"
grep -E "served_slots|event=cb_self_check|\[paged-kv\] (parity|batched-isolation model.*proven)" $O/serve-$PORT.log | cut -c1-400
/usr/bin/python3 -c "import json;d=json.load(open(\"$O/status.json\"))[\"continuous_batching\"];print(\"status: active=%s paged=%s proof=%s slots=%s self_check=%s\"%(d[\"active\"],d[\"paged_kv_decision\"],d[\"policy\"][\"local_proof_result\"],d[\"scheduler\"][\"slots_total\"],json.dumps(d.get(\"self_check\"))))" 2>&1 | cut -c1-600
kill $P; for _ in $(seq 1 30); do kill -0 $P 2>/dev/null || break; sleep 1; done; kill -9 $P 2>/dev/null
