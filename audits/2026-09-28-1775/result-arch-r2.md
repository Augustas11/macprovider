## Raw output

```text
Architecture result: the hotfix materially relieves read-versus-writer starvation. Finality/display/payout reads use the four-connection read pool, referral reconciliation is bounded, and `RecoverLedger` no longer holds one writer transaction for the full scan. No CRITICAL or HIGH findings.

Findings:

1. **MEDIUM — RecoverLedger failure rows misrepresent committed partial work**

   `phase4-coordinator/internal/billing/recovery.go:45-65,68-114`

   Each hourly chunk commits independently, but the deferred failed-run insert always records zero rows and zero credit deltas. A failure after earlier chunks commit therefore leaves durable ledger changes while reporting a failed run with no work. A process crash between the last chunk commit and the final `complete` insert can leave no run record at all. The successful cross-boundary test does not cover this.

   Fix: create or update one durable run record before processing; update cumulative counters after every committed chunk; mark that same row `failed` with cumulative values on error. Add a forced second-chunk failure test and rerun test proving ledger idempotence and correct failed-run accounting.

2. **LOW — Read-only DSN enforcement is weak for non-file DSNs**

   `phase4-coordinator/internal/sqliteutil/dsn.go:56-76`; `phase4-coordinator/cmd/coordinator/main.go:354-366`

   If `DBPath` is supplied as an existing SQLite URI/DSN rather than a filesystem path, appending `mode=ro` is not a robust read-only contract. `query_only(true)` and the current fixed `SELECT` callers substantially mitigate this, so this is not a current money-path blocker.

   Fix: validate that the billing read pool receives a filesystem path, or parse and canonicalize SQLite URI parameters before adding `mode=ro`; add URI/DSN coverage.

3. **LOW — Recovery pool-attestation discovery still occupies the writer handle**

   `phase4-coordinator/internal/billing/recovery.go:527-544,572-594`

   `recoveryPoolAttestedRoutes` performs discovery, route loading, fence reads, and label reads through `s.db`, the shared single-connection writer pool. With a large pool-attested dataset, these reads can again delay hot-path writers. Production trusted pools are disabled, so this is not a blocker for this hotfix.

   Fix: move pure discovery/pre-read work to the billing read pool while retaining only the transaction-time fence/revalidation on the writer. Treat the trustpool `BEGIN IMMEDIATE` reconstruct path as a separate pre-enablement design gate.

4. **INFO — Same-file connection/FD budget is implicit**

   `phase4-coordinator/internal/requestlog/store.go:118-136`; `phase4-coordinator/cmd/coordinator/main.go:354-366`

   The deployment can now retain four billing reader connections in addition to the route-snapshot pool capped at four, the writer/auth/checkpointer/audit handles, and optional BYOM/trustpool readers. Under a low `RLIMIT_NOFILE` or enabled optional stores, startup or reader acquisition could fail.

   Fix: document and test the expected connection budget, expose pool stats, and verify the production file-descriptor limit against the maximum configured topology.

5. **INFO — WAL truncation may be deferred by reader snapshots**

   `phase4-coordinator/internal/sqliteutil/wal.go:48-65`; `phase4-coordinator/cmd/coordinator/main.go:2118-2159`

   The read pool can pin WAL snapshots. PASSIVE checkpointing does not wait for readers, while TRUNCATE may return busy and be deferred. This should not recreate writer starvation because TRUNCATE is attempted only during idle periods with a bounded timeout, and the read paths close their rows.

   Follow-up: monitor WAL size and checkpoint-busy/retry counts after rollout; alert if reader snapshots prevent truncation persistently.

Assessment of the requested invariants:

- Orphan quarantine, missing-credit creation, and attempt ordinals across an hourly boundary are covered by `recovery_chunk_test.go:14-47`; the half-open ranges and global ordinal SQL preserve successful-result equivalence.
- Pool-attestation pre-read is performed per chunk and the chunk transaction re-fences/revalidates before crediting.
- SPEC-022 settlement evidence invariants remain preserved: verified settlement still requires the existing finality/evidence path, and missing-receipt recording retains its writer transaction and re-read.
- The missing coverage is failure semantics and mid-run rerun behavior, captured by finding 1.

Verification: targeted tests passed for `internal/billing`, `internal/referralapi`, `internal/rewards`, and `cmd/coordinator`; `git diff --check` passed. The full repository test suite was not run.

VERDICT: 0 CRITICAL, 0 HIGH, 1 MEDIUM


