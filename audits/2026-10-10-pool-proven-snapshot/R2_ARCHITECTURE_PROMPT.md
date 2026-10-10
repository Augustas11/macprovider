# Pool-proven snapshot rollup audit (round R2)

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

## Round 2 (VERIFICATION + changed lines)

Round 1 findings for this lane are in `R1_ARCHITECTURE_RESULT.md` (all lanes' results
are in the same directory). Fix commit: `a17649ee3` (anchor diff
`git diff e7217c3b6..a17649ee3`). For EACH round-1 finding (all three lanes),
answer FIXED / NOT FIXED / PARTIAL with file:line evidence. Then review only
the changed lines of the anchor diff (and the code they rely on) for new
defects. Do not report pre-existing issues outside the anchor diff.

Summary of the fix:
- `trg_ppr_srs_delete` / `trg_ppr_srv_delete` (BEFORE DELETE on
  settlement_route_snapshots / settlement_receipt_verdicts, WHEN OLD.pool_id
  non-empty) capture an uncaptured attempt and freeze `verdict_ok` and
  `finality_at_utc` from the rows being deleted, only while both rows exist.
- The credit half (payable enforce credit, positive debit/credit, policy
  version captured from the snapshot) is read live on every pass, also for
  archived attempts; `counted = verdict_ok AND credit_payable`.
- No version reset: rows are never deleted; a cursor reset rebuilds hot rows
  and keeps archived ones.
- Every refresh read runs under a 10 s timeout; write transactions touch at
  most 200 rows under a 2 s timeout (including the wait for the writer).
- Schema + triggers are created in the billing migration (after table
  rebuilds, before the earnings rollup).

Lane: ARCHITECTURE REVIEW, focus FIT WITH RETENTION (#1909) AND THE SPEC. Read
PR #1909's branch `origin/campaign/1793-sqlite-retention` (evidence_retention.go,
the payable-view change, settlement_finality.go) only as context. Does the rollup
keep R012 counts exact once retention deletes settled snapshot/verdict/output
rows, including partial deletion across batches? Is the "keep stored state when
evidence is gone" rule sound given retention only archives settled, finality-
closed requests? Is rebuildability adequate (version bump rebuilds from hot rows
only)? Does the design conflict with #1909 (triggers, view, compat floor,
incremental vacuum, rowid reuse after deletion with AUTOINCREMENT)? Does the read
/write handle split in server.go keep test and production wiring correct when the
route-read store is absent? Is the SPEC-047 R012 text (R009 limits: 10 s query
timeout, 100 000 ceiling, no partial snapshot, materialized every 15 minutes and
at startup) still satisfied, or does the 5-minute refresh budget need a SPEC
amendment? Is CONFORMANCE.json mapping accurate?
