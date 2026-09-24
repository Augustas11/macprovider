#!/usr/bin/env bash
# Start or stop the one lab serve process (by its recorded, re-verified
# identity only; never by name, so the live provider is never signalled).
#   serve.sh start [binary]   serve.sh stop
set -euo pipefail
LAB="${LAB:-/Users/a1/lab-1690-m6}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PIDF="$LAB/run/serve.pid"
# shellcheck source=pidguard.sh
. "$HERE/pidguard.sh"
stop() { pg_stop "$PIDF" 30 1; }
case "${1:-}" in
  stop) stop ;;
  start)
    stop
    LAB_CLI="${2:-$LAB/bin/macprovider-cli-lab}" nohup "$HERE/cli.sh" serve --config "$LAB/provider/config.yaml" --isolate-lifecycle >>"$LAB/logs/serve.log" 2>&1 &
    pg_record "$PIDF" $!
    sleep 12
    pid=$(pg_verify "$PIDF") && echo "serve pid $pid" ;;
  *) echo "usage: serve.sh start [binary] | stop" >&2; exit 2 ;;
esac
