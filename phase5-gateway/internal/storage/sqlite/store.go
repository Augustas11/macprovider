package sqlite

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/base64"
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
	_ storage.AuthStore          = (*Store)(nil)
	_ storage.AccountStore       = (*Store)(nil)
	_ storage.KeyStore           = (*Store)(nil)
	_ storage.UsageStore         = (*Store)(nil)
	_ storage.WalletSessionStore = (*Store)(nil)
	_ storage.FeedbackStore      = (*Store)(nil)
	_ storage.AuditStore         = (*Store)(nil)
	_ storage.CapacityStore      = (*Store)(nil)
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
//	v5 — SPEC-022: usage_events accepts coordinator_observed settlement
//	     rows after coordinator receipt finality verifies canonical usage.
//	v6 — SPEC-022 D12: quota_reservations marks receipt-finality holds so
//	     admin reconciliation does not scan ordinary in-flight reservations.
//	v7 — SPEC-022 D13: quota_reservations accepts stale_held terminal holds
//	     for coordinator-missing ambiguity that must release active quota.
//	v8 — public issuance reservation events for atomic per-IP signup/demo/
//	     feedback ceilings.
//	v9 — oauth return_to + oauth_handoffs support.
//	v10 — SPEC-040 wallet-native buyer session tables.
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
const maxKnownSchemaVersion = 10

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
	if _, err := s.db.ExecContext(ctx, quotaReservationsTableDDL); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx, quotaReservationsAuxiliaryDDL); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx, demoUsageEventsTableDDL); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx, demoUsageEventsAuxiliaryDDL); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx, walletSessionDDL); err != nil {
		return err
	}
	if err := s.ensureWalletSessionRequestMapModelIDColumn(ctx); err != nil {
		return err
	}
	if err := s.ensureWalletSessionReplayDispatchColumns(ctx); err != nil {
		return err
	}
	if err := s.ensureOAuthStateExpiresAtColumn(ctx); err != nil {
		return err
	}
	if err := s.ensureOAuthStateActionColumn(ctx); err != nil {
		return err
	}
	if err := s.ensureOAuthStateReturnToColumn(ctx); err != nil {
		return err
	}
	if err := s.ensureOAuthHandoffsTable(ctx); err != nil {
		return err
	}
	if err := s.ensureUsageEventsCompositePK(ctx); err != nil {
		return err
	}
	if err := s.ensureDemoUsageEventsCompositePK(ctx); err != nil {
		return err
	}
	if err := s.ensureUsageEventsCoordinatorObservedSource(ctx); err != nil {
		return err
	}
	if err := s.ensureQuotaSettlementHoldColumn(ctx); err != nil {
		return err
	}
	if err := s.ensureQuotaReservationStaleHeldStatus(ctx); err != nil {
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
	if _, err := s.db.ExecContext(ctx, "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(5, ?)", now); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx, "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(6, ?)", now); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx, "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(7, ?)", now); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx, "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(8, ?)", now); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx, "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(9, ?)", now); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx, "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(10, ?)", now); err != nil {
		return err
	}
	return nil
}

func (s *Store) ensureOAuthStateExpiresAtColumn(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(oauth_states)`)
	if err != nil {
		return err
	}
	defer rows.Close()
	hasExpiresAt := false
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull int
		var defaultValue sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
			return err
		}
		if name == "expires_at" {
			hasExpiresAt = true
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if !hasExpiresAt {
		if _, err := s.db.ExecContext(ctx, `ALTER TABLE oauth_states ADD COLUMN expires_at TEXT NOT NULL DEFAULT ''`); err != nil {
			return err
		}
		if _, err := s.db.ExecContext(ctx, `UPDATE oauth_states SET expires_at = strftime('%Y-%m-%dT%H:%M:%SZ', created_at, '+10 minutes') WHERE expires_at = ''`); err != nil {
			return err
		}
	}
	_, err = s.db.ExecContext(ctx, `
		CREATE INDEX IF NOT EXISTS idx_oauth_states_session ON oauth_states(session_id, expires_at);
		CREATE INDEX IF NOT EXISTS idx_oauth_states_client_ip_expires ON oauth_states(client_ip, expires_at);
	`)
	return err
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

func (s *Store) ensureOAuthStateReturnToColumn(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(oauth_states)`)
	if err != nil {
		return err
	}
	defer rows.Close()
	hasReturnTo := false
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull int
		var defaultValue sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
			return err
		}
		if name == "return_to" {
			hasReturnTo = true
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if hasReturnTo {
		return nil
	}
	_, err = s.db.ExecContext(ctx, `ALTER TABLE oauth_states ADD COLUMN return_to TEXT NOT NULL DEFAULT ''`)
	return err
}

func (s *Store) ensureOAuthHandoffsTable(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
		CREATE TABLE IF NOT EXISTS oauth_handoffs (
			token_hash BLOB PRIMARY KEY,
			api_key TEXT NOT NULL,
			created_at TEXT NOT NULL,
			expires_at TEXT NOT NULL,
			consumed_at TEXT NOT NULL DEFAULT ''
		);
		CREATE INDEX IF NOT EXISTS idx_oauth_handoffs_expires ON oauth_handoffs(expires_at);
	`)
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

// ensureUsageEventsCoordinatorObservedSource rebuilds v4 usage_events
// tables whose CHECK constraint predates SPEC-022 coordinator finality.
// SQLite cannot ALTER a CHECK constraint in place, so use the same
// canonical-table rebuild pattern as the PK migrations.
func (s *Store) ensureUsageEventsCoordinatorObservedSource(ctx context.Context) error {
	var sqlText string
	err := s.db.QueryRowContext(ctx, `
		SELECT sql FROM sqlite_master
		WHERE type = 'table' AND name = 'usage_events'`).Scan(&sqlText)
	if err != nil {
		return err
	}
	if strings.Contains(sqlText, "coordinator_observed") {
		return nil
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
	if _, err := tx.ExecContext(ctx, `ALTER TABLE usage_events RENAME TO usage_events_legacy`); err != nil {
		return fmt.Errorf("rename usage_events for coordinator_observed migration: %w", err)
	}
	if _, err := tx.ExecContext(ctx, usageEventsTableDDL); err != nil {
		return fmt.Errorf("create usage_events with coordinator_observed source: %w", err)
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
		return fmt.Errorf("copy usage_events rows for coordinator_observed migration: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `DROP TABLE usage_events_legacy`); err != nil {
		return fmt.Errorf("drop legacy usage_events after coordinator_observed migration: %w", err)
	}
	if _, err := tx.ExecContext(ctx, usageEventsAuxiliaryDDL); err != nil {
		return fmt.Errorf("recreate usage_events index/trigger after coordinator_observed migration: %w", err)
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(5, ?)`,
		encodeTime(time.Now().UTC())); err != nil {
		return fmt.Errorf("stamp schema_migrations v5 inside coordinator_observed migration tx: %w", err)
	}
	return tx.Commit()
}

func (s *Store) ensureQuotaSettlementHoldColumn(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(quota_reservations)`)
	if err != nil {
		return err
	}
	defer rows.Close()
	hasSettlementHold := false
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull int
		var defaultValue sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
			return err
		}
		if name == "settlement_hold" {
			hasSettlementHold = true
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if hasSettlementHold {
		return nil
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `ALTER TABLE quota_reservations ADD COLUMN settlement_hold INTEGER NOT NULL DEFAULT 0 CHECK (settlement_hold IN (0, 1))`); err != nil {
		return fmt.Errorf("add quota_reservations.settlement_hold: %w", err)
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(6, ?)`,
		encodeTime(time.Now().UTC())); err != nil {
		return fmt.Errorf("stamp schema_migrations v6 with settlement_hold column: %w", err)
	}
	return tx.Commit()
}

func (s *Store) ensureWalletSessionRequestMapModelIDColumn(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(wallet_session_request_map)`)
	if err != nil {
		return err
	}
	defer rows.Close()
	hasModelID := false
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull int
		var defaultValue sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
			return err
		}
		if name == "model_id" {
			hasModelID = true
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if hasModelID {
		return nil
	}
	_, err = s.db.ExecContext(ctx, `ALTER TABLE wallet_session_request_map ADD COLUMN model_id TEXT NOT NULL DEFAULT ''`)
	if err != nil {
		return fmt.Errorf("add wallet_session_request_map.model_id: %w", err)
	}
	return nil
}

func (s *Store) ensureWalletSessionReplayDispatchColumns(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(wallet_session_replays)`)
	if err != nil {
		return err
	}
	defer rows.Close()
	existing := map[string]struct{}{}
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull int
		var defaultValue sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
			return err
		}
		existing[name] = struct{}{}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	for _, column := range []struct {
		name string
		ddl  string
	}{
		{"dispatch_armed_at", `ALTER TABLE wallet_session_replays ADD COLUMN dispatch_armed_at TEXT NOT NULL DEFAULT ''`},
		{"dispatched_at", `ALTER TABLE wallet_session_replays ADD COLUMN dispatched_at TEXT NOT NULL DEFAULT ''`},
		{"recovery_policy", `ALTER TABLE wallet_session_replays ADD COLUMN recovery_policy TEXT NOT NULL DEFAULT ''`},
		{"intended_effect", `ALTER TABLE wallet_session_replays ADD COLUMN intended_effect TEXT NOT NULL DEFAULT ''`},
		{"reserved_tokens", `ALTER TABLE wallet_session_replays ADD COLUMN reserved_tokens INTEGER NOT NULL DEFAULT 0 CHECK (reserved_tokens >= 0)`},
	} {
		if _, ok := existing[column.name]; ok {
			continue
		}
		if _, err := s.db.ExecContext(ctx, column.ddl); err != nil {
			return fmt.Errorf("add wallet_session_replays.%s: %w", column.name, err)
		}
	}
	return nil
}

