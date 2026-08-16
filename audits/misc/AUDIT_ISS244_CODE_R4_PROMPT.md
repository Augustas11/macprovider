## Lane: CODE — Round 4

## Context

R3 three-lane audit returned: CODE 0/0/1/1/0, SEC 0/1/0/0/0, ARCH 0/0/4/2/0.

R3 fix-pass landed as commit `d8120ad` on branch `fix/iss244-deploy-pearl-tls-safety` in `/Users/augstar/macprovider-iss244/`.

Changes since R3 audit:
1. **Four-state classification** (HAVE / RENEW / EXPIRED / MISSING) — RENEW now only for valid-right-now near-expiry certs (`-checkend 0` then `-checkend 86400`). EXPIRED behaves like MISSING.
2. **MISSING + EXPIRED always install stub** (dropped vhost gating). Stub overwrite is idempotent.
3. **catalog_path destination allowlist**: `/opt/macprovider/*` only.
4. **Pre-upload cert assertion**: anchored to expected hostname (`ssl_certificate /etc/letsencrypt/live/<host>/fullchain.pem;` exact match).
5. **Stats smoke check** in step 8 (WARN-only by default; fail-closed with STATS_REQUIRED=1).
6. **State-aware failure messaging** per-domain via DOMAINS_STATE_KEYS/VALS parallel arrays.

## Your job

CODE LANE round 4. Re-audit:

- Did the R3 changes introduce new bash 3.2 + set -u hazards (the new parallel arrays, the state lookup loop, the always-stub logic)?
- The state lookup `i=0 / for k in keys; do if k=d; then val=VALS[i]; break; fi; i++; done` pattern — does this work correctly on bash 3.2 + set -u when arrays are empty?
- The new `case "$prior_state"` block — does it handle the empty-string fallback safely?
- The catalog_path allowlist — does `case "$CATALOG_REMOTE_PATH" in /opt/macprovider/*) ;;` correctly reject `/opt/macprovider` (no trailing slash) vs accept `/opt/macprovider/file`?
- The anchored cert assertion regex — does `${host_esc}/fullchain\\.pem;` correctly escape and anchor?
- The stats smoke check `curl ... 2>/dev/null || echo "000"` — under set -e, does the `|| echo` short-circuit correctly?

Produce findings in the standard severity-graded format. If no findings at a severity, write "(none)".

## Files in scope

- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-stats.malibu.tech.conf`

R3→R4 diff: `git -C /Users/augstar/macprovider-iss244 show HEAD`
Cumulative: `git -C /Users/augstar/macprovider-iss244 diff HEAD~4 HEAD`
