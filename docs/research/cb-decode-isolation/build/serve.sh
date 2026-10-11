#!/bin/bash
# usage: serve.sh <out-dir> <port> <tree:after|main> <cfg:a3b|q27b> [VAR=value ...]   prints PID
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=<studio-home>/lab-di; OUT=$1; PORT=$2; T=$3; C=$4; shift 4
case $PORT in 1819[5-9]) ;; *) echo "port $PORT outside 18195-18199" >&2; exit 2;; esac
mkdir -p "$OUT" $L/tmp
sed "s/^port: .*/port: $PORT/" $L/cfg/$C.yaml > "$OUT/config.yaml"; chmod 600 "$OUT/config.yaml"
env TMPDIR=$L/tmp/ MACPROVIDER_LIFECYCLE_ROOT="$OUT/lifecycle" "$@" \
  $L/src-$T/.build/release/macprovider-cli serve --config "$OUT/config.yaml" --port "$PORT" \
  --no-join ${NOAT:+}$([ -z "$NOAT" ] && echo --autotune-candidate) --no-idle-prewarm > "$OUT/serve.log" 2>&1 &
echo $!
