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

	"github.com/augstar/macprovider-coordinator/internal/config"
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
var ErrOwnershipExists = errors.New("provider ownership already exists")
var ErrPairOTInvalid = errors.New("pair_ot invalid")
var ErrPairOTAlreadyOwned = errors.New("pair_ot provider already owned by another account")
var ErrSessionInvalid = errors.New("mp_session invalid")
var ErrPendingPairOTMissing = errors.New("pending pair_ot missing")
var ErrAppTrackExistingTokenNoProof = errors.New("existing active token requires current bearer proof")
var ErrAppTrackReissueCooldown = errors.New("app-track provider token reissue cooldown active")

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

type PairOTMint struct {
	PairOT    string
	ClaimURL  string
	ExpiresAt time.Time
}

type AdmissionPairMint struct {
	TokenRecord   TokenRecord
	ProviderToken string
	PairOT        string
	ExpiresAt     time.Time
	Paired        bool
}

type OAuthState struct {
	ReturnTo      string
	PendingPairOT sql.NullString
	ExpiresAt     string
}

type MPSession struct {
	ID                  string
	GitHubUserID        int64
	GitHubLogin         string
	LastSeenAt          time.Time
	LastSetCookieAt     time.Time
	PendingPairOT       sql.NullString
	PendingPairOTExpiry sql.NullString
}

type OwnedProvider struct {
	ProviderID string `json:"provider_id"`
	ClaimedAt  string `json:"claimed_at"`
	LastSeenAt string `json:"last_seen_at"`
}

type BindResult struct {
	ProviderID  string
	GitHubLogin string
	ClaimedAt   string
}

type PairOTMintLogRecord struct {
	ID         int64
	ProviderID string
	SourceIP   sql.NullString
	UserAgent  sql.NullString
	Outcome    int
	TS         string
}

