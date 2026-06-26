package auth

import (
	"bytes"
	"context"
	"crypto/ed25519"
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
var ErrOAuthStateRateLimited = errors.New("oauth state rate limited")
var ErrBootstrapIdentityMismatch = errors.New("bootstrap receipt identity mismatch")
var ErrBootstrapIdentityExists = errors.New("provider_id is bound to bootstrap identity custody")
var ErrBootstrapTokenUsed = errors.New("bootstrap token was already used")
var ErrBootstrapTokenExpired = errors.New("bootstrap token expired")
var ErrBootstrapRateLimited = errors.New("bootstrap mint rate limited")
var ErrBootstrapOutstandingLimit = errors.New("bootstrap outstanding token limit reached")
var ErrAdmissionIdentityMismatch = errors.New("admission identity public key mismatch")
var ErrAdmissionIdentityBearerMismatch = errors.New("admission identity bearer does not own provider_id")
var ErrAdmissionIdentityRotationMismatch = errors.New("admission identity rotation compare-and-swap mismatch")
var ErrAdmissionIdentityRecoveryMismatch = errors.New("admission identity recovery authorization or compare-and-swap mismatch")
var ErrAdmissionIdentityRecoveryNotFound = errors.New("pending recovery not found")
var ErrAdmissionIdentityRecoveryCommitted = errors.New("pending recovery already committed")
var ErrAdmissionIdentityRecoveryDualControl = errors.New("dual_control_required")

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

type BootstrapIdentityRecord struct {
	ProviderID        string
	CreatedAt         string
	ExpiresAt         sql.NullString
	ConfirmedAt       sql.NullString
	OperatorRevokedAt sql.NullString
}

// AdmissionIdentityState is the coordinator-authoritative key state used for
// provider admission. PreviousPublicKey is returned only while its bounded
// rollback window remains active.
type AdmissionIdentityState struct {
	CurrentPublicKey   []byte
	Generation         int
	PreviousPublicKey  []byte
	PreviousValidUntil *time.Time
}

const AdmissionIdentityPreviousKeyGrace = 7 * 24 * time.Hour

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

type BootstrapMintRequest struct {
	ProviderID          string
	ProviderName        string
	SourceIP            string
	ReceiptPubkey       []byte
	Now                 time.Time
	TTL                 time.Duration
	PerIPLimitPerHour   int
	PerProviderPerHour  int
	GlobalLimitPerHour  int
	UnconfirmedIDMax    int
	OutstandingTokenMax int
	IdentityRetention   time.Duration
	ReferralCode        string
	ReferralPolicy      ReferralPolicy
}

type BootstrapMint struct {
	TokenRecord   TokenRecord
	ProviderToken string
	Replaced      bool
}

type OAuthState struct {
	ReturnTo      string
	PendingPairOT sql.NullString
	ExpiresAt     string
	OriginHash    sql.NullString
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
// GatewayInternalBearerMatches. After the M3-2 legacy-fallback removal
// (PR #87 item 3, post-2026-07-12 cutover gate) the only non-None value
// is BearerKindServiceToken; the previous BearerKindOperatorKey existed
// solely to label the M3-2 fallback path on the audit-log line so the
// operator could watch the cutover, and the path is now gone. The enum
// stays so call sites that emit `event=internal_bearer_accepted key=<kind>`
// keep the established log shape.
type InternalBearerKind int

const (
	BearerKindNone InternalBearerKind = iota
	BearerKindServiceToken
)

// String matches the JSON shape the operator filters on in journald.
func (k InternalBearerKind) String() string {
	if k == BearerKindServiceToken {
		return "service_token"
	}
	return ""
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

// GatewayInternalBearerMatches returns BearerKindServiceToken when the
// request's Bearer token matches the gateway_service_token, else
// BearerKindNone. This is the credential class for SERVICE-TO-SERVICE
// endpoints (`/internal/routing`, `/internal/sticky`) that the gateway
// calls upstream.
//
// History: PR #73 (M3-2 / SECU-4) introduced a dual-credential bridge
// here that also accepted the legacy operator_key as a backward-compat
// fallback so the cutover could roll out without an atomic flip. The
// fallback was removed by PR #87 item 3 once the 30-day clean-cutover
// gate fired (2026-07-12, zero gateway-origin operator_key admits on
// /internal/* throughout the window). Empty serviceToken still means
// DENY (M1-5 / SECU-5 preserved).
func GatewayInternalBearerMatches(headers http.Header, serviceToken string) InternalBearerKind {
	if serviceToken != "" && BearerTokenMatchesHeader(headers, serviceToken) {
		return BearerKindServiceToken
	}
	return BearerKindNone
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
			origin_hash TEXT,
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
		// Historical name retained for an additive migration. The table is the
		// durable admission-key registry for every provider ID: installer mp-*
		// identities begin provisional and legacy bearer-owned identities are
		// inserted confirmed after challenge-signature proof.
		`CREATE TABLE IF NOT EXISTS provider_bootstrap_identities (
			provider_id TEXT PRIMARY KEY,
			receipt_pubkey BLOB NOT NULL UNIQUE,
			identity_generation INTEGER NOT NULL DEFAULT 1,
			previous_receipt_pubkey BLOB,
			previous_valid_until TEXT,
			rotated_at TEXT,
			created_at TEXT NOT NULL,
			confirmed_at TEXT,
			operator_revoked_at TEXT,
			expires_at TEXT
		)`,
		`CREATE TABLE IF NOT EXISTS admission_identity_recovery_audit (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			provider_id TEXT NOT NULL,
			prior_generation INTEGER NOT NULL,
			new_generation INTEGER NOT NULL,
			prior_public_key_sha256 TEXT NOT NULL,
			new_public_key_sha256 TEXT NOT NULL,
			granted_by TEXT NOT NULL,
			recovery_authorization_id TEXT,
			incident_id TEXT,
			recovered_at TEXT NOT NULL,
			UNIQUE(provider_id, prior_generation, new_generation)
		)`,
		`CREATE TABLE IF NOT EXISTS admission_identity_recovery_authorizations (
			pending_id TEXT PRIMARY KEY,
			provider_id TEXT NOT NULL,
			candidate_public_key_sha256 TEXT NOT NULL,
			expected_current_public_key_sha256 TEXT NOT NULL,
			expected_generation INTEGER NOT NULL,
			requested_by TEXT NOT NULL,
			requested_until TEXT NOT NULL,
			reason TEXT NOT NULL,
			incident_id TEXT NOT NULL,
			approved_by TEXT,
			approved_at TEXT,
			consumed_at TEXT,
			cancelled_at TEXT,
			created_at TEXT NOT NULL,
			CHECK (expected_generation >= 1),
			CHECK (candidate_public_key_sha256 <> expected_current_public_key_sha256),
			CHECK ((approved_by IS NULL) = (approved_at IS NULL)),
			CHECK (approved_by IS NULL OR approved_by <> requested_by),
			UNIQUE(provider_id, incident_id)
		)`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_admission_identity_recovery_open
			ON admission_identity_recovery_authorizations(provider_id)
			WHERE consumed_at IS NULL AND cancelled_at IS NULL`,
		`CREATE TABLE IF NOT EXISTS bootstrap_mint_log (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			provider_id TEXT NOT NULL,
			source_ip TEXT NOT NULL,
			ts TEXT NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_bootstrap_mint_log_provider_ts ON bootstrap_mint_log(provider_id, ts)`,
		`CREATE INDEX IF NOT EXISTS idx_bootstrap_mint_log_ip_ts ON bootstrap_mint_log(source_ip, ts)`,
		`CREATE TABLE IF NOT EXISTS referral_issuers (
			issuer_id TEXT PRIMARY KEY,
			code_type TEXT NOT NULL CHECK(code_type IN ('S','P')),
			key_id TEXT NOT NULL,
			campaign TEXT NOT NULL,
			provider_id TEXT,
			base_capacity INTEGER NOT NULL CHECK(base_capacity >= 0),
			bonus_capacity INTEGER NOT NULL DEFAULT 0 CHECK(bonus_capacity >= 0),
			expires_at TEXT,
			revoked_at TEXT,
			created_at TEXT NOT NULL,
			first_serving_at TEXT,
			UNIQUE(provider_id, campaign)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_referral_issuers_provider_campaign ON referral_issuers(provider_id, campaign)`,
		`CREATE TABLE IF NOT EXISTS referral_redemptions (
			campaign TEXT NOT NULL,
			provider_id TEXT NOT NULL,
			issuer_id TEXT NOT NULL REFERENCES referral_issuers(issuer_id),
			code_digest TEXT NOT NULL,
			policy_version TEXT NOT NULL DEFAULT 'v1',
			redeemed_at TEXT NOT NULL,
			PRIMARY KEY(campaign, provider_id)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_referral_redemptions_issuer ON referral_redemptions(issuer_id)`,
		`CREATE TABLE IF NOT EXISTS provider_referral_admissions (
			provider_id TEXT NOT NULL,
			campaign TEXT NOT NULL,
			policy_version TEXT NOT NULL,
			decision TEXT NOT NULL CHECK(decision IN ('referred','grandfathered')),
			applied_at TEXT NOT NULL,
			PRIMARY KEY(provider_id, campaign)
		)`,
		`CREATE TABLE IF NOT EXISTS apptrack_pending_referral_mints (
			provider_id TEXT PRIMARY KEY,
			token_hash TEXT NOT NULL UNIQUE,
			campaign TEXT NOT NULL,
			registration_source_ip TEXT NOT NULL,
			registration_nonce TEXT NOT NULL,
			registration_attempt_ts TEXT NOT NULL,
			created_redemption INTEGER NOT NULL CHECK(created_redemption IN (0, 1)),
			created_at TEXT NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_apptrack_pending_referral_mints_created_at ON apptrack_pending_referral_mints(created_at)`,
		`CREATE TABLE IF NOT EXISTS bootstrap_gc_audit (
			id INTEGER PRIMARY KEY CHECK (id = 1),
			last_run_at TEXT NOT NULL,
			last_removed_identities INTEGER NOT NULL,
			last_removed_tokens INTEGER NOT NULL,
			last_removed_logs INTEGER NOT NULL,
			total_removed_identities INTEGER NOT NULL,
			total_removed_tokens INTEGER NOT NULL,
			total_removed_logs INTEGER NOT NULL
		)`,
	}
	stmts = append(stmts, referralAdminSchemaStatements()...)
	stmts = append(stmts, referralSocialSchemaStatements()...)
	for _, stmt := range stmts {
		if _, err := tx.ExecContext(ctx, stmt); err != nil {
			return err
		}
	}
	if err := ensureColumnTx(ctx, tx, "oauth_states", "origin_hash", `ALTER TABLE oauth_states ADD COLUMN origin_hash TEXT`); err != nil {
		return err
	}
	if err := ensureColumnTx(ctx, tx, "provider_tokens", "bootstrap_issued", `ALTER TABLE provider_tokens ADD COLUMN bootstrap_issued INTEGER NOT NULL DEFAULT 0`); err != nil {
		return err
	}
	if err := ensureColumnTx(ctx, tx, "provider_tokens", "bootstrap_expires_at", `ALTER TABLE provider_tokens ADD COLUMN bootstrap_expires_at TEXT`); err != nil {
		return err
	}
	if err := ensureColumnTx(ctx, tx, "referral_social_verifications", "share_url_hash", `ALTER TABLE referral_social_verifications ADD COLUMN share_url_hash TEXT NOT NULL DEFAULT ''`); err != nil {
		return err
	}
	if err := ensureColumnTx(ctx, tx, "referral_social_verifications", "challenge_hash", `ALTER TABLE referral_social_verifications ADD COLUMN challenge_hash TEXT NOT NULL DEFAULT ''`); err != nil {
		return err
	}
	if err := ensureColumnTx(ctx, tx, "referral_social_verifications", "next_check_at", `ALTER TABLE referral_social_verifications ADD COLUMN next_check_at TEXT NOT NULL DEFAULT ''`); err != nil {
		return err
	}
	if err := ensureColumnTx(ctx, tx, "referral_social_verifications", "recheck_attempts", `ALTER TABLE referral_social_verifications ADD COLUMN recheck_attempts INTEGER NOT NULL DEFAULT 0`); err != nil {
		return err
	}
	if err := ensureColumnTx(ctx, tx, "referral_social_verifications", "lease_token", `ALTER TABLE referral_social_verifications ADD COLUMN lease_token TEXT`); err != nil {
		return err
	}
	if err := ensureColumnTx(ctx, tx, "referral_social_verifications", "lease_until", `ALTER TABLE referral_social_verifications ADD COLUMN lease_until TEXT`); err != nil {
		return err
	}
	if err := ensureColumnTx(ctx, tx, "referral_social_verification_history", "challenge_hash", `ALTER TABLE referral_social_verification_history ADD COLUMN challenge_hash TEXT NOT NULL DEFAULT ''`); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
CREATE INDEX IF NOT EXISTS idx_referral_social_recheck_pending
    ON referral_social_verifications(campaign, next_check_at, pending_since)
 WHERE granted_at IS NULL AND failed_at IS NULL`); err != nil {
		return err
	}
	if err := ensureColumnTx(ctx, tx, "provider_bootstrap_identities", "confirmed_at", `ALTER TABLE provider_bootstrap_identities ADD COLUMN confirmed_at TEXT`); err != nil {
		return err
	}
	if err := ensureColumnTx(ctx, tx, "provider_bootstrap_identities", "expires_at", `ALTER TABLE provider_bootstrap_identities ADD COLUMN expires_at TEXT`); err != nil {
		return err
	}
	if err := ensureColumnTx(ctx, tx, "provider_bootstrap_identities", "operator_revoked_at", `ALTER TABLE provider_bootstrap_identities ADD COLUMN operator_revoked_at TEXT`); err != nil {
		return err
	}
	if err := ensureColumnTx(ctx, tx, "provider_bootstrap_identities", "identity_generation", `ALTER TABLE provider_bootstrap_identities ADD COLUMN identity_generation INTEGER NOT NULL DEFAULT 1`); err != nil {
		return err
	}
	if err := ensureColumnTx(ctx, tx, "provider_bootstrap_identities", "previous_receipt_pubkey", `ALTER TABLE provider_bootstrap_identities ADD COLUMN previous_receipt_pubkey BLOB`); err != nil {
		return err
	}
	if err := ensureColumnTx(ctx, tx, "provider_bootstrap_identities", "previous_valid_until", `ALTER TABLE provider_bootstrap_identities ADD COLUMN previous_valid_until TEXT`); err != nil {
		return err
	}
	if err := ensureColumnTx(ctx, tx, "provider_bootstrap_identities", "rotated_at", `ALTER TABLE provider_bootstrap_identities ADD COLUMN rotated_at TEXT`); err != nil {
		return err
	}
	if err := ensureColumnTx(ctx, tx, "admission_identity_recovery_audit", "recovery_authorization_id", `ALTER TABLE admission_identity_recovery_audit ADD COLUMN recovery_authorization_id TEXT`); err != nil {
		return err
	}
	if err := ensureColumnTx(ctx, tx, "admission_identity_recovery_audit", "incident_id", `ALTER TABLE admission_identity_recovery_audit ADD COLUMN incident_id TEXT`); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
UPDATE provider_bootstrap_identities
   SET confirmed_at = COALESCE(confirmed_at, created_at)
 WHERE EXISTS (
       SELECT 1 FROM provider_tokens
        WHERE provider_tokens.provider_id = provider_bootstrap_identities.provider_id
          AND provider_tokens.bootstrap_issued = 1
          AND provider_tokens.last_used_at IS NOT NULL
   )`); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
UPDATE provider_bootstrap_identities
   SET expires_at = (
       SELECT MAX(provider_tokens.bootstrap_expires_at)
         FROM provider_tokens
        WHERE provider_tokens.provider_id = provider_bootstrap_identities.provider_id
          AND provider_tokens.bootstrap_issued = 1
   )
 WHERE confirmed_at IS NULL AND expires_at IS NULL`); err != nil {
		return err
	}
	return tx.Commit()
}

func ensureColumnTx(ctx context.Context, tx *sql.Tx, table, column, alter string) error {
	rows, err := tx.QueryContext(ctx, `PRAGMA table_info(`+table+`)`)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var cid, notNull, pk int
		var name, typ string
		var defaultValue sql.NullString
		if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
			return err
		}
		if name == column {
			return nil
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, alter)
	return err
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
	return s.issueToken(ctx, providerID, providerName, "", ReferralPolicy{})
}

// IssueTokenWithReferral redeems referral capacity in the same SQLite
// transaction as the token insert.
func (s *Store) IssueTokenWithReferral(ctx context.Context, providerID, providerName, referralCode string, policy ReferralPolicy) (TokenRecord, string, error) {
	return s.issueToken(ctx, providerID, providerName, referralCode, policy)
}

func (s *Store) issueToken(ctx context.Context, providerID, providerName, referralCode string, policy ReferralPolicy) (TokenRecord, string, error) {
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
	now := time.Now().UTC()
	createdAt := timeText(now)
	var record TokenRecord
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		if IsCredentialBootstrapPrincipal(providerID) {
			var bootstrapIdentityExists int
			if err := conn.QueryRowContext(ctx, `
SELECT EXISTS(
    SELECT 1 FROM provider_bootstrap_identities WHERE provider_id = ?
)`, providerID).Scan(&bootstrapIdentityExists); err != nil {
				return err
			}
			if bootstrapIdentityExists == 1 {
				return ErrBootstrapIdentityExists
			}
		}
		if _, err := redeemReferralTx(ctx, conn, policy, referralCode, providerID, now); err != nil {
			return err
		}
		res, err := conn.ExecContext(ctx, `INSERT INTO provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at) VALUES (?, ?, ?, ?, ?)`, hash, prefix, providerID, providerName, createdAt)
		if err != nil {
			if isActiveProviderTokenConstraintFailure(err) {
				return ErrActiveTokenAlreadyExists
			}
			return err
		}
		id, err := res.LastInsertId()
		if err != nil {
			return err
		}
		record = TokenRecord{ID: id, TokenPrefix: prefix, ProviderID: providerID, ProviderName: providerName, CreatedAt: createdAt}
		return nil
	})
	if err != nil {
		return TokenRecord{}, "", err
	}
	return record, token, nil
}

// MintBootstrapToken is the only credential-bootstrap mutation path. The
// receipt-key TOFU binding, durable rate checks, bounded transactional GC,
// same-key unused-token replacement, and new token insert share one
// BEGIN IMMEDIATE transaction. A response-loss retry can therefore replace
// only the bootstrap token owned by the exact key that proved the fresh v2
// challenge; ordinary and used tokens are never revoked by this path, while
// expired never-used token rows are collected while their receipt-key custody
// bindings remain available for the configured recovery window. Confirmed and
// operator-revoked bindings remain durable; never-admitted random IDs are
// collected after retention so unauthenticated storage remains time-bounded.
func (s *Store) MintBootstrapToken(ctx context.Context, req BootstrapMintRequest) (BootstrapMint, error) {
	if err := config.ValidateProviderID(req.ProviderID); err != nil {
		return BootstrapMint{}, err
	}
	if !IsCredentialBootstrapPrincipal(req.ProviderID) {
		return BootstrapMint{}, ErrBootstrapIdentityMismatch
	}
	req.ProviderName = strings.TrimSpace(req.ProviderName)
	req.SourceIP = strings.TrimSpace(req.SourceIP)
	if req.ProviderName == "" || req.SourceIP == "" {
		return BootstrapMint{}, fmt.Errorf("bootstrap provider name and source ip are required")
	}
	if len(req.ReceiptPubkey) != ed25519.PublicKeySize {
		return BootstrapMint{}, fmt.Errorf("bootstrap receipt public key must be %d bytes", ed25519.PublicKeySize)
	}
	if req.Now.IsZero() {
		req.Now = time.Now().UTC()
	} else {
		req.Now = req.Now.UTC()
	}
	if req.TTL <= 0 || req.IdentityRetention <= 0 || req.PerIPLimitPerHour <= 0 || req.PerProviderPerHour <= 0 ||
		req.GlobalLimitPerHour <= 0 || req.UnconfirmedIDMax <= 0 || req.OutstandingTokenMax <= 0 {
		return BootstrapMint{}, fmt.Errorf("bootstrap limits and ttl must be positive")
	}
	if req.IdentityRetention <= req.TTL {
		return BootstrapMint{}, fmt.Errorf("bootstrap identity retention must exceed token ttl")
	}
	newToken, err := randomHex(32)
	if err != nil {
		return BootstrapMint{}, err
	}

	var out BootstrapMint
	var decisionErr error
	err = sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		nowText := timeText(req.Now)
		cutoffText := timeText(req.Now.Add(-time.Hour))
		identityCutoffText := timeText(req.Now.Add(-req.IdentityRetention))
		expiresText := timeText(req.Now.Add(req.TTL))

		removedLogs, err := deleteRows(ctx, conn, `DELETE FROM bootstrap_mint_log WHERE ts < ?`, cutoffText)
		if err != nil {
			return err
		}
		removedTokens, err := deleteRows(ctx, conn, `
DELETE FROM provider_tokens
 WHERE bootstrap_issued = 1
   AND last_used_at IS NULL
   AND bootstrap_expires_at IS NOT NULL
   AND bootstrap_expires_at <= ?`, nowText)
		if err != nil {
			return err
		}
		// Unconfirmed receipt-key bindings survive token expiry for the configured
		// recovery window, then become safe to collect: their random 128-bit
		// provider IDs were never admitted or exposed through the live pool.
		// Confirmed ownership and operator tombstones remain durable forever.
		removedIdentities, err := deleteRows(ctx, conn, `
DELETE FROM provider_bootstrap_identities
 WHERE confirmed_at IS NULL
   AND operator_revoked_at IS NULL
   AND expires_at IS NOT NULL
   AND expires_at <= ?`, identityCutoffText)
		if err != nil {
			return err
		}
		if _, err := conn.ExecContext(ctx, `
INSERT INTO bootstrap_gc_audit (
    id, last_run_at, last_removed_identities, last_removed_tokens, last_removed_logs,
    total_removed_identities, total_removed_tokens, total_removed_logs
) VALUES (1, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
    last_run_at = excluded.last_run_at,
    last_removed_identities = excluded.last_removed_identities,
    last_removed_tokens = excluded.last_removed_tokens,
    last_removed_logs = excluded.last_removed_logs,
    total_removed_identities = bootstrap_gc_audit.total_removed_identities + excluded.last_removed_identities,
    total_removed_tokens = bootstrap_gc_audit.total_removed_tokens + excluded.last_removed_tokens,
    total_removed_logs = bootstrap_gc_audit.total_removed_logs + excluded.last_removed_logs`,
			nowText, removedIdentities, removedTokens, removedLogs, removedIdentities, removedTokens, removedLogs); err != nil {
			return err
		}

		var storedPubkey []byte
		var confirmedAt, operatorRevokedAt sql.NullString
		identityErr := conn.QueryRowContext(ctx, `
SELECT receipt_pubkey, confirmed_at, operator_revoked_at
  FROM provider_bootstrap_identities
 WHERE provider_id = ?`, req.ProviderID).Scan(&storedPubkey, &confirmedAt, &operatorRevokedAt)
		if identityErr != nil && identityErr != sql.ErrNoRows {
			return identityErr
		}
		identityExists := identityErr == nil
		if identityExists && !bytes.Equal(storedPubkey, req.ReceiptPubkey) {
			decisionErr = ErrBootstrapIdentityMismatch
			return nil
		}
		if identityExists && operatorRevokedAt.Valid {
			decisionErr = ErrBootstrapTokenUsed
			return nil
		}

		// Bootstrap is not an alternate issuance path for an operator-managed
		// principal. Preserve that provenance even after the ordinary token is
		// revoked so a former credential holder cannot resurrect access with a
		// locally available receipt key.
		var ordinaryHistory int
		if err := conn.QueryRowContext(ctx, `
SELECT EXISTS(
    SELECT 1 FROM provider_tokens
     WHERE provider_id = ? AND bootstrap_issued = 0
)`, req.ProviderID).Scan(&ordinaryHistory); err != nil {
			return err
		}
		if ordinaryHistory == 1 {
			decisionErr = ErrBootstrapIdentityMismatch
			return nil
		}

		var active struct {
			ID        int64
			Issued    int
			ExpiresAt sql.NullString
			LastUsed  sql.NullString
		}
		activeErr := conn.QueryRowContext(ctx, `
SELECT id, bootstrap_issued, bootstrap_expires_at, last_used_at
  FROM provider_tokens
 WHERE provider_id = ? AND revoked_at IS NULL
 LIMIT 1`, req.ProviderID).Scan(&active.ID, &active.Issued, &active.ExpiresAt, &active.LastUsed)
		if activeErr != nil && activeErr != sql.ErrNoRows {
			return activeErr
		}
		activeExists := activeErr == nil
		if activeExists {
			if active.Issued != 1 || !identityExists {
				decisionErr = ErrBootstrapIdentityMismatch
				return nil
			}
			if active.LastUsed.Valid || confirmedAt.Valid {
				decisionErr = ErrBootstrapTokenUsed
				return nil
			}
			expiresAt, parseErr := time.Parse(time.RFC3339, active.ExpiresAt.String)
			if !active.ExpiresAt.Valid || parseErr != nil || !expiresAt.After(req.Now) {
				decisionErr = ErrBootstrapTokenExpired
				return nil
			}
		} else if identityExists {
			// Confirmed ownership is permanent. An unconfirmed exact-key binding
			// may outlive its provisional token and is the authorized recovery
			// path; malformed or operator-revoked bindings failed above.
			if confirmedAt.Valid {
				decisionErr = ErrBootstrapTokenUsed
				return nil
			}
		}

		var ipMints, providerMints, globalMints int
		if err := conn.QueryRowContext(ctx, `
SELECT COUNT(1) FROM bootstrap_mint_log
 WHERE source_ip = ? AND ts >= ?`, req.SourceIP, cutoffText).Scan(&ipMints); err != nil {
			return err
		}
		if err := conn.QueryRowContext(ctx, `
SELECT COUNT(1) FROM bootstrap_mint_log
 WHERE provider_id = ? AND ts >= ?`, req.ProviderID, cutoffText).Scan(&providerMints); err != nil {
			return err
		}
		if err := conn.QueryRowContext(ctx, `
SELECT COUNT(1) FROM bootstrap_mint_log
 WHERE ts >= ?`, cutoffText).Scan(&globalMints); err != nil {
			return err
		}
		if ipMints >= req.PerIPLimitPerHour || providerMints >= req.PerProviderPerHour || globalMints >= req.GlobalLimitPerHour {
			decisionErr = ErrBootstrapRateLimited
			return nil
		}

		if !activeExists {
			var outstanding, unconfirmed int
			if err := conn.QueryRowContext(ctx, `
SELECT COUNT(1)
  FROM provider_tokens
 WHERE bootstrap_issued = 1
   AND revoked_at IS NULL
   AND last_used_at IS NULL
   AND bootstrap_expires_at > ?`, nowText).Scan(&outstanding); err != nil {
				return err
			}
			if outstanding >= req.OutstandingTokenMax {
				decisionErr = ErrBootstrapOutstandingLimit
				return nil
			}
			if err := conn.QueryRowContext(ctx, `
SELECT COUNT(1)
  FROM provider_bootstrap_identities
 WHERE confirmed_at IS NULL
   AND operator_revoked_at IS NULL
   AND expires_at IS NOT NULL
   AND expires_at > ?`, nowText).Scan(&unconfirmed); err != nil {
				return err
			}
			if !identityExists && unconfirmed >= req.UnconfirmedIDMax {
				decisionErr = ErrBootstrapOutstandingLimit
				return nil
			}
		}

		referralPolicy := req.ReferralPolicy
		// Grandfathering is available only after exact receipt-key custody of an
		// existing bootstrap identity has been proven above.
		referralPolicy.GrandfatherProof = identityExists
		if _, err := redeemReferralTx(ctx, conn, referralPolicy, req.ReferralCode, req.ProviderID, req.Now); err != nil {
			return err
		}

		if activeExists {
			res, err := conn.ExecContext(ctx, `
UPDATE provider_tokens
   SET revoked_at = ?
 WHERE id = ?
   AND revoked_at IS NULL
   AND last_used_at IS NULL
   AND bootstrap_issued = 1`, nowText, active.ID)
			if err != nil {
				return err
			}
			affected, err := res.RowsAffected()
			if err != nil {
				return err
			}
			if affected != 1 {
				return ErrBootstrapTokenUsed
			}
			if _, err := conn.ExecContext(ctx, `
UPDATE provider_bootstrap_identities
   SET expires_at = ?
 WHERE provider_id = ? AND confirmed_at IS NULL`, expiresText, req.ProviderID); err != nil {
				return err
			}
			out.Replaced = true
		} else if identityExists {
			if _, err := conn.ExecContext(ctx, `
UPDATE provider_bootstrap_identities
   SET expires_at = ?
 WHERE provider_id = ?
   AND confirmed_at IS NULL
   AND operator_revoked_at IS NULL`, expiresText, req.ProviderID); err != nil {
				return err
			}
			out.Replaced = true
		} else {
			if _, err := conn.ExecContext(ctx, `
INSERT INTO provider_bootstrap_identities (provider_id, receipt_pubkey, created_at, expires_at)
VALUES (?, ?, ?, ?)`, req.ProviderID, req.ReceiptPubkey, nowText, expiresText); err != nil {
				if isConstraintFailure(err) {
					decisionErr = ErrBootstrapIdentityMismatch
					return nil
				}
				return err
			}
		}

		prefix := newToken[:tokenDisplayPrefixLength]
		res, err := conn.ExecContext(ctx, `
INSERT INTO provider_tokens (
    token_hash, token_prefix, provider_id, provider_name, created_at,
    bootstrap_issued, bootstrap_expires_at
) VALUES (?, ?, ?, ?, ?, 1, ?)`,
			tokenHash(newToken), prefix, req.ProviderID, req.ProviderName, nowText, expiresText)
		if err != nil {
			if isActiveProviderTokenConstraintFailure(err) {
				return ErrActiveTokenAlreadyExists
			}
			return err
		}
		id, err := res.LastInsertId()
		if err != nil {
			return err
		}
		if _, err := conn.ExecContext(ctx, `
INSERT INTO bootstrap_mint_log (provider_id, source_ip, ts)
VALUES (?, ?, ?)`, req.ProviderID, req.SourceIP, nowText); err != nil {
			return err
		}
		out.TokenRecord = TokenRecord{
			ID: id, TokenPrefix: prefix, ProviderID: req.ProviderID,
			ProviderName: req.ProviderName, CreatedAt: nowText,
		}
		out.ProviderToken = newToken
		return nil
	})
	if err != nil {
		return BootstrapMint{}, err
	}
	if decisionErr != nil {
		return BootstrapMint{}, decisionErr
	}
	return out, nil
}

