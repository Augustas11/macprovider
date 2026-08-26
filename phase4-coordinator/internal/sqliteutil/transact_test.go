package sqliteutil

import (
	"context"
	"database/sql"
	"errors"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

type observedEvent struct {
	kind      string
	component string
	outcome   string
}

type testObserver struct {
	events []observedEvent
}

func (o *testObserver) ObserveSQLiteConnectionWait(component, outcome string, _ time.Duration) {
	o.events = append(o.events, observedEvent{kind: "conn", component: component, outcome: outcome})
}

func (o *testObserver) ObserveSQLiteTransactionDuration(component, outcome string, _ time.Duration) {
	o.events = append(o.events, observedEvent{kind: "tx", component: component, outcome: outcome})
}

func (o *testObserver) ObserveSQLiteWALCheckpoint(component, pageClass, outcome string, _ int64) {
	o.events = append(o.events, observedEvent{kind: "wal:" + pageClass, component: component, outcome: outcome})
}

func openTestDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(`CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)`); err != nil {
		t.Fatalf("create table: %v", err)
	}
	return db
}

func rowCount(t *testing.T, db *sql.DB) int {
	t.Helper()
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM t`).Scan(&n); err != nil {
		t.Fatalf("count: %v", err)
	}
	return n
}

func TestTransactCommitsOnNilError(t *testing.T) {
	db := openTestDB(t)
	err := Transact(context.Background(), db, func(ctx context.Context, conn *sql.Conn) error {
		if _, err := conn.ExecContext(ctx, `INSERT INTO t (v) VALUES ('a'), ('b')`); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		t.Fatalf("Transact returned err: %v", err)
	}
	if n := rowCount(t, db); n != 2 {
		t.Fatalf("row count after commit = %d, want 2", n)
	}
}

func TestTransactRollsBackOnError(t *testing.T) {
	db := openTestDB(t)
	sentinel := errors.New("callback rejected")
	err := Transact(context.Background(), db, func(ctx context.Context, conn *sql.Conn) error {
		if _, err := conn.ExecContext(ctx, `INSERT INTO t (v) VALUES ('a')`); err != nil {
			return err
		}
		return sentinel
	})
	if !errors.Is(err, sentinel) {
		t.Fatalf("Transact returned %v, want sentinel", err)
	}
	if n := rowCount(t, db); n != 0 {
		t.Fatalf("row count after rollback = %d, want 0", n)
	}
}

// TestTransactRollbackUsesBackgroundContext verifies the load-bearing
// invariant that ROLLBACK is issued with context.Background(), not the
// caller's ctx: a caller who cancels their ctx after a partial write must
// not leave the SQLite write lock held.
func TestTransactRollbackUsesBackgroundContext(t *testing.T) {
	db := openTestDB(t)
	ctx, cancel := context.WithCancel(context.Background())
	sentinel := errors.New("aborting after partial write")
	err := Transact(ctx, db, func(innerCtx context.Context, conn *sql.Conn) error {
		if _, err := conn.ExecContext(innerCtx, `INSERT INTO t (v) VALUES ('a')`); err != nil {
			return err
		}
		// Simulate a caller cancelling before the callback returns.
		// If the helper used innerCtx for ROLLBACK, the rollback exec
		// would fail with context.Canceled and the tx would leak. Our
		// invariant is that ROLLBACK runs on context.Background().
		cancel()
		return sentinel
	})
	if !errors.Is(err, sentinel) {
		t.Fatalf("Transact returned %v, want sentinel", err)
	}
	// Prove the tx was fully unwound: a fresh BEGIN IMMEDIATE on a
	// separate conn must succeed immediately. If the previous tx
	// held the writer lock the busy_timeout would fire (or with our
	// pool of 1, this would deadlock).
	if err := Transact(context.Background(), db, func(c context.Context, conn *sql.Conn) error {
		_, err := conn.ExecContext(c, `INSERT INTO t (v) VALUES ('b')`)
		return err
	}); err != nil {
		t.Fatalf("follow-up Transact after cancelled-caller rollback: %v", err)
	}
	if n := rowCount(t, db); n != 1 {
		t.Fatalf("row count = %d, want 1 (only the follow-up commit)", n)
	}
}

func TestTransactBeginError(t *testing.T) {
	db := openTestDB(t)
	_ = db.Close() // force db.Conn to fail
	err := Transact(context.Background(), db, func(ctx context.Context, conn *sql.Conn) error {
		t.Fatal("callback should not run when db is closed")
		return nil
	})
	if err == nil {
		t.Fatal("Transact returned nil on closed db, want error")
	}
}

func TestTransactObservedEmitsConnectionWaitAndTransactionOutcome(t *testing.T) {
	db := openTestDB(t)
	observer := &testObserver{}

	err := TransactObserved(context.Background(), db, "billing_hot_path", observer, func(ctx context.Context, conn *sql.Conn) error {
		_, err := conn.ExecContext(ctx, `INSERT INTO t (v) VALUES ('a')`)
		return err
	})
	if err != nil {
		t.Fatalf("TransactObserved success path returned err: %v", err)
	}

	sentinel := errors.New("callback rejected")
	err = TransactObserved(context.Background(), db, "billing_hot_path", observer, func(context.Context, *sql.Conn) error {
		return sentinel
	})
	if !errors.Is(err, sentinel) {
		t.Fatalf("TransactObserved returned %v, want sentinel", err)
	}

	assertObserved(t, observer.events, observedEvent{kind: "conn", component: "billing_hot_path", outcome: "success"})
	assertObserved(t, observer.events, observedEvent{kind: "tx", component: "billing_hot_path", outcome: "success"})
	assertObserved(t, observer.events, observedEvent{kind: "tx", component: "billing_hot_path", outcome: "error"})
}

func TestRunWALCheckpointEmitsPageClasses(t *testing.T) {
	db, err := sql.Open("sqlite", WithPragmas(t.TempDir()+"/checkpoint.db"))
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if _, err := db.Exec(`CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)`); err != nil {
		t.Fatalf("create table: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO t (v) VALUES ('a')`); err != nil {
		t.Fatalf("insert: %v", err)
	}

	observer := &testObserver{}
	if err := RunWALCheckpoint(context.Background(), db, "wal_checkpoint", observer); err != nil {
		t.Fatalf("RunWALCheckpoint returned err: %v", err)
	}

	assertObserved(t, observer.events, observedEvent{kind: "wal:busy", component: "wal_checkpoint", outcome: "success"})
	assertObserved(t, observer.events, observedEvent{kind: "wal:log", component: "wal_checkpoint", outcome: "success"})
	assertObserved(t, observer.events, observedEvent{kind: "wal:checkpointed", component: "wal_checkpoint", outcome: "success"})
}

func assertObserved(t *testing.T, events []observedEvent, want observedEvent) {
	t.Helper()
	for _, got := range events {
		if got == want {
			return
		}
	}
	t.Fatalf("missing observation %+v in %+v", want, events)
}