type PairOTRefreshResult struct {
	Mint        PairOTMint
	RetryAfter  int
	RateLimited bool
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

// InternalBearerKind identifies WHICH credential class matched in
// GatewayInternalBearerMatches. The audit-log call sites use this to
// emit `event=internal_bearer_accepted key=<kind>` so the operator can
// watch the M3-2 cutover for gateway-origin calls still landing under
// operator_key. The zero value (BearerKindNone) means no match.
type InternalBearerKind int

const (
	BearerKindNone InternalBearerKind = iota
	BearerKindServiceToken
	BearerKindOperatorKey
)

// String matches the JSON shape the operator filters on in journald.
func (k InternalBearerKind) String() string {
	switch k {
	case BearerKindServiceToken:
		return "service_token"
	case BearerKindOperatorKey:
		return "operator_key"
	default:
		return ""
	}
}

// OperatorOnlyBearerMatches returns true when the request carries a
// Bearer token that matches operatorKey. This is the credential class
// for HUMAN-ADMIN endpoints (`/admin/blacklist`, `/admin/promote`,
// `/admin/reject`, `/admin/ledger/*`, `/admin/explorer/*`, `/poolz`).
// It deliberately does NOT accept gateway_service_token: the codex
// security audit on PR #73 flagged that admin endpoints accepting the
// service-token would silently grant human-admin power to the gateway
// once the operator rotated the legacy operator_key.
//
// Empty operatorKey means DENY (M1-5 / SECU-5 preserved).
func OperatorOnlyBearerMatches(headers http.Header, operatorKey string) bool {
	return BearerTokenMatchesHeader(headers, operatorKey)
}

// GatewayInternalBearerMatches returns the matched credential kind when
// the request's Bearer token matches EITHER the gateway service token
// OR the operator key. This is the credential class for
// SERVICE-TO-SERVICE endpoints (`/internal/routing`, `/internal/sticky`)
// that the gateway calls upstream.
//
// BOTH candidates are evaluated BEFORE branching to close the
// short-circuit timing oracle the codex security audit on PR #73
// flagged as MEDIUM: an attacker could otherwise distinguish "service
// token matched" vs "operator key matched" by measuring response
// timing. Each candidate is constant-time compared via
// BearerTokenMatchesHeader and only counted when non-empty so an empty
// gateway_service_token can't widen the auth surface.
//
// Returns BearerKindServiceToken when service_token matches (preferred),
// BearerKindOperatorKey when operator_key matches (legacy fallback),
// BearerKindNone otherwise. service_token takes precedence so the
// audit-log line reports the credential the gateway is supposed to be
// using post-cutover.
func GatewayInternalBearerMatches(headers http.Header, operatorKey, serviceToken string) InternalBearerKind {
	serviceMatch := serviceToken != "" && BearerTokenMatchesHeader(headers, serviceToken)
	operatorMatch := operatorKey != "" && BearerTokenMatchesHeader(headers, operatorKey)
	switch {
	case serviceMatch:
		return BearerKindServiceToken
	case operatorMatch:
		return BearerKindOperatorKey
	default:
		return BearerKindNone
	}
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
	// QW-5 / M2-3 / ARCH-3: cap the pool at a single connection to match
	// the gateway pattern (phase5-gateway/internal/storage/sqlite/store.go).
	// SQLite serializes writers regardless; pinning the pool at 1 makes
	// BEGIN IMMEDIATE contention explicit and eliminates a class of
	// SQLITE_BUSY tail-latency on the coordinator money path.
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
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
	if err := s.ensureActiveProviderIDUniqueness(ctx); err != nil {
		return err
	}
	return s.ensureGitHubAuthSchema(ctx)
}

func (s *Store) ensureGitHubAuthSchema(ctx context.Context) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS github_identities (
			github_user_id INTEGER PRIMARY KEY,
			github_login TEXT NOT NULL,
			created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
			last_seen_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		)`,
		`CREATE TABLE IF NOT EXISTS provider_ownership (
			provider_id TEXT PRIMARY KEY,
			github_user_id INTEGER NOT NULL REFERENCES github_identities(github_user_id),
			claimed_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		)`,
		`CREATE INDEX IF NOT EXISTS idx_ownership_github ON provider_ownership(github_user_id)`,
		`CREATE TABLE IF NOT EXISTS pair_ots (
			id TEXT PRIMARY KEY,
			provider_id TEXT NOT NULL,
			expires_at TEXT NOT NULL,
			used_at TEXT,
			created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		)`,
		`CREATE INDEX IF NOT EXISTS idx_pair_ots_provider ON pair_ots(provider_id)`,
		`CREATE TABLE IF NOT EXISTS mp_sessions (
			id TEXT PRIMARY KEY,
			github_user_id INTEGER NOT NULL REFERENCES github_identities(github_user_id),
			created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
			last_seen_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
			last_setcookie_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
			pending_pair_ot TEXT,
			pending_pair_ot_expires_at TEXT
		)`,
		`CREATE INDEX IF NOT EXISTS idx_sessions_user ON mp_sessions(github_user_id)`,
		`CREATE TABLE IF NOT EXISTS oauth_states (
			state TEXT PRIMARY KEY,
			return_to TEXT NOT NULL,
			pending_pair_ot TEXT,
			expires_at TEXT NOT NULL,
			created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		)`,
		`CREATE TABLE IF NOT EXISTS pair_ot_mint_log (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			provider_id TEXT NOT NULL,
			source_ip TEXT,
			user_agent TEXT,
			outcome INTEGER NOT NULL,
			ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		)`,
		`CREATE INDEX IF NOT EXISTS idx_mint_log_provider_ts ON pair_ot_mint_log(provider_id, ts)`,
		`CREATE TABLE IF NOT EXISTS apptrack_register_reissues (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			provider_id TEXT NOT NULL,
			ts TEXT NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_apptrack_register_reissues_provider_ts ON apptrack_register_reissues(provider_id, ts)`,
	}
	for _, stmt := range stmts {
		if _, err := tx.ExecContext(ctx, stmt); err != nil {
			return err
		}
	}
	return tx.Commit()
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
	// Issue #274 R1 CODE LOW-1: validate the RAW provider_id before any
	// normalization so admission paths apply the same gate semantics as WS
	// paths (which validate as-received). Leading/trailing whitespace is
	// already disallowed by providerIDPattern, so this also rejects
	// `" m4-anon "`-style inputs symmetrically.
	if err := config.ValidateProviderID(providerID); err != nil {
		return TokenRecord{}, "", err
	}
	providerName = strings.TrimSpace(providerName)
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

func (s *Store) MintProviderTokenAppTrack(ctx context.Context, providerID string, currentBearer *string) (string, error) {
	if err := config.ValidateProviderID(providerID); err != nil {
		return "", err
	}
	conn, err := s.db.Conn(ctx)
	if err != nil {
		return "", err
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		return "", err
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()

	nowText := nowString()
	var active struct {
		ID        int64
		TokenHash string
	}
	err = conn.QueryRowContext(ctx, `
SELECT id, token_hash
  FROM provider_tokens
 WHERE provider_id = ? AND revoked_at IS NULL
 LIMIT 1`, providerID).Scan(&active.ID, &active.TokenHash)
	if err != nil && err != sql.ErrNoRows {
		return "", err
	}

	requiresProof := err == nil
	if requiresProof {
		if currentBearer == nil || strings.TrimSpace(*currentBearer) == "" || tokenHash(strings.TrimSpace(*currentBearer)) != active.TokenHash {
			return "", ErrAppTrackExistingTokenNoProof
		}
		var recent int
		if err := conn.QueryRowContext(ctx, `
SELECT COUNT(1)
  FROM apptrack_register_reissues
 WHERE provider_id = ? AND ts >= ?`,
			providerID, timeText(time.Now().UTC().Add(-5*time.Minute)),
		).Scan(&recent); err != nil {
			return "", err
		}
		if recent > 0 {
			return "", ErrAppTrackReissueCooldown
		}
	}

	if err == nil {
		if _, err := conn.ExecContext(ctx, `
UPDATE provider_tokens
   SET revoked_at = ?
 WHERE id = ? AND revoked_at IS NULL`, nowText, active.ID); err != nil {
			return "", err
		}
	}

	token, err := randomHex(32)
	if err != nil {
		return "", err
	}
	prefix := token[:tokenDisplayPrefixLength]
	if _, err := conn.ExecContext(ctx, `
INSERT INTO provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at)
VALUES (?, ?, ?, ?, ?)`, tokenHash(token), prefix, providerID, "malibu-app", nowText); err != nil {
		if isActiveProviderTokenConstraintFailure(err) {
			return "", ErrActiveTokenAlreadyExists
		}
		return "", err
	}
	if requiresProof {
		if _, err := conn.ExecContext(ctx, `
INSERT INTO apptrack_register_reissues (provider_id, ts)
VALUES (?, ?)`, providerID, nowText); err != nil {
			return "", err
		}
	}
	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		return "", err
	}
	committed = true
	return token, nil
}

// HasActiveTokenForProvider returns true when at least one unrevoked token row
// exists for providerID. The Wave 2 custody gate treats every active row as
// proof-required; last_used_at is not a recovery signal.
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

func (s *Store) ListActiveProviderIDsCreatedBefore(ctx context.Context, cutoff time.Time) ([]string, error) {
	if s == nil || s.db == nil {
		return nil, errors.New("auth store is nil")
	}
	rows, err := s.db.QueryContext(ctx, `
SELECT DISTINCT provider_id
  FROM provider_tokens
 WHERE revoked_at IS NULL
   AND provider_id <> ''
   AND created_at <= ?
 ORDER BY provider_id`, timeText(cutoff.UTC()))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var providerID string
		if err := rows.Scan(&providerID); err != nil {
			return nil, err
		}
		out = append(out, providerID)
	}
	return out, rows.Err()
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

func (s *Store) DB() *sql.DB {
	return s.db
}

func (s *Store) UpsertGitHubIdentity(ctx context.Context, githubUserID int64, login string, now time.Time) error {
	login = strings.TrimSpace(login)
	if githubUserID <= 0 || login == "" {
		return fmt.Errorf("github identity requires id and login")
	}
	nowText := timeText(now)
	_, err := s.db.ExecContext(ctx, `
INSERT INTO github_identities (github_user_id, github_login, created_at, last_seen_at)
VALUES (?, ?, ?, ?)
ON CONFLICT(github_user_id) DO UPDATE SET github_login = excluded.github_login, last_seen_at = excluded.last_seen_at`,
		githubUserID, login, nowText, nowText)
	return err
}

func (s *Store) CreateOAuthState(ctx context.Context, state, returnTo string, pendingPairOT *string, now time.Time) error {
	if state == "" || returnTo == "" {
		return fmt.Errorf("oauth state and return_to are required")
	}
	var pending any
	if pendingPairOT != nil {
		pending = *pendingPairOT
	}
	_, err := s.db.ExecContext(ctx, `
INSERT INTO oauth_states (state, return_to, pending_pair_ot, expires_at, created_at)
VALUES (?, ?, ?, ?, ?)`,
		state, returnTo, pending, timeText(now.Add(10*time.Minute)), timeText(now))
	return err
}

func (s *Store) ConsumeOAuthState(ctx context.Context, state string, now time.Time) (OAuthState, bool, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return OAuthState{}, false, err
	}
	defer tx.Rollback()
	var out OAuthState
	err = tx.QueryRowContext(ctx, `
DELETE FROM oauth_states
 WHERE state = ? AND expires_at > ?
RETURNING return_to, pending_pair_ot, expires_at`,
		state, timeText(now)).Scan(&out.ReturnTo, &out.PendingPairOT, &out.ExpiresAt)
	if err == sql.ErrNoRows {
		return OAuthState{}, false, nil
	}
	if err != nil {
		return OAuthState{}, false, err
	}
	if err := tx.Commit(); err != nil {
		return OAuthState{}, false, err
	}
	return out, true, nil
}

func (s *Store) CreateMPSession(ctx context.Context, githubUserID int64, pendingPairOT sql.NullString, now time.Time) (string, error) {
	sessionID, err := randomHex(32)
	if err != nil {
		return "", err
	}
	var pending any
	var pendingExpires any
	if pendingPairOT.Valid && pendingPairOT.String != "" {
		pending = pendingPairOT.String
		pendingExpires = timeText(now.Add(10 * time.Minute))
	}
	nowText := timeText(now)
	_, err = s.db.ExecContext(ctx, `
INSERT INTO mp_sessions (id, github_user_id, created_at, last_seen_at, last_setcookie_at, pending_pair_ot, pending_pair_ot_expires_at)
VALUES (?, ?, ?, ?, ?, ?, ?)`,
		sessionID, githubUserID, nowText, nowText, nowText, pending, pendingExpires)
	return sessionID, err
}

func (s *Store) LoadMPSession(ctx context.Context, id string, now time.Time) (MPSession, bool, error) {
	var sess MPSession
	var lastSeen, lastSet string
	err := s.db.QueryRowContext(ctx, `
SELECT s.id, s.github_user_id, g.github_login, s.last_seen_at, s.last_setcookie_at, s.pending_pair_ot, s.pending_pair_ot_expires_at
  FROM mp_sessions s
  JOIN github_identities g ON g.github_user_id = s.github_user_id
 WHERE s.id = ? AND s.last_seen_at >= ?`,
		id, timeText(now.AddDate(0, 0, -30))).Scan(&sess.ID, &sess.GitHubUserID, &sess.GitHubLogin, &lastSeen, &lastSet, &sess.PendingPairOT, &sess.PendingPairOTExpiry)
	if err == sql.ErrNoRows {
		return MPSession{}, false, nil
	}
	if err != nil {
		return MPSession{}, false, err
	}
	sess.LastSeenAt = parseTimeOrZero(lastSeen)
	sess.LastSetCookieAt = parseTimeOrZero(lastSet)
	return sess, true, nil
}

func (s *Store) TouchMPSession(ctx context.Context, id string, now time.Time, reissuedCookie bool) error {
	if reissuedCookie {
		_, err := s.db.ExecContext(ctx, `UPDATE mp_sessions SET last_seen_at = ?, last_setcookie_at = ? WHERE id = ?`, timeText(now), timeText(now), id)
		return err
	}
	_, err := s.db.ExecContext(ctx, `UPDATE mp_sessions SET last_seen_at = ? WHERE id = ?`, timeText(now), id)
	return err
}

func (s *Store) DeleteMPSession(ctx context.Context, id string) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM mp_sessions WHERE id = ?`, id)
	return err
}

