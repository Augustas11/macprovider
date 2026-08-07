package sqlite

import (
	"context"
	"strings"
	"testing"
)

// TestImmediateTxCommitDoesNotPoisonConnWhenContextCancelled reproduces the
// 2026-08-07 gateway quota-reservation outage: the terminal COMMIT ran under the
// caller's (already-cancelled) context, failed without ending the SQLite
// transaction, and conn.Close() then returned a connection with an open
// transaction to the MaxOpenConns=1 pool. Every subsequent writer — quota
// reservation, settlement holds — failed with
// "cannot start a transaction within a transaction" until the process restarted.
func TestImmediateTxCommitDoesNotPoisonConnWhenContextCancelled(t *testing.T) {
	store := newTestStore(t)

	ctx, cancel := context.WithCancel(context.Background())
	tx, err := store.beginImmediate(ctx)
	if err != nil {
		t.Fatalf("beginImmediate: %v", err)
	}
	// The request/reconcile deadline fires before the terminal COMMIT runs.
	cancel()
	// Commit runs its terminal statement on a fresh uncancellable context, so a
	// dead caller context must NOT prevent a clean commit.
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit under cancelled caller context: %v", err)
	}

	assertConnNotPoisoned(t, store)
}

// TestDiscardConnDropsPoisonedConnectionFromPool covers the last-resort cleanup
// path: when a terminal COMMIT/ROLLBACK cannot end the transaction and the
// connection is discarded, the MaxOpenConns=1 pool must open a fresh connection
// rather than hand back the one still mid-transaction. Without discard, that
// leftover open transaction is exactly the outage's poison.
func TestDiscardConnDropsPoisonedConnectionFromPool(t *testing.T) {
	store := newTestStore(t)

	// Borrow the single pooled connection and leave a transaction open on it,
	// standing in for a terminal statement that could not end the transaction.
	conn, err := store.db.Conn(context.Background())
	if err != nil {
		t.Fatalf("Conn: %v", err)
	}
	if _, err := conn.ExecContext(context.Background(), "BEGIN IMMEDIATE"); err != nil {
		t.Fatalf("BEGIN IMMEDIATE: %v", err)
	}
	discardConn(conn)

	assertConnNotPoisoned(t, store)
}

// TestImmediateTxRollbackDoesNotPoisonConnWhenContextCancelled is the rollback
// counterpart: a cancelled caller context must not prevent ROLLBACK from ending
// the transaction before the connection is returned to the pool.
func TestImmediateTxRollbackDoesNotPoisonConnWhenContextCancelled(t *testing.T) {
	store := newTestStore(t)

	ctx, cancel := context.WithCancel(context.Background())
	tx, err := store.beginImmediate(ctx)
	if err != nil {
		t.Fatalf("beginImmediate: %v", err)
	}
	cancel()
	tx.Rollback()

	assertConnNotPoisoned(t, store)
}

// assertConnNotPoisoned proves the single writer connection is not stuck mid
// transaction: a fresh immediate transaction must open and commit rather than
// fail with "cannot start a transaction within a transaction".
func assertConnNotPoisoned(t *testing.T, store *Store) {
	t.Helper()
	tx, err := store.beginImmediate(context.Background())
	if err != nil {
		if strings.Contains(err.Error(), "transaction within a transaction") {
			t.Fatalf("connection left poisoned by prior terminal statement: %v", err)
		}
		t.Fatalf("beginImmediate on recovered connection: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit on recovered connection: %v", err)
	}
}
