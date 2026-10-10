#!/bin/bash
# Start a hybrid-window build on an isolated loopback port (no join).
# usage: lab-serve.sh <out-dir> <port> [VAR=value ...]   (prints PID)
#   CFG selects the config (default A3B), BIN the executable (default serve build).
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=<studio-home>/lab-hw; OUT=$1; PORT=$2; shift 2
mkdir -p "$OUT" "$L/home" "$L/tmp"
sed "s/^port: .*/port: $PORT/" "${CFG:-<studio-home>/lab-332/cfg/config.yaml}" > "$OUT/cfg-$PORT.yaml"; chmod 600 "$OUT/cfg-$PORT.yaml"
env TMPDIR=$L/tmp/ MACPROVIDER_LIFECYCLE_ROOT=$L/home/lifecycle "$@" \
  "${BIN:-$L/serve/phase3-binary/.build/release/macprovider-cli}" serve --config "$OUT/cfg-$PORT.yaml" --port "$PORT" \
  --no-join --no-idle-prewarm > "$OUT/serve-$PORT.log" 2>&1 &
echo $!