func (s *Store) ListOwnedProviders(ctx context.Context, githubUserID int64) ([]OwnedProvider, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT provider_id, claimed_at FROM provider_ownership WHERE github_user_id = ? ORDER BY claimed_at, provider_id`, githubUserID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []OwnedProvider
	for rows.Next() {
		var p OwnedProvider
		if err := rows.Scan(&p.ProviderID, &p.ClaimedAt); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *Store) HasOwnership(ctx context.Context, providerID string) (bool, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(1) FROM provider_ownership WHERE provider_id = ?`, providerID).Scan(&n)
	return n > 0, err
}

func (s *Store) MintAdmissionTokenAndPairOT(ctx context.Context, providerID, providerName string, now time.Time) (AdmissionPairMint, error) {
	// Issue #274 R1 CODE LOW-1: validate the RAW provider_id before any
	// normalization so admission paths apply the same gate semantics as WS
	// paths.
	if err := config.ValidateProviderID(providerID); err != nil {
		return AdmissionPairMint{}, err
	}
	providerName = strings.TrimSpace(providerName)
	if providerName == "" {
		return AdmissionPairMint{}, fmt.Errorf("provider id and name are required")
	}
	providerToken, err := randomHex(32)
	if err != nil {
		return AdmissionPairMint{}, err
	}
	pairOT, err := randomHex(32)
	if err != nil {
		return AdmissionPairMint{}, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return AdmissionPairMint{}, err
	}
	defer tx.Rollback()
	hash := tokenHash(providerToken)
	prefix := providerToken[:tokenDisplayPrefixLength]
	nowText := timeText(now)
	res, err := tx.ExecContext(ctx, `INSERT INTO provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at) VALUES (?, ?, ?, ?, ?)`, hash, prefix, providerID, providerName, nowText)
	if err != nil {
		if isActiveProviderTokenConstraintFailure(err) {
			return AdmissionPairMint{}, ErrActiveTokenAlreadyExists
		}
		return AdmissionPairMint{}, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return AdmissionPairMint{}, err
	}
	var owned int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(1) FROM provider_ownership WHERE provider_id = ?`, providerID).Scan(&owned); err != nil {
		return AdmissionPairMint{}, err
	}
	out := AdmissionPairMint{
		TokenRecord:   TokenRecord{ID: id, TokenPrefix: prefix, ProviderID: providerID, ProviderName: providerName, CreatedAt: nowText},
		ProviderToken: providerToken,
	}
	if owned == 0 {
		out.PairOT = pairOT
		out.ExpiresAt = now.Add(10 * time.Minute).UTC()
		out.Paired = true
		if _, err := tx.ExecContext(ctx, `INSERT INTO pair_ots (id, provider_id, expires_at, created_at) VALUES (?, ?, ?, ?)`, pairOT, providerID, timeText(out.ExpiresAt), nowText); err != nil {
			return AdmissionPairMint{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return AdmissionPairMint{}, err
	}
	return out, nil
}

func (s *Store) MintPairOT(ctx context.Context, providerID string, now time.Time) (PairOTMint, error) {
	providerID = strings.TrimSpace(providerID)
	if providerID == "" {
		return PairOTMint{}, fmt.Errorf("provider id is required")
	}
	pairOT, err := randomHex(32)
	if err != nil {
		return PairOTMint{}, err
	}
	expires := now.Add(10 * time.Minute).UTC()
	_, err = s.db.ExecContext(ctx, `INSERT INTO pair_ots (id, provider_id, expires_at, created_at) VALUES (?, ?, ?, ?)`, pairOT, providerID, timeText(expires), timeText(now))
	if err != nil {
		return PairOTMint{}, err
	}
	return PairOTMint{PairOT: pairOT, ExpiresAt: expires}, nil
}

func (s *Store) CountRecentSuccessfulPairOTRefreshMints(ctx context.Context, providerID string, since time.Time) (int, sql.NullString, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT ts FROM pair_ot_mint_log WHERE provider_id = ? AND outcome = 200 AND ts >= ? ORDER BY ts ASC`, providerID, timeText(since))
	if err != nil {
		return 0, sql.NullString{}, err
	}
	defer rows.Close()
	count := 0
	var oldest sql.NullString
	for rows.Next() {
		var ts string
		if err := rows.Scan(&ts); err != nil {
			return 0, sql.NullString{}, err
		}
		if count == 0 {
			oldest = sql.NullString{String: ts, Valid: true}
		}
		count++
	}
	return count, oldest, rows.Err()
}

