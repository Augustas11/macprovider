#!/bin/bash
# Ragged grouped-prefill probe: start one lab serve with the CB trace on, run
# ragged_prefill_probe.py against it, keep the trace's prefill groups, stop it.
# usage: rpp.sh <name> <port> <bindir> <model> [VAR=value ...]   (CFG selects config; PGP_*/RPP_* env passes through)
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=<studio-home>/lab-332; N=$1; PORT=$2; B=$3; MODEL=$4; shift 4
KEEP=1 BIN=$L/$B/macprovider-cli $L/probe.sh $N $PORT MACPROVIDER_CB_TRACE=1 "$@" > $L/runs2/$N.probe.txt 2>&1
P=$(cat $L/runs2/$N/pid)
grep -h "continuous_batch_prefill_grouping" $L/runs2/$N/serve-$PORT.log >> $L/runs2/$N.probe.txt
python3 $L/ragged_prefill_probe.py $PORT $MODEL $L/runs2/$N/rpp.json > $L/runs2/$N/rpp.txt 2>&1
kill $P; sleep 6
grep -ho "ev=prefill_shared rows=[0-9]* chunk=[0-9]* ragged=[a-z]*" $L/runs2/$N/serve-$PORT.log | sed 's/ev=prefill_shared //' | sort | uniq -c > $L/runs2/$N/groups.txt
echo done > $L/runs2/$N/rpp.done
