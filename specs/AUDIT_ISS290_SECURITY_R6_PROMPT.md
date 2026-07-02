## Lane: SECURITY — Round 6

## Context

R5 outcomes:
- CODE 0/1/0/0 (HIGH known-deferred C2 remote)
- SEC  0/0/0/0 — approve
- ARCH 0/1/1/0 (HIGH rollback chain; MED sudo/non-sudo inconsistency)

R5 fix-pass `55bf31b` (OPS.md-only):
1. Rollback blocks converted to `&&`-chained pipelines. Any failure
   aborts. Closes ARCH R5 HIGH.
2. `sudo -u macprovider test -f/-r` for consistent privilege matching
   the real reader. Closes ARCH R5 MED.
3. Belt-and-braces `sudo test -x .../gateway.prev` before stop.

Deferred (unchanged): drain boundary, C2 remote drift.

## Your job

SECURITY LANE round 6. Verify convergence + any remaining gaps.

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss290/phase5-gateway/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss290/OPS.md`

R5→R6 diff: `git -C /Users/augstar/macprovider-iss290 show HEAD`
