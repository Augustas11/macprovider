#!/usr/bin/env bash
# In-VM pass driver for #1816 (runs detached under systemd-run, so a host
# network drop cannot kill it).
# Usage: run-passes.sh [passes] [steps] [first-pass-id]
#   steps: space-separated subset of the chain, default the full chain
#     B1 = shared vm/20-bootstrap.sh (old/old, fresh state)  B2 = vm/21-bootstrap-1816.sh
#     S1 S2 S3 S4 S5 S6
#   Every pass starts from a fresh bootstrap; the scenarios depend on each
#   other in chain order (S2 leaves the new pair, S3 the pools, ...).
set -uo pipefail
. /root/e2e/h/vm/lib.sh
passes="${1:-2}"; steps="${2:-B1 B2 S1 S2 S3 S4 S5 S6}"; first="${3:-1}"
bash $E2E_H/vm/10-build.sh || die "build failed"
if [ "$first" = 1 ] && [ "${E2E_KEEP_EVIDENCE:-0}" != 1 ]; then
  : >"$E2E_EVIDENCE/results.jsonl"
  rm -rf "$E2E_EVIDENCE"/p[0-9]* /root/e2e/pools16
fi
step() { log "=== pass $1: $2"; PASS_ID=$1 bash "$2" || log "=== $2 exited $?"; }
for p in $(seq "$first" $((first + passes - 1))); do
  for s in $steps; do
    case $s in
      B1) rm -rf /root/e2e/pools16; systemctl stop e2e-1816-keeper 2>/dev/null; step ${p}A $E2E_H/vm/20-bootstrap.sh ;;
      B2) step ${p}A /root/e2e/h16/vm/21-bootstrap-1816.sh ;;
      S1) step ${p}A $E2E_H/vm/s1-baseline.sh ;;
      S2) step ${p}A /root/e2e/h16/vm/s2-updater.sh ;;
      S3) step ${p}A /root/e2e/h16/vm/s3-pool-models.sh ;;
      S4) step ${p}A /root/e2e/h16/vm/s4-refusals.sh ;;
      S5) step ${p}A /root/e2e/h16/vm/s5-rotation.sh ;;
      S6) step ${p}A /root/e2e/h16/vm/s6-rollback.sh ;;
      *) log "unknown step $s" ;;
    esac
  done
  result "pass$p" INFO "chain done"
done
systemctl stop e2e-1816-keeper 2>/dev/null || true
log "ALL-PASSES-DONE"
