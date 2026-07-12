#!/usr/bin/env bash
# h1-undercredit-probe.sh — READ-ONLY diagnostic for runbook item 2 / decision gate G1.
#
# Measures how often the SPEC-005 byte-estimate clamp (min(provider_reported,
# ceil(wire_bytes/16))) actually reduces the credited completion below the
# provider-reported value on 200-status rows, and by how much. See
# ops/runbooks/spec-drift-remediation.md (item 2) and audit finding H1.
#
# Production ledger: /var/lib/macprovider/coordinator.db on coordinator.streamvc.live
# (Pearl VPS). Requires operator SSH + read access. NEVER writes to the live file —
# snapshot first, then query the copy.
#
# Usage:
#   # on the VPS, as a user with read access to the ledger:
#   sqlite3 /var/lib/macprovider/coordinator.db ".backup /tmp/coord-snap.db"
#   ./h1-undercredit-probe.sh /tmp/coord-snap.db 2026-07-04T00:00:00Z 2026-07-11T00:00:00Z
#   rm -f /tmp/coord-snap.db
set -euo pipefail
DB="${1:?db path (use a .backup snapshot, not the live file)}"
START="${2:?start RFC3339 UTC, e.g. 2026-07-04T00:00:00Z}"
END="${3:?end RFC3339 UTC, e.g. 2026-07-11T00:00:00Z}"

sqlite3 -readonly -box "file:${DB}?mode=ro" <<SQL
-- Read-only is enforced by \`-readonly\` + \`?mode=ro\` on the main (snapshot) DB above.
-- Do NOT add \`PRAGMA query_only = ON;\` here: it also blocks the temp DB, so the
-- \`.parameter set\` below cannot create temp.sqlite_parameters — it then fails with
-- "no such table: temp.sqlite_parameters" and the query silently binds :start/:end to
-- NULL and returns all-zeros (a false "no under-credit"). The temp DB is independent
-- of the read-only main DB, so parameter binding is safe without query_only.
.parameter set :start '${START}'
.parameter set :end   '${END}'
WITH base AS (
  SELECT completion_tokens           AS rep,   -- provider-reported completion
         estimated_completion_tokens AS est,   -- ceil(wire_bytes/16) byte estimate
         completion_rate_per_mtok    AS crate,
         global_multiplier_ppm       AS mult,
         provider_share_bps          AS pshare,
         stream
  FROM ledger_request_credits
  WHERE status = 200
    AND usage_source = 'byte_estimated'
    AND fault_flag = 'none'
    AND quarantined = 0
    AND ts_utc >= :start AND ts_utc < :end
),
bound AS (   -- rows where the clamp reduced credited completion below reported
  SELECT (rep - est) AS delta_tok,
         CAST(ROUND((rep - est) * crate * mult / 1000000000000.0) AS INTEGER) AS delta_gross,
         pshare
  FROM base
  WHERE rep IS NOT NULL AND est IS NOT NULL AND est < rep
),
med AS (
  SELECT delta_tok,
         ROW_NUMBER() OVER (ORDER BY delta_tok) rn,
         COUNT(*)     OVER ()                    n
  FROM bound
)
SELECT
  (SELECT COUNT(*) FROM base)                        AS n_byte_estimated_200,
  (SELECT COUNT(*) FROM base WHERE rep IS NOT NULL)  AS n_reported_present,
  (SELECT COUNT(*) FROM bound)                       AS n_clamp_bound,
  ROUND(100.0*(SELECT COUNT(*) FROM base WHERE rep IS NOT NULL)
              /NULLIF((SELECT COUNT(*) FROM base),0),2)          AS pct_reported_present,
  ROUND(100.0*(SELECT COUNT(*) FROM bound)
              /NULLIF((SELECT COUNT(*) FROM base),0),2)          AS pct_bound_of_all_byte_est,
  ROUND(100.0*(SELECT COUNT(*) FROM bound)
              /NULLIF((SELECT COUNT(*) FROM base WHERE rep IS NOT NULL),0),2) AS pct_bound_of_reported,
  (SELECT COALESCE(SUM(delta_tok),0) FROM bound)     AS total_undercredit_tokens,
  (SELECT AVG(delta_tok) FROM med WHERE rn IN ((n+1)/2,(n+2)/2)) AS median_undercredit_tokens,
  (SELECT COALESCE(SUM(delta_gross),0) FROM bound)   AS total_undercredit_gross_credits,
  (SELECT COALESCE(SUM(CAST(ROUND(delta_gross*pshare/10000.0) AS INTEGER)),0) FROM bound)
                                                     AS total_undercredit_provider_credits,
  ROUND((SELECT COALESCE(SUM(CAST(ROUND(delta_gross*pshare/10000.0) AS INTEGER)),0) FROM bound)/1000000.0,4)
                                                     AS total_undercredit_provider_usd;
SQL

# G1 interpretation (see runbook item 2):
#  REVERT the divisor to content-bytes /4 (and use the byte estimate only as a
#  usage-absent fallback, never as a downward clamp on reported completions) if ANY of:
#    - pct_bound_of_reported >= 5%
#    - median_undercredit_tokens >= ~20% of the window's median reported completion
#    - annualized total_undercredit_provider_usd is material for the payout base
#  DOCUMENT the /16 clamp in SPEC-005 v0.6 (no code change) only if ALL of:
#    - pct_bound_of_reported < 1%, AND total_undercredit_tokens is rounding-level,
#      AND pct_reported_present is low (estimate is a genuine usage-absent fallback).
