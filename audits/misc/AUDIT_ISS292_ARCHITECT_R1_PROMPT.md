## Lane: ARCHITECT — Round 1

## Context

Issue #292 closes a LOW-severity operator-local /tmp symlink-race
threat in coordinator deploy-pearl-vps.sh step 8.

Fix in commit `559f315`:
- Predictable /tmp path → `mktemp -t macprovider-catalog-current.XXXXXXXX`
- Wrapped in `umask 077` for 0600 perms
- Cleanup added to unconditional EXIT trap registered at line 254 (#244 R6)

## Your job

ARCHITECT LANE round 1. Consider trap ordering, error-path coverage,
and consistency with the coordinator script's other mktemp uses
(`TMP_CATALOG_PUBKEY`, `DEPLOY_TMP`).

## Files in scope

- `/Users/augstar/macprovider-iss292/phase4-coordinator/dist/deploy-pearl-vps.sh`

Diff: `git -C /Users/augstar/macprovider-iss292 show HEAD`
