## Lane: ARCHITECT — Round 5

## Context

R4 ARCH returned 0 CRITICAL, 0 HIGH, 2 MEDIUM (state-aware abort messaging incomplete, stats smoke too superficial), 2 LOW.

R4 fix-pass landed as commit `20c16fe`. Architectural changes:

1. Catalog destination is hardcoded — coordinator.yaml `tier2.catalog_path` must equal `/opt/macprovider/tier2-catalog.json` exactly.
2. /opt/macprovider is now root-owned 0750.
3. Stats smoke check hits `/v1/stats/health` (the SPEC-017 surface) and uses the correct curl-exit-check pattern.
4. Primary-failure abort now state-aware (RENEW vs EXPIRED/MISSING).
5. Strategy preamble rewritten to four-state model.

## Your job

ARCHITECT LANE round 5. Re-audit:

- The hardcoded-path approach — does it conflict with any other design (e.g., SPEC text that says catalog_path is operator-configurable)? Should there be a migration path for operators with the path set differently in their yaml?
- The /opt/macprovider ownership flip (macprovider:macprovider 0755 → root:macprovider 0750) — does it break any other deploy pattern (rollback scripts, monitor service, anything that writes into /opt/macprovider)?
- The stats smoke check now requires the gateway service to be up AND the SPEC-017 stats route to be configured. Is there ever a legitimate deploy where stats. is intentionally unavailable (e.g., a first-ever deploy before the stats vhost is wired)?
- The 5-round audit loop is producing convergence on smaller and smaller fixes — is there a sign the script's design has fundamental issues that an architectural refactor would solve more cleanly than more iteration?
- Is there any remaining stale documentation or comment that contradicts the current behavior?

Produce findings in standard format.

## Files in scope

- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-stats.streamvc.live.conf`

R4→R5 diff: `git -C /Users/augstar/macprovider-iss244 show HEAD`
Cumulative: `git -C /Users/augstar/macprovider-iss244 diff HEAD~5 HEAD`
