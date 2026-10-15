# Settlement evidence retention (SPEC-022 R-15)

Related: #1793. This runbook covers the retention job that moves settled
SPEC-022 evidence out of the hot coordinator SQLite database. The rows it moves
are route snapshots, receipt verdicts, attempt outputs, compute-integrity
captures, delivered audit-outbox rows, and the matching mirrored rows in the
`coordinator.db.route-snapshots` journal. The job writes them to a compressed,
checksummed archive on the coordinator host, verifies the archive by reading it
back, and deletes only rows that match it column for column. It never deletes
ledger credits, operator credits, payouts, settlement windows, or quarantine
resolutions.

Retention is **on by default**. Once the release is deployed, it runs nightly
at 03:00 UTC with the bounds below and needs no operator step. The kill switch
is `billing.retention.enabled: false` plus SIGHUP.

Before any Pearl step, read `docs/runbooks/pearl-coordinator-rollout.md` and
tell the operator the expected downtime. Live changes go through
`scripts/ops/pearl-runtime.sh` (status, next, then `next --run`). The
`coordinator.yaml` edits below are manual operator steps.

## What is eligible

The job works on whole requests. A request leaves hot storage only when every
one of these is true:

- No ledger credit for the request is quarantined.
- Every credit is payable (`spec022_payable_request_credits`).
- No credit has a force-credit hold or any other quarantine resolution.
- Every credit is either unsettled with no payout id, or settled into a
  `ready` or `consumed` (never `voided`) payout. Since SPEC-022 v0.4.5 a
  credit does not have to be settled: its tombstone keeps it payable, and the
  weekly settlement settles it through the tombstone into the same payout
  with the same sums.
- Every credit was created, and every verdict closed, before the finality
  point T (`cutoff_window_end_utc` / `credit_age_cutoff_utc` in the report).
  T is the earlier of now minus `verdict_close_grace_hours` (default 48) and
  the start of the newest completed nightly reconcile, but never earlier than
  the reconcile horizon (nightly and startup windows plus the recovery grace
  and a day). With the nightly reconcile running, evidence leaves about two
  days after its verdict closed instead of after two settlement windows.
- Every verdict is closed, and none is pending or quarantined.
- Every audit-outbox row is drained, and none is poisoned.
- Every attempt-output journal row is materialized.
- Every route-snapshot journal row is mirrored, with the same digest.
- The request does not hold its provider's earliest verified verdict. That
  verdict is the referral evidence, so it stays hot.
- No attempt is relay-blind (SPEC-022 R-14). The gateway's relay-blind
  recovery reads coverage from the route snapshot, so those requests stay hot.
- Every account scope on the request's credits and verdicts has a route
  snapshot, and at deletion every scope's settlement finality is closed. The
  job stores that finality with the deletion, so a buyer reservation still
  held at the gateway settles from it later.
- Every route snapshot the SPEC-047-R012 pool-proven rollup counts
  (enforce-mode `pool_manifest` snapshots with a `pool_id`) is held, with its
  finality, in `pool_proven_rollup_attempts`; until the rollup refresh
  records it, the request stays hot
  (`skipped_requests.pool_proven_rollup_pending`).

## Configuration

