#!/bin/bash
# M4 step-1 rig: loopback coordinator + Qwen3.6 rig provider (branch build).
# Live :8080 untouched. Isolated provider id, credentials and HOME.
set -uo pipefail
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
RIG=/Users/a1/lab-ac25-m2/rig; P=$RIG/prov36; OUT=/Users/a1/lab-cb-sampling/m4; mkdir -p $P $OUT
for port in 19080 19081 18090; do lsof -nP -iTCP:$port -sTCP:LISTEN -t >/dev/null 2>&1 && { echo "port $port busy"; exit 3; }; done
cp -R $RIG/prov/catalog-release $RIG/prov/compatibility-set-local $RIG/prov/compatibility-set.json $P/ 2>/dev/null
rm -f $P/macprovider-cli; cp /Users/a1/macprovider-cb-sampling/phase3-binary/.build/release/macprovider-cli $P/
cp /Users/a1/lab-ac25-m2/mlx.metallib $P/mlx.metallib
MSHA=$(shasum -a 256 $P/mlx.metallib | cut -d' ' -f1)
/usr/bin/python3 - "$P/config.yaml" "$MSHA" <<'PY'
import os, re, sys
q = open("/Users/a1/lab-ac25-m2/q36/config.yaml").read()
keep = [l for l in q.splitlines() if l.startswith(("model", "model_artifact", "model_catalog"))]
cfg = "\n".join(keep) + f"""
coordinator_url: "ws://127.0.0.1:19081/ws/provider"
provider_id: "ac25-rig-provider"
port: 18090
max_concurrency_override: 4
continuous_batch_queue_limit: 8
max_context_override: 32768
mlx_cache_limit_mb: 2048
enable_receipts: true
credential_store: protected_file
continuous_batching: canary
continuous_batching_cached_turns: {os.environ.get("CACHED_TURNS", "false")}
paged_kv:
  enabled: true
continuous_batching_accepted_tuples:
  - model_id: qwen/qwen3.6-27b
    model_sha256: 518ef47c298783d8547b50406e84548e5bf7705b82355a38f9eaef1368817931
    cache_class: mixed
    kv_dtype: fp16
    requires_moe: false
    hardware_class: "apple-silicon:Apple M3 Ultra:ram-256gb"
    metallib_sha256: {sys.argv[2]}
    kernel_identifier: macprovider_paged_kv_gather_v1
"""
open(sys.argv[1], "w").write(cfg)
PY
cd $RIG && (nohup ./coordinator --config $RIG/coordinator.yaml > $OUT/coord.out.log 2> $OUT/coord.err.log < /dev/null &)
for i in $(seq 1 30); do lsof -nP -iTCP:19080 -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 1; done
cd $P && (HOME=$RIG/home MACPROVIDER_PROTECTED_CREDENTIAL_ROOT=$RIG/creds nohup /usr/bin/python3 $RIG/ptyrun.py $OUT/prov.tty.log ./macprovider-cli serve --config $P/config.yaml --isolate-lifecycle > /dev/null 2>&1 < /dev/null &)
for i in $(seq 1 120); do grep -q "measure OK\|measure nil" $OUT/prov.tty.log 2>/dev/null && break; sleep 5; done
sleep 20
grep -aE "\[paged-kv\] (measure|runtime-identity)|lab_loopback|error|ERROR" $OUT/prov.tty.log | tail -5
curl -s --max-time 5 http://127.0.0.1:18090/v1/status | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); print('coord', d.get('coordinator',{}).get('connected'), d.get('network_state'), 'cb', (d.get('continuous_batching') or {}).get('active'))"
