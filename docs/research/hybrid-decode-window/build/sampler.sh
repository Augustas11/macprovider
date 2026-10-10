#!/bin/bash
# Every 2 s: epoch, live :8080 requests_in_flight, and the summed CPU% of
# other heavy inference processes (executable macprovider-cli, Python, mlx*,
# llama*, ollama, LM Studio) that are neither this lab tree, its load
# generator, nor the live provider. The live provider is paused by bench.sh,
# so its own CPU is not counted; its in-flight count is.
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
while true; do
  n=$(curl -s --max-time 2 http://127.0.0.1:8080/v1/status | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin).get('requests_in_flight', -1))" 2>/dev/null)
  skip=" $(pgrep -f 'lab-hw|depth_sweep|sampler\.sh|<studio-home>/macprovider/macprovider-cli' | tr '\n' ' ') "
  o=$(ps -axo pid=,%cpu=,comm= | awk -v skip="$skip" '
    index(skip, " " $1 " ") {next}
    { c = $0; sub(/^ *[0-9]+ +[0-9.]+ +/, "", c) }
    c ~ /macprovider-cli|[Pp]ython|\/mlx|llama|ollama|LM Studio|lms$/ { if ($2+0 >= 3) { s += $2; l = l $1 ":" int($2) "," } }
    END { printf "%d %s", s+0, (l == "" ? "-" : l) }')
  echo "$(date +%s) ${n:--1} $o"
  sleep 2
done
