#!/bin/bash
# Issue #1906: model-level paged decode at the serve's ~3k-token context, to
# split context cost from serve overhead. Run under bench.sh.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=/Users/a1/lab-1906
B=/Users/a1/macprovider-1906-cb-depth/phase3-binary/.build/release/macprovider-cli
M=$(grep '^model_artifact_path:' "$LAB/cfg/config.yaml" | sed 's/^model_artifact_path: *//; s/"//g')
OUT=$1; mkdir -p "$OUT"
for r in 8 16; do
  "$B" msb-throughput --model "$M" --engine paged --rows $r --prompt-tokens 3072 --decode-tokens 128 \
    --runs 2 --max-physical-blocks 8192 --output "$OUT/msb-paged-L3072-r$r.json" > "$OUT/msb-L3072-r$r.log" 2>&1
  grep -h "^msb-throughput: model" "$OUT/msb-L3072-r$r.log" | sed "s/^/rows=$r L=3072 /"
done
echo MSB_CONTEXT_DONE
