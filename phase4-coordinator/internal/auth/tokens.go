package auth

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	_ "modernc.org/sqlite"
)

// ErrActiveTokenAlreadyExists is returned by IssueToken when the
// per-provider_id unique-constraint installed by
// ensureActiveProviderIDUniqueness rejects the INSERT because an
// unrevoked token already exists for the same provider_id. Callers
// MUST distinguish this sentinel from generic DB errors so they can
// apply SPEC-003 v0.8.3 FR-C9.4 admit-tokenless semantics (mark the
// admission as AuthBearerlessDuplicate, exclude from routing/billing,
// refuse to evict an existing routable session) rather than treating
// it as an internal error.
//
// Pre-v0.8.2 a race on the SELECT-then-INSERT TOFU pattern was the
// credential-capture path the codex security re-audit on PR #44
// flagged as MAJOR-1. The partial unique index added in v0.8.2 and
// preserved in v0.8.3 (PR #69) closes that race; the wire-level
// reject was replaced with admit-tokenless in v0.8.3 (Entry 66).
var ErrActiveTokenAlreadyExists = errors.New("provider_token: active token already exists for provider_id")

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
	if err := s.ensureProviderIDColumn(ctx); err != nil {
		return err
	}
	return s.ensureActiveProviderIDUniqueness(ctx)
}

// ensureActiveProviderIDUniqueness installs the SPEC-003 v0.8.2 partial
// unique index that enforces "at most one unrevoked token per
// provider_id" at the SQL layer. This closes the TOCTOU window the
// codex security re-audit on PR #44 flagged as MAJOR-1: pre-fix the
// FR-C9.4 TOFU gate was a SELECT followed by an unrelated INSERT, and
// two concurrent tokenless connects for the same provider_id could
// both pass the SELECT before either committed. SQLite WAL serializes
// the writes but does not retroactively serialize the reads. With this
// partial unique index, the second INSERT fails with a constraint
// violation and IssueToken returns ErrActiveTokenAlreadyExists, which
// v0.8.3 (Entry 66) maps to admit-tokenless + AuthBearerlessDuplicate
// on the wire (was: TOFU rejection / close).
//
// Pinned-tier operator-issued tokens use the same path; if an operator
// runs `coordinator-cli issue-token` twice for the same provider_id
// without revoking the first, the second now fails fast — protecting
// the operator from accidentally minting parallel valid bearers.
//
// The index excludes rows with empty provider_id (legacy unfilled
// rows) and revoked rows, so the constraint matches the semantic
// invariant "active credential for this identity" exactly.
func (s *Store) ensureActiveProviderIDUniqueness(ctx context.Context) error {
	// Best-effort cleanup of pre-existing duplicates: keep the most
	// recently created unrevoked row per provider_id and revoke the
	// rest. This is a one-time migration step so the unique index can
	// be created without aborting on existing duplicate state from the
	// v0.8 pre-TOFU era.
	if _, err := s.db.ExecContext(ctx, `
UPDATE provider_tokens
   SET revoked_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE revoked_at IS NULL
   AND provider_id <> ''
   AND id NOT IN (
       SELECT MAX(id) FROM provider_tokens
        WHERE revoked_at IS NULL
          AND provider_id <> ''
        GROUP BY provider_id
   )
`); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx, `
CREATE UNIQUE INDEX IF NOT EXISTS idx_provider_tokens_one_active_per_provider
    ON provider_tokens(provider_id)
 WHERE revoked_at IS NULL AND provider_id <> ''
`)
	return err
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
		// SPEC-003 v0.8.2 FR-C9.4 — the partial unique index installed
		// by ensureActiveProviderIDUniqueness rejects a second active
		// token for the same provider_id. modernc.org/sqlite surfaces
		// this as a constraint-failure error whose Error() string
		// contains "UNIQUE constraint failed". Map to the sentinel so
		// the WS server can apply v0.8.3 admit-tokenless semantics
		// (was: close with CloseInvalidToken) instead of leaking a
		// generic DB error to the wire.
		if isActiveProviderTokenConstraintFailure(err) {
			return TokenRecord{}, "", ErrActiveTokenAlreadyExists
		}
		return TokenRecord{}, "", err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return TokenRecord{}, "", err
	}
	return TokenRecord{ID: id, TokenPrefix: prefix, ProviderID: providerID, ProviderName: providerName, CreatedAt: createdAt}, token, nil
}

