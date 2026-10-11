#!/bin/bash
# Window 1: startup probes (A3B fused on/off, 27B) on the after build, then A3B
# throughput main vs after at 1/2/4/8/16 rows, plus after uncapped at 16 rows.
L=<studio-home>/lab-di; OUT=$L/runs/w1-$(date -u +%Y%m%dT%H%MZ); mkdir -p $OUT
$L/sampler.sh > $OUT/samples.log 2>&1 & SAM=$!; trap 'kill $SAM 2>/dev/null' EXIT
echo "WINDOW1_START $(date -u +%T)"
$L/startup-probe.sh w1-sp-a3b-fused 18195 after a3b
$L/startup-probe.sh w1-sp-a3b-stock 18196 after a3b MLX_LM_QWEN35_FUSED_MOE=0
$L/startup-probe.sh w1-sp-q27b 18197 after q27b
$L/tput.sh $OUT a3b-main main a3b 1,2,4,8,16
$L/tput.sh $OUT a3b-after after a3b 1,2,4,8,16
$L/tput.sh $OUT a3b-after-uncapped after a3b 16 MACPROVIDER_LAB_DECODE_ROW_BOUND=64
echo "WINDOW1_DONE $(date -u +%T) out=$OUT"
