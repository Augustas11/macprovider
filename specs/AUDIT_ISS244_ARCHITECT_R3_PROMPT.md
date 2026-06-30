## Lane: ARCHITECT — Round 3

## Context

R2 ARCH audit returned 0 CRITICAL, 0 HIGH, 3 MEDIUM (openssl-missing fallback, template-hostname duplication, state machine untestable), 2 LOW (STATS_REQUIRED hidden, stale defensive-sed comment).

R2 fix-pass landed as commit `102d4f1`. Architectural changes:

1. Three-state classification (HAVE/RENEW/MISSING + vhost flag) replaces binary HAVE/NEED.
2. Pre-upload assertion verifies server_name + cert paths match template hostname.
3. Missing openssl on remote is fatal (no silent fallback).
4. Env-var documentation in usage header.
5. Stale sed comment removed; strategy preamble rewritten to describe the new state machine.
6. ARCH M3 (state machine untestable) deferred — extracted scope into a follow-up issue would be cleaner than retrofitting.

## Your job

ARCHITECT LANE round 3. Re-audit:

- Did the three-state model actually buy clean separation of concerns, or did it just push complexity around?
- The pre-upload assertion now has 4 checks per template — clean or sprawling?
- The strategy preamble at step 5 — accurate? Does it cover the RENEW case correctly?
- ARCH M3 deferral — is that the right call, or is testability still a deploy-time-blocker?
- The interaction between the new three-state model and the existing comments about SPEC-017, M1-6, DEVE-4, DEVE-5 — any new contradictions or stale references?
- The script is now 750+ lines for a deploy wrapper. Is there a point where extraction-vs-cohesion tips, and what would the extraction look like (helper script, sourced lib, Go binary, separate stage)?
- The STATS_REQUIRED=0 default — is documenting the rationale (issue #244 root cause) sufficient, or does the operator contract need a stronger guard?

Produce findings in the standard severity-graded format.

## Files in scope

- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-stats.streamvc.live.conf`

R2→R3 diff: `git -C /Users/augstar/macprovider-iss244 show HEAD`
R0→R3 cumulative diff: `git -C /Users/augstar/macprovider-iss244 diff HEAD~3 HEAD`
