#!/bin/bash
# Lab-only exploratory profile run. Usage: prof-run.sh <tag> <bindir> [env...]
set -uo pipefail
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=<studio-home>/lab-332; M=$L/mtp; TAG=$1; BD=$2; shift 2
R=$M/runs/$TAG; rm -rf $R; mkdir -p $R
B=$BD/macprovider-cli
[ -f $BD/mlx.metallib ] || cp -c $L/bin/mlx.metallib $BD/
echo "start $(date -u +%T) tag=$TAG bin=$(shasum -a 256 $B | cut -c1-16) env=$*" > $R/bench.log
env "$@" MACPROVIDER_LAB_PROF=1 MACPROVIDER_NATIVE_MTP_E2E=1 $B native-mtp-bench --root $L/fixture/q36-a3b-cat --model-id qwen/qwen3.6-35b-a3b --policy ${POLICY:-$M/explore.json} --out $R/out.jsonl --phase matrix --provider-commit f424aa9d6d381b24056e556b9d6386c47ce2bf10 >> $R/bench.log 2>&1
echo "exit=$? tag=$TAG end $(date -u +%T)" | tee -a $R/bench.log
