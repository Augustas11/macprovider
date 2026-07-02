package sqlite

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
	_ "modernc.org/sqlite"
)

type Store struct {
	db *sql.DB
}

var (
	_ storage.AuthStore     = (*Store)(nil)
	_ storage.AccountStore  = (*Store)(nil)
	_ storage.KeyStore      = (*Store)(nil)
	_ storage.UsageStore    = (*Store)(nil)
	_ storage.FeedbackStore = (*Store)(nil)
	_ storage.AuditStore    = (*Store)(nil)
	_ storage.CapacityStore = (*Store)(nil)
)

func Open(ctx context.Context, path string) (*Store, error) {
	if path == "" {
		return nil, fmt.Errorf("sqlite db path must be set")
	}
	db, err := sql.Open("sqlite", sqliteDSN(path))
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	if _, err := db.ExecContext(ctx, "PRAGMA busy_timeout = 5000; PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;"); err != nil {
		_ = db.Close()
		return nil, err
	}
	store := &Store{db: db}
	if err := store.Migrate(ctx); err != nil {
		_ = db.Close()
		return nil, err
	}
	return store, nil
}

// OpenReadOnly opens a SECOND handle to the same database file in
// read-only mode. M2-4 / PERF-4: the primary handle is capped at
// MaxOpenConns=1 to serialize BEGIN IMMEDIATE writes, which means a
// slow explorer query (e.g. `EXPLAIN`-unfriendly aggregate over
// usage_events) blocks ReserveQuota on the money path. A separate
// read-only handle with conn cap 4 leverages SQLite WAL's concurrent
// reader semantics so explorer/status/usage GETs no longer share a
// connection with writes.
//
// The caller is responsible for opening the writable Store first and
// running Migrate(): the read-only DSN cannot create or evolve schema.
func OpenReadOnly(ctx context.Context, path string) (*Store, error) {
	if path == "" {
		return nil, fmt.Errorf("sqlite db path must be set")
	}
	db, err := sql.Open("sqlite", sqliteReadOnlyDSN(path))
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(2)
	if err := db.PingContext(ctx); err != nil {
		_ = db.Close()
		return nil, err
	}
	return &Store{db: db}, nil
}

func (s *Store) Close() error {
	return s.db.Close()
}

func (s *Store) Ping(ctx context.Context) error {
	return s.db.PingContext(ctx)
}

// maxKnownSchemaVersion is the highest schema_migrations.version this
// binary understands. Version history:
//
//	v1 — original schema.
//	v2 — issue #196: usage_events PK (account_id, request_id).
//	v3 — issue #210: demo_usage_events PK (demo_token_hash, request_id).
//	v4 — issue #231: idx_quota_request + idx_concurrency_request so
//	     the §6.4 ambiguity probe stops full-scanning those tables.
//
// At Open time the store reads the current applied version; if it
// exceeds this constant the binary is older than the DB and refuses
// to start, preventing silent data hazards on rollback (e.g., a
// legacy `WHERE request_id = ?` lookup returning a wrong-identity
// row once cross-identity collisions exist).
//
// Operators rolling back the gateway binary on a DB at a higher
// version must restore /var/lib/macprovider/gateway.db from the
// pre-deploy snapshot (deploy-pearl-vps.sh step 5b writes one).
const maxKnownSchemaVersion = 4

func (s *Store) Migrate(ctx context.Context) error {
	if err := s.checkSchemaVersionGate(ctx); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx, schemaSQL); err != nil {
		return err
	}
	// usage_events table + auxiliary DDL (indexes + append-only
	// triggers) are kept in shared constants so the in-place upgrade
	// path (ensureUsageEventsCompositePK) creates them with identical
	// text, preserving sqlite_master byte-equality across fresh
	// installs and migrated DBs.
	if _, err := s.db.ExecContext(ctx, usageEventsTableDDL); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx, usageEventsAuxiliaryDDL); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx, demoUsageEventsTableDDL); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx, demoUsageEventsAuxiliaryDDL); err != nil {
		return err
	}
	if err := s.ensureOAuthStateActionColumn(ctx); err != nil {
		return err
	}
	if err := s.ensureUsageEventsCompositePK(ctx); err != nil {
		return err
	}
	if err := s.ensureDemoUsageEventsCompositePK(ctx); err != nil {
		return err
	}
	// Stamp the schema version. We always insert v1 (preserves
	// historical behavior for any tooling that checked exactly that
	// row) AND the post-#196 marker v2. INSERT OR IGNORE keeps it
	// idempotent on re-run.
	//
	// Note: ensureUsageEventsCompositePK ALSO stamps v2 inside its
	// rebuild transaction so the shape change and the version marker
	// commit atomically (ISS-196 R4 architect HIGH). The outer v2
	// insert here is the no-op repair path for new installs and for
	// DBs that came through Migrate without needing a rebuild.
	now := encodeTime(time.Now().UTC())
	if _, err := s.db.ExecContext(ctx, "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(1, ?)", now); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx, "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(2, ?)", now); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx, "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(3, ?)", now); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx, "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(4, ?)", now); err != nil {
		return err
	}
	return nil
}

// checkSchemaVersionGate refuses to run Migrate when the DB carries
// a schema version higher than this binary knows about. Protects
// against the silent-corruption rollback scenario flagged in the
// ISS-196 R1 architect HIGH finding: an older binary opening a
// DB that has already been migrated to a composite-PK shape would
// run the legacy `WHERE request_id = ?` query and risk returning
// a wrong-account row once cross-account request_id duplicates
// exist. Failing closed at Open is the safe choice.
func (s *Store) checkSchemaVersionGate(ctx context.Context) error {
	// schema_migrations may not exist yet on a brand-new DB; the
	// follow-up schemaSQL run creates it. Tolerate the missing-table
	// case here.
	var current sql.NullInt64
	err := s.db.QueryRowContext(ctx, `SELECT MAX(version) FROM schema_migrations`).Scan(&current)
	if err != nil {
		if strings.Contains(err.Error(), "no such table") {
			return nil
		}
		return err
	}
	if !current.Valid {
		return nil
	}
	if current.Int64 > maxKnownSchemaVersion {
		return fmt.Errorf("gateway DB schema_migrations.version=%d exceeds this binary's max-known version %d — refusing to open (issue #196 rollback safety). Restore from pre-deploy snapshot.",
			current.Int64, maxKnownSchemaVersion)
	}
	return nil
}

