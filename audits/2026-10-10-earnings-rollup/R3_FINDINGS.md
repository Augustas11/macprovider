=================== code
## Raw output

```text
Round-2 CODE findings:

1. **FIXED — REPLACE invalidation.** `earnings_rollup.go:192–234` invalidates conflicting old rows before replacement, including related-table ID conflicts. The replacement regression passed with recursive triggers disabled.
2. **FIXED — cached/live maturity coherence.** `earnings_rollup.go:1205` rejects a read spanning maturity. The cached-A/live-B regression passed.
3. **FIXED — reset generation ABA.** `earnings_rollup.go:969` captures generation and epoch together; publication checks both at line 1018. The reset-between-read-and-publish regression passed.
4. **FIXED — excessive SQLite lock wait.** `earnings_rollup.go:829` lowers the reserved connection’s busy timeout and restores it before reuse. The real two-connection held-lock regression passed.
5. **NOT FIXED completely — fallback consistency.** Concurrent-write isolation is fixed and its regression passed. Maturity consistency still fails when retries are exhausted, as detailed below.

Remaining issue:

- **MEDIUM — exhausted fallback retries return known-inconsistent earnings.**  
  [endpoints.go:1685](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/endpoints.go:1685), with separate payable queries at lines 1699 and 1710.  
  **Scenario:** a provider uses fallback and supplies a range containing every credit. Force credits mature between the range-total and lifetime-pending queries on all three attempts. Each attempt detects the race, but the wrapper returns the final mismatched figures with no error. A reduced SQLite reproduction produced `(total,pending)` pairs `(0,10)`, `(10,20)`, and `(20,30)`—although these fields must be equal at every instant for that range. A database snapshot does not freeze SQLite’s clock across statements.  
  **Fix:** compute ranged totals and lifetime pending in one aggregate statement, or propagate the maturity-race error after exhaustion. Add a regression crossing maturity on every fallback attempt. The general fallback inconsistency is **pre-existing**; silently accepting a detected race is introduced here.

Reviewed the complete three-commit diff and touched code. Eight focused billing regressions and `git diff --check origin/main...HEAD` passed. No files edited.

**Gate: FAIL — one MEDIUM remains.**

C/H/M/L = 0/0/1/0
=================== security
## Raw output

```text
Security gate: **FAIL — 1 MEDIUM remains.** No files edited.

Round-2 security findings:

- **FIXED — MEDIUM: maintenance lock waits exceeded the budget.** [earnings_rollup.go:829](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:829) now reserves the writer connection, lowers `busy_timeout` to at most 250 ms and half the calculated remaining budget, then restores it before returning the connection. Restoration failure discards the connection. Both backfill and publication use this helper. The added held-lock regression checks yielding and timeout restoration; I inspected it but did not run it.

- **NOT FIXED completely — MEDIUM: refresh starvation.** Slow stale buckets now receive slices and backoff, and all three classes rotate. However, advancing cursors past **unattempted** work still permits indefinite starvation under repeated deadline exhaustion. Evidence and fix below.

- **FIXED — bulk cache invalidation.** [earnings_rollup.go:378](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:378) retains cache rows and increments the epoch; publication checks generation and epoch at [line 1018](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:1018).

- **FIXED — LOW: synchronous quarantine-history index build.** The introduced `idx_lqr_force_credit_matures` build is removed. [earnings_rollup.go:1219](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:1219) uses the existing resolution-kind index. Initial rollup indexes cover newly created cache tables. **Pre-existing** startup index builds remain outside this diff.

Remaining finding:

- **MEDIUM — selection advances cursors beyond work that never runs.** [earnings_rollup.go:816](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:816), with deadline exits at [line 709](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:709).

  **Failure scenario:** with the default limit of 50, each queue selects 17 buckets and immediately advances its cursor to the seventeenth. Suppose 51 dirty buckets remain queued, and leading recomputes take approximately 240 ms before conflicting with concurrent writes. Each one-second tick attempts only the first five selected buckets. Selection cycles through three blocks of 17, repeatedly skipping their tails. A cold bucket in the final tail never rebuilds; earnings continue using expensive live reads indefinitely.

  **Evidence:** a reduced in-memory SQLite reproduction using the actual rotating-selection queries selected `p00–p16`, `p17–p33`, then `p34–p50`. After 12 simulated deadline-limited ticks, only 15 of 51 buckets had been attempted; `p50` never ran. Conflicts receive no backoff at line 724. Existing conflict/fairness regressions use `context.Background()` and therefore miss this case. This mechanism is introduced by `72188c42c`; it leaves the availability finding unresolved.

  **Fix:** advance each queue cursor only past attempted or explicitly deferred buckets, or retain unattempted selections for the next pass. Add a repeated one-second-deadline regression combining persistent conflicts with cold tail buckets.

