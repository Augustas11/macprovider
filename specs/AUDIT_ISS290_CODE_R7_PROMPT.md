## Lane: CODE — Round 7

## Context

R6 outcomes:
- CODE 0/1/1/0 (HIGH known-deferred C2 remote drift; MED script-printed
  rollback recipe stale vs. OPS.md canonical)
- SEC  0/0/0/0 — approve
- ARCH 0/0/1/0 (MED same convergent rollback recipe divergence)

R6 fix-pass `7be1b29` (script-only, echo lines 490-514):
Aligned the post-deploy printed rollback recipe with the R5 OPS.md
canonical: `sudo -u macprovider ls`, `sudo -u macprovider test -f/-r`,
`sudo test -x /opt/macprovider/gateway.prev` BEFORE `systemctl stop`,
sudo prefix on all state-changing commands, trailing healthz curl.

Deferred (unchanged): drain boundary, C2 remote drift.

## Your job

CODE LANE round 7. Verify convergence + any remaining gaps introduced by
the script/OPS.md alignment.

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss290/phase5-gateway/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss290/OPS.md`

R6→R7 diff: `git -C /Users/augstar/macprovider-iss290 show HEAD`
