#!/bin/bash
# Window 2: 27B throughput, main vs after at 1/2/4/8/16 rows, plus after uncapped at 16;
# then two more A3B 4-row cells per arm (window 1 had one noisy 4-row cell).
L=<studio-home>/lab-di; OUT=$L/runs/w2-$(date -u +%Y%m%dT%H%MZ); mkdir -p $OUT
$L/sampler.sh > $OUT/samples.log 2>&1 & SAM=$!; trap 'kill $SAM 2>/dev/null' EXIT
echo "WINDOW2_START $(date -u +%T)"
$L/tput.sh $OUT q27b-main main q27b 1,2,4,8,16
$L/tput.sh $OUT q27b-after after q27b 1,2,4,8,16
$L/tput.sh $OUT q27b-after-uncapped after q27b 16 MACPROVIDER_LAB_DECODE_ROW_BOUND=64
$L/tput.sh $OUT a3b-main-r main a3b 4,4
$L/tput.sh $OUT a3b-after-r after a3b 4,4
echo "WINDOW2_DONE $(date -u +%T) out=$OUT"
