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
# curl_bearer <token> <curl args...>: curl with "Authorization: Bearer
# <token>" read from a 0600 temp file (curl -H @file), so the token never
# appears in a process argv. The token reaches this shell function as an
# argument, which is not an exec. The body runs in a subshell whose EXIT
# trap removes the header file on every exit, a signal included.
curl_bearer() (
  tok="$1"; shift
  f="$(umask 077 && mktemp)" || exit 1
  trap 'rm -f "$f"' EXIT
  trap 'exit 130' INT TERM HUP
  printf 'Authorization: Bearer %s\n' "$tok" >"$f"
  curl -H @"$f" "$@"
)
# with_coordinator_env <command...>: run a command as macprovider with
# /etc/macprovider/coordinator.env loaded inside the child shell, so no
# credential is expanded into an argv (`env KEY=...` would list them).
with_coordinator_env() {
  sudo -u macprovider bash -c 'set -a; . /etc/macprovider/coordinator.env; set +a; exec "$@"' with_coordinator_env "$@"
}
# result <scenario> <PASS|FAIL|BUG|GAP|INFO> <message>
result() {
  python3 - "$1" "$2" "$3" >>"$E2E_EVIDENCE/results.jsonl" <<'PY'
import json, sys, datetime
print(json.dumps({"scenario": sys.argv[1], "result": sys.argv[2], "detail": sys.argv[3],
                  "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}))
PY
  log "[$1] $2: $3"
}