`coordinator.yaml`, `billing.retention` (all reloadable with SIGHUP):

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Arms the nightly 03:00 UTC run and `POST .../run`. `false` is the kill switch. Dry runs work either way. |
| `archive_dir` | empty | Absolute directory for `settlement-evidence-*.jsonl.gz` archives and their `.manifest.json` files. Empty means `retention-archive/` in the directory of the coordinator database file (for a database at `/var/lib/macprovider/coordinator.db`: `/var/lib/macprovider/retention-archive/`). Created with mode `0700` on first use. |
| `archive_min_free_bytes` | `21474836480` (20 GiB) | A run that would write a new archive is refused (`refused_archive_disk_low`) while the archive filesystem has less free space. `0` disables this bound. |
| `archive_min_free_percent` | `10` | Same, as a percentage of the archive filesystem. `0` disables this bound. |
| `verdict_close_grace_hours` | `48` | Grace after verdict close before evidence may leave (SPEC-022 R-15.2), in `[24, 720]` and above `settlement.startup_reconcile_window_hours`. |
| `min_settlement_cycles` | `2` | Still loads and is validated (floor 2); no longer gates evidence retention since SPEC-022 v0.4.5. |
| `batch_size` | `50` | Requests deleted per short `BEGIN IMMEDIATE` transaction. |
| `batch_pause_ms` | `200` | Pause between delete batches and between vacuum steps. |
| `max_requests_per_run` | `20000` | Requests per archive (the key keeps its old name so existing configs load). A run drains: it writes, verifies, and deletes archive after archive along a scan lap (below) until the lap completes, `max_scan_rows_per_run` is reached, or `run_budget_minutes` is spent. Memory does not grow with it: requests are streamed into the archive one at a time, and deletion re-reads the archive one batch at a time (at most `batch_size` requests; a batch is also flushed once it reaches 16 MiB of archived payload, so it can exceed 16 MiB by at most one request). |
| `max_scan_rows_per_run` | `5000000` | Ledger credits scanned per run, a backstop: the run budget is normally the limit. Laps start at the archived low watermark, so a run does not re-walk archived credits; a lap that hits this bound continues in the next run. |
| `run_budget_minutes` | `30` | Wall-clock budget of one run, in `[1, 240]`. Checked between scan chunks, between archives, and between delete batches; an archive cut short stays pending and the next run resumes it, skipping the requests it already deleted. |
| `incremental_vacuum_pages` | `2048` | Pages released per `PRAGMA incremental_vacuum` step. |
| `incremental_vacuum_max_steps` | `256` | Steps per run, per database file. |
| `offhost_verify_command` | empty | Optional. Absolute argv. The job appends `<archive_path> <sha256_hex>`. Exit 0 means that checksum is confirmed at an off-host destination. When set, it is an extra check before deletion; when empty, nothing is skipped. |
| `offhost_verify_timeout_seconds` | `300` | Limit for one verify command. |

### Scan laps, the watermark, and the holds table

A lap walks the ledger from the archived low watermark to its end, across as
many runs as it takes. Every credit at or below the watermark is archived,
kept hot for good (`provider_first_verified_verdict`, `relay_blind_attempt`,
`credit_quarantine_resolution`, `already_archived`), or named in the holds
table (`settlement_evidence_retention_holds`). The holds table takes requests
that may still become eligible but can stay that way for a long time: old
unsettled credits (an unresolved quarantine, a provider below the minimum
payout), an open verdict, an undelivered outbox row, a deletion re-check
refusal, and so on. Each lap starts by re-checking every hold below the lap
start: a hold that now qualifies is archived, a permanent one is dropped.
Only too-young credits (inside the reconcile horizon, or settled into a
window less than `min_settlement_cycles` old) pin the watermark; they sit at
the end of the ledger.

When a lap completes, the watermark moves up and the run stops:
`stop_reason` is `drained` when that lap found no eligible request, else
`lap_complete`. The next run's lap shows whether the backlog drained.
`backlog_drained` is persisted: it is true while the last completed lap
found nothing eligible.

### Optional off-host verify command contract

Retention does not need an off-host copy to delete: the local archive is
re-read and checked before anything leaves. An operator who also wants an
off-host copy confirmed before deletion configures this command. It runs
without a shell and with a minimal `PATH`. It may copy the
archive and its manifest to the off-host destination itself. It must exit 0
only after it has read back the remote file's SHA-256 and compared it with the
second argument. Any other exit refuses deletion and leaves the archive in the
`exported` state. The next run resumes that archive and does not write a new
one. Keep the script outside the repository and make it root-owned and not
writable by group or other. Example shape, with placeholders:

```bash
#!/usr/bin/env bash
set -euo pipefail
archive="$1"; want="$2"
rsync -a "$archive" "$archive.manifest.json" <backup-host>:<backup-dir>/
got="$(ssh <backup-host> sha256sum "<backup-dir>/$(basename "$archive")" | cut -d' ' -f1)"
[ "$got" = "$want" ]
```

## 1. Deploy the code (retention on)

1. `scripts/ops/pearl-runtime.sh status`, then `next`, then
   `MACPROVIDER_OPS_OWNER=<label> scripts/ops/pearl-runtime.sh next --run`
   for each step of the runtime train. State the downtime from
   `docs/runbooks/pearl-coordinator-rollout.md` first.
