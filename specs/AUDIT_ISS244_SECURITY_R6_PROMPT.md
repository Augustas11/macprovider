## Lane: SECURITY — Round 6

## Context

R5 SEC: 1 CRITICAL + 1 MEDIUM (predictable /tmp staging + macprovider-writable artifacts).

R5 fix-pass landed as commit `d919a50`. Security changes:
1. **Per-deploy `$DEPLOY_TMP`** via `umask 077 && mktemp -d -t macprovider-deploy.XXXXXXXX`. All SCPs land in it; all installs read from it.
2. **Artifact ownership** `root:macprovider` with `0750`/`0640` modes.
3. **Stats smoke gated on stats.enabled** + early STATS_REQUIRED coherence check.

## Your job

SECURITY LANE round 6. Re-audit:

- Did the `$DEPLOY_TMP` mktemp -d approach actually close the /tmp race? Any window between mktemp and chmod where the dir could be raced?
- The EXIT trap on cleanup — if the deploy aborts during SCP, does the trap correctly clean up the dir? Any TOCTOU between the trap and a same-host attacker (who can't write to the 0700 dir but could observe the deploy via process listing)?
- Does the path-shape guard `case "$DEPLOY_TMP" in /tmp/macprovider-deploy.*) ;;` catch a maliciously-crafted mktemp wrapper?
- Tightened artifact ownership — confirm the daemon can still read its config (mode 0640 root:macprovider, daemon runs as macprovider in the group)?
- Are there other `/tmp/X` paths I missed (e.g., catalog smoke check uses `/tmp/macprovider-catalog-current.json` on the OPERATOR Mac — different threat model but still worth flagging)?
- Are there other coordinator.yaml values that flow into SSH commands and might need validation?

Produce findings in standard severity-graded format.

## Files in scope

- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/coordinator.yaml.example`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/monitor/macprovider-monitor.service`

R5→R6 diff: `git -C /Users/augstar/macprovider-iss244 show HEAD`
Cumulative: `git -C /Users/augstar/macprovider-iss244 diff HEAD~6 HEAD`
