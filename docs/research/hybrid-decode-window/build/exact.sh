#!/bin/bash
# FR-CB2 hybrid window exactness proof (window 16 vs 1, fixed batch of 16,
# prompts 1536..2091 tokens) on the served A3B (fused MoE on and off) and 27B.
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=<studio-home>/lab-hw; R=$L/runs/exact; mkdir -p $R
P=<studio-home>/macprovider-hybrid-window/scripts/lab/cb-studio/hybrid-window-proof.sh
A3B="<studio-home>/Library/Application Support/macprovider/models/mlx-community--Qwen3.6-35B-A3B-4bit/38740b847e4cb78f352aba30aa41c76e08e6eb46/3fed776d41b6883888541d19f71a3866acc3bc6e628402066b67e5ac0a676ff1"
Q27="<studio-home>/Library/Application Support/macprovider/models/mlx-community--Qwen3.6-27B-4bit/c000ac2c2057d94be3fa931000c31723aac53282/518ef47c298783d8547b50406e84548e5bf7705b82355a38f9eaef1368817931"
export B=$L/serve/phase3-binary/.build/release/macprovider-cli
M="$A3B" MLX_LM_QWEN35_FUSED_MOE=1 bash $P $R/a3b-fused; echo "a3b-fused rc=$?"
M="$A3B" MLX_LM_QWEN35_FUSED_MOE=0 bash $P $R/a3b-stock; echo "a3b-stock rc=$?"
M="$Q27" bash $P $R/q27; echo "q27 rc=$?"
echo EXACT_DONE