2. On startup, the migration creates `settlement_evidence_archives`,
   `settlement_evidence_archived_credits`,
   `settlement_evidence_archived_verdict_counts`, and
   `settlement_evidence_retention_state`. It also rebuilds the payable view
   with the archived-credit branch and records billing compatibility floor 4
   (section 6: from here on, roll forward only).
3. Each nightly run drains for up to `run_budget_minutes`: archives of at
   most `max_requests_per_run` requests, deleted `batch_size` requests per
   short transaction with `batch_pause_ms` between batches. A backlog larger
   than one budget drains over several nights; it never holds the writer
   for long. The run's log line reports:
   - `stop_reason`: `drained`, `lap_complete`, `run_budget`, `scan_bound`,
     or `refused` (`status` names the refusal; `archives` and
     `deleted_requests` still count what the run deleted before it);
   - `backlog_drained`, `laps_completed`, `lap_eligible_requests`,
     `last_lap_eligible_requests`, `watermark_credit_id`, and
     `held_requests` (the holds table);
   - `last_lap_skipped`: the last completed lap's skip counts by reason;
   - `backlog_candidate_credits`: the held requests plus the settled,
     unarchived credits above the watermark past both cutoffs, an upper
     bound of the remaining eligible backlog (`-1` if not computed);
   - `auto_vacuum` per database file.

   A drained backlog does not bring `backlog_candidate_credits` to zero:
   its floor is the held requests and the too-young credits, and
   `last_lap_skipped` names them by reason. `backlog_drained=true` is
   the drain signal. A watermark that climbs and a
   `last_lap_eligible_requests` that falls night over night mean draining. To hold
   retention off for this deploy, set `billing.retention.enabled: false`
   in `coordinator.yaml` before the runtime train step.

## 2. Dry run

```bash
curl -fsS -H "Authorization: Bearer $OPERATOR_KEY" \
  https://<coordinator-host>/admin/ledger/settlement-evidence-retention
```

The report has:

- `cutoff_window_end_utc`: the settlement-window finality point;
- `credit_age_cutoff_utc`: the reconcile horizon;
- `eligible_requests`: what the next new archive would hold (at most
  `max_requests_per_run`; the run itself drains further, and resumes a
  pending archive first);
- `tables.<table>.rows` and `tables.<table>.payload_bytes`: the summed column
  lengths, an estimate of what leaves;
- `skipped_requests` counts by reason.

`cutoff_window_end_utc` is empty until three or more weekly settlements have
completed. Use the dry run to preview what the next nightly run moves. A dry
run scans at most `max_scan_rows_per_run` credits from the
lap cursor and writes nothing.

## 3. Watching the first live run

1. Check that the archive filesystem (default: the database's filesystem,
   `retention-archive/` next to the database) has room above the free-space
   floor for the dry-run payload. Gzip usually makes the archive several
   times smaller than the payload estimate. To put archives elsewhere, set
   an absolute `archive_dir` and reload with SIGHUP.
2. Optional: install an off-host verify command, test it by hand on a scratch
   file, set `offhost_verify_command`, and reload with SIGHUP.
3. Wait for the nightly run, or start one now:

   ```bash
   curl -fsS -X POST -H "Authorization: Bearer $OPERATOR_KEY" \
     https://<coordinator-host>/admin/ledger/settlement-evidence-retention/run
   curl -fsS -H "Authorization: Bearer $OPERATOR_KEY" \
     "https://<coordinator-host>/admin/ledger/settlement-evidence-retention?report=last"
   ```

