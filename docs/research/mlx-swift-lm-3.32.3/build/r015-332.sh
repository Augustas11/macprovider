#!/bin/bash
# SPEC-048 R015 on the mlx-swift-lm 3.32.3 lab-harness build. In-process, no ports, no join.
# Run under bench.sh (live paused and drained). Mirrors the 2026-10-06 quiet run's phases.
set -uo pipefail
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=<studio-home>/lab-332; R=$L/runs2/step3-r015; mkdir -p $R; S=$R/status.txt
B=$L/src/phase3-binary/.build/release/macprovider-cli
FIX=$L/fixture/q36-a3b-cat; P=$L/r015-policy.json; PC=531ce132afb8410f5d7a18469045de40b0d27cbd
OUT=$R/r015-a3b-332.jsonl
( while true; do echo "$(date -u +%FT%TZ) out_lines=$(wc -l < $OUT 2>/dev/null || echo 0) gpu=$(ioreg -r -c IOAccelerator -d 1 2>/dev/null | grep -o '"Device Utilization %"=[0-9]*' | head -1 | cut -d= -f2) other=$(ps -axo %cpu,command | grep -E 'llama-server|ollama|mlx_lm|omlx' | grep -v grep | awk '{s+=$1} END {print s+0}')"; sleep 10; done ) > $R/contamination.log 2>&1 &
SP=$!; trap 'kill $SP 2>/dev/null' EXIT
echo "started_at=$(date -u +%FT%TZ) policy_sha256=$(shasum -a 256 $P | cut -d' ' -f1) binary_sha256=$(shasum -a 256 $B | cut -d' ' -f1) metallib_sha256=$(shasum -a 256 $(dirname $B)/mlx.metallib | cut -d' ' -f1) provider_commit=$PC" >> $S
MACPROVIDER_NATIVE_MTP_E2E=1 MACPROVIDER_NATIVE_MTP_E2E_SERVE_PATH=1 $B native-mtp-hardware-e2e --root $FIX --model-id qwen/qwen3.6-35b-a3b --max-batch 2 --sizing-prompt-tokens 1024 --sizing-output-tokens 256 > $R/hardware-e2e.log 2>&1
echo "phase=hardware_e2e exit_code=$? at=$(date -u +%FT%TZ)" >> $S
MACPROVIDER_NATIVE_MTP_E2E=1 $B native-mtp-bench --root $FIX --model-id qwen/qwen3.6-35b-a3b --policy $P --out $OUT --phase matrix --provider-commit $PC > $R/bench-matrix.log 2>&1
echo "phase=matrix exit_code=$? lines=$(wc -l < $OUT) at=$(date -u +%FT%TZ)" >> $S
MACPROVIDER_NATIVE_MTP_E2E=1 $B native-mtp-bench --root $FIX --model-id qwen/qwen3.6-35b-a3b --policy $P --out $OUT --phase sustained --provider-commit $PC > $R/bench-sustained.log 2>&1
echo "phase=sustained exit_code=$? lines=$(wc -l < $OUT) jsonl_sha256=$(shasum -a 256 $OUT | cut -d' ' -f1) at=$(date -u +%FT%TZ)" >> $S
echo R015_DONE >> $S
