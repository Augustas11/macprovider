#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

PORT="${MACPROVIDER_PORT:-18092}"
LOG_FILE="/private/tmp/macprovider-health-$PORT.log"
trap stop_provider EXIT
start_provider "$PORT" "" "$LOG_FILE"
wait_http "$PORT" /v1/health

python3 - "$PORT" <<'PY'
import json
import sys
import urllib.request

port = sys.argv[1]
with urllib.request.urlopen(f"http://127.0.0.1:{port}/v1/health", timeout=5) as response:
    data = json.loads(response.read().decode())
assert response.status == 200, data
for key in ("status", "model", "uptime_s", "requests_in_flight", "requests_queued", "capacity"):
    assert key in data, data
assert "max_concurrency" in data["capacity"], data
assert data["status"] in ("ready", "busy"), data
print(json.dumps({"ok": True, "status": data["status"], "capacity": data["capacity"]}))
PY
