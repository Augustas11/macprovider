#!/usr/bin/env bash
# R (VM half): pool R for the real Swift shard group run from the host Mac.
#   r-pool.sh <artifact-hash>   -> prints "POOL_ID=<id> POOL_MODEL=<pool model id>"
# Native entry real-r for the lab copy's snapshot hash, pool_shard_groups/v1
# naming e2e-real-head (max_members 2), members e2e-real-head and e2e-real-m1,
# signed by coordinator-cli like pool S. Idempotent: an existing pool R is kept.
set -euo pipefail
. /root/e2e/h/vm/lib.sh; . $E2E_H/vm/lib-deploy.sh; . $E2E_H/vm/lib-scn.sh; . /root/e2e/h16/vm/lib-1816.sh; . /root/e2e/h84/vm/lib-2084.sh
H_REAL="${1:?artifact hash}"
ACCT="$(gwsql "SELECT account_id FROM accounts LIMIT 1")"
if [ ! -s "$E2E_POOLS/R/pool_id" ]; then
  $PM init R --allowlist "" >/dev/null
  $PM stage R --add real-r macprovider.snapshot-manifest.v1 "$H_REAL" mlx_cache $S_RATES 8192 >/dev/null
  $PM stage R --shard-group $RHEAD real-r 2 >/dev/null
  $PM create R --members $RHEAD,$RM1 --buyer "$ACCT" >/root/e2e/logs/r-pool-create.txt 2>&1 || { tail -3 /root/e2e/logs/r-pool-create.txt >&2; exit 1; }
fi
systemctl is-active --quiet e2e-1816-keeper || keeper_on
echo "POOL_ID=$(pool_id R) POOL_MODEL=$(pmid R real-r)"
