package sqliteutil

import (
	"context"
	"database/sql"
	"time"
)

// Observer receives closed-set SQLite timing observations from money-path
// stores. Implementations must keep labels bounded; component values are
// call-site constants, and outcome is "success" or "error".
type Observer interface {
	ObserveSQLiteConnectionWait(component, outcome string, duration time.Duration)
	ObserveSQLiteTransactionDuration(component, outcome string, duration time.Duration)
}

// Transact reserves a single *sql.Conn from db, issues BEGIN IMMEDIATE to
// take the SQLite write lock deterministically, invokes fn with the
// reserved connection, and then COMMITs on nil error or ROLLBACKs on
// non-nil error (or panic).
//
// The ROLLBACK is issued with context.Background(), never the caller's
// ctx, so cancellation of the request context after a partial write does
// not leave the transaction dangling.
//
// The callback receives the reserved *sql.Conn and MUST issue all
// subsequent statements against it — SQLite transactions are bound to a
// single connection, and running a statement on a different conn from the
// pool while a BEGIN IMMEDIATE is in flight would deadlock against the
// write lock this call is holding.
//
// This helper replaces the hand-rolled
//
//	conn, _ := s.db.Conn(ctx); defer conn.Close()
//	conn.ExecContext(ctx, "BEGIN IMMEDIATE")
//	committed := false
//	defer func() { if !committed { _, _ = conn.ExecContext(context.Background(), "ROLLBACK") } }()
//	... work ...
//	conn.ExecContext(ctx, "COMMIT"); committed = true
//
// pattern used across money-path stores (billing, auth token issuance,
// requestlog, receipts). Semantics are byte-equivalent to that pattern;
// see phase4-coordinator/internal/sqliteutil/transact_test.go for the
// invariant coverage.
func Transact(ctx context.Context, db *sql.DB, fn func(context.Context, *sql.Conn) error) (err error) {
	return TransactObserved(ctx, db, "", nil, fn)
}

// TransactObserved is Transact with optional timing observation for the
// sql.DB connection wait and full BEGIN IMMEDIATE..COMMIT/ROLLBACK duration.
func TransactObserved(ctx context.Context, db *sql.DB, component string, observer Observer, fn func(context.Context, *sql.Conn) error) (err error) {
	connWaitStarted := time.Now()
	conn, cerr := db.Conn(ctx)
	observeConnectionWait(observer, component, cerr, time.Since(connWaitStarted))
	if cerr != nil {
		return cerr
	}
	defer conn.Close()

	txStarted := time.Now()
	txErr := true
	defer func() {
		if err == nil && !txErr {
			observeTransactionDuration(observer, component, nil, time.Since(txStarted))
			return
		}
		observeTransactionDuration(observer, component, err, time.Since(txStarted))
	}()

	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		return err
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()

	if err := fn(ctx, conn); err != nil {
		return err
	}

	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		return err
	}
	committed = true
	txErr = false
	return nil
}

func observeConnectionWait(observer Observer, component string, err error, duration time.Duration) {
	if observer == nil || component == "" {
		return
	}
	observer.ObserveSQLiteConnectionWait(component, sqliteOutcome(err), duration)
}

func observeTransactionDuration(observer Observer, component string, err error, duration time.Duration) {
	if observer == nil || component == "" {
		return
	}
	observer.ObserveSQLiteTransactionDuration(component, sqliteOutcome(err), duration)
}

func sqliteOutcome(err error) string {
	if err != nil {
		return "error"
	}
	return "success"
}
