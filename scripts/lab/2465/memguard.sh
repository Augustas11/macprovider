#!/bin/bash
# Free-memory guard for one intake lab job (#2465, #2466), run on the Studio beside it so it works
# with ssh down (the Studio has no swap and hangs outright when RAM fills). Samples system free
# memory every 2 s, logs every 30 s and whenever free is within 10 points of the floor, and below
# FLOOR_PCT stops the whole job process group and any serve whose config lives under LAB_DIR.
# usage: memguard.sh JOB_PID FLOOR_PCT LOG LAB_DIR
set -u
jp=$1 floor=$2 log=$3 lab=$4 n=0
while kill -0 "$jp" 2>/dev/null; do
  free=$(memory_pressure 2>/dev/null | awk '/free percentage/ {gsub("%", "", $NF); print $NF}')
  if [ -z "$free" ]; then sleep 2; continue; fi
  if [ $((n % 15)) -eq 0 ] || [ "$free" -lt $((floor + 10)) ]; then
    echo "$(date +%H:%M:%S) free_pct=$free top_rss_kb=$(ps -axco rss=,command= | sort -nr | head -3 | tr -s ' \n' ' ')" >> "$log"
  fi
  if [ "$free" -lt "$floor" ]; then
    echo "$(date +%H:%M:%S) MEMGUARD_KILL free_pct=$free floor=$floor" >> "$log"
    kill -TERM -- -"$jp" 2>/dev/null; sleep 5; kill -KILL -- -"$jp" 2>/dev/null
    pkill -KILL -f "macprovider-cli[ ]serve --config $lab/" 2>/dev/null
    exit 0
  fi
  n=$((n + 1)); sleep 2
done