4. The run is done when it reports `status: deleted`, with
   `deleted_requests`, `delete_batches`, `tables.<table>.deleted_rows`,
   `archive_file`, `archive_sha256`, and `archive_bytes` set;
   `archive_free_bytes` and `archive_disk_bytes` show the archive
   filesystem at the start of the run. Each nightly run logs a
   `settlement evidence retention: level=... status=... archive_bytes=...`
   line with these fields, next to the `settlement_evidence_retention`
   event. Other statuses:
   - `refused_archive_disk_low` (logged with `level=warn`): the archive
     filesystem is below `archive_min_free_bytes` or
     `archive_min_free_percent`, checked before the export and again every
     4 MiB of archive written. The partial archive is removed and nothing
     is deleted; the next run re-selects the same requests. Free space or
     move `archive_dir`.
   - `refused_offhost_unverified`: only with an off-host command configured.
     The archive is kept and nothing is deleted. Fix the command; the next
     run resumes this archive.
   - `refused_archive_invalid`: the archive failed its checksum, size, parse,
     or count check. It is marked `failed` and nothing is deleted. The next
     run writes a fresh archive.
   - `nothing_eligible`.

   `skipped_requests.hot_row_changed_since_archive` counts requests left hot
   because a row changed after export; the next archive picks them up.
   `route_snapshot_journal_kept_rows` counts archived journal rows left hot
   for the same reason. If a run stops after the main delete commits but
   before the journal step, the archive stays `exported` (or
   `offhost_verified`) and the next run finishes the journal step before
   marking it `deleted`.
5. Retention never deletes archive files. Archives are the only copy of the
   deleted evidence; include `archive_dir` in the host's backups.

Weekly settlement, nightly reconcile, payout claims, earnings, and the billing
mirror keep working on archived requests:

- Tombstones keep archived credits payable and verified.
- Archived verdict counts feed reward unlock and the unranged receipt
  summaries.
- Ranged receipt diagnostics and the admin verdict counters count hot rows
  only.
- A settlement-finality lookup for an archived request returns the finality
  stored when it was deleted (`settlement_evidence_archived_finality`), so a
  reservation the gateway still holds can settle. A receipt lookup returns
  not found.

## 4. Reclaiming space: auto_vacuum

Deleted pages go to the freelist. `PRAGMA incremental_vacuum` returns them to
the filesystem only when the database is in `auto_vacuum = INCREMENTAL` mode.
The `vacuum` entries in the report show `auto_vacuum_mode`, the freelist
before and after, `needs_one_time_conversion`, and `skipped` with the reason
no step ran. On an `auto_vacuum = NONE` database the step is skipped and the
coordinator logs `auto_vacuum=none incremental_vacuum=skipped` for that
file. The job never runs a full `VACUUM`. Free pages are reused by new writes either way, so the file stops
growing even without the conversion.

The one-time conversion rewrites the whole file and needs the coordinator
stopped, so it waits for the drain (`backlog_drained=true`). It runs through
the ops entry point, never by hand. The entry point reads the three files'
`auto_vacuum` mode and the last retention lap read-only. It refuses until
the drain signal holds, states the downtime first, and takes the live-ops
lock and the three Pearl locks (updater, deploy, deploy-operation). It
checks free space on the database filesystem for three times the files'
size (a backup copy, VACUUM's temporary copy, which it keeps there with
`SQLITE_TMPDIR`, and the WAL), then stops the coordinator. It runs `PRAGMA quick_check` on the
coordinator database, its `.route-snapshots` journal, and the audit database
(`coordinator-audit.db` in the same directory) and refuses, starting the
coordinator again, if any fails. It then takes a fresh
`VACUUM INTO` backup next to each file (`<file>.pre-incremental-<UTC stamp>`,
named in the output). It runs `PRAGMA auto_vacuum = INCREMENTAL; VACUUM;` on
each file with the SQLite 3.53.2 CLI from `ops/pearl-updater`, runs
`quick_check` again, and starts the coordinator. If `quick_check` fails after
the VACUUM, it leaves the coordinator stopped and names the backup to
restore. Remove the backups once the coordinator has run cleanly on the
converted files. Read
`docs/runbooks/pearl-coordinator-rollout.md` and state the downtime to the
operator before the run step:

```bash
PEARL_RUNTIME_TASK=retention-vacuum-conversion PEARL_COORDINATOR_DB=<db-path> \
  scripts/ops/pearl-runtime.sh status
PEARL_RUNTIME_TASK=retention-vacuum-conversion PEARL_COORDINATOR_DB=<db-path> \
  MACPROVIDER_OPS_OWNER=<label> scripts/ops/pearl-runtime.sh next --run
```

The downtime is about as long as the backup step measured in
`ops/runbooks/pearl-release-updater.md`, in proportion to the remaining
size. After the conversion, `status` reports the task done and the next
retention report shows `auto_vacuum_mode: incremental`.

## 5. Restore and rederive

