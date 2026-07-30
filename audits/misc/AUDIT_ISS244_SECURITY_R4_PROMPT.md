## Lane: SECURITY — Round 4

## Context

R3 SEC returned 0 CRITICAL, 1 HIGH (catalog_path needed destination allowlist, not just shell-safety), 0 MEDIUM, 0 LOW.

R3 fix-pass landed as commit `d8120ad`. Security-relevant changes:

1. **catalog_path allowlist**: restricted to `/opt/macprovider/*` only. Other destinations refused fail-closed (so a poisoned config can no longer re-chown `/etc/macprovider`).
2. **Four-state cert classification** (HAVE/RENEW/EXPIRED/MISSING). EXPIRED treats like MISSING — broken cert no longer preserved as-is.
3. **Pre-upload assertion** anchored to expected hostname path exactly.
4. **Stats smoke check** in step 8 (WARN by default; STATS_REQUIRED=1 promotes to exit-9).
5. **State-aware failure messaging** — operator sees correct per-domain post-failure state.

## Your job

SECURITY LANE round 4. Re-audit:

- Did the `/opt/macprovider/*` allowlist actually close the HIGH? Any edge case where the pattern matches something unsafe (e.g., symlinks, race between probe and install, path containing `/opt/macprovider/../../etc/`)?
- The R3 already rejects `..` and `//`, but `case "$path" in /opt/macprovider/*) ;;` — does this gate run BEFORE the `..`/`/` reject? Order matters.
- Are there other coordinator.yaml-sourced values now flowing into single-quoted SSH commands that this PR introduced?
- The new stats smoke check `curl ... 2>/dev/null || echo "000"` — any way this hides a real TLS-layer attack (cert mismatch, downgrade) under a successful "200" response?
- DOMAINS_STATE_KEYS/VALS parallel arrays — any way a malicious cert-status line poisons one but not the other, leading to wrong state mapping?

Produce findings in standard format.

## Files in scope

- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-stats.streamvc.live.conf`

R3→R4 diff: `git -C /Users/augstar/macprovider-iss244 show HEAD`
Cumulative: `git -C /Users/augstar/macprovider-iss244 diff HEAD~4 HEAD`
