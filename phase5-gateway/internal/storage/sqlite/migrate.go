package sqlite

// usageEventsTableDDL is the canonical CREATE TABLE for usage_events
// in its post-#196 composite-PK shape. Used both inside schemaSQL
// (fresh installs) and inside ensureUsageEventsCompositePK
// (in-place upgrades) so the sqlite_master.sql entry for the table
// is byte-for-byte identical across paths. ISS-196 R2 architect
// MEDIUM finding.
const usageEventsTableDDL = `CREATE TABLE IF NOT EXISTS usage_events (
	request_id TEXT NOT NULL,
	account_id TEXT NOT NULL,
	demo_identity TEXT NOT NULL DEFAULT '',
	window_date TEXT NOT NULL,
	prompt_tokens INTEGER NOT NULL CHECK (prompt_tokens >= 0),
	completion_tokens INTEGER NOT NULL CHECK (completion_tokens >= 0),
	total_tokens INTEGER NOT NULL CHECK (total_tokens >= 0),
	token_source TEXT NOT NULL CHECK (token_source IN ('provider_reported', 'gateway_estimated', 'manual_fixture', 'coordinator_observed')),
	outcome TEXT NOT NULL,
	created_at TEXT NOT NULL,
	PRIMARY KEY (account_id, request_id)
)`

// usageEventsAuxiliaryDDL is the canonical text for the usage_events
// secondary indexes and append-only triggers. Used both inside
// schemaSQL (for fresh installs) and by ensureUsageEventsCompositePK
// (for in-place upgrades from the pre-issue-#196 single-column PK
// shape) so the post-migration sqlite_master entries are byte-for-byte
// identical to a fresh install. Architect R1 MEDIUM finding.
// demoUsageEventsTableDDL is the canonical CREATE TABLE for
// demo_usage_events in its post-#210 composite-PK shape. The PK
// `(demo_token_hash, request_id)` closes the cross-demo collision
// where two demo identities could share a buyer-controlled
// X-Request-ID and have the second settlement silently drop the
// audit row.
const demoUsageEventsTableDDL = `CREATE TABLE IF NOT EXISTS demo_usage_events (
	request_id TEXT NOT NULL,
	client_ip TEXT NOT NULL,
	demo_token_hash TEXT NOT NULL,
	window_date TEXT NOT NULL,
	total_tokens INTEGER NOT NULL CHECK (total_tokens >= 0),
	created_at TEXT NOT NULL,
	PRIMARY KEY (demo_token_hash, request_id)
)`

// demoUsageEventsAuxiliaryDDL covers the secondary index + append-only
// triggers for demo_usage_events. Mirrors usageEventsAuxiliaryDDL.
const demoUsageEventsAuxiliaryDDL = `
CREATE INDEX IF NOT EXISTS idx_demo_usage_ip_token_date ON demo_usage_events(client_ip, demo_token_hash, window_date);
-- request_id-leading index keeps unscoped audit-trail lookups indexed
-- (explorer activity view, future reconciliation tooling).
CREATE INDEX IF NOT EXISTS idx_demo_usage_request ON demo_usage_events(request_id);

CREATE TRIGGER IF NOT EXISTS demo_usage_events_no_update BEFORE UPDATE ON demo_usage_events
BEGIN
	SELECT RAISE(ABORT, 'demo_usage_events are append-only');
END;
CREATE TRIGGER IF NOT EXISTS demo_usage_events_no_delete BEFORE DELETE ON demo_usage_events
BEGIN
	SELECT RAISE(ABORT, 'demo_usage_events are append-only');
END;
`

const usageEventsAuxiliaryDDL = `
CREATE INDEX IF NOT EXISTS idx_usage_account_date ON usage_events(account_id, window_date);
CREATE INDEX IF NOT EXISTS idx_usage_created_at ON usage_events(created_at);
-- request_id-leading index restored after issue #196 made the PK
-- composite (account_id, request_id). Without this, the explorer
-- "find request by id" path (explorerAccountIDsForRequest, the
-- ambiguity probe, and SPEC-007 session-detail unscoped lookups)
-- would full-scan the table.
CREATE INDEX IF NOT EXISTS idx_usage_request ON usage_events(request_id);

CREATE TRIGGER IF NOT EXISTS usage_events_no_update BEFORE UPDATE ON usage_events
BEGIN
	SELECT RAISE(ABORT, 'usage_events are append-only');
END;
CREATE TRIGGER IF NOT EXISTS usage_events_no_delete BEFORE DELETE ON usage_events
BEGIN
	SELECT RAISE(ABORT, 'usage_events are append-only');
END;
`

