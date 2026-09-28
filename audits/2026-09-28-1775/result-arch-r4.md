## Raw output

```text
Architecture re-audit result: the read pool materially relieves the observed writer starvation, and I found no SPEC-022 settlement-evidence violation. One MEDIUM remains.

Findings

- MEDIUM — Recovery transaction duration is still not hard-bounded by row count  
  File: [recovery.go:21-26](/Users/augstar/macprovider-1775/phase4-coordinator/internal/billing/recovery.go:21), [recovery.go:75-94](/Users/augstar/macprovider-1775/phase4-coordinator/internal/billing/recovery.go:75)

  A five-minute time window can contain an arbitrary number of request rows. A burst or backlog exceeding roughly 2,000–2,500 rows can again hold the single writer beyond the six-second buyer-write budget; at the measured 2.4 ms/row, 10,000 rows would occupy it for roughly 24 seconds. The tests prove result equivalence and mid-run recovery, but do not establish a hard occupancy bound.

  Fix: add a deterministic maximum-row/keyset boundary, using `(ts_utc, id)` ordering, while retaining the existing half-open semantics and cumulative run accounting.

Non-blocking follow-ups

- LOW — Trusted-pool recovery still performs writer transactions per candidate at [recovery.go:566-615](/Users/augstar/macprovider-1775/phase4-coordinator/internal/billing/recovery.go:566). This is acceptable for the current production configuration because trusted pools default to disabled at [config.go:1609-1616](/Users/augstar/macprovider-1775/phase4-coordinator/internal/config/config.go:1609). Treat the reader/fencing redesign as a prerequisite before enablement.

- LOW — `SelectReadyPayouts` still reads through the writer DB at [attempts.go:112-129](/Users/augstar/macprovider-1775/phase4-coordinator/internal/payout/attempts.go:112). Move candidate discovery to the read pool later, retaining the writer-side claim/re-read.

- LOW — Read snapshots can defer PASSIVE/TRUNCATE WAL progress at [main.go:2135-2157](/Users/augstar/macprovider-1775/phase4-coordinator/cmd/coordinator/main.go:2135). The new deadlines bound this risk, but WAL growth and checkpoint deferrals should be monitored.

- LOW — Non-file DB-path handling remains imperfect at [main.go:356-366](/Users/augstar/macprovider-1775/phase4-coordinator/cmd/coordinator/main.go:356). `mode=ro` is reliable for file-backed SQLite, while URI/in-memory configurations remain a documented follow-up.

The four-connection billing pool is bounded and reused by same-file payout reads; finality discovery reads now avoid the writer, while the writer-side evidence re-read remains necessary for correctness. Recovery chunking preserves orphan quarantine, missing-credit creation, cross-boundary attempt ordinals, durable failure accounting, and rerun convergence in the targeted tests. SPEC-022’s no-synthetic-route and verified-receipt requirements remain intact.

Validation passed: `git diff --check`; targeted billing recovery, referral serving, and coordinator payout-reader tests.

VERDICT: 0 CRITICAL, 0 HIGH, 1 MEDIUM


