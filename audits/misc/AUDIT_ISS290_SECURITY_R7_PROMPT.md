## Lane: SECURITY — Round 7

## Context

R6 outcomes:
- CODE 0/1/1/0 (HIGH known-deferred C2 remote drift; MED script rollback stale)
- SEC  0/0/0/0 — approve
- ARCH 0/0/1/0 (MED convergent script/OPS.md rollback divergence)

R6 fix-pass `7be1b29`: script-only, aligned printed rollback recipe with
OPS.md canonical (adds `sudo`, `sudo -u macprovider` validation,
`sudo test -x /opt/macprovider/gateway.prev` precheck, healthz curl).

## Your job

SECURITY LANE round 7. The R6 fix touched an operator-copyable printed
recipe that includes privilege operations (sudo, sudo -u macprovider,
systemctl stop, install). Verify no new escalation, injection, or
race-condition surface was introduced by the alignment.

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss290/phase5-gateway/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss290/OPS.md`

R6→R7 diff: `git -C /Users/augstar/macprovider-iss290 show HEAD`