// ensureOAuthStateActionColumn handles upgrade-in-place for pre-existing
// gateway.db files that were created before `oauth_states.action` was added
// to schemaSQL. Mirrors phase4-coordinator/internal/auth/tokens.go's
// ensureProviderIDColumn — check PRAGMA table_info, ALTER TABLE if missing.
func (s *Store) ensureOAuthStateActionColumn(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(oauth_states)`)
	if err != nil {
		return err
	}
	defer rows.Close()
	hasAction := false
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull int
		var defaultValue sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
			return err
		}
		if name == "action" {
			hasAction = true
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if hasAction {
		return nil
	}
	_, err = s.db.ExecContext(ctx, `ALTER TABLE oauth_states ADD COLUMN action TEXT NOT NULL DEFAULT ''`)
	return err
}

// ensureUsageEventsCompositePK upgrades pre-issue-#196 gateway.db files
// whose `usage_events` table has PRIMARY KEY (request_id) — a global
// uniqueness constraint that lets a buyer with two accounts collide on
// the same X-Request-ID after streaming has flushed, escaping
// settlement. The fix is composite PK (account_id, request_id).
//
// New installs land on the composite PK directly via schemaSQL. Old
// installs need a table rebuild because SQLite cannot ALTER PRIMARY
// KEY in place. Detection: PRAGMA table_info pk-column count and
// names.
//
// The rebuild runs inside a single deferred-FK transaction so partial
// state cannot leak. The append-only DELETE/UPDATE triggers and the
// two secondary indexes ride along with the renamed table per SQLite
// ALTER TABLE RENAME semantics (verified against the SQLite docs);
// no manual recreate is needed.
func (s *Store) ensureUsageEventsCompositePK(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(usage_events)`)
	if err != nil {
		return err
	}
	type col struct {
		name string
		pk   int
	}
	var pkCols []col
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull int
		var defaultValue sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
			_ = rows.Close()
			return err
		}
		if pk > 0 {
			pkCols = append(pkCols, col{name: name, pk: pk})
		}
	}
	if err := rows.Close(); err != nil {
		return err
	}
	// Composite (account_id, request_id) — already migrated.
	if len(pkCols) == 2 &&
		((pkCols[0].name == "account_id" && pkCols[1].name == "request_id") ||
			(pkCols[0].name == "request_id" && pkCols[1].name == "account_id")) {
		return nil
	}
	// Anything other than the legacy single-column (request_id) PK is
	// an unrecognized shape — bail loudly rather than corrupt data.
	if !(len(pkCols) == 1 && pkCols[0].name == "request_id") {
		return fmt.Errorf("usage_events PK shape unrecognized: %+v", pkCols)
	}
	// Rebuild. PRAGMA foreign_keys is OFF for the duration so the
	// drop+rename does not trip cascading FK checks (usage_events is
	// not a FK target today, but defensive). Restored on exit.
	if _, err := s.db.ExecContext(ctx, `PRAGMA foreign_keys = OFF`); err != nil {
		return err
	}
	defer func() {
		_, _ = s.db.ExecContext(ctx, `PRAGMA foreign_keys = ON`)
	}()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	// Sequence: legacy → legacy_old (rename), then create the
	// canonical usage_events with the new PK using its REAL name
	// from the start. This keeps sqlite_master.sql for usage_events
	// byte-equal between fresh installs and migrated DBs (an
	// ALTER...RENAME would store `CREATE TABLE "usage_events"` with
	// quotes — caught by ISS-196 R2 architect MEDIUM).
	if _, err := tx.ExecContext(ctx, `ALTER TABLE usage_events RENAME TO usage_events_legacy`); err != nil {
		return fmt.Errorf("rename legacy usage_events aside: %w", err)
	}
	// Use the SAME usageEventsTableDDL the fresh-install path runs so
	// sqlite_master.sql for usage_events is byte-equal across paths.
	if _, err := tx.ExecContext(ctx, usageEventsTableDDL); err != nil {
		return fmt.Errorf("create new usage_events: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO usage_events
			(request_id, account_id, demo_identity, window_date,
			 prompt_tokens, completion_tokens, total_tokens,
			 token_source, outcome, created_at)
		SELECT request_id, account_id, demo_identity, window_date,
		       prompt_tokens, completion_tokens, total_tokens,
		       token_source, outcome, created_at
		FROM usage_events_legacy`); err != nil {
		return fmt.Errorf("copy usage_events rows: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `DROP TABLE usage_events_legacy`); err != nil {
		return fmt.Errorf("drop legacy usage_events table: %w", err)
	}
	// Recreate the secondary indexes and append-only triggers. DROP
	// TABLE removed them. The shared usageEventsAuxiliaryDDL constant
	// is the SAME text Migrate() executes on a fresh install, so the
	// post-migration sqlite_master entries are byte-for-byte identical
	// — addresses architect R1 MEDIUM finding.
	if _, err := tx.ExecContext(ctx, usageEventsAuxiliaryDDL); err != nil {
		return fmt.Errorf("recreate usage_events index/trigger: %w", err)
	}
	// Stamp schema_migrations version 2 inside the SAME transaction as
	// the rebuild. Without this atomicity, the rebuild could commit but
	// the version stamp could fail — leaving a composite-PK DB with no
	// v2 marker, which the next open (or an old binary) would treat as
	// v1 and proceed against a shape it doesn't understand. ISS-196 R4
	// architect HIGH.
	if _, err := tx.ExecContext(ctx,
		`INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(2, ?)`,
		encodeTime(time.Now().UTC())); err != nil {
		return fmt.Errorf("stamp schema_migrations v2 inside rebuild tx: %w", err)
	}
	return tx.Commit()
}

// ensureDemoUsageEventsCompositePK is the issue #210 sibling of
// ensureUsageEventsCompositePK. Migrates `demo_usage_events` from
// PRIMARY KEY (request_id) — pre-existing global uniqueness across
// all demo identities, exploitable when two demo_token_hash values
// collide on the same buyer-supplied X-Request-ID — to composite
// PRIMARY KEY (demo_token_hash, request_id).
//
// Same rebuild pattern as the v2 migration: detect legacy shape,
// rename-aside + create-canonical + copy + drop, stamp v3 inside
// the same transaction so the shape change and the version marker
// commit atomically.
func (s *Store) ensureDemoUsageEventsCompositePK(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(demo_usage_events)`)
	if err != nil {
		return err
	}
	type col struct {
		name string
		pk   int
	}
	var pkCols []col
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull int
		var defaultValue sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
			_ = rows.Close()
			return err
		}
		if pk > 0 {
			pkCols = append(pkCols, col{name: name, pk: pk})
		}
	}
	if err := rows.Close(); err != nil {
		return err
	}
	// Composite (demo_token_hash, request_id) — already migrated.
	if len(pkCols) == 2 &&
		((pkCols[0].name == "demo_token_hash" && pkCols[1].name == "request_id") ||
			(pkCols[0].name == "request_id" && pkCols[1].name == "demo_token_hash")) {
		return nil
	}
	if !(len(pkCols) == 1 && pkCols[0].name == "request_id") {
		return fmt.Errorf("demo_usage_events PK shape unrecognized: %+v", pkCols)
	}
	if _, err := s.db.ExecContext(ctx, `PRAGMA foreign_keys = OFF`); err != nil {
		return err
	}
	defer func() {
		_, _ = s.db.ExecContext(ctx, `PRAGMA foreign_keys = ON`)
	}()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `ALTER TABLE demo_usage_events RENAME TO demo_usage_events_legacy`); err != nil {
		return fmt.Errorf("rename legacy demo_usage_events aside: %w", err)
	}
	if _, err := tx.ExecContext(ctx, demoUsageEventsTableDDL); err != nil {
		return fmt.Errorf("create new demo_usage_events: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO demo_usage_events
			(request_id, client_ip, demo_token_hash, window_date, total_tokens, created_at)
		SELECT request_id, client_ip, demo_token_hash, window_date, total_tokens, created_at
		FROM demo_usage_events_legacy`); err != nil {
		return fmt.Errorf("copy demo_usage_events rows: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `DROP TABLE demo_usage_events_legacy`); err != nil {
		return fmt.Errorf("drop legacy demo_usage_events table: %w", err)
	}
	if _, err := tx.ExecContext(ctx, demoUsageEventsAuxiliaryDDL); err != nil {
		return fmt.Errorf("recreate demo_usage_events index/trigger: %w", err)
	}
	// Stamp v3 inside the same transaction — atomicity per ISS-196 R4.
	if _, err := tx.ExecContext(ctx,
		`INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(3, ?)`,
		encodeTime(time.Now().UTC())); err != nil {
		return fmt.Errorf("stamp schema_migrations v3 inside rebuild tx: %w", err)
	}
	return tx.Commit()
}

func (s *Store) CreateAccount(ctx context.Context, account storage.Account) error {
	if account.CreatedAt.IsZero() {
		account.CreatedAt = time.Now().UTC()
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO accounts(account_id, status, quota_class, concurrency_class, created_at)
		VALUES(?, ?, ?, ?, ?)`,
		account.AccountID, nonEmpty(account.Status, "active"), nonEmpty(account.QuotaClass, "default"),
		nonEmpty(account.ConcurrencyClass, "default"), encodeTime(account.CreatedAt))
	return err
}

