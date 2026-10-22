#!/usr/bin/env bash
# U: rollout order (SPEC-051-R027, PR body "Rollout and deploy"): coordinator
# first, on the old/old Pearl-shaped host left by the bootstrap.
#   1. old/old catalog traffic settles (reference);
#   2. NEW coordinator by the deploy-shaped binary swap on the production
#      SQLite file: the shard group tables are created by the startup
#      migration, every pre-existing ledger/request-log row is intact, the old
#      gateway keeps settling catalog traffic;
#   3. rollback rehearsal: the OLD coordinator starts on the migrated file and
#      serves, then the new one again (a rollback after the deploy is safe);
#   4. NEW gateway through the real deploy-pearl-vps.sh; catalog traffic
#      settles on the new pair.
set -uo pipefail
. /root/e2e/h/vm/lib.sh; . $E2E_H/vm/lib-deploy.sh; . $E2E_H/vm/lib-scn.sh; . /root/e2e/h16/vm/lib-1816.sh; . /root/e2e/h84/vm/lib-2084.sh
EV=$E2E_EVIDENCE/p$PASS_ID-u; mkdir -p "$EV"
[ "$(sides)" = old/old ] || die "U needs old/old"
run="$(run_id u-oldold)"; traffic "$run" "ns=3,st=3" >/dev/null
settle_and_check U-oldold-catalog "$run" --expect ns=settled,st=settled
counts() { csql "SELECT (SELECT COUNT(*) FROM request_log)||'/'||(SELECT COUNT(*) FROM ledger_request_credits)||'/'||(SELECT COUNT(*) FROM settlement_receipt_verdicts)"; }
before="$(counts)"
csql ".tables" | tr -s ' \n' '\n' | grep -c '^shard_group' >"$EV/shard-tables-before.txt" || true
coord_install new >"$EV/coord-new.txt" 2>&1 && result U-coordinator-new-healthy PASS "new coordinator healthy on the production-shaped SQLite file ($(coord_healthz | head -c 160))" \
  || { result U-coordinator-new-healthy FAIL "$(tail -5 "$EV/coord-new.txt" | tr '\n' ' ')"; exit 1; }
tables="$(csql "SELECT group_concat(name, ',') FROM sqlite_master WHERE type='table' AND name LIKE 'shard_group%'")"
after="$(counts)"
if [ "$tables" = "shard_group_records,shard_group_member_bindings,shard_group_attestations" ] && [ "$before" = "$after" ] && [ "$(cat "$EV/shard-tables-before.txt")" = 0 ]; then
  result U-migration PASS "startup migration created $tables; request_log/ledger/verdict counts unchanged ($before)"
else result U-migration FAIL "tables=[$tables] before=$(cat "$EV/shard-tables-before.txt") counts before=$before after=$after"; fi
wait_providers 2 || true
run="$(run_id u-newold)"; traffic "$run" "ns=3,st=3" >/dev/null
settle_and_check U-newcoord-oldgw-catalog "$run" --expect ns=settled,st=settled
# rollback rehearsal on the migrated file
if coord_install old >"$EV/coord-rollback.txt" 2>&1; then
  wait_providers 2 || true
  run="$(run_id u-rollback)"; traffic "$run" "ns=2,st=2" >/dev/null
  settle_and_check U-rollback-old-on-migrated-db "$run" --expect ns=settled,st=settled
else result U-rollback-old-on-migrated-db FAIL "old coordinator did not start on the migrated DB: $(tail -5 "$EV/coord-rollback.txt" | tr '\n' ' ')"; fi
coord_install new >"$EV/coord-new2.txt" 2>&1 || { result U-coordinator-new-again FAIL "$(tail -5 "$EV/coord-new2.txt" | tr '\n' ' ')"; exit 1; }
gw_deploy new >"$EV/gw-new.txt" 2>&1 && result U-gateway-new PASS "gateway deployed by the real deploy-pearl-vps.sh after the coordinator" \
  || { result U-gateway-new FAIL "$(tail -8 "$EV/gw-new.txt" | tr '\n' ' ')"; exit 1; }
wait_providers 2 || true
run="$(run_id u-newnew)"; traffic "$run" "ns=3,st=3" >/dev/null
settle_and_check U-newnew-catalog "$run" --expect ns=settled,st=settled