// IsCredentialBootstrapPrincipal recognizes installer-generated auth
// principals. The 128-bit lowercase suffix is deliberately unrelated to the
// operator-facing hostname/display name, so an unauthenticated client cannot
// permanently preclaim a predictable handle.
func IsCredentialBootstrapPrincipal(providerID string) bool {
	if len(providerID) != len("mp-")+32 || !strings.HasPrefix(providerID, "mp-") {
		return false
	}
	for _, c := range providerID[len("mp-"):] {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

func deleteRows(ctx context.Context, conn *sql.Conn, query string, args ...any) (int64, error) {
	res, err := conn.ExecContext(ctx, query, args...)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

func (s *Store) MintProviderTokenAppTrack(ctx context.Context, providerID string, currentBearer, freshTokenCandidate *string) (string, error) {
	if err := config.ValidateProviderID(providerID); err != nil {
		return "", err
	}
	var token string
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		nowText := nowString()
		var active struct {
			ID        int64
			TokenHash string
		}
		lookupErr := conn.QueryRowContext(ctx, `
SELECT id, token_hash
  FROM provider_tokens
 WHERE provider_id = ? AND revoked_at IS NULL
 LIMIT 1`, providerID).Scan(&active.ID, &active.TokenHash)
		if lookupErr != nil && lookupErr != sql.ErrNoRows {
			return lookupErr
		}

		requiresProof := lookupErr == nil
		if requiresProof {
			if currentBearer == nil || strings.TrimSpace(*currentBearer) == "" || tokenHash(strings.TrimSpace(*currentBearer)) != active.TokenHash {
				return ErrAppTrackExistingTokenNoProof
			}
			var recent int
			if err := conn.QueryRowContext(ctx, `
SELECT COUNT(1)
  FROM apptrack_register_reissues
 WHERE provider_id = ? AND ts >= ?`,
				providerID, timeText(time.Now().UTC().Add(-5*time.Minute)),
			).Scan(&recent); err != nil {
				return err
			}
			if recent > 0 {
				return ErrAppTrackReissueCooldown
			}
		}

		if lookupErr == nil {
			if _, err := conn.ExecContext(ctx, `
UPDATE provider_tokens
   SET revoked_at = ?
 WHERE id = ? AND revoked_at IS NULL`, nowText, active.ID); err != nil {
				return err
			}
		}

		var newToken string
		if !requiresProof && freshTokenCandidate != nil {
			newToken = strings.TrimSpace(*freshTokenCandidate)
			if len(newToken) != 64 || !isLowerHexToken(newToken) {
				return ErrReferralConflict
			}
		} else {
			var err error
			newToken, err = randomHex(32)
			if err != nil {
				return err
			}
		}
		prefix := newToken[:tokenDisplayPrefixLength]
		if _, err := conn.ExecContext(ctx, `
INSERT INTO provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at)
VALUES (?, ?, ?, ?, ?)`, tokenHash(newToken), prefix, providerID, "malibu-app", nowText); err != nil {
			if isActiveProviderTokenConstraintFailure(err) {
				return ErrActiveTokenAlreadyExists
			}
			return err
		}
		if requiresProof {
			if _, err := conn.ExecContext(ctx, `
INSERT INTO apptrack_register_reissues (provider_id, ts)
VALUES (?, ?)`, providerID, nowText); err != nil {
				return err
			}
		}
		token = newToken
		return nil
	})
	if err != nil {
		return "", err
	}
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

// PruneUnusedTokens retires tokens whose `last_used_at` is NULL and whose
// `created_at` is older than the supplied cutoff time. Returns the number of
// rows retired. Used by `coordinator-cli prune-tokens` to bound
// the operational cost of FR-C9.4 multi-mint-then-self-heal — a token
// that has never been used to authenticate and is older than the
// settling window is safe to invalidate.
//
// Historical ordinary credentials for strict installer mp-* principals are
// revoked but retained as ownership tombstones. MintBootstrapToken relies on
// that durable provenance to prevent a pruned operator-managed identity from
// being reclaimed through the unauthenticated bootstrap track. Bootstrap
// token rows can be deleted because provider_bootstrap_identities is their
// durable custody record.
//
// The cutoff is compared as ISO-8601 strings; tokens.go nowString
// formats `created_at` in the same `2006-01-02T15:04:05Z` shape, and
// lexicographic comparison is monotonic within that format.
func (s *Store) PruneUnusedTokens(ctx context.Context, olderThan time.Time) (int64, error) {
	cutoff := olderThan.UTC().Format("2006-01-02T15:04:05Z")
	nowText := nowString()
	var retired int64
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		rows, err := conn.QueryContext(ctx, `
SELECT id, provider_id, bootstrap_issued
  FROM provider_tokens
 WHERE last_used_at IS NULL
   AND revoked_at IS NULL
   AND created_at < ?`, cutoff)
		if err != nil {
			return err
		}
		type candidate struct {
			id              int64
			providerID      string
			bootstrapIssued int
		}
		var candidates []candidate
		for rows.Next() {
			var c candidate
			if err := rows.Scan(&c.id, &c.providerID, &c.bootstrapIssued); err != nil {
				rows.Close()
				return err
			}
			candidates = append(candidates, c)
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return err
		}
		if err := rows.Close(); err != nil {
			return err
		}
		for _, c := range candidates {
			var res sql.Result
			if c.bootstrapIssued == 0 && IsCredentialBootstrapPrincipal(c.providerID) {
				res, err = conn.ExecContext(ctx, `
UPDATE provider_tokens
   SET revoked_at = ?
 WHERE id = ? AND revoked_at IS NULL AND last_used_at IS NULL`, nowText, c.id)
			} else {
				res, err = conn.ExecContext(ctx, `
DELETE FROM provider_tokens
 WHERE id = ? AND revoked_at IS NULL AND last_used_at IS NULL`, c.id)
			}
			if err != nil {
				return err
			}
			n, err := res.RowsAffected()
			if err != nil {
				return err
			}
			retired += n
		}
		return nil
	})
	if err != nil {
		return 0, err
	}
	return retired, nil
}

