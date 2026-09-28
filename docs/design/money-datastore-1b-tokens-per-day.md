# Money datastore for 1B tokens/day (issue #1775)

Status: design, 2026-09-28. Owner: coordinator money path. Governs the durable
redesign that follows the #1775 hotfix PR. Normative changes still land through
SPEC-002 / SPEC-005 / SPEC-022 amendments before code.

## 1. What #1775 actually is (measured, not inferred)

Evidence: read-only probes of Pearl on 2026-09-28 (journal, `/metrics`, and a
`VACUUM INTO` snapshot of `coordinator.db` analysed off-host).

| Claim in the issue | Measured reality |
|---|---|
| "Settlement stopped fleet-wide at 23:59" | **False.** `RunSettlement` is weekly (Monday 00:00 UTC). It ran at `2026-09-28T00:00:00.4Z` and wrote `ledger_payout_ready` ids 16/17 (46,135 credits). Everything after 00:00 is unsettled by design until 2026-10-05. |
| "94k unsettled = outage" | Unsettled pre-Monday credits are (a) **carry-over below `min_payout_credits` = 500,000** (27,986 fully verified enforce credits, 1.04M provider credits, 09-14..09-28) and (b) **permanently ineligible enforce credits** — see below. |
| "Audit outbox backlog unbounded" | **False.** 19 pending, oldest 135 s, 2,092 drained in 3.4 h. The outbox is audit-only; settlement eligibility never reads it. |
| "stats-billing-mirror fails every 46 s" | **False.** The unit succeeds every run. The failed unit is a stale manual `systemd-run` transient from 2026-09-25. |
| "WAL never truncates, grows unbounded" | WAL file is 104 MB but holds ~663 live frames; PASSIVE checkpoints complete. Not the bottleneck. |

The real defects:

1. **Hot-path writer starvation by pool sharing.** `reqLogStore.DB()` is one
   `*sql.DB` with `SetMaxOpenConns(1)` shared by billing, admission, BYOM,
   explorer, payout reads, finality lookups, sweeps and admin aggregates.
   Hot-path transactions take ~7 ms, yet the `database/sql` wait before
   `BEGIN IMMEDIATE` averages ~0.96 s and 15/1076 waits exceeded the 6 s buyer
   budget in 3.4 h. Result: 40–70 failed hot-path/evidence writes per day.
2. **Evidence loss → unpayable credits.** Of 35,068 unsettled enforce credits
   (09-14..09-28), ~7,082 (≈20% by count, ≈215k provider credits) lack a
   verified verdict, attempt output, or route snapshot, or sit in a
   `pending/inconclusive` verdict that never closes. Under SPEC-022 enforce these
   can never settle. Ledger *credits* themselves are repaired by nightly
   `RecoverLedger` (1–16 rows/day recreated), but settlement *evidence* is not.
3. **Pathological background queries.** The referral serving reconciler query is
   quadratic (>300 s on a prod copy; times out on every 30 s run). The pool
   expiry sweep re-scans ~7.9k never-closing non-pool pending verdicts with a
   temp-B-tree sort every ≤2 min on the shared connection.
4. **Nightly reconcile holds the only writer for ~2 min** (00:00:14→00:02:13),
   which produces the midnight cluster of hot-path failures.
5. **Unbounded growth.** 5.16 GB for ~500k requests since 2026-06-30
   (≈10 KB/request all-in): `settlement_route_snapshots` 1.28 GB (≈4 KB/row),
   `settlement_receipt_verdicts` 0.95 GB, drained outbox 0.63 GB, legacy
   `audit_log` 0.62 GB. No retention on any of them.

The hotfix PR for #1775 addresses (1) partially and (3): a read-only pool for
billing reads and the explorer, the referral query rewrite, and observed labels
for the unobserved money transactions. It does not change the ceiling below.

## 2. Target load

Last full week (09-21..09-28): 86,778 requests, 142.7M tokens → 20.4M
tokens/day, ~1.64k tokens/request, 12.4k requests/day (0.14 req/s).

At 1B tokens/day and the same ratio: **~608k requests/day, ~7 req/s mean,
~25–30 req/s at a 4× diurnal peak** — ~50× today. Per request the money path
does ~5 durable writes (route snapshot, request log + credit, attempt output,
receipt verdict + outbox, outbox drain mark) → **~35 writes/s mean, ~150/s
peak**, and **~6 GB/day** of evidence at today's row sizes (~180 GB/month).

