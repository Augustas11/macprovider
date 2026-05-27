package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

type Store struct {
	db *sql.DB
}

type TokenRecord struct {
	ID           int64
	TokenPrefix  string
	ProviderName string
	CreatedAt    string
	RevokedAt    sql.NullString
	LastUsedAt   sql.NullString
}

func OpenStore(path string) (*Store, error) {
	if path == "" {
		return nil, fmt.Errorf("db path is required")
	}
	if dir := filepath.Dir(path); dir != "." && dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, err
		}
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	s := &Store{db: db}
	if err := s.migrate(context.Background()); err != nil {
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

func (s *Store) migrate(ctx context.Context) error {
	if _, err := s.db.ExecContext(ctx, `PRAGMA journal_mode=WAL`); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS provider_tokens (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    token_hash TEXT NOT NULL UNIQUE,
    token_prefix TEXT NOT NULL,
    provider_name TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    revoked_at TEXT DEFAULT NULL,
    last_used_at TEXT DEFAULT NULL
);
CREATE INDEX IF NOT EXISTS idx_token_hash ON provider_tokens(token_hash);
`)
	return err
}

func (s *Store) IssueToken(ctx context.Context, providerName string) (TokenRecord, string, error) {
	if providerName == "" {
		return TokenRecord{}, "", fmt.Errorf("provider name is required")
	}
	var raw [32]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return TokenRecord{}, "", err
	}
	token := hex.EncodeToString(raw[:])
	hash := tokenHash(token)
	prefix := token[:6]
	createdAt := nowString()
	res, err := s.db.ExecContext(ctx, `INSERT INTO provider_tokens (token_hash, token_prefix, provider_name, created_at) VALUES (?, ?, ?, ?)`, hash, prefix, providerName, createdAt)
	if err != nil {
		return TokenRecord{}, "", err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return TokenRecord{}, "", err
	}
	return TokenRecord{ID: id, TokenPrefix: prefix, ProviderName: providerName, CreatedAt: createdAt}, token, nil
}

func (s *Store) ValidateToken(ctx context.Context, token string) (bool, error) {
	if token == "" {
		return false, nil
	}
	hash := tokenHash(token)
	var id int64
	err := s.db.QueryRowContext(ctx, `SELECT id FROM provider_tokens WHERE token_hash = ? AND revoked_at IS NULL`, hash).Scan(&id)
	if err == sql.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	_, err = s.db.ExecContext(ctx, `UPDATE provider_tokens SET last_used_at = ? WHERE id = ?`, nowString(), id)
	if err != nil {
		return false, err
	}
	return true, nil
}

func (s *Store) RevokeToken(ctx context.Context, tokenPrefix string) (TokenRecord, error) {
	if len(tokenPrefix) < 6 {
		return TokenRecord{}, fmt.Errorf("token prefix must be at least 6 hex characters")
	}
	prefix := tokenPrefix[:6]
	revokedAt := nowString()
	res, err := s.db.ExecContext(ctx, `UPDATE provider_tokens SET revoked_at = ? WHERE token_prefix = ? AND revoked_at IS NULL`, revokedAt, prefix)
	if err != nil {
		return TokenRecord{}, err
	}
	affected, err := res.RowsAffected()
	if err != nil {
		return TokenRecord{}, err
	}
	if affected == 0 {
		return TokenRecord{}, fmt.Errorf("no active token found for prefix %s", prefix)
	}
	return s.tokenByPrefix(ctx, prefix)
}

func (s *Store) ListTokens(ctx context.Context) ([]TokenRecord, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, token_prefix, provider_name, created_at, revoked_at, last_used_at FROM provider_tokens ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var records []TokenRecord
	for rows.Next() {
		var r TokenRecord
		if err := rows.Scan(&r.ID, &r.TokenPrefix, &r.ProviderName, &r.CreatedAt, &r.RevokedAt, &r.LastUsedAt); err != nil {
			return nil, err
		}
		records = append(records, r)
	}
	return records, rows.Err()
}

func (s *Store) tokenByPrefix(ctx context.Context, prefix string) (TokenRecord, error) {
	var r TokenRecord
	err := s.db.QueryRowContext(ctx, `SELECT id, token_prefix, provider_name, created_at, revoked_at, last_used_at FROM provider_tokens WHERE token_prefix = ? ORDER BY id DESC LIMIT 1`, prefix).
		Scan(&r.ID, &r.TokenPrefix, &r.ProviderName, &r.CreatedAt, &r.RevokedAt, &r.LastUsedAt)
	return r, err
}

func tokenHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func nowString() string {
	return time.Now().UTC().Format("2006-01-02T15:04:05Z")
}
