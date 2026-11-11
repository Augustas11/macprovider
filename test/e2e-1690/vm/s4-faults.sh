#!/usr/bin/env bash
# S4 fault injection on the gateway->coordinator hop (new coordinator + new
# gateway): a proxy strips trailers / strips only the outcome declarations
# (MAC kept) / tampers a tuple value / drops the connection after the body,
# each with the pin off and on. Expected: held or refunded, never a wrong
# debit, and every hold reaches a terminal state via the reconciler.
# Then a coordinator store failure after delivery (exclusive SQLite lock on the
# billing DB while a non-streaming attempt records after its write).
set -uo pipefail
. /root/e2e/h/vm/lib.sh; . $E2E_H/vm/lib-deploy.sh; . $E2E_H/vm/lib-scn.sh
[ "$(cat /root/e2e/coordinator.side)/$(cat /root/e2e/gateway.side)" = new/new ] || die "S4 needs new/new"
install -o root -g root -m 0755 /root/e2e/bins/faultproxy /opt/macprovider/e2e-faultproxy
install -m 0644 $E2E_H/lib/e2e-faultproxy.service /etc/systemd/system/e2e-faultproxy.service
systemctl daemon-reload; systemctl restart e2e-faultproxy
gw_set coordinator.buyer_url http://127.0.0.1:8453
for pin in false true; do
  gw_set coordinator.require_settlement_trailers $pin; gw_restart
  for mode in pass strip-trailers strip-outcome tamper drop-after-body; do
    echo "$mode" >/run/e2e-faultproxy/mode
    tag="$(echo "$mode" | tr -d '-')"
    run="$(run_id "s4${tag}pin${pin:0:1}")"
    since="$(mark)"
    traffic "$run" "ns=3,st=3,st_dc=1"
    sleep 2
    h="$(holds_active)"
    journal_since macprovider-gateway "$since" "$E2E_EVIDENCE/$run.gateway.log"
    journal_since e2e-faultproxy "$since" "$E2E_EVIDENCE/$run.proxy.log"
    result "S4-$mode-pin=$pin" INFO "holds after traffic: $h; missing-finality lines: $(grep -c 'finality missing' "$E2E_EVIDENCE/$run.gateway.log")"
    DRAIN_MAX=600 settle_and_check "S4-$mode-pin=$pin" "$run"
  done
done
echo pass >/run/e2e-faultproxy/mode
gw_set coordinator.buyer_url http://127.0.0.1:8443; gw_set coordinator.require_settlement_trailers true; gw_restart
systemctl stop e2e-faultproxy

# --- coordinator store failure after delivery (enforce, pin on) ---------------
# Non-streaming responses are delayed 1.5 s by the fake provider; take an
# exclusive lock on the billing DB at +1.0 s for 15 s (> busy_timeout 5 s and
# requestLogWriteTimeout 6 s), so the post-write record/quarantine fail.
for n in 1 2; do
  run="$(run_id "s4storefail$n")"
  since="$(mark)"
  python3 - "$CDB" <<'PY' &
import sqlite3, sys, time
time.sleep(1.0)
c = sqlite3.connect(sys.argv[1], timeout=5, isolation_level=None)
c.execute("BEGIN EXCLUSIVE")
time.sleep(15)
c.execute("ROLLBACK")
PY
  lockpid=$!
  traffic "$run" "ns=1"
  wait "$lockpid" 2>/dev/null || true
  journal_since macprovider-coordinator "$since" "$E2E_EVIDENCE/$run.coordinator.log"
  journal_since macprovider-gateway "$since" "$E2E_EVIDENCE/$run.gateway.log"
  ev="$(grep -o '"event":"[a-z_]*"' "$E2E_EVIDENCE/$run.coordinator.log" | sort | uniq -c | tr '\n' ' ')"
  result "S4-store-failure-$n" INFO "coordinator events: $ev; buyer finality: $(grep -o '"buyer_finality":"[a-z]*"' "$E2E_EVIDENCE/$run.coordinator.log" | head -1)"
  DRAIN_MAX=600 settle_and_check "S4-store-failure-$n" "$run"
done
