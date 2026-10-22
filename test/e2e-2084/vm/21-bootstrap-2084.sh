#!/usr/bin/env bash
# VM step 21 (after the shared 20-bootstrap.sh, old/old): the #2084 host state.
#   - provider tokens for the fake shard group (head, stage member, spare, a
#     second owner's Mac) and the scenario-R real Swift head and member;
#   - SPEC-003 ownership claims: the result of the GitHub claim flow
#     (github_identities + provider_ownership rows; the VM cannot reach GitHub
#     OAuth, deviation D2): head, member, spare and both real providers owned
#     by one GitHub identity, e2e-prov-14 by another;
#   - receipt / admission key seed files (generated here, never printed).
set -euo pipefail
. /root/e2e/h/vm/lib.sh; . $E2E_H/vm/lib-deploy.sh; . $E2E_H/vm/lib-scn.sh; . /root/e2e/h16/vm/lib-1816.sh; . /root/e2e/h84/vm/lib-2084.sh
systemctl stop 'e2e-shardprov@*' 2>/dev/null || true
rm -rf $SG_DIR $E2E_POOLS /root/e2e/receipt-key-e2e-* /root/e2e/admission-key-e2e-* /root/e2e/shardprov-*.env /root/e2e/shard-epoch
log "2084: provider tokens"
for p in $SHARD_IDS $RHEAD $RM1; do
  for t in 1 2 3 4 5 6 7 8 9 10; do out="$(/opt/macprovider/coordinator-cli issue-token -db $CDB -provider-id $p -provider-name $p 2>&1)" && break; sleep 3; done
  printf '%s\n' "$out" | sed -n 's/^token=//p' >/root/e2e/token-$p; chmod 600 /root/e2e/token-$p
  [ -s /root/e2e/token-$p ] || die "issue-token $p failed: $out"
done
log "2084: ownership claims"
csql "INSERT OR IGNORE INTO github_identities(github_user_id, github_login) VALUES ($OWNER_GH, 'e2e-2084-owner'), ($OTHER_GH, 'e2e-2084-other');
      INSERT OR REPLACE INTO provider_ownership(provider_id, github_user_id) VALUES ('$HEAD',$OWNER_GH),('$M1',$OWNER_GH),('$SPARE',$OWNER_GH),('$RHEAD',$OWNER_GH),('$RM1',$OWNER_GH),('$OTHER',$OTHER_GH);"
chown -R macprovider:macprovider /var/lib/macprovider
install -o root -g root -m 0755 /root/e2e/bins/fakeprov /opt/macprovider/e2e-fakeprov
shardprov_unit
log "2084 bootstrap ok: $(csql "SELECT group_concat(provider_id||'='||github_user_id, ' ') FROM provider_ownership")"
