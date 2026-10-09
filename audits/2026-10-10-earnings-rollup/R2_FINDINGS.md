=================== code
## Raw output

```text
Round-1 CODE findings:

1. **FIXED — replacement writes leave the deleted bucket clean.**  
   [earnings_rollup.go:191](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:191) adds BEFORE INSERT/UPDATE invalidation for conflicting ledger rows; equivalent triggers cover related-table ID conflicts. The schema-key guard and replacement regression passed with `recursive_triggers=OFF`.

2. **FIXED — maturity can produce totals that never matched the view.**  
   [earnings_rollup.go:881](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:881) captures a cutoff, and [line 996](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:996) rejects reads spanning a provider maturity. The cached-A/live-B regression passed, confirming a retry returns 30 rather than the impossible 20.

3. **FIXED — reset permits generation ABA.**  
   [earnings_rollup.go:760](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:760) reads generation and epoch in the aggregate snapshot; [line 808](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:808) checks both before publishing. Reset preserves bucket rows and advances the epoch. The reset-between-read-and-publish regression passed.

4. **NOT FIXED — MEDIUM — the one-second refresh budget remains unenforced during SQLite lock waits.**  
   [earnings_rollup.go:721](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:721), [line 806](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:806).  
   The tick now supplies a one-second context, but `sqliteutil.Transact` reserves the shared writer connection and executes `BEGIN IMMEDIATE` with the existing **5,000 ms busy timeout**. In pinned modernc SQLite v1.52.0, context cancellation calls `sqlite3_interrupt`; the transaction-acquisition busy loop does not check that interrupt. Another connection holding the writer lock can therefore keep maintenance occupying the shared connection beyond its budget, delaying buyer writes.

   Evidence: a reduced WAL SQLite reproduction interrupted acquisition at one second but returned `database is locked` after **5.357 seconds**. Pinned-driver source confirms the same busy-loop behavior. The new deadline tests exercise sleeping hooks and a context-aware fake, not actual lock contention.

   **Fix:** cap lock acquisition on the reserved connection to the remaining tick budget, restore its timeout before returning it, and add a real two-connection WAL contention regression.

New issues:

- **LOW — pre-existing fallback reads still lack a common snapshot.**  
  [endpoints.go:1673](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/endpoints.go:1673).  
  Backfill, irregular timestamps, or exhausted maturity retries fall back to separate queries for range totals, lifetime pending, and faults. A concurrent mutation can make the returned fields disagree—for example, pending can become smaller than an earlier range total. This behavior predates the rollup, but remains outside its snapshot guarantee.  
  **Fix:** execute fallback aggregates in one snapshot with consistent maturity handling; test mutation between fallback aggregates.

Reviewed all six changed files in the complete two-commit diff and affected view/schema/transaction code. Nine focused billing regressions passed; `git diff --check origin/main...HEAD` passed. Checkout unchanged.

**Gate: FAIL — one unresolved MEDIUM.**

C/H/M/L = 0/0/1/1
=================== security
## Raw output

```text
Security gate: **FAIL — 2 MEDIUM, 1 LOW.** Reviewed the complete `origin/main...HEAD` diff and affected code. No files edited.

Round-1 security findings:

1. **NOT FIXED — one-second refresh budget.** The context deadline is now propagated ([main.go:3002](/Users/augstar/macprovider-1925b/phase4-coordinator/cmd/coordinator/main.go:3002)), but write-lock acquisition still uses the shared connection’s **5-second busy timeout**. The pinned driver interrupts SQLite on cancellation; its busy retry loop does not check that interrupt.
2. **NOT FIXED — refresh starvation, narrowed.** Dirty buckets now rotate, and failures no longer abort ordinary passes. However, stale buckets remain an unrotated oldest-first queue ([earnings_rollup.go:573](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:573)). A leading bucket that exhausts the deadline repeatedly can starve later providers.
3. **FIXED — bulk cache invalidation.** Reset now increments the epoch without deleting accumulated cache rows ([earnings_rollup.go:378](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:378)). Reads reject old epochs; recompute publication checks the captured epoch. The populated-cache regression explicitly checks that reset preserves rows.

Outstanding findings:

1. **MEDIUM — maintenance can monopolize the shared connection beyond its budget.**  
   [earnings_rollup.go:806](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:806), also backfill at line 721.  
   **Scenario:** another SQLite writer holds the lock when maintenance reserves the coordinator’s single shared writer connection and issues `BEGIN IMMEDIATE`. Cancellation after one second does not terminate the busy-handler loop; maintenance can retain that connection until the five-second timeout, queuing unrelated settlement and buyer writes behind it. The busy timeout/helper behavior is **pre-existing**; relying on it for the new maintenance budget introduces this coupling. Current deadline tests cover cooperative waiting and between-bucket cancellation, not lock contention.  
   **Evidence:** pinned-driver source inspection; an in-memory SQLite reproduction interrupted after 100 ms returned only after 565 ms with a 500 ms busy timeout. This reproduction used Python SQLite, not the Go driver.  
   **Fix:** bound maintenance lock acquisition on the reserved connection to the remaining budget, restoring its timeout afterward, or use a separately configured maintenance connection with short/nonblocking lock acquisition. Test actual held-lock contention with the pinned driver.