func (s *Store) AddAccountIdentity(ctx context.Context, identity storage.AccountIdentity) error {
	if identity.CreatedAt.IsZero() {
		identity.CreatedAt = time.Now().UTC()
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO account_identities(account_id, provider, provider_user_id, email, created_at)
		VALUES(?, ?, ?, ?, ?)`,
		identity.AccountID, identity.Provider, identity.ProviderUserID, identity.Email, encodeTime(identity.CreatedAt))
	return err
}

func (s *Store) LookupAccountByIdentity(ctx context.Context, provider, providerUserID string) (storage.Account, error) {
	row := s.db.QueryRowContext(ctx, `
		SELECT a.account_id, a.status, a.quota_class, a.concurrency_class, a.created_at
		FROM account_identities i
		JOIN accounts a ON a.account_id = i.account_id
		WHERE i.provider = ? AND i.provider_user_id = ?`, provider, providerUserID)
	var account storage.Account
	var created string
	if err := row.Scan(&account.AccountID, &account.Status, &account.QuotaClass, &account.ConcurrencyClass, &created); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.Account{}, storage.ErrNotFound
		}
		return storage.Account{}, err
	}
	account.CreatedAt = decodeTime(created)
	return account, nil
}

func (s *Store) LookupAccount(ctx context.Context, accountID string) (storage.Account, error) {
	row := s.db.QueryRowContext(ctx, `
		SELECT account_id, status, quota_class, concurrency_class, created_at
		FROM accounts
		WHERE account_id = ?`, accountID)
	var account storage.Account
	var created string
	if err := row.Scan(&account.AccountID, &account.Status, &account.QuotaClass, &account.ConcurrencyClass, &created); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.Account{}, storage.ErrNotFound
		}
		return storage.Account{}, err
	}
	account.CreatedAt = decodeTime(created)
	return account, nil
}

func (s *Store) CreateAPIKey(ctx context.Context, key storage.APIKey) error {
	if key.CreatedAt.IsZero() {
		key.CreatedAt = time.Now().UTC()
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO api_keys(key_id, account_id, key_hash, key_hash_prefix, status, created_at)
		VALUES(?, ?, ?, ?, ?, ?)`,
		key.KeyID, key.AccountID, key.KeyHash, key.KeyHashPrefix, nonEmpty(key.Status, "active"), encodeTime(key.CreatedAt))
	return err
}

func (s *Store) ValidateAPIKeyHash(ctx context.Context, keyHash []byte) (storage.KeyValidation, error) {
	row := s.db.QueryRowContext(ctx, `
		SELECT k.key_id, k.account_id, k.status, k.key_hash_prefix, k.created_at,
		       a.status, a.quota_class, a.concurrency_class
		FROM api_keys k
		JOIN accounts a ON a.account_id = k.account_id
		WHERE k.key_hash = ?
		LIMIT 1`, keyHash)
	var validation storage.KeyValidation
	var created string
	if err := row.Scan(&validation.KeyID, &validation.AccountID, &validation.KeyStatus, &validation.KeyHashPrefix, &created, &validation.AccountStatus, &validation.QuotaClass, &validation.ConcurrencyClass); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.KeyValidation{}, storage.ErrNotFound
		}
		return storage.KeyValidation{}, err
	}
	validation.CreatedAt = decodeTime(created)
	validation.Active = validation.KeyStatus == "active" && validation.AccountStatus == "active"
	return validation, nil
}