func (s *Store) ensureQuotaReservationStaleHeldStatus(ctx context.Context) error {
	var sqlText string
	err := s.db.QueryRowContext(ctx, `
		SELECT sql FROM sqlite_master
		WHERE type = 'table' AND name = 'quota_reservations'`).Scan(&sqlText)
	if err != nil {
		return err
	}
	if strings.Contains(sqlText, "stale_held") {
		return nil
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `ALTER TABLE quota_reservations RENAME TO quota_reservations_legacy`); err != nil {
		return fmt.Errorf("rename quota_reservations for stale_held migration: %w", err)
	}
	if _, err := tx.ExecContext(ctx, quotaReservationsTableDDL); err != nil {
		return fmt.Errorf("create quota_reservations with stale_held status: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO quota_reservations
			(account_id, request_id, window_date, reserved_tokens, settled_tokens,
			 status, settlement_hold, expires_at, created_at, settled_at)
		SELECT account_id, request_id, window_date, reserved_tokens, settled_tokens,
		       status, settlement_hold, expires_at, created_at, settled_at
		FROM quota_reservations_legacy`); err != nil {
		return fmt.Errorf("copy quota_reservations rows for stale_held migration: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `DROP TABLE quota_reservations_legacy`); err != nil {
		return fmt.Errorf("drop legacy quota_reservations after stale_held migration: %w", err)
	}
	if _, err := tx.ExecContext(ctx, quotaReservationsAuxiliaryDDL); err != nil {
		return fmt.Errorf("recreate quota_reservations indexes after stale_held migration: %w", err)
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(7, ?)`,
		encodeTime(time.Now().UTC())); err != nil {
		return fmt.Errorf("stamp schema_migrations v7 inside stale_held migration tx: %w", err)
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
	return s.StoreOAuthStateWithCap(ctx, state, 0, time.Now().UTC())
}

func (s *Store) StoreOAuthStateWithCap(ctx context.Context, state storage.OAuthState, maxPerIP int, now time.Time) error {
	if state.CreatedAt.IsZero() {
		if now.IsZero() {
			now = time.Now().UTC()
		}
		state.CreatedAt = now.UTC()
	}
	if state.ExpiresAt.IsZero() {
		state.ExpiresAt = state.CreatedAt.Add(10 * time.Minute)
	}
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if maxPerIP > 0 && state.ClientIP != "" {
		var count int
		if err := tx.QueryRowContext(ctx, `
			SELECT COUNT(*) FROM oauth_states
			WHERE client_ip = ? AND consumed_at = '' AND expires_at > ?`,
			state.ClientIP, encodeTime(now.UTC())).Scan(&count); err != nil {
			return err
		}
		if count >= maxPerIP {
			return storage.ErrOAuthStateCap
		}
	}
	_, err = tx.ExecContext(ctx, `
		INSERT INTO oauth_states(state_hash, session_id, redirect_uri, return_to, client_ip, created_at, expires_at, action)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?)`,
		state.StateHash, state.SessionID, state.RedirectURI, state.ReturnTo,
		state.ClientIP, encodeTime(state.CreatedAt), encodeTime(state.ExpiresAt), state.Action)
	if err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) ConsumeOAuthState(ctx context.Context, stateHash []byte, sessionID string, now time.Time) (string, string, string, error) {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return "", "", "", err
	}
	defer tx.Rollback()
	var redirectURI string
	var returnTo string
	var expiresAt string
	var consumedAt string
	var action string
	if err := tx.QueryRowContext(ctx, `
		SELECT redirect_uri, return_to, expires_at, consumed_at, action
		FROM oauth_states
		WHERE state_hash = ? AND session_id = ?`,
		stateHash, sessionID).Scan(&redirectURI, &returnTo, &expiresAt, &consumedAt, &action); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", "", "", storage.ErrNotFound
		}
		return "", "", "", err
	}
	if consumedAt != "" || !now.Before(decodeTime(expiresAt)) {
		return "", "", "", storage.ErrNotFound
	}
	_, err = tx.ExecContext(ctx, `UPDATE oauth_states SET consumed_at = ? WHERE state_hash = ?`, encodeTime(now.UTC()), stateHash)
	if err != nil {
		return "", "", "", err
	}
	return redirectURI, action, returnTo, tx.Commit()
}

func (s *Store) StoreOAuthHandoff(ctx context.Context, handoff storage.OAuthHandoff) error {
	if handoff.CreatedAt.IsZero() {
		handoff.CreatedAt = time.Now().UTC()
	}
	consumedAt := ""
	if !handoff.ConsumedAt.IsZero() {
		consumedAt = encodeTime(handoff.ConsumedAt)
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO oauth_handoffs(token_hash, api_key, created_at, expires_at, consumed_at)
		VALUES(?, ?, ?, ?, ?)`,
		handoff.TokenHash, handoff.APIKey, encodeTime(handoff.CreatedAt), encodeTime(handoff.ExpiresAt), consumedAt)
	return err
}

func (s *Store) ConsumeOAuthHandoff(ctx context.Context, tokenHash []byte, now time.Time) (string, error) {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	var apiKey string
	var expiresAt string
	var consumedAt string
	if err := tx.QueryRowContext(ctx, `
		SELECT api_key, expires_at, consumed_at
		FROM oauth_handoffs
		WHERE token_hash = ?`,
		tokenHash).Scan(&apiKey, &expiresAt, &consumedAt); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", storage.ErrNotFound
		}
		return "", err
	}
	if consumedAt != "" || !now.Before(decodeTime(expiresAt)) {
		return "", storage.ErrNotFound
	}
	_, err = tx.ExecContext(ctx, `UPDATE oauth_handoffs SET consumed_at = ? WHERE token_hash = ?`, encodeTime(now.UTC()), tokenHash)
	if err != nil {
		return "", err
	}
	return apiKey, tx.Commit()
}

func (s *Store) PruneExpiredOAuthHandoffs(ctx context.Context, now time.Time) (int64, error) {
	if now.IsZero() {
		now = time.Now().UTC()
	}
	res, err := s.db.ExecContext(ctx, `
		DELETE FROM oauth_handoffs
		WHERE expires_at <= ?`, encodeTime(now.UTC()))
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

func (s *Store) PruneExpiredOAuthState(ctx context.Context, now time.Time) (int64, error) {
	if now.IsZero() {
		now = time.Now().UTC()
	}
	res, err := s.db.ExecContext(ctx, `
		DELETE FROM oauth_states
		WHERE expires_at <= ?`, encodeTime(now.UTC()))
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

func (s *Store) ReservePublicIssuance(ctx context.Context, reservation storage.PublicIssuanceReservation) error {
	if reservation.Limit <= 0 {
		return storage.ErrRateLimit
	}
	if reservation.CreatedAt.IsZero() {
		reservation.CreatedAt = time.Now().UTC()
	}
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	windowStart := encodeTime(reservation.WindowStart.UTC())
	createdAt := encodeTime(reservation.CreatedAt.UTC())
	if _, err := tx.ExecContext(ctx, `
		DELETE FROM public_issuance_events
		WHERE surface = ? AND created_at < ?`, reservation.Surface, windowStart); err != nil {
		return err
	}

	var count int
	if err := tx.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM public_issuance_events
		WHERE surface = ? AND client_ip = ? AND created_at >= ?`,
		reservation.Surface, reservation.ClientIP, windowStart).Scan(&count); err != nil {
		return err
	}

	legacyCount, err := s.legacyPublicIssuanceCountTx(ctx, tx, reservation.Surface, reservation.ClientIP, windowStart)
	if err != nil {
		return err
	}
	count += legacyCount
	if count >= reservation.Limit {
		return storage.ErrRateLimit
	}
	_, err = tx.ExecContext(ctx, `
		INSERT INTO public_issuance_events(surface, client_ip, created_at)
		VALUES(?, ?, ?)`, reservation.Surface, reservation.ClientIP, createdAt)
	if err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) legacyPublicIssuanceCountTx(ctx context.Context, tx *immediateTx, surface, clientIP, windowStart string) (int, error) {
	var firstReservation sql.NullString
	if err := tx.QueryRowContext(ctx, `
		SELECT MIN(created_at) FROM public_issuance_events
		WHERE surface = ? AND client_ip = ?`, surface, clientIP).Scan(&firstReservation); err != nil {
		return 0, err
	}
	legacyUpperBound := ""
	if firstReservation.Valid {
		legacyUpperBound = firstReservation.String
	}
	var query string
	switch surface {
	case "signup":
		query = `SELECT COUNT(*) FROM signup_events WHERE client_ip = ? AND created_at >= ?`
	case "demo_session":
		query = `SELECT COUNT(*) FROM demo_session_events WHERE client_ip = ? AND created_at >= ?`
	default:
		return 0, nil
	}
	args := []any{clientIP, windowStart}
	if legacyUpperBound != "" {
		query += ` AND created_at < ?`
		args = append(args, legacyUpperBound)
	}
	var count int
	if err := tx.QueryRowContext(ctx, query, args...).Scan(&count); err != nil {
		return 0, err
	}
	return count, nil
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
	var existingStatus string
	err = tx.QueryRowContext(ctx, `
		SELECT status FROM quota_reservations
		WHERE account_id = ? AND request_id = ?`,
		req.AccountID, req.RequestID).Scan(&existingStatus)
	if err == nil {
		return storage.QuotaDecision{}, storage.ErrReservationExists
	}
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
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
		if isUniqueConstraintError(err) {
			return storage.QuotaDecision{}, storage.ErrReservationExists
		}
		return storage.QuotaDecision{}, err
	}
	decision.Admitted = true
	decision.ReservedTokens += req.RequestedTokens
	decision.RemainingTokens = max64(0, remaining-req.RequestedTokens)
	return decision, tx.Commit()
}

func isUniqueConstraintError(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "constraint failed") &&
		(strings.Contains(msg, "unique") || strings.Contains(msg, "primary key"))
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
		return fmt.Errorf("%w: reservation %s is %s", storage.ErrReservationTerminal, settlement.RequestID, status)
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
		// Wraps the sentinel exactly like SettleReservation does. A caller
		// that CLASSIFIES the error (the #763 journal recovery ladder) must
		// see a terminal demo reservation as terminal, or it would retry an
		// already-settled effect forever instead of falling through to the
		// idempotent usage-event rung. The settle path itself is unaffected:
		// settleAfterCommit treats every settle error identically.
		return fmt.Errorf("%w: reservation %s is %s", storage.ErrReservationTerminal, settlement.RequestID, status)
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

