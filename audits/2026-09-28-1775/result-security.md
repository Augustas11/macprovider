## Raw output

```text
Audited `audits/2026-09-28-1775/full.diff` without modifying files.

1. **MEDIUM — Unbounded WAL-pinning reads**

   `phase4-coordinator/internal/billing/endpoints.go:681-712,1094-1120`  
   `phase4-coordinator/cmd/coordinator/main.go:369-370,3377-3384`

   Admin summary/providers and authenticated provider earnings use the four-connection reader pool with `r.Context()` but no query deadline. The HTTP server has `ReadTimeout` and `IdleTimeout`, but no `WriteTimeout`; an active client can keep requests alive indefinitely. Four long aggregate reads can hold WAL snapshots, preventing checkpoint truncation while money writes continue, potentially exhausting disk and reintroducing buyer-path degradation.

   Fix: apply explicit bounded read contexts to every reader-backed endpoint, with limits below the operational WAL/write budget; add a concurrency/WAL-growth regression test.

2. **LOW — `mode=ro` is not effective for ordinary paths**

   `phase4-coordinator/internal/sqliteutil/dsn.go:63-76`  
   `phase4-coordinator/internal/requestlog/store.go:126-136`  
   `phase4-coordinator/go.mod:21`

   The default path is a plain filename such as `coordinator.db`. With pinned `modernc.org/sqlite v1.52.0`, query parameters on non-`file:` DSNs are stripped before `sqlite3_open_v2`, so `mode=ro` does not enforce OS-level read-only access. Current moved operations are fixed `SELECT`/`QueryRow` calls and `query_only(true)` blocks normal SQL writes, so I found no current write or data-corruption path. However, an accidental future `ExecContext` or `PRAGMA query_only=OFF` would use a writable connection.

   Fix: construct a proper `file:` URI or use a connector with read-only open flags, and add a regression proving writes fail and the DB/WAL remains unchanged.

3. **LOW — New transaction metrics are silently discarded**

   `phase4-coordinator/internal/billing/{recovery.go:520,settlement_output.go:414,settlement_pool_labels.go:90,settlement_receipts.go:314}`  
   `phase4-coordinator/internal/stats/metrics/metrics.go:521-527`

   The new components (`ledger_recovery`, `settlement_attempt_output`, `settlement_pool_labels`, `settlement_receipt`) are constants, so label cardinality is bounded, but `allowMoneySQLiteComponent` rejects all four. `TransactObserved` therefore emits no metrics for these paths, hiding connection waits and transaction failures.

   Fix: add the four constants to the allow-list and assert their Prometheus series in tests.

No authn/authz regression, SQL injection surface, new data exposure, or buyer/provider ability to influence settlement state was found. The read handle is only used through fixed query methods, and existing operator/provider authorization remains in place.

VERDICT: 0 CRITICAL, 0 HIGH, 1 MEDIUM


