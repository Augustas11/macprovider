package sqliteutil

import (
	"context"
	"database/sql"
)

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
	conn, cerr := db.Conn(ctx)
	if cerr != nil {
		return cerr
	}
	defer conn.Close()

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
	return nil
}