No additional actionable security findings. Trigger lookups use existing primary/unique indexes, settlement stamping skips generation writes, and no new secret or request-content disclosure was identified.

Validation: complete diff and affected-code inspection, reduced SQLite scheduler reproduction, and `git diff --check` passed. Go tests and production-scale timing were not run. Checkout remains clean.

C/H/M/L = 0/0/1/0
=================== architecture
## Raw output

```text
Architecture gate: **FAIL — one MEDIUM remains.**

Round-2 architecture findings:

1. **FIXED — replacement invalidation.** [earnings_rollup.go:192](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:192): BEFORE INSERT/UPDATE triggers invalidate conflicting old rows independently of recursive-delete triggers.

2. **FIXED — refresh budget propagation and lock waits.** [earnings_rollup.go:829](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:829): maintenance bounds `busy_timeout`, restores it before releasing the connection, and yields on contention. The real two-connection lock regression passed.

3. **FIXED — synchronous bulk cache reset.** [earnings_rollup.go:378](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:378): reset advances the epoch without deleting cache rows. Populated-cache reset regression passed.

4. **NOT FIXED completely — LOW: refresh visibility.** [main.go:3044](/Users/augstar/macprovider-1925b/phase4-coordinator/cmd/coordinator/main.go:3044): backlog counts and full-view fallback logging are added. Backlog age and pass duration remain absent; hybrid reads doing substantial live-view work do not increment the fallback counter. Operators can see pending work but cannot assess its age or request cost. **Fix:** report duration, oldest outstanding work, and hybrid live-read usage. Carried finding; not pre-existing on main.

5. **NOT FIXED — INFO: retention integration coverage.** [earnings_rollup_test.go:833](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup_test.go:833): no combined archive/delete/read/recompute regression exists. [PR #1909](https://github.com/Augustas11/macprovider/pull/1909) remains open and introduces `lrc.settled` and `settlement_evidence_archived_credits` as payable inputs, beyond this branch’s invalidation coverage. The schema guard should detect that integration mismatch. **Fix:** extend triggers when integrating retention and verify earnings before archive, immediately after deletion, and after refresh.

6. **FIXED — old-epoch work receives no capacity under dirty churn.** [earnings_rollup.go:664](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:664): equal class shares and rotating interleaving remove that specific priority starvation. The old-epoch-under-dirty-churn regression passed. A separate within-queue defect follows.

New finding:

- **MEDIUM — advancing cursors past unattempted work permits indefinite starvation.** [earnings_rollup.go:816](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:816), with early returns at lines 709 and 726.

  **Failure scenario:** a stable dirty queue contains 51 buckets. Each pass selects 17 and immediately advances its cursor to the seventeenth. Four leading buckets take approximately 240 ms each and conflict; the fifth exhausts the remaining tick budget. Conflicts remain queued, and parent-deadline exhaustion returns without backoff. Subsequent passes select buckets 18–34, then 35–51, then repeat. The tails of all three batches are never attempted, including cheap historical buckets. Rotating the starting class does not help when only dirty work exists. Historical earnings continue requiring expensive live reads indefinitely.

  **Evidence:** an in-memory SQLite reproduction of the selection/cursor algorithm repeated this three-pass cycle across nine passes; 36 of 51 buckets were never attempted. This is an algorithm reproduction, not an end-to-end timing test.

  **Fix:** advance queue cursors through attempted work, preserving unattempted tails for subsequent passes. Add a deadline-constrained regression with persistent conflicts and cold buckets. Introduced by this branch.

Static review found no immediate predecessor-binary schema incompatibility. SPEC-014 response semantics and SPEC-022 payable authority remain unchanged. The mandatory startup maturity-index build identified previously has been removed. Executable downgrade and production-scale timing were not tested.

Reviewed the complete three-commit diff and touched code. Six focused billing regressions and `git diff --check origin/main...HEAD` passed. No files edited; checkout clean.

C/H/M/L = 0/0/1/1