func (s *Store) ListAPIKeys(ctx context.Context, accountID string) ([]storage.APIKeySummary, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT key_id, key_hash_prefix, status, created_at, revoked_at
		FROM api_keys
		WHERE account_id = ?
		ORDER BY created_at ASC`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var keys []storage.APIKeySummary
	for rows.Next() {
		var key storage.APIKeySummary
		var created string
		var revoked string
		if err := rows.Scan(&key.KeyID, &key.KeyHashPrefix, &key.Status, &created, &revoked); err != nil {
			return nil, err
		}
		key.CreatedAt = decodeTime(created)
		if revoked != "" {
			key.RevokedAt = decodeTime(revoked)
		}
		keys = append(keys, key)
	}
	return keys, rows.Err()
}

func (s *Store) RevokeAPIKey(ctx context.Context, keyID, actor, requestID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer rollback(tx)
	var accountID string
	if err := tx.QueryRowContext(ctx, `SELECT account_id FROM api_keys WHERE key_id = ?`, keyID).Scan(&accountID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.ErrNotFound
		}
		return err
	}
	now := encodeTime(time.Now().UTC())
	if _, err := tx.ExecContext(ctx, `UPDATE api_keys SET status = 'revoked', revoked_at = ? WHERE key_id = ?`, now, keyID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO api_key_events(key_id, account_id, request_id, event_type, actor, created_at)
		VALUES(?, ?, ?, 'revoked', ?, ?)`, keyID, accountID, requestID, actor, now); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) RevokeAPIKeyForAccount(ctx context.Context, accountID, keyID, actor, requestID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer rollback(tx)
	now := encodeTime(time.Now().UTC())
	res, err := tx.ExecContext(ctx, `UPDATE api_keys SET status = 'revoked', revoked_at = ? WHERE key_id = ? AND account_id = ?`, now, keyID, accountID)
	if err != nil {
		return err
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return storage.ErrNotFound
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO api_key_events(key_id, account_id, request_id, event_type, actor, created_at)
		VALUES(?, ?, ?, 'revoked', ?, ?)`, keyID, accountID, requestID, actor, now); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) RotateAPIKey(ctx context.Context, oldKeyID, accountID string, newKey storage.APIKey, actor, requestID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer rollback(tx)
	var existingAccountID string
	if err := tx.QueryRowContext(ctx, `SELECT account_id FROM api_keys WHERE key_id = ? AND account_id = ?`, oldKeyID, accountID).Scan(&existingAccountID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.ErrNotFound
		}
		return err
	}
	if newKey.CreatedAt.IsZero() {
		newKey.CreatedAt = time.Now().UTC()
	}
	newKey.AccountID = accountID
	now := encodeTime(time.Now().UTC())
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO api_keys(key_id, account_id, key_hash, key_hash_prefix, status, created_at)
		VALUES(?, ?, ?, ?, ?, ?)`,
		newKey.KeyID, accountID, newKey.KeyHash, newKey.KeyHashPrefix, nonEmpty(newKey.Status, "active"), encodeTime(newKey.CreatedAt)); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE api_keys SET status = 'revoked', revoked_at = ? WHERE key_id = ? AND account_id = ?`, now, oldKeyID, accountID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO api_key_events(key_id, account_id, request_id, event_type, actor, created_at)
		VALUES(?, ?, ?, 'rotated_from', ?, ?)`, oldKeyID, accountID, requestID, actor, now); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO api_key_events(key_id, account_id, request_id, event_type, actor, created_at)
		VALUES(?, ?, ?, 'rotated_to', ?, ?)`, newKey.KeyID, accountID, requestID, actor, now); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) StoreOAuthState(ctx context.Context, state storage.OAuthState) error {
	if state.CreatedAt.IsZero() {
		state.CreatedAt = time.Now().UTC()
	}
	if state.ExpiresAt.IsZero() {
		state.ExpiresAt = state.CreatedAt.Add(10 * time.Minute)
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO oauth_states(state_hash, session_id, redirect_uri, client_ip, created_at, expires_at, action)
		VALUES(?, ?, ?, ?, ?, ?, ?)`,
		state.StateHash, state.SessionID, state.RedirectURI, state.ClientIP,
		encodeTime(state.CreatedAt), encodeTime(state.ExpiresAt), state.Action)
	return err
}

func (s *Store) ConsumeOAuthState(ctx context.Context, stateHash []byte, sessionID string, now time.Time) (string, string, error) {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return "", "", err
	}
	defer tx.Rollback()
	var redirectURI string
	var expiresAt string
	var consumedAt string
	var action string
	if err := tx.QueryRowContext(ctx, `
		SELECT redirect_uri, expires_at, consumed_at, action
		FROM oauth_states
		WHERE state_hash = ? AND session_id = ?`,
		stateHash, sessionID).Scan(&redirectURI, &expiresAt, &consumedAt, &action); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", "", storage.ErrNotFound
		}
		return "", "", err
	}
	if consumedAt != "" || !now.Before(decodeTime(expiresAt)) {
		return "", "", storage.ErrNotFound
	}
	_, err = tx.ExecContext(ctx, `UPDATE oauth_states SET consumed_at = ? WHERE state_hash = ?`, encodeTime(now.UTC()), stateHash)
	if err != nil {
		return "", "", err
	}
	return redirectURI, action, tx.Commit()
}

func (s *Store) RecordSignupEvent(ctx context.Context, event storage.SignupEvent) error {
	if event.CreatedAt.IsZero() {
		event.CreatedAt = time.Now().UTC()
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO signup_events(event_id, account_id, client_ip, provider, created_at)
		VALUES(?, ?, ?, ?, ?)`, event.EventID, event.AccountID, event.ClientIP, event.Provider, encodeTime(event.CreatedAt))
	return err
}

func (s *Store) CountSignupEventsSince(ctx context.Context, clientIP string, since time.Time) (int, error) {
	var count int
	err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM signup_events
		WHERE client_ip = ? AND created_at >= ?`, clientIP, encodeTime(since)).Scan(&count)
	return count, err
}

func (s *Store) RecordDemoSessionEvent(ctx context.Context, event storage.DemoSessionEvent) error {
	if event.CreatedAt.IsZero() {
		event.CreatedAt = time.Now().UTC()
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO demo_session_events(event_id, client_ip, created_at)
		VALUES(?, ?, ?)`, event.EventID, event.ClientIP, encodeTime(event.CreatedAt))
	return err
}

func (s *Store) CountDemoSessionEventsSince(ctx context.Context, clientIP string, since time.Time) (int, error) {
	var count int
	err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM demo_session_events
		WHERE client_ip = ? AND created_at >= ?`, clientIP, encodeTime(since)).Scan(&count)
	return count, err
}

func (s *Store) ReserveQuota(ctx context.Context, req storage.ReservationRequest) (storage.QuotaDecision, error) {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return storage.QuotaDecision{}, err
	}
	defer tx.Rollback()
	if req.CreatedAt.IsZero() {
		req.CreatedAt = time.Now().UTC()
	}
	if _, err := reapExpiredReservationsTx(ctx, tx, req.CreatedAt); err != nil {
		return storage.QuotaDecision{}, err
	}
	used, reserved, err := dailyUsageTx(ctx, tx, req.AccountID, req.WindowDate)
	if err != nil {
		return storage.QuotaDecision{}, err
	}
	remaining := req.DailyQuota - used - reserved
	decision := storage.QuotaDecision{
		Admitted: false, LimitTokens: req.DailyQuota, UsedTokens: used, ReservedTokens: reserved,
		RemainingTokens: max64(0, remaining), ResetUnix: resetUnix(req.WindowDate),
	}
	if req.RequestedTokens > remaining {
		tx.Rollback() // read-only path; rollback is equivalent to commit here
		return decision, storage.ErrQuotaExceeded
	}
	if req.ExpiresAt.IsZero() {
		req.ExpiresAt = req.CreatedAt.Add(24 * time.Hour)
	}
	_, err = tx.ExecContext(ctx, `
		INSERT INTO quota_reservations(account_id, request_id, window_date, reserved_tokens, status, expires_at, created_at)
		VALUES(?, ?, ?, ?, 'active', ?, ?)`,
		req.AccountID, req.RequestID, req.WindowDate, req.RequestedTokens, encodeTime(req.ExpiresAt), encodeTime(req.CreatedAt))
	if err != nil {
		return storage.QuotaDecision{}, err
	}
	decision.Admitted = true
	decision.ReservedTokens += req.RequestedTokens
	decision.RemainingTokens = max64(0, remaining-req.RequestedTokens)
	return decision, tx.Commit()
}

