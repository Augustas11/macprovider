=================== code
## Raw output

```text
Gate fails: four MEDIUM findings in the complete `origin/main...HEAD` diff.

1. **MEDIUM — replacement writes leave the deleted bucket clean.** [earnings_rollup.go:151](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:151)  
   `INSERT OR REPLACE` can move an existing credit to another hour or provider. SQLite fires the implicit DELETE trigger only with `recursive_triggers=ON`; the pinned driver defaults to OFF and the DSN does not enable it. The new bucket becomes dirty, but the old bucket remains trusted and overstates earnings indefinitely. The reduced SQLite reproduction confirmed this. No current production replacement caller was found, but the promised write-independent exactness is incomplete.  
   **Fix:** enforce recursive triggers on every writer connection, including supported maintenance writers, or enforce replacement-safe writes. Add replacement tests that change hour, provider, and related-row identity.

2. **MEDIUM — maturity can produce totals that never matched the view.** [earnings_rollup.go:720](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:720)  
   Cache eligibility and live gaps execute in separate statements. A read transaction freezes database contents, but does not freeze SQLite `'now'`. Cached credit A can mature after eligibility checking, while later-maturing credit B becomes payable during a subsequent live read. The endpoint excludes A and includes B. Reproduction returned **20**, although coherent view totals were only **0, 10, 30**. Multiple live gaps have the same timing risk.  
   **Fix:** evaluate cache eligibility and all live aggregates at one shared maturity cutoff, or in one aggregate SQL statement. Add a test crossing maturity during the endpoint read; the existing test crosses between requests.

3. **MEDIUM — reset permits generation ABA.** [earnings_rollup.go:659](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:659)  
   Reset deletes buckets, and backfill recreates them at `gen=1`. An overlapping refresher can retain an old generation-1 aggregate while another initializer changes/reset the cache and recreates that bucket. Its publish checks only `gen`, so stale figures become clean. The state epoch already protects backfill, but does not protect recompute. This requires overlapping initialization/reset and refresh.  
   **Fix:** capture the state epoch in the recompute snapshot and require the same epoch in its write transaction. Add a reset-between-read-and-publish regression using the existing hook.

4. **MEDIUM — the one-second refresh budget is not enforced.** [main.go:2998](/Users/augstar/macprovider-1925b/phase4-coordinator/cmd/coordinator/main.go:2998)  
   Each pass gets a **30-second** context and can backfill plus recompute 50 buckets. The one-second deadline is checked only after that work finishes. Expensive buckets or lock waits can therefore sustain read load and writer transactions well beyond the claimed duty cycle; overdue ticker events can trigger another pass immediately.  
   **Fix:** pass the tick deadline into the refresher and honor it between buckets and before write transactions. Add a slow-pass cancellation test.

All findings are introduced by this change. Reviewed all six changed files and affected view/connection code. Validation used reduced in-memory SQLite reproductions; Go tests were not run. Checkout unchanged.

C/H/M/L = 0/0/4/0
=================== security
## Raw output

```text
Security gate: **FAIL — 3 MEDIUM findings.** Reviewed the complete diff and touched code; no files edited.

1. **MEDIUM — The one-second refresh budget is not enforced.**  
   [main.go:3002](/Users/augstar/macprovider-1925b/phase4-coordinator/cmd/coordinator/main.go:3002)  
   Each pass receives a fresh **30-second** context; the one-second deadline is checked only after the pass returns. A large bucket or SQLite lock wait can therefore consume far beyond the stated budget. Subsequent ticks can keep maintenance running under sustained backlog, competing with settlement for IO and the shared writer connection.  
   **Fix:** give each pass the remaining tick deadline, enforce smaller write-transaction bounds, and use the existing money-path maintenance yielding policy. Add a slow-pass cancellation test.

2. **MEDIUM — Persistently dirty leading buckets can starve every later provider.**  
   [earnings_rollup.go:465](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:465)  
   Every pass selects the first 50 dirty index entries without a cursor. Buckets whose generation repeatedly changes during recomputation remain at the front. With 50 such buckets, later providers never refresh; stale-bucket processing is also excluded. Their earnings reads retain the expensive live-view path and can continue exceeding the endpoint timeout. This introduces cross-provider availability coupling.  
   **Fix:** rotate selection with a resumable cursor and reserve capacity for stale buckets. Isolate persistent bucket failures so they cannot repeatedly abort progress. A tiny SQLite reproduction confirmed identical selections across three passes while provider 51 was never selected.

