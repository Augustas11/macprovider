#!/bin/bash
# Column-cap fix (7b5fbd675) lab window: build, hardware e2e, interleaved s1/s2 timing vs e1103712d, long-generation check. In-process only: no ports, no join.
set -uo pipefail
R=/Users/a1/mtp-colcap-7b5fbd675
FIX=/Users/a1/.cache/macprovider-mtp-e2e/q36-a3b-cat
OLD=/Users/a1/mtp-r015-amended-26a434-20261006/src/phase3-binary/.build/arm64-apple-macosx/release/macprovider-cli
NEW=$R/src/phase3-binary/.build/arm64-apple-macosx/release/macprovider-cli
OLDPC=e1103712d408a0b158ac17dd8834875245874a42
NEWPC=7b5fbd67546788a3f77d675b93eec1de3d1411e1
LOCK=/Users/a1/.lab-window.lock
S=$R/status.txt
until mkdir "$LOCK" 2>/dev/null; do sleep 30; done
echo "colcap-7b5fbd675 (claude executor, branch mtp/step-overhead) $(date -u +%FT%TZ) pid $$" > "$LOCK/owner"
(
  while true; do date -u +%FT%TZ; for i in 1 2 3 4 5; do ioreg -r -c IOAccelerator -d 1 2>/dev/null | grep -o "\"Device Utilization %\"=[0-9]*" | head -1; sleep 1; done | tr "\n" " "; echo; sleep 20; done
) > $R/gpu.log 2>&1 &
SP=$!; trap "kill $SP 2>/dev/null || true; rm -rf $LOCK; echo DONE >> $S" EXIT
echo "lock_acquired $(date -u +%FT%TZ)" >> $S
cd $R/src/phase3-binary && swift build -c release --product macprovider-cli -Xswiftc -DMACPROVIDER_LAB_HARNESS > $R/build.log 2>&1; rc=$?
echo "$(date -u +%FT%TZ) build exit=$rc" >> $S; [ $rc -eq 0 ] || exit 1
cp /Users/a1/mtp-r015-amended-26a434-20261006/src/phase3-binary/.build/arm64-apple-macosx/release/mlx.metallib $(dirname $NEW)/mlx.metallib
echo "new_sha256=$(shasum -a 256 $NEW | awk '{print $1}') old_sha256=$(shasum -a 256 $OLD | awk '{print $1}') metallib=$(shasum -a 256 $(dirname $NEW)/mlx.metallib | awk '{print $1}')" >> $S
MACPROVIDER_NATIVE_MTP_E2E=1 MACPROVIDER_NATIVE_MTP_E2E_SERVE_PATH=1 "$NEW" native-mtp-hardware-e2e --root $FIX --model-id qwen/qwen3.6-35b-a3b --max-batch 2 --sizing-prompt-tokens 1024 --sizing-output-tokens 256 > $R/e2e/hardware-e2e.log 2>&1; rc=$?
echo "$(date -u +%FT%TZ) hardware_e2e exit=$rc" >> $S
for run in old1 new1 new2 old2; do
  case $run in old*) BIN=$OLD; PC=$OLDPC; P=$R/timing/timing-old-policy.json;; new*) BIN=$NEW; PC=$NEWPC; P=$R/timing/timing-new-policy.json;; esac
  echo "$(date -u +%FT%TZ) start timing $run" >> $S
  MACPROVIDER_NATIVE_MTP_E2E=1 "$BIN" native-mtp-bench --root $FIX --model-id qwen/qwen3.6-35b-a3b --policy $P --out $R/timing/$run.jsonl --phase matrix --provider-commit $PC > $R/timing/$run.log 2>&1; rc=$?
  echo "$(date -u +%FT%TZ) end timing $run exit=$rc" >> $S
done
for run in new old; do
  case $run in old) BIN=$OLD; PC=$OLDPC;; new) BIN=$NEW; PC=$NEWPC;; esac
  echo "$(date -u +%FT%TZ) start longgen $run" >> $S
  MACPROVIDER_NATIVE_MTP_E2E=1 "$BIN" native-mtp-bench --root $FIX --model-id qwen/qwen3.6-35b-a3b --policy $R/longgen/longgen-$run-policy.json --out $R/longgen/$run.jsonl --phase matrix --provider-commit $PC > $R/longgen/$run.log 2>&1; rc=$?
  echo "$(date -u +%FT%TZ) end longgen $run exit=$rc" >> $S
done