func (s *Store) ValidateToken(ctx context.Context, token string) (string, bool, error) {
	if token == "" {
		return "", false, nil
	}
	hash := tokenHash(token)
	var providerID string
	valid := false
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var id int64
		var bootstrapIssued int
		var bootstrapExpiresAt, lastUsedAt sql.NullString
		err := conn.QueryRowContext(ctx, `
SELECT id, provider_id, bootstrap_issued, bootstrap_expires_at, last_used_at
  FROM provider_tokens
 WHERE token_hash = ? AND revoked_at IS NULL AND provider_id <> ''`, hash).
			Scan(&id, &providerID, &bootstrapIssued, &bootstrapExpiresAt, &lastUsedAt)
		if err == sql.ErrNoRows {
			return nil
		}
		if err != nil {
			return err
		}
		if bootstrapIssued == 1 && !lastUsedAt.Valid {
			now := time.Now().UTC()
			expiresAt, parseErr := time.Parse(time.RFC3339, bootstrapExpiresAt.String)
			if !bootstrapExpiresAt.Valid || parseErr != nil || !expiresAt.After(now) {
				_, err := conn.ExecContext(ctx, `
UPDATE provider_tokens
   SET revoked_at = ?
 WHERE id = ? AND revoked_at IS NULL AND last_used_at IS NULL`, timeText(now), id)
				return err
			}
		}
		valid = true
		return nil
	})
	if err != nil {
		return "", false, err
	}
	if !valid {
		return "", false, nil
	}
	if providerID == "" {
		return "", false, nil
	}
	return providerID, true, nil
}

