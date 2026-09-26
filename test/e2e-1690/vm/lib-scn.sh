# shellcheck shell=bash
# Scenario helpers: buyer traffic, reconcile drain, oracle, evidence capture.
# Source after lib.sh and lib-deploy.sh. PASS_ID (1|2) tags every run id.
PASS_ID="${PASS_ID:-1}"
MODEL="${E2E_MODEL:-meta-llama/llama-3.2-3b-instruct}"

run_id() { echo "p${PASS_ID}$1"; }   # e.g. p1s1

# traffic <run-id> [mix]: buyer traffic through nginx; returns loadgen summary.
traffic() {
  local run="$1" mix="${2:-ns=4,st=4,st_dc=2,ns_dc=2,ns_over=1}"; shift 2 2>/dev/null || shift $#
  rm -f "$E2E_EVIDENCE/$run.load.jsonl"
  python3 $E2E_H/tools/loadgen.py --run "$run" --out "$E2E_EVIDENCE/$run.load.jsonl" --model "$MODEL" --mix "$mix" "$@" \
    | tee "$E2E_EVIDENCE/$run.load.summary.json"
}

holds_active() { gwsql "SELECT COUNT(*) FROM quota_reservations WHERE status='active' AND settlement_hold=1"; }
reservations_active() {
  local ids; ids="$(python3 -c 'import json,sys;print(",".join("\x27%s\x27" % json.loads(l)["rid"] for l in open(sys.argv[1])))' "$E2E_EVIDENCE/$1.load.jsonl" 2>/dev/null)"
  gwsql "SELECT COUNT(*) FROM quota_reservations WHERE status='active' AND request_id IN (${ids:-''})"
}
reconcile_once() {
  curl_bearer "$(opkey)" -sS -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:9443/admin/settlement/reconcile
}
# drain <run-id> [max-seconds]: poke the reconciler (runbook rollback step 2
# command) until no reservation of the run is active and no hold remains.
drain() {
  local run="$1" max="${2:-480}" t=0 a h
  while :; do
    a="$(reservations_active "$run")"; h="$(holds_active)"
    [ "$a" = 0 ] && [ "$h" = 0 ] && { log "drain $run: clean after ${t}s"; return 0; }
    [ "$t" -ge "$max" ] && { log "drain $run: TIMEOUT after ${t}s active=$a holds=$h"; return 1; }
    reconcile_once >/dev/null || true
    sleep 10; t=$((t + 10))
  done
}
# check <run-id> [oracle args...]: oracle report to evidence; returns its status.
check() {
  local run="$1"; shift
  python3 $E2E_H/tools/oracle.py --allow "${ORACLE_ALLOW:-I5}" --prefix "$run" --load "$E2E_EVIDENCE/$run.load.jsonl" --out "$E2E_EVIDENCE/$run.oracle.json" "$@" | tee "$E2E_EVIDENCE/$run.oracle.txt"
  return "${PIPESTATUS[0]}"
}
# settle_and_check <scenario-label> <run-id> [oracle args]: drain + oracle + result line.
settle_and_check() {
  local label="$1" run="$2"; shift 2
  local d=0 c=0
  drain "$run" "${DRAIN_MAX:-480}" || d=1
  check "$run" "$@" || c=1
  if [ $d = 0 ] && [ $c = 0 ]; then result "$label" PASS "run $run: $(head -1 "$E2E_EVIDENCE/$run.oracle.txt")"
  else result "$label" FAIL "run $run drain=$d oracle=$c: $(head -6 "$E2E_EVIDENCE/$run.oracle.txt" | tr '\n' ' ')"; fi
  return $((d + c))
}
# journal_since <unit> <since> <out>
journal_since() { journalctl -u "$1" --since "$2" --no-pager -o cat >"$3" 2>/dev/null || true; }
mark() { date -u '+%Y-%m-%d %H:%M:%S'; }

# probe_finality <label> [stream]: one chat straight at the coordinator the way
# the gateway sends it (service token, account, request id, capability) and
# save headers + trailers (curl --raw shows chunked trailers).
probe_finality() {
  local label="$1" stream="${2:-false}" acct gst
  acct="$(gwsql "SELECT account_id FROM accounts LIMIT 1")"
  gst="$(sed -n 's/^GATEWAY_SERVICE_TOKEN=//p' /etc/macprovider/coordinator.env)"
  curl_bearer "$gst" -sS --raw -D "$E2E_EVIDENCE/probe-$label.headers" -o "$E2E_EVIDENCE/probe-$label.body" \
    -H "X-MacProvider-Account: $acct" -H "X-Request-ID: probe-$label-$(date +%s)" \
    -H "X-MacProvider-Internal-Settlement-Trailers: 1" -H 'Content-Type: application/json' -H 'TE: trailers' \
    -d "{\"model\":\"$MODEL\",\"stream\":$stream,\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"probe\"}]}" \
    http://127.0.0.1:8443/v1/chat/completions
  grep -i '^trailer\|x-macprovider-settlement' "$E2E_EVIDENCE/probe-$label.headers" | tr -d '\r'
  grep -ai 'x-macprovider-settlement' "$E2E_EVIDENCE/probe-$label.body" | tr -d '\r'
}
