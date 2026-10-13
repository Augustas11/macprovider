# Sustained-load acceptance harness (#1793)

`sustained_load_harness_test.go` checks the exit criterion in
`docs/design/money-datastore-1b-tokens-per-day.md` §4: 30 req/s sustained for
24 h through the full money path with 0 hot-path write failures, no evidence
loss, and weekly settlement finishing in under 60 s.

It runs the real `coordinator` and `gateway` binaries, which `TestMain` builds
from this checkout. Fake providers sign SPEC-015 settlement receipts, and the
coordinator runs with `verified_model_settlement_mode=enforce`. Every request
goes buyer → gateway → coordinator → provider, and settles through the
SPEC-022 verdict, ledger credit and gateway reconciler.

The load is **open loop**. Requests go out on a fixed schedule whether or not
earlier ones have finished. Latency is measured from the scheduled send time,
so a stalled writer shows up as latency and failures, not as a lower request
rate.

## Opt-in

The file has the `loadharness` build tag. `make test-integration` and CI never
compile it.

## Commands

Smoke run (2 min at 5 req/s, 30 s burst at 10 req/s, retention every 30 s):

```bash
cd test/integration
go test -tags loadharness -run TestSustainedLoadAcceptance1793 -count=1 -timeout 30m -v . \
  -args -lh.smoke -lh.out=/tmp/lh-smoke
```

Full run (24 h at 30 req/s, 1 h burst at 60 req/s in the middle, retention every 15 min):

```bash
cd test/integration
go test -tags loadharness -run TestSustainedLoadAcceptance1793 -count=1 -timeout 0 -v . \
  -args -lh.out="$HOME/loadharness-1793-$(date -u +%Y%m%dT%H%M%SZ)" \
        -lh.seed-db=/path/to/production-sized/coordinator.db
```

Leave out `-lh.seed-db` to start from an empty store. The seed file is copied,
never opened in place. Its `-wal` and `.route-snapshots` siblings are copied
too when they exist. Checkpoint the seed (`PRAGMA wal_checkpoint(TRUNCATE)`)
before copying. A seed must never contain real buyer data that is not allowed
on the run host.

