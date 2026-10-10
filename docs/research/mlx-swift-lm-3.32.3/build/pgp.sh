#!/bin/bash
# usage: pgp.sh <name> <port> <bindir> <model> [VAR=value ...]   (CFG selects config; PGP_* env passes through)
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=<studio-home>/lab-332; N=$1; PORT=$2; B=$3; MODEL=$4; shift 4
KEEP=1 BIN=$L/$B/macprovider-cli $L/probe.sh $N $PORT "$@" > $L/runs2/$N.probe.txt 2>&1
P=$(cat $L/runs2/$N/pid)
grep -h "continuous_batch_prefill_grouping" $L/runs2/$N/serve-$PORT.log >> $L/runs2/$N.probe.txt
python3 $L/prefill_group_probe.py $PORT $MODEL $L/runs2/$N/pgp.json > $L/runs2/$N/pgp.txt 2>&1
kill $P; sleep 6; echo done > $L/runs2/$N/pgp.done