3. **MEDIUM — Cache invalidation performs an unbounded startup write transaction.**  
   [earnings_rollup.go:289](/Users/augstar/macprovider-1925b/phase4-coordinator/internal/billing/earnings_rollup.go:289)  
   A fingerprint change or missing trigger deletes both populated cache tables inside one `BEGIN IMMEDIATE` transaction. Its duration and WAL growth scale with cache size. On a mature deployment, an otherwise additive upgrade can prolong startup and monopolize SQLite’s writer, potentially causing concurrent money writes to exhaust their busy timeout. The 60-second retry budget bounds retries, not transaction execution.  
   **Fix:** invalidate through an epoch switch, rebuild incrementally, and reclaim obsolete cache data in bounded batches. Add coverage for resetting a populated cache.

These are introduced findings. Validation was read-only inspection, the small SQLite queue reproduction, and `git diff --check` (passed). Go tests and production-scale latency checks were not run.

C/H/M/L = 0/0/3/0
=================== architecture
## Raw output

```text
Architecture gate **FAIL**: two MEDIUM findings. Reviewed the complete diff and affected code; no files edited.

1. **MEDIUM — Replacement can leave an old bucket permanently trusted.**  
   `phase4-coordinator/internal/billing/earnings_rollup.go:150`  
   Writer DSNs do not enable `recursive_triggers`. An `INSERT OR REPLACE` replacing a credit with the same unique request tuple but a different `ts_utc` fires the insert trigger for the new hour, while SQLite suppresses the implicit delete trigger for the old hour. The old cached credits remain falsely clean, overstating lifetime/pending totals indefinitely. No current production replacement statement against these inputs was found, but the advertised coverage of arbitrary writers is incomplete. An isolated SQLite reproduction confirmed the missed old generation.  
   **Fix:** invalidate conflicting old rows before insertion, covering every conflict key, or enforce recursive triggers on every writer—including supported downgrade binaries. Add replacement tests across hours and identities.

2. **MEDIUM — The one-second refresh budget is not enforced.**  
   `phase4-coordinator/cmd/coordinator/main.go:2998`  
   Each pass receives a **30-second** context; the one-second deadline is checked only after it finishes. A pass can recompute 50 expensive hours and write a backfill batch containing up to 2,000 distinct buckets. On the loaded database, this can sustain read pressure and repeated contention for the single money writer far beyond the claimed duty cycle. Overrunning ticks can also leave the next ticker event immediately ready. The refresher test uses instantaneous calls and misses this scenario.  
   **Fix:** propagate the tick’s actual deadline through the pass, stop between buckets, treat budget exhaustion as normal yielding, and use the existing money-maintenance activity gate. Test slow passes and contention.

3. **LOW — Cache reset is synchronous and proportional to accumulated cache size.**  
   `phase4-coordinator/internal/billing/earnings_rollup.go:289`  
   A changed fingerprint or missing trigger deletes both entire cache tables under `BEGIN IMMEDIATE` before startup completes. First installation is lightweight, but subsequent resets are not necessarily the documented “one short write transaction.” The 60-second retry budget bounds lock retries, not successful deletion work.  
   **Fix:** invalidate via an epoch/state transition immediately, then reclaim obsolete cache rows in bounded background batches.

4. **LOW — Successful refresh starvation is largely invisible.**  
   `phase4-coordinator/internal/billing/earnings_rollup.go:511`  
   Generation races are silently skipped; only errors and backfill completion are logged. A refresher that repeatedly loses races can appear healthy while earnings continues using expensive live reads.  
   **Fix:** expose bounded metrics for dirty/stale backlog, recompute conflicts, pass duration, and cache versus live fallback usage.

5. **INFO — Retention compatibility needs a combined integration test.**  
   `phase4-coordinator/internal/billing/earnings_rollup.go:196`  
   [PR #1909](https://github.com/Augustas11/macprovider/pull/1909) remains open and introduces archive-aware payable semantics. Its view change should reset this cache; evidence deletes should invalidate affected hours. Those properties are not yet tested together. Confirm every new eligibility input has invalidation coverage and test earnings before deletion, immediately afterward, and after recomputation.

The SQLite cache is a defensible design for exact money reads; the asynchronously populated Postgres mirror is not an equivalent freshness authority. No obvious immediate predecessor-binary schema incompatibility was found. Validation comprised static review, `git diff --check`, and the isolated SQLite reproduction; Go tests were not run.

C/H/M/L = 0/0/2/2
