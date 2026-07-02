## Lane: CODE — Round 4

## Context

R3 outcomes:
- CODE 0/2/2/1
- SEC  0/2/1/1
- ARCH 0/0/2/1

R3 fix-pass `211c1ed`:
1. **WAL sidecar cleanup** on rollback (both OPS.md and script's
   printed rollback). Closes CODE R3 HIGH (SQLite-verified).
2. **In-flight guard fails CLOSED** on missing/unparseable metric.
   INFLIGHT can now be a positive integer or the literal "unknown".
   FORCE_RESTART=1 audit tombstone covers both cases. Closes SEC R3
   HIGH + CODE R3 MED.
3. **OPS.md step numbers** rewritten to 2c/2d ordering. Closes
   3-of-3 convergent MED.
4. Stale prune comment updated to reflect Python implementation.

Deferred:
- Drain boundary (SEC R3 HIGH): request-pause needs endpoint work
- C2 remote drift (CODE R3 HIGH + SEC R3 MED): applies to coord too

## Your job

CODE LANE round 4. Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss290/phase5-gateway/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss290/OPS.md`

R3→R4 diff: `git -C /Users/augstar/macprovider-iss290 show HEAD`
