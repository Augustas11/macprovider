package requestlog

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	_ "modernc.org/sqlite"
)

type Store struct {
	db *sql.DB
}

var ErrIdempotencyConflict = errors.New("idempotency key body hash mismatch")

type execer interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
}

type Row struct {
	TSUtc               time.Time
	RequestID           string
	Model               string
	ProviderAssignedID  string
	PromptTokens        *int64
	CompletionTokens    *int64
	EstimatedCompTokens *int64
	LatencyMs           float64
	RoutingMs           float64
	Status              int
	Stream              bool
	BuyerIP             string
	Error               string
	ErrorCode           string
	PrefHeader          string
	ProviderHeader      string
	Retried             int
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

func (s *Store) DB() *sql.DB {
	if s == nil {
		return nil
	}
	return s.db
}

func (s *Store) migrate(ctx context.Context) error {
	if _, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS request_log (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_utc               TEXT    NOT NULL,
    request_id           TEXT    NOT NULL,
    model                TEXT    NOT NULL,
    provider_assigned_id TEXT    NULL,
    prompt_tokens        INTEGER NULL,
    completion_tokens    INTEGER NULL,
    estimated_completion_tokens INTEGER NULL,
    total_tokens         INTEGER NULL,
    latency_ms           REAL    NOT NULL,
    routing_ms           REAL    NOT NULL,
    status               INTEGER NOT NULL,
    stream               INTEGER NOT NULL,
    buyer_ip             TEXT    NOT NULL DEFAULT '',
    error                TEXT    NULL,
    error_code           TEXT    NULL,
    pref_header          TEXT    NULL,
    provider_header      TEXT    NULL,
    retried              INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_request_log_ts_utc
    ON request_log(ts_utc);
CREATE INDEX IF NOT EXISTS idx_request_log_request_id_id
    ON request_log(request_id, id);

CREATE TABLE IF NOT EXISTS request_idempotency_keys (
    idempotency_key TEXT PRIMARY KEY,
    body_sha256    TEXT NOT NULL,
    request_id     TEXT NOT NULL UNIQUE,
    created_at_utc TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_request_idempotency_request
    ON request_idempotency_keys(request_id);
`); err != nil {
		return err
	}
	return s.ensureColumns(ctx)
}

func (s *Store) Insert(ctx context.Context, row Row) error {
	return insert(ctx, s.db, row)
}

func (s *Store) ReserveIdempotencyKey(ctx context.Context, key, bodySHA256, requestID string, now time.Time) (string, bool, error) {
	if s == nil || s.db == nil {
		return "", false, fmt.Errorf("store is closed")
	}
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{})
	if err != nil {
		return "", false, err
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback()
		}
	}()
	var existingHash, existingRequestID string
	err = tx.QueryRowContext(ctx, `SELECT body_sha256, request_id FROM request_idempotency_keys WHERE idempotency_key = ?`, key).Scan(&existingHash, &existingRequestID)
	if err == nil {
		if existingHash != bodySHA256 {
			return "", false, ErrIdempotencyConflict
		}
		if err := tx.Commit(); err != nil {
			return "", false, err
		}
		committed = true
		return existingRequestID, true, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return "", false, err
	}
	if _, err := tx.ExecContext(ctx, `
INSERT INTO request_idempotency_keys (idempotency_key, body_sha256, request_id, created_at_utc)
VALUES (?, ?, ?, ?)`,
		key, bodySHA256, requestID, now.UTC().Format(time.RFC3339Nano),
	); err != nil {
		return "", false, err
	}
	if err := tx.Commit(); err != nil {
		return "", false, err
	}
	committed = true
	return requestID, false, nil
}

func (s *Store) PruneBefore(ctx context.Context, cutoff time.Time) (int64, error) {
	if s == nil || s.db == nil {
		return 0, fmt.Errorf("store is closed")
	}
	cutoffText := cutoff.UTC().Format(time.RFC3339Nano)
	if _, err := s.db.ExecContext(ctx, `DELETE FROM request_idempotency_keys WHERE julianday(created_at_utc) < julianday(?)`, cutoffText); err != nil {
		return 0, err
	}
	result, err := s.db.ExecContext(ctx, `DELETE FROM request_log WHERE julianday(ts_utc) < julianday(?)`, cutoffText)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

func (s *Store) BeginTx(ctx context.Context, opts *sql.TxOptions) (*sql.Tx, error) {
	if s == nil || s.db == nil {
		return nil, fmt.Errorf("store is closed")
	}
	return s.db.BeginTx(ctx, opts)
}

func (s *Store) InsertTx(ctx context.Context, tx *sql.Tx, row Row) error {
	if tx == nil {
		return fmt.Errorf("tx is required")
	}
	return insert(ctx, tx, row)
}

func (s *Store) InsertExec(ctx context.Context, db interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
}, row Row) error {
	if db == nil {
		return fmt.Errorf("db is required")
	}
	return insert(ctx, db, row)
}

func insert(ctx context.Context, db execer, row Row) error {
	var totalTokens sql.NullInt64
	if row.PromptTokens != nil && row.CompletionTokens != nil {
		if *row.PromptTokens >= 0 && *row.CompletionTokens >= 0 && *row.PromptTokens <= math.MaxInt64-*row.CompletionTokens {
			totalTokens = sql.NullInt64{Int64: *row.PromptTokens + *row.CompletionTokens, Valid: true}
		}
	}
	_, err := db.ExecContext(ctx, `
INSERT INTO request_log (
    ts_utc,
    request_id,
    model,
    provider_assigned_id,
    prompt_tokens,
    completion_tokens,
    estimated_completion_tokens,
    total_tokens,
    latency_ms,
    routing_ms,
    status,
    stream,
    buyer_ip,
    error,
    error_code,
    pref_header,
    provider_header,
    retried
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		row.TSUtc.UTC().Format(time.RFC3339Nano),
		row.RequestID,
		row.Model,
		nullString(row.ProviderAssignedID),
		nullInt64(row.PromptTokens),
		nullInt64(row.CompletionTokens),
		nullInt64(row.EstimatedCompTokens),
		totalTokens,
		row.LatencyMs,
		row.RoutingMs,
		row.Status,
		boolInt(row.Stream),
		row.BuyerIP,
		nullString(row.Error),
		nullString(row.ErrorCode),
		nullString(row.PrefHeader),
		nullString(row.ProviderHeader),
		row.Retried,
	)
	return err
}

func (s *Store) ensureColumns(ctx context.Context) error {
	cols, err := s.columns(ctx)
	if err != nil {
		return err
	}
	for _, migration := range []struct {
		name string
		sql  string
	}{
		{name: "provider_assigned_id", sql: `ALTER TABLE request_log ADD COLUMN provider_assigned_id TEXT NULL`},
		{name: "prompt_tokens", sql: `ALTER TABLE request_log ADD COLUMN prompt_tokens INTEGER NULL`},
		{name: "completion_tokens", sql: `ALTER TABLE request_log ADD COLUMN completion_tokens INTEGER NULL`},
		{name: "estimated_completion_tokens", sql: `ALTER TABLE request_log ADD COLUMN estimated_completion_tokens INTEGER NULL`},
		{name: "total_tokens", sql: `ALTER TABLE request_log ADD COLUMN total_tokens INTEGER NULL`},
		{name: "latency_ms", sql: `ALTER TABLE request_log ADD COLUMN latency_ms REAL NOT NULL DEFAULT 0`},
		{name: "routing_ms", sql: `ALTER TABLE request_log ADD COLUMN routing_ms REAL NOT NULL DEFAULT 0`},
		{name: "status", sql: `ALTER TABLE request_log ADD COLUMN status INTEGER NOT NULL DEFAULT 0`},
		{name: "stream", sql: `ALTER TABLE request_log ADD COLUMN stream INTEGER NOT NULL DEFAULT 0`},
		{name: "buyer_ip", sql: `ALTER TABLE request_log ADD COLUMN buyer_ip TEXT NOT NULL DEFAULT ''`},
		{name: "error", sql: `ALTER TABLE request_log ADD COLUMN error TEXT NULL`},
		{name: "error_code", sql: `ALTER TABLE request_log ADD COLUMN error_code TEXT NULL`},
		{name: "pref_header", sql: `ALTER TABLE request_log ADD COLUMN pref_header TEXT NULL`},
		{name: "provider_header", sql: `ALTER TABLE request_log ADD COLUMN provider_header TEXT NULL`},
		{name: "retried", sql: `ALTER TABLE request_log ADD COLUMN retried INTEGER NOT NULL DEFAULT 0`},
	} {
		if cols[migration.name] {
			continue
		}
		if _, err := s.db.ExecContext(ctx, migration.sql); err != nil {
			return err
		}
	}
	return s.requireColumns(ctx, []string{"id", "ts_utc", "request_id", "model"})
}

func (s *Store) columns(ctx context.Context) (map[string]bool, error) {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(request_log)`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	cols := map[string]bool{}
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull int
		var defaultValue sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
			return nil, err
		}
		cols[name] = true
	}
	return cols, rows.Err()
}

func (s *Store) requireColumns(ctx context.Context, names []string) error {
	cols, err := s.columns(ctx)
	if err != nil {
		return err
	}
	for _, name := range names {
		if !cols[name] {
			return fmt.Errorf("request_log missing required column %s", name)
		}
	}
	return nil
}

func nullString(v string) sql.NullString {
	return sql.NullString{String: v, Valid: v != ""}
}

func nullInt64(v *int64) sql.NullInt64 {
	if v == nil {
		return sql.NullInt64{}
	}
	return sql.NullInt64{Int64: *v, Valid: true}
}

func boolInt(v bool) int {
	if v {
		return 1
	}
	return 0
}
