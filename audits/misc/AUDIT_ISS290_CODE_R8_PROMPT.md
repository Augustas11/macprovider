## Lane: CODE — Round 8

## Context

R7 outcomes:
- CODE 0/0/1/0 (MED: rollback glob expanded in caller shell, blocked
  sudo-non-root operator case)
- SEC  0/0/0/0 — approve
- ARCH 0/2/0/0 (both HIGH known-deferred: C2 remote drift, drain
  boundary — unchanged since R5)

R7 fix-pass `e53d060`:
Wrapped the rollback `LATEST=$(...)` glob resolution in `sudo -u macprovider sh -c '...'`
so the glob expands inside the macprovider shell (which can traverse
0750 daemon-owned /var/lib/macprovider) rather than the caller's
sudo-capable non-root shell (which can't). Applied to both
OPS.md and the deploy-pearl-vps.sh printed recipe. Empty-match still
fails closed via `[ -n "$LATEST" ]` guard.

## Your job

CODE LANE round 8. Verify R7 MED is closed and no new gaps.

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss290/phase5-gateway/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss290/OPS.md`

R7→R8 diff: `git -C /Users/augstar/macprovider-iss290 show HEAD`
