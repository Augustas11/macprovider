package auth

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	_ "modernc.org/sqlite"
)

type Store struct {
	db *sql.DB
}

const tokenDisplayPrefixLength = 12

type TokenRecord struct {
	ID           int64
	TokenPrefix  string
	ProviderID   string
	ProviderName string
	CreatedAt    string
	RevokedAt    sql.NullString
	LastUsedAt   sql.NullString
}

func AuthorizedBearer(r *http.Request, expected string) bool {
	return expected == "" || BearerTokenMatchesHeader(r.Header, expected)
}

func BearerTokenMatchesHeader(headers http.Header, expected string) bool {
	expected = strings.TrimSpace(expected)
	if expected == "" {
		return false
	}
	auth := strings.TrimSpace(headers.Get("Authorization"))
	token, ok := strings.CutPrefix(auth, "Bearer ")
	if !ok {
		return false
	}
	token = strings.TrimSpace(token)
	tokenHash := sha256.Sum256([]byte(token))
	expectedHash := sha256.Sum256([]byte(expected))
	return hmac.Equal(tokenHash[:], expectedHash[:])
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
	db, err := sql.Open("sqlite", sqliteutil.WithPragmas(path))
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
	if _, err := s.db.ExecContext(ctx, `PRAGMA busy_timeout=5000`); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS provider_tokens (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    token_hash TEXT NOT NULL UNIQUE,
    token_prefix TEXT NOT NULL,
    provider_id TEXT NOT NULL DEFAULT '',
    provider_name TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    revoked_at TEXT DEFAULT NULL,
    last_used_at TEXT DEFAULT NULL
);
CREATE INDEX IF NOT EXISTS idx_token_hash ON provider_tokens(token_hash);
`)
	if err != nil {
		return err
	}
	return s.ensureProviderIDColumn(ctx)
}

func (s *Store) ensureProviderIDColumn(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(provider_tokens)`)
	if err != nil {
		return err
	}
	defer rows.Close()
	hasProviderID := false
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull int
		var defaultValue sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
			return err
		}
		if name == "provider_id" {
			hasProviderID = true
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if hasProviderID {
		return nil
	}
	_, err = s.db.ExecContext(ctx, `ALTER TABLE provider_tokens ADD COLUMN provider_id TEXT NOT NULL DEFAULT ''`)
	return err
}

func (s *Store) IssueToken(ctx context.Context, providerID, providerName string) (TokenRecord, string, error) {
	providerID = strings.TrimSpace(providerID)
	providerName = strings.TrimSpace(providerName)
	if providerID == "" {
		return TokenRecord{}, "", fmt.Errorf("provider id is required")
	}
	if providerName == "" {
		return TokenRecord{}, "", fmt.Errorf("provider name is required")
	}
	var raw [32]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return TokenRecord{}, "", err
	}
	token := hex.EncodeToString(raw[:])
	hash := tokenHash(token)
	prefix := token[:tokenDisplayPrefixLength]
	createdAt := nowString()
	res, err := s.db.ExecContext(ctx, `INSERT INTO provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at) VALUES (?, ?, ?, ?, ?)`, hash, prefix, providerID, providerName, createdAt)
	if err != nil {
		return TokenRecord{}, "", err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return TokenRecord{}, "", err
	}
	return TokenRecord{ID: id, TokenPrefix: prefix, ProviderID: providerID, ProviderName: providerName, CreatedAt: createdAt}, token, nil
}

func (s *Store) ValidateToken(ctx context.Context, token string) (string, bool, error) {
	if token == "" {
		return "", false, nil
	}
	hash := tokenHash(token)
	var providerID string
	err := s.db.QueryRowContext(ctx, `SELECT provider_id FROM provider_tokens WHERE token_hash = ? AND revoked_at IS NULL`, hash).Scan(&providerID)
	if err == sql.ErrNoRows {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	if providerID == "" {
		return "", false, nil
	}
	return providerID, true, nil
}

func (s *Store) MarkTokenUsed(ctx context.Context, token string) error {
	if token == "" {
		return fmt.Errorf("token is required")
	}
	res, err := s.db.ExecContext(ctx, `UPDATE provider_tokens SET last_used_at = ? WHERE token_hash = ? AND revoked_at IS NULL AND provider_id <> ''`, nowString(), tokenHash(token))
	if err != nil {
		return err
	}
	affected, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if affected == 0 {
		return fmt.Errorf("no active token found")
	}
	return nil
}

func (s *Store) RevokeToken(ctx context.Context, tokenPrefix string) (TokenRecord, error) {
	if len(tokenPrefix) < 6 {
		return TokenRecord{}, fmt.Errorf("token prefix must be at least 6 hex characters")
	}
	prefix := tokenPrefix
	if len(prefix) > tokenDisplayPrefixLength {
		prefix = prefix[:tokenDisplayPrefixLength]
	}
	if !isHexPrefix(prefix) {
		return TokenRecord{}, fmt.Errorf("token prefix must contain only hex characters")
	}
	rows, err := s.db.QueryContext(ctx, `SELECT id FROM provider_tokens WHERE substr(token_prefix, 1, ?) = ? AND revoked_at IS NULL LIMIT 2`, len(prefix), prefix)
	if err != nil {
		return TokenRecord{}, err
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return TokenRecord{}, err
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		return TokenRecord{}, err
	}
	if len(ids) == 0 {
		return TokenRecord{}, fmt.Errorf("no active token found for prefix %s", prefix)
	}
	if len(ids) > 1 {
		return TokenRecord{}, fmt.Errorf("ambiguous active token prefix %s", prefix)
	}
	revokedAt := nowString()
	res, err := s.db.ExecContext(ctx, `UPDATE provider_tokens SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL`, revokedAt, ids[0])
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
	return s.tokenByID(ctx, ids[0])
}

func (s *Store) ListTokens(ctx context.Context) ([]TokenRecord, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, token_prefix, provider_id, provider_name, created_at, revoked_at, last_used_at FROM provider_tokens ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var records []TokenRecord
	for rows.Next() {
		var r TokenRecord
		if err := rows.Scan(&r.ID, &r.TokenPrefix, &r.ProviderID, &r.ProviderName, &r.CreatedAt, &r.RevokedAt, &r.LastUsedAt); err != nil {
			return nil, err
		}
		records = append(records, r)
	}
	return records, rows.Err()
}

func (s *Store) tokenByID(ctx context.Context, id int64) (TokenRecord, error) {
	var r TokenRecord
	err := s.db.QueryRowContext(ctx, `SELECT id, token_prefix, provider_id, provider_name, created_at, revoked_at, last_used_at FROM provider_tokens WHERE id = ?`, id).
		Scan(&r.ID, &r.TokenPrefix, &r.ProviderID, &r.ProviderName, &r.CreatedAt, &r.RevokedAt, &r.LastUsedAt)
	return r, err
}

func isHexPrefix(prefix string) bool {
	for _, r := range prefix {
		if r >= '0' && r <= '9' || r >= 'a' && r <= 'f' || r >= 'A' && r <= 'F' {
			continue
		}
		return false
	}
	return true
}

func tokenHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func nowString() string {
	return time.Now().UTC().Format("2006-01-02T15:04:05Z")
}
