#!/bin/bash
# Sample the live provider status every 5 s for $1 seconds (no lab load).
for i in $(seq 1 $(( $1 / 5 ))); do
  curl -s --max-time 3 http://127.0.0.1:8080/v1/status | /usr/bin/python3 -c "import sys,json,time;d=json.load(sys.stdin);s=d[\"continuous_batching\"][\"scheduler\"];print(time.strftime(\"%H:%M:%S\",time.gmtime()),\"in_flight=%s state=%s paused=%s rows=%s fwd=%s total=%s\"%(d[\"requests_in_flight\"],d[\"lifecycle\"][\"state\"],d[\"lifecycle\"][\"operator_paused\"],s[\"active_decode_rows\"],s[\"shared_forward_calls\"],d.get(\"requests_total\")))"
  sleep 5
done
