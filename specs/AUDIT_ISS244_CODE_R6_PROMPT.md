## Lane: CODE — Round 6

## Context

R5: CODE PASS (0/0/0/0/0), SEC 1 CRITICAL + 1 MEDIUM, ARCH 0/0/2/1/0.

R5 fix-pass landed as commit `d919a50` on branch `fix/iss244-deploy-pearl-tls-safety`. Re-firing CODE per [[feedback-skip-accepted-audit-lanes]] because R5 fix-pass touched code paths CODE previously audited.

Changes:
1. **Per-deploy mktemp staging dir** `$DEPLOY_TMP` (mode 0700 root-owned). All `/tmp/X` → `$DEPLOY_TMP/X`. EXIT trap cleans up.
2. **Tightened artifact ownership**: `root:macprovider 0750` for binary/CLI; `0640` for config/catalog.
3. **`yaml_block_value()`** helper added (generalized `yaml_tier2_value`).
4. **Early STATS_REQUIRED vs stats.enabled coherence check** before SSH mutations.
5. **Stats smoke gated on stats.enabled=true**.
6. **doc/comment drift** updates in monitor.service + OPS.md + coordinator.yaml.example.

## Your job

CODE LANE round 6. Re-audit:

- `DEPLOY_TMP=$($SSH 'umask 077 && mktemp -d -t macprovider-deploy.XXXXXXXX')` — does the umask + mktemp combo correctly produce 0700? Does `-t` work consistently on all Ubuntu certbot-supporting versions?
- The path-shape `case "$DEPLOY_TMP" in /tmp/macprovider-deploy.*) ;;` — does it correctly reject unexpected paths?
- All `/tmp/X` references replaced with `$DEPLOY_TMP/X`? Run a quick scan and verify none were missed.
- EXIT trap interaction with the existing TMP_CATALOG_PUBKEY trap — combined correctly so both fire?
- `yaml_block_value` awk pattern — any pathological yaml that confuses the block-scan?
- The early STATS_REQUIRED coherence check at the top — runs before any SSH; correct ordering?

Produce findings in standard severity-graded format. If no findings, write "(none)".

## Files in scope

- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/coordinator.yaml.example`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/monitor/macprovider-monitor.service`

R5→R6 diff: `git -C /Users/augstar/macprovider-iss244 show HEAD`
Cumulative: `git -C /Users/augstar/macprovider-iss244 diff HEAD~6 HEAD`