// ValidateTokenReadOnly authenticates provider API reads without taking a
// write transaction or refreshing last_used_at. Expired provisional bootstrap
// credentials fail closed but remain for the normal auth retention path.
func (s *Store) ValidateTokenReadOnly(ctx context.Context, token string) (string, bool, error) {
	if token == "" {
		return "", false, nil
	}
	var providerID string
	var bootstrapIssued int
	var bootstrapExpiresAt, lastUsedAt sql.NullString
	err := s.db.QueryRowContext(ctx, `
SELECT provider_id, bootstrap_issued, bootstrap_expires_at, last_used_at
  FROM provider_tokens
 WHERE token_hash = ? AND revoked_at IS NULL AND provider_id <> ''`, tokenHash(token)).Scan(
		&providerID, &bootstrapIssued, &bootstrapExpiresAt, &lastUsedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	if bootstrapIssued == 1 && !lastUsedAt.Valid {
		expiresAt, parseErr := time.Parse(time.RFC3339, bootstrapExpiresAt.String)
		if !bootstrapExpiresAt.Valid || parseErr != nil || !expiresAt.After(time.Now().UTC()) {
			return "", false, nil
		}
	}
	return providerID, true, nil
}

// LookupBootstrapIdentityPubkey returns the durable receipt-key owner for an
// installer-generated provider ID. Confirmed ownership is permanent. Before
// first accepted admission, the binding is usable only while its matching
// provisional bearer is active and unexpired. This lets the normal bearer-v2
// handshake prove the same identity that minted the credential without
// trusting a self-declared key or an ephemeral provider-pool entry.
func (s *Store) LookupBootstrapIdentityPubkey(ctx context.Context, providerID string) ([]byte, bool, error) {
	if !IsCredentialBootstrapPrincipal(providerID) {
		return nil, false, nil
	}
	return s.LookupAdmissionIdentityPubkey(ctx, providerID)
}

// LookupAdmissionIdentityPubkey returns the coordinator-owned durable
// admission key for any provider ID. Confirmed identities survive coordinator
// and provider restarts without consulting the live provider pool. An
// unconfirmed installer identity remains usable only while its provisional
// bearer is active and unexpired.
func (s *Store) LookupAdmissionIdentityPubkey(ctx context.Context, providerID string) ([]byte, bool, error) {
	state, ok, err := s.LookupAdmissionIdentityState(ctx, providerID, time.Now().UTC())
	if err != nil || !ok {
		return nil, ok, err
	}
	return append([]byte(nil), state.CurrentPublicKey...), true, nil
}

// LookupAdmissionIdentityState returns the active admission-key generation.
// Confirmed identities remain active until operator revocation. A provisional
// bootstrap identity remains active only while its matching unused bearer is
// active and unexpired. Expired previous keys are deliberately omitted while
// their authoritative deadline remains available for response-loss replay.
func (s *Store) LookupAdmissionIdentityState(ctx context.Context, providerID string, now time.Time) (AdmissionIdentityState, bool, error) {
	if err := config.ValidateProviderID(providerID); err != nil {
		return AdmissionIdentityState{}, false, err
	}
	if now.IsZero() {
		now = time.Now().UTC()
	} else {
		now = now.UTC()
	}
	nowText := timeText(now)
	var current, previous []byte
	var generation int
	var previousValidUntil sql.NullString
	err := s.db.QueryRowContext(ctx, `
SELECT i.receipt_pubkey, i.identity_generation,
       i.previous_receipt_pubkey, i.previous_valid_until
  FROM provider_bootstrap_identities i
 WHERE i.provider_id = ?
   AND i.operator_revoked_at IS NULL
   AND (
       i.confirmed_at IS NOT NULL
       OR (
           i.confirmed_at IS NULL
           AND i.expires_at IS NOT NULL
           AND i.expires_at > ?
           AND EXISTS (
               SELECT 1
                 FROM provider_tokens t
                WHERE t.provider_id = i.provider_id
                  AND t.bootstrap_issued = 1
                  AND t.revoked_at IS NULL
                  AND t.last_used_at IS NULL
                  AND t.bootstrap_expires_at IS NOT NULL
                  AND t.bootstrap_expires_at > ?
           )
       )
   )`, providerID, nowText, nowText).Scan(&current, &generation, &previous, &previousValidUntil)
	if err == sql.ErrNoRows {
		return AdmissionIdentityState{}, false, nil
	}
	if err != nil {
		return AdmissionIdentityState{}, false, err
	}
	if len(current) != ed25519.PublicKeySize || generation < 1 {
		return AdmissionIdentityState{}, false, nil
	}
	state := AdmissionIdentityState{
		CurrentPublicKey: append([]byte(nil), current...),
		Generation:       generation,
	}
	if previousValidUntil.Valid {
		validUntil, parseErr := time.Parse(time.RFC3339, previousValidUntil.String)
		if parseErr == nil {
			validUntil = validUntil.UTC()
			state.PreviousValidUntil = &validUntil
			if len(previous) == ed25519.PublicKeySize && validUntil.After(now) {
				state.PreviousPublicKey = append([]byte(nil), previous...)
			}
		}
	}
	return state, true, nil
}

// BootstrapIdentityExists distinguishes a legacy mp-* principal that predates
// credential bootstrap from a principal whose durable binding exists but is
// no longer active. Callers may preserve legacy verification only for the
// former; the latter must fail closed rather than falling back to live state.
func (s *Store) BootstrapIdentityExists(ctx context.Context, providerID string) (bool, error) {
	if !IsCredentialBootstrapPrincipal(providerID) {
		return false, nil
	}
	return s.AdmissionIdentityExists(ctx, providerID)
}

// AdmissionIdentityExists distinguishes an identity that has never enrolled
// from a durable binding that is inactive or operator-revoked. Callers must
// never downgrade an existing binding to self-declared or live-pool identity.
func (s *Store) AdmissionIdentityExists(ctx context.Context, providerID string) (bool, error) {
	if err := config.ValidateProviderID(providerID); err != nil {
		return false, err
	}
	var exists int
	err := s.db.QueryRowContext(ctx, `
SELECT EXISTS(
    SELECT 1 FROM provider_bootstrap_identities WHERE provider_id = ?
)`, providerID).Scan(&exists)
	if err != nil {
		return false, err
	}
	return exists == 1, nil
}

// BindAdmissionIdentity atomically enrolls a challenge-signature-proven public
// key for the provider ID owned by bearer. The WS layer verifies possession of
// the matching private key before calling this method; this transaction then
// revalidates that the still-active bearer owns providerID and makes the
// binding durable. Existing keys are idempotent and can never be replaced by
// this first-enrollment path.
func (s *Store) BindAdmissionIdentity(ctx context.Context, providerID, bearer string, pubkey []byte, now time.Time) error {
	if err := config.ValidateProviderID(providerID); err != nil {
		return err
	}
	bearer = strings.TrimSpace(bearer)
	if bearer == "" {
		return ErrAdmissionIdentityBearerMismatch
	}
	if len(pubkey) != ed25519.PublicKeySize {
		return fmt.Errorf("admission identity public key must be %d bytes", ed25519.PublicKeySize)
	}
	if now.IsZero() {
		now = time.Now().UTC()
	} else {
		now = now.UTC()
	}

	var decisionErr error
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var tokenProviderID string
		var bootstrapIssued int
		var bootstrapExpiresAt, lastUsedAt sql.NullString
		err := conn.QueryRowContext(ctx, `
SELECT provider_id, bootstrap_issued, bootstrap_expires_at, last_used_at
  FROM provider_tokens
 WHERE token_hash = ? AND revoked_at IS NULL AND provider_id <> ''`, tokenHash(bearer)).
			Scan(&tokenProviderID, &bootstrapIssued, &bootstrapExpiresAt, &lastUsedAt)
		if err == sql.ErrNoRows {
			decisionErr = ErrAdmissionIdentityBearerMismatch
			return nil
		}
		if err != nil {
			return err
		}
		if tokenProviderID != providerID {
			decisionErr = ErrAdmissionIdentityBearerMismatch
			return nil
		}
		if bootstrapIssued == 1 && !lastUsedAt.Valid {
			expiresAt, parseErr := time.Parse(time.RFC3339, bootstrapExpiresAt.String)
			if !bootstrapExpiresAt.Valid || parseErr != nil || !expiresAt.After(now) {
				decisionErr = ErrAdmissionIdentityBearerMismatch
				return nil
			}
		}

		var stored []byte
		var operatorRevokedAt sql.NullString
		lookupErr := conn.QueryRowContext(ctx, `
SELECT receipt_pubkey, operator_revoked_at
  FROM provider_bootstrap_identities
 WHERE provider_id = ?`, providerID).Scan(&stored, &operatorRevokedAt)
		if lookupErr != nil && lookupErr != sql.ErrNoRows {
			return lookupErr
		}
		if lookupErr == nil {
			if operatorRevokedAt.Valid || !bytes.Equal(stored, pubkey) {
				decisionErr = ErrAdmissionIdentityMismatch
			}
			return nil
		}

		_, err = conn.ExecContext(ctx, `
INSERT INTO provider_bootstrap_identities (
    provider_id, receipt_pubkey, created_at, confirmed_at, expires_at
) VALUES (?, ?, ?, ?, NULL)`, providerID, append([]byte(nil), pubkey...), timeText(now), timeText(now))
		if err != nil {
			if isConstraintFailure(err) {
				decisionErr = ErrAdmissionIdentityMismatch
				return nil
			}
			return err
		}
		return nil
	})
	if err != nil {
		return err
	}
	return decisionErr
}

