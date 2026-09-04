package sqliteutil

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"strconv"
	"time"
)

// WALCheckpointMode is a closed set of SQLite wal_checkpoint modes used by
// the money checkpointer. SQL is selected by switch, never by interpolating
// caller strings. RESTART is intentionally omitted: it waits on readers and
// is forbidden on the live soak path.
type WALCheckpointMode string

const (
	WALCheckpointPassive  WALCheckpointMode = "PASSIVE"
	WALCheckpointTruncate WALCheckpointMode = "TRUNCATE"
)

// WALCheckpointResult is the busy/log/checkpointed triple from
// PRAGMA wal_checkpoint.
type WALCheckpointResult struct {
	Busy              int64
	LogPages          int64
	CheckpointedPages int64
}

// WALObserver receives closed-set WAL checkpoint page observations.
type WALObserver interface {
	ObserveSQLiteWALCheckpoint(component, pageClass, outcome string, pages int64)
	ObserveSQLiteWALCheckpointDuration(component, outcome string, duration time.Duration)
}

func walCheckpointSQL(mode WALCheckpointMode) (string, error) {
	switch mode {
	case WALCheckpointPassive:
		return `PRAGMA wal_checkpoint(PASSIVE)`, nil
	case WALCheckpointTruncate:
		return `PRAGMA wal_checkpoint(TRUNCATE)`, nil
	default:
		return "", fmt.Errorf("sqliteutil: unsupported wal checkpoint mode %q", mode)
	}
}

// RunWALCheckpointMode runs a bounded checkpoint in a closed-set mode and
// observes the busy/log/checkpointed page counts. Callers should provide an
// off-hot-path *sql.DB so disabling wal_autocheckpoint does not move
// checkpoint work onto request or billing pools.
func RunWALCheckpointMode(ctx context.Context, db *sql.DB, component string, observer WALObserver, mode WALCheckpointMode) (WALCheckpointResult, error) {
	query, err := walCheckpointSQL(mode)
	if err != nil {
		return WALCheckpointResult{}, err
	}
	var result WALCheckpointResult
	started := time.Now()
	err = db.QueryRowContext(ctx, query).Scan(&result.Busy, &result.LogPages, &result.CheckpointedPages)
	outcome := sqliteOutcome(err)
	observeWALCheckpointDuration(observer, component, outcome, time.Since(started))
	observeWALCheckpoint(observer, component, "busy", outcome, result.Busy)
	observeWALCheckpoint(observer, component, "log", outcome, result.LogPages)
	observeWALCheckpoint(observer, component, "checkpointed", outcome, result.CheckpointedPages)
	return result, err
}

// RunWALCheckpoint runs a bounded TRUNCATE checkpoint on the supplied SQLite
// handle and observes the busy/log/checkpointed page counts.
func RunWALCheckpoint(ctx context.Context, db *sql.DB, component string, observer WALObserver) error {
	_, err := RunWALCheckpointMode(ctx, db, component, observer, WALCheckpointTruncate)
	return err
}

// WALFileSize returns the size of dbPath's sidecar WAL file, or 0 if the
// file is missing or unreadable.
func WALFileSize(dbPath string) int64 {
	info, err := os.Stat(dbPath + "-wal")
	if err != nil {
		return 0
	}
	return info.Size()
}

const maxBusyTimeout = 5 * time.Minute

// SetBusyTimeout sets PRAGMA busy_timeout on db to timeout, clamped to
// [1ms, 5m]. The duration is converted to a decimal integer; it is not
// interpolated as a SQL keyword or identifier.
func SetBusyTimeout(ctx context.Context, db *sql.DB, timeout time.Duration) error {
	if db == nil {
		return fmt.Errorf("sqliteutil: nil db")
	}
	if timeout > maxBusyTimeout {
		timeout = maxBusyTimeout
	}
	ms := timeout.Milliseconds()
	if ms < 1 {
		ms = 1
	}
	_, err := db.ExecContext(ctx, "PRAGMA busy_timeout = "+strconv.FormatInt(ms, 10))
	return err
}

func observeWALCheckpoint(observer WALObserver, component, pageClass, outcome string, pages int64) {
	if observer == nil || component == "" {
		return
	}
	observer.ObserveSQLiteWALCheckpoint(component, pageClass, outcome, pages)
}

func observeWALCheckpointDuration(observer WALObserver, component, outcome string, duration time.Duration) {
	if observer == nil || component == "" {
		return
	}
	observer.ObserveSQLiteWALCheckpointDuration(component, outcome, duration)
}
