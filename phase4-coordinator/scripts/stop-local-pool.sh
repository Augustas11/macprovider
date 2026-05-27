#!/usr/bin/env bash
# Tear down a pool created by scripts/run-local-pool.sh.
set -u

for pidfile in /tmp/mp-local-mockA.pid /tmp/mp-local-mockB.pid /tmp/mp-local-coord.pid; do
  if [ -f "$pidfile" ]; then
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  fi
done

pkill -f "mockprovider --coord-url ws://127.0.0.1:18444" 2>/dev/null || true
pkill -f "coordinator -config /tmp/mp-local-coord.yaml" 2>/dev/null || true
sleep 0.5
echo "[stop] pool stopped"
