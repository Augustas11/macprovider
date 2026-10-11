#!/bin/bash
# SPEC-048 R015 on the decode-isolation lab-harness build (fork 3.32.3-macprovider.6,
# compiled verify ON). Run under bench.sh. usage: r015.sh a|b
#   a = hardware E2E + matrix, b = sustained (separate windows, same JSONL).
set -uo pipefail
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=<studio-home>/lab-di; R=$L/r015; S=$R/status.txt
B=$L/src-after/.build/release/macprovider-cli
FIX=<studio-home>/lab-332/fixture/q36-a3b-cat; P=$R/policy.json; PC=3db5fd811a2fc0e3da6044ddb28d8887272c4201
OUT=$R/r015-a3b.jsonl
( while true; do echo "$(date -u +%FT%TZ) out_lines=$(wc -l < $OUT 2>/dev/null || echo 0) live_in_flight=$(curl -s --max-time 2 http://127.0.0.1:8080/v1/status | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin).get('requests_in_flight', -1))" 2>/dev/null)"; sleep 10; done ) >> $R/contamination.log 2>&1 &
SP=$!
$L/sampler.sh >> $R/samples.log 2>&1 &
SP2=$!; trap "kill $SP $SP2 2>/dev/null" EXIT
echo "part=$1 started_at=$(date -u +%FT%TZ) policy_sha256=$(shasum -a 256 $P | cut -d" " -f1) binary_sha256=$(shasum -a 256 $B | cut -d" " -f1) metallib_sha256=$(shasum -a 256 $(dirname $B)/mlx.metallib | cut -d" " -f1) provider_commit=$PC env=MLX_LM_QWEN35_COMPILED_VERIFY=unset(on)" >> $S
if [ "$1" = a ]; then
  MACPROVIDER_NATIVE_MTP_E2E=1 MACPROVIDER_NATIVE_MTP_E2E_SERVE_PATH=1 $B native-mtp-hardware-e2e --root $FIX --model-id qwen/qwen3.6-35b-a3b --max-batch 2 --sizing-prompt-tokens 1024 --sizing-output-tokens 256 > $R/hardware-e2e.log 2>&1
  echo "phase=hardware_e2e exit_code=$? at=$(date -u +%FT%TZ)" >> $S
  MACPROVIDER_NATIVE_MTP_E2E=1 $B native-mtp-bench --root $FIX --model-id qwen/qwen3.6-35b-a3b --policy $P --out $OUT --phase matrix --provider-commit $PC > $R/bench-matrix.log 2>&1
  echo "phase=matrix exit_code=$? lines=$(wc -l < $OUT) at=$(date -u +%FT%TZ)" >> $S
else
  MACPROVIDER_NATIVE_MTP_E2E=1 $B native-mtp-bench --root $FIX --model-id qwen/qwen3.6-35b-a3b --policy $P --out $OUT --phase sustained --provider-commit $PC > $R/bench-sustained.log 2>&1
  echo "phase=sustained exit_code=$? lines=$(wc -l < $OUT) jsonl_sha256=$(shasum -a 256 $OUT | cut -d" " -f1) at=$(date -u +%FT%TZ)" >> $S
  echo R015_DONE >> $S
fi
