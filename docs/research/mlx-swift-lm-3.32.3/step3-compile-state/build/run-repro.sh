#!/bin/bash
# Lab-only reload/churn reproducer. Usage: run-repro.sh <old|new> <tag> [env...]
set -uo pipefail
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=<studio-home>/lab-332; C=$L/cs; V=$1; TAG=$2; shift 2
R=$C/runs/$TAG; rm -rf $R; mkdir -p $R
B=$C/$V/phase3-binary/.build/release/macprovider-cli
PC=d07d0cf092b1b7c43e4c03dd8973db5f254c4409
echo "start $(date -u +%FT%TZ) tag=$TAG build=$V bin=$(shasum -a 256 $B | cut -c1-16) env=$*" > $R/run.log
env "$@" MLX_LAB_STALE=1 MACPROVIDER_NATIVE_MTP_E2E=1 $B native-mtp-bench --root $L/fixture/q36-a3b-cat --model-id qwen/qwen3.6-35b-a3b --policy $C/cs-reload.json --out $R/out.jsonl --phase matrix --provider-commit $PC > $R/bench.log 2>&1
echo "exit=$? end $(date -u +%FT%TZ)" >> $R/run.log
