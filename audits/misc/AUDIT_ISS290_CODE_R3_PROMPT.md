## Lane: CODE — Round 3

## Context

R2 outcomes:
- CODE 0/3/1/0 (3 HIGH + 1 MED)
- SEC  0/1/1/0
- ARCH 0/1/2/0

R2 fix-pass `d6ed9ef`:
1. MOVED in-flight guard to step 2c (pre-scp) + DB snapshot to
   step 2d (pre-binary-swap). Closes convergent rollback-safety HIGH.
2. Snapshot pruning rewritten as macprovider Python with strict
   regex pattern check. Closes CODE HIGH filename-injection.
3. OPS.md rollback rewritten: schema-aware DEFAULT; binary-only
   explicitly gated behind "no schema bump" note.
4. Nginx template pre-flight grep assertion of server_name + cert path.
5. Deferred: C2 remote-config drift check (applies to coord too).

## Your job

CODE LANE round 3. Verify convergence + remaining gaps.

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss290/phase5-gateway/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss290/OPS.md`

R2→R3 diff: `git -C /Users/augstar/macprovider-iss290 show HEAD`
