#!/bin/bash
# After seq-c: the throughput matrix again with the #1906 runtime-compare slot
# configuration (max_concurrency_override 32, queue 256), so depth 16 is not
# capped at 8 slots.
L=<studio-home>/lab-hw
while pgrep -f "seq-c.sh" >/dev/null; do sleep 20; done
quiet() {
  $L/sampler.sh > $L/runs/quiet-$1.log 2>&1 & local s=$!
  for _ in $(seq 1 5400); do
    sleep 2
    [ $(wc -l < $L/runs/quiet-$1.log) -ge 30 ] || continue
    [ "$(tail -30 $L/runs/quiet-$1.log | awk "\$3 >= 5 {b=1} END {print b+0}")" = 0 ] && { kill $s; echo "QUIET_$1 $(date -u +%T)"; return 0; }
  done
  kill $s; echo "NO_QUIET_$1 $(date -u +%T)"; return 1
}
quiet tput32 && CFG=$L/cfg/config-a3b-32slots.yaml <studio-home>/lab-cb-sampling/bench.sh $L/tput.sh $L/runs/tput32
echo "TPUT32_WINDOW_DONE $(date -u +%T)"
echo SEQD_DONE