func (s *Store) SettleReservation(ctx context.Context, settlement storage.ReservationSettlement) error {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var windowDate string
	var status string
	if err := tx.QueryRowContext(ctx, `
		SELECT window_date, status FROM quota_reservations
		WHERE account_id = ? AND request_id = ?`, settlement.AccountID, settlement.RequestID).Scan(&windowDate, &status); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.ErrReservationNotFound
		}
		return err
	}
	if status != "active" {
		return fmt.Errorf("reservation %s is %s", settlement.RequestID, status)
	}
	if settlement.SettledAt.IsZero() {
		settlement.SettledAt = time.Now().UTC()
	}
	if err := normalizeSettlementTokens(&settlement); err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `
		UPDATE quota_reservations
		SET status = 'settled', settled_tokens = ?, settled_at = ?
		WHERE account_id = ? AND request_id = ?`,
		settlement.TotalTokens, encodeTime(settlement.SettledAt), settlement.AccountID, settlement.RequestID)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `
		INSERT INTO usage_events(request_id, account_id, window_date, prompt_tokens, completion_tokens, total_tokens, token_source, outcome, created_at)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		settlement.RequestID, settlement.AccountID, windowDate, settlement.PromptTokens, settlement.CompletionTokens,
		settlement.TotalTokens, settlement.TokenSource, settlement.Outcome, encodeTime(settlement.SettledAt))
	if err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) SettleDemoReservation(ctx context.Context, settlement storage.ReservationSettlement, demo storage.DemoUsageEvent) error {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var windowDate string
	var status string
	if err := tx.QueryRowContext(ctx, `
		SELECT window_date, status FROM quota_reservations
		WHERE account_id = ? AND request_id = ?`, settlement.AccountID, settlement.RequestID).Scan(&windowDate, &status); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.ErrReservationNotFound
		}
		return err
	}
	if status != "active" {
		return fmt.Errorf("reservation %s is %s", settlement.RequestID, status)
	}
	if settlement.SettledAt.IsZero() {
		settlement.SettledAt = time.Now().UTC()
	}
	if err := normalizeSettlementTokens(&settlement); err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `
		UPDATE quota_reservations
		SET status = 'settled', settled_tokens = ?, settled_at = ?
		WHERE account_id = ? AND request_id = ?`,
		settlement.TotalTokens, encodeTime(settlement.SettledAt), settlement.AccountID, settlement.RequestID)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `
		INSERT INTO usage_events(request_id, account_id, demo_identity, window_date, prompt_tokens, completion_tokens, total_tokens, token_source, outcome, created_at)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		settlement.RequestID, settlement.AccountID, demo.ClientIP, windowDate, settlement.PromptTokens, settlement.CompletionTokens,
		settlement.TotalTokens, settlement.TokenSource, settlement.Outcome, encodeTime(settlement.SettledAt))
	if err != nil {
		return err
	}
	if demo.CreatedAt.IsZero() {
		demo.CreatedAt = settlement.SettledAt
	}
	if demo.WindowDate == "" {
		demo.WindowDate = windowDate
	}
	if demo.TotalTokens == 0 {
		demo.TotalTokens = settlement.TotalTokens
	}
	_, err = tx.ExecContext(ctx, `
		INSERT INTO demo_usage_events(request_id, client_ip, demo_token_hash, window_date, total_tokens, created_at)
		VALUES(?, ?, ?, ?, ?, ?)`,
		demo.RequestID, demo.ClientIP, demo.DemoTokenHash, demo.WindowDate, demo.TotalTokens, encodeTime(demo.CreatedAt))
	if err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) RefundReservation(ctx context.Context, accountID, requestID string, refundedAt int64) error {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	when := time.Unix(refundedAt, 0).UTC()
	res, err := tx.ExecContext(ctx, `
		UPDATE quota_reservations
		SET status = 'refunded', settled_tokens = 0, settled_at = ?
		WHERE account_id = ? AND request_id = ? AND status = 'active'`,
		encodeTime(when), accountID, requestID)
	if err != nil {
		return err
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return storage.ErrReservationNotFound
	}
	return tx.Commit()
}

func (s *Store) ClampReservationExpiry(ctx context.Context, accountID, requestID string, expiresAt time.Time) error {
	if expiresAt.IsZero() {
		return fmt.Errorf("reservation expiry cannot be zero")
	}
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	expiresAt = expiresAt.UTC()
	var rawExpiry string
	if err := tx.QueryRowContext(ctx, `
		SELECT expires_at FROM quota_reservations
		WHERE account_id = ? AND request_id = ? AND status = 'active'`,
		accountID, requestID).Scan(&rawExpiry); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.ErrReservationNotFound
		}
		return err
	}
	currentExpiry := decodeTime(rawExpiry)
	if currentExpiry.IsZero() {
		return fmt.Errorf("reservation %s expiry is invalid", requestID)
	}
	if !expiresAt.Before(currentExpiry) {
		return tx.Commit()
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE quota_reservations
		SET expires_at = ?
		WHERE account_id = ? AND request_id = ? AND status = 'active'`,
		encodeTime(expiresAt), accountID, requestID); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) AcquireConcurrency(ctx context.Context, req storage.ConcurrencyRequest) (storage.ConcurrencyDecision, error) {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return storage.ConcurrencyDecision{}, err
	}
	defer tx.Rollback()
	if req.CreatedAt.IsZero() {
		req.CreatedAt = time.Now().UTC()
	}
	if req.ExpiresAt.IsZero() {
		req.ExpiresAt = req.CreatedAt.Add(10 * time.Minute)
	}
	_, err = tx.ExecContext(ctx, `
		UPDATE concurrency_reservations
		SET status = 'expired', released_at = ?
		WHERE account_id = ? AND status = 'active' AND expires_at <= ?`,
		encodeTime(req.CreatedAt), req.AccountID, encodeTime(req.CreatedAt))
	if err != nil {
		return storage.ConcurrencyDecision{}, err
	}
	var active int
	if err := tx.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM concurrency_reservations
		WHERE account_id = ? AND status = 'active' AND expires_at > ?`,
		req.AccountID, encodeTime(req.CreatedAt)).Scan(&active); err != nil {
		return storage.ConcurrencyDecision{}, err
	}
	decision := storage.ConcurrencyDecision{Admitted: false, Limit: req.Limit, Active: active}
	if active >= req.Limit {
		if err := tx.Commit(); err != nil {
			return storage.ConcurrencyDecision{}, err
		}
		return decision, storage.ErrQuotaExceeded
	}
	_, err = tx.ExecContext(ctx, `
		INSERT INTO concurrency_reservations(account_id, request_id, status, expires_at, created_at)
		VALUES(?, ?, 'active', ?, ?)`,
		req.AccountID, req.RequestID, encodeTime(req.ExpiresAt), encodeTime(req.CreatedAt))
	if err != nil {
		return storage.ConcurrencyDecision{}, err
	}
	decision.Admitted = true
	decision.Active = active + 1
	return decision, tx.Commit()
}

