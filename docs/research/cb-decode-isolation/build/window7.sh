#!/bin/bash
# FR-CB10 self-check at k up to 16: narrowed+capped build vs main (uncapped), A3B fused.
L=<studio-home>/lab-di; mkdir -p $L/runs/sc
$L/sampler.sh > $L/runs/sc/samples.log 2>&1 & S=$!; trap "kill $S 2>/dev/null" EXIT
echo "WINDOW7_START $(date -u +%T)"
$L/sc-one.sh a3b-after 18195 after a3b 900
$L/sc-one.sh a3b-main 18196 main a3b 900
echo "WINDOW7_DONE $(date -u +%T)"
