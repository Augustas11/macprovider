#!/bin/bash
L=<studio-home>/lab-332
while ! grep -q SEQ1_DONE $L/cs/console-seq1.txt; do sleep 10; done
while pgrep -f "lab-cb-sampling/bench.sh <studio-home>/lab-332/cs/seq1.sh" >/dev/null; do sleep 5; done
mkdir -p $L/runs4/step3-r015-8875
mv $L/r015-policy-8875.json.tmp $L/r015-policy-8875.json
echo "frozen_at=$(date -u +%FT%TZ) policy_sha256=$(shasum -a 256 $L/r015-policy-8875.json | cut -d" " -f1) differs_from=8722ddbf4393a49fdfa48850d33fe6e9bdbf3c76954d913825b7f46165c0c9d2 fields=provider_commit,mlx_fork_revision env=MLX_LM_QWEN35_COMPILED_VERIFY_unset(compiled_verify_on)" > $L/runs4/step3-r015-8875/policy-freeze.txt
cp -p $L/r015-policy-8875.json $L/runs4/step3-r015-8875/policy.json
<studio-home>/lab-cb-sampling/bench.sh $L/window-8875.sh
