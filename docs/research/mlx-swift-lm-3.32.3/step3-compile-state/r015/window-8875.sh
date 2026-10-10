#!/bin/bash
# One bench.sh window: startup probes on the 8875789e7 serve build, then the formal R015.
L=<studio-home>/lab-332
for spec in "a3b-fused-8875 18190" "a3b-stock-8875 18191 MLX_LM_QWEN35_FUSED_MOE=0"; do
  set -- $spec
  BIN=$L/bin-8875/macprovider-cli $L/probe.sh "$@"
done
$L/r015-8875.sh
echo WINDOW_DONE
