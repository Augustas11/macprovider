#!/usr/bin/env bash
# In-VM pass driver (runs detached, so a host network drop cannot kill it).
# Usage: run-passes.sh [passes] [chains] [first-pass-id]
#   chains: A (S1,S2,S4,S6) B (S3) C (S1,S2,S5). A first-pass-id above 1
#   appends to the existing evidence instead of starting it over.
# Each chain starts from a fresh bootstrap (old coordinator + old gateway).
set -uo pipefail
. /root/e2e/h/vm/lib.sh
passes="${1:-2}"; chains="${2:-ABC}"; first="${3:-1}"
bash $E2E_H/vm/10-build.sh || die "build failed"
if [ "$first" = 1 ]; then
  : >"$E2E_EVIDENCE/results.jsonl"
  rm -rf "$E2E_EVIDENCE"/p[0-9]* /root/e2e/pools
fi
step() { log "=== pass $1: $2"; PASS_ID=$1 bash $E2E_H/vm/$2; }  # $1 = <pass><chain>, e.g. 1A
for p in $(seq "$first" $((first + passes - 1))); do
  for c in $(echo "$chains" | fold -w1); do
    case $c in
      A) for s in 20-bootstrap.sh s1-baseline.sh s2-rollout.sh s4-faults.sh s6-rollback.sh; do step $p$c $s; done ;;
      B) for s in 20-bootstrap.sh s3-newgw-oldcoord.sh; do step $p$c $s; done ;;
      C) for s in 20-bootstrap.sh s1-baseline.sh s2-rollout.sh s5-pool.sh; do step $p$c $s; done ;;
    esac
    result "pass$p-chain$c" INFO "chain done"
  done
done
log "ALL-PASSES-DONE"
