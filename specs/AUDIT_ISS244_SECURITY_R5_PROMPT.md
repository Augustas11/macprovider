## Lane: SECURITY — Round 5

## Context

R4 SEC returned 0 CRITICAL, 2 HIGH (catalog_path symlink race + stats `000000` bug), 0 MEDIUM, 0 LOW.

R4 fix-pass landed as commit `20c16fe`. Security-relevant changes:

1. **Hardcoded catalog destination** to `/opt/macprovider/tier2-catalog.json`. coordinator.yaml must match exactly.
2. **`/opt/macprovider` root-owned 0750** in step 3 — macprovider user can no longer create files/symlinks under it.
3. **Stats smoke check** uses `if ! STATS=$(curl ...)` form + `/v1/stats/health` endpoint expecting 200.

## Your job

SECURITY LANE round 5. Re-audit:

- Did changing `/opt/macprovider` to `root:macprovider 0750` actually close the symlink race? Are there other paths under /opt/macprovider that still permit non-root write?
- The hardcoded catalog path approach — any way an attacker controls the install destination via env var, symlink at /tmp/tier2-catalog.json, or other vector?
- The stats smoke check now hits `/v1/stats/health`. Is there a known authenticated route that a malicious operator could redirect this to, leaking info?
- The deploy script now interpolates `$CATALOG_REMOTE_PATH_CANONICAL` (a script-controlled constant) into the SSH command — confirm there's no operator-tainted value flowing.
- The R3 `case` statement and R4 hardcode together — any combination that could be bypassed (e.g., via env override CATALOG_REMOTE_PATH_CANONICAL)?

Produce findings in standard format.

## Files in scope

- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-stats.streamvc.live.conf`

R4→R5 diff: `git -C /Users/augstar/macprovider-iss244 show HEAD`
Cumulative: `git -C /Users/augstar/macprovider-iss244 diff HEAD~5 HEAD`
