## Lane: SECURITY — Round 7

## Context

R6 SEC: 0 C / 0 H / 2 M / 2 L.

R6 fix-pass landed as commit `fac851b`. Security changes:
1. EXIT trap unconditional (covers DEPLOY_TMP cleanup regardless of catalog enablement).
2. `/tmp/last-deploy-bypass.json` writers use remote `umask 077 && mktemp`.

## Your job

SECURITY LANE round 7. Re-audit:

- Did the unconditional EXIT trap and mktemp tombstone fixes actually close the R6 SEC MEDs?
- Are there now any predictable root-written /tmp files left in the script?
- The `umask 077 && mktemp` runs inside an SSH-quoted heredoc — verify the umask is correctly inherited by mktemp.
- Any new attack surface from making the EXIT trap unconditional (e.g., signal-handling that fires the trap during something it shouldn't)?

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss244/OPS.md`
- `/Users/augstar/macprovider-iss244/audits/2026-06-10/ROLLBACK_PROCEDURE.md`

R6→R7 diff: `git -C /Users/augstar/macprovider-iss244 show HEAD`
Cumulative: `git -C /Users/augstar/macprovider-iss244 diff HEAD~7 HEAD`
