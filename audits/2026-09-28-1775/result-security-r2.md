## Raw output

```text
Security review completed for `git diff origin/main -- phase4-coordinator`.

Findings:

- LOW — `phase4-coordinator/internal/sqliteutil/dsn.go:63-76`, used by `requestlog/store.go:126-136` and `cmd/coordinator/main.go:357,3685`
  
  For ordinary filesystem paths, modernc SQLite strips the query string before opening the database, so `mode=ro` is not applied. `_pragma=query_only(true)` is applied afterward, preventing normal SQL writes, but the connection still opens with read-write/create semantics. A missing alternate payout DB could therefore be created, and future code could weaken the only effective protection.

  Fix: normalize paths to `file:` URIs before adding `mode=ro`, fail closed on missing files, and add a regression test proving both existing and missing-path behavior plus rejected writes.

- LOW — `phase4-coordinator/cmd/coordinator/main.go:362-364`, `internal/explorer/handlers.go:62-75`
  
  The reader pool now permits four simultaneous explorer snapshots. Each request is bounded to the configured maximum of five seconds, but an authenticated operator can continuously renew slow requests, keeping at least one WAL snapshot active and delaying checkpoints while writers grow the WAL. This is a residual availability risk, not an unbounded single-request context issue.

  Fix: add a process-wide limit on concurrent reader-backed explorer queries and monitor/enforce WAL growth or checkpoint health.

- INFO — `phase4-coordinator/internal/trustpool/durable_store.go:2595`, `internal/sqliteutil/transact.go:70`
  
  Trusted-pool reconstruction still uses `BEGIN IMMEDIATE` for read-heavy reconstruction. This remains acceptable to carry as a documented pre-enablement prerequisite because the path is gated by `cfg.TrustedPools.Enabled` at `cmd/coordinator/main.go:1127` and is disabled in production. Before enabling trusted pools, replace this with a read-only snapshot plus explicit fencing/revalidation design.

No injection, authn/authz, data-exposure, metrics-cardinality, or buyer/provider money-state findings were identified. Changed SQL uses fixed statements and bound parameters; moved reads remain SELECT-only, contexts are bounded, and settlement authorization retains writer-side revalidation. Targeted package tests passed.

VERDICT: 0 CRITICAL, 0 HIGH, 0 MEDIUM


