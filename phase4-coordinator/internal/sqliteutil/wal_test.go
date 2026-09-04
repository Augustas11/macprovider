package sqliteutil

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func openManualCheckpointDB(t *testing.T) (dbPath string, db *sql.DB) {
	t.Helper()
	dbPath = filepath.Join(t.TempDir(), "checkpoint.db")
	db, err := sql.Open("sqlite", WithManualWALCheckpointPragmas(dbPath))
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	if _, err := db.Exec(`CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)`); err != nil {
		t.Fatalf("create table: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO t (v) VALUES ('a'), ('b'), ('c')`); err != nil {
		t.Fatalf("insert: %v", err)
	}
	return dbPath, db
}

func TestRunWALCheckpointModeTruncateShrinksWAL(t *testing.T) {
	dbPath, db := openManualCheckpointDB(t)
	if size := WALFileSize(dbPath); size == 0 {
		t.Fatal("WAL size before TRUNCATE = 0, want growth from inserts")
	}

	observer := &testObserver{}
	result, err := RunWALCheckpointMode(context.Background(), db, "wal_checkpoint", observer, WALCheckpointTruncate)
	if err != nil {
		t.Fatalf("TRUNCATE checkpoint: %v", err)
	}
	if result.Busy != 0 {
		t.Fatalf("TRUNCATE busy=%d want 0", result.Busy)
	}
	assertWALObservations(t, observer)
	if size := WALFileSize(dbPath); size != 0 {
		t.Fatalf("WAL size after TRUNCATE=%d want 0", size)
	}
}

func TestRunWALCheckpointModePassiveIsValid(t *testing.T) {
	dbPath, db := openManualCheckpointDB(t)
	observer := &testObserver{}
	result, err := RunWALCheckpointMode(context.Background(), db, "wal_checkpoint", observer, WALCheckpointPassive)
	if err != nil {
		t.Fatalf("PASSIVE checkpoint: %v", err)
	}
	if result.LogPages < 0 || result.CheckpointedPages < 0 {
		t.Fatalf("PASSIVE result = %+v, want non-negative pages", result)
	}
	assertWALObservations(t, observer)
	if _, err := os.Stat(dbPath); err != nil {
		t.Fatalf("db missing after PASSIVE: %v", err)
	}
}

func TestRunWALCheckpointModeRejectsInvalidMode(t *testing.T) {
	_, db := openManualCheckpointDB(t)
	for _, mode := range []WALCheckpointMode{
		"RESTART",
		"TRUNCATE); DROP TABLE t; --",
	} {
		observer := &testObserver{}
		result, err := RunWALCheckpointMode(context.Background(), db, "wal_checkpoint", observer, mode)
		if err == nil {
			t.Fatalf("mode %q returned nil error", mode)
		}
		if !strings.Contains(err.Error(), "unsupported wal checkpoint mode") {
			t.Fatalf("mode %q error = %v, want unsupported", mode, err)
		}
		if result != (WALCheckpointResult{}) {
			t.Fatalf("mode %q result = %+v, want zero value", mode, result)
		}
		if len(observer.events) != 0 {
			t.Fatalf("mode %q emitted observations: %+v", mode, observer.events)
		}
	}
	if _, err := db.Exec(`INSERT INTO t (v) VALUES ('still-there')`); err != nil {
		t.Fatalf("table t should still exist after rejected mode: %v", err)
	}
}

func TestWALFileSizeMissingIsZero(t *testing.T) {
	if got := WALFileSize(filepath.Join(t.TempDir(), "missing.db")); got != 0 {
		t.Fatalf("WALFileSize(missing)=%d want 0", got)
	}
}

func TestSetBusyTimeout(t *testing.T) {
	_, db := openManualCheckpointDB(t)
	if err := SetBusyTimeout(context.Background(), db, 15*time.Second); err != nil {
		t.Fatalf("SetBusyTimeout: %v", err)
	}
	var ms int64
	if err := db.QueryRow(`PRAGMA busy_timeout`).Scan(&ms); err != nil {
		t.Fatalf("PRAGMA busy_timeout: %v", err)
	}
	if ms != 15000 {
		t.Fatalf("busy_timeout=%d want 15000", ms)
	}
}

func TestSetBusyTimeoutBoundsTruncateWaitAgainstReader(t *testing.T) {
	dbPath, db := openManualCheckpointDB(t)
	reader, err := sql.Open("sqlite", WithPragmas(dbPath))
	if err != nil {
		t.Fatalf("open reader: %v", err)
	}
	t.Cleanup(func() { _ = reader.Close() })
	tx, err := reader.Begin()
	if err != nil {
		t.Fatalf("begin reader tx: %v", err)
	}
	t.Cleanup(func() { _ = tx.Rollback() })
	rows, err := tx.Query(`SELECT v FROM t`)
	if err != nil {
		t.Fatalf("reader select: %v", err)
	}
	t.Cleanup(func() { _ = rows.Close() })
	if !rows.Next() {
		t.Fatal("reader select returned no rows")
	}

	if err := SetBusyTimeout(context.Background(), db, 50*time.Millisecond); err != nil {
		t.Fatalf("SetBusyTimeout: %v", err)
	}
	started := time.Now()
	result, err := RunWALCheckpointMode(context.Background(), db, "wal_checkpoint", nil, WALCheckpointTruncate)
	elapsed := time.Since(started)
	if err != nil {
		t.Fatalf("TRUNCATE with held reader: %v", err)
	}
	if result.Busy == 0 {
		t.Fatal("TRUNCATE busy=0 with held reader, want busy!=0")
	}
	if elapsed > time.Second {
		t.Fatalf("TRUNCATE waited %s, want ~50ms busy_timeout not the 5s DSN default", elapsed)
	}
}

func assertWALObservations(t *testing.T, observer *testObserver) {
	t.Helper()
	assertObserved(t, observer.events, observedEvent{kind: "wal:busy", component: "wal_checkpoint", outcome: "success"})
	assertObserved(t, observer.events, observedEvent{kind: "wal:log", component: "wal_checkpoint", outcome: "success"})
	assertObserved(t, observer.events, observedEvent{kind: "wal:checkpointed", component: "wal_checkpoint", outcome: "success"})
	assertObserved(t, observer.events, observedEvent{kind: "wal_duration", component: "wal_checkpoint", outcome: "success"})
}
