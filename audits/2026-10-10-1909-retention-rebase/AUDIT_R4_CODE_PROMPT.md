# R4 verification audit (code) — #1909 after rebase onto #1950

This is a first-party software-correctness review of our own code. Method constraint: do NOT author or construct malformed payloads or exploit inputs; evaluate by reading source, specs and tests and by running EXISTING tests only; describe gaps abstractly (field + condition) in prose. Do not edit, commit or push anything, and do not create files in the worktree.

Worktree: /Users/augstar/macprovider-1909 (branch campaign/1793-sqlite-retention, PR #1909).
Scope: the complete PR diff as it will land:

    git -C /Users/augstar/macprovider-1909 diff origin/main...HEAD
    git -C /Users/augstar/macprovider-1909 log --oneline origin/main..HEAD

Feature: SPEC-022 R-15 settled-evidence retention (#1793), rebased onto current main. It exports settled evidence rows (route snapshots, receipt verdicts, attempt outputs, compute-integrity captures, drained audit-outbox rows, route-snapshot journal mirrors) of requests whose credits settled at least two completed settlement cycles ago into a gzip JSONL archive with a SHA-256 manifest under a local archive_dir (default retention-archive/ next to the database file), re-reads and verifies the archive (checksum, size, parse, row counts, row-for-row equality with the hot rows), optionally runs an operator off-host verification command, then deletes in bounded BEGIN IMMEDIATE batches and runs bounded incremental vacuum. Tombstones (settlement_evidence_archived_credits, settlement_evidence_archived_verdict_counts, settlement_evidence_archived_finality) keep archived credits payable, verified, counted and their finality readable. Retention is ON by default (billing.retention.enabled defaults to true; false is the kill switch), refuses to write an archive below a free-space floor (archive_min_free_bytes 20 GiB / archive_min_free_percent 10), and the first run is bounded by max_requests_per_run and batch_size. Billing compat floor 4 is recorded at open (roll forward only). Money path.

Integration points with main to check specifically:
- #1935 provider earnings rollup (phase4-coordinator/internal/billing/earnings_rollup.go): trigger-maintained hourly cache over the payable view inputs. The PR adds the tombstone table as a view input with an insert trigger and drops the `settled = 1` condition from the view's archived-credit branch. Earnings must stay exact across archival.
- countVerifiedReceipts (phase4-coordinator/internal/rewards/unlock.go): must keep the provider-index (INDEXED BY idx_srv_provider_recent) and unpinned fallback and add archived verdict counts in one statement.
- SPEC-047-R012 pool-proven aggregate: a separate branch (origin/fix/pool-proven-snapshot) turns it into a maintained rollup table pool_proven_rollup_attempts. Retention must keep pool-scoped requests hot until that rollup holds their final state, and keep them hot entirely while that table does not exist.
- Never-touched classes: unsettled, quarantined, held/force-resolved, relay-blind, open finality, voided payout, open/pending/quarantined verdict, undrained/poisoned outbox, unmaterialized journal.

Severity bar: CRITICAL/HIGH/MEDIUM only for real defects with a concrete failure scenario and file:line evidence you verified in the code. Style, speculative hardening and "more tests would be nice" are LOW/INFO. Ignore pre-existing issues outside the diff unless the diff makes them reachable.

Output: a findings list (severity, title, file:line, evidence, failure scenario, fix), then one final line exactly:
VERDICT: CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n>

Lane: code. Focus: correctness bugs, logic errors, broken invariants, error handling, transaction/concurrency bugs, earnings/receipt-count exactness, and regressions in existing behavior.

Round 4 is a verification-only round. #1950 (the pool-proven maintained rollup, with BEFORE DELETE freeze triggers on settlement_route_snapshots and settlement_receipt_verdicts) is now on origin/main and #1909 is rebased on it. Two behavior-relevant changes since the clean R1-R3 rounds: (1) commit a4a22cd55 — poolProvenRollupPending (evidence_retention.go) now keeps a request hot only while one of its snapshots that the rollup counts (poolProvenSnapshotSQL: enforce, pool_manifest source, non-empty pool_id) lacks a pool_proven_rollup_attempts row with finality_at_utc; the table-absent branch is gone because #1950's billing migration always creates it; (2) commit 39c619493 — #1950's pool_proven_test.go fixtures now use the real tombstone table. Verify: retention can never shrink the pool-proven aggregate (consider the freeze triggers firing inside retention's delete transaction alongside the earnings-rollup triggers), no pool attempt that the aggregate counts is archived before it is final, the combined code is correct, and no new CRITICAL/HIGH/MEDIUM defect exists in the full diff.