const schemaSQL = `
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS schema_migrations (
	version INTEGER PRIMARY KEY,
	applied_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS accounts (
	account_id TEXT PRIMARY KEY,
	status TEXT NOT NULL CHECK (status IN ('active', 'blocked')),
	quota_class TEXT NOT NULL,
	concurrency_class TEXT NOT NULL,
	created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS account_identities (
	account_id TEXT NOT NULL REFERENCES accounts(account_id),
	provider TEXT NOT NULL,
	provider_user_id TEXT NOT NULL,
	email TEXT NOT NULL DEFAULT '',
	created_at TEXT NOT NULL,
	PRIMARY KEY (provider, provider_user_id)
);

CREATE INDEX IF NOT EXISTS idx_account_identities_account ON account_identities(account_id);

CREATE TABLE IF NOT EXISTS oauth_states (
	state_hash BLOB PRIMARY KEY,
	session_id TEXT NOT NULL,
	redirect_uri TEXT NOT NULL,
	client_ip TEXT NOT NULL,
	created_at TEXT NOT NULL,
	expires_at TEXT NOT NULL,
	consumed_at TEXT NOT NULL DEFAULT '',
	action TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_oauth_states_session ON oauth_states(session_id, expires_at);

CREATE TABLE IF NOT EXISTS api_keys (
	key_id TEXT PRIMARY KEY,
	account_id TEXT NOT NULL REFERENCES accounts(account_id),
	key_hash BLOB NOT NULL UNIQUE,
	key_hash_prefix TEXT NOT NULL,
	status TEXT NOT NULL CHECK (status IN ('active', 'revoked')),
	created_at TEXT NOT NULL,
	revoked_at TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_api_keys_hash ON api_keys(key_hash);
CREATE INDEX IF NOT EXISTS idx_api_keys_account ON api_keys(account_id);

CREATE TABLE IF NOT EXISTS api_key_events (
	event_id INTEGER PRIMARY KEY AUTOINCREMENT,
	key_id TEXT NOT NULL,
	account_id TEXT NOT NULL,
	request_id TEXT NOT NULL,
	event_type TEXT NOT NULL,
	actor TEXT NOT NULL,
	created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_api_key_events_key ON api_key_events(key_id);

-- usage_events table: see usageEventsTableDDL constant for the canonical
-- shape. Executed alongside schemaSQL in Migrate() so both paths share
-- one source of truth post-#196.

CREATE TABLE IF NOT EXISTS quota_reservations (
	account_id TEXT NOT NULL,
	request_id TEXT NOT NULL,
	window_date TEXT NOT NULL,
	reserved_tokens INTEGER NOT NULL CHECK (reserved_tokens >= 0),
	settled_tokens INTEGER NOT NULL DEFAULT 0 CHECK (settled_tokens >= 0),
	status TEXT NOT NULL CHECK (status IN ('active', 'settled', 'refunded', 'expired')),
	settlement_hold INTEGER NOT NULL DEFAULT 0 CHECK (settlement_hold IN (0, 1)),
	expires_at TEXT NOT NULL,
	created_at TEXT NOT NULL,
	settled_at TEXT NOT NULL DEFAULT '',
	PRIMARY KEY (account_id, request_id)
);

CREATE INDEX IF NOT EXISTS idx_quota_active_account_date ON quota_reservations(account_id, window_date, status);
CREATE INDEX IF NOT EXISTS idx_quota_expires_at ON quota_reservations(expires_at);
-- #231 R3 SEC MEDIUM closure: request_id-leading index so the
-- §6.4 explorerAccountIDsForRequest ambiguity probe uses an index
-- lookup instead of a full table scan on quota_reservations.
-- Composite PK is (account_id, request_id); without this auxiliary
-- index the ambiguity SELECT goes to SCAN under EXPLAIN QUERY PLAN.
CREATE INDEX IF NOT EXISTS idx_quota_request ON quota_reservations(request_id);

CREATE TABLE IF NOT EXISTS concurrency_reservations (
	account_id TEXT NOT NULL,
	request_id TEXT NOT NULL,
	status TEXT NOT NULL CHECK (status IN ('active', 'released', 'expired')),
	expires_at TEXT NOT NULL,
	created_at TEXT NOT NULL,
	released_at TEXT NOT NULL DEFAULT '',
	PRIMARY KEY (account_id, request_id)
);

CREATE INDEX IF NOT EXISTS idx_concurrency_active_account ON concurrency_reservations(account_id, status, expires_at);
-- #231 R3 SEC MEDIUM closure: matches idx_quota_request — covers the
-- §6.4 ambiguity probe's concurrency_reservations branch.
CREATE INDEX IF NOT EXISTS idx_concurrency_request ON concurrency_reservations(request_id);

CREATE TABLE IF NOT EXISTS feedback_events (
	event_id TEXT PRIMARY KEY,
	request_id TEXT NOT NULL,
	account_id TEXT NOT NULL,
	scope TEXT NOT NULL,
	rating INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 4),
	comment TEXT NOT NULL,
	created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_feedback_request ON feedback_events(request_id);
CREATE INDEX IF NOT EXISTS idx_feedback_created_at ON feedback_events(created_at);

CREATE TABLE IF NOT EXISTS signup_events (
	event_id TEXT PRIMARY KEY,
	account_id TEXT NOT NULL,
	client_ip TEXT NOT NULL,
	provider TEXT NOT NULL,
	created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_signup_ip_created ON signup_events(client_ip, created_at);

CREATE TABLE IF NOT EXISTS demo_session_events (
	event_id TEXT PRIMARY KEY,
	client_ip TEXT NOT NULL,
	created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_demo_session_ip_created ON demo_session_events(client_ip, created_at);

-- demo_usage_events table: see demoUsageEventsTableDDL constant.
-- See [[usageEventsTableDDL]] for the parallel pattern on usage_events
-- (#196). Both fresh installs and in-place upgrades execute the same
-- DDL constants so sqlite_master entries are byte-equal.

CREATE TABLE IF NOT EXISTS audit_events (
	event_id TEXT PRIMARY KEY,
	request_id TEXT NOT NULL,
	account_id TEXT NOT NULL DEFAULT '',
	actor TEXT NOT NULL,
	event_type TEXT NOT NULL,
	payload_json TEXT NOT NULL,
	created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_audit_request ON audit_events(request_id);
CREATE INDEX IF NOT EXISTS idx_audit_created_at ON audit_events(created_at);

CREATE TABLE IF NOT EXISTS capacity_signal_events (
	event_id TEXT PRIMARY KEY,
	signal TEXT NOT NULL,
	value REAL NOT NULL,
	threshold REAL NOT NULL,
	firing INTEGER NOT NULL CHECK (firing IN (0, 1)),
	created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_capacity_signal_created ON capacity_signal_events(signal, created_at);

CREATE TABLE IF NOT EXISTS runtime_config (
	key TEXT PRIMARY KEY,
	value TEXT NOT NULL,
	updated_at TEXT NOT NULL
);

CREATE TRIGGER IF NOT EXISTS feedback_events_no_update BEFORE UPDATE ON feedback_events
BEGIN
	SELECT RAISE(ABORT, 'feedback_events are append-only');
END;
CREATE TRIGGER IF NOT EXISTS feedback_events_no_delete BEFORE DELETE ON feedback_events
BEGIN
	SELECT RAISE(ABORT, 'feedback_events are append-only');
END;
CREATE TRIGGER IF NOT EXISTS audit_events_no_update BEFORE UPDATE ON audit_events
BEGIN
	SELECT RAISE(ABORT, 'audit_events are append-only');
END;
CREATE TRIGGER IF NOT EXISTS audit_events_no_delete BEFORE DELETE ON audit_events
BEGIN
	SELECT RAISE(ABORT, 'audit_events are append-only');
END;
CREATE TRIGGER IF NOT EXISTS api_key_events_no_update BEFORE UPDATE ON api_key_events
BEGIN
	SELECT RAISE(ABORT, 'api_key_events are append-only');
END;
CREATE TRIGGER IF NOT EXISTS api_key_events_no_delete BEFORE DELETE ON api_key_events
BEGIN
	SELECT RAISE(ABORT, 'api_key_events are append-only');
END;
-- demo_usage_events auxiliary DDL (index + triggers) lives in
-- demoUsageEventsAuxiliaryDDL, mirroring the #196 usage_events pattern.
CREATE TRIGGER IF NOT EXISTS capacity_signal_events_no_update BEFORE UPDATE ON capacity_signal_events
BEGIN
	SELECT RAISE(ABORT, 'capacity_signal_events are append-only');
END;
CREATE TRIGGER IF NOT EXISTS capacity_signal_events_no_delete BEFORE DELETE ON capacity_signal_events
BEGIN
	SELECT RAISE(ABORT, 'capacity_signal_events are append-only');
END;
CREATE TRIGGER IF NOT EXISTS signup_events_no_update BEFORE UPDATE ON signup_events
BEGIN
	SELECT RAISE(ABORT, 'signup_events are append-only');
END;
CREATE TRIGGER IF NOT EXISTS signup_events_no_delete BEFORE DELETE ON signup_events
BEGIN
	SELECT RAISE(ABORT, 'signup_events are append-only');
END;
CREATE TRIGGER IF NOT EXISTS demo_session_events_no_update BEFORE UPDATE ON demo_session_events
BEGIN
	SELECT RAISE(ABORT, 'demo_session_events are append-only');
END;
CREATE TRIGGER IF NOT EXISTS demo_session_events_no_delete BEFORE DELETE ON demo_session_events
BEGIN
	SELECT RAISE(ABORT, 'demo_session_events are append-only');
END;
CREATE TRIGGER IF NOT EXISTS concurrency_reservations_no_delete BEFORE DELETE ON concurrency_reservations
BEGIN
	SELECT RAISE(ABORT, 'concurrency_reservations cannot be deleted');
END;
	`
