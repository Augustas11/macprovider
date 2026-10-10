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

- Every ledger credit for the request is settled and not quarantined.
- Every credit is payable (`spec022_payable_request_credits`).
- No credit has a force-credit hold or any other quarantine resolution.
- Every credit settled into a `ready` or `consumed` (never `voided`) payout
  whose window is at least `min_settlement_cycles` (minimum 2) completed weekly
  windows old.
- Every credit is older than the nightly-reconcile and startup-scan horizons
  plus one day.
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
- Every pool-scoped route snapshot is held, with its finality, in the
  SPEC-047-R012 pool-proven rollup (`pool_proven_rollup_attempts`). Without
  that table, pool-scoped requests stay hot
  (`skipped_requests.pool_proven_rollup_pending`).

## Configuration

`coordinator.yaml`, `billing.retention` (all reloadable with SIGHUP):

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Arms the nightly 03:00 UTC run and `POST .../run`. `false` is the kill switch. Dry runs work either way. |
| `archive_dir` | empty | Absolute directory for `settlement-evidence-*.jsonl.gz` archives and their `.manifest.json` files. Empty means `retention-archive/` in the directory of the coordinator database file (for a database at `/var/lib/macprovider/coordinator.db`: `/var/lib/macprovider/retention-archive/`). Created with mode `0700` on first use. |
| `archive_min_free_bytes` | `21474836480` (20 GiB) | A run that would write a new archive is refused (`refused_archive_disk_low`) while the archive filesystem has less free space. `0` disables this bound. |
| `archive_min_free_percent` | `10` | Same, as a percentage of the archive filesystem. `0` disables this bound. |
| `min_settlement_cycles` | `2` | Completed settlement windows that must follow the credit's window. Floor: 2. |
| `batch_size` | `50` | Requests deleted per short `BEGIN IMMEDIATE` transaction. |
| `batch_pause_ms` | `200` | Pause between delete batches and between vacuum steps. |
| `max_requests_per_run` | `20000` | Requests archived per run. Memory does not grow with it: requests are streamed into the archive one at a time, and deletion re-reads the archive one batch at a time (at most `batch_size` requests; a batch is also flushed once it reaches 16 MiB of archived payload, so it can exceed 16 MiB by at most one request). |
| `max_scan_rows_per_run` | `500000` | Ledger credits scanned per run. The scan resumes from a persisted cursor and wraps. |
| `incremental_vacuum_pages` | `2048` | Pages released per `PRAGMA incremental_vacuum` step. |
| `incremental_vacuum_max_steps` | `256` | Steps per run, per database file. |
| `offhost_verify_command` | empty | Optional. Absolute argv. The job appends `<archive_path> <sha256_hex>`. Exit 0 means that checksum is confirmed at an off-host destination. When set, it is an extra check before deletion; when empty, nothing is skipped. |
| `offhost_verify_timeout_seconds` | `300` | Limit for one verify command. |

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
3. The first nightly run after the deploy archives and deletes at most
   `max_requests_per_run` requests, `batch_size` requests per short
   transaction with `batch_pause_ms` between batches. A large backlog drains
   over several nights; it never holds the writer for long. To hold
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
- `eligible_requests`;
- `tables.<table>.rows` and `tables.<table>.payload_bytes`: the summed column
  lengths, an estimate of what leaves;
- `skipped_requests` counts by reason.

`cutoff_window_end_utc` is empty until three or more weekly settlements have
completed. Use the dry run to preview what the next nightly run moves. A dry
run scans at most `max_scan_rows_per_run` credits from the
persisted cursor and writes nothing.

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
before and after, and `needs_one_time_conversion`. The job never runs a full
`VACUUM`. Free pages are reused by new writes either way, so the file stops
growing even without the conversion.

The one-time conversion rewrites the whole file and needs the coordinator
stopped. Do it only after retention has shrunk the live data. The rewrite
takes about as long as the backup step measured in
`ops/runbooks/pearl-release-updater.md`, in proportion to the remaining size.
State that downtime to the operator first and follow
`docs/runbooks/pearl-coordinator-rollout.md` for the stop and start:

```bash
sqlite3 <db-path> 'PRAGMA auto_vacuum = INCREMENTAL; VACUUM; PRAGMA quick_check;'
sqlite3 <db-path>.route-snapshots 'PRAGMA auto_vacuum = INCREMENTAL; VACUUM; PRAGMA quick_check;'
```

Use the SQLite 3.53.2 CLI named in `ops/pearl-updater` (see
`ops/runbooks/pearl-release-updater.md`). After the conversion, the next
report shows `auto_vacuum_mode: incremental`.

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
- Tombstones (`settlement_evidence_archived_credits`) are permanent: a trigger
  refuses updates and deletes.

## Done criteria

Issue #1793 counts as done when both of these hold:

- the live hot-database size stays flat across two weekly settlements while
  retention runs nightly;
- a sampled settled credit rederives from its archive.

Record the before and after `coordinator.db` sizes and the report JSON in the
issue.
