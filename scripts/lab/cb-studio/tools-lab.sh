#!/bin/bash
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=/Users/a1/lab-cb-sampling; B=$L/bin-tools; O=$L/tools-e2e; mkdir -p $O
lsof -nP -iTCP:18080 -sTCP:LISTEN -t >/dev/null 2>&1 && { echo busy; exit 3; }
cd $B; (nohup ./macprovider-cli serve --config $B/config.yaml --no-join > $O/serve.out 2> $O/serve.err < /dev/null &)
for i in $(seq 1 120); do SP=$(lsof -nP -t -iTCP:18080 -sTCP:LISTEN); [ -n "$SP" ] && grep -q "measure OK" $O/serve.err && break; sleep 5; done
echo "serve pid=$SP sha=$(shasum -a 256 $B/macprovider-cli | cut -c1-16)"
/usr/bin/python3 $L/tools_e2e.py 18080
echo "batching_admitted=$(grep -c 'batching_admitted' $O/serve.err) serial_routed=$(grep -c 'serial_routed' $O/serve.err) forward_failures=$(grep -acE 'batching_forward_failed|batching_prefill_failed' $O/serve.err)"
grep -o 'serial_routed reason=[a-z_]*' $O/serve.err | sort | uniq -c
kill $SP
