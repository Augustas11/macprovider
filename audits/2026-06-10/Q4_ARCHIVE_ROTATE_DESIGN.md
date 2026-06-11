# Q4 / M2-4 Part C — Archive-Rotate Design Sketch

**Status:** RULING — `archive-rotate to cold storage`. Implementation deferred. See `beta/DECISION_CRITERIA.md` Entry 63 (2026-06-11) for the decision.

**Audit refs:** `audits/2026-06-10/REPO_AUDIT.md` §3.6 PERF-1, §6 Open Q4.

## Decision

The gateway's append-only event tables stay append-only. The 9 `BEFORE DELETE` `RAISE(ABORT)` triggers in `phase5-gateway/internal/storage/sqlite/migrate.go:184-251` are **not amended**. Disk pressure on Pearl is handled out-of-band by a rotation job that ships the live `gateway.db` file to cold storage on a size or age threshold.

Trade-off accepted: ongoing cold-storage cost (~$0.01/GB/month at current usage) in exchange for preserving "nothing is ever deleted" as the system's tamper-evidence claim.

## Why archive-rotate beat trigger-amendment

- **Audit / compliance.** "Append-only forever" is easier to defend than "append-only for N days." A trigger amendment forces per-table retention decisions that drag in compliance / legal review.
- **Implementation surface.** Trigger amendment touches 9 tables × 2 triggers each + migration of existing rows + per-table reaper extension. Rotation is one shell-or-Go job that copies a file.
- **Reversibility.** A rotation job is easy to roll back (stop the cron). A trigger amendment is a schema migration that's permanent the moment any row is deleted under the new rule.
- **Cost.** S3 Standard-IA at ~$0.0125/GB/month + ~$0.0004/1k requests. Even a 10 GB/year `gateway.db` is $1.50/year cold-storage. Negligible vs. one operator-hour saved on a future "why was this row deleted?" question.

## Design sketch (out of scope for current PR)

### Trigger condition

Choose **size threshold** (e.g. `gateway.db > 8 GB`) or **age** (e.g. file mtime > 30 days), whichever fires first. Size is the load-bearing signal — age is a safety net for low-traffic periods. Pearl's `/var/lib` headroom is the upper bound.

### Cadence

Daily check via systemd timer (mirrors `macprovider-monitor`). Check is cheap (`stat` + maybe `du -sh`), only fires the rotation when the threshold is crossed.

### Rotation procedure

1. **Quiesce the gateway** writes briefly:
   - SIGSTOP the gateway process, OR
   - lock the DB at the SQLite layer (`PRAGMA locking_mode=EXCLUSIVE`), OR
   - run during the existing scripted-deploy quiet window.
2. **Snapshot** via SQLite's built-in `.backup` command or `VACUUM INTO 'gateway.db.YYYY-MM-DD.bak'`. This produces a clean, single-file backup with no WAL artifacts.
3. **Ship to cold storage** using the operator's existing S3 credentials (already used by M1-6's remote backup). Compress before upload (`zstd` typical 5×).
4. **Truncate the live file** — this is the part that needs care. Two options:
   - **a) Full reset:** delete `gateway.db` + WAL + SHM, restart gateway, run `Migrate()` to recreate schema. Loses *everything*; only viable if compliance accepts "old data lives only in cold storage."
   - **b) Aged-prune via raw SQL during quiesce:** temporarily disable the BEFORE DELETE triggers (`DROP TRIGGER ...; DELETE FROM table WHERE created_at < cutoff; CREATE TRIGGER ...`), VACUUM. Keeps recent rows live, ships everything else to cold storage. This is the recommended path — it preserves the "recent rows are queryable in-place" property the explorer + /v1/usage need.
5. **Verify** the cold-storage object is readable and the live `gateway.db` is smaller (otherwise alert and roll back).
6. **Unquiesce** gateway writes.

### Restore procedure

1. `aws s3 cp s3://macprovider-archives/gateway.db.YYYY-MM-DD.bak.zst /tmp/`
2. `zstd -d /tmp/gateway.db.YYYY-MM-DD.bak.zst`
3. Open via `sqlite3 gateway.db.YYYY-MM-DD.bak` for read-only forensic queries.
4. Document the restore as an incident in `beta/DECISION_CRITERIA.md` if used.

### Implementation surface (when the work is scheduled)

| Component | Owner | What |
|---|---|---|
| `phase5-gateway/cmd/gateway/main.go` | Go | Optional: register the rotation job inside the gateway process so it runs in-process. Or keep it external. |
| `phase5-gateway/dist/archive-rotate.sh` | bash | The actual rotation script. Mirrors `deploy-pearl-vps.sh` shape (M1-6). |
| `phase5-gateway/dist/macprovider-archive-rotate.service` + `.timer` | systemd | Daily timer. |
| `OPS.md` §3.x | docs | Rotation cadence + restore procedure. |
| `audits/2026-06-10/Q4_ARCHIVE_ROTATE_DESIGN.md` | this doc | Updated to reflect actual implementation when it lands. |

Estimated effort: ~1 week including operator testing on a Pearl replica.

## Until implementation lands

- The 9 `BEFORE DELETE` triggers stay enforced.
- `phase5-gateway/internal/storage/sqlite/migrate.go:184-251` is **untouched** by any PR until this design is implemented.
- Disk monitoring fallback: operator should add `du -sh /var/lib/macprovider/gateway.db` to the monitor's probe set and alert at 50% of `/var/lib` free space as an early warning. This is a cheap, low-risk change that can land independently in any monitor-tweak PR.

## What does NOT change

- `quota_reservations` terminal cleanup (M2-4 Part B, already shipped). That table has no BEFORE-DELETE trigger and gets row-level DELETE on 7-day terminal cleanup. The archive-rotate job operates at the file level on the 9 protected tables; the existing per-row reaper on `quota_reservations` runs independently and unchanged.
- M3-1 (sargable prunes). The archive-rotate target is the file, not individual rows — sargable prune work on `quota_reservations` and the request_log stays valid.
- The existing remote-backup of `gateway.db` from M1-6. That's a **safety** backup (so Pearl loss doesn't destroy data); archive-rotate is a **retention** backup (so Pearl's disk doesn't fill up). They serve different purposes and can coexist.
