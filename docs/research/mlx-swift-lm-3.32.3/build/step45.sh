#!/bin/bash
# Steps 4-5: control 1.8.230, new build fused, new build stock MoE, one bench.sh window.
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=<studio-home>/lab-332; O=$L/runs4/step45; mkdir -p $O
echo "binaries new=$(shasum -a 256 $L/bin/macprovider-cli | cut -c1-16) control=$(shasum -a 256 $L/control-1.8.230/bin/macprovider-cli | cut -c1-16)"
BIN=$L/control-1.8.230/bin/macprovider-cli CFG=$L/cfg/config-control.yaml $L/rtcmp-332.sh $O ctl230-w1
$L/rtcmp-332.sh $O ours332-fused-w1
$L/rtcmp-332.sh $O ours332-stock-w1 MLX_LM_QWEN35_FUSED_MOE=0
echo "STEP45_DONE $(date -u +%T)"
