## Lane: ARCHITECT — Round 2

## Context

R1 three-lane codex audit returned 0 CRITICAL across all lanes, 2 HIGH on ARCH (primary-failure exit-9 unreachable; DOMAIN/STATS_DOMAIN override mismatched template hostnames), 3 MEDIUM, 2 LOW, 1 INFO.

R1 fix-pass landed as commit `592989b`. Changes:

1. Validate DOMAIN/STATS_DOMAIN/EMAIL up front; refuse overrides that don't match baked-in templates.
2. Strengthen HAVE classification (openssl + privkey).
3. Strict HAVE/NEED parser (exact coverage, fail-closed on malformed/missing).
4. Pre-upload assertion replaces defensive sed.
5. Move primary-failure exit-9 immediately after step 6b.
6. STATS_REQUIRED=1 opt-in.
7. Empty failed-domain loop fixed.

## Your job

ARCHITECT LANE round 2: re-audit the design now that the R1 changes have layered in. Look for:

- Did the absorbed fixes actually close the original ARCH HIGHs/MEDIUMs cleanly, or did they paper over the deeper invariant?
- Is the new "validate-then-refuse-override" pattern at the top of the script a maintainable design, or does it hide future drift (now the template hostnames are duplicated: in the conf files AND in the validator)?
- Does the strict HAVE/NEED parser belong in the deploy script, or is it a sign that the responsibility should move into a separate helper that can be unit-tested?
- Is the pre-upload conf assertion clean, or does it create new coupling between deploy script and conf file shape that will rot?
- ARCH M3 from R1 (state machine not locally testable) — was this addressed? If not, is it acceptable to defer?
- Did the STATS_REQUIRED knob complicate the failure surface in a way that operators won't understand?
- Are there remaining conflicts between the deploy logic and the SPEC-017 / M1-6 / DEVE-4 / DEVE-5 callouts elsewhere in the script?

Re-read the FULL file. Produce findings in this format:

```
CRITICAL: <title>
  file:line — <problem>
  why it matters: <one sentence>
  suggested fix: <one to two sentences>

HIGH: <...>
MEDIUM: <...>
LOW: <...>
INFO: <...>
```

If a severity has no findings, write "(none)".

## Files in scope

- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-stats.malibu.tech.conf`

R1→R2 diff: `git -C /Users/augstar/macprovider-iss244 show HEAD`
R0→R2 cumulative diff: `git -C /Users/augstar/macprovider-iss244 diff HEAD~2 HEAD`
