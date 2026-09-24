#!/usr/bin/env bash
# V12: D1a wholesale statement for the E2 buyer account over the period that
# spans V1 + V4 + V5 (and every other generation this VM billed): each line's
# gross must equal an independent per-generation recompute from the real
# ledger (oracle.py statement-check). Run twice: regeneration is stable (O4:
# the same rows price the same after later changes).
set -euo pipefail
. "$(dirname "$0")/../env.sh"
. "$E2E_HARNESS/lib/common.sh"
e2e_write_ssh_config; e2e_push_tools
acct="$(vm "sqlite3 /var/lib/macprovider/request-log.sqlite \"select account_id from request_log where status=200 and account_id is not null group by account_id order by count(*) desc limit 1\"")"
period="$(date -u +%Y-%m)"
gens="$(vm "sqlite3 /var/lib/macprovider/request-log.sqlite 'select count(*) from ledger_config_snapshots'")"
v1="$(vm "python3 /root/e2e/tools/oracle.py statement-check '$acct' '$period' /root/e2e/stmt-1.json" | tail -n 1 || true)"
v2="$(vm "python3 /root/e2e/tools/oracle.py statement-check '$acct' '$period' /root/e2e/stmt-2.json" || true)"
same="$(vm "python3 -c 'import json;a,b=(json.load(open(f)) for f in (\"/root/e2e/stmt-1.json\",\"/root/e2e/stmt-2.json\"));[x.pop(\"generated_at_utc\",None) for x in (a,b)];print(a==b)'")"
printf '%s\n%s\n' "$v1" "$v2" >"$E2E_EVIDENCE/V12-statement-check.json"
if python3 -c 'import json,sys;sys.exit(0 if json.loads(sys.argv[1])["ok"] else 1)' "$v1" && [ "$same" = True ]; then
  e2e_result V12 PASS "account $acct $period over $gens billing generations: every line = per-generation recompute; regeneration identical; $v1"
else
  e2e_result V12 FAIL "account $acct $period ($gens generations): $v1 | regeneration identical=$same"
fi
