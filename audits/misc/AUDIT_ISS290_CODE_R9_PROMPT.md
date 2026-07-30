## Lane: CODE — Round 9

## Context

R8 outcomes:
- CODE 0/0/1/0 (MED: nested single quote `sh -c '...'` inside outer
  `ssh '...'` broke the printed rollback recipe — my R7 regression)
- SEC skipped (0/0/0/0 at R6+R7, R8 fix in already-approved surface)
- ARCH 0/0/1/0 (same convergent MED)

R8 fix-pass `64e2e9c`:
- `sh -c "ls -1t ..."` — inner double quotes, no outer quote breakage
- Rewrote the R7/R8 comment lines to drop all `'` (comments inside
  outer `ssh '...'` are still parsed for quote balance by caller shell)

Verified: printed heredoc body contains 0 apostrophes.

## Your job

CODE LANE round 9. Confirm the printed rollback recipe is now
copy-paste safe and no new gaps.

## Files in scope

- `/Users/augstar/macprovider-iss290/phase5-gateway/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss290/OPS.md`

R8→R9 diff: `git -C /Users/augstar/macprovider-iss290 show HEAD`
