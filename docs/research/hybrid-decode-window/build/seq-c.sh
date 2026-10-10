#!/bin/bash
# Wait for a quiet Studio (no live request in flight is not required here;
# no other heavy lab process for 60 s), then the throughput window, then the
# R015 window, then the 27B exactness proof (no pause).
L=<studio-home>/lab-hw
quiet() {
  $L/sampler.sh > $L/runs/quiet-$1.log 2>&1 & local s=$!
  for _ in $(seq 1 5400); do
    sleep 2
    [ $(wc -l < $L/runs/quiet-$1.log) -ge 30 ] || continue
    [ "$(tail -30 $L/runs/quiet-$1.log | awk '$3 >= 5 {b=1} END {print b+0}')" = 0 ] && { kill $s; echo "QUIET_$1 $(date -u +%T)"; return 0; }
  done
  kill $s; echo "NO_QUIET_$1 $(date -u +%T)"; return 1
}
quiet tput && <studio-home>/lab-cb-sampling/bench.sh $L/tput.sh $L/runs/tput
echo "TPUT_WINDOW_DONE $(date -u +%T)"
quiet r015 && <studio-home>/lab-cb-sampling/bench.sh $L/r015.sh
echo "R015_WINDOW_DONE $(date -u +%T)"
A3B=x; Q27="<studio-home>/Library/Application Support/macprovider/models/mlx-community--Qwen3.6-27B-4bit/c000ac2c2057d94be3fa931000c31723aac53282/518ef47c298783d8547b50406e84548e5bf7705b82355a38f9eaef1368817931"
rm -rf $L/runs/exact/q27
B=$L/serve/phase3-binary/.build/release/macprovider-cli M="$Q27" bash <studio-home>/macprovider-hybrid-window/scripts/lab/cb-studio/hybrid-window-proof.sh $L/runs/exact/q27; echo "q27 rc=$?"
echo SEQC_DONE
