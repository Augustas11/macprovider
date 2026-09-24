#!/usr/bin/env bash
# Start or stop the one lab serve process (by its recorded PID only; never by
# name, so the live provider is never signalled).
#   serve.sh start [binary]   serve.sh stop
set -euo pipefail
LAB="${LAB:-/Users/a1/lab-1690-m6}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PIDF="$LAB/run/serve.pid"
stop() {
  if [[ -f "$PIDF" ]] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
    kill -TERM "$(cat "$PIDF")"
    for _ in $(seq 1 30); do kill -0 "$(cat "$PIDF")" 2>/dev/null || break; sleep 1; done
    kill -0 "$(cat "$PIDF")" 2>/dev/null && kill -KILL "$(cat "$PIDF")" || true
  fi
  rm -f "$PIDF"
}
case "${1:-}" in
  stop) stop ;;
  start)
    stop
    LAB_CLI="${2:-$LAB/bin/macprovider-cli-lab}" nohup "$HERE/cli.sh" serve --config "$LAB/provider/config.yaml" --isolate-lifecycle >>"$LAB/logs/serve.log" 2>&1 &
    echo $! >"$PIDF"
    sleep 12
    kill -0 "$(cat "$PIDF")" && echo "serve pid $(cat "$PIDF")" ;;
  *) echo "usage: serve.sh start [binary] | stop" >&2; exit 2 ;;
esac
