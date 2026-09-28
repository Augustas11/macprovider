## Raw output

```text
Result: the reader-pool change materially relieves finality/admin starvation, and the RecoverLedger durability semantics are now correct. I found one residual MEDIUM architecture issue; no CRITICAL or HIGH findings.

Findings:

- **MEDIUM — `phase4-coordinator/internal/billing/recovery.go:21,70-98,130-206`**  
  **Scenario:** RecoverLedger now commits hourly windows, but each window is still unbounded by row count or duration. A heavily concentrated hour can keep the sole writer connection occupied beyond the buyer’s 6-second budget. Startup recovery begins after listeners start (`cmd/coordinator/main.go:1512-1537`), and `runtime.Gosched()` occurs only after commit.  
  **Fix:** Bound writer occupancy by row count and/or maximum transaction duration, splitting large windows into smaller writer transactions while preserving cumulative run counters. Add per-chunk duration metrics and alerting.

- **LOW — `phase4-coordinator/internal/payout/runner.go:583-588`, `internal/payout/attempts.go:112-129`**  
  The payout runner’s pure `SelectReadyPayouts` query still uses the writer DB passed by `setupPayout` (`cmd/coordinator/main.go:1282`). A large payout backlog can briefly occupy the single writer connection. Provider wallet/accrual reads are correctly moved to the billing read pool, so this is a secondary residual.  
  **Fix:** Inject a read DB for candidate selection; retain the writer transaction’s authoritative re-read and claim.

- **LOW — `phase4-coordinator/cmd/coordinator/main.go:354-366`, `:2118-2158`**  
  Four read connections can pin WAL snapshots. PASSIVE checkpointing remains safe, but `TRUNCATE` is deferred whenever readers prevent full checkpointing, allowing WAL growth under long reads. The explicit 5/15-second deadlines and bounded pool make this non-blocking.  
  **Fix:** Alert on WAL size and `checkpointed < log` divergence; preserve the existing deadline requirements.

- **LOW — `phase4-coordinator/internal/billing/recovery.go:561-632`, `cmd/coordinator/main.go:1127-1148`**  
  Trusted-pool discovery and reconstruction still use the writer and can issue `BEGIN IMMEDIATE` when trusted pools are enabled. This is acceptable to carry because production trusted pools are disabled, but it must remain a documented pre-enablement prerequisite.  
  **Fix:** Design and test a separate read/fencing path before enabling trusted pools.

RecoverLedger verification:

- Hourly half-open windows prevent boundary duplication.
- Attempt ordinals use full request history, so chunk boundaries do not renumber retries.
- Orphan quarantine and missing-credit creation remain result-equivalent.
- Pool attestation is pre-read per chunk and re-fenced inside the writer transaction.
- `TestRecoverLedgerChunkedMatchesSingleWindowAcrossBoundary` passes.
- `TestRecoverLedgerMidRunFailureRecordsCommittedWorkAndRerunConverges` passes; committed counters survive failure and rerun converges.
- Remaining test gap: no concurrent pool-attestation mutation test across a chunk boundary, and the failure test does not assert every cumulative counter exactly.

SPEC-022 review found no violation: recovery uses persisted route snapshots and fails closed for missing evidence; it does not synthesize settlement snapshots or create receipt-less positive settlement.

Validation passed:

- `go test ./internal/billing -count=1`
- referral/requestlog/rewards/metrics package tests
- payout and WS package tests
- coordinator targeted tests
- `git diff --check origin/main -- phase4-coordinator`

VERDICT: 0 CRITICAL, 0 HIGH, 1 MEDIUM