2. **MEDIUM — an expensive stale bucket can indefinitely block later refresh work.**  
   [earnings_rollup.go:573](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:573).  
   **Scenario:** the earliest stale bucket’s aggregation consistently exceeds the one-second deadline. It remains clean-by-generation but stale-by-time, so every tick selects it first again. Cancellation returns before later stale or dirty work executes. Ordinary persistent errors can likewise occupy all ten reserved stale slots. Later providers retain expensive live reads indefinitely. Introduced by this change; the round-2 dirty cursor does not cover this queue.  
   **Evidence:** the stale selection has no cursor; a reduced in-memory reproduction selected the same ten entries across three passes and never selected entry eleven.  
   **Fix:** rotate stale work too, advance past attempted buckets even on cancellation, and prevent a repeatedly slow bucket from consuming every tick’s first attempt. Add stale-error and stale-timeout starvation regressions.

New issue:

3. **LOW — startup still contains a data-dependent index build.**  
   [earnings_rollup.go:310](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:310).  
   **Scenario:** first installation builds `idx_lqr_force_credit_matures` synchronously over existing quarantine-resolution history. SQLite scans the table under a write transaction even though the index is partial. Large history can delay startup and block concurrent writers; the retry budget does not bound successful execution. This index is introduced here; existing migrations also contain synchronous index builds. The 17 GB database size alone does not establish this table’s size.  
   **Fix:** measure that table’s size and schedule the index build within an explicit rollout window, or remove the mandatory startup build through a bounded alternative.

Trigger lookups use existing primary/unique indexes, and settlement stamping skips generation writes. No new secret or request-content disclosure was found.

Validation: complete static review, small in-memory SQLite checks, and `git diff --check` passed. Go tests and production-scale checks were not run. Checkout unchanged.

C/H/M/L = 0/0/2/1
=================== architecture
## Raw output

```text
Architecture gate **FAIL**: one MEDIUM remains.

Round-1 architecture findings:

1. **FIXED — MEDIUM: replacement leaves old bucket trusted.**  
   [earnings_rollup.go:191](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:191): BEFORE INSERT/UPDATE triggers invalidate conflicting old rows without requiring recursive triggers. Related-table ID conflicts are covered at line 210. Replacement and unique-key coverage regressions were added.

2. **FIXED — MEDIUM: one-second refresh budget not propagated.**  
   [main.go:3002](/Users/augstar/macprovider-1925b/phase4-coordinator/cmd/coordinator/main.go:3002): passes now share the tick’s one-second context. Refresh checks cancellation between buckets, treats deadline exhaustion as yielding, and uses the buyer-activity gate. Slow-pass regressions were added.

3. **FIXED — LOW: synchronous bulk cache reset.**  
   [earnings_rollup.go:378](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:378): reset increments the epoch without deleting populated cache tables. Reads reject old epochs; background refresh rebuilds them.

4. **NOT FIXED completely — LOW: refresh starvation visibility.**  
   [main.go:3013](/Users/augstar/macprovider-1925b/phase4-coordinator/cmd/coordinator/main.go:3013): conflict/failure counters now produce warnings, improving visibility. Backlog age, old-epoch backlog, pass duration, and cache/live fallback usage remain unobserved. Successful maintenance can therefore appear healthy while historical earnings remain expensive.  
   **Fix:** expose bounded backlog, duration, and fallback metrics. Carried from round 1; not pre-existing on main.

5. **NOT FIXED — INFO: combined retention integration coverage.**  
   [earnings_rollup_test.go:833](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup_test.go:833): the schema guard is useful, but no combined archive/delete/read/recompute test exists. [PR #1909](https://github.com/Augustas11/macprovider/pull/1909), still open, adds `lrc.settled` and `settlement_evidence_archived_credits` as payable inputs; both lack invalidation coverage here and should trip that guard. Ordinary evidence DELETE triggers are covered, and a changed view fingerprints differently.  
   **Fix:** extend invalidation coverage during integration and assert exact earnings before retention, immediately after deletion, and after refresh.

New finding:

- **MEDIUM — old-epoch history can starve indefinitely behind dirty churn.**  
  [earnings_rollup.go:581](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:581), particularly line 588. Stale buckets receive reserved capacity, but old-epoch buckets receive only capacity left after dirty selection. Following a fingerprint reset, 50 persistently conflicting dirty buckets fill every pass, so unchanged historical buckets never rebuild. Rotating the dirty cursor does not provide fairness between these classes. Historical reads remain on the expensive live view and can continue timing out despite an operating refresher.  
  **Evidence:** a reduced in-memory SQLite reproduction selected 50 dirty buckets and zero old-epoch buckets on every repeated pass; the cold bucket remained at epoch 1.  
  **Fix:** reserve capacity for old-epoch work or rotate fairly between work classes. Add a regression combining an epoch reset, continuously conflicting dirty buckets, and cold historical buckets. Introduced by this change.

No immediate predecessor-binary schema incompatibility was identified through static inspection. The branch preserves SPEC-014 response semantics and SPEC-022 payable authority; retention integration needs the coverage above.

Reviewed the complete two-commit diff and touched code. `git diff --check origin/main...HEAD` passed. Go tests, production-scale timing, and executable downgrade testing were not run. No files edited.

C/H/M/L = 0/0/1/1
