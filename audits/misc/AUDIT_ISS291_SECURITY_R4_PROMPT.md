## Lane: SECURITY — Round 4

## Context

R3 outcomes:
- CODE 0/0/0/0 PASS at R2, skipped R3 (scope unchanged)
- SEC  0/0/1/1 — MED: DIST_DIR still uses logical `$0` + plain `pwd`
- ARCH 0/0/0/0 PASS at R2, skipped R3

R3 fix-pass `bbfa59b`:
- `DIST_DIR="$_PEARL_TLS_SCRIPT_DIR"` — reuses the physically-
  resolved path so a parent-DIR symlink cannot redirect deploy
  artifact reads/uploads
- T25e static regression guard on the assignment shape
- T25f end-to-end driver via parent-alias symlink proves
  DIST_DIR settles on the physical real path

89/89 tests pass.

## Your job

SECURITY LANE round 4. Verify all symlink-related surfaces are
closed. Any other logical-path recomputation site in
deploy-pearl-vps.sh that could be exploited the same way.

## Files in scope

- `/Users/augstar/macprovider-iss291/phase4-coordinator/dist/lib/pearl_tls.sh`
- `/Users/augstar/macprovider-iss291/phase4-coordinator/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss291/phase4-coordinator/dist/test/check_pearl_tls_test.sh`

R3→R4 diff: `git -C /Users/augstar/macprovider-iss291 show HEAD`