// RotateAdmissionIdentity advances the admission key by one generation after
// the WS layer has verified a signature by expectedCurrent over the initial
// transcript containing next. The transaction revalidates the exact active
// bearer and performs a generation/key compare-and-swap, so a bearer alone
// cannot replace identity custody. Repeating the exact transition after a
// lost response is idempotent.
func (s *Store) RotateAdmissionIdentity(
	ctx context.Context,
	providerID, bearer string,
	expectedCurrent, next []byte,
	expectedGeneration int,
	now time.Time,
) (AdmissionIdentityState, error) {
	if err := config.ValidateProviderID(providerID); err != nil {
		return AdmissionIdentityState{}, err
	}
	bearer = strings.TrimSpace(bearer)
	if bearer == "" {
		return AdmissionIdentityState{}, ErrAdmissionIdentityBearerMismatch
	}
	if len(expectedCurrent) != ed25519.PublicKeySize || len(next) != ed25519.PublicKeySize {
		return AdmissionIdentityState{}, fmt.Errorf("admission identity rotation keys must be %d bytes", ed25519.PublicKeySize)
	}
	if bytes.Equal(expectedCurrent, next) || expectedGeneration < 1 {
		return AdmissionIdentityState{}, ErrAdmissionIdentityRotationMismatch
	}
	if now.IsZero() {
		now = time.Now().UTC()
	} else {
		now = now.UTC()
	}

	var result AdmissionIdentityState
	var decisionErr error
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var tokenProviderID string
		var bootstrapIssued int
		var bootstrapExpiresAt, lastUsedAt sql.NullString
		if err := conn.QueryRowContext(ctx, `
SELECT provider_id, bootstrap_issued, bootstrap_expires_at, last_used_at
  FROM provider_tokens
 WHERE token_hash = ? AND revoked_at IS NULL AND provider_id <> ''`, tokenHash(bearer)).
			Scan(&tokenProviderID, &bootstrapIssued, &bootstrapExpiresAt, &lastUsedAt); err != nil {
			if err == sql.ErrNoRows {
				decisionErr = ErrAdmissionIdentityBearerMismatch
				return nil
			}
			return err
		}
		if tokenProviderID != providerID {
			decisionErr = ErrAdmissionIdentityBearerMismatch
			return nil
		}
		if bootstrapIssued == 1 && !lastUsedAt.Valid {
			expiresAt, parseErr := time.Parse(time.RFC3339, bootstrapExpiresAt.String)
			if !bootstrapExpiresAt.Valid || parseErr != nil || !expiresAt.After(now) {
				decisionErr = ErrAdmissionIdentityBearerMismatch
				return nil
			}
		}

		var stored, previous []byte
		var generation int
		var confirmedAt, operatorRevokedAt, previousValidUntil sql.NullString
		if err := conn.QueryRowContext(ctx, `
SELECT receipt_pubkey, identity_generation, previous_receipt_pubkey,
       previous_valid_until, confirmed_at, operator_revoked_at
  FROM provider_bootstrap_identities
 WHERE provider_id = ?`, providerID).
			Scan(&stored, &generation, &previous, &previousValidUntil, &confirmedAt, &operatorRevokedAt); err != nil {
			if err == sql.ErrNoRows {
				decisionErr = ErrAdmissionIdentityRotationMismatch
				return nil
			}
			return err
		}
		if operatorRevokedAt.Valid || !confirmedAt.Valid {
			decisionErr = ErrAdmissionIdentityRotationMismatch
			return nil
		}

		// Exact replay after the commit but before the provider received the
		// response. The old key must still be the recorded previous key and
		// the generation must have advanced exactly once.
		if bytes.Equal(stored, next) && generation == expectedGeneration+1 && bytes.Equal(previous, expectedCurrent) {
			result = admissionIdentityStateFromStored(stored, generation, previous, previousValidUntil, now)
			return nil
		}
		if !bytes.Equal(stored, expectedCurrent) || generation != expectedGeneration {
			decisionErr = ErrAdmissionIdentityRotationMismatch
			return nil
		}

		rotatedAt := timeText(now)
		previousUntil := timeText(now.Add(AdmissionIdentityPreviousKeyGrace))
		res, err := conn.ExecContext(ctx, `
UPDATE provider_bootstrap_identities
   SET receipt_pubkey = ?,
       identity_generation = identity_generation + 1,
       previous_receipt_pubkey = ?,
       previous_valid_until = ?,
       rotated_at = ?
 WHERE provider_id = ?
   AND operator_revoked_at IS NULL
   AND receipt_pubkey = ?
   AND identity_generation = ?`,
			append([]byte(nil), next...), append([]byte(nil), expectedCurrent...), previousUntil,
			rotatedAt, providerID, append([]byte(nil), expectedCurrent...), expectedGeneration)
		if err != nil {
			if isConstraintFailure(err) {
				decisionErr = ErrAdmissionIdentityRotationMismatch
				return nil
			}
			return err
		}
		rows, err := res.RowsAffected()
		if err != nil {
			return err
		}
		if rows != 1 {
			decisionErr = ErrAdmissionIdentityRotationMismatch
			return nil
		}
		validUntil := now.Add(AdmissionIdentityPreviousKeyGrace).UTC().Truncate(time.Second)
		result = AdmissionIdentityState{
			CurrentPublicKey:   append([]byte(nil), next...),
			Generation:         expectedGeneration + 1,
			PreviousPublicKey:  append([]byte(nil), expectedCurrent...),
			PreviousValidUntil: &validUntil,
		}
		return nil
	})
	if err != nil {
		return AdmissionIdentityState{}, err
	}
	if decisionErr != nil {
		return AdmissionIdentityState{}, decisionErr
	}
	return result, nil
}

