package audit

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/verifiedarchive"
)

// SPEC-002 R-7.10.2 (#1793): the audit database keeps only its active
// period hot. Rows of whole UTC days older than HotDays are written to a
// closed period archive (internal/verifiedarchive: gzip JSON lines, SHA-256,
// byte size, row counts), the archive is re-read and verified, and only then
// are the rows deleted, each only while the live row still equals its
// archived copy. The archives, not the hot file, hold the audit history for
// storage.audit_log_retention_days (90-day floor); an archive whose newest
// day is past that window is removed.

const (
	auditArchiveFormat     = "macprovider-audit-log-archive-v1"
	auditArchiveNamePrefix = "audit-log"
	auditArchiveTable      = "audit_log"
	auditArchiveRole       = "audit"
	// auditArchiveGroupRows is the number of rows per archive group: a
	// verified pass keeps one digest per group.
	auditArchiveGroupRows = 1000
	// AuditArchiveDirName is the default archive directory, created next to
	// the audit database file.
	AuditArchiveDirName = "audit-archive"

	auditArchiveStatusExported = "exported"
	auditArchiveStatusDeleted  = "deleted"
	auditArchiveStatusRemoved  = "removed"
	auditArchiveStatusFailed   = "failed"

	// Rotation report statuses.
	RotationStatusNothingDue = "nothing_due"
	RotationStatusRotated    = "rotated"
	RotationStatusDiskLow    = "refused_archive_disk_low"
	RotationStatusInvalid    = "refused_archive_invalid"
	RotationStatusBudget     = "run_budget_spent"
)

var (
	// ErrRotationBusy reports a rotation already running on this store.
	ErrRotationBusy = errors.New("audit log rotation is already running")
	errRotationDisk = errors.New("archive filesystem below its free-space floor")
)

// RotationOptions are the effective rotation settings.
type RotationOptions struct {
	// ArchiveDir is the absolute archive directory.
	ArchiveDir string
	// HotDays is how many whole UTC days stay in the hot file, today
	// included in the count's base: rows of days before today-HotDays move.
	HotDays int
	// RetentionDays is storage.audit_log_retention_days: an archive whose
	// newest day is older than this is removed.
	RetentionDays int
	// MaxRowsPerArchive bounds one archive file.
	MaxRowsPerArchive int
	BatchSize         int
	BatchPause        time.Duration
	RunBudget         time.Duration
	MinFreeBytes      int64
	MinFreePercent    int
	// IncrementalVacuumPages is the page count per incremental_vacuum step
	// on a database in auto_vacuum=INCREMENTAL; zero skips the step.
	IncrementalVacuumPages    int
	IncrementalVacuumMaxSteps int
}

func (o RotationOptions) normalized() (RotationOptions, error) {
	if strings.TrimSpace(o.ArchiveDir) == "" || !filepath.IsAbs(o.ArchiveDir) {
		return o, fmt.Errorf("audit archive directory must be an absolute path")
	}
	if o.HotDays < 1 {
		return o, fmt.Errorf("audit hot days must be >= 1")
	}
	if o.RetentionDays < o.HotDays {
		return o, fmt.Errorf("audit retention days must be >= hot days")
	}
	if o.MaxRowsPerArchive < 1 {
		o.MaxRowsPerArchive = 200000
	}
	if o.BatchSize < 1 {
		o.BatchSize = pruneBatchSize
	}
	if o.RunBudget <= 0 {
		o.RunBudget = 15 * time.Minute
	}
	return o, nil
}

// RotationReport is what one rotation run did.
type RotationReport struct {
	Status          string `json:"status"`
	CutoffDayUTC    string `json:"cutoff_day_utc"`
	Archives        int    `json:"archives"`
	ArchivedRows    int64  `json:"archived_rows"`
	DeletedRows     int64  `json:"deleted_rows"`
	KeptRows        int64  `json:"kept_rows"`
	RemovedArchives int    `json:"removed_archives"`
	LastArchiveFile string `json:"last_archive_file,omitempty"`
	LastArchiveSHA  string `json:"last_archive_sha256,omitempty"`
	AutoVacuumMode  string `json:"auto_vacuum_mode,omitempty"`
	Error           string `json:"error,omitempty"`
}

type rotationRuntime struct {
	mu sync.Mutex
}

