## Raw output

```text
Reviewed `audits/2026-09-28-1775/full.diff` and surrounding code. Targeted tests passed:

- `go test ./internal/billing ./internal/referralapi`
- `go test ./cmd/coordinator -run 'Test.*(WAL|Checkpoint|MoneySQLite)' -count=1`

Blocking findings:

1. **HIGH — nightly recovery still monopolizes the writer**

   `phase4-coordinator/internal/billing/recovery.go:29,74-125`

   `RecoverLedger` still opens one long `ReadOnly:false` transaction, scans `request_log`, and performs reconciliation writes. During the observed ~2-minute run, hot-path credit/evidence writes still wait behind the single writer connection and SQLite write lock. The new read pool does not help this transaction.

   **Fix:** Process recovery in bounded batches with short writer transactions. Re-read and revalidate persisted request logs, route snapshots, settlement evidence, and pool labels inside each write batch so SPEC-022 fail-closed behavior is preserved.

2. **HIGH — buyer finality lookups remain on the writer**

   `phase4-coordinator/internal/buyer/server.go:1264-1271`  
   `phase4-coordinator/internal/billing/settlement_finality.go:117-128,410-416,456-550`

   Buyer finality requests still perform direct request lookup, verdict lookup, route-snapshot/evidence lookup, and enforce-credit lookup through `s.db`, which is the single writer pool. Under recovery or other writer contention, the buyer finality path can still exceed its latency budget.

   **Fix:** Move the read-only discovery phase to the read pool, then perform authoritative revalidation and any `RecordMissingSettlementReceipt` mutation in a short writer transaction. Do not trade writer contention for stale or non-atomic SPEC-022 decisions.

3. **HIGH — trust-pool reconstruction still takes a write lock on the buyer path**

   `phase4-coordinator/cmd/coordinator/main.go:1129`  
   `phase4-coordinator/internal/buyer/server.go:1157-1171`  
   `phase4-coordinator/internal/trustpool/durable_store.go:2590-2625`

   `Reconstruct` uses `sqliteutil.Transact`, whose implementation still executes `BEGIN IMMEDIATE` (`internal/sqliteutil/transact.go:49-90`). A buyer trust-pool authorization can therefore acquire the shared request-log writer while replaying durable pool state. Concurrent trust-pool refreshes or large event histories can recreate connection starvation.

   **Fix:** Add a read-only reconstruction path over a dedicated read pool, retaining one consistent snapshot and the existing durable-revision/fencing checks. Keep write transactions only for durable mutations.

4. **MEDIUM — payout reads fall back to the writer for the normal same-file configuration**

   `phase4-coordinator/cmd/coordinator/main.go:3680-3689`  
   `phase4-coordinator/internal/rewards/wallet_status.go:295-312`

   When `SQLitePayoutDBPath` is empty or equals the primary DB path, `configuredPayoutReadDB` returns `defaultStore.DB()`. Consequently, wallet-status and payout-read queries still consume the single writer pool in the normal deployment.

   **Fix:** Pass the shared billing read DB into payout configuration, or open a dedicated read-only pool whenever payout data resides in the primary DB. Preserve the writer only for payout mutations.

Non-blocking follow-ups:

- **INFO — `TransactObserved` is instrumentation, not contention relief.**  
  `internal/sqliteutil/transact.go:49-90` still uses `BEGIN IMMEDIATE`. The changed call sites gain wait/duration metrics, but any read work performed through them still takes the writer path. Keep the instrumentation, but migrate genuinely read-only transactions to a read-only pool.

- **INFO — WAL interaction is bounded but lacks coverage.**  
  The checkpointer uses `PASSIVE`, then conditionally `TRUNCATE`, with bounded timeout (`cmd/coordinator/main.go:2135-2156`). A long-lived reader can prevent full checkpointing and cause WAL growth, but should not directly block writers because `PASSIVE` is non-blocking and `TRUNCATE` is bounded. Add a test and telemetry for a held reader snapshot, checkpoint backlog, and reader-pool `DBStats`.

- **INFO — connection/FD budget should be documented and measured.**  
  The new pool adds up to four primary-file connections (`cmd/coordinator/main.go:362-370`) alongside the writer, checkpoint DB, route-snapshot pool, model-admission reader, audit store, and possible referral/payout readers. Four is consistent with existing patterns, but there is no aggregate budget or startup/steady-state observation. Add `DBStats` metrics and validate the service’s `RLIMIT_NOFILE` under concurrent load.

Coverage notes:

- BYOM/model-admission route reads already use `configuredModelAdmissionRouteReadStore` (`main.go:3692-3705`).
- Admission and canary stores remain writer-backed, but their recurring operations are primarily mutations/startup loads rather than the large pure-read path targeted here.
- The changed settlement display, audit, expiry-selection, and referral queries do bypass the writer, and their rows are generally closed before subsequent writes.
- I found no direct SPEC-022 invariant violation in the diff. The changed queries do not mint credits or alter verdict outcomes; the pool-expiry path still performs authoritative writer-side recording. Any finality/recovery split must preserve R-7, R-8, R-11, and R-12 revalidation requirements.

No files were modified.

VERDICT: 0 CRITICAL, 3 HIGH, 1 MEDIUM