func (s *Store) MintPairOTRefresh(ctx context.Context, providerID, sourceIP, userAgent string, now time.Time) (PairOTRefreshResult, error) {
	providerID = strings.TrimSpace(providerID)
	if providerID == "" {
		return PairOTRefreshResult{}, fmt.Errorf("provider id is required")
	}
	conn, err := s.db.Conn(ctx)
	if err != nil {
		return PairOTRefreshResult{}, err
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		return PairOTRefreshResult{}, err
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()

	rows, err := conn.QueryContext(ctx, `SELECT ts FROM pair_ot_mint_log WHERE provider_id = ? AND outcome = 200 AND ts >= ? ORDER BY ts ASC`, providerID, timeText(now.Add(-time.Hour)))
	if err != nil {
		return PairOTRefreshResult{}, err
	}
	count := 0
	var oldest sql.NullString
	for rows.Next() {
		var ts string
		if err := rows.Scan(&ts); err != nil {
			rows.Close()
			return PairOTRefreshResult{}, err
		}
		if count == 0 {
			oldest = sql.NullString{String: ts, Valid: true}
		}
		count++
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return PairOTRefreshResult{}, err
	}
	rows.Close()

	if count >= 5 {
		if _, err := conn.ExecContext(ctx, `INSERT INTO pair_ot_mint_log (provider_id, source_ip, user_agent, outcome, ts) VALUES (?, ?, ?, ?, ?)`,
			providerID, nullString(sourceIP), nullString(userAgent), http.StatusTooManyRequests, timeText(now)); err != nil {
			return PairOTRefreshResult{}, err
		}
		if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
			return PairOTRefreshResult{}, err
		}
		committed = true
		return PairOTRefreshResult{RetryAfter: retryAfterSeconds(oldest, now), RateLimited: true}, nil
	}

	pairOT, err := randomHex(32)
	if err != nil {
		return PairOTRefreshResult{}, err
	}
	expires := now.Add(10 * time.Minute).UTC()
	if _, err := conn.ExecContext(ctx, `INSERT INTO pair_ots (id, provider_id, expires_at, created_at) VALUES (?, ?, ?, ?)`, pairOT, providerID, timeText(expires), timeText(now)); err != nil {
		return PairOTRefreshResult{}, err
	}
	if _, err := conn.ExecContext(ctx, `INSERT INTO pair_ot_mint_log (provider_id, source_ip, user_agent, outcome, ts) VALUES (?, ?, ?, ?, ?)`,
		providerID, nullString(sourceIP), nullString(userAgent), http.StatusOK, timeText(now)); err != nil {
		return PairOTRefreshResult{}, err
	}
	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		return PairOTRefreshResult{}, err
	}
	committed = true
	return PairOTRefreshResult{Mint: PairOTMint{PairOT: pairOT, ExpiresAt: expires}}, nil
}

