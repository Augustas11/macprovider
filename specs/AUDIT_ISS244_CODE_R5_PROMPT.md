## Lane: CODE — Round 5

## Context

R4 returned: CODE 0/2/0/1/0, SEC 0/2/0/0/0, ARCH 0/0/2/2/0.

R4 fix-pass landed as commit `20c16fe` on branch `fix/iss244-deploy-pearl-tls-safety`.

Changes:
1. **Hardcoded catalog destination** — `CATALOG_REMOTE_PATH_CANONICAL=/opt/macprovider/tier2-catalog.json`. coordinator.yaml must match exactly.
2. **`/opt/macprovider` root-owned 0750**: `install -d -o root -g macprovider -m 0750 /opt/macprovider` in step 3.
3. **Stats smoke check fix**: `if ! STATS_STATUS=$(curl ...); then STATS_STATUS=000; fi` + endpoint changed to `/v1/stats/health` expecting 200.
4. **State-aware primary-failure abort** messaging (RENEW vs EXPIRED/MISSING).
5. **Strategy preamble rewritten** to four-state model.

## Your job

CODE LANE round 5. Re-audit:

- Does the hardcoded catalog path work safely in all paths (validation, catalog install at line ~455, smoke check at end of step 8)?
- Did changing `/opt/macprovider` ownership from `macprovider:macprovider 0755` to `root:macprovider 0750` break any other use site? Check every `install -o ...` that writes into /opt/macprovider — they all run via SSH-as-root, so root can write to 0750 dir, but verify.
- The new stats smoke check `if ! STATS_STATUS=$(curl ...);` — is this bash 3.2 + set -e compatible? Does the `if !` correctly suppress set -e for the command-substitution failure?
- The state-aware primary-failure abort uses the same DOMAINS_STATE_KEYS/VALS parallel-array pattern from R3 — any new empty-array hazard?

Produce findings in standard format. If no findings at a severity, write "(none)".

## Files in scope

- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-stats.streamvc.live.conf`

R4→R5 diff: `git -C /Users/augstar/macprovider-iss244 show HEAD`
Cumulative: `git -C /Users/augstar/macprovider-iss244 diff HEAD~5 HEAD`
