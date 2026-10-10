#!/bin/bash
# Window 8: A3B main vs narrowed at 8 and 16 concurrent, mixed-length prompts
# (uniform 300-2500 tokens per request, 256 output, 90 s cells), so rows
# straddle the 1024-key route boundary and the narrowed build splits rows.
L=<studio-home>/lab-di; OUT=$L/runs/w8-$(date -u +%Y%m%dT%H%MZ); mkdir -p $OUT
$L/sampler.sh > $OUT/samples.log 2>&1 & SAM=$!; trap 'kill $SAM 2>/dev/null' EXIT
echo "WINDOW8_START $(date -u +%T)"
export SWEEP=$L/mixed_sweep.py MIX_MIN=300 MIX_MAX=2500 SHAPE="1400 256 90 20"
$L/tput.sh $OUT a3b-mixed-main main a3b 8,16,8,16
$L/tput.sh $OUT a3b-mixed-narrowed after a3b 8,16,8,16
echo "WINDOW8_DONE $(date -u +%T) out=$OUT"
