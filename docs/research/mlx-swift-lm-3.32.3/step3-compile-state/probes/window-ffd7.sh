#!/bin/bash
# One bench.sh window: startup probes on the ffd79639b serve build (compile-cache cleanup fix).
L=<studio-home>/lab-332
for spec in "a3b-fused-ffd7 18192" "a3b-stock-ffd7 18193 MLX_LM_QWEN35_FUSED_MOE=0"; do
  set -- $spec
  BIN=$L/bin-ffd7/macprovider-cli $L/probe.sh "$@"
done
echo WINDOW_DONE