func (s *Store) RequestAdmissionIdentityRecovery(
	ctx context.Context,
	authorization AdmissionIdentityRecoveryAuthorization,
	now time.Time,
) (AdmissionIdentityRecoveryAuthorization, error) {
	if err := validateAdmissionIdentityRecoveryAuthorization(authorization, false); err != nil {
		return AdmissionIdentityRecoveryAuthorization{}, err
	}
	if now.IsZero() {
		now = time.Now().UTC()
	} else {
		now = now.UTC()
	}
	if !authorization.RequestedUntil.After(now) || authorization.RequestedUntil.Sub(now) > 24*time.Hour {
		return AdmissionIdentityRecoveryAuthorization{}, ErrAdmissionIdentityRecoveryMismatch
	}
	var canonical AdmissionIdentityRecoveryAuthorization
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		if _, err := conn.ExecContext(ctx, `
UPDATE admission_identity_recovery_authorizations
   SET cancelled_at = ?
 WHERE provider_id = ?
   AND consumed_at IS NULL
   AND cancelled_at IS NULL
   AND requested_until <= ?`,
			timeText(now), authorization.ProviderID, timeText(now)); err != nil {
			return err
		}

		var requestedUntilText string
		var approvedBy sql.NullString
		err := conn.QueryRowContext(ctx, `
SELECT pending_id, provider_id, candidate_public_key_sha256,
       expected_current_public_key_sha256, expected_generation,
       requested_by, requested_until, reason, incident_id, approved_by
  FROM admission_identity_recovery_authorizations
 WHERE provider_id = ?
   AND consumed_at IS NULL
   AND cancelled_at IS NULL`, authorization.ProviderID).Scan(
			&canonical.PendingID, &canonical.ProviderID,
			&canonical.CandidatePublicKeySHA256,
			&canonical.ExpectedCurrentPublicKeySHA256,
			&canonical.ExpectedGeneration, &canonical.RequestedBy,
			&requestedUntilText, &canonical.Reason, &canonical.IncidentID,
			&approvedBy,
		)
		if err == nil {
			canonical.RequestedUntil = parseTimeOrZero(requestedUntilText)
			if approvedBy.Valid {
				canonical.ApprovedBy = approvedBy.String
			}
			if sameAdmissionIdentityRecoveryRequest(canonical, authorization) {
				return nil
			}
			return ErrAdmissionIdentityRecoveryCommitted
		}
		if err != sql.ErrNoRows {
			return err
		}

		_, err = conn.ExecContext(ctx, `
INSERT INTO admission_identity_recovery_authorizations (
    pending_id, provider_id, candidate_public_key_sha256,
    expected_current_public_key_sha256, expected_generation,
    requested_by, requested_until, reason, incident_id, created_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			authorization.PendingID, authorization.ProviderID,
			authorization.CandidatePublicKeySHA256,
			authorization.ExpectedCurrentPublicKeySHA256,
			authorization.ExpectedGeneration, authorization.RequestedBy,
			timeText(authorization.RequestedUntil), authorization.Reason,
			authorization.IncidentID, timeText(now))
		if err != nil && isConstraintFailure(err) {
			return ErrAdmissionIdentityRecoveryCommitted
		}
		if err == nil {
			canonical = authorization
			canonical.RequestedUntil = parseTimeOrZero(timeText(authorization.RequestedUntil))
		}
		return err
	})
	if err != nil {
		return AdmissionIdentityRecoveryAuthorization{}, err
	}
	return canonical, nil
}

func sameAdmissionIdentityRecoveryRequest(
	left, right AdmissionIdentityRecoveryAuthorization,
) bool {
	// pending_id is coordinator-generated response state. Every field bound to
	// the operator request and current identity authority must still match.
	return left.ProviderID == right.ProviderID &&
		left.CandidatePublicKeySHA256 == right.CandidatePublicKeySHA256 &&
		left.ExpectedCurrentPublicKeySHA256 == right.ExpectedCurrentPublicKeySHA256 &&
		left.ExpectedGeneration == right.ExpectedGeneration &&
		left.RequestedBy == right.RequestedBy &&
		timeText(left.RequestedUntil) == timeText(right.RequestedUntil) &&
		left.Reason == right.Reason &&
		left.IncidentID == right.IncidentID
}

func (s *Store) ApproveAdmissionIdentityRecovery(
	ctx context.Context,
	pendingID, approvedBy string,
	now time.Time,
) (AdmissionIdentityRecoveryAuthorization, error) {
	pendingID = strings.TrimSpace(pendingID)
	approvedBy = strings.TrimSpace(approvedBy)
	if pendingID == "" || len(pendingID) > 128 || !validRecoveryOperatorActor(approvedBy) {
		return AdmissionIdentityRecoveryAuthorization{}, ErrAdmissionIdentityRecoveryMismatch
	}
	if now.IsZero() {
		now = time.Now().UTC()
	} else {
		now = now.UTC()
	}
	var result AdmissionIdentityRecoveryAuthorization
	var decisionErr error
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var requestedUntilText string
		var existingApprovedBy, approvedAt, consumedAt, cancelledAt sql.NullString
		err := conn.QueryRowContext(ctx, `
SELECT pending_id, provider_id, candidate_public_key_sha256,
       expected_current_public_key_sha256, expected_generation,
       requested_by, requested_until, reason, incident_id,
       approved_by, approved_at, consumed_at, cancelled_at
  FROM admission_identity_recovery_authorizations
 WHERE pending_id = ?`, pendingID).Scan(
			&result.PendingID, &result.ProviderID,
			&result.CandidatePublicKeySHA256,
			&result.ExpectedCurrentPublicKeySHA256,
			&result.ExpectedGeneration, &result.RequestedBy,
			&requestedUntilText, &result.Reason, &result.IncidentID,
			&existingApprovedBy, &approvedAt, &consumedAt, &cancelledAt,
		)
		if err == sql.ErrNoRows {
			decisionErr = ErrAdmissionIdentityRecoveryNotFound
			return nil
		}
		if err != nil {
			return err
		}
		result.RequestedUntil = parseTimeOrZero(requestedUntilText)
		if existingApprovedBy.Valid || approvedAt.Valid || consumedAt.Valid || cancelledAt.Valid {
			decisionErr = ErrAdmissionIdentityRecoveryCommitted
			return nil
		}
		if result.RequestedBy == approvedBy {
			decisionErr = ErrAdmissionIdentityRecoveryDualControl
			return nil
		}
		if !result.RequestedUntil.After(now) {
			decisionErr = ErrAdmissionIdentityRecoveryMismatch
			return nil
		}
		res, err := conn.ExecContext(ctx, `
UPDATE admission_identity_recovery_authorizations
   SET approved_by = ?, approved_at = ?
 WHERE pending_id = ?
   AND approved_at IS NULL
   AND consumed_at IS NULL
   AND cancelled_at IS NULL`, approvedBy, timeText(now), pendingID)
		if err != nil {
			return err
		}
		rows, err := res.RowsAffected()
		if err != nil {
			return err
		}
		if rows != 1 {
			decisionErr = ErrAdmissionIdentityRecoveryCommitted
			return nil
		}
		result.ApprovedBy = approvedBy
		return nil
	})
	if err != nil {
		return AdmissionIdentityRecoveryAuthorization{}, err
	}
	if decisionErr != nil {
		return AdmissionIdentityRecoveryAuthorization{}, decisionErr
	}
	return result, nil
}

func validateAdmissionIdentityRecoveryAuthorization(authorization AdmissionIdentityRecoveryAuthorization, approved bool) error {
	if err := config.ValidateProviderID(strings.TrimSpace(authorization.ProviderID)); err != nil {
		return err
	}
	if strings.TrimSpace(authorization.PendingID) == "" || len(authorization.PendingID) > 128 ||
		!validRecoveryDigest(authorization.CandidatePublicKeySHA256) ||
		!validRecoveryDigest(authorization.ExpectedCurrentPublicKeySHA256) ||
		authorization.CandidatePublicKeySHA256 == authorization.ExpectedCurrentPublicKeySHA256 ||
		authorization.ExpectedGeneration < 1 ||
		!validRecoveryOperatorActor(authorization.RequestedBy) ||
		strings.TrimSpace(authorization.Reason) == "" || len(authorization.Reason) > 2048 ||
		strings.TrimSpace(authorization.IncidentID) == "" || len(authorization.IncidentID) > 256 {
		return ErrAdmissionIdentityRecoveryMismatch
	}
	if approved && !validRecoveryOperatorActor(authorization.ApprovedBy) {
		return ErrAdmissionIdentityRecoveryMismatch
	}
	return nil
}

func validRecoveryDigest(value string) bool {
	if len(value) != sha256.Size*2 || value != strings.ToLower(value) {
		return false
	}
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == sha256.Size
}

func validRecoveryOperatorActor(value string) bool {
	value = strings.TrimSpace(value)
	return strings.HasPrefix(value, "operator:") &&
		strings.TrimSpace(strings.TrimPrefix(value, "operator:")) != "" &&
		!strings.ContainsAny(value, " \t\r\n") && len(value) <= 256
}

// RecoverAdmissionIdentity atomically consumes the exact one-shot operator
// approval while replacing the durable key generation and writing its audit
// row. The WS layer has already verified the active bearer and possession of
// next. A stale key, generation, candidate, expired approval, or replay rolls
// the whole SQLite transaction back without changing authority.
func (s *Store) RecoverAdmissionIdentity(
	ctx context.Context,
	providerID, bearer string,
	expectedCurrent, next []byte,
	expectedGeneration int,
	now time.Time,
) (AdmissionIdentityState, AdmissionIdentityRecoveryAuthorization, error) {
	if err := config.ValidateProviderID(providerID); err != nil {
		return AdmissionIdentityState{}, AdmissionIdentityRecoveryAuthorization{}, err
	}
	bearer = strings.TrimSpace(bearer)
	if bearer == "" {
		return AdmissionIdentityState{}, AdmissionIdentityRecoveryAuthorization{}, ErrAdmissionIdentityBearerMismatch
	}
	if len(expectedCurrent) != ed25519.PublicKeySize || len(next) != ed25519.PublicKeySize {
		return AdmissionIdentityState{}, AdmissionIdentityRecoveryAuthorization{}, fmt.Errorf("admission identity recovery keys must be %d bytes", ed25519.PublicKeySize)
	}
	if bytes.Equal(expectedCurrent, next) || expectedGeneration < 1 {
		return AdmissionIdentityState{}, AdmissionIdentityRecoveryAuthorization{}, ErrAdmissionIdentityRecoveryMismatch
	}
	if now.IsZero() {
		now = time.Now().UTC()
	} else {
		now = now.UTC()
	}
	priorDigest := sha256.Sum256(expectedCurrent)
	newDigest := sha256.Sum256(next)
	priorDigestText := hex.EncodeToString(priorDigest[:])
	newDigestText := hex.EncodeToString(newDigest[:])

	var result AdmissionIdentityState
	var authorization AdmissionIdentityRecoveryAuthorization
	var decisionErr error
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var tokenProviderID string
		var bootstrapIssued int
		var bootstrapExpiresAt, lastUsedAt sql.NullString
		if err := conn.QueryRowContext(ctx, `
SELECT provider_id, bootstrap_issued, bootstrap_expires_at, last_used_at
  FROM provider_tokens
 WHERE token_hash = ? AND revoked_at IS NULL AND provider_id <> ''`, tokenHash(bearer)).
			Scan(&tokenProviderID, &bootstrapIssued, &bootstrapExpiresAt, &lastUsedAt); err != nil {
			if err == sql.ErrNoRows {
				decisionErr = ErrAdmissionIdentityBearerMismatch
				return nil
			}
			return err
		}
		if tokenProviderID != providerID {
			decisionErr = ErrAdmissionIdentityBearerMismatch
			return nil
		}
		if bootstrapIssued == 1 && !lastUsedAt.Valid {
			expiresAt, parseErr := time.Parse(time.RFC3339, bootstrapExpiresAt.String)
			if !bootstrapExpiresAt.Valid || parseErr != nil || !expiresAt.After(now) {
				decisionErr = ErrAdmissionIdentityBearerMismatch
				return nil
			}
		}

		var requestedUntilText string
		if err := conn.QueryRowContext(ctx, `
SELECT pending_id, provider_id, candidate_public_key_sha256,
       expected_current_public_key_sha256, expected_generation,
       requested_by, approved_by, requested_until, reason, incident_id
  FROM admission_identity_recovery_authorizations
 WHERE provider_id = ?
   AND candidate_public_key_sha256 = ?
   AND expected_current_public_key_sha256 = ?
   AND expected_generation = ?
   AND approved_at IS NOT NULL
   AND consumed_at IS NULL
   AND cancelled_at IS NULL
   AND requested_until > ?`,
			providerID, newDigestText, priorDigestText, expectedGeneration, timeText(now)).Scan(
			&authorization.PendingID, &authorization.ProviderID,
			&authorization.CandidatePublicKeySHA256,
			&authorization.ExpectedCurrentPublicKeySHA256,
			&authorization.ExpectedGeneration, &authorization.RequestedBy,
			&authorization.ApprovedBy, &requestedUntilText,
			&authorization.Reason, &authorization.IncidentID,
		); err != nil {
			if err == sql.ErrNoRows {
				decisionErr = ErrAdmissionIdentityRecoveryMismatch
				return nil
			}
			return err
		}
		authorization.RequestedUntil = parseTimeOrZero(requestedUntilText)
		if err := validateAdmissionIdentityRecoveryAuthorization(authorization, true); err != nil ||
			!authorization.RequestedUntil.After(now) {
			decisionErr = ErrAdmissionIdentityRecoveryMismatch
			return nil
		}

		var stored []byte
		var generation int
		var confirmedAt, operatorRevokedAt sql.NullString
		lookupErr := conn.QueryRowContext(ctx, `
SELECT receipt_pubkey, identity_generation, confirmed_at, operator_revoked_at
  FROM provider_bootstrap_identities
 WHERE provider_id = ?`, providerID).Scan(&stored, &generation, &confirmedAt, &operatorRevokedAt)
		if lookupErr != nil && lookupErr != sql.ErrNoRows {
			return lookupErr
		}
		if lookupErr == nil {
			if operatorRevokedAt.Valid || !confirmedAt.Valid {
				decisionErr = ErrAdmissionIdentityRecoveryMismatch
				return nil
			}
			if !bytes.Equal(stored, expectedCurrent) || generation != expectedGeneration {
				decisionErr = ErrAdmissionIdentityRecoveryMismatch
				return nil
			}
			res, err := conn.ExecContext(ctx, `
UPDATE provider_bootstrap_identities
   SET receipt_pubkey = ?,
       identity_generation = identity_generation + 1,
       previous_receipt_pubkey = NULL,
       previous_valid_until = NULL,
       rotated_at = ?
 WHERE provider_id = ?
   AND operator_revoked_at IS NULL
   AND receipt_pubkey = ?
   AND identity_generation = ?`,
				append([]byte(nil), next...), timeText(now), providerID,
				append([]byte(nil), expectedCurrent...), expectedGeneration)
			if err != nil {
				if isConstraintFailure(err) {
					decisionErr = ErrAdmissionIdentityRecoveryMismatch
					return nil
				}
				return err
			}
			rows, err := res.RowsAffected()
			if err != nil {
				return err
			}
			if rows != 1 {
				decisionErr = ErrAdmissionIdentityRecoveryMismatch
				return nil
			}
		} else {
			// Migration from an external App/Postgres identity has no SQLite
			// admission row yet. The WS verifier supplied that authoritative
			// expectedCurrent after validating the operator recovery policy.
			_, err := conn.ExecContext(ctx, `
INSERT INTO provider_bootstrap_identities (
    provider_id, receipt_pubkey, identity_generation, created_at,
    confirmed_at, expires_at, rotated_at
) VALUES (?, ?, ?, ?, ?, NULL, ?)`,
				providerID, append([]byte(nil), next...), expectedGeneration+1,
				timeText(now), timeText(now), timeText(now))
			if err != nil {
				if isConstraintFailure(err) {
					decisionErr = ErrAdmissionIdentityRecoveryMismatch
					return nil
				}
				return err
			}
		}

		consume, err := conn.ExecContext(ctx, `
UPDATE admission_identity_recovery_authorizations
   SET consumed_at = ?
 WHERE pending_id = ?
   AND consumed_at IS NULL
   AND cancelled_at IS NULL`, timeText(now), authorization.PendingID)
		if err != nil {
			return err
		}
		consumedRows, err := consume.RowsAffected()
		if err != nil {
			return err
		}
		if consumedRows != 1 {
			return ErrAdmissionIdentityRecoveryMismatch
		}
		if _, err := conn.ExecContext(ctx, `
INSERT INTO admission_identity_recovery_audit (
    provider_id, prior_generation, new_generation,
    prior_public_key_sha256, new_public_key_sha256, granted_by,
    recovery_authorization_id, incident_id, recovered_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			providerID, expectedGeneration, expectedGeneration+1,
			priorDigestText, newDigestText, authorization.ApprovedBy,
			authorization.PendingID, authorization.IncidentID, timeText(now)); err != nil {
			if isConstraintFailure(err) {
				return ErrAdmissionIdentityRecoveryMismatch
			}
			return err
		}
		result = AdmissionIdentityState{
			CurrentPublicKey: append([]byte(nil), next...),
			Generation:       expectedGeneration + 1,
		}
		return nil
	})
	if err != nil {
		return AdmissionIdentityState{}, AdmissionIdentityRecoveryAuthorization{}, err
	}
	if decisionErr != nil {
		return AdmissionIdentityState{}, AdmissionIdentityRecoveryAuthorization{}, decisionErr
	}
	return result, authorization, nil
}

