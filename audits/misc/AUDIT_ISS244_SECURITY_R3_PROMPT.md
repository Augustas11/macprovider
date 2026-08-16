## Lane: SECURITY — Round 3

## Context

R2 SEC audit returned 0 CRITICAL, 2 HIGH (RENEW-clobber, tier2.catalog_path quote-break), 2 MEDIUM, 1 LOW.

R2 fix-pass landed as commit `102d4f1`. Key security-relevant changes:

1. RENEW state keeps existing TLS vhost (no clobber on near-expiry).
2. `tier2.catalog_path` validated against strict pattern before any SSH use.
3. Missing openssl on remote is FATAL.
4. Parser tightened (rejects malformed lines).
5. Pre-upload assertion verifies server_name + cert paths in templates.

## Your job

SECURITY LANE round 3. Re-audit:

- Did the catalog_path validator actually close the quote-break hazard? Is the regex tight enough — any null byte / Unicode / encoding bypass?
- Are there OTHER coordinator.yaml values (operator_key, catalog_public_key, anything else from `yaml_tier2_value`) that flow into SSH command strings without similar validation?
- The RENEW state preserves existing vhost — does that introduce any new TOCTOU window where the cert could be replaced under the script?
- The `bash -s -- '$DOMAIN' '$STATS_DOMAIN'` remote invocation uses single-quoted shell positional args after the validators ran — any way an attacker still controls those values?
- The STATS_REQUIRED=0 default — is there any path where stats. cert outage compounds with another failure mode into something worse than "non-primary domain temporarily unavailable"?
- Any new attack surface introduced by the R2 changes (e.g., the `read -r` parsing, the `_seen` linear scan, the apt-get install of openssl)?

Produce findings in the standard severity-graded format.

## Files in scope

- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-stats.malibu.tech.conf`

R2→R3 diff: `git -C /Users/augstar/macprovider-iss244 show HEAD`
R0→R3 cumulative diff: `git -C /Users/augstar/macprovider-iss244 diff HEAD~3 HEAD`
