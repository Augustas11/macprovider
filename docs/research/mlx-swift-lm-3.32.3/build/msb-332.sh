#!/bin/bash
# MSB-01..05 + FR-CB15 leftovers + FR-PKV13 ceiling cells on the 3.32.3 lab build.
# In-process harness, no ports, no join. Run under bench.sh (live paused).
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=<studio-home>/lab-332; B=$L/bin/macprovider-cli; O=$L/runs2/step2-msb; mkdir -p $O; cd $O
M="<studio-home>/Library/Application Support/macprovider/models/mlx-community--Qwen3.6-35B-A3B-4bit/38740b847e4cb78f352aba30aa41c76e08e6eb46/3fed776d41b6883888541d19f71a3866acc3bc6e628402066b67e5ac0a676ff1"
echo "start $(date -u +%T) binary $(shasum -a 256 $B | cut -c1-16)"
for r in 1 2 4 8; do
  $B msb-throughput --model "$M" --engine paged --rows $r --prompt-tokens 1536 --decode-tokens 128 --runs 2 --output $O/paged-L1536-r$r.json > $O/paged-L1536-r$r.log 2>&1
  echo "paged r=$r exit=$? $(grep -h '^msb-throughput: model' $O/paged-L1536-r$r.log | tail -1)"
done
for sc in msb03 msb05 leftovers; do
  $B msb-throughput --model "$M" --engine scheduler --scenario $sc --output $O/scheduler-$sc.json > $O/scheduler-$sc.log 2>&1
  echo "scenario $sc exit=$? $(date -u +%T)"
done
echo "MSB_DONE $(date -u +%T)"
