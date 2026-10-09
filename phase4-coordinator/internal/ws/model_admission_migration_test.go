package ws

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"
)

// #1880: the additive model_admission_events column migration is idempotent
// (a column another process added first counts as done) and waits out a
// schema lock instead of failing startup.
func TestModelAdmissionColumnMigrationIdempotentAndRetriesBusy(t *testing.T) {
	path := filepath.Join(t.TempDir(), "coordinator.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer db.Close()
	if _, err := NewSQLiteModelAdmissionStore(db); err != nil {
		t.Fatalf("first migration: %v", err)
	}
	if _, err := NewSQLiteModelAdmissionStore(db); err != nil {
		t.Fatalf("second migration: %v", err)
	}
	const stmt = `ALTER TABLE model_admission_events ADD COLUMN requested_pool_model_id TEXT NOT NULL DEFAULT ''`
	if err := addSQLiteModelAdmissionColumn(db, "requested_pool_model_id", stmt, time.Second, func(time.Duration) {}); err != nil {
		t.Fatalf("duplicate column must count as done: %v", err)
	}

	// A second connection holds an exclusive lock; the migration retries
	// until it is released.
	holder, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open holder: %v", err)
	}
	defer holder.Close()
	conn, err := holder.Conn(context.Background())
	if err != nil {
		t.Fatalf("holder conn: %v", err)
	}
	defer conn.Close()
	if _, err := conn.ExecContext(context.Background(), `BEGIN EXCLUSIVE`); err != nil {
		t.Fatalf("begin exclusive: %v", err)
	}
	sleeps := 0
	release := func(time.Duration) {
		sleeps++
		if sleeps == 2 {
			if _, err := conn.ExecContext(context.Background(), `COMMIT`); err != nil {
				t.Errorf("commit: %v", err)
			}
		}
	}
	const busyStmt = `ALTER TABLE model_admission_events ADD COLUMN migration_retry_probe TEXT NOT NULL DEFAULT ''`
	if err := addSQLiteModelAdmissionColumn(db, "migration_retry_probe", busyStmt, time.Minute, release); err != nil {
		t.Fatalf("busy migration: %v", err)
	}
	if sleeps < 2 {
		t.Fatalf("migration retried %d times, want it to wait for the lock", sleeps)
	}

	// A lock that is never released fails after the bounded budget.
	if _, err := conn.ExecContext(context.Background(), `BEGIN EXCLUSIVE`); err != nil {
		t.Fatalf("begin exclusive again: %v", err)
	}
	defer conn.ExecContext(context.Background(), `ROLLBACK`)
	const stuckStmt = `ALTER TABLE model_admission_events ADD COLUMN migration_stuck_probe TEXT NOT NULL DEFAULT ''`
	if err := addSQLiteModelAdmissionColumn(db, "migration_stuck_probe", stuckStmt, 50*time.Millisecond, func(d time.Duration) { time.Sleep(d) }); err == nil {
		t.Fatal("migration under a held lock succeeded past its budget")
	}
}
