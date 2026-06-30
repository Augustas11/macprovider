## Lane: CODE — Round 7

## Context

R6: CODE 0/0/2/1/0, SEC 0/0/2/2/0, ARCH 0/0/2/1/0.

R6 fix-pass landed as commit `fac851b`. Changes:
1. EXIT trap moved UNCONDITIONAL (before any temp resource creation).
2. Both `/tmp/last-deploy-bypass.json` writers (step 1c + 6c) use remote `umask 077 && mktemp` per call.
3. OPS.md narrows ownership claim to coordinator-only.
4. ROLLBACK_PROCEDURE.md + SPEC_015_V03_OPERATOR_RUNBOOK.md updated to `root:macprovider 0750`.

## Your job

CODE LANE round 7. Re-audit:

- The unconditional EXIT trap registration — does it correctly fire on early-exit before DEPLOY_TMP is set? (TMP_CATALOG_PUBKEY uses `${VAR:-}` guard.)
- The new `_bypass_tmp=$(umask 077 && mktemp)` pattern with remote here-doc — does the variable correctly preserve through the heredoc body via shell escape `\"\$_bypass_tmp\"`?
- Any path I missed in the /tmp → mktemp migration?
- Is `set -e` correctly preserved when curl exits 1 to the `if !` branch?

Standard severity-graded findings. If a severity has no findings, write "(none)".

## Files in scope

- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss244/OPS.md`
- `/Users/augstar/macprovider-iss244/audits/2026-06-10/ROLLBACK_PROCEDURE.md`
- `/Users/augstar/macprovider-iss244/audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md`

R6→R7 diff: `git -C /Users/augstar/macprovider-iss244 show HEAD`
Cumulative: `git -C /Users/augstar/macprovider-iss244 diff HEAD~7 HEAD`
