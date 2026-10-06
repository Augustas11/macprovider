#!/bin/bash
# Long-generation follow-up (o4096 budget) for the column-cap fix: new then old. In-process only: no ports, no join.
set -uo pipefail
R=/Users/a1/mtp-colcap-7b5fbd675
FIX=/Users/a1/.cache/macprovider-mtp-e2e/q36-a3b-cat
OLD=/Users/a1/mtp-r015-amended-26a434-20261006/src/phase3-binary/.build/arm64-apple-macosx/release/macprovider-cli
NEW=$R/src/phase3-binary/.build/arm64-apple-macosx/release/macprovider-cli
LOCK=/Users/a1/.lab-window.lock
S=$R/status2.txt
until mkdir "$LOCK" 2>/dev/null; do sleep 30; done
echo "colcap-7b5fbd675 longgen2 (claude executor, branch mtp/step-overhead) $(date -u +%FT%TZ) pid $$" > "$LOCK/owner"
trap "rm -rf $LOCK; echo DONE >> $S" EXIT
echo "lock_acquired $(date -u +%FT%TZ)" >> $S
for run in new old; do
  case $run in old) BIN=$OLD; PC=e1103712d408a0b158ac17dd8834875245874a42;; new) BIN=$NEW; PC=7b5fbd67546788a3f77d675b93eec1de3d1411e1;; esac
  echo "$(date -u +%FT%TZ) start longgen2 $run" >> $S
  MACPROVIDER_NATIVE_MTP_E2E=1 "$BIN" native-mtp-bench --root $FIX --model-id qwen/qwen3.6-35b-a3b --policy $R/longgen2/longgen2-$run-policy.json --out $R/longgen2/$run.jsonl --phase matrix --provider-commit $PC > $R/longgen2/$run.log 2>&1; rc=$?
  echo "$(date -u +%FT%TZ) end longgen2 $run exit=$rc" >> $S
done