A single SQLite file on a 2 vCPU / 8 GB VPS cannot hold that: not because
SQLite's single writer can't do 150 short commits/s, but because (a) every
long reader or long write transaction on the box stalls the writer, (b) every
maintenance job (reconcile, sweeps, prune, VACUUM, backup) competes for the same
lock and disk, (c) a 180 GB/month file has no online compaction, and (d) the
updater's 6 GB DB-copy snapshots already take ~6 min of downtime today.

## 3. Architecture

### 3.1 Split by consistency class

| Class | Tables | Store |
|---|---|---|
| Money ledger (must be exact, small rows) | `ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, quarantine resolutions, reconciliation runs | **Postgres** (`macprovider_money` DB on the existing Postgres 16 cluster, later a managed instance) |
| Settlement evidence (append-only, fat, retention-bound) | route snapshots, attempt outputs, receipt verdicts, audit outbox | **Postgres, range-partitioned by day**; payloads compressed; retention by `DROP PARTITION` |
| Observability | `request_log`, routing decisions, provider connection events | Postgres stats cluster (already exists) or a separate SQLite file — never the money writer |

Postgres gives MVCC (readers never block writers), row-level locks (concurrent
writers), `SERIALIZABLE` or `SELECT … FOR UPDATE` where money invariants need
it, online `pg_dump`/base backups instead of stop-the-world copies, and
partition drop instead of `DELETE`+`VACUUM`. The coordinator already depends on
Postgres for stats, so this adds no new operational technology.

### 3.2 Hot path: one short transaction, evidence off the critical path

- Buyer hot path writes **exactly one** transaction: request credit +
  settlement subject row + a compact evidence-journal row (idempotency key
  `(account_scope, request_id, attempt_n, provider_id)`). Target p99 < 20 ms.
- Route snapshot, attempt output, receipt verdict and audit payload are appended
  to the evidence journal and materialised by an **always-on async worker**
  with its own connection pool, bounded batch sizes and per-row idempotency.
  No worker is gated on an "idle" signal; each is rate-limited instead.
- A missing-evidence verdict is only written after the worker's retry budget is
  exhausted, not because a 6 s deadline expired under contention. That removes
  the ~20% unpayable class at its source.

### 3.3 Settlement

- Keep weekly cadence and `min_payout_credits` (product policy), but run the
  eligibility query against Postgres with an index on
  `(settled, settlement_policy_mode, ts_utc)` and evidence joins on the
  idempotency key. Make the run **catch-up aware**: persist the last completed
  window and run a missed window on start, instead of relying on a timer that
  only fires while the process is up at 00:00 Monday. (Today a missed run loses
  no money, because eligibility has no lower time bound and credits carry over,
  but payout slips a full week.)
- Nightly `RecoverLedger` becomes a chunked, per-hour-window job with its own
  connection; it never holds a global lock.

### 3.4 Retention

- Evidence partitions: keep 35 days hot (covers the weekly window + 2 reconcile
  windows + dispute margin), then export to object storage (zstd JSONL, hashed
  manifest) and drop the partition.
- Audit outbox: drop drained rows after export; poisoned rows stay until
  acknowledged.
- Ledger rows: kept forever (small).

### 3.5 Capacity check at target

~150 writes/s peak of <2 KB compressed rows on Postgres with
`synchronous_commit=on` is comfortably inside a 4 vCPU / 16 GB instance with
SSD; ~6 GB/day uncompressed evidence becomes ~1.5 GB/day compressed and is
bounded at ~50 GB by the 35-day window. The weekly settlement query touches only
unsettled rows via a partial index.

## 4. Migration plan (each step is its own PR, SPEC-first where normative)

1. **Hotfix (#1775 PR).** Read pool, referral query rewrite, observed labels.
2. **Stop the bleeding in SQLite.** Chunk `RecoverLedger`; partial index for the
   pool sweep; close or exclude never-closing non-pool `pending` verdicts
   (needs a SPEC-022 decision: what is the terminal outcome of a pending
   non-pool verdict whose deadline passed?); catch-up for missed weekly runs.
3. **Evidence journal (SQLite first).** Introduce the single-transaction hot
   path + async materialiser behind the existing store interfaces, still on
   SQLite, so the behaviour change is isolated from the storage change.
4. **Postgres money schema + dual-write.** Write ledger + evidence to Postgres
   in the async worker; reconcile SQLite vs Postgres daily; no reads switch yet.
5. **Cut reads over**, then settlement, then the hot path; keep SQLite as
   read-only history for one full settlement cycle; then archive.
6. **Retention** (partition drop + export) and updater snapshot changes (no DB
   file copy; use `pg_basebackup` / WAL archiving).

Exit criterion for the redesign: a 30 req/s sustained synthetic load for 24 h
against a staging coordinator with 0 hot-path write failures, 0 evidence-loss
ineligible credits, and weekly settlement completing in < 60 s.
