## Lane: CODE — Round 1

## Context

Issue #292: `phase4-coordinator/dist/deploy-pearl-vps.sh` step 8
(`/catalog/current` smoke check) wrote to a predictable
`/tmp/macprovider-catalog-current.json` on the OPERATOR'S Mac. A local
attacker on the workstation could pre-place a symlink at that path to
redirect the write. LOW severity — deferred from #244 R6/R7 CODE+SEC
lanes. This PR closes it as a small ride-along.

Fix in commit `559f315`:
- Replace 3 refs to `/tmp/macprovider-catalog-current.json` with
  `"$CATALOG_SMOKE_TMP"` where
  `CATALOG_SMOKE_TMP=$(umask 077 && mktemp -t macprovider-catalog-current.XXXXXXXX)`
- Cleanup added to the existing unconditional EXIT trap (#244 R6)

## Your job

CODE LANE round 1. Standard severity-graded findings for the small change.

## Files in scope

- `/Users/augstar/macprovider-iss292/phase4-coordinator/dist/deploy-pearl-vps.sh`

Diff: `git -C /Users/augstar/macprovider-iss292 show HEAD`
