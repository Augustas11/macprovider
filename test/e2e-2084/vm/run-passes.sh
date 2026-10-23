#!/usr/bin/env bash
# In-VM pass driver for #2084 (runs detached under systemd-run, so a host
# network drop cannot kill it).
# Usage: run-passes.sh [passes] [steps] [first-pass-id]
#   B1 = shared vm/20-bootstrap.sh (old/old, fresh state)
#   B2 = vm/21-bootstrap-2084.sh   U = vm/u-rollout.sh (coordinator first)
#   P  = vm/s-pool.sh (pool + group up)   F = vm/s-fake.sh (fake group scenarios)
#   Every pass starts from a fresh bootstrap; steps depend on each other in
#   chain order.
set -uo pipefail
. /root/e2e/h/vm/lib.sh
export DRAIN_MAX="${DRAIN_MAX:-660}"
passes="${1:-1}"; steps="${2:-B1 B2 U P F}"; first="${3:-1}"
bash $E2E_H/vm/10-build.sh || { log "RUN-PASSES-ABORTED: build failed"; exit 1; }
if [ "$first" = 1 ] && [ "${E2E_KEEP_EVIDENCE:-0}" != 1 ]; then
  : >"$E2E_EVIDENCE/results.jsonl"
  rm -rf "$E2E_EVIDENCE"/p[0-9]*
fi
step() { log "=== pass $1: $2"; PASS_ID=$1 bash "$2"; local rc=$?; [ $rc = 0 ] || log "=== $2 exited $rc"; return $rc; }
for p in $(seq "$first" $((first + passes - 1))); do
  for s in $steps; do
    case $s in
      B1) systemctl stop 'e2e-shardprov@*' e2e-1816-keeper 2>/dev/null; rm -rf /root/e2e/pools84 /run/e2e-shard
          step ${p} $E2E_H/vm/20-bootstrap.sh || { result "pass$p-bootstrap" FAIL "vm/20-bootstrap.sh failed; chain skipped"; break; } ;;
      B2) step ${p} /root/e2e/h84/vm/21-bootstrap-2084.sh || { result "pass$p-bootstrap" FAIL "vm/21-bootstrap-2084.sh failed; chain skipped"; break; } ;;
      U) step ${p} /root/e2e/h84/vm/u-rollout.sh || { result "pass$p-rollout" FAIL "u-rollout.sh failed; chain skipped"; break; } ;;
      P) step ${p} /root/e2e/h84/vm/s-pool.sh ;;
      F) step ${p} /root/e2e/h84/vm/s-fake.sh ;;
      *) log "unknown step $s" ;;
    esac
  done
  result "pass$p" INFO "chain done"
done
log "ALL-PASSES-DONE"