func (s *Store) ReleaseConcurrency(ctx context.Context, accountID, requestID string, releasedAt time.Time) error {
	if releasedAt.IsZero() {
		releasedAt = time.Now().UTC()
	}
	_, err := s.db.ExecContext(ctx, `
		UPDATE concurrency_reservations
		SET status = 'released', released_at = ?
		WHERE account_id = ? AND request_id = ? AND status = 'active'`,
		encodeTime(releasedAt), accountID, requestID)
	return err
}

func (s *Store) InsertUsageEvent(ctx context.Context, event storage.UsageEvent) error {
	_, err := s.insertUsageEventExec(ctx, event, false)
	return err
}

// EnsureUsageEvent inserts a usage_events row idempotently — duplicate
// request_id PKs are absorbed via INSERT OR IGNORE. Used as the
// SPEC-006 § 17.7 fallback path in chat_proxy.settleAfterCommit when
// the normal SettleReservation path fails: even if the reservation
// is missing or in an unexpected state, the buyer-facing usage record
// MUST exist after bytes have flowed (issue #187).
//
// PK-collision verify (ISS-187 R1 code+security MAJOR): historically
// the gateway `usage_events.request_id` was a GLOBAL primary key,
// allowing cross-account collisions (issue #196). The schema is now
// `(account_id, request_id)`, so the only legitimate INSERT OR IGNORE
// no-op is a same-account retry — typically a SPEC-006 § 17.7 fallback
// firing again after the primary settle path. EnsureUsageEvent still
// checks RowsAffected on 0 and verifies the full billing payload
// (tokens + window + identity) matches; a mismatch returns
// ErrUsageEventConflict so the caller knows the fallback failed and
// must refund. With the composite PK the cross-account branch can no
// longer occur — the verify is retained as defense in depth against
// same-account payload drift (e.g. two settle paths racing with
// different token counts).
func (s *Store) EnsureUsageEvent(ctx context.Context, event storage.UsageEvent) error {
	// Normalize identically to insertUsageEventExec so the post-insert
	// payload comparison below reads the same TotalTokens value that
	// is persisted on disk. Without this, a benign retry that passes
	// TotalTokens=0 (with prompt+completion set) would compare 0
	// against the row's normalized prompt+completion sum and
	// falsely return ErrUsageEventConflict, triggering a wrong
	// refund. Caught by ISS-196 R2 codex CODE MEDIUM.
	if event.TotalTokens == 0 {
		event.TotalTokens = event.PromptTokens + event.CompletionTokens
	}
	result, err := s.insertUsageEventExec(ctx, event, true)
	if err != nil {
		return err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if affected > 0 {
		return nil
	}
	// PK collision. Read the existing row and verify it matches the
	// incoming event's billing-relevant fields. Mismatch => cross-
	// account collision, a corrupted prior write, OR a payload
	// drift (e.g., same account/request_id retrying with a different
	// token count) — none of which should silently succeed.
	// R2 code MAJOR: verify the FULL billing payload (tokens + window
	// + identity), not just identity. Without this, a buyer who can
	// race two settle paths with different token counts could pin a
	// low-token row first and then have higher-token settles
	// silently no-op.
	var existing struct {
		AccountID        string
		DemoIdentity     string
		WindowDate       string
		PromptTokens     int64
		CompletionTokens int64
		TotalTokens      int64
		TokenSource      string
		Outcome          string
	}
	if err := s.db.QueryRowContext(ctx, `
		SELECT account_id, demo_identity, window_date, prompt_tokens, completion_tokens, total_tokens, token_source, outcome
		FROM usage_events WHERE account_id = ? AND request_id = ?`, event.AccountID, event.RequestID).Scan(
		&existing.AccountID, &existing.DemoIdentity, &existing.WindowDate,
		&existing.PromptTokens, &existing.CompletionTokens, &existing.TotalTokens,
		&existing.TokenSource, &existing.Outcome,
	); err != nil {
		return err
	}
	if existing.AccountID != event.AccountID ||
		existing.DemoIdentity != event.DemoIdentity ||
		existing.WindowDate != event.WindowDate ||
		existing.PromptTokens != event.PromptTokens ||
		existing.CompletionTokens != event.CompletionTokens ||
		existing.TotalTokens != event.TotalTokens ||
		existing.TokenSource != event.TokenSource ||
		existing.Outcome != event.Outcome {
		return storage.ErrUsageEventConflict
	}
	return nil
}

// EnsureDemoUsageEvent inserts a demo_usage_events row idempotently
// — duplicates on the request_id PK silently no-op. The
// EnsureUsageEvent caller already runs the cross-account payload
// verify on usage_events, so a benign duplicate here on the
// demo-side table is not a security regression: an attacker who
// could pass the usage_events conflict check could already write
// the demo row legitimately.
func (s *Store) EnsureDemoUsageEvent(ctx context.Context, event storage.DemoUsageEvent) error {
	if event.CreatedAt.IsZero() {
		event.CreatedAt = time.Now().UTC()
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO demo_usage_events(request_id, client_ip, demo_token_hash, window_date, total_tokens, created_at)
		VALUES(?, ?, ?, ?, ?, ?)`,
		event.RequestID, event.ClientIP, event.DemoTokenHash, event.WindowDate, event.TotalTokens, encodeTime(event.CreatedAt))
	return err
}

func (s *Store) insertUsageEventExec(ctx context.Context, event storage.UsageEvent, idempotent bool) (sql.Result, error) {
	if event.CreatedAt.IsZero() {
		event.CreatedAt = time.Now().UTC()
	}
	if event.PromptTokens < 0 || event.CompletionTokens < 0 || event.TotalTokens < 0 {
		return nil, fmt.Errorf("usage tokens must be non-negative")
	}
	if event.PromptTokens > math.MaxInt64-event.CompletionTokens {
		return nil, fmt.Errorf("usage token total overflows int64")
	}
	sum := event.PromptTokens + event.CompletionTokens
	if event.TotalTokens == 0 {
		event.TotalTokens = sum
	} else if event.TotalTokens != sum {
		return nil, fmt.Errorf("usage total_tokens does not match prompt_tokens plus completion_tokens")
	}
	stmt := `
		INSERT INTO usage_events(request_id, account_id, demo_identity, window_date, prompt_tokens, completion_tokens, total_tokens, token_source, outcome, created_at)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
	if idempotent {
		stmt = `
		INSERT OR IGNORE INTO usage_events(request_id, account_id, demo_identity, window_date, prompt_tokens, completion_tokens, total_tokens, token_source, outcome, created_at)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
	}
	return s.db.ExecContext(ctx, stmt,
		event.RequestID, event.AccountID, event.DemoIdentity, event.WindowDate, event.PromptTokens, event.CompletionTokens,
		event.TotalTokens, event.TokenSource, event.Outcome, encodeTime(event.CreatedAt))
}

func normalizeSettlementTokens(settlement *storage.ReservationSettlement) error {
	if settlement.PromptTokens < 0 || settlement.CompletionTokens < 0 || settlement.TotalTokens < 0 {
		return fmt.Errorf("settlement tokens must be non-negative")
	}
	if settlement.PromptTokens > math.MaxInt64-settlement.CompletionTokens {
		return fmt.Errorf("settlement token total overflows int64")
	}
	sum := settlement.PromptTokens + settlement.CompletionTokens
	if settlement.TotalTokens == 0 {
		settlement.TotalTokens = sum
	} else if settlement.TotalTokens != sum {
		return fmt.Errorf("settlement total_tokens does not match prompt_tokens plus completion_tokens")
	}
	if settlement.MaxTotalTokens > 0 && settlement.TotalTokens > settlement.MaxTotalTokens {
		return fmt.Errorf("settlement total_tokens exceeds request maximum")
	}
	return nil
}

func (s *Store) DailyUsage(ctx context.Context, accountID, windowDate string) (int64, int64, error) {
	return dailyUsageTx(ctx, s.db, accountID, windowDate)
}

func (s *Store) ReapExpiredReservations(ctx context.Context, now time.Time) (int64, error) {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	n, err := reapExpiredReservationsTx(ctx, tx, now)
	if err != nil {
		return 0, err
	}
	return n, tx.Commit()
}

// DeleteTerminalQuotaReservations removes quota_reservations rows in a
// terminal status (expired / settled / refunded) whose settled_at is
// strictly before `before`. M2-4 / PERF-1 Part B: terminal reservations
// carry no audit value — the usage_events row is the durable record —
// so they're safe to delete past a retention threshold. The caller picks
// `before` (the reaper uses now - 7d).
//
// Only quota_reservations is touched here. concurrency_reservations has
// a `concurrency_reservations_no_delete` BEFORE DELETE trigger that
// forbids deletion; treating that as a Q4-gated decision per the audit's
// PERF-1 / Open Q4 ("append-only-forever: requirement or default?").
func (s *Store) DeleteTerminalQuotaReservations(ctx context.Context, before time.Time) (int64, error) {
	if before.IsZero() {
		return 0, fmt.Errorf("before time must be non-zero")
	}
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	res, err := tx.ExecContext(ctx, `
		DELETE FROM quota_reservations
		WHERE status IN ('expired', 'settled', 'refunded')
		  AND settled_at IS NOT NULL
		  AND settled_at < ?`,
		encodeTime(before))
	if err != nil {
		return 0, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, err
	}
	return n, tx.Commit()
}

func (s *Store) InsertFeedbackEvent(ctx context.Context, event storage.FeedbackEvent) error {
	if event.CreatedAt.IsZero() {
		event.CreatedAt = time.Now().UTC()
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO feedback_events(event_id, request_id, account_id, scope, rating, comment, created_at)
		VALUES(?, ?, ?, ?, ?, ?, ?)`,
		event.EventID, event.RequestID, event.AccountID, event.Scope, event.Rating, event.Comment, encodeTime(event.CreatedAt))
	return err
}

func (s *Store) ListFeedbackEventsSince(ctx context.Context, since time.Time) ([]storage.FeedbackSummaryEvent, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT event_id, request_id, account_id, scope, rating, comment, created_at
		FROM feedback_events
		WHERE created_at >= ?
		ORDER BY created_at ASC`, encodeTime(since))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var events []storage.FeedbackSummaryEvent
	for rows.Next() {
		var event storage.FeedbackSummaryEvent
		var created string
		if err := rows.Scan(&event.EventID, &event.RequestID, &event.AccountID, &event.Scope, &event.Rating, &event.Comment, &created); err != nil {
			return nil, err
		}
		event.CreatedAt = decodeTime(created)
		events = append(events, event)
	}
	return events, rows.Err()
}

func (s *Store) InsertAuditEvent(ctx context.Context, event storage.AuditEvent) error {
	if event.CreatedAt.IsZero() {
		event.CreatedAt = time.Now().UTC()
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO audit_events(event_id, request_id, account_id, actor, event_type, payload_json, created_at)
		VALUES(?, ?, ?, ?, ?, ?, ?)`,
		event.EventID, event.RequestID, event.AccountID, event.Actor, event.Type, event.Payload, encodeTime(event.CreatedAt))
	return err
}

func (s *Store) LatestCapacitySignals(ctx context.Context) ([]storage.CapacitySignalEvent, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT c.event_id, c.signal, c.value, c.threshold, c.firing, c.created_at
		FROM capacity_signal_events c
		JOIN (
			SELECT signal, MAX(created_at) AS created_at
			FROM capacity_signal_events
			GROUP BY signal
		) latest ON latest.signal = c.signal AND latest.created_at = c.created_at
		ORDER BY c.signal ASC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []storage.CapacitySignalEvent
	for rows.Next() {
		var event storage.CapacitySignalEvent
		var firing int
		var created string
		if err := rows.Scan(&event.EventID, &event.Signal, &event.Value, &event.Threshold, &firing, &created); err != nil {
			return nil, err
		}
		event.Firing = firing == 1
		event.CreatedAt = decodeTime(created)
		out = append(out, event)
	}
	return out, rows.Err()
}

// capacityTierDTO is the on-disk JSON shape for capacity_tier runtime_config rows.
// Has the same field names and shape as the old fmt.Sprintf format
// `{"tier":N,"signals":"..."}`, but encoding/json may produce different output
// for characters like <, >, & and correctly handles backslashes, quotes,
// control characters, and Unicode that the old %q verb encoded differently
// (code-review finding CODE-6).
type capacityTierDTO struct {
	Tier    int    `json:"tier"`
	Signals string `json:"signals"`
}

func (s *Store) GetCapacityTier(ctx context.Context) (storage.CapacityTier, error) {
	row := s.db.QueryRowContext(ctx, `SELECT value, updated_at FROM runtime_config WHERE key = 'capacity_tier'`)
	var value string
	var updated string
	if err := row.Scan(&value, &updated); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.CapacityTier{Tier: 0}, nil
		}
		return storage.CapacityTier{}, err
	}
	var dto capacityTierDTO
	if err := json.Unmarshal([]byte(value), &dto); err != nil {
		// Legacy compat: old rows were written by fmt.Sprintf with %q, which
		// produces Go-quoted strings (e.g., \xNN escapes) that json.Unmarshal
		// rejects. Try the old format as a fallback so we can read existing rows.
		var legacyTier int
		var legacySignals string
		if _, scanErr := fmt.Sscanf(value, `{"tier":%d,"signals":%q}`, &legacyTier, &legacySignals); scanErr == nil {
			return storage.CapacityTier{Tier: legacyTier, Signals: legacySignals, UpdatedAt: decodeTime(updated)}, nil
		}
		return storage.CapacityTier{}, fmt.Errorf("decode capacity_tier: %w", err)
	}
	return storage.CapacityTier{Tier: dto.Tier, Signals: dto.Signals, UpdatedAt: decodeTime(updated)}, nil
}

