package sqliteutil

import (
	"context"
	"database/sql"
	"time"
)

// WALObserver receives closed-set WAL checkpoint page observations.
type WALObserver interface {
	ObserveSQLiteWALCheckpoint(component, pageClass, outcome string, pages int64)
	ObserveSQLiteWALCheckpointDuration(component, outcome string, duration time.Duration)
}

// RunWALCheckpoint runs a bounded TRUNCATE checkpoint on the supplied SQLite
// handle and observes the busy/log/checkpointed page counts. Callers should
// provide an off-hot-path *sql.DB so disabling wal_autocheckpoint does not
// move checkpoint work onto request or billing pools.
func RunWALCheckpoint(ctx context.Context, db *sql.DB, component string, observer WALObserver) error {
	var busy, logPages, checkpointedPages int64
	started := time.Now()
	err := db.QueryRowContext(ctx, `PRAGMA wal_checkpoint(TRUNCATE)`).Scan(&busy, &logPages, &checkpointedPages)
	outcome := sqliteOutcome(err)
	observeWALCheckpointDuration(observer, component, outcome, time.Since(started))
	observeWALCheckpoint(observer, component, "busy", outcome, busy)
	observeWALCheckpoint(observer, component, "log", outcome, logPages)
	observeWALCheckpoint(observer, component, "checkpointed", outcome, checkpointedPages)
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