Each archive is self-contained. It holds every column of every archived
evidence row. It also holds reference copies of the request's ledger credits,
operator credits, payout rows, provider identity snapshots, and config
snapshots. Run these against the archive in `archive_dir` or a copy of it:

```bash
coordinator-cli settlement-evidence-archive verify   --archive <file>.jsonl.gz
coordinator-cli settlement-evidence-archive rederive --archive <file>.jsonl.gz --credit-id <ledger_request_credits.id>
```

- `verify` re-checks the SHA-256, size, every line, and the row counts
  against the manifest.
- `rederive` reprices the credit:
  - from the archived closed, payable verdict's attempt-output usage (basis
    `receipt_bound_usage`), the same way the verified-receipt sync priced it;
  - or, for a legacy or observe credit, from its own ledger token fields
    (basis `ledger_tokens`).

  It exits non-zero unless the result equals the archived credit. Compare it
  with the hot `ledger_request_credits` row as well.

To find a credit's archive:

```sql
SELECT a.file_name, a.sha256
  FROM settlement_evidence_archived_credits c
  JOIN settlement_evidence_archives a ON a.id = c.archive_id
 WHERE c.request_credit_id = ?;
```

Re-inserting archived rows into the hot tables is not part of normal
operations and is not needed to rederive a credit. If an incident needs it,
restore into a scratch copy of the database, never into the live one.

## 6. Rollback

- To stop retention: set `billing.retention.enabled: false` and reload with
  SIGHUP. A run in progress stops deleting at the next batch boundary. Each
  batch either commits whole or not at all. The archive stays `exported`
  (or `offhost_verified`) and is resumed after re-enabling.
- Roll the coordinator forward only, once this release has started. On
  open it records billing compatibility contract 4 in `billing_compat_floor`
  (SPEC-022 R-15.9), and every deletion records it again. Older releases
  implement contract 3 or lower and refuse to open the database at startup
  (`billing: database requires a newer coordinator billing contract`). The
  guard exists because an older payable view has no tombstone branch: it
  would drop archived credits and void their payouts.
- The updater needs no extra step. It already rejects a downgrade `--apply`.
  A rollback of the deploying transaction restores the pre-apply database
  snapshot, which is still at contract 3, together with the previous release.
  If that snapshot is skipped or refused, the older coordinator fails closed
  at startup and the rollback raises its critical alert. Roll forward to a
  retention-capable release. Check the floor with:

  ```sql
  SELECT contract, recorded_at_utc FROM billing_compat_floor;
  ```

  Never lower it by hand.
- Since SPEC-022 v0.4.5 the first deletion that tombstones an unsettled
  credit records contract 5 in the same transaction. A contract-4 release
  would neither settle such a credit through its tombstone nor skip it in the
  nightly reconcile, so it refuses the database from that commit on. Until
  the first such deletion (the first nightly run after the deploy), the
  previous release can still open the database.
- Tombstones (`settlement_evidence_archived_credits`) are permanent: a trigger
  refuses updates and deletes. A tombstoned credit's money columns are
  immutable (`trg_lrc_archived_money_immutable`), settled or not.

## 7. Hot footprint (SPEC-022 R-15.10)

These run without the nightly job and need no operator step:

- Drained, unpoisoned audit-outbox rows leave the money database
  `storage.settlement_receipt_audit_outbox_drained_retention_hours` (default
  24) after delivery. The audit database keeps its copy for
  `storage.audit_log_retention_days`. A lab journey whose validator reads
  outbox rows (the privacy-class journey) must extract the money database
  within that window.
- Route-snapshot journal rows leave
  `storage.route_snapshot_journal_mirrored_grace_minutes` (default 60) after
  mirroring, once the primary row is verified to hold the same digest and
  JSON. Rows that stay behind (unmirrored, or primary missing or different)
  are counted as `kept_rows` in the `route snapshot journal pruned mirrored
  rows` log line. The first runs after the deploy drain the existing backlog
  in bounded batches.
- New route snapshots store `route_snapshot_canonical_json` empty when it
  recomputes from `route_snapshot_json`; new verdicts store `{}` in
  `verifier_diagnostics_json`.
- The first startup on this release drops ten unused indexes
  (`DROP INDEX IF EXISTS`) in the money database, the journal, and the audit
  database. It runs once, inside the updater's startup window; it frees
  pages to the freelist and does not rebuild anything. A later rollback to a
  release from before this change recreates the indexes at its startup, which
  takes longer on a large database.