func (s *Store) ExpireReservation(ctx context.Context, accountID, requestID string, expiredAt time.Time) error {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if expiredAt.IsZero() {
		expiredAt = time.Now().UTC()
	}
	res, err := tx.ExecContext(ctx, `
		UPDATE quota_reservations
		SET status = 'expired', settled_tokens = 0, settled_at = ?
		WHERE account_id = ? AND request_id = ? AND status = 'active'`,
		encodeTime(expiredAt.UTC()), accountID, requestID)
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

func (s *Store) MarkReservationStaleHeld(ctx context.Context, accountID, requestID string, staleAt time.Time) error {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if staleAt.IsZero() {
		staleAt = time.Now().UTC()
	}
	res, err := tx.ExecContext(ctx, `
		UPDATE quota_reservations
		SET status = 'stale_held', settled_tokens = 0, settled_at = ?, settlement_hold = 1
		WHERE account_id = ? AND request_id = ? AND status = 'active' AND settlement_hold = 1`,
		encodeTime(staleAt.UTC()), accountID, requestID)
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

func (s *Store) MarkReservationSettlementHold(ctx context.Context, accountID, requestID string) error {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var status string
	if err := tx.QueryRowContext(ctx, `
		SELECT status FROM quota_reservations
		WHERE account_id = ? AND request_id = ?`,
		accountID, requestID).Scan(&status); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.ErrReservationNotFound
		}
		return err
	}
	if status != "active" {
		return fmt.Errorf("%w: reservation %s is %s", storage.ErrReservationTerminal, requestID, status)
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE quota_reservations
		SET settlement_hold = 1
		WHERE account_id = ? AND request_id = ? AND status = 'active'`,
		accountID, requestID); err != nil {
		return err
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
	newExpiry := currentExpiry
	if expiresAt.Before(currentExpiry) {
		newExpiry = expiresAt
	}
	if _, err := tx.ExecContext(ctx, `
			UPDATE quota_reservations
			SET expires_at = ?, settlement_hold = 1
			WHERE account_id = ? AND request_id = ? AND status = 'active'`,
		encodeTime(newExpiry), accountID, requestID); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) ListSettlementHeldReservations(ctx context.Context, limit int) ([]storage.ActiveReservation, error) {
	if limit <= 0 {
		limit = 100
	}
	if limit > 500 {
		limit = 500
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT qr.account_id, qr.request_id, COALESCE(wrm.session_id, ''), qr.window_date,
			qr.reserved_tokens, qr.expires_at, qr.created_at
		FROM quota_reservations qr
		LEFT JOIN wallet_session_request_map wrm
			ON wrm.account_id = qr.account_id AND wrm.request_id = qr.request_id
		WHERE qr.status = 'active' AND qr.settlement_hold = 1
		ORDER BY qr.expires_at ASC, qr.created_at ASC
		LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]storage.ActiveReservation, 0, limit)
	for rows.Next() {
		var reservation storage.ActiveReservation
		var expiresAt, createdAt string
		if err := rows.Scan(
			&reservation.AccountID, &reservation.RequestID, &reservation.WalletSessionID,
			&reservation.WindowDate, &reservation.ReservedTokens, &expiresAt, &createdAt,
		); err != nil {
			return nil, err
		}
		reservation.ExpiresAt = decodeTime(expiresAt)
		reservation.CreatedAt = decodeTime(createdAt)
		out = append(out, reservation)
	}
	return out, rows.Err()
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

func (s *Store) StoreWalletSessionChallenge(ctx context.Context, challenge storage.WalletSessionChallenge) error {
	if challenge.CreatedAt.IsZero() {
		challenge.CreatedAt = time.Now().UTC()
	}
	if challenge.Purpose == "" {
		challenge.Purpose = "wallet-session-registration-v1"
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO wallet_session_challenges(
			nonce_hash, account_id, wallet_namespace, wallet_fingerprint, purpose, audience,
			requested_expires_at, per_request_token_cap, total_token_cap, model_allowlist_json,
			session_public_key, created_at, expires_at)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		challenge.NonceHash, challenge.AccountID, challenge.WalletNamespace, challenge.WalletFingerprint,
		challenge.Purpose, challenge.Audience, encodeTime(challenge.RequestedExpiresAt),
		challenge.PerRequestTokenCap, challenge.TotalTokenCap, challenge.ModelAllowlistJSON,
		challenge.SessionPublicKey, encodeTime(challenge.CreatedAt), encodeTime(challenge.ExpiresAt))
	return err
}

func (s *Store) RegisterWalletSession(ctx context.Context, req storage.WalletSessionRegistrationRequest) (storage.WalletSession, error) {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return storage.WalletSession{}, err
	}
	defer tx.Rollback()
	if req.CreatedAt.IsZero() {
		req.CreatedAt = time.Now().UTC()
	}
	now := req.CreatedAt.UTC()
	var accountStatus string
	if err := tx.QueryRowContext(ctx, `SELECT status FROM accounts WHERE account_id = ?`, req.AccountID).Scan(&accountStatus); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.WalletSession{}, storage.ErrNotFound
		}
		return storage.WalletSession{}, err
	}
	if accountStatus != "active" {
		return storage.WalletSession{}, storage.ErrWalletSessionInactive
	}
	challenge, err := walletChallengeByNonceTx(ctx, tx, req.ChallengeNonceHash)
	if err != nil {
		return storage.WalletSession{}, err
	}
	if challenge.AccountID != req.AccountID || challenge.WalletNamespace != req.WalletNamespace || challenge.WalletFingerprint != req.WalletFingerprint {
		return storage.WalletSession{}, storage.ErrNotFound
	}
	if challenge.Audience != req.Audience ||
		!challenge.RequestedExpiresAt.Equal(req.RequestedExpiresAt) ||
		challenge.PerRequestTokenCap != req.PerRequestTokenCap ||
		challenge.TotalTokenCap != req.TotalTokenCap ||
		challenge.ModelAllowlistJSON != req.ModelAllowlistJSON ||
		!bytesEqual(challenge.SessionPublicKey, req.SessionPublicKey) {
		return storage.WalletSession{}, storage.ErrWalletChallengeMismatch
	}
	if !challenge.ConsumedAt.IsZero() {
		return storage.WalletSession{}, storage.ErrWalletChallengeConsumed
	}
	if !now.Before(challenge.ExpiresAt) {
		return storage.WalletSession{}, storage.ErrWalletChallengeExpired
	}
	if !now.Before(challenge.RequestedExpiresAt) {
		return storage.WalletSession{}, storage.ErrWalletChallengeExpired
	}
	var identityAccountID, identityStatus string
	err = tx.QueryRowContext(ctx, `
		SELECT account_id, status FROM wallet_identities
		WHERE wallet_namespace = ? AND wallet_fingerprint = ?`,
		req.WalletNamespace, req.WalletFingerprint).Scan(&identityAccountID, &identityStatus)
	if err == nil {
		if identityAccountID != req.AccountID {
			return storage.WalletSession{}, storage.ErrWalletIdentityConflict
		}
		if identityStatus != "active" {
			return storage.WalletSession{}, storage.ErrWalletSessionInactive
		}
	} else if errors.Is(err, sql.ErrNoRows) {
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO wallet_identities(wallet_namespace, wallet_fingerprint, account_id, status, verification_public_key, created_at)
			VALUES(?, ?, ?, 'active', ?, ?)`,
			req.WalletNamespace, req.WalletFingerprint, req.AccountID, req.VerificationPublicKey, encodeTime(now)); err != nil {
			return storage.WalletSession{}, err
		}
	} else {
		return storage.WalletSession{}, err
	}
	if req.MaxActivePerAccount > 0 {
		count, err := activeWalletSessionCountTx(ctx, tx, `account_id = ?`, now, req.AccountID)
		if err != nil {
			return storage.WalletSession{}, err
		}
		if count >= req.MaxActivePerAccount {
			return storage.WalletSession{}, storage.ErrWalletSessionActiveCap
		}
	}
	if req.MaxActivePerWallet > 0 {
		count, err := activeWalletSessionCountTx(ctx, tx, `wallet_namespace = ? AND wallet_fingerprint = ?`, now, req.WalletNamespace, req.WalletFingerprint)
		if err != nil {
			return storage.WalletSession{}, err
		}
		if count >= req.MaxActivePerWallet {
			return storage.WalletSession{}, storage.ErrWalletSessionActiveCap
		}
	}
	session := storage.WalletSession{
		SessionID: req.SessionID, AccountID: req.AccountID, WalletNamespace: req.WalletNamespace,
		WalletFingerprint: req.WalletFingerprint, Status: "active", ExpiresAt: challenge.RequestedExpiresAt,
		TotalTokenCap: challenge.TotalTokenCap, PerRequestTokenCap: challenge.PerRequestTokenCap,
		ModelAllowlistJSON: challenge.ModelAllowlistJSON, BearerHash: req.BearerHash, BearerKeyID: req.BearerKeyID,
		VerificationPublicKey: req.VerificationPublicKey, SessionPublicKey: challenge.SessionPublicKey, CreatedAt: now,
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO wallet_sessions(
			session_id, account_id, wallet_namespace, wallet_fingerprint, status, expires_at,
			total_token_cap, per_request_token_cap, model_allowlist_json, bearer_hash, bearer_key_id,
			verification_public_key, session_public_key, created_at)
		VALUES(?, ?, ?, ?, 'active', ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		session.SessionID, session.AccountID, session.WalletNamespace, session.WalletFingerprint,
		encodeTime(session.ExpiresAt), session.TotalTokenCap, session.PerRequestTokenCap, session.ModelAllowlistJSON,
		session.BearerHash, session.BearerKeyID, session.VerificationPublicKey, session.SessionPublicKey, encodeTime(now)); err != nil {
		return storage.WalletSession{}, err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE wallet_session_challenges
		SET consumed_at = ?, consumed_session_id = ?
		WHERE nonce_hash = ? AND consumed_at = ''`,
		encodeTime(now), session.SessionID, req.ChallengeNonceHash); err != nil {
		return storage.WalletSession{}, err
	}
	return session, tx.Commit()
}

func (s *Store) LookupWalletSessionByBearerHash(ctx context.Context, bearerHash []byte) (storage.WalletSession, error) {
	row := s.db.QueryRowContext(ctx, `
		SELECT session_id, account_id, wallet_namespace, wallet_fingerprint, status, expires_at,
			total_token_cap, per_request_token_cap, model_allowlist_json, bearer_hash, bearer_key_id,
			verification_public_key, session_public_key, created_at, revoked_at, revoked_by, revoked_reason
		FROM wallet_sessions
		WHERE bearer_hash = ?`, bearerHash)
	return scanWalletSession(row)
}

func (s *Store) ListWalletSessions(ctx context.Context, accountID string) ([]storage.WalletSession, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT session_id, account_id, wallet_namespace, wallet_fingerprint, status, expires_at,
			total_token_cap, per_request_token_cap, model_allowlist_json, bearer_hash, bearer_key_id,
			verification_public_key, session_public_key, created_at, revoked_at, revoked_by, revoked_reason
		FROM wallet_sessions
		WHERE account_id = ?
		ORDER BY created_at DESC, session_id DESC`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var sessions []storage.WalletSession
	for rows.Next() {
		session, err := scanWalletSession(rows)
		if err != nil {
			return nil, err
		}
		sessions = append(sessions, session)
	}
	return sessions, rows.Err()
}

func (s *Store) GetWalletSession(ctx context.Context, accountID, sessionID string) (storage.WalletSession, error) {
	row := s.db.QueryRowContext(ctx, `
		SELECT session_id, account_id, wallet_namespace, wallet_fingerprint, status, expires_at,
			total_token_cap, per_request_token_cap, model_allowlist_json, bearer_hash, bearer_key_id,
			verification_public_key, session_public_key, created_at, revoked_at, revoked_by, revoked_reason
		FROM wallet_sessions
		WHERE account_id = ? AND session_id = ?`, accountID, sessionID)
	return scanWalletSession(row)
}

func (s *Store) WalletSessionUsage(ctx context.Context, accountID, sessionID string) (storage.WalletSessionUsage, error) {
	session, err := s.GetWalletSession(ctx, accountID, sessionID)
	if err != nil {
		return storage.WalletSessionUsage{}, err
	}
	var settled, reserved, held int64
	var count int
	if err := s.db.QueryRowContext(ctx, `
		SELECT
			COALESCE(SUM(CASE WHEN status = 'settled' THEN settled_tokens ELSE 0 END), 0),
			COALESCE(SUM(CASE WHEN status = 'active' THEN reserved_tokens ELSE 0 END), 0),
			COALESCE(SUM(CASE WHEN status IN ('held', 'quarantined', 'stale_held') THEN reserved_tokens ELSE 0 END), 0),
			COUNT(*)
		FROM wallet_session_reservations
		WHERE account_id = ? AND session_id = ?`,
		accountID, sessionID).Scan(&settled, &reserved, &held, &count); err != nil {
		return storage.WalletSessionUsage{}, err
	}
	usedExposure := settled + reserved + held
	return storage.WalletSessionUsage{
		SessionID: sessionID, AccountID: accountID, TotalCap: session.TotalTokenCap,
		PerRequestCap: session.PerRequestTokenCap, SettledTokens: settled, ReservedTokens: reserved,
		HeldTokens: held, RemainingTokens: max64(0, session.TotalTokenCap-usedExposure), RequestCount: count,
	}, nil
}

func (s *Store) ListWalletSessionUsageDetails(ctx context.Context, accountID, sessionID string, limit int, cursor string, since, until time.Time) ([]storage.WalletSessionUsageDetail, string, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 100 {
		limit = 100
	}
	if since.IsZero() {
		since = time.Unix(0, 0).UTC()
	}
	if until.IsZero() {
		until = time.Now().UTC()
	}
	cursorCreatedAt, cursorRequestID, err := decodeWalletUsageCursor(cursor)
	if err != nil {
		return nil, "", err
	}
	whereCursor := ""
	args := []any{accountID, sessionID, encodeTime(since.UTC()), encodeTime(until.UTC())}
	if cursorCreatedAt != "" {
		whereCursor = ` AND (sr.created_at < ? OR (sr.created_at = ? AND sr.request_id < ?))`
		args = append(args, cursorCreatedAt, cursorCreatedAt, cursorRequestID)
	}
	args = append(args, limit+1)
	rows, err := s.db.QueryContext(ctx, `
		SELECT
			sr.request_id,
			COALESCE(wrm.model_id, ''),
			sr.reserved_tokens,
			sr.settled_tokens,
			sr.status,
			sr.created_at,
			sr.settled_at,
			CASE WHEN ue.request_id IS NULL THEN 0 ELSE 1 END,
			COALESCE(ue.prompt_tokens, 0),
			COALESCE(ue.completion_tokens, 0),
			COALESCE(ue.total_tokens, 0),
			COALESCE(ue.token_source, ''),
			COALESCE(ue.outcome, ''),
			COALESCE(ue.created_at, '')
		FROM wallet_session_reservations sr
		LEFT JOIN wallet_session_request_map wrm
			ON wrm.account_id = sr.account_id AND wrm.request_id = sr.request_id AND wrm.session_id = sr.session_id
		LEFT JOIN usage_events ue
			ON ue.account_id = sr.account_id AND ue.request_id = sr.request_id
		WHERE sr.account_id = ? AND sr.session_id = ?
			AND sr.created_at >= ? AND sr.created_at <= ?`+whereCursor+`
		ORDER BY sr.created_at DESC, sr.request_id DESC
		LIMIT ?`, args...)
	if err != nil {
		return nil, "", err
	}
	defer rows.Close()
	details := make([]storage.WalletSessionUsageDetail, 0, limit)
	var nextCursor string
	for rows.Next() {
		var detail storage.WalletSessionUsageDetail
		var reservationCreatedAt, reservationSettledAt, usageCreatedAt string
		var hasUsage int
		if err := rows.Scan(
			&detail.RequestID, &detail.ModelID, &detail.ReservedTokens, &detail.SettledTokens,
			&detail.TerminalStatus, &reservationCreatedAt, &reservationSettledAt, &hasUsage,
			&detail.PromptTokens, &detail.CompletionTokens, &detail.TotalTokens,
			&detail.TokenSource, &detail.Outcome, &usageCreatedAt,
		); err != nil {
			return nil, "", err
		}
		if len(details) == limit {
			nextCursor = encodeWalletUsageCursor(details[len(details)-1].ReservationCreatedAt, details[len(details)-1].RequestID)
			break
		}
		detail.ReservationCreatedAt = decodeTime(reservationCreatedAt)
		detail.ReservationSettledAt = decodeTime(reservationSettledAt)
		detail.UsageEventCreatedAt = decodeTime(usageCreatedAt)
		detail.QuotaReservationID = "qres_" + detail.RequestID
		detail.SessionReservationID = "wsres_" + detail.RequestID
		if hasUsage == 1 {
			detail.UsageEventID = "uev_" + detail.RequestID
		}
		detail.ReconciliationStatus = walletUsageReconciliationStatus(detail.TerminalStatus, hasUsage == 1)
		details = append(details, detail)
	}
	if err := rows.Err(); err != nil {
		return nil, "", err
	}
	return details, nextCursor, nil
}

func (s *Store) RevokeWalletSession(ctx context.Context, accountID, sessionID, actor, reason string, revokedAt time.Time) error {
	if revokedAt.IsZero() {
		revokedAt = time.Now().UTC()
	}
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	res, err := tx.ExecContext(ctx, `
		UPDATE wallet_sessions
		SET status = 'revoked', revoked_at = ?, revoked_by = ?, revoked_reason = ?
		WHERE account_id = ? AND session_id = ? AND status = 'active'`,
		encodeTime(revokedAt.UTC()), actor, reason, accountID, sessionID)
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
	if err := refundClaimedWalletAdmissionsTx(ctx, tx, accountID, sessionID, revokedAt.UTC()); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) AdmitWalletSessionInference(ctx context.Context, req storage.WalletSessionAdmissionRequest) (storage.WalletSessionAdmissionDecision, error) {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return storage.WalletSessionAdmissionDecision{}, err
	}
	defer tx.Rollback()
	if req.CreatedAt.IsZero() {
		req.CreatedAt = time.Now().UTC()
	}
	now := req.CreatedAt.UTC()
	if req.ExpiresAt.IsZero() {
		req.ExpiresAt = now.Add(24 * time.Hour)
	}
	if req.Replay.SessionID == "" {
		req.Replay.SessionID = req.SessionID
	}
	if req.Replay.RequestID == "" {
		req.Replay.RequestID = req.RequestID
	}
	if req.Replay.Method == "" {
		req.Replay.Method = req.Method
	}
	if req.Replay.CanonicalRoute == "" {
		req.Replay.CanonicalRoute = req.CanonicalRoute
	}
	if _, err := reapExpiredReservationsTx(ctx, tx, now); err != nil {
		return storage.WalletSessionAdmissionDecision{}, err
	}
	session, accountStatus, err := activeWalletSessionTx(ctx, tx, req.AccountID, req.SessionID, now)
	if err != nil {
		return storage.WalletSessionAdmissionDecision{}, err
	}
	if accountStatus != "active" {
		return storage.WalletSessionAdmissionDecision{}, storage.ErrWalletSessionInactive
	}
	if req.ModelID != "" && !walletSessionAllowsModel(session.ModelAllowlistJSON, req.ModelID) {
		return storage.WalletSessionAdmissionDecision{}, storage.ErrWalletSessionModelDenied
	}
	if req.RequestedTokens > session.PerRequestTokenCap {
		return storage.WalletSessionAdmissionDecision{}, storage.ErrWalletSessionPerRequestCap
	}
	if err := insertWalletReplayTx(ctx, tx, req.Replay, "claimed", now); err != nil {
		return storage.WalletSessionAdmissionDecision{}, err
	}
	sessionUsed, sessionReserved, err := walletSessionExposureTx(ctx, tx, req.SessionID)
	if err != nil {
		return storage.WalletSessionAdmissionDecision{}, err
	}
	remainingSession := session.TotalTokenCap - sessionUsed - sessionReserved
	decision := storage.WalletSessionAdmissionDecision{
		Admitted: false, AccountID: req.AccountID, SessionID: req.SessionID, RequestID: req.RequestID,
		SessionUsed: sessionUsed, SessionReserved: sessionReserved, SessionRemaining: max64(0, remainingSession),
	}
	if req.RequestedTokens > remainingSession {
		return decision, storage.ErrWalletSessionCapExceeded
	}
	used, reserved, err := dailyUsageTx(ctx, tx, req.AccountID, req.WindowDate)
	if err != nil {
		return storage.WalletSessionAdmissionDecision{}, err
	}
	accountRemaining := req.DailyQuota - used - reserved
	decision.AccountQuota = storage.QuotaDecision{
		Admitted: false, LimitTokens: req.DailyQuota, UsedTokens: used, ReservedTokens: reserved,
		RemainingTokens: max64(0, accountRemaining), ResetUnix: resetUnix(req.WindowDate),
	}
	if req.RequestedTokens > accountRemaining {
		return decision, storage.ErrQuotaExceeded
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO quota_reservations(account_id, request_id, window_date, reserved_tokens, status, expires_at, created_at)
		VALUES(?, ?, ?, ?, 'active', ?, ?)`,
		req.AccountID, req.RequestID, req.WindowDate, req.RequestedTokens, encodeTime(req.ExpiresAt.UTC()), encodeTime(now)); err != nil {
		if isUniqueConstraintError(err) {
			return storage.WalletSessionAdmissionDecision{}, storage.ErrReservationExists
		}
		return storage.WalletSessionAdmissionDecision{}, err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO wallet_session_reservations(session_id, request_id, account_id, reserved_tokens, status, expires_at, created_at)
		VALUES(?, ?, ?, ?, 'active', ?, ?)`,
		req.SessionID, req.RequestID, req.AccountID, req.RequestedTokens, encodeTime(req.ExpiresAt.UTC()), encodeTime(now)); err != nil {
		return storage.WalletSessionAdmissionDecision{}, err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO wallet_session_request_map(account_id, request_id, session_id, session_reservation_id, canonical_route, model_id, created_at)
		VALUES(?, ?, ?, ?, ?, ?, ?)`,
		req.AccountID, req.RequestID, req.SessionID, req.RequestID, req.CanonicalRoute, req.ModelID, encodeTime(now)); err != nil {
		return storage.WalletSessionAdmissionDecision{}, err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE wallet_session_replays
		SET account_reservation_id = ?, session_reservation_id = ?, updated_at = ?
		WHERE session_id = ? AND request_id = ?`,
		req.RequestID, req.RequestID, encodeTime(now), req.SessionID, req.RequestID); err != nil {
		return storage.WalletSessionAdmissionDecision{}, err
	}
	decision.Admitted = true
	decision.AccountQuota.Admitted = true
	decision.AccountQuota.ReservedTokens += req.RequestedTokens
	decision.AccountQuota.RemainingTokens = max64(0, accountRemaining-req.RequestedTokens)
	decision.SessionReserved += req.RequestedTokens
	decision.SessionRemaining = max64(0, remainingSession-req.RequestedTokens)
	return decision, tx.Commit()
}

