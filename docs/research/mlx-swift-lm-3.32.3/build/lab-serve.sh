#!/bin/bash
# Start the mlx-swift-lm 3.32.3 lab build on an isolated loopback port.
# usage: lab-serve.sh <out-dir> <port> [VAR=value ...]   (prints PID)
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=<studio-home>/lab-332; OUT=$1; PORT=$2; shift 2
mkdir -p "$OUT" "$L/home" "$L/tmp"
sed "s/^port: .*/port: $PORT/" "${CFG:-$L/cfg/config.yaml}" > "$OUT/cfg-$PORT.yaml"; chmod 600 "$OUT/cfg-$PORT.yaml"
env TMPDIR=$L/tmp/ MACPROVIDER_LIFECYCLE_ROOT=$L/home/lifecycle "$@" \
  "${BIN:-$L/bin/macprovider-cli}" serve --config "$OUT/cfg-$PORT.yaml" --port "$PORT" \
  --no-join --autotune-candidate --no-idle-prewarm > "$OUT/serve-$PORT.log" 2>&1 &
echo $!
