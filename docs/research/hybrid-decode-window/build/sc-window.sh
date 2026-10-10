#!/bin/bash
# FR-CB10 self-check composition at the hybrid serve window (16) on the #1953
# build, A3B (fused MoE, default) and 27B, owner-pinned 8 slots as live. Run
# under bench-norestart.sh. Live requests_in_flight sampled every 2 s.
L=<studio-home>/lab-hw; mkdir -p $L/runs/sc
$L/sampler.sh > $L/runs/sc/samples.log 2>&1 & S=$!
trap "kill $S 2>/dev/null" EXIT
echo "WINDOW_RUN_START $(date -u +%T)"
CFG=<studio-home>/lab-332/cfg/config.yaml $L/sc-one.sh a3b-fused 18190 720
CFG=<studio-home>/lab-332/cfg/config-27b.yaml $L/sc-one.sh q27 18191 720
echo "WINDOW_RUN_END $(date -u +%T)"