func (s *Store) AdmitWalletSessionMetadata(ctx context.Context, req storage.WalletSessionMetadataAdmissionRequest) error {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if req.CreatedAt.IsZero() {
		req.CreatedAt = time.Now().UTC()
	}
	now := req.CreatedAt.UTC()
	if req.Replay.SessionID == "" {
		req.Replay.SessionID = req.SessionID
	}
	if req.Replay.RequestID == "" {
		return storage.ErrWalletSessionReplayMismatch
	}
	if _, _, err := activeWalletSessionTx(ctx, tx, req.AccountID, req.SessionID, now); err != nil {
		return err
	}
	if existing, matched, err := walletReplayMaterialMatchTx(ctx, tx, req.Replay); err != nil {
		return err
	} else if existing {
		if matched {
			return storage.ErrWalletSessionReplayDuplicate
		}
		return storage.ErrWalletSessionReplayMismatch
	}
	if req.MaxReplayRows > 0 || req.MaxReplayBytes > 0 {
		rows, bytes, err := walletReplayCapacityTx(ctx, tx, req.SessionID)
		if err != nil {
			return err
		}
		if (req.MaxReplayRows > 0 && rows >= req.MaxReplayRows) || (req.MaxReplayBytes > 0 && bytes+req.Replay.BodyBytes > req.MaxReplayBytes) {
			return storage.ErrWalletSessionReplayCapacity
		}
	}
	if req.RateLimit > 0 {
		var count int
		if err := tx.QueryRowContext(ctx, `
			SELECT COUNT(*) FROM wallet_session_replays
			WHERE session_id = ? AND metadata_client_ip = ? AND created_at >= ?`,
			req.SessionID, req.Replay.MetadataClientIP, encodeTime(req.WindowStart.UTC())).Scan(&count); err != nil {
			return err
		}
		if count >= req.RateLimit {
			return storage.ErrRateLimit
		}
	}
	if err := insertWalletReplayTx(ctx, tx, req.Replay, "metadata_only", now); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) ArmWalletSessionDispatch(ctx context.Context, arm storage.WalletSessionDispatchArm) error {
	if arm.ArmedAt.IsZero() {
		arm.ArmedAt = time.Now().UTC()
	}
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, _, err := activeWalletSessionTx(ctx, tx, arm.AccountID, arm.SessionID, arm.ArmedAt.UTC()); err != nil {
		return err
	}
	var replayState, replayRoute, reservationStatus, quotaStatus string
	var reservedTokens int64
	if err := tx.QueryRowContext(ctx, `
		SELECT r.state, r.canonical_route, sr.status, qr.status, sr.reserved_tokens
		FROM wallet_session_replays r
		JOIN wallet_session_reservations sr ON sr.session_id = r.session_id AND sr.request_id = r.request_id
		JOIN quota_reservations qr ON qr.account_id = sr.account_id AND qr.request_id = sr.request_id
		WHERE r.session_id = ? AND r.request_id = ? AND sr.account_id = ?`,
		arm.SessionID, arm.RequestID, arm.AccountID).Scan(&replayState, &replayRoute, &reservationStatus, &quotaStatus, &reservedTokens); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.ErrWalletSessionDispatchFence
		}
		return err
	}
	if replayState != "claimed" || reservationStatus != "active" || quotaStatus != "active" ||
		(arm.CanonicalRoute != "" && replayRoute != arm.CanonicalRoute) {
		return storage.ErrWalletSessionDispatchFence
	}
	res, err := tx.ExecContext(ctx, `
		UPDATE wallet_session_replays
		SET state = 'dispatch_armed',
			dispatch_armed_at = ?,
			recovery_policy = 'hold_until_settlement_finality',
			intended_effect = 'wallet_session_inference',
			reserved_tokens = ?,
			updated_at = ?
		WHERE session_id = ? AND request_id = ? AND state = 'claimed'`,
		encodeTime(arm.ArmedAt.UTC()), reservedTokens, encodeTime(arm.ArmedAt.UTC()), arm.SessionID, arm.RequestID)
	if err != nil {
		return err
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return storage.ErrWalletSessionDispatchFence
	}
	return tx.Commit()
}

