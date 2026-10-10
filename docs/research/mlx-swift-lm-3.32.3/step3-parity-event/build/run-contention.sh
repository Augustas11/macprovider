#!/bin/bash
# Lab-only reproducer: two concurrent formal-binary native-mtp-bench processes (GPU contention).
# Usage: run-contention.sh <tag> [env...]
set -uo pipefail
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=<studio-home>/lab-332; RP=$L/repro; TAG=$1; shift
R=$RP/runs/$TAG; rm -rf $R; mkdir -p $R
B=$L/src/phase3-binary/.build/release/macprovider-cli
PC=d07d0cf092b1b7c43e4c03dd8973db5f254c4409
echo "start $(date -u +%FT%TZ) tag=$TAG bin=$(shasum -a 256 $B | cut -c1-16) env=$*" > $R/run.log
( while true; do echo "$(date -u +%FT%TZ) a=$(wc -l < $R/a.jsonl 2>/dev/null || echo 0) b=$(wc -l < $R/b.jsonl 2>/dev/null || echo 0) other=$(ps -axo %cpu,command | grep -E "llama-server|ollama|mlx_lm|omlx" | grep -v grep | awk "{s+=\$1} END {print s+0}")"; sleep 10; done ) > $R/contamination.log 2>&1 &
SP=$!; trap "kill $SP 2>/dev/null" EXIT
env "$@" MACPROVIDER_NATIVE_MTP_E2E=1 $B native-mtp-bench --root $L/fixture/q36-a3b-cat --model-id qwen/qwen3.6-35b-a3b --policy $RP/rp-p4096-b40.json --out $R/a.jsonl --phase matrix --provider-commit $PC > $R/a.log 2>&1 &
PA=$!
sleep 20
env "$@" MACPROVIDER_NATIVE_MTP_E2E=1 $B native-mtp-bench --root $L/fixture/q36-a3b-cat --model-id qwen/qwen3.6-35b-a3b --policy $RP/rp-p1536-b40.json --out $R/b.jsonl --phase matrix --provider-commit $PC > $R/b.log 2>&1 &
PB=$!
wait $PA; EA=$?; wait $PB; EB=$?
echo "exit a=$EA b=$EB end $(date -u +%FT%TZ)" | tee -a $R/run.log
