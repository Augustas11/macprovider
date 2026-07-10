## Lane: ARCHITECT — Round 4

## Context

R3 ARCH returned 0 CRITICAL, 0 HIGH, 4 MEDIUM (vhost=1 coarse, RENEW conflates expired, assertion loose, no stats smoke check), 2 LOW (misleading messaging, stale nginx comments).

R3 fix-pass landed as commit `d8120ad`. Architectural changes:

1. **Four-state classification** (HAVE / RENEW / EXPIRED / MISSING) — RENEW is now narrowly "valid right now, <24h to expiry"; EXPIRED treats like MISSING.
2. **MISSING + EXPIRED always install stub** (vhost gating dropped — was over-coarse).
3. **catalog_path destination allowlist** (`/opt/macprovider/*` only).
4. **Pre-upload assertion** anchored to expected hostname exactly.
5. **Stats smoke check** in step 8 (WARN by default, fail-closed with STATS_REQUIRED=1).
6. **State-aware failure messaging** per-domain.
7. **Stale nginx comments** cleaned up.
8. **R2 ARCH M3 (state machine extraction)** stays deferred — too large for this PR.

## Your job

ARCHITECT LANE round 4. Re-audit:

- Did the four-state model actually close the R3 ARCH MEDs cleanly, or did EXPIRED introduce new coupling/edge cases?
- The DOMAINS_STATE_KEYS/VALS parallel-array pattern — clean enough for bash, or a sign the helper-extraction recommendation should land in this PR after all?
- The catalog_path allowlist (`/opt/macprovider/*`) — is this the right invariant or is it too narrow (e.g., does deployment ever legitimately want `/var/lib/macprovider/...`)?
- The stats smoke check defaulting to WARN-only — does the new state-aware messaging make the failure surface clear enough that operators won't miss it?
- Is the strategy preamble at step 5 still accurate after the EXPIRED state was added?
- Any new conflicts between the script's growing logic and the surrounding comments (SPEC-017, M1-6, DEVE-4/5)?
- The decision to defer ARCH M3 (state machine extraction) — still defensible after R3, or should it land here?

Produce findings in standard format.

## Files in scope

- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-stats.streamvc.live.conf`

R3→R4 diff: `git -C /Users/augstar/macprovider-iss244 show HEAD`
Cumulative: `git -C /Users/augstar/macprovider-iss244 diff HEAD~4 HEAD`