func (s *Store) MarkWalletSessionDispatched(ctx context.Context, sessionID, requestID string, dispatchedAt time.Time) error {
	if dispatchedAt.IsZero() {
		dispatchedAt = time.Now().UTC()
	}
	res, err := s.db.ExecContext(ctx, `
		UPDATE wallet_session_replays
		SET state = 'dispatched', dispatched_at = ?, updated_at = ?
		WHERE session_id = ? AND request_id = ? AND state = 'dispatch_armed'`,
		encodeTime(dispatchedAt.UTC()), encodeTime(dispatchedAt.UTC()), sessionID, requestID)
	if err != nil {
		return err
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return storage.ErrWalletSessionDispatchFence
	}
	return nil
}

func (s *Store) HoldStaleWalletSessionDispatchArms(ctx context.Context, before, heldAt time.Time) (int64, error) {
	if heldAt.IsZero() {
		heldAt = time.Now().UTC()
	}
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	rows, err := tx.QueryContext(ctx, `
		SELECT sr.account_id, sr.session_id, sr.request_id
		FROM wallet_session_reservations sr
		JOIN wallet_session_replays r ON r.session_id = sr.session_id AND r.request_id = sr.request_id
		WHERE sr.status = 'active'
			AND r.state IN ('dispatch_armed', 'dispatched')
			AND r.updated_at < ?
		ORDER BY r.updated_at ASC`, encodeTime(before.UTC()))
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	type staleArm struct {
		accountID string
		sessionID string
		requestID string
	}
	var stale []staleArm
	for rows.Next() {
		var row staleArm
		if err := rows.Scan(&row.accountID, &row.sessionID, &row.requestID); err != nil {
			return 0, err
		}
		stale = append(stale, row)
	}
	if err := rows.Err(); err != nil {
		return 0, err
	}
	var held int64
	for _, row := range stale {
		if err := transitionWalletSessionReservationTx(ctx, tx, row.accountID, row.sessionID, row.requestID, "held", "held", heldAt.UTC()); err != nil {
			if errors.Is(err, storage.ErrReservationNotFound) {
				continue
			}
			return 0, err
		}
		held++
	}
	return held, tx.Commit()
}

func (s *Store) RefundStaleWalletSessionClaims(ctx context.Context, before, refundedAt time.Time) (int64, error) {
	if refundedAt.IsZero() {
		refundedAt = time.Now().UTC()
	}
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	refunded, err := refundStaleWalletSessionClaimsTx(ctx, tx, before.UTC(), refundedAt.UTC())
	if err != nil {
		return 0, err
	}
	return refunded, tx.Commit()
}

