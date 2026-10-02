#!/bin/bash
# Round 2b: client-cancel probe (exercises the all-cancelled early window end).
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=/Users/a1/lab-cb-step; O=$L/out3-$(date -u +%Y%m%dT%H%M%SZ); mkdir -p $O
lsof -nP -iTCP:18080 -sTCP:LISTEN -t >/dev/null 2>&1 && { echo busy; exit 3; }
for v in base fix; do
  B=/Users/a1/macprovider-cb-step-$v/phase3-binary/.build/arm64-apple-macosx/release
  cd $B; (nohup ./macprovider-cli serve --config $L/config.yaml --no-join > $O/serve-$v.out 2> $O/serve-$v.err < /dev/null &)
  P=""; for i in $(seq 1 120); do P=$(lsof -nP -t -iTCP:18080 -sTCP:LISTEN); [ -n "$P" ] && grep -q "measure OK" $O/serve-$v.err && break; sleep 5; done
  echo "VARIANT $v pid=$P $(date -u +%T)"
  /usr/bin/python3 $L/cancel_probe.py 18080 meta-llama/llama-3.1-8b-instruct | sed "s/^/$v /" | tee -a $O/semantics.txt
  sleep 2
  echo "$v admitted=$(grep -c batching_admitted $O/serve-$v.err) failures=$(grep -cE 'forward_failed|blockTableMismatch|cleanup_failed|stream_mismatch|invalid_decode_token' $O/serve-$v.err) cancel_lines=$(grep -ciE 'cancel' $O/serve-$v.err)" | tee -a $O/semantics.txt
  kill $P; for i in $(seq 1 30); do lsof -nP -iTCP:18080 -sTCP:LISTEN -t >/dev/null 2>&1 || break; sleep 2; done
done
echo "LAB_DONE $O"
