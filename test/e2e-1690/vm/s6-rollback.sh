#!/usr/bin/env bash
# S6 rollback rehearsal, runbook section 9 "Rollback, in this order", run
# literally on the new/new (pin on) host left by S2/S4:
#   1 nginx 503 on the buyer routes (gateway stays up), verified with curl
#   2 drain settlement holds with the reconciler until the runbook's count is 0
#   3 pin off, restart the gateway
#   4 gateway rollback (pre-check, stop, named snapshot + binary, export rows
#     after the snapshot, recipe restore without start, re-apply, start),
#     then the coordinator rollback (pool-rollback-preflight gate first)
#   5 resume buyer traffic; ledger rows neither lost nor duplicated.
set -uo pipefail
. /root/e2e/h/vm/lib.sh; . $E2E_H/vm/lib-deploy.sh; . $E2E_H/vm/lib-scn.sh
[ "$(cat /root/e2e/coordinator.side)/$(cat /root/e2e/gateway.side)" = new/new ] || die "S6 starts from new/new"
EV=$E2E_EVIDENCE/p$PASS_ID-s6; mkdir -p "$EV"

# Pre-rollback traffic so the rollback has post-snapshot rows to carry.
run="$(run_id s6pre)"; traffic "$run" "ns=3,st=3"; drain "$run" 480 || true
snap_counts() {
  gwsql "SELECT 'usage_events', COUNT(*), COALESCE(SUM(total_tokens),0) FROM usage_events UNION ALL
         SELECT 'quota_reservations', COUNT(*), COALESCE(SUM(settled_tokens),0) FROM quota_reservations UNION ALL
         SELECT 'quota_settled', COUNT(*), COALESCE(SUM(settled_tokens),0) FROM quota_reservations WHERE status='settled' UNION ALL
         SELECT 'accounts', COUNT(*), 0 FROM accounts UNION ALL SELECT 'api_keys', COUNT(*), 0 FROM api_keys"
  csql "SELECT 'ledger_request_credits', COUNT(*), COALESCE(SUM(gross_credits),0) FROM ledger_request_credits"
}
snap_counts >"$EV/counts-before.txt"