func (s *Store) FinalizeWalletSessionReservation(ctx context.Context, settlement storage.WalletSessionReservationSettlement) error {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if settlement.SettledAt.IsZero() {
		settlement.SettledAt = time.Now().UTC()
	}
	accountSettlement := storage.ReservationSettlement{
		AccountID: settlement.AccountID, RequestID: settlement.RequestID, PromptTokens: settlement.PromptTokens,
		CompletionTokens: settlement.CompletionTokens, TotalTokens: settlement.TotalTokens, MaxTotalTokens: settlement.MaxTotalTokens,
		TokenSource: settlement.TokenSource, Outcome: settlement.Outcome, SettledAt: settlement.SettledAt,
	}
	if err := normalizeSettlementTokens(&accountSettlement); err != nil {
		return err
	}
	var windowDate, quotaStatus, sessionStatus string
	if err := tx.QueryRowContext(ctx, `
		SELECT qr.window_date, qr.status, sr.status
		FROM quota_reservations qr
		JOIN wallet_session_reservations sr ON sr.account_id = qr.account_id AND sr.request_id = qr.request_id
		WHERE qr.account_id = ? AND qr.request_id = ? AND sr.session_id = ?`,
		settlement.AccountID, settlement.RequestID, settlement.SessionID).Scan(&windowDate, &quotaStatus, &sessionStatus); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.ErrReservationNotFound
		}
		return err
	}
	if quotaStatus != "active" || (sessionStatus != "active" && sessionStatus != "held") {
		return fmt.Errorf("%w: wallet reservation %s is %s/%s", storage.ErrReservationTerminal, settlement.RequestID, quotaStatus, sessionStatus)
	}
	when := encodeTime(settlement.SettledAt.UTC())
	if _, err := tx.ExecContext(ctx, `
		UPDATE quota_reservations
		SET status = 'settled', settled_tokens = ?, settled_at = ?
		WHERE account_id = ? AND request_id = ? AND status = 'active'`,
		accountSettlement.TotalTokens, when, settlement.AccountID, settlement.RequestID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE wallet_session_reservations
		SET status = 'settled', settled_tokens = ?, settled_at = ?
		WHERE session_id = ? AND request_id = ? AND status IN ('active', 'held')`,
		accountSettlement.TotalTokens, when, settlement.SessionID, settlement.RequestID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO usage_events(request_id, account_id, window_date, prompt_tokens, completion_tokens, total_tokens, token_source, outcome, created_at)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		settlement.RequestID, settlement.AccountID, windowDate, accountSettlement.PromptTokens, accountSettlement.CompletionTokens,
		accountSettlement.TotalTokens, accountSettlement.TokenSource, accountSettlement.Outcome, when); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE wallet_session_replays
		SET state = 'finalized', terminal_state = ?, updated_at = ?
		WHERE session_id = ? AND request_id = ?`,
		settlement.Outcome, when, settlement.SessionID, settlement.RequestID); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) RefundWalletSessionReservation(ctx context.Context, accountID, sessionID, requestID string, refundedAt time.Time) error {
	if refundedAt.IsZero() {
		refundedAt = time.Now().UTC()
	}
	return s.transitionWalletSessionReservation(ctx, accountID, sessionID, requestID, "refunded", "refunded", refundedAt.UTC())
}

func (s *Store) SealWalletSessionUsageEvent(ctx context.Context, accountID, sessionID, requestID string, settledTokens int64, sealedAt time.Time) error {
	if sealedAt.IsZero() {
		sealedAt = time.Now().UTC()
	}
	if settledTokens < 0 {
		return fmt.Errorf("settled tokens must be non-negative")
	}
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	whenText := encodeTime(sealedAt.UTC())
	res, err := tx.ExecContext(ctx, `
		UPDATE wallet_session_reservations
		SET status = 'settled', settled_tokens = ?, settled_at = ?
		WHERE account_id = ? AND session_id = ? AND request_id = ? AND status IN ('active', 'held')`,
		settledTokens, whenText, accountID, sessionID, requestID)
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
	if _, err := tx.ExecContext(ctx, `
		UPDATE quota_reservations
		SET status = 'settled', settled_tokens = ?, settled_at = ?, settlement_hold = 0
		WHERE account_id = ? AND request_id = ? AND status = 'active'`,
		settledTokens, whenText, accountID, requestID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE wallet_session_replays
		SET state = 'finalized', terminal_state = 'usage_event', updated_at = ?
		WHERE session_id = ? AND request_id = ?`,
		whenText, sessionID, requestID); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) HoldWalletSessionReservation(ctx context.Context, accountID, sessionID, requestID string, heldAt time.Time) error {
	if heldAt.IsZero() {
		heldAt = time.Now().UTC()
	}
	return s.transitionWalletSessionReservation(ctx, accountID, sessionID, requestID, "held", "held", heldAt.UTC())
}

func (s *Store) QuarantineWalletSessionReservation(ctx context.Context, accountID, sessionID, requestID string, quarantinedAt time.Time) error {
	if quarantinedAt.IsZero() {
		quarantinedAt = time.Now().UTC()
	}
	return s.transitionWalletSessionReservation(ctx, accountID, sessionID, requestID, "quarantined", "quarantined", quarantinedAt.UTC())
}

func (s *Store) MarkWalletSessionReservationStaleHeld(ctx context.Context, accountID, sessionID, requestID string, staleAt time.Time) error {
	if staleAt.IsZero() {
		staleAt = time.Now().UTC()
	}
	return s.transitionWalletSessionReservation(ctx, accountID, sessionID, requestID, "stale_held", "stale_held", staleAt.UTC())
}

func (s *Store) transitionWalletSessionReservation(ctx context.Context, accountID, sessionID, requestID, status, replayState string, when time.Time) error {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := transitionWalletSessionReservationTx(ctx, tx, accountID, sessionID, requestID, status, replayState, when); err != nil {
		return err
	}
	return tx.Commit()
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
	return s.ListFeedbackEventsSinceLimit(ctx, since, 0)
}

func (s *Store) ListFeedbackEventsSinceLimit(ctx context.Context, since time.Time, limit int) ([]storage.FeedbackSummaryEvent, error) {
	limitClause := ""
	args := []any{encodeTime(since)}
	if limit > 0 {
		limitClause = " LIMIT ?"
		args = append(args, limit)
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT event_id, request_id, account_id, scope, rating, comment, created_at
		FROM feedback_events
		WHERE created_at >= ?
		ORDER BY created_at DESC`+limitClause, args...)
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
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := func() error {
		current, err := getKillSwitchTx(ctx, tx)
		if err != nil {
			return err
		}
		state.Version = current.Version + 1
		return setKillSwitchTx(ctx, tx, state)
	}(); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) CompareAndSwapKillSwitch(ctx context.Context, expectedVersion int64, state storage.KillSwitchState) (bool, error) {
	if state.UpdatedAt.IsZero() {
		state.UpdatedAt = time.Now().UTC()
	}
	applied := false
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	if err := func() error {
		current, err := getKillSwitchTx(ctx, tx)
		if err != nil {
			return err
		}
		if current.Version != expectedVersion {
			return nil
		}
		state.Version = current.Version + 1
		if err := setKillSwitchTx(ctx, tx, state); err != nil {
			return err
		}
		applied = true
		return nil
	}(); err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return applied, err
}

