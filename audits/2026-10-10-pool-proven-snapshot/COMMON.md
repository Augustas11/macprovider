# Pool-proven snapshot rollup audit (round R{ROUND})

Repository: the current working directory (branch `fix/pool-proven-snapshot`).
Audit the complete diff `git diff origin/main...HEAD` (read every changed file in
full where needed, and the surrounding code the diff relies on). Do not edit
files. Do not run network commands.

## Change under audit

Bug: the SPEC-047-R012 pool-proven aggregate (`GET /admin/model-admission/pool-proven`,
`specs/SPEC-047-*.md` R012) never built in production. The old builder query
(`origin/main:phase4-coordinator/internal/billing/pool_proven.go`) drove the
SPEC-022 payable view `spec022_payable_request_credits` over every enforce-mode
ledger credit (plan: `SEARCH lrc USING INDEX idx_lrc_spec022_payable
(settlement_policy_mode=?)` + correlated evidence EXISTS + json_extract per row +
temp B-tree), exceeding the 10 s build deadline on a production-size ledger in which
pool-manifest attempts are a tiny fraction.

Fix: a coordinator-maintained rollup `pool_proven_rollup_attempts` (one row per
enforce-mode pool_manifest attempt) plus `pool_proven_rollup_cursor`:
- Capture: rowid high-water mark over `settlement_route_snapshots` (append-only via
  `trg_srs_immutable`, AUTOINCREMENT ids, single SQLite writer), 20 000-id range
  reads, provenance copied from the immutable snapshot, account scope stored as
  `SettlementAccountScopeHash`.
- Evaluate: each pass re-evaluates the unchanged R012 v0.2.9 counting predicate,
  by key lookups only, for rows whose stored finality is NULL or >= window start;
  stores `counted` and `finality_at_utc` (verdict close time,
  `COALESCE(updated_at_utc, created_at_utc)` as before). If the snapshot or verdict
  row is gone (SPEC-022 R-15 retention, PR #1909), the stored state is kept.
- Reads go through the read-only route-read handle; writes are short transactions
  on the shared single-connection writer. Refresh has a 5-minute budget and
  commits progress; the aggregate read keeps the 10 s timeout, the 100 000
  ceiling, and no-partial-snapshot; a failed refresh keeps the previous snapshot.
- `poolProvenRollupVersion` mismatch clears the rollup and rebuilds from hot rows.

Constraints the fix must meet: complete well within the deadline on a production
DB and never starve the hot-path writer (the request-log/billing writer pool has
exactly one connection); count only settled, paid, payable-receipt,
verified-pool-labelled, pool_manifest attempts exactly as R012 says (disputed,
reversed/quarantined, unsettled, zero-credit, catalog-source excluded); stay
correct once #1909 archives settled evidence rows; no conflict with #1909.

Key files: `phase4-coordinator/internal/billing/pool_proven.go`,
`phase4-coordinator/internal/ws/model_admission_pool_proven.go`,
`phase4-coordinator/internal/ws/server.go` (source wiring),
`phase4-coordinator/internal/ws/model_admission.go` (table creation), the tests,
`specs/CONFORMANCE.json` (R012 row). Context: `internal/billing/store.go`
(payable view), `internal/billing/relay_blind_settlement.go`
(`payableSettlementOutcomeSQL`), `internal/billing/route_snapshot.go` (snapshot
insert), `cmd/coordinator/main.go` (DB handles).

## Output

List findings as `SEVERITY (CRITICAL/HIGH/MEDIUM/LOW/INFO) — file:line —
problem — concrete fix`. Mark whether each finding is NEW in this diff or
PRE-EXISTING. End with exactly one line:
`VERDICT: C=<n> H=<n> M=<n> L=<n>`.