func admissionIdentityStateFromStored(current []byte, generation int, previous []byte, previousValidUntil sql.NullString, now time.Time) AdmissionIdentityState {
	state := AdmissionIdentityState{
		CurrentPublicKey: append([]byte(nil), current...),
		Generation:       generation,
	}
	if !previousValidUntil.Valid {
		return state
	}
	validUntil, err := time.Parse(time.RFC3339, previousValidUntil.String)
	if err == nil {
		validUntil = validUntil.UTC()
		state.PreviousValidUntil = &validUntil
		if len(previous) == ed25519.PublicKeySize && validUntil.After(now) {
			state.PreviousPublicKey = append([]byte(nil), previous...)
		}
	}
	return state
}

func (s *Store) MarkTokenUsed(ctx context.Context, token string) error {
	if token == "" {
		return fmt.Errorf("token is required")
	}
	_, ok, err := s.validateAndMaybeConfirmToken(ctx, token, true)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("no active token found")
	}
	return nil
}

// ValidateAndMarkTokenUsed validates a bearer and stamps ordinary or already
// confirmed credentials under one BEGIN IMMEDIATE transaction. A fresh
// bootstrap bearer is deliberately left unconsumed: the WS admission path must
// call MarkTokenUsed only after provider-ID binding and every hello/evidence/
// admission check has succeeded, and before registration or an accepted
// response. Until that boundary, failed sessions remain reclaimable and
// bounded by the bootstrap TTL. Expired unused bootstrap bearers are revoked
// atomically here.
//
// Callers SHOULD use this instead of `ValidateToken` for any WS-connect
// validation; legacy `ValidateToken` is retained for read-only paths
// that don't need to record use (operator tooling, status checks).
func (s *Store) ValidateAndMarkTokenUsed(ctx context.Context, token string) (string, bool, error) {
	return s.validateAndMaybeConfirmToken(ctx, token, false)
}

func (s *Store) validateAndMaybeConfirmToken(ctx context.Context, token string, confirmBootstrap bool) (string, bool, error) {
	if token == "" {
		return "", false, nil
	}
	hash := tokenHash(token)
	var providerID string
	valid := false
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var id int64
		var bootstrapIssued int
		var bootstrapExpiresAt, lastUsedAt sql.NullString
		err := conn.QueryRowContext(ctx, `
SELECT id, provider_id, bootstrap_issued, bootstrap_expires_at, last_used_at
  FROM provider_tokens
 WHERE token_hash = ? AND revoked_at IS NULL AND provider_id <> ''`, hash).
			Scan(&id, &providerID, &bootstrapIssued, &bootstrapExpiresAt, &lastUsedAt)
		if err == sql.ErrNoRows {
			return nil
		}
		if err != nil {
			return err
		}

		now := time.Now().UTC()
		nowText := timeText(now)
		if bootstrapIssued == 1 && !lastUsedAt.Valid {
			expiresAt, parseErr := time.Parse(time.RFC3339, bootstrapExpiresAt.String)
			if !bootstrapExpiresAt.Valid || parseErr != nil || !expiresAt.After(now) {
				if _, err := conn.ExecContext(ctx, `
UPDATE provider_tokens
   SET revoked_at = ?
 WHERE id = ? AND revoked_at IS NULL AND last_used_at IS NULL`, nowText, id); err != nil {
					return err
				}
				return nil
			}
			if !confirmBootstrap {
				valid = true
				return nil
			}
		}

		res, err := conn.ExecContext(ctx, `
UPDATE provider_tokens
   SET last_used_at = ?
 WHERE id = ? AND revoked_at IS NULL`, nowText, id)
		if err != nil {
			return err
		}
		affected, err := res.RowsAffected()
		if err != nil {
			return err
		}
		if affected != 1 {
			return nil
		}
		if bootstrapIssued == 1 && !lastUsedAt.Valid {
			res, err := conn.ExecContext(ctx, `
UPDATE provider_bootstrap_identities
   SET confirmed_at = COALESCE(confirmed_at, ?), expires_at = NULL
 WHERE provider_id = ?`, nowText, providerID)
			if err != nil {
				return err
			}
			confirmed, err := res.RowsAffected()
			if err != nil {
				return err
			}
			if confirmed != 1 {
				return fmt.Errorf("bootstrap identity missing for provider %q", providerID)
			}
		}
		valid = true
		return nil
	})
	if err != nil {
		return "", false, err
	}
	if !valid {
		return "", false, nil
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
	var revokedID int64
	var decisionErr error
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		rows, err := conn.QueryContext(ctx, `
SELECT id, provider_id, bootstrap_issued
  FROM provider_tokens
 WHERE substr(token_prefix, 1, ?) = ? AND revoked_at IS NULL
 LIMIT 2`, len(prefix), prefix)
		if err != nil {
			return err
		}
		defer rows.Close()
		type candidate struct {
			id              int64
			providerID      string
			bootstrapIssued int
		}
		var candidates []candidate
		for rows.Next() {
			var item candidate
			if err := rows.Scan(&item.id, &item.providerID, &item.bootstrapIssued); err != nil {
				return err
			}
			candidates = append(candidates, item)
		}
		if err := rows.Err(); err != nil {
			return err
		}
		if err := rows.Close(); err != nil {
			return err
		}
		if len(candidates) == 0 {
			decisionErr = fmt.Errorf("no active token found for prefix %s", prefix)
			return nil
		}
		if len(candidates) > 1 {
			decisionErr = fmt.Errorf("ambiguous active token prefix %s", prefix)
			return nil
		}
		item := candidates[0]
		revokedAt := nowString()
		res, err := conn.ExecContext(ctx, `
UPDATE provider_tokens SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL`, revokedAt, item.id)
		if err != nil {
			return err
		}
		affected, err := res.RowsAffected()
		if err != nil {
			return err
		}
		if affected != 1 {
			decisionErr = fmt.Errorf("no active token found for prefix %s", prefix)
			return nil
		}
		if item.bootstrapIssued == 1 {
			if _, err := conn.ExecContext(ctx, `
UPDATE provider_bootstrap_identities
   SET operator_revoked_at = COALESCE(operator_revoked_at, ?)
 WHERE provider_id = ?`, revokedAt, item.providerID); err != nil {
				return err
			}
		}
		revokedID = item.id
		return nil
	})
	if err != nil {
		return TokenRecord{}, err
	}
	if decisionErr != nil {
		return TokenRecord{}, decisionErr
	}
	return s.tokenByID(ctx, revokedID)
}