func getKillSwitchTx(ctx context.Context, tx queryer) (storage.KillSwitchState, error) {
	row := tx.QueryRowContext(ctx, `SELECT value, updated_at FROM runtime_config WHERE key = 'kill_switch'`)
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

func setKillSwitchTx(ctx context.Context, tx execer, state storage.KillSwitchState) error {
	value, err := json.Marshal(struct {
		DemoOnly     bool  `json:"demo_only"`
		AllPublicAPI bool  `json:"all_public_api"`
		Version      int64 `json:"version"`
	}{DemoOnly: state.DemoOnly, AllPublicAPI: state.AllPublicAPI, Version: state.Version})
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `
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
	if _, err := refundExpiredWalletSessionClaimsTx(ctx, q, now.UTC()); err != nil {
		return 0, err
	}
	res, err := q.ExecContext(ctx, `
		UPDATE quota_reservations
		SET status = 'expired', settled_tokens = 0, settled_at = ?
		WHERE status = 'active' AND settlement_hold = 0 AND expires_at <= ?
			AND NOT EXISTS (
				SELECT 1
				FROM wallet_session_reservations sr
				JOIN wallet_session_replays r ON r.session_id = sr.session_id AND r.request_id = sr.request_id
				WHERE sr.account_id = quota_reservations.account_id
					AND sr.request_id = quota_reservations.request_id
					AND sr.status = 'active'
					AND r.state IN ('dispatch_armed', 'dispatched')
			)`,
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

type rowScanner interface {
	Scan(dest ...any) error
}

func scanWalletSession(row rowScanner) (storage.WalletSession, error) {
	var session storage.WalletSession
	var expiresAt, createdAt, revokedAt string
	if err := row.Scan(
		&session.SessionID, &session.AccountID, &session.WalletNamespace, &session.WalletFingerprint,
		&session.Status, &expiresAt, &session.TotalTokenCap, &session.PerRequestTokenCap,
		&session.ModelAllowlistJSON, &session.BearerHash, &session.BearerKeyID,
		&session.VerificationPublicKey, &session.SessionPublicKey, &createdAt, &revokedAt,
		&session.RevokedBy, &session.RevokedReason,
	); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.WalletSession{}, storage.ErrNotFound
		}
		return storage.WalletSession{}, err
	}
	session.ExpiresAt = decodeTime(expiresAt)
	session.CreatedAt = decodeTime(createdAt)
	session.RevokedAt = decodeTime(revokedAt)
	return session, nil
}

func walletChallengeByNonceTx(ctx context.Context, tx *immediateTx, nonceHash []byte) (storage.WalletSessionChallenge, error) {
	var challenge storage.WalletSessionChallenge
	var requestedExpiresAt, createdAt, expiresAt, consumedAt string
	if err := tx.QueryRowContext(ctx, `
		SELECT nonce_hash, account_id, wallet_namespace, wallet_fingerprint, purpose, audience,
			requested_expires_at, per_request_token_cap, total_token_cap, model_allowlist_json,
			session_public_key, created_at, expires_at, consumed_at, consumed_session_id
		FROM wallet_session_challenges
		WHERE nonce_hash = ?`, nonceHash).Scan(
		&challenge.NonceHash, &challenge.AccountID, &challenge.WalletNamespace, &challenge.WalletFingerprint,
		&challenge.Purpose, &challenge.Audience, &requestedExpiresAt, &challenge.PerRequestTokenCap,
		&challenge.TotalTokenCap, &challenge.ModelAllowlistJSON, &challenge.SessionPublicKey,
		&createdAt, &expiresAt, &consumedAt, &challenge.ConsumedSessionID,
	); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.WalletSessionChallenge{}, storage.ErrNotFound
		}
		return storage.WalletSessionChallenge{}, err
	}
	challenge.RequestedExpiresAt = decodeTime(requestedExpiresAt)
	challenge.CreatedAt = decodeTime(createdAt)
	challenge.ExpiresAt = decodeTime(expiresAt)
	challenge.ConsumedAt = decodeTime(consumedAt)
	return challenge, nil
}

func activeWalletSessionCountTx(ctx context.Context, tx *immediateTx, predicate string, now time.Time, args ...any) (int, error) {
	query := `SELECT COUNT(*) FROM wallet_sessions WHERE status = 'active' AND expires_at > ? AND ` + predicate
	allArgs := append([]any{encodeTime(now.UTC())}, args...)
	var count int
	if err := tx.QueryRowContext(ctx, query, allArgs...).Scan(&count); err != nil {
		return 0, err
	}
	return count, nil
}

func activeWalletSessionTx(ctx context.Context, tx *immediateTx, accountID, sessionID string, now time.Time) (storage.WalletSession, string, error) {
	var accountStatus string
	row := tx.QueryRowContext(ctx, `
		SELECT ws.session_id, ws.account_id, ws.wallet_namespace, ws.wallet_fingerprint, ws.status, ws.expires_at,
			ws.total_token_cap, ws.per_request_token_cap, ws.model_allowlist_json, ws.bearer_hash, ws.bearer_key_id,
			ws.verification_public_key, ws.session_public_key, ws.created_at, ws.revoked_at, ws.revoked_by, ws.revoked_reason,
			a.status
		FROM wallet_sessions ws
		JOIN accounts a ON a.account_id = ws.account_id
		WHERE ws.account_id = ? AND ws.session_id = ?`,
		accountID, sessionID)
	var session storage.WalletSession
	var expiresAt, createdAt, revokedAt string
	if err := row.Scan(
		&session.SessionID, &session.AccountID, &session.WalletNamespace, &session.WalletFingerprint,
		&session.Status, &expiresAt, &session.TotalTokenCap, &session.PerRequestTokenCap,
		&session.ModelAllowlistJSON, &session.BearerHash, &session.BearerKeyID,
		&session.VerificationPublicKey, &session.SessionPublicKey, &createdAt, &revokedAt,
		&session.RevokedBy, &session.RevokedReason, &accountStatus,
	); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.WalletSession{}, "", storage.ErrNotFound
		}
		return storage.WalletSession{}, "", err
	}
	session.ExpiresAt = decodeTime(expiresAt)
	session.CreatedAt = decodeTime(createdAt)
	session.RevokedAt = decodeTime(revokedAt)
	if session.Status != "active" || accountStatus != "active" || !now.Before(session.ExpiresAt) {
		return storage.WalletSession{}, accountStatus, storage.ErrWalletSessionInactive
	}
	return session, accountStatus, nil
}

func walletSessionAllowsModel(allowlistJSON, modelID string) bool {
	var models []string
	if err := json.Unmarshal([]byte(allowlistJSON), &models); err != nil {
		return false
	}
	for _, model := range models {
		if model == modelID {
			return true
		}
	}
	return false
}

func insertWalletReplayTx(ctx context.Context, tx *immediateTx, replay storage.WalletSessionReplayMaterial, state string, now time.Time) error {
	if existing, matched, err := walletReplayMaterialMatchTx(ctx, tx, replay); err != nil {
		return err
	} else if existing {
		if matched {
			return storage.ErrWalletSessionReplayDuplicate
		}
		return storage.ErrWalletSessionReplayMismatch
	}
	_, err := tx.ExecContext(ctx, `
		INSERT INTO wallet_session_replays(
			session_id, request_id, method, canonical_route, semantic_headers_hash, raw_body_hash,
			body_bytes, metadata_client_ip, state, created_at, updated_at)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		replay.SessionID, replay.RequestID, replay.Method, replay.CanonicalRoute, replay.SemanticHeadersHash,
		replay.RawBodyHash, replay.BodyBytes, replay.MetadataClientIP, state, encodeTime(now.UTC()), encodeTime(now.UTC()))
	if isUniqueConstraintError(err) {
		return storage.ErrWalletSessionReplayDuplicate
	}
	return err
}

func walletReplayMaterialMatchTx(ctx context.Context, tx *immediateTx, replay storage.WalletSessionReplayMaterial) (bool, bool, error) {
	var method, route, metadataClientIP string
	var semanticHash, rawBodyHash []byte
	var bodyBytes int64
	err := tx.QueryRowContext(ctx, `
		SELECT method, canonical_route, semantic_headers_hash, raw_body_hash, body_bytes, metadata_client_ip
		FROM wallet_session_replays
		WHERE session_id = ? AND request_id = ?`,
		replay.SessionID, replay.RequestID).Scan(&method, &route, &semanticHash, &rawBodyHash, &bodyBytes, &metadataClientIP)
	if errors.Is(err, sql.ErrNoRows) {
		return false, false, nil
	}
	if err != nil {
		return false, false, err
	}
	matched := method == replay.Method && route == replay.CanonicalRoute &&
		bytesEqual(semanticHash, replay.SemanticHeadersHash) &&
		bytesEqual(rawBodyHash, replay.RawBodyHash) &&
		bodyBytes == replay.BodyBytes && metadataClientIP == replay.MetadataClientIP
	return true, matched, nil
}

func walletSessionExposureTx(ctx context.Context, tx *immediateTx, sessionID string) (used int64, reserved int64, err error) {
	var usedNull, reservedNull sql.NullInt64
	if err := tx.QueryRowContext(ctx, `
		SELECT COALESCE(SUM(settled_tokens), 0)
		FROM wallet_session_reservations
		WHERE session_id = ? AND status = 'settled'`, sessionID).Scan(&usedNull); err != nil {
		return 0, 0, err
	}
	if err := tx.QueryRowContext(ctx, `
		SELECT COALESCE(SUM(reserved_tokens), 0)
		FROM wallet_session_reservations
		WHERE session_id = ? AND status IN ('active', 'held', 'quarantined', 'stale_held')`, sessionID).Scan(&reservedNull); err != nil {
		return 0, 0, err
	}
	return usedNull.Int64, reservedNull.Int64, nil
}

func walletReplayCapacityTx(ctx context.Context, tx *immediateTx, sessionID string) (rows int, bytes int64, err error) {
	var bytesNull sql.NullInt64
	if err := tx.QueryRowContext(ctx, `
		SELECT COUNT(*), COALESCE(SUM(body_bytes), 0)
		FROM wallet_session_replays
		WHERE session_id = ?`, sessionID).Scan(&rows, &bytesNull); err != nil {
		return 0, 0, err
	}
	return rows, bytesNull.Int64, nil
}

