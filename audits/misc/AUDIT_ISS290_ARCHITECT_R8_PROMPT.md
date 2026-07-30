## Lane: ARCHITECT — Round 8

## Context

R7 outcomes:
- CODE 0/0/1/0 (MED: rollback glob expansion caller-shell bug)
- SEC  0/0/0/0 — approve
- ARCH 0/2/0/0 (both HIGH known-deferred: C2 remote drift, drain
  boundary — unchanged since R5)

R7 fix-pass `e53d060`: wrapped the rollback glob resolution in
`sudo -u macprovider sh -c '...'` so it expands inside the macprovider
shell. Applied to both OPS.md canonical and the deploy-pearl-vps.sh
printed rollback recipe.

## Your job

ARCHITECT LANE round 8. Verify:
1. The R7 CODE MED (glob caller-shell) is structurally closed
2. No new architectural regression from the sh-c wrapper
3. C2 drift + drain boundary remain the only outstanding deferred HIGHs

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss290/phase5-gateway/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss290/OPS.md`

R7→R8 diff: `git -C /Users/augstar/macprovider-iss290 show HEAD`