func (s *Store) SetCapacityTier(ctx context.Context, tier storage.CapacityTier) error {
	if tier.UpdatedAt.IsZero() {
		tier.UpdatedAt = time.Now().UTC()
	}
	value, err := json.Marshal(capacityTierDTO{Tier: tier.Tier, Signals: tier.Signals})
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO runtime_config(key, value, updated_at)
		VALUES('capacity_tier', ?, ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
		string(value), encodeTime(tier.UpdatedAt))
	return err
}

func (s *Store) GetKillSwitch(ctx context.Context) (storage.KillSwitchState, error) {
	row := s.db.QueryRowContext(ctx, `SELECT value, updated_at FROM runtime_config WHERE key = 'kill_switch'`)
	var value string
	var updated string
	if err := row.Scan(&value, &updated); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.KillSwitchState{}, nil
		}
		return storage.KillSwitchState{}, err
	}
	var state storage.KillSwitchState
	if err := json.Unmarshal([]byte(value), &state); err != nil {
		return storage.KillSwitchState{}, err
	}
	state.UpdatedAt = decodeTime(updated)
	return state, nil
}

func (s *Store) SetKillSwitch(ctx context.Context, state storage.KillSwitchState) error {
	if state.UpdatedAt.IsZero() {
		state.UpdatedAt = time.Now().UTC()
	}
	value, err := json.Marshal(struct {
		DemoOnly     bool `json:"demo_only"`
		AllPublicAPI bool `json:"all_public_api"`
	}{DemoOnly: state.DemoOnly, AllPublicAPI: state.AllPublicAPI})
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO runtime_config(key, value, updated_at)
		VALUES('kill_switch', ?, ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
		string(value), encodeTime(state.UpdatedAt))
	return err
}

