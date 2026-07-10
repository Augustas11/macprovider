#!/usr/bin/env bash
set -euo pipefail

DIST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONITOR="$DIST_DIR/monitor/macprovider-monitor.py"
UNIT="$DIST_DIR/monitor/macprovider-monitor.service"
DEPLOY="$DIST_DIR/deploy-pearl-vps.sh"

grep -Fq 'StateDirectory=macprovider-monitor' "$UNIT"
grep -Fq 'os.environ.get("STATE_DIRECTORY", "/var/lib/macprovider-monitor")' "$MONITOR"
grep -Fq 'if [ -f /etc/macprovider/monitor.env ]; then' "$DEPLOY"
grep -Fq 'chown root:macprovider /etc/macprovider/monitor.env' "$DEPLOY"
grep -Fq 'chmod 0640 /etc/macprovider/monitor.env' "$DEPLOY"

state_file="$(STATE_DIRECTORY=/tmp/macprovider-monitor-test python3 - "$MONITOR" <<'PY'
import runpy
import sys

namespace = runpy.run_path(sys.argv[1], run_name="monitor_contract_test")
print(namespace["STATE_FILE"])
PY
)"

test "$state_file" = "/tmp/macprovider-monitor-test/monitor-state.json"
echo "PASS: monitor state and env permissions match the hardened systemd contract"