# ---- 1. stop buyer traffic at nginx -------------------------------------------
grep -l 9443 /etc/nginx/sites-enabled/* >"$EV/sites-proxying-9443.txt"
nginx_block_buyers >"$EV/nginx-reload.txt" 2>&1
c1="$(curl -s -o /dev/null -w '%{http_code}' -X POST https://api.malibu.tech/v1/chat/completions)"
c2="$(curl -s -o /dev/null -w '%{http_code}' https://api.malibu.tech/healthz)"
c3="$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:9443/admin/settlement/reconcile)"
for p in /auth/x /account /docs /privacy; do printf '%s %s\n' "$p" "$(curl -s -o /dev/null -w '%{http_code}' https://api.malibu.tech$p)"; done >"$EV/nginx-503-routes.txt"
[ "$c1" = 503 ] && [ "$c2" = 200 ] && result S6-step1-nginx-503 PASS "chat=503 healthz=200 gateway-local-admin=$c3; $(tr '\n' ' ' <"$EV/nginx-503-routes.txt")" \
  || result S6-step1-nginx-503 FAIL "chat=$c1 healthz=$c2 (expected 503/200)"
for i in $(seq 1 24); do [ -s "$EV/outside-curl.done" ] && break; sleep 5; done; result S6-step1-outside-curl INFO "$(cat "$EV/outside-curl.txt" 2>/dev/null || echo "no host curl recorded (host driver not running)")"

# ---- 2. drain holds -------------------------------------------------------------
t=0
until [ "$(gwsql "SELECT COUNT(*) FROM quota_reservations WHERE status = 'active' AND settlement_hold = 1")" = 0 ] || [ $t -ge 600 ]; do
  curl_bearer "$(opkey)" -s -X POST http://127.0.0.1:9443/admin/settlement/reconcile >>"$EV/reconcile.txt"; echo >>"$EV/reconcile.txt"
  sleep 10; t=$((t+10))
done
hc="$(gwsql "SELECT COUNT(*) FROM quota_reservations WHERE status = 'active' AND settlement_hold = 1")"
[ "$hc" = 0 ] && result S6-step2-drain PASS "holds drained to 0 in ${t}s" || result S6-step2-drain FAIL "$hc holds left after ${t}s"

# ---- 3. pin off -------------------------------------------------------------------
gw_set coordinator.require_settlement_trailers false; gw_restart
result S6-step3-pin-off PASS "require_settlement_trailers=false, gateway restarted"

# ---- 4a. gateway rollback -----------------------------------------------------------
pre="$(gwsql "SELECT COUNT(*) FROM usage_events WHERE token_source = 'pool_operator_attested'")"
echo "$pre" >"$EV/precheck.txt"
if [ "$pre" != 0 ]; then
  result S6-step4-gw-precheck PASS "pre-check forbids the gateway rollback: $pre pool_operator_attested rows (roll forward)"
else
  result S6-step4-gw-precheck INFO "pre-check count 0: gateway rollback allowed"
  systemctl stop macprovider-gateway
  SNAP="$(cat /root/e2e/gw-snapshot-rollout.path)"
  [ -n "$SNAP" ] && [ -f "$SNAP" ] || die "no named v14-deploy snapshot recorded"
  want="$(sha256sum /root/e2e/bins/old/gateway-linux-amd64 | cut -d' ' -f1)"
  have="$(sha256sum /opt/macprovider/gateway.prev | cut -d' ' -f1)"
  if [ "$want" = "$have" ]; then BIN=/opt/macprovider/gateway.prev; binnote="gateway.prev matches the pre-v14 release"
  else BIN=/root/e2e/bins/old/gateway-linux-amd64; binnote="gateway.prev ($have) is NOT the pre-v14 release ($want): installing the release binary explicitly"; fi
  result S6-step4-gw-inputs INFO "snapshot=$SNAP binary: $binnote"
  ts="$(basename "$SNAP" | sed -E 's/.*pre-deploy\.([0-9]{8})T([0-9]{2})([0-9]{2})([0-9]{2})Z/\1 \2:\3:\4/')"
  SNAP_ISO="$(date -u -d "$ts" +%Y-%m-%dT%H:%M:%SZ)"
  echo "$SNAP_ISO" >"$EV/snapshot-ts.txt"
  gwsql ".tables" >"$EV/gateway-tables.txt"
  python3 $E2E_H/tools/gw-rollback-export.py "$GWDB" "$SNAP_ISO" "$EV/export.sql" >"$EV/export-summary.txt" 2>&1 \
    || result S6-step4-gw-export FAIL "export failed: $(tail -3 "$EV/export-summary.txt")"
  result S6-step4-gw-export INFO "$(tr '\n' ' ' <"$EV/export-summary.txt" | head -c 600)"
  # printed recipe, with the named snapshot and binary, without the start:
  sudo -u macprovider test -r "$SNAP" && sudo -u macprovider sqlite3 "$SNAP" "PRAGMA integrity_check;" | head -1 | grep -q '^ok$' || die "snapshot unreadable"
  install -o root -g macprovider -m 0750 "$BIN" /opt/macprovider/gateway
  rm -f "$GWDB-wal" "$GWDB-shm"
  install -o macprovider -g macprovider -m 0600 "$SNAP" "$GWDB"
  sudo -u macprovider sqlite3 "$GWDB" "PRAGMA integrity_check;" >"$EV/restore-integrity.txt"
  # re-apply
  if sudo -u macprovider sqlite3 -bail "$GWDB" <"$EV/export.sql" >"$EV/reapply.txt" 2>&1; then
    result S6-step4-gw-reapply PASS "re-applied $(grep -c '^INSERT' "$EV/export.sql") rows"
  else result S6-step4-gw-reapply FAIL "re-apply failed: $(tail -3 "$EV/reapply.txt" | tr '\n' ' ')"; fi
  result S6-step4-gw-quota-totals GAP "runbook: 'reconcile daily quota totals for the affected accounts' names no table or command; see plan"
  systemctl start macprovider-gateway
  for i in $(seq 1 60); do gw_healthz >/dev/null 2>&1 && break; sleep 1; done
  if gw_healthz >/dev/null 2>&1; then echo old >/root/e2e/gateway.side; result S6-step4-gw-start PASS "old gateway healthy: $(gw_healthz | head -c 160)"
  else journalctl -u macprovider-gateway -n 30 --no-pager >"$EV/gateway-start-fail.txt"; result S6-step4-gw-start FAIL "old gateway did not start: $(tail -3 "$EV/gateway-start-fail.txt" | tr '\n' ' ')"; fi
fi

# ---- 4b. coordinator rollback ---------------------------------------------------------
# Literal runbook command first (config path as written), then the path the
# live Pearl config actually has. (At d5dd3334 the subcommand took no
# --config-overlay; F-6 added it.)
/opt/macprovider/coordinator pool-rollback-preflight --config /etc/macprovider/coordinator.yaml >"$EV/preflight-literal.txt" 2>&1; rc1=$?
with_coordinator_env /opt/macprovider/coordinator pool-rollback-preflight \
  --config /opt/macprovider/coordinator.yaml >"$EV/preflight-pearl.txt" 2>&1; rc2=$?
result S6-step4-coord-preflight INFO "literal (--config /etc/macprovider/coordinator.yaml) rc=$rc1: $(head -c 200 "$EV/preflight-literal.txt" | tr '\n' ' '); --config /opt/macprovider/coordinator.yaml rc=$rc2: $(head -c 300 "$EV/preflight-pearl.txt" | tr '\n' ' ')"
[ "$rc2" = 0 ] || result S6-step4-coord-preflight-gate FAIL "gate exits $rc2 with no pool ever created"
since="$(mark)"
if (coord_install old) >"$EV/coord-rollback.txt" 2>&1; then result S6-step4-coord-rollback PASS "old coordinator healthy on the migrated DB"
else result S6-step4-coord-rollback FAIL "old coordinator failed on the migrated DB: $(tail -5 "$EV/coord-rollback.txt" | tr '\n' ' ')"; fi
journal_since macprovider-coordinator "$since" "$EV/coordinator-after-rollback.log"
wait_providers 2 || result S6-step4-providers FAIL "providers did not reconnect after the coordinator rollback"

# ---- 5. resume buyer traffic -------------------------------------------------------------
nginx_unblock_buyers >/dev/null 2>&1
c="$(curl -s -o /dev/null -w '%{http_code}' https://api.malibu.tech/healthz)"
snap_counts >"$EV/counts-after-rollback.txt"
# Rows added by the rolled-back-to coordinator's startup scan are reported,
# not counted as a loss, as long as none of them is payable.
added="$(csql "SELECT COUNT(*) || ' startup_scan rows, payable=' || (SELECT COUNT(*) FROM spec022_payable_request_credits p WHERE p.recovery_source='startup_scan') FROM ledger_request_credits WHERE recovery_source='startup_scan'")"
python3 - "$EV/counts-before.txt" "$EV/counts-after-rollback.txt" >"$EV/counts-diff.txt" <<'PY2'
import sys
a = dict((l.split("|")[0], l.strip().split("|")[1:]) for l in open(sys.argv[1]) if "|" in l)
b = dict((l.split("|")[0], l.strip().split("|")[1:]) for l in open(sys.argv[2]) if "|" in l)
bad = [k for k in a if a[k] != b.get(k) and k != "ledger_request_credits"]
lost = int(b["ledger_request_credits"][0]) < int(a["ledger_request_credits"][0])
for k in a: print(k, a[k], b.get(k), "" if a[k] == b.get(k) else "<-- CHANGED")
sys.exit(1 if bad or lost else 0)
PY2
[ $? = 0 ] && result S6-no-rows-lost PASS "gateway rows/sums identical, no ledger row lost ($added): $(tr '\n' ';' <"$EV/counts-diff.txt")" \
  || result S6-no-rows-lost FAIL "rows changed across the rollback ($added): $(tr '\n' ';' <"$EV/counts-diff.txt")"
echo "$added" | grep -q 'payable=0' || result S6-startup-scan-payable FAIL "old coordinator startup scan created payable rows: $added"
run="$(run_id s6post)"; traffic "$run"
settle_and_check S6-after-rollback "$run" --expect ns=settled,st=settled