func refundClaimedWalletAdmissionsTx(ctx context.Context, tx *immediateTx, accountID, sessionID string, when time.Time) error {
	rows, err := tx.QueryContext(ctx, `
		SELECT request_id FROM wallet_session_replays
		WHERE session_id = ? AND state = 'claimed'`, sessionID)
	if err != nil {
		return err
	}
	defer rows.Close()
	var requestIDs []string
	for rows.Next() {
		var requestID string
		if err := rows.Scan(&requestID); err != nil {
			return err
		}
		requestIDs = append(requestIDs, requestID)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	for _, requestID := range requestIDs {
		if err := transitionWalletSessionReservationTx(ctx, tx, accountID, sessionID, requestID, "refunded", "refunded", when); err != nil && !errors.Is(err, storage.ErrReservationNotFound) {
			return err
		}
	}
	return nil
}

func refundStaleWalletSessionClaimsTx(ctx context.Context, q execer, before, refundedAt time.Time) (int64, error) {
	whenText := encodeTime(refundedAt.UTC())
	res, err := q.ExecContext(ctx, `
		UPDATE wallet_session_reservations
		SET status = 'refunded', settled_tokens = 0, settled_at = ?
		WHERE status = 'active'
			AND EXISTS (
				SELECT 1
				FROM wallet_session_replays r
				WHERE r.session_id = wallet_session_reservations.session_id
					AND r.request_id = wallet_session_reservations.request_id
					AND r.state = 'claimed'
					AND r.updated_at < ?
			)`,
		whenText, encodeTime(before.UTC()))
	if err != nil {
		return 0, err
	}
	refunded, err := res.RowsAffected()
	if err != nil {
		return 0, err
	}
	if refunded == 0 {
		return 0, nil
	}
	if _, err := q.ExecContext(ctx, `
		UPDATE quota_reservations
		SET status = 'refunded', settled_tokens = 0, settled_at = ?, settlement_hold = 0
		WHERE status = 'active'
			AND EXISTS (
				SELECT 1
				FROM wallet_session_reservations sr
				JOIN wallet_session_replays r ON r.session_id = sr.session_id AND r.request_id = sr.request_id
				WHERE sr.account_id = quota_reservations.account_id
					AND sr.request_id = quota_reservations.request_id
					AND sr.status = 'refunded'
					AND sr.settled_at = ?
					AND r.state = 'claimed'
					AND r.updated_at < ?
			)`,
		whenText, whenText, encodeTime(before.UTC())); err != nil {
		return 0, err
	}
	if _, err := q.ExecContext(ctx, `
		UPDATE wallet_session_replays
		SET state = 'refunded', terminal_state = 'refunded', updated_at = ?
		WHERE state = 'claimed'
			AND updated_at < ?
			AND EXISTS (
				SELECT 1
				FROM wallet_session_reservations sr
				WHERE sr.session_id = wallet_session_replays.session_id
					AND sr.request_id = wallet_session_replays.request_id
					AND sr.status = 'refunded'
					AND sr.settled_at = ?
			)`,
		whenText, encodeTime(before.UTC()), whenText); err != nil {
		return 0, err
	}
	return refunded, nil
}

func refundExpiredWalletSessionClaimsTx(ctx context.Context, q execer, now time.Time) (int64, error) {
	whenText := encodeTime(now.UTC())
	res, err := q.ExecContext(ctx, `
		UPDATE wallet_session_reservations
		SET status = 'refunded', settled_tokens = 0, settled_at = ?
		WHERE status = 'active'
			AND EXISTS (
				SELECT 1
				FROM wallet_session_replays r
				JOIN quota_reservations qr ON qr.account_id = wallet_session_reservations.account_id
					AND qr.request_id = wallet_session_reservations.request_id
				WHERE r.session_id = wallet_session_reservations.session_id
					AND r.request_id = wallet_session_reservations.request_id
					AND r.state = 'claimed'
					AND qr.status = 'active'
					AND qr.expires_at <= ?
			)`,
		whenText, whenText)
	if err != nil {
		return 0, err
	}
	refunded, err := res.RowsAffected()
	if err != nil {
		return 0, err
	}
	if refunded == 0 {
		return 0, nil
	}
	if _, err := q.ExecContext(ctx, `
		UPDATE quota_reservations
		SET status = 'refunded', settled_tokens = 0, settled_at = ?, settlement_hold = 0
		WHERE status = 'active'
			AND expires_at <= ?
			AND EXISTS (
				SELECT 1
				FROM wallet_session_reservations sr
				JOIN wallet_session_replays r ON r.session_id = sr.session_id AND r.request_id = sr.request_id
				WHERE sr.account_id = quota_reservations.account_id
					AND sr.request_id = quota_reservations.request_id
					AND sr.status = 'refunded'
					AND sr.settled_at = ?
					AND r.state = 'claimed'
			)`,
		whenText, whenText, whenText); err != nil {
		return 0, err
	}
	if _, err := q.ExecContext(ctx, `
		UPDATE wallet_session_replays
		SET state = 'refunded', terminal_state = 'refunded', updated_at = ?
		WHERE state = 'claimed'
			AND EXISTS (
				SELECT 1
				FROM wallet_session_reservations sr
				WHERE sr.session_id = wallet_session_replays.session_id
					AND sr.request_id = wallet_session_replays.request_id
					AND sr.status = 'refunded'
					AND sr.settled_at = ?
			)`,
		whenText, whenText); err != nil {
		return 0, err
	}
	return refunded, nil
}

func transitionWalletSessionReservationTx(ctx context.Context, tx *immediateTx, accountID, sessionID, requestID, status, replayState string, when time.Time) error {
	whenText := encodeTime(when.UTC())
	quotaStatus := "refunded"
	settlementHold := 0
	if status == "held" || status == "quarantined" {
		quotaStatus = "active"
		settlementHold = 1
	} else if status == "stale_held" {
		quotaStatus = "stale_held"
		settlementHold = 1
	}
	var exists int
	if err := tx.QueryRowContext(ctx, `
		SELECT 1
		FROM wallet_session_reservations sr
		JOIN quota_reservations qr ON qr.account_id = sr.account_id AND qr.request_id = sr.request_id
		WHERE sr.account_id = ?
			AND sr.session_id = ?
			AND sr.request_id = ?
			AND sr.status IN ('active', 'held', 'quarantined')
			AND qr.status = 'active'`,
		accountID, sessionID, requestID).Scan(&exists); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.ErrReservationNotFound
		}
		return err
	}
	res, err := tx.ExecContext(ctx, `
		UPDATE wallet_session_reservations
		SET status = ?, settled_tokens = 0, settled_at = ?
		WHERE account_id = ? AND session_id = ? AND request_id = ? AND status IN ('active', 'held', 'quarantined')`,
		status, whenText, accountID, sessionID, requestID)
	if err != nil {
		return err
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return fmt.Errorf("wallet session reservation transition affected %d wallet rows", rows)
	}
	var resQuota sql.Result
	if quotaStatus == "active" {
		resQuota, err = tx.ExecContext(ctx, `
			UPDATE quota_reservations
			SET settlement_hold = ?
			WHERE account_id = ? AND request_id = ? AND status = 'active'`,
			settlementHold, accountID, requestID)
	} else {
		resQuota, err = tx.ExecContext(ctx, `
			UPDATE quota_reservations
			SET status = ?, settled_tokens = 0, settled_at = ?, settlement_hold = ?
			WHERE account_id = ? AND request_id = ? AND status = 'active'`,
			quotaStatus, whenText, settlementHold, accountID, requestID)
	}
	if err != nil {
		return err
	}
	quotaRows, err := resQuota.RowsAffected()
	if err != nil {
		return err
	}
	if quotaRows != 1 {
		return fmt.Errorf("wallet session reservation transition affected %d quota rows", quotaRows)
	}
	_, err = tx.ExecContext(ctx, `
		UPDATE wallet_session_replays
		SET state = ?, terminal_state = ?, updated_at = ?
		WHERE session_id = ? AND request_id = ?`,
		replayState, replayState, whenText, sessionID, requestID)
	return err
}

type walletUsageCursor struct {
	CreatedAt string `json:"created_at"`
	RequestID string `json:"request_id"`
}

func encodeWalletUsageCursor(createdAt time.Time, requestID string) string {
	raw, _ := json.Marshal(walletUsageCursor{CreatedAt: encodeTime(createdAt.UTC()), RequestID: requestID})
	return base64.RawURLEncoding.EncodeToString(raw)
}

func decodeWalletUsageCursor(cursor string) (string, string, error) {
	if strings.TrimSpace(cursor) == "" {
		return "", "", nil
	}
	raw, err := base64.RawURLEncoding.DecodeString(cursor)
	if err != nil {
		return "", "", storage.ErrBadCursor
	}
	var decoded walletUsageCursor
	if err := json.Unmarshal(raw, &decoded); err != nil || decoded.CreatedAt == "" || decoded.RequestID == "" {
		return "", "", storage.ErrBadCursor
	}
	return decoded.CreatedAt, decoded.RequestID, nil
}

func walletUsageReconciliationStatus(status string, hasUsage bool) string {
	switch {
	case status == "settled" && hasUsage:
		return "matched"
	case status == "settled":
		return "settled_missing_usage_event"
	case hasUsage:
		return "usage_event_present"
	case status == "active":
		return "pending"
	case status == "held" || status == "quarantined" || status == "stale_held":
		return status
	default:
		return "reservation_" + status
	}
}

func bytesEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
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

func (tx *immediateTx) QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error) {
	return tx.conn.QueryContext(ctx, query, args...)
}

// immediateTxTerminalTimeout bounds each terminal COMMIT/ROLLBACK statement.
const immediateTxTerminalTimeout = 5 * time.Second

// execTerminal runs a single terminal statement (COMMIT or ROLLBACK) on its own
// fresh, uncancellable context. It is deliberately NOT derived from tx.ctx (the
// request/reconcile context): under an already-cancelled tx.ctx the statement
// would fail without ending the SQLite transaction, and conn.Close() would then
// return a connection with an OPEN transaction to the MaxOpenConns=1 pool —
// poisoning every later writer with "cannot start a transaction within a
// transaction" until restart (the 2026-08-07 gateway quota-reservation outage).
// Each call gets its OWN context so a COMMIT that consumed its whole deadline on
// a lock cannot hand an already-expired context to the compensating ROLLBACK.
func execTerminal(conn *sql.Conn, stmt string) error {
	ctx, cancel := context.WithTimeout(context.Background(), immediateTxTerminalTimeout)
	defer cancel()
	_, err := conn.ExecContext(ctx, stmt)
	return err
}

// discardConn destroys the underlying driver connection so the pool opens a
// fresh one next time instead of reusing this one. Returning driver.ErrBadConn
// from Raw marks the driver connection bad; database/sql then drops it rather
// than returning it to the MaxOpenConns=1 pool. Used only when a transaction
// could not be cleanly terminated, so a connection that may still hold an open
// transaction is never handed to the next borrower.
func discardConn(conn *sql.Conn) {
	_ = conn.Raw(func(any) error { return driver.ErrBadConn })
	_ = conn.Close()
}

func (tx *immediateTx) Commit() error {
	if tx.done {
		return nil
	}
	tx.done = true
	err := execTerminal(tx.conn, "COMMIT")
	if err != nil {
		// COMMIT failed, so the transaction may still be open. Roll it back on
		// a FRESH context (execTerminal), so a COMMIT that exhausted its own
		// deadline cannot leave ROLLBACK unable to run.
		if rbErr := execTerminal(tx.conn, "ROLLBACK"); rbErr != nil {
			// Neither COMMIT nor ROLLBACK could end the transaction; the
			// connection may still be mid-transaction. Discard it rather than
			// return a poisoned connection to the pool.
			discardConn(tx.conn)
			return err
		}
	}
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
	if err := execTerminal(tx.conn, "ROLLBACK"); err != nil {
		// ROLLBACK could not end the transaction; do not return a possibly
		// mid-transaction connection to the pool.
		discardConn(tx.conn)
		return
	}
	_ = tx.conn.Close()
}

func (s *Store) beginImmediate(ctx context.Context) (*immediateTx, error) {
	conn, err := s.db.Conn(ctx)
	if err != nil {
		return nil, err
	}
	if _, err := conn.ExecContext(ctx, "BEGIN IMMEDIATE"); err != nil {
		// Discard rather than return the connection to the pool: defends
		// against a driver/runtime race where BEGIN IMMEDIATE started the
		// transaction before reporting a cancellation, which a plain Close
		// would hand back to the next borrower mid-transaction.
		discardConn(conn)
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