// RevokeBootstrapIdentity is the operator escape hatch for an installer
// identity whose provisional token has already expired or been collected.
// The durable tombstone prevents future same-key recovery, while excluding the
// reviewed identity from the bounded unconfirmed queue. Any still-active
// bootstrap bearer is revoked in the same transaction.
func (s *Store) RevokeBootstrapIdentity(ctx context.Context, providerID string) error {
	if err := config.ValidateProviderID(providerID); err != nil {
		return err
	}
	if !IsCredentialBootstrapPrincipal(providerID) {
		return ErrBootstrapIdentityMismatch
	}
	nowText := nowString()
	var decisionErr error
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var exists int
		if err := conn.QueryRowContext(ctx, `
SELECT EXISTS(
    SELECT 1 FROM provider_bootstrap_identities WHERE provider_id = ?
)`, providerID).Scan(&exists); err != nil {
			return err
		}
		if exists != 1 {
			decisionErr = fmt.Errorf("bootstrap identity not found for provider %q", providerID)
			return nil
		}
		if _, err := conn.ExecContext(ctx, `
UPDATE provider_bootstrap_identities
   SET operator_revoked_at = COALESCE(operator_revoked_at, ?)
 WHERE provider_id = ?`, nowText, providerID); err != nil {
			return err
		}
		if _, err := conn.ExecContext(ctx, `
UPDATE provider_tokens
   SET revoked_at = COALESCE(revoked_at, ?)
 WHERE provider_id = ? AND bootstrap_issued = 1`, nowText, providerID); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		return err
	}
	return decisionErr
}

func (s *Store) ListBootstrapIdentities(ctx context.Context) ([]BootstrapIdentityRecord, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT provider_id, created_at, expires_at, confirmed_at, operator_revoked_at
  FROM provider_bootstrap_identities
 ORDER BY created_at, provider_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var records []BootstrapIdentityRecord
	for rows.Next() {
		var record BootstrapIdentityRecord
		if err := rows.Scan(
			&record.ProviderID,
			&record.CreatedAt,
			&record.ExpiresAt,
			&record.ConfirmedAt,
			&record.OperatorRevokedAt,
		); err != nil {
			return nil, err
		}
		records = append(records, record)
	}
	return records, rows.Err()
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
	return s.CreateOAuthStateBound(ctx, state, returnTo, pendingPairOT, "", now)
}

func (s *Store) CreateOAuthStateBound(ctx context.Context, state, returnTo string, pendingPairOT *string, originHash string, now time.Time) error {
	if state == "" || returnTo == "" {
		return fmt.Errorf("oauth state and return_to are required")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var pending any
	if pendingPairOT != nil {
		pending = *pendingPairOT
	}
	var origin any
	if originHash != "" {
		origin = originHash
		if _, err := tx.ExecContext(ctx, `DELETE FROM oauth_states WHERE expires_at <= ?`, timeText(now)); err != nil {
			return err
		}
		var active int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM oauth_states WHERE origin_hash = ? AND created_at > ?`, originHash, timeText(now.Add(-10*time.Minute))).Scan(&active); err != nil {
			return err
		}
		if active >= 20 {
			return ErrOAuthStateRateLimited
		}
	}
	if _, err := tx.ExecContext(ctx, `
INSERT INTO oauth_states (state, return_to, pending_pair_ot, origin_hash, expires_at, created_at)
VALUES (?, ?, ?, ?, ?, ?)`,
		state, returnTo, pending, origin, timeText(now.Add(10*time.Minute)), timeText(now)); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) ConsumeOAuthState(ctx context.Context, state string, now time.Time) (OAuthState, bool, error) {
	return s.ConsumeOAuthStateBound(ctx, state, "", now)
}

func (s *Store) ConsumeOAuthStateBound(ctx context.Context, state, originHash string, now time.Time) (OAuthState, bool, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return OAuthState{}, false, err
	}
	defer tx.Rollback()
	var out OAuthState
	query := `
DELETE FROM oauth_states
 WHERE state = ? AND expires_at > ?
RETURNING return_to, pending_pair_ot, expires_at, origin_hash`
	args := []any{state, timeText(now)}
	if originHash != "" {
		query = `
DELETE FROM oauth_states
 WHERE state = ? AND expires_at > ? AND (origin_hash = ? OR origin_hash IS NULL OR origin_hash = '')
RETURNING return_to, pending_pair_ot, expires_at, origin_hash`
		args = append(args, originHash)
	}
	err = tx.QueryRowContext(ctx, query, args...).Scan(&out.ReturnTo, &out.PendingPairOT, &out.ExpiresAt, &out.OriginHash)
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
	return s.mintAdmissionTokenAndPairOT(ctx, providerID, providerName, now, "", ReferralPolicy{})
}

func (s *Store) MintAdmissionTokenAndPairOTWithReferral(ctx context.Context, providerID, providerName string, now time.Time, referralCode string, policy ReferralPolicy) (AdmissionPairMint, error) {
	return s.mintAdmissionTokenAndPairOT(ctx, providerID, providerName, now, referralCode, policy)
}

func (s *Store) mintAdmissionTokenAndPairOT(ctx context.Context, providerID, providerName string, now time.Time, referralCode string, policy ReferralPolicy) (AdmissionPairMint, error) {
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
	hash := tokenHash(providerToken)
	prefix := providerToken[:tokenDisplayPrefixLength]
	nowText := timeText(now)
	var out AdmissionPairMint
	err = sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		if IsCredentialBootstrapPrincipal(providerID) {
			var bootstrapIdentityExists int
			if err := conn.QueryRowContext(ctx, `
SELECT EXISTS(
    SELECT 1 FROM provider_bootstrap_identities WHERE provider_id = ?
)`, providerID).Scan(&bootstrapIdentityExists); err != nil {
				return err
			}
			if bootstrapIdentityExists == 1 {
				return ErrBootstrapIdentityExists
			}
		}
		if _, err := redeemReferralTx(ctx, conn, policy, referralCode, providerID, now); err != nil {
			return err
		}
		res, err := conn.ExecContext(ctx, `INSERT INTO provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at) VALUES (?, ?, ?, ?, ?)`, hash, prefix, providerID, providerName, nowText)
		if err != nil {
			if isActiveProviderTokenConstraintFailure(err) {
				return ErrActiveTokenAlreadyExists
			}
			return err
		}
		id, err := res.LastInsertId()
		if err != nil {
			return err
		}
		var owned int
		if err := conn.QueryRowContext(ctx, `SELECT COUNT(1) FROM provider_ownership WHERE provider_id = ?`, providerID).Scan(&owned); err != nil {
			return err
		}
		out = AdmissionPairMint{
			TokenRecord:   TokenRecord{ID: id, TokenPrefix: prefix, ProviderID: providerID, ProviderName: providerName, CreatedAt: nowText},
			ProviderToken: providerToken,
		}
		if owned == 0 {
			out.PairOT = pairOT
			out.ExpiresAt = now.Add(10 * time.Minute).UTC()
			out.Paired = true
			if _, err := conn.ExecContext(ctx, `INSERT INTO pair_ots (id, provider_id, expires_at, created_at) VALUES (?, ?, ?, ?)`, pairOT, providerID, timeText(out.ExpiresAt), nowText); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
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
	var result PairOTRefreshResult
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		rows, err := conn.QueryContext(ctx, `SELECT ts FROM pair_ot_mint_log WHERE provider_id = ? AND outcome = 200 AND ts >= ? ORDER BY ts ASC`, providerID, timeText(now.Add(-time.Hour)))
		if err != nil {
			return err
		}
		count := 0
		var oldest sql.NullString
		for rows.Next() {
			var ts string
			if err := rows.Scan(&ts); err != nil {
				rows.Close()
				return err
			}
			if count == 0 {
				oldest = sql.NullString{String: ts, Valid: true}
			}
			count++
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return err
		}
		rows.Close()

		if count >= 5 {
			if _, err := conn.ExecContext(ctx, `INSERT INTO pair_ot_mint_log (provider_id, source_ip, user_agent, outcome, ts) VALUES (?, ?, ?, ?, ?)`,
				providerID, nullString(sourceIP), nullString(userAgent), http.StatusTooManyRequests, timeText(now)); err != nil {
				return err
			}
			result = PairOTRefreshResult{RetryAfter: retryAfterSeconds(oldest, now), RateLimited: true}
			return nil
		}

		pairOT, err := randomHex(32)
		if err != nil {
			return err
		}
		expires := now.Add(10 * time.Minute).UTC()
		if _, err := conn.ExecContext(ctx, `INSERT INTO pair_ots (id, provider_id, expires_at, created_at) VALUES (?, ?, ?, ?)`, pairOT, providerID, timeText(expires), timeText(now)); err != nil {
			return err
		}
		if _, err := conn.ExecContext(ctx, `INSERT INTO pair_ot_mint_log (provider_id, source_ip, user_agent, outcome, ts) VALUES (?, ?, ?, ?, ?)`,
			providerID, nullString(sourceIP), nullString(userAgent), http.StatusOK, timeText(now)); err != nil {
			return err
		}
		result = PairOTRefreshResult{Mint: PairOTMint{PairOT: pairOT, ExpiresAt: expires}}
		return nil
	})
	if err != nil {
		return PairOTRefreshResult{}, err
	}
	return result, nil
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

func isConstraintFailure(err error) bool {
	return err != nil && strings.Contains(err.Error(), "constraint failed")
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