**Start the 24 h run on a Sunday (UTC).** The weekly settlement and the nightly
reconcile run on wall-clock timers that config cannot change (see "Missing
coordinator hooks"). A run that starts on a Sunday covers Monday 00:00 UTC, so
a weekly settlement pass runs under load, as do the 00:00 nightly reconcile and
the 03:00 retention timer.

| Flag | Default | Smoke |
| --- | --- | --- |
| `-lh.rps` | 30 | 5 |
| `-lh.duration` | 24h | 2m |
| `-lh.burst-rps` | 60 | 10 |
| `-lh.burst-duration` (0 = no burst) | 1h | 30s |
| `-lh.burst-at` | middle of run | 60s |
| `-lh.interval` (JSONL record period) | 1m | 20s |
| `-lh.sample` (metrics scrape period) | 10s | 5s |
| `-lh.retention-every` (0 = off) | 15m | 30s |
| `-lh.providers` (2 slots each) | 8 | 2 |
| `-lh.stream-ratio` | 0.5 | 0.5 |
| `-lh.max-inflight` | 1024 | 1024 |
| `-lh.coord-log-level` | warn | warn |
| `-lh.drain` | 30s | 30s |
| `-lh.seed-db` | none | none |
| `-lh.out` | `$TMPDIR/macprovider-loadharness-<ts>` | same |

Explicit flags override the smoke preset.

Disk use: the gateway has no log-level setting and writes about 3 lines per
request, so a 24 h run writes about 2–3 GB of `gateway.log`. The coordinator
SQLite WAL also grows between checkpoints. Use a volume with at least 20 GB
free, or set `-lh.out` to one. Retention refuses to archive when free disk is
below its production floor (20 GiB / 10 %). That shows up as status
`archive_disk_low` in the retention passes.

## Output

- `metrics.jsonl`: one record per interval with these fields:
  - `sent`, `succeeded`, `failed{class}`
  - buyer `p50`/`p99` latency
  - `hot_path_write_failures`
  - `commit_p99_ms`, overall and per component: BEGIN IMMEDIATE → COMMIT from
    `money_sqlite_transaction_duration_seconds` on `/admin/metrics`
  - `outbox_pending`, `outbox_oldest_age_s`
  - `materializer_pending`, `materializer_lag_s`
  - WAL checkpoint and `ledger_recovery` (nightly reconcile) transaction
    counts and p99
  - settlement and retention passes that finished in the interval
  - file sizes of the coordinator DB, gateway DB, WALs, route-snapshot journal
    and retention archive
- `summary.json`: per-phase totals, all passes, final evidence counts, the
  config overrides and the criteria, with `verdict` set to `PASS` or `FAIL`.
- `coord.log`, `gateway.log`: child process output.

The test fails when the verdict is `FAIL`.

## Criteria

| Name | PASS when |
| --- | --- |
| `hot_path_write_failures_zero` | no `outcome="error"` on the hot-path `money_sqlite_*` components over the run |
| `commit_p99_below_50ms` | run-wide p99 of hot-path BEGIN IMMEDIATE → COMMIT is under 50 ms (histogram buckets 1 ms·2ⁿ, linear interpolation as in `histogram_quantile`) |
| `outbox_backlog_flat` | see "Flatness rule" below; applies to `settlement_receipt_audit_outbox_pending_rows`, tolerance 50 rows |
| `materializer_lag_flat` | same rule for `settlement_attempt_output_journal_oldest_pending_age_seconds`, tolerance 30 s |
| `weekly_settlement_pass_below_60s` | every observed settlement window took under 60 s, and at least one was observed |
| `retention_pass_below_60s` | every observed retention run took under 60 s, and at least one was observed |
| `burst_holds` | burst success ratio ≥ 99.9 % and achieved rate ≥ 95 % of target |
| `steady_success_ratio` | steady success ratio ≥ 99.9 % |
| `evidence_loss_zero` | every succeeded request has a closed `verified` settlement verdict, and no new verdict is anything else |

**Flatness rule.** The rule uses steady-phase samples after a 10 % warm-up,
split into four quarters. The series fails only when the four quarter medians
never decrease **and** the last quarter is more than the tolerance above the
first.

Hot-path components: `billing_hot_path`, `request_log_identity`,
`route_snapshot`, `route_snapshot_journal`, `settlement_attempt_output`,
`settlement_receipt`, `settlement_pool_labels`. Everything else
(`ledger_recovery`, `wal_checkpoint`, journal materialize) is background work.

**How settlement pass duration is measured.** `RunSettlement` stamps
`ledger_settlement_windows.completed_at_utc` when it acquires BEGIN IMMEDIATE,
and commits the marker last. The harness polls that table every second and
takes (first time the row is seen) − `completed_at_utc`.

A window committed before the first poll gets `upper_bound: true`. This is the
boot catch-up pass, and its figure includes the boot delay.

## Config overrides used

These overrides are also listed in `summary.json` under `config_overrides`:

- coordinator `settlement.verified_model_settlement_mode=enforce`
- coordinator `settlement.job_enabled=true`: weekly settlement catch-up at boot
  and on the Monday 00:00 UTC timer, plus the nightly reconcile at 00:00 UTC
- coordinator `settlement.min_payout_credits=0` (fixture value)
- coordinator `billing.retention.enabled=true`, with production defaults for
  every other retention knob. The harness POSTs
  `/admin/ledger/settlement-evidence-retention/run` every
  `-lh.retention-every`, because the in-process timer only fires at 03:00 UTC.
  It also records any run the timer starts.
- coordinator `logging.level=-lh.coord-log-level`
- gateway `quotas.account_concurrency=-lh.max-inflight` and
  `quotas.account_daily_tokens=1e12`, because one buyer key carries the whole
  load
- gateway `settlement.reconcile_interval_s=5`

The outbox drainer, the journal materializer and the WAL checkpointer keep
their compiled-in cadences, which range from a few seconds to 30 s. A 24 h run
already covers thousands of their cycles.

## Missing coordinator hooks

These are why some cycles cannot be compressed. Each is a production change and
is out of scope for this test-only harness.

1. **Weekly settlement has no compressible schedule and no run trigger.**
   `StartWeeklySettlement` (`internal/billing/settlement.go`) fires only at
   `NextMondayUTC`. No config field or admin route runs a pass on demand. Under
   load, a run sees a pass only at boot catch-up or when it spans Monday
   00:00 UTC.
2. **The nightly reconcile is fixed at 00:00 UTC**
   (`StartNightlyReconcile`, `internal/billing/recovery.go`). It has no
   interval override and no admin trigger.
3. **The evidence retention timer is fixed at 03:00 UTC**
   (`StartEvidenceRetention`). This is covered by the existing admin run route,
   which the harness uses.
4. **No duration metric or completion log for settlement and reconcile passes.**
   Only errors are logged. The harness infers settlement duration from the
   window marker, and reconcile cost from `ledger_recovery` transaction
   histograms.
5. **No gauge for the route-snapshot journal materializer backlog.** Only the
   settlement-attempt-output journal exports pending rows and oldest age.