func (s *Store) InsertCapacitySignalEvent(ctx context.Context, event storage.CapacitySignalEvent) error {
	if event.CreatedAt.IsZero() {
		event.CreatedAt = time.Now().UTC()
	}
	firing := 0
	if event.Firing {
		firing = 1
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO capacity_signal_events(event_id, signal, value, threshold, firing, created_at)
		VALUES(?, ?, ?, ?, ?, ?)`,
		event.EventID, event.Signal, event.Value, event.Threshold, firing, encodeTime(event.CreatedAt))
	return err
}

type queryer interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

type execer interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
}

func reapExpiredReservationsTx(ctx context.Context, q execer, now time.Time) (int64, error) {
	if now.IsZero() {
		now = time.Now().UTC()
	}
	res, err := q.ExecContext(ctx, `
		UPDATE quota_reservations
		SET status = 'expired', settled_tokens = 0, settled_at = ?
		WHERE status = 'active' AND expires_at <= ?`,
		encodeTime(now), encodeTime(now))
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

func dailyUsageTx(ctx context.Context, q queryer, accountID, windowDate string) (int64, int64, error) {
	var used sql.NullInt64
	if err := q.QueryRowContext(ctx, `
		SELECT COALESCE(SUM(total_tokens), 0)
		FROM usage_events
		WHERE account_id = ? AND window_date = ?`, accountID, windowDate).Scan(&used); err != nil {
		return 0, 0, err
	}
	var reserved sql.NullInt64
	if err := q.QueryRowContext(ctx, `
		SELECT COALESCE(SUM(reserved_tokens), 0)
		FROM quota_reservations
		WHERE account_id = ? AND window_date = ? AND status = 'active'`, accountID, windowDate).Scan(&reserved); err != nil {
		return 0, 0, err
	}
	return used.Int64, reserved.Int64, nil
}

type immediateTx struct {
	ctx  context.Context
	conn *sql.Conn
	done bool
}

func (tx *immediateTx) ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error) {
	return tx.conn.ExecContext(ctx, query, args...)
}

func (tx *immediateTx) QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row {
	return tx.conn.QueryRowContext(ctx, query, args...)
}

func (tx *immediateTx) Commit() error {
	if tx.done {
		return nil
	}
	tx.done = true
	_, err := tx.conn.ExecContext(tx.ctx, "COMMIT")
	closeErr := tx.conn.Close()
	if err != nil {
		return err
	}
	return closeErr
}

func (tx *immediateTx) Rollback() {
	if tx.done {
		return
	}
	tx.done = true
	_, _ = tx.conn.ExecContext(tx.ctx, "ROLLBACK")
	_ = tx.conn.Close()
}

func (s *Store) beginImmediate(ctx context.Context) (*immediateTx, error) {
	conn, err := s.db.Conn(ctx)
	if err != nil {
		return nil, err
	}
	if _, err := conn.ExecContext(ctx, "BEGIN IMMEDIATE"); err != nil {
		_ = conn.Close()
		return nil, err
	}
	return &immediateTx{ctx: ctx, conn: conn}, nil
}

func rollback(tx *sql.Tx) {
	_ = tx.Rollback()
}

func encodeTime(t time.Time) string {
	return t.UTC().Format(time.RFC3339Nano)
}

func decodeTime(s string) time.Time {
	t, _ := time.Parse(time.RFC3339Nano, s)
	return t
}

func nonEmpty(v, fallback string) string {
	if v == "" {
		return fallback
	}
	return v
}

func max64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

func resetUnix(windowDate string) int64 {
	t, err := time.Parse("2006-01-02", windowDate)
	if err != nil {
		return 0
	}
	return t.Add(24 * time.Hour).Unix()
}
