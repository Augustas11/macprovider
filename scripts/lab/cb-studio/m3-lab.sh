#!/bin/bash
# SPEC-039 FR-PKV13 overhead ceiling re-record on the final #1646-remaining build.
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=/Users/a1/lab-cb-sampling; B=$L/bin-tools/macprovider-cli; O=$L/m3-final; rm -rf $O; mkdir -p $O; cd $O
M=/Users/a1/.cache/huggingface/hub/models--mlx-community--Qwen3.6-27B-4bit/snapshots/c000ac2c2057d94be3fa931000c31723aac53282
echo "binary $(shasum -a 256 $B | cut -c1-16)"
for eng in contiguous paged; do for Lp in 32 1536 4096; do for r in 1 2 4 8; do
  $B msb-throughput --model $M --engine $eng --rows $r --prompt-tokens $Lp --decode-tokens 128 --runs 2 --output $O/$eng-L$Lp-r$r.json > $O/$eng-L$Lp-r$r.log 2>&1
  grep -h "^msb-throughput: model" $O/$eng-L$Lp-r$r.log | sed "s/^/L=$Lp /"
done; done; done
echo M3_DONE