func (s *Store) ensureAuditArchiveTable(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS audit_log_archives (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_name TEXT NOT NULL UNIQUE,
    sha256 TEXT NOT NULL CHECK(length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
    size_bytes INTEGER NOT NULL CHECK(size_bytes > 0),
    group_count INTEGER NOT NULL CHECK(group_count > 0),
    row_count INTEGER NOT NULL CHECK(row_count > 0),
    first_day_utc TEXT NOT NULL,
    last_day_utc TEXT NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('exported','deleted','removed','failed')),
    deleted_rows INTEGER NOT NULL DEFAULT 0 CHECK(deleted_rows >= 0),
    last_error TEXT NOT NULL DEFAULT '',
    created_at_utc TEXT NOT NULL,
    updated_at_utc TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_log_archives_status ON audit_log_archives(status, id);`)
	return err
}

// auditArchiveKnownTable is the archive's only table.
func auditArchiveKnownTable(table string) bool { return table == auditArchiveTable }

type auditArchiveRecord struct {
	id       int64
	manifest verifiedarchive.Manifest
}

// RotateClosedPeriods archives, verifies, and deletes the audit rows of whole
// UTC days before today-HotDays, then removes archives past RetentionDays.
// A run resumes an archive an earlier run exported but did not finish
// deleting, and stops at its budget, a refusal, or when nothing is due.
func (s *Store) RotateClosedPeriods(ctx context.Context, opts RotationOptions, now time.Time) (report RotationReport, err error) {
	if s == nil || s.db == nil {
		return RotationReport{}, errStoreClosed
	}
	if !s.settlementReceiptOutboxEnabled {
		return RotationReport{}, fmt.Errorf("audit log rotation runs on the settlement receipt audit database only")
	}
	if !s.rotation.mu.TryLock() {
		return RotationReport{}, ErrRotationBusy
	}
	defer s.rotation.mu.Unlock()
	opts, err = opts.normalized()
	if err != nil {
		return RotationReport{}, err
	}
	now = now.UTC()
	deadline := time.Now().Add(opts.RunBudget)
	// The export walk resumes where the previous archive of this run ended,
	// so a row kept hot by its deletion step is not archived again this run.
	var walk auditExportKey
	cutoffDay := now.AddDate(0, 0, -opts.HotDays).Format("2006-01-02")
	report = RotationReport{Status: RotationStatusNothingDue, CutoffDayUTC: cutoffDay}
	defer func() {
		if err != nil {
			report.Error = err.Error()
		}
	}()
	for {
		if err := ctx.Err(); err != nil {
			return report, err
		}
		if !time.Now().Before(deadline) {
			report.Status = RotationStatusBudget
			break
		}
		rec, err := s.pendingAuditArchive(ctx)
		if err != nil {
			return report, err
		}
		if rec == nil {
			free, total, err := verifiedarchive.FilesystemSpace(opts.ArchiveDir)
			if err != nil {
				return report, err
			}
			if reason := verifiedarchive.BelowFloor(free, total, opts.MinFreeBytes, opts.MinFreePercent); reason != "" {
				report.Status = RotationStatusDiskLow
				report.Error = reason
				break
			}
			rec, err = s.exportAuditArchive(ctx, opts, cutoffDay, now, &walk)
			if errors.Is(err, errRotationDisk) {
				report.Status = RotationStatusDiskLow
				report.Error = err.Error()
				break
			}
			if err != nil {
				return report, err
			}
			if rec == nil {
				break
			}
			report.ArchivedRows += sumRowCounts(rec.manifest.RowCounts)
		}
		path := filepath.Join(opts.ArchiveDir, rec.manifest.ArchiveFile)
		verified, verr := verifiedarchive.Verify(path, rec.manifest, auditArchiveKnownTable)
		if verr != nil {
			report.Status = RotationStatusInvalid
			_ = s.setAuditArchiveStatus(context.WithoutCancel(ctx), rec.id, auditArchiveStatusFailed, verr.Error(), 0)
			return report, verr
		}
		report.LastArchiveFile, report.LastArchiveSHA = rec.manifest.ArchiveFile, rec.manifest.SHA256
		deleted, kept, derr := s.deleteArchivedAuditRows(ctx, opts, rec.id, verified, deadline)
		report.DeletedRows += deleted
		report.KeptRows += kept
		if errors.Is(derr, errRotationBudget) {
			report.Status = RotationStatusBudget
			break
		}
		if derr != nil {
			if errors.Is(derr, verifiedarchive.ErrInvalid) {
				report.Status = RotationStatusInvalid
				_ = s.setAuditArchiveStatus(context.WithoutCancel(ctx), rec.id, auditArchiveStatusFailed, derr.Error(), 0)
			}
			return report, derr
		}
		if err := s.setAuditArchiveStatus(ctx, rec.id, auditArchiveStatusDeleted, "", 0); err != nil {
			return report, err
		}
		report.Archives++
		report.Status = RotationStatusRotated
	}
	removed, err := s.removeExpiredAuditArchives(ctx, opts, now)
	report.RemovedArchives = removed
	if err != nil {
		return report, err
	}
	report.AutoVacuumMode = s.incrementalVacuum(ctx, opts)
	return report, nil
}

var errRotationBudget = errors.New("audit log rotation run budget spent")

func sumRowCounts(m map[string]int64) int64 {
	var n int64
	for _, v := range m {
		n += v
	}
	return n
}

// pendingAuditArchive is the oldest archive exported but not yet deleted.
func (s *Store) pendingAuditArchive(ctx context.Context) (*auditArchiveRecord, error) {
	var rec auditArchiveRecord
	var rows int64
	err := s.db.QueryRowContext(ctx, `
SELECT id, file_name, sha256, size_bytes, group_count, row_count
  FROM audit_log_archives
 WHERE status = 'exported'
 ORDER BY id
 LIMIT 1`).Scan(&rec.id, &rec.manifest.ArchiveFile, &rec.manifest.SHA256, &rec.manifest.SizeBytes,
		&rec.manifest.RequestCount, &rows)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	rec.manifest.Format = auditArchiveFormat
	rec.manifest.RowCounts = map[string]int64{auditArchiveTable: rows}
	return &rec, nil
}

// exportAuditArchive writes the next archive: up to MaxRowsPerArchive rows
// of days before cutoffDay, oldest first, in groups of auditArchiveGroupRows.
// It returns nil when nothing is due. ts_utc starts with its fixed-width
// YYYY-MM-DD day, so ts_utc < cutoffDay selects exactly the days before it.
// auditExportKey is the (ts_utc, id) position of an export walk.
type auditExportKey struct {
	ts string
	id int64
}

func (s *Store) exportAuditArchive(ctx context.Context, opts RotationOptions, cutoffDay string, now time.Time, walk *auditExportKey) (*auditArchiveRecord, error) {
	var w *verifiedarchive.Writer
	abort := func() { w.Abort() }
	lastTS, lastID := walk.ts, walk.id
	firstDay, lastDay := "", ""
	var total int64
	spaceGuard := func() error {
		free, size, err := verifiedarchive.FilesystemSpace(opts.ArchiveDir)
		if err != nil {
			return err
		}
		if reason := verifiedarchive.BelowFloor(free, size, opts.MinFreeBytes, opts.MinFreePercent); reason != "" {
			return fmt.Errorf("%w: %s", errRotationDisk, reason)
		}
		return nil
	}
	for total < int64(opts.MaxRowsPerArchive) {
		limit := auditArchiveGroupRows
		if remaining := int64(opts.MaxRowsPerArchive) - total; remaining < int64(limit) {
			limit = int(remaining)
		}
		rows, err := queryAuditRows(ctx, s.db, `
SELECT * FROM audit_log
 WHERE ts_utc >= ? AND ts_utc < ?
   AND NOT (ts_utc = ? AND id <= ?)
 ORDER BY ts_utc, id
 LIMIT ?`, lastTS, cutoffDay, lastTS, lastID, limit)
		if err != nil {
			abort()
			return nil, err
		}
		if len(rows) == 0 {
			break
		}
		if w == nil {
			w, err = verifiedarchive.NewWriter(opts.ArchiveDir, auditArchiveNamePrefix, auditArchiveFormat, now, cutoffDay)
			if err != nil {
				return nil, err
			}
			w.SetSpaceGuard(4<<20, spaceGuard)
		}
		firstID, _ := rows[0]["id"].(int64)
		lastRowID, _ := rows[len(rows)-1]["id"].(int64)
		lastTS, _ = rows[len(rows)-1]["ts_utc"].(string)
		lastID = lastRowID
		for _, row := range rows {
			ts, _ := row["ts_utc"].(string)
			if len(ts) >= 10 {
				if firstDay == "" || ts[:10] < firstDay {
					firstDay = ts[:10]
				}
				if ts[:10] > lastDay {
					lastDay = ts[:10]
				}
			}
		}
		group := fmt.Sprintf("audit_log:%d:%d:%d", w.Groups(), firstID, lastRowID)
		if err := w.WriteGroup(group, nil, []verifiedarchive.TableRows{{Table: auditArchiveTable, Role: auditArchiveRole, Rows: rows}}); err != nil {
			abort()
			return nil, err
		}
		total += int64(len(rows))
		if len(rows) < limit {
			break
		}
	}
	if w == nil {
		return nil, nil
	}
	walk.ts, walk.id = lastTS, lastID
	manifest, _, err := w.Finish()
	if err != nil {
		return nil, err
	}
	stamp := verifiedarchive.TimeText(time.Now())
	res, err := s.db.ExecContext(ctx, `
INSERT INTO audit_log_archives (
    file_name, sha256, size_bytes, group_count, row_count, first_day_utc, last_day_utc,
    status, created_at_utc, updated_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, 'exported', ?, ?)`,
		manifest.ArchiveFile, manifest.SHA256, manifest.SizeBytes, manifest.RequestCount, total, firstDay, lastDay,
		manifest.CreatedAtUTC, stamp)
	if err != nil {
		// The durable file is harmless; its rows stay hot and the next run
		// archives them again.
		return nil, fmt.Errorf("record audit archive %s: %w", manifest.ArchiveFile, err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	return &auditArchiveRecord{id: id, manifest: manifest}, nil
}

type auditRowQueryer interface {
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
}

func queryAuditRows(ctx context.Context, q auditRowQueryer, query string, args ...any) ([]verifiedarchive.Row, error) {
	rows, err := q.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		return nil, err
	}
	var out []verifiedarchive.Row
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return nil, err
		}
		row := make(verifiedarchive.Row, len(cols))
		for i, c := range cols {
			row[c] = verifiedarchive.NormalizeValue(vals[i])
		}
		out = append(out, row)
	}
	return out, rows.Err()
}

// deleteArchivedAuditRows re-reads the verified archive as a stream and
// deletes its rows in short transactions of BatchSize rows, each row only
// while the live row equals its archived copy; a row already gone is the
// expected state on a resumed archive. Every re-read group must match its
// digest from the verified pass.
func (s *Store) deleteArchivedAuditRows(ctx context.Context, opts RotationOptions, archiveID int64, verified verifiedarchive.Verified, deadline time.Time) (int64, int64, error) {
	var deleted, kept int64
	var batch []verifiedarchive.Row
	batches := 0
	run := func() error {
		if len(batch) == 0 {
			return nil
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if !time.Now().Before(deadline) {
			return errRotationBudget
		}
		if batches > 0 && opts.BatchPause > 0 {
			timer := time.NewTimer(opts.BatchPause)
			select {
			case <-ctx.Done():
				timer.Stop()
				return ctx.Err()
			case <-timer.C:
			}
		}
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		defer func() { _ = tx.Rollback() }()
		var n int64
		for _, archived := range batch {
			id, ok := archived["id"].(int64)
			if !ok {
				kept++
				continue
			}
			live, err := queryAuditRows(ctx, tx, `SELECT * FROM audit_log WHERE id = ?`, id)
			if err != nil {
				return err
			}
			if len(live) == 0 {
				continue
			}
			if !verifiedarchive.RowsEqual(live[0], archived) {
				kept++
				continue
			}
			res, err := tx.ExecContext(ctx, `DELETE FROM audit_log WHERE id = ?`, id)
			if err != nil {
				return err
			}
			affected, _ := res.RowsAffected()
			n += affected
		}
		if _, err := tx.ExecContext(ctx, `
UPDATE audit_log_archives SET deleted_rows = deleted_rows + ?, updated_at_utc = ? WHERE id = ?`,
			n, verifiedarchive.TimeText(time.Now()), archiveID); err != nil {
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
		deleted += n
		batches++
		batch = nil
		return nil
	}
	err := verifiedarchive.Stream(verified.Path, verified.Manifest, auditArchiveKnownTable, func(g verifiedarchive.Group) error {
		if want, ok := verified.Digests[g.ID]; !ok || want != g.Digest {
			return fmt.Errorf("%w: group %q changed since verification", verifiedarchive.ErrInvalid, g.ID)
		}
		for _, row := range g.Rows[auditArchiveTable] {
			batch = append(batch, row)
			if len(batch) >= opts.BatchSize {
				if err := run(); err != nil {
					return err
				}
			}
		}
		return nil
	})
	if err != nil {
		return deleted, kept, err
	}
	return deleted, kept, run()
}

func (s *Store) setAuditArchiveStatus(ctx context.Context, id int64, status, lastError string, deleted int64) error {
	if len(lastError) > 1000 {
		lastError = lastError[:1000]
	}
	_, err := s.db.ExecContext(ctx, `
UPDATE audit_log_archives
   SET status = ?, last_error = ?, deleted_rows = deleted_rows + ?, updated_at_utc = ?
 WHERE id = ?`, status, lastError, deleted, verifiedarchive.TimeText(time.Now()), id)
	return err
}

// removeExpiredAuditArchives removes the files of deleted archives whose
// newest day is older than the retention window (AC-K.14: audit rows older
// than retention are pruned).
func (s *Store) removeExpiredAuditArchives(ctx context.Context, opts RotationOptions, now time.Time) (int, error) {
	expiredBefore := now.AddDate(0, 0, -opts.RetentionDays).Format("2006-01-02")
	rows, err := s.db.QueryContext(ctx, `
SELECT id, file_name FROM audit_log_archives
 WHERE status = 'deleted' AND last_day_utc < ?
 ORDER BY id`, expiredBefore)
	if err != nil {
		return 0, err
	}
	type expired struct {
		id   int64
		name string
	}
	var list []expired
	for rows.Next() {
		var e expired
		if err := rows.Scan(&e.id, &e.name); err != nil {
			rows.Close()
			return 0, err
		}
		list = append(list, e)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return 0, err
	}
	if err := rows.Close(); err != nil {
		return 0, err
	}
	removed := 0
	for _, e := range list {
		if filepath.Base(e.name) != e.name {
			continue
		}
		path := filepath.Join(opts.ArchiveDir, e.name)
		for _, p := range []string{path + verifiedarchive.ManifestSuffix, path} {
			if err := os.Remove(p); err != nil && !errors.Is(err, os.ErrNotExist) {
				return removed, err
			}
		}
		if err := s.setAuditArchiveStatus(ctx, e.id, auditArchiveStatusRemoved, "", 0); err != nil {
			return removed, err
		}
		removed++
	}
	if removed > 0 {
		if err := verifiedarchive.FsyncDir(opts.ArchiveDir); err != nil {
			return removed, err
		}
	}
	return removed, nil
}

// incrementalVacuum reclaims free pages in bounded steps when the audit
// database is in auto_vacuum=INCREMENTAL, and reports the mode. It never
// runs a full VACUUM.
func (s *Store) incrementalVacuum(ctx context.Context, opts RotationOptions) string {
	var mode int
	if err := s.db.QueryRowContext(ctx, `PRAGMA auto_vacuum`).Scan(&mode); err != nil {
		return "unknown"
	}
	switch mode {
	case 0:
		return "none"
	case 1:
		return "full"
	case 2:
	default:
		return fmt.Sprintf("unknown(%d)", mode)
	}
	for step := 0; step < opts.IncrementalVacuumMaxSteps && opts.IncrementalVacuumPages > 0; step++ {
		var free int64
		if err := s.db.QueryRowContext(ctx, `PRAGMA freelist_count`).Scan(&free); err != nil || free == 0 || ctx.Err() != nil {
			break
		}
		if _, err := s.db.ExecContext(ctx, fmt.Sprintf(`PRAGMA incremental_vacuum(%d)`, opts.IncrementalVacuumPages)); err != nil {
			break
		}
	}
	return "incremental"
}

// VerifyArchiveFile re-verifies a closed period archive against its sidecar
// manifest (operator restore procedure). It reads only the file.
func VerifyArchiveFile(archivePath string) (verifiedarchive.Manifest, error) {
	manifest, err := verifiedarchive.ReadManifest(archivePath)
	if err != nil {
		return verifiedarchive.Manifest{}, err
	}
	if manifest.Format != auditArchiveFormat {
		return verifiedarchive.Manifest{}, fmt.Errorf("%w: manifest format %q", verifiedarchive.ErrInvalid, manifest.Format)
	}
	if _, err := verifiedarchive.Verify(archivePath, manifest, auditArchiveKnownTable); err != nil {
		return verifiedarchive.Manifest{}, err
	}
	return manifest, nil
}
