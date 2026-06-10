package audit

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	_ "modernc.org/sqlite"
)

var errStoreClosed = errors.New("audit store is closed")

type Store struct {
	db *sql.DB
}

func OpenStore(dbPath string) (*Store, error) {
	if dbPath == "" {
		return nil, fmt.Errorf("db path is required")
	}
	if dir := filepath.Dir(dbPath); dir != "." && dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, err
		}
	}
	db, err := sql.Open("sqlite", sqliteutil.WithPragmas(dbPath))
	if err != nil {
		return nil, err
	}
	// Match phase5-gateway/internal/storage/sqlite/store.go:38-39: cap the
	// pool at one connection so writers using BEGIN IMMEDIATE serialise
	// inside the Go layer instead of contending in sqlite's 5s busy_timeout.
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	s := &Store{db: db}
	ctx := context.Background()
	if _, err := s.db.ExecContext(ctx, `PRAGMA journal_mode=WAL`); err != nil {
		_ = db.Close()
		return nil, err
	}
	if _, err := s.db.ExecContext(ctx, `PRAGMA busy_timeout=5000`); err != nil {
		_ = db.Close()
		return nil, err
	}
	if err := s.migrate(ctx); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error {
	if s == nil || s.db == nil {
		return nil
	}
	return s.db.Close()
}

// DB returns the underlying *sql.DB. This exists for two scopes only:
//   - tests that need to assert on row state (the integration tests in
//     internal/ws and the boundary tests in this package read via DB()).
//   - future SPEC-002 §7.10.3 R-7.10.11 event types that may want to
//     share connection pooling with operator_model_swap.
//
// Production code MUST use EmitSwap / Insert / PruneBefore. Bypassing
// those entry points skips the F-1.5 invariant guard (SPEC-002 v1.3.5
// R-7.10.9) and the eventType/providerID hygiene.
func (s *Store) DB() *sql.DB {
	if s == nil {
		return nil
	}
	return s.db
}

func (s *Store) migrate(ctx context.Context) error {
	if s == nil || s.db == nil {
		return errStoreClosed
	}
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_utc TEXT NOT NULL,
    event_type TEXT NOT NULL,
    provider_id TEXT,
    payload_json TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_log_ts_utc ON audit_log(ts_utc);
CREATE INDEX IF NOT EXISTS idx_audit_log_provider_id ON audit_log(provider_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_event_type ON audit_log(event_type);
`)
	return err
}

func (s *Store) Insert(ctx context.Context, ts time.Time, eventType, providerID, payloadJSON string) error {
	if s == nil || s.db == nil {
		return errStoreClosed
	}
	var provider sql.NullString
	if providerID != "" {
		provider = sql.NullString{String: providerID, Valid: true}
	}
	_, err := s.db.ExecContext(ctx, `
INSERT INTO audit_log (
    ts_utc,
    event_type,
    provider_id,
    payload_json
) VALUES (?, ?, ?, ?)`,
		ts.UTC().Format(time.RFC3339Nano),
		eventType,
		provider,
		payloadJSON,
	)
	return err
}

func (s *Store) PruneBefore(ctx context.Context, cutoff time.Time) (int64, error) {
	if s == nil || s.db == nil {
		return 0, errStoreClosed
	}
	result, err := s.db.ExecContext(ctx, `DELETE FROM audit_log WHERE julianday(ts_utc) < julianday(?)`, cutoff.UTC().Format(time.RFC3339Nano))
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

// EmitSwap writes one operator_model_swap audit row for an upstream-gated
// Phase 2C swap event. ApplyHeartbeat invokes the emitter while holding
// Registry.mu; this method must not call back into pool.Registry and keeps the
// write best-effort per SPEC-002 v1.3.5 R-7.10.8.
func (s *Store) EmitSwap(ctx context.Context, event pool.SwapEvent) error {
	payload, err := buildSwapPayload(event)
	if err != nil {
		return err
	}
	if err := assertNoForbiddenSubstrings(payload); err != nil {
		return fmt.Errorf("%w; payload_json=%s", err, payload)
	}
	if err := s.Insert(ctx, event.CompletedAt.UTC(), "operator_model_swap", event.ProviderID, string(payload)); err != nil {
		return fmt.Errorf("insert operator_model_swap audit row: %w; payload_json=%s", err, payload)
	}
	return nil
}