- The audit database (`coordinator-audit.db`) keeps
  `storage.audit_log_hot_days` (default 7) whole UTC days hot. A daily run at
  02:30 UTC writes older rows to `storage.audit_log_archive_dir` (default
  `audit-archive` next to the audit database) as
  `audit-log-<UTC stamp>-<nonce>.jsonl.gz` with a manifest, re-reads and
  verifies it, then deletes the rows in short batches (SPEC-002 R-7.10.2a).
  It refuses below the same free-space floor as this job. The log line is
  `audit log rotation finished` with `status`, `archived_rows`,
  `deleted_rows`, `kept_rows`, and `removed_archives`; `kept_rows` are rows
  that changed after export and are archived again by a later run. Archives
  whose last day is older than `storage.audit_log_retention_days` are
  removed. Rows leave the audit database only through a verified archive;
  the generic 90-day pruner no longer runs on it. The first runs after the
  deploy move the existing backlog in
  bounded archives (200,000 rows each, 15 minutes per run). Verify an archive
  from the file alone with
  `coordinator-cli audit-log-archive verify --archive <file>`. The audit file
  stops growing at once; it shrinks only after the one-time conversion in
  section 4, which includes it.
- Audit payloads written by this release name each field once
  (SPEC-022 R-11.1.2): the ingested event carries the attempt and receipt
  identity only, and verifier checks are reduced to `unmet_checks`.

## 8. Ledger rollup and the request_log window (SPEC-022 R-15.11, SPEC-005 §2.1b, §7.8)

These run without an operator step once the release is deployed.

- **Ledger rollup.** After each nightly retention run, the rollup walks
  payouts from a persisted cursor. A request rolls up when its evidence is
  archived and every credit settled into a `ready` or `consumed` payout whose
  window is `billing.ledger_rollup.min_settlement_cycles` (default 5)
  completed windows old and older than the `request_log` window. Its credits,
  operator credits, provider identity snapshots, and tombstones go to a
  verified `ledger-rollup-*.jsonl.gz` archive in the retention archive
  directory. They are then replaced in short transactions by per-payout,
  per-hour, per-model rows in `ledger_settled_rollups`. Payout rows,
  settlement windows, quarantine resolutions, and frozen finality stay hot.
  A request skipped for a reason that can clear (evidence not archived yet,
  `request_log` rows still present, rows changed after export) is kept in
  `ledger_rollup_holds` and re-checked by every run, so the cursor never
  strands it. With the stats Postgres configured, a credit rolls up only
  after the stats billing mirror copied it (`billing_mirror_behind` holds),
  and a mirror state the coordinator cannot read stops the run with an error
  in the log line; check it after the first nightly run. The log line is
  `nightly ledger rollup finished`, with
  `rolled_requests`, `rolled_credits`, `kept_requests` (the run's skips), and
  `rollup_cursor`. The kill switch is
  `billing.ledger_rollup.enabled: false` plus SIGHUP. Verify a rollup archive
  from the file alone with
  `coordinator-cli ledger-rollup-archive verify --archive <file>`.
- **Rollback.** The first rollup transaction records billing contract 6. A
  release from before it refuses the database from then on: it would not add
  the rollup rows to payable totals and would void a ready payout whose
  credits rolled up.
- **`request_log` window.** `storage.request_log_retention_days` defaults to
  14 (it must exceed `settlement.nightly_reconcile_window_days`). Check the
  live `coordinator.yaml`: a value pinned to 90 there keeps the old window
  until it is changed. Rows with an account leave only through the wholesale
  fold into `wholesale_usage_daily`, a whole request at a time, so D1a
  statements keep their totals. Pruning runs off the startup path in hourly
  passes of at most five minutes. The first passes after lowering the window
  drain the backlog over several hours, which is why a large backlog does
  not delay startup. The admin reconcile refuses a range that starts before
  the window, because its buyer side is gone.

## Done criteria

Issue #1793 counts as done when both of these hold:

- the live hot-database size stays flat across two weekly settlements while
  retention runs nightly;
- a sampled settled credit rederives from its archive.

Record the before and after `coordinator.db` sizes and the report JSON in the
issue.
