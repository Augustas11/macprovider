package audit

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	_ "modernc.org/sqlite"
)

var errStoreClosed = errors.New("audit store is closed")

type Store struct {
	db                             *sql.DB
	settlementReceiptOutboxEnabled bool
}

// DefaultDBPath returns the sibling audit DB path next to the primary
// coordinator money DB.
func DefaultDBPath(storageDBPath string) string {
	dir := filepath.Dir(strings.TrimSpace(storageDBPath))
	if dir == "" || dir == "." {
		return "coordinator-audit.db"
	}
	return filepath.Join(dir, "coordinator-audit.db")
}

func OpenStore(dbPath string) (*Store, error) {
	return openStore(dbPath, false, false)
}

func OpenSettlementReceiptStore(dbPath string) (*Store, error) {
	return openStore(dbPath, false, true)
}

// OpenStoreWithManualWALCheckpoint opens an audit store for a SQLite DB whose
// physical file has an explicit external WAL checkpoint owner.
func OpenStoreWithManualWALCheckpoint(dbPath string) (*Store, error) {
	return openStore(dbPath, true, false)
}

func openStore(dbPath string, manualWALCheckpoint bool, settlementReceiptOutboxEnabled bool) (*Store, error) {
	if dbPath == "" {
		return nil, fmt.Errorf("db path is required")
	}
	if dir := filepath.Dir(dbPath); dir != "." && dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, err
		}
	}
	dsn := sqliteutil.WithPragmas(dbPath)
	if manualWALCheckpoint {
		dsn = sqliteutil.WithManualWALCheckpointPragmas(dbPath)
	}
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// QW-5 / M2-3 / ARCH-3: cap the pool at a single connection (mirrors
	// phase5-gateway/internal/storage/sqlite/store.go). Prevents implicit
	// concurrent BEGIN IMMEDIATE on shared SQLite files and removes a
	// latent SQLITE_BUSY source on the coordinator money path.
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	s := &Store{db: db, settlementReceiptOutboxEnabled: settlementReceiptOutboxEnabled}
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
	if err != nil {
		return err
	}
	if !s.settlementReceiptOutboxEnabled {
		return nil
	}
	exists, err := s.columnExists(ctx, "audit_log", "settlement_receipt_audit_outbox_id")
	if err != nil {
		return err
	}
	if !exists {
		if _, err := s.db.ExecContext(ctx, `ALTER TABLE audit_log ADD COLUMN settlement_receipt_audit_outbox_id INTEGER NULL`); err != nil {
			return err
		}
	}
	_, err = s.db.ExecContext(ctx, `
CREATE UNIQUE INDEX IF NOT EXISTS idx_audit_log_settlement_receipt_outbox
    ON audit_log(settlement_receipt_audit_outbox_id)
    WHERE settlement_receipt_audit_outbox_id IS NOT NULL`)
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

func (s *Store) InsertSettlementReceiptOutbox(ctx context.Context, ts time.Time, eventType, providerID, payloadJSON string, outboxID int64) (bool, error) {
	if s == nil || s.db == nil {
		return false, errStoreClosed
	}
	if outboxID <= 0 {
		return false, fmt.Errorf("settlement receipt audit outbox id is required")
	}
	var provider sql.NullString
	if providerID != "" {
		provider = sql.NullString{String: providerID, Valid: true}
	}
	res, err := s.db.ExecContext(ctx, `
INSERT OR IGNORE INTO audit_log (
    ts_utc,
    event_type,
    provider_id,
    settlement_receipt_audit_outbox_id,
    payload_json
) VALUES (?, ?, ?, ?, ?)`,
		ts.UTC().Format(time.RFC3339Nano),
		eventType,
		provider,
		outboxID,
		payloadJSON,
	)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	if n > 0 {
		return true, nil
	}
	tsUTC := ts.UTC().Format(time.RFC3339Nano)
	var gotTS, gotEventType, gotPayload string
	var gotProvider sql.NullString
	if err := s.db.QueryRowContext(ctx, `
SELECT ts_utc, event_type, provider_id, payload_json
FROM audit_log
WHERE settlement_receipt_audit_outbox_id = ?`, outboxID).Scan(&gotTS, &gotEventType, &gotProvider, &gotPayload); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return false, fmt.Errorf("settlement receipt audit outbox id %d was ignored but no existing audit row was found", outboxID)
		}
		return false, err
	}
	if gotTS != tsUTC ||
		gotEventType != eventType ||
		gotProvider.Valid != provider.Valid ||
		(gotProvider.Valid && gotProvider.String != provider.String) ||
		gotPayload != payloadJSON {
		return false, fmt.Errorf("settlement receipt audit outbox id %d already exists with different audit event", outboxID)
	}
	return false, nil
}

func (s *Store) columnExists(ctx context.Context, table, column string) (bool, error) {
	rows, err := s.db.QueryContext(ctx, "PRAGMA table_info("+table+")")
	if err != nil {
		return false, err
	}
	defer rows.Close()
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull int
		var defaultValue sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
			return false, err
		}
		if name == column {
			return true, nil
		}
	}
	if err := rows.Err(); err != nil {
		return false, err
	}
	return false, nil
}

// pruneBatchSize bounds a single retention DELETE to keep the write lock
// short while billing's 6s hot path is sharing the same SQLite handle.
// PERF-3 (M3-1): the comparison stays on julianday() because audit_log
// writes use time.RFC3339Nano, which strips trailing zeros in the
// fractional seconds — variable widths break lexicographic `<` ordering
// (".000…Z" sorts before "Z"). Normalizing writes to a fixed-width
// format is deferred to a follow-up.
const pruneBatchSize = 500

// pruneBatchYieldMs is the sleep between full batches so concurrent
// audit writers can acquire the SQLite writer lock between iterations.
const pruneBatchYieldMs = 10

func (s *Store) PruneBefore(ctx context.Context, cutoff time.Time) (int64, error) {
	if s == nil || s.db == nil {
		return 0, errStoreClosed
	}
	cutoffText := cutoff.UTC().Format(time.RFC3339Nano)
	var total int64
	for {
		res, err := s.db.ExecContext(ctx, `DELETE FROM audit_log WHERE rowid IN (SELECT rowid FROM audit_log WHERE julianday(ts_utc) < julianday(?) LIMIT ?)`, cutoffText, pruneBatchSize)
		if err != nil {
			return total, err
		}
		n, err := res.RowsAffected()
		if err != nil {
			return total, err
		}
		total += n
		if n < int64(pruneBatchSize) {
			return total, nil
		}
		// Yield so concurrent writers can acquire the writer lock between full batches.
		select {
		case <-ctx.Done():
			return total, ctx.Err()
		case <-time.After(pruneBatchYieldMs * time.Millisecond):
		}
	}
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
