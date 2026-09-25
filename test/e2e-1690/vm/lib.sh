# shellcheck shell=bash
# In-VM helpers (run as root inside the fake-Pearl VM).
E2E=/root/e2e
E2E_H=$E2E/h
E2E_LOGS=$E2E/logs
E2E_EVIDENCE=$E2E/evidence
mkdir -p "$E2E_LOGS" "$E2E_EVIDENCE"
export GOTOOLCHAIN=auto
log() { printf '[vm %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { printf '[vm] FATAL: %s\n' "$*" >&2; exit 1; }
GWDB=/var/lib/macprovider/gateway.db
CDB=/var/lib/macprovider/request-log.sqlite
gwsql() { sqlite3 -cmd '.timeout 5000' "$GWDB" "$@"; }
csql() { sqlite3 -cmd '.timeout 5000' "$CDB" "$@"; }
opkey() { sed -n 's/^OPERATOR_KEY=//p' /etc/macprovider/coordinator.env; }
# result <scenario> <PASS|FAIL|BUG|GAP|INFO> <message>
result() {
  python3 - "$1" "$2" "$3" >>"$E2E_EVIDENCE/results.jsonl" <<'PY'
import json, sys, datetime
print(json.dumps({"scenario": sys.argv[1], "result": sys.argv[2], "detail": sys.argv[3],
                  "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}))
PY
  log "[$1] $2: $3"
}
