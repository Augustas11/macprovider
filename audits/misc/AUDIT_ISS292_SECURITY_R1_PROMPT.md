## Lane: SECURITY — Round 1

## Context

Issue #292 closes a LOW-severity operator-local /tmp symlink-race
threat in coordinator deploy-pearl-vps.sh step 8. Predictable path
`/tmp/macprovider-catalog-current.json` on operator's Mac → mktemp.

Fix in commit `559f315`:
- `CATALOG_SMOKE_TMP=$(umask 077 && mktemp -t macprovider-catalog-current.XXXXXXXX)`
- 3 references switched to `"$CATALOG_SMOKE_TMP"` (curl -o, head -c error, python3 json.load)
- Cleanup added to the unconditional EXIT trap (#244 R6)

## Your job

SECURITY LANE round 1. Confirm the local symlink-race is closed and
no new attack surface is introduced.

## Files in scope

- `/Users/augstar/macprovider-iss292/phase4-coordinator/dist/deploy-pearl-vps.sh`

Diff: `git -C /Users/augstar/macprovider-iss292 show HEAD`