// HasActiveTokenForProvider returns true when at least one unrevoked
// token row exists for `providerID`. Exposed on both the concrete Store
// AND the `internal/ws.TokenIssuer` interface (v0.8.4 composition, PR #69
// merge with PR #78) so `resolveProvisionalToken` can disambiguate
// "no row at all (mint OK)" from "active row with last_used_at IS NOT
// NULL (strict TOFU reject)" after `RevokeUnusedTokenForProvider`
// returned (false, nil).
//
// Under v0.8.4 the TOCTOU concern the v0.8.2 codex security re-audit
// (PR #44 MAJOR-1) flagged is no longer applicable: the partial unique
// index `idx_provider_tokens_one_active_per_provider` remains the atomic
// mint-or-collide invariant. This method is purely a read-only
// disambiguation step that runs AFTER the self-heal write; the
// subsequent `IssueToken` INSERT is what actually commits the
// at-most-one-bearer rule. A concurrent reconnect that races between
// our HasActive check and our INSERT is caught by the unique index
// (returns `ErrActiveTokenAlreadyExists` → race-loss admit-quarantined
// path).
//
// Also used for operator tooling — e.g. `coordinator-cli list-tokens`
// presence checks and pre-flag-flip audit scripts.
func (s *Store) HasActiveTokenForProvider(ctx context.Context, providerID string) (bool, error) {
	providerID = strings.TrimSpace(providerID)
	if providerID == "" {
		return false, fmt.Errorf("provider id is required")
	}
	var count int
	err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(1) FROM provider_tokens WHERE provider_id = ? AND revoked_at IS NULL`,
		providerID,
	).Scan(&count)
	if err != nil {
		return false, err
	}
	return count > 0, nil
}

// RevokeUnusedTokenForProvider implements SPEC-003 v0.8.3 FR-C9.4
// unused-token self-heal. Atomically revokes the (at most one) active
// row for `providerID` whose `last_used_at IS NULL`, returning
// (true, nil) if a row was revoked and (false, nil) if no row matched.
//
// "At most one" is guaranteed by the partial unique index
// `idx_provider_tokens_one_active_per_provider` installed in v0.8.2.
// The UPDATE is a single statement, and SQLite WAL serializes
// writers — a concurrent reconnect either revokes the row first
// (we see RowsAffected=0) or arrives after we have revoked it
// (also RowsAffected=0 on its side). The unique index is the
// second-line defense for any IssueToken that races after revoke.
//
// Used by ws.resolveProvisionalToken to convert a deploy-gap /
// first-mint-not-yet-used lockout into an in-band self-heal. A
// (true, nil) return means the caller should proceed to IssueToken —
// the provider gets a fresh row, the operator sees an
// `fr_c9_4_self_heal` log line, no human intervention required.
// A (false, nil) return means EITHER no active row at all OR the
// active row has `last_used_at IS NOT NULL` (a used token, the
// codex MAJOR-1 vector). The caller MUST then call
// HasActiveTokenForProvider to disambiguate; if a row remains it is
// a used-token-tokenless-reconnect and the caller MUST follow the
// v0.8.1 strict-reject path.
//
// On DB error the caller MUST fail closed (reject the connect).
func (s *Store) RevokeUnusedTokenForProvider(ctx context.Context, providerID string) (bool, error) {
	providerID = strings.TrimSpace(providerID)
	if providerID == "" {
		return false, fmt.Errorf("provider id is required")
	}
	res, err := s.db.ExecContext(ctx,
		`UPDATE provider_tokens
		    SET revoked_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		  WHERE provider_id = ?
		    AND revoked_at IS NULL
		    AND last_used_at IS NULL`,
		providerID,
	)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	return n > 0, nil
}

// PruneUnusedTokens deletes tokens whose `last_used_at` is NULL and
// whose `created_at` is older than the supplied cutoff time. Returns the
// number of rows pruned. Used by `coordinator-cli prune-tokens` to bound
// the operational cost of FR-C9.4 multi-mint-then-self-heal — a token
// that has never been used to authenticate and is older than the
// settling window is safe to drop.
//
// The cutoff is compared as ISO-8601 strings; tokens.go nowString
// formats `created_at` in the same `2006-01-02T15:04:05Z` shape, and
// lexicographic comparison is monotonic within that format.
func (s *Store) PruneUnusedTokens(ctx context.Context, olderThan time.Time) (int64, error) {
	cutoff := olderThan.UTC().Format("2006-01-02T15:04:05Z")
	res, err := s.db.ExecContext(ctx,
		`DELETE FROM provider_tokens WHERE last_used_at IS NULL AND revoked_at IS NULL AND created_at < ?`,
		cutoff,
	)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
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

// ValidateAndMarkTokenUsed atomically validates a bearer and stamps its
// `last_used_at`. SPEC-003 v0.8.4 (fix-pass-5) — closes the TOCTOU
// window between separate `ValidateToken` and `MarkTokenUsed` calls
// that the codex code-review (PR #69 fix-pass-4) flagged: between the
// two, a concurrent tokenless connect could see `last_used_at IS NULL`
// and self-heal-revoke the legitimate row, then mint a fresh bearer
// for the attacker. This atomic UPDATE-RETURNING closes the window by
// stamping `last_used_at` in the same statement that the validation
// reads from. SQLite WAL serializes writers; once this call returns
// (providerID, true, nil), the row's `last_used_at` is set and any
// subsequent `RevokeUnusedTokenForProvider` skips this row.
//
// Callers SHOULD use this instead of `ValidateToken` for any WS-connect
// validation; legacy `ValidateToken` is retained for read-only paths
// that don't need to record use (operator tooling, status checks).
func (s *Store) ValidateAndMarkTokenUsed(ctx context.Context, token string) (string, bool, error) {
	if token == "" {
		return "", false, nil
	}
	hash := tokenHash(token)
	var providerID string
	err := s.db.QueryRowContext(ctx,
		`UPDATE provider_tokens
		    SET last_used_at = ?
		  WHERE token_hash = ? AND revoked_at IS NULL AND provider_id <> ''
		  RETURNING provider_id`,
		nowString(), hash,
	).Scan(&providerID)
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

// isActiveProviderTokenConstraintFailure detects the SQLite unique-
// constraint failure for `idx_provider_tokens_one_active_per_provider`.
// modernc.org/sqlite returns the constraint failure via the error
// string ("UNIQUE constraint failed: provider_tokens.provider_id" for
// indexed columns, but the partial index name appears in the SQLite
// error message instead of column names for partial-index conflicts).
// Match both forms defensively so a future driver-version bump doesn't
// silently downgrade the TOFU gate to a generic 500.
func isActiveProviderTokenConstraintFailure(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "constraint failed") &&
		(strings.Contains(msg, "idx_provider_tokens_one_active_per_provider") ||
			strings.Contains(msg, "provider_tokens.provider_id"))
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