func (s *Store) ConsumePendingPairOT(ctx context.Context, sessionID string, now time.Time) (string, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	var pairOT string
	nowText := timeText(now)
	err = tx.QueryRowContext(ctx, `
SELECT pending_pair_ot
  FROM mp_sessions
 WHERE id = ?
   AND pending_pair_ot IS NOT NULL
   AND pending_pair_ot_expires_at > ?`, sessionID, nowText).Scan(&pairOT)
	if err == sql.ErrNoRows {
		return "", ErrPendingPairOTMissing
	}
	if err != nil {
		return "", err
	}
	res, err := tx.ExecContext(ctx, `
UPDATE mp_sessions
   SET pending_pair_ot = NULL,
       pending_pair_ot_expires_at = NULL
 WHERE id = ?
   AND pending_pair_ot = ?
   AND pending_pair_ot_expires_at > ?`, sessionID, pairOT, nowText)
	if err != nil {
		return "", err
	}
	affected, err := res.RowsAffected()
	if err != nil {
		return "", err
	}
	if affected == 0 {
		return "", ErrPendingPairOTMissing
	}
	if err := tx.Commit(); err != nil {
		return "", err
	}
	return pairOT, nil
}

func (s *Store) LogPairOTMint(ctx context.Context, providerID, sourceIP, userAgent string, outcome int, now time.Time) error {
	if providerID == "" {
		providerID = "unknown"
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO pair_ot_mint_log (provider_id, source_ip, user_agent, outcome, ts) VALUES (?, ?, ?, ?, ?)`,
		providerID, nullString(sourceIP), nullString(userAgent), outcome, timeText(now))
	return err
}

func (s *Store) ListPairOTMintLog(ctx context.Context, providerID string) ([]PairOTMintLogRecord, error) {
	query := `SELECT id, provider_id, source_ip, user_agent, outcome, ts FROM pair_ot_mint_log`
	args := []any{}
	if strings.TrimSpace(providerID) != "" {
		query += ` WHERE provider_id = ?`
		args = append(args, strings.TrimSpace(providerID))
	}
	query += ` ORDER BY ts DESC, id DESC`
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PairOTMintLogRecord
	for rows.Next() {
		var r PairOTMintLogRecord
		if err := rows.Scan(&r.ID, &r.ProviderID, &r.SourceIP, &r.UserAgent, &r.Outcome, &r.TS); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *Store) BindPairOT(ctx context.Context, sessionID, pairOT string, now time.Time, enqueue func(BindResult) error) (BindResult, error) {
	pairOT = strings.TrimSpace(pairOT)
	if pairOT == "" {
		return BindResult{}, ErrPendingPairOTMissing
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return BindResult{}, err
	}
	defer tx.Rollback()
	nowText := timeText(now)
	var providerID string
	err = tx.QueryRowContext(ctx, `
UPDATE pair_ots
   SET used_at = ?
 WHERE id = ?
   AND used_at IS NULL
   AND expires_at > ?
RETURNING provider_id`, nowText, pairOT, nowText).Scan(&providerID)
	if err == sql.ErrNoRows {
		return BindResult{}, ErrPairOTInvalid
	}
	if err != nil {
		return BindResult{}, err
	}
	var githubUserID int64
	var githubLogin string
	err = tx.QueryRowContext(ctx, `
SELECT s.github_user_id, g.github_login
  FROM mp_sessions s
  JOIN github_identities g ON g.github_user_id = s.github_user_id
 WHERE s.id = ? AND s.last_seen_at >= ?`,
		sessionID, timeText(now.AddDate(0, 0, -30))).Scan(&githubUserID, &githubLogin)
	if err == sql.ErrNoRows {
		return BindResult{}, ErrSessionInvalid
	}
	if err != nil {
		return BindResult{}, err
	}
	claimedAt := nowText
	err = tx.QueryRowContext(ctx, `
INSERT INTO provider_ownership (provider_id, github_user_id, claimed_at)
VALUES (?, ?, ?)
ON CONFLICT(provider_id) DO NOTHING
RETURNING claimed_at`, providerID, githubUserID, claimedAt).Scan(&claimedAt)
	if err == sql.ErrNoRows {
		var existingUserID int64
		err = tx.QueryRowContext(ctx, `SELECT github_user_id, claimed_at FROM provider_ownership WHERE provider_id = ?`, providerID).Scan(&existingUserID, &claimedAt)
		if err != nil {
			return BindResult{}, err
		}
		if existingUserID != githubUserID {
			if commitErr := tx.Commit(); commitErr != nil {
				return BindResult{}, commitErr
			}
			return BindResult{}, ErrPairOTAlreadyOwned
		}
	} else if err != nil {
		return BindResult{}, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE mp_sessions SET last_seen_at = ? WHERE id = ?`, nowText, sessionID); err != nil {
		return BindResult{}, err
	}
	result := BindResult{ProviderID: providerID, GitHubLogin: githubLogin, ClaimedAt: claimedAt}
	if enqueue != nil {
		if err := enqueue(result); err != nil {
			return BindResult{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return BindResult{}, err
	}
	return result, nil
}

func (s *Store) PruneGitHubAuthState(ctx context.Context, now time.Time) error {
	_, err := s.db.ExecContext(ctx, `
DELETE FROM pair_ots WHERE expires_at < ?;
DELETE FROM oauth_states WHERE expires_at < ?;
UPDATE mp_sessions
   SET pending_pair_ot = NULL,
       pending_pair_ot_expires_at = NULL
 WHERE pending_pair_ot IS NOT NULL
   AND pending_pair_ot_expires_at < ?;
DELETE FROM mp_sessions WHERE last_seen_at < ?;
DELETE FROM pair_ot_mint_log WHERE ts < ?;`,
		timeText(now.Add(-24*time.Hour)),
		timeText(now.Add(-24*time.Hour)),
		timeText(now),
		timeText(now.AddDate(0, 0, -30)),
		timeText(now.AddDate(0, 0, -90)),
	)
	return err
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

func randomHex(n int) (string, error) {
	raw := make([]byte, n)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw), nil
}

func nowString() string {
	return time.Now().UTC().Format("2006-01-02T15:04:05Z")
}

func timeText(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05Z")
}

func parseTimeOrZero(s string) time.Time {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}
	}
	return t.UTC()
}

func nullString(v string) sql.NullString {
	v = strings.TrimSpace(v)
	return sql.NullString{String: v, Valid: v != ""}
}

func retryAfterSeconds(oldest sql.NullString, now time.Time) int {
	if !oldest.Valid {
		return 3600
	}
	oldestAt, err := time.Parse(time.RFC3339, oldest.String)
	if err != nil {
		return 3600
	}
	retryAfter := int(oldestAt.Add(time.Hour).Sub(now).Seconds())
	if retryAfter < 1 {
		return 1
	}
	return retryAfter
}
