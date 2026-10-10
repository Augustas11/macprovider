#!/bin/bash
# Run one isolated, no-join lab provider for issue #700 matrix rows, probe it,
# then stop it. Never touches the live provider: own port, own ctl socket,
# own switch-state path, own HOME/TMPDIR/lifecycle root, auto-update off.
#
# usage: issue700_lab_serve.sh <name> <port> <model_dir> <family> <cb:off|canary> [extra serve args...]
#   LAB        lab root holding bin/ (binary + mlx.metallib) and the probe script
#   EXTRA_CFG  optional YAML file appended to the generated lab config
#   BINDIR     directory holding macprovider-cli + mlx.metallib (default $LAB/bin)
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=${LAB:?set LAB to the lab root}; BINDIR=${BINDIR:-$LAB/bin}
N=$1; PORT=$2; MODEL=$3; FAMILY=$4; CB=$5; shift 5
case "$PORT" in 1818[5-9]) ;; *) echo "port $PORT outside the lab range 18185-18189" >&2; exit 2 ;; esac
if pgrep -f lab-cb-sampling/bench.sh >/dev/null; then echo "bench window active; not starting" >&2; exit 3; fi
O=$LAB/runs/$N; rm -rf "$O"; mkdir -p "$O" "$LAB/home" "$LAB/tmp"
cat > "$O/config.yaml" <<EOF
auto_update_enabled: false
enable_receipts: false
idle_prewarm:
  enabled: false
continuous_batching: "$CB"
EOF
# EXTRA_CFG: optional YAML appended verbatim (e.g. paged_kv plus a lab
# continuous_batching_accepted_tuples entry for the CB startup probe).
[ -n "${EXTRA_CFG:-}" ] && cat "$EXTRA_CFG" >> "$O/config.yaml"
chmod 600 "$O/config.yaml"
env HOME=$LAB/home TMPDIR=$LAB/tmp/ MACPROVIDER_LIFECYCLE_ROOT=$LAB/home/lifecycle \
  "$BINDIR/macprovider-cli" serve --no-join --config "$O/config.yaml" \
  --credential-store protected_file --port "$PORT" --model "$MODEL" \
  --max-context 8192 --continuous-batching "$CB" --no-enable-warm-swap \
  --ctl-socket-path "$O/ctl.sock" --switch-state-path "$O/last-switch.ts" \
  --no-enable-receipts --no-idle-prewarm "$@" > "$O/serve.log" 2>&1 &
P=$!; echo "$P" > "$O/pid"
ready=0
for i in $(seq 1 120); do
  curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && { ready=1; break; }
  kill -0 "$P" 2>/dev/null || break
  sleep 5
done
exe=$(lsof -a -p "$P" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
echo "== $N ready=$ready after=$((i*5))s exe_is_lab_binary=$([ "$exe" = "$BINDIR/macprovider-cli" ] && echo yes || echo no)"
if [ "$ready" = 1 ]; then
  curl -s "http://127.0.0.1:$PORT/v1/status" > "$O/status.json"
  python3 -I "$LAB/issue700_correctness_probe.py" --port "$PORT" --family "$FAMILY" --out "$O/probe.json" | tee "$O/probe.txt"
  curl -s "http://127.0.0.1:$PORT/v1/status" > "$O/status-after.json"
fi
kill "$P" 2>/dev/null; sleep 5; kill -0 "$P" 2>/dev/null && kill -9 "$P"
grep -n -i -E "unhandled|missing|mismatch|shape|error|fatal|metallib|paged-kv|continuous.batch|cb_|unsupported" "$O/serve.log" | head -60 > "$O/serve-grep.txt"
echo "DONE $N"
