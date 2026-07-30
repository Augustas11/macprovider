package billing

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	_ "modernc.org/sqlite"
)

type RateCardEntry = config.RateCardEntry
type RewardsConfig = config.RewardsConfig
type SettlementConfig = config.SettlementConfig

type Store struct {
	db           *sql.DB
	now          func() time.Time
	settlementMu sync.RWMutex
	settlement   SettlementConfig
	// SPEC-005 v0.4 §13.2 — billing.quarantine_resolution_force_void_enabled
	// route-layer flag. Held as atomic.Bool so the handler reads it on
	// every request (no re-wire of the HTTP handler on reload).
	// SetForceVoidEnabled is the only writer and emits the
	// billing_config_flag_changed audit event on actual flips.
	// forceVoidReloadMu serializes writes so that the (audit, publish)
	// pair is atomic and the published value is durable in audit_log
	// before any handler can observe it (R2 fix for flag-flip race).
	forceVoidReloadMu      sync.Mutex
	forceVoidEnabled       atomic.Bool
	forceCreditEnabled     atomic.Bool
	forceCreditHoldSeconds atomic.Int64
}

const defaultForceCreditSettlementHoldSeconds int64 = 24 * 60 * 60

func NewStore(db *sql.DB) (*Store, error) {
	if db == nil {
		return nil, fmt.Errorf("db is required")
	}
	s := &Store{db: db, now: time.Now}
	s.forceCreditHoldSeconds.Store(defaultForceCreditSettlementHoldSeconds)
	if err := s.migrate(context.Background()); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Store) migrate(ctx context.Context) error {
	var mode string
	if err := s.db.QueryRowContext(ctx, `PRAGMA journal_mode=WAL`).Scan(&mode); err != nil {
		return err
	}
	if !strings.EqualFold(mode, "wal") {
		return fmt.Errorf("sqlite journal_mode must be WAL, got %s", mode)
	}
	if _, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS ledger_request_credits (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    request_id TEXT NOT NULL,
    attempt_n INTEGER NOT NULL CHECK(attempt_n >= 0),
    provider_id TEXT NOT NULL,
    provider_assigned_id TEXT NULL,
    ts_utc TEXT NOT NULL,
    model TEXT NOT NULL,
    status INTEGER NOT NULL,
    stream INTEGER NOT NULL CHECK(stream IN (0,1)),
    prompt_tokens INTEGER NULL CHECK(prompt_tokens IS NULL OR prompt_tokens >= 0),
    charged_prompt_tokens INTEGER NULL CHECK(charged_prompt_tokens IS NULL OR charged_prompt_tokens >= 0),
    provider_reported_prompt_tokens INTEGER NULL CHECK(provider_reported_prompt_tokens IS NULL OR provider_reported_prompt_tokens >= 0),
    cached_prompt_tokens INTEGER NULL CHECK(cached_prompt_tokens IS NULL OR (cached_prompt_tokens >= 0 AND cached_prompt_tokens <= prompt_tokens)),
    completion_tokens INTEGER NULL CHECK(completion_tokens IS NULL OR completion_tokens >= 0),
    estimated_completion_tokens INTEGER NULL CHECK(estimated_completion_tokens IS NULL OR estimated_completion_tokens >= 0),
    usage_source TEXT NOT NULL CHECK(usage_source IN ('provider_reported','byte_estimated','null_error')),
    prompt_rate_per_mtok INTEGER NOT NULL CHECK(prompt_rate_per_mtok >= 0),
    completion_rate_per_mtok INTEGER NOT NULL CHECK(completion_rate_per_mtok >= 0),
    global_multiplier_ppm INTEGER NOT NULL CHECK(global_multiplier_ppm >= 0),
    gross_credits INTEGER NOT NULL CHECK(gross_credits >= 0),
    provider_share_bps INTEGER NOT NULL CHECK(provider_share_bps BETWEEN 0 AND 10000),
    provider_credits INTEGER NOT NULL CHECK(provider_credits >= 0),
    fault_flag TEXT NOT NULL DEFAULT 'none' CHECK(fault_flag IN ('none','breaker_qualifying','null_usage_error')),
    attestation_class TEXT NULL,
    settled INTEGER NOT NULL DEFAULT 0 CHECK(settled IN (0,1)),
    settlement_id INTEGER NULL,
    quarantined INTEGER NOT NULL DEFAULT 0 CHECK(quarantined IN (0,1)),
    quarantine_reason TEXT NULL,
    settlement_account_scope_hash TEXT NULL CHECK(settlement_account_scope_hash IS NULL OR (length(settlement_account_scope_hash) = 64 AND settlement_account_scope_hash NOT GLOB '*[^0-9a-f]*')),
    settlement_policy_mode TEXT NOT NULL DEFAULT 'legacy' CHECK(settlement_policy_mode IN ('legacy','observe','enforce')),
    settlement_policy_version TEXT NULL,
    recovery_source TEXT NOT NULL DEFAULT 'hot_path' CHECK(recovery_source IN ('hot_path','startup_scan','nightly_reconcile')),
    created_at_utc TEXT NOT NULL,
    updated_at_utc TEXT NULL,
    UNIQUE(request_id, attempt_n, provider_id),
    CHECK(usage_source != 'null_error' OR gross_credits = 0)
);
CREATE INDEX IF NOT EXISTS idx_lrc_provider_ts ON ledger_request_credits(provider_id, ts_utc);
CREATE INDEX IF NOT EXISTS idx_lrc_unsettled ON ledger_request_credits(provider_id, settled, ts_utc);
CREATE INDEX IF NOT EXISTS idx_lrc_request ON ledger_request_credits(request_id);
CREATE INDEX IF NOT EXISTS idx_lrc_quarantine ON ledger_request_credits(quarantined, ts_utc);
CREATE INDEX IF NOT EXISTS idx_lrc_fault ON ledger_request_credits(provider_id, fault_flag, ts_utc);

CREATE TABLE IF NOT EXISTS ledger_operator_credits (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    request_credit_id INTEGER NOT NULL REFERENCES ledger_request_credits(id),
    request_id TEXT NOT NULL,
    attempt_n INTEGER NOT NULL CHECK(attempt_n >= 0),
    provider_id TEXT NOT NULL,
    ts_utc TEXT NOT NULL,
    gross_credits INTEGER NOT NULL CHECK(gross_credits >= 0),
    operator_share_bps INTEGER NOT NULL CHECK(operator_share_bps BETWEEN 0 AND 10000),
    operator_credits INTEGER NOT NULL CHECK(operator_credits >= 0),
    fault_flag TEXT NOT NULL DEFAULT 'none' CHECK(fault_flag IN ('none','breaker_qualifying','null_usage_error')),
    created_at_utc TEXT NOT NULL,
    UNIQUE(request_credit_id)
);
CREATE INDEX IF NOT EXISTS idx_loc_request ON ledger_operator_credits(request_id);
CREATE INDEX IF NOT EXISTS idx_loc_provider_ts ON ledger_operator_credits(provider_id, ts_utc);
CREATE INDEX IF NOT EXISTS idx_loc_ts ON ledger_operator_credits(ts_utc);

CREATE TABLE IF NOT EXISTS ledger_payout_ready (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    provider_id TEXT NOT NULL,
    window_start_utc TEXT NOT NULL,
    window_end_utc TEXT NOT NULL,
    cadence_days INTEGER NOT NULL CHECK(cadence_days > 0),
    source_credit_count INTEGER NOT NULL CHECK(source_credit_count > 0),
    gross_credits INTEGER NOT NULL CHECK(gross_credits >= 0),
    provider_credits INTEGER NOT NULL CHECK(provider_credits >= 0),
    operator_credits INTEGER NOT NULL CHECK(operator_credits >= 0),
    min_payout_credits INTEGER NOT NULL CHECK(min_payout_credits >= 0),
    payout_currency TEXT NULL,
    payout_external_id TEXT NULL,
    status TEXT NOT NULL DEFAULT 'ready' CHECK(status IN ('ready','consumed','voided')),
    idempotency_key TEXT NOT NULL,
    created_at_utc TEXT NOT NULL,
    UNIQUE(provider_id, window_start_utc, window_end_utc),
    UNIQUE(idempotency_key)
);
CREATE INDEX IF NOT EXISTS idx_lpr_provider_status ON ledger_payout_ready(provider_id, status, window_end_utc);
CREATE INDEX IF NOT EXISTS idx_lpr_status ON ledger_payout_ready(status, window_end_utc);
CREATE TRIGGER IF NOT EXISTS trg_lpr_terminal_status_guard
BEFORE UPDATE OF status ON ledger_payout_ready
WHEN OLD.status IN ('consumed','voided') AND NEW.status != OLD.status
BEGIN
    SELECT RAISE(ABORT, 'ledger_payout_ready status is terminal');
END;

CREATE TABLE IF NOT EXISTS ledger_reconciliation_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_type TEXT NOT NULL CHECK(run_type IN ('startup_scan','nightly_reconcile','admin_reconcile','spec_007_claim')),
    from_utc TEXT NOT NULL,
    to_utc TEXT NOT NULL,
    request_log_rows_scanned INTEGER NOT NULL CHECK(request_log_rows_scanned >= 0),
    missing_credit_rows_created INTEGER NOT NULL CHECK(missing_credit_rows_created >= 0),
    orphan_credit_rows_quarantined INTEGER NOT NULL CHECK(orphan_credit_rows_quarantined >= 0),
    buyer_equivalent_credits INTEGER NOT NULL CHECK(buyer_equivalent_credits >= 0),
    provider_gross_credits INTEGER NOT NULL CHECK(provider_gross_credits >= 0),
    reconciliation_delta_credits INTEGER NOT NULL,
    started_at_utc TEXT NOT NULL,
    finished_at_utc TEXT NULL,
    status TEXT NOT NULL CHECK(status IN ('running','complete','failed')),
    error TEXT NULL,
    created_at_utc TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_lrr_type_started ON ledger_reconciliation_runs(run_type, started_at_utc);
CREATE INDEX IF NOT EXISTS idx_lrr_range ON ledger_reconciliation_runs(from_utc, to_utc);

CREATE TABLE IF NOT EXISTS ledger_config_snapshots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    effective_at_utc TEXT NOT NULL,
    config_hash TEXT NOT NULL,
    provider_share_bps INTEGER NOT NULL CHECK(provider_share_bps BETWEEN 0 AND 10000),
    global_multiplier_ppm INTEGER NOT NULL CHECK(global_multiplier_ppm >= 0),
    rate_card_json TEXT NOT NULL,
    created_at_utc TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_lcs_effective_at ON ledger_config_snapshots(effective_at_utc);

	CREATE TABLE IF NOT EXISTS ledger_provider_identity_snapshots (
	    id INTEGER PRIMARY KEY AUTOINCREMENT,
	    request_id TEXT NOT NULL,
	    attempt_n INTEGER NOT NULL CHECK(attempt_n >= 0),
	    provider_assigned_id TEXT NOT NULL,
	    provider_id TEXT NOT NULL,
	    resolved_from TEXT NOT NULL CHECK(resolved_from IN ('pool_entry','response_header','admin_recovery')),
	    pool_session_started_at_utc TEXT NULL,
	    config_snapshot_id INTEGER NULL CHECK(config_snapshot_id IS NULL OR config_snapshot_id > 0),
	    provider_reported_prompt_tokens INTEGER NULL CHECK(provider_reported_prompt_tokens IS NULL OR provider_reported_prompt_tokens >= 0),
	    created_at_utc TEXT NOT NULL,
	    UNIQUE(request_id, attempt_n, provider_assigned_id)
	);
CREATE INDEX IF NOT EXISTS idx_lpis_request ON ledger_provider_identity_snapshots(request_id, attempt_n);
CREATE INDEX IF NOT EXISTS idx_lpis_provider ON ledger_provider_identity_snapshots(provider_id, created_at_utc);

CREATE TABLE IF NOT EXISTS settlement_route_snapshots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_scope TEXT NOT NULL,
    request_id TEXT NOT NULL,
    attempt_n INTEGER NOT NULL CHECK(attempt_n >= 0),
    provider_id TEXT NOT NULL,
    provider_session_id TEXT NULL,
    provider_generation_id TEXT NULL,
    paid_entrypoint TEXT NOT NULL,
    provider_receipt_key_id TEXT NOT NULL CHECK(length(provider_receipt_key_id) = 79 AND substr(provider_receipt_key_id, 1, 15) = 'ed25519-sha256:' AND substr(provider_receipt_key_id, 16) NOT GLOB '*[^0-9a-f]*'),
    provider_receipt_key_source TEXT NOT NULL CHECK(provider_receipt_key_source IN ('auth_session','rotation_grace','operator_pin')),
    model_id TEXT NOT NULL,
    provider_reported_model_hash TEXT NOT NULL CHECK(length(provider_reported_model_hash) = 64 AND provider_reported_model_hash NOT GLOB '*[^0-9a-f]*'),
    expected_catalog_model_hash TEXT NOT NULL CHECK(length(expected_catalog_model_hash) = 64 AND expected_catalog_model_hash NOT GLOB '*[^0-9a-f]*'),
    catalog_id TEXT NOT NULL,
    catalog_body_digest TEXT NOT NULL CHECK(length(catalog_body_digest) = 64 AND catalog_body_digest NOT GLOB '*[^0-9a-f]*'),
    catalog_signature_key_id TEXT NOT NULL,
    catalog_signature_pubkey_fingerprint TEXT NOT NULL CHECK(length(catalog_signature_pubkey_fingerprint) = 79 AND substr(catalog_signature_pubkey_fingerprint, 1, 15) = 'ed25519-sha256:' AND substr(catalog_signature_pubkey_fingerprint, 16) NOT GLOB '*[^0-9a-f]*'),
    catalog_expires_at_unix_ms INTEGER NOT NULL CHECK(catalog_expires_at_unix_ms > 0),
    spec008_hash_status TEXT NOT NULL,
    route_snapshot_policy_version TEXT NOT NULL,
    route_snapshot_mode TEXT NOT NULL CHECK(route_snapshot_mode IN ('observe','enforce')),
    route_decision_ts_unix_ms INTEGER NOT NULL CHECK(route_decision_ts_unix_ms > 0),
    request_start_ts_unix_ms INTEGER NOT NULL CHECK(request_start_ts_unix_ms > 0),
    pending_deadline_seconds INTEGER NOT NULL CHECK(pending_deadline_seconds BETWEEN 1 AND 900),
    prompt_hash_basis TEXT NOT NULL,
    prompt_hash TEXT NOT NULL CHECK(length(prompt_hash) = 64 AND prompt_hash NOT GLOB '*[^0-9a-f]*'),
    route_snapshot_digest TEXT NOT NULL CHECK(length(route_snapshot_digest) = 64 AND route_snapshot_digest NOT GLOB '*[^0-9a-f]*'),
    route_snapshot_json TEXT NOT NULL,
    route_snapshot_canonical_json TEXT NOT NULL,
    created_at_utc TEXT NOT NULL,
    UNIQUE(account_scope, request_id, attempt_n, provider_id)
);
CREATE INDEX IF NOT EXISTS idx_srs_request ON settlement_route_snapshots(account_scope, request_id, attempt_n);
CREATE INDEX IF NOT EXISTS idx_srs_provider ON settlement_route_snapshots(provider_id, created_at_utc);
CREATE INDEX IF NOT EXISTS idx_srs_digest ON settlement_route_snapshots(route_snapshot_digest);

CREATE TABLE IF NOT EXISTS settlement_attempt_outputs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_scope TEXT NOT NULL,
    request_id TEXT NOT NULL,
    attempt_n INTEGER NOT NULL CHECK(attempt_n >= 0),
    provider_id TEXT NOT NULL,
    terminal_state TEXT NOT NULL CHECK(terminal_state IN ('normal_done','provider_error','buyer_cancel','gateway_timeout','upstream_transport_disconnect')),
    terminal_state_ts_unix_ms INTEGER NOT NULL CHECK(terminal_state_ts_unix_ms > 0),
    output_available INTEGER NOT NULL DEFAULT 1 CHECK(output_available IN (0,1)),
    output_prefix_start_byte INTEGER NOT NULL CHECK(output_prefix_start_byte >= 0),
    output_prefix_end_byte INTEGER NOT NULL CHECK(output_prefix_end_byte >= output_prefix_start_byte),
    output_hash TEXT CHECK(output_hash IS NULL OR (length(output_hash) = 64 AND output_hash NOT GLOB '*[^0-9a-f]*')),
    settlement_output_canonical_json TEXT,
    usage_hash TEXT NOT NULL CHECK(length(usage_hash) = 64 AND usage_hash NOT GLOB '*[^0-9a-f]*'),
    usage_canonical_json TEXT NOT NULL,
    usage_source TEXT NOT NULL CHECK(usage_source IN ('coordinator_observed','byte_estimated')),
    overlapping_or_duplicate INTEGER NOT NULL DEFAULT 0 CHECK(overlapping_or_duplicate IN (0,1)),
    created_at_utc TEXT NOT NULL,
    UNIQUE(account_scope, request_id, attempt_n, provider_id)
);
CREATE INDEX IF NOT EXISTS idx_sao_request_range ON settlement_attempt_outputs(account_scope, request_id, output_prefix_start_byte, output_prefix_end_byte);
CREATE INDEX IF NOT EXISTS idx_sao_output_hash ON settlement_attempt_outputs(output_hash);

CREATE TABLE IF NOT EXISTS settlement_receipt_verdicts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_scope_hash TEXT NOT NULL CHECK(length(account_scope_hash) = 64 AND account_scope_hash NOT GLOB '*[^0-9a-f]*'),
    request_id TEXT NOT NULL,
    attempt_n INTEGER NOT NULL CHECK(attempt_n >= 0),
    provider_id TEXT NOT NULL,
    receipt_present INTEGER NOT NULL CHECK(receipt_present IN (0,1)),
    receipt_version TEXT NULL,
    receipt_result TEXT NOT NULL CHECK(receipt_result IN ('valid','invalid','inconclusive')),
    settlement_outcome TEXT NOT NULL CHECK(settlement_outcome IN ('pending','verified','quarantined','zero_settled')),
    reason TEXT NOT NULL,
    idempotency_status TEXT NOT NULL CHECK(idempotency_status IN ('pending','pending_updated','first_terminal','terminal_after_pending','terminal_noop')),
    closed INTEGER NOT NULL CHECK(closed IN (0,1)),
    terminal_state TEXT NOT NULL CHECK(terminal_state IN ('normal_done','provider_error','buyer_cancel','gateway_timeout','upstream_transport_disconnect')),
    terminal_state_ts_unix_ms INTEGER NOT NULL CHECK(terminal_state_ts_unix_ms > 0),
    pending_deadline_unix_ms INTEGER NOT NULL CHECK(pending_deadline_unix_ms > 0),
    received_at_unix_ms INTEGER NOT NULL CHECK(received_at_unix_ms > 0),
    route_snapshot_digest TEXT NOT NULL CHECK(length(route_snapshot_digest) = 64 AND route_snapshot_digest NOT GLOB '*[^0-9a-f]*'),
    route_snapshot_policy_version TEXT NOT NULL,
    route_snapshot_mode TEXT NOT NULL CHECK(route_snapshot_mode IN ('observe','enforce')),
    paid_entrypoint TEXT NOT NULL,
    spec008_hash_status TEXT NOT NULL,
    provider_reported_model_hash TEXT NOT NULL CHECK(length(provider_reported_model_hash) = 64 AND provider_reported_model_hash NOT GLOB '*[^0-9a-f]*'),
    provider_receipt_key_fingerprint TEXT NOT NULL CHECK(length(provider_receipt_key_fingerprint) = 79 AND substr(provider_receipt_key_fingerprint, 1, 15) = 'ed25519-sha256:' AND substr(provider_receipt_key_fingerprint, 16) NOT GLOB '*[^0-9a-f]*'),
    catalog_id TEXT NOT NULL,
    catalog_body_digest TEXT NOT NULL CHECK(length(catalog_body_digest) = 64 AND catalog_body_digest NOT GLOB '*[^0-9a-f]*'),
    expected_catalog_model_hash TEXT NOT NULL CHECK(length(expected_catalog_model_hash) = 64 AND expected_catalog_model_hash NOT GLOB '*[^0-9a-f]*'),
    model_id TEXT NOT NULL,
    model_hash TEXT NULL CHECK(model_hash IS NULL OR (length(model_hash) = 64 AND model_hash NOT GLOB '*[^0-9a-f]*')),
    receipt_profile TEXT NOT NULL CHECK(receipt_profile = 'spec015-v0.4'),
    buyer_debit_outcome TEXT NOT NULL CHECK(buyer_debit_outcome = 'no_money_movement_step5'),
    provider_settlement_outcome TEXT NOT NULL CHECK(provider_settlement_outcome = 'no_money_movement_step5'),
    payout_exclusion_outcome TEXT NOT NULL CHECK(payout_exclusion_outcome = 'excluded_until_spec022_verified'),
    prompt_hash TEXT NOT NULL CHECK(length(prompt_hash) = 64 AND prompt_hash NOT GLOB '*[^0-9a-f]*'),
    output_hash TEXT NULL CHECK(output_hash IS NULL OR (length(output_hash) = 64 AND output_hash NOT GLOB '*[^0-9a-f]*')),
    usage_digest TEXT NULL CHECK(usage_digest IS NULL OR (length(usage_digest) = 64 AND usage_digest NOT GLOB '*[^0-9a-f]*')),
    receipt_tuple_canonical_sha256 TEXT NULL CHECK(receipt_tuple_canonical_sha256 IS NULL OR (length(receipt_tuple_canonical_sha256) = 64 AND receipt_tuple_canonical_sha256 NOT GLOB '*[^0-9a-f]*')),
    checks_json TEXT NOT NULL,
    verifier_diagnostics_json TEXT NOT NULL,
    facts_json TEXT NULL,
    created_at_utc TEXT NOT NULL,
    updated_at_utc TEXT NULL,
    UNIQUE(account_scope_hash, request_id, attempt_n, provider_id)
);
CREATE INDEX IF NOT EXISTS idx_srv_outcome ON settlement_receipt_verdicts(settlement_outcome, closed, received_at_unix_ms);
CREATE INDEX IF NOT EXISTS idx_srv_request ON settlement_receipt_verdicts(account_scope_hash, request_id, attempt_n);
CREATE INDEX IF NOT EXISTS idx_srv_provider_recent ON settlement_receipt_verdicts(provider_id, received_at_unix_ms DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_srv_provider_failed_recent ON settlement_receipt_verdicts(provider_id, received_at_unix_ms DESC, id DESC)
    WHERE closed=1 AND settlement_outcome='quarantined';

-- SPEC-005 v0.5 (issue #253) — MIG-005-011
-- ledger_quarantine_resolutions records operator-issued quarantine
-- decisions. v0.5 widens the enum to force-credit and keeps history:
-- at most one corrective opposite-kind row may be appended by the
-- handler during the hold window; readers project the latest row.
CREATE TABLE IF NOT EXISTS ledger_quarantine_resolutions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    request_credit_id INTEGER NOT NULL REFERENCES ledger_request_credits(id),
    resolution_kind TEXT NOT NULL CHECK(resolution_kind IN ('force_void','force_credit')),
    operator_id TEXT NOT NULL CHECK(length(operator_id) BETWEEN 1 AND 64),
    resolution_reason TEXT NOT NULL CHECK(length(resolution_reason) BETWEEN 1 AND 500),
    created_at_utc TEXT NOT NULL,
    force_credit_matures_at_utc TEXT NULL,
    correction_deadline_at_utc TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_lqr_kind_created ON ledger_quarantine_resolutions(resolution_kind, created_at_utc);
CREATE INDEX IF NOT EXISTS idx_lqr_request_latest ON ledger_quarantine_resolutions(request_credit_id, created_at_utc DESC, id DESC);
`); err != nil {
		return err
	}
	if err := s.ensureLedgerQuarantineResolutionsV05(ctx); err != nil {
		return err
	}
	if err := s.ensureCachedPromptTokensColumn(ctx); err != nil {
		return err
	}
	if err := s.ensureLedgerRequestCreditPromptSplitColumns(ctx); err != nil {
		return err
	}
	if err := s.ensureLedgerProviderIdentityColumns(ctx); err != nil {
		return err
	}
	if err := s.ensureLedgerRequestCreditSettlementColumns(ctx); err != nil {
		return err
	}
	if err := s.normalizeBillingTimeTextColumns(ctx); err != nil {
		return err
	}
	if err := s.ensureLedgerRequestCreditSettlementPolicyGuards(ctx); err != nil {
		return err
	}
	if err := s.rebuildSpec022PayableRequestCreditsView(ctx); err != nil {
		return err
	}
	if err := s.rebuildLegacyConfigSnapshots(ctx); err != nil {
		return err
	}
	return s.validateRequestLog(ctx)
}

func (s *Store) ensureLedgerRequestCreditSettlementColumns(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(ledger_request_credits)`)
	if err != nil {
		return err
	}
	defer rows.Close()
	cols := map[string]bool{}
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull, pk int
		var dflt any
		if err := rows.Scan(&cid, &name, &typ, &notNull, &dflt, &pk); err != nil {
			return err
		}
		cols[name] = true
	}
	if err := rows.Err(); err != nil {
		return err
	}
	add := []struct {
		name string
		sql  string
	}{
		{"settlement_account_scope_hash", `ALTER TABLE ledger_request_credits ADD COLUMN settlement_account_scope_hash TEXT NULL`},
		{"settlement_policy_mode", `ALTER TABLE ledger_request_credits ADD COLUMN settlement_policy_mode TEXT NOT NULL DEFAULT 'legacy'`},
		{"settlement_policy_version", `ALTER TABLE ledger_request_credits ADD COLUMN settlement_policy_version TEXT NULL`},
	}
	for _, col := range add {
		if cols[col.name] {
			continue
		}
		if _, err := s.db.ExecContext(ctx, col.sql); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) ensureLedgerQuarantineResolutionsV05(ctx context.Context) error {
	if err := s.recoverLedgerQuarantineResolutionsV05(ctx); err != nil {
		return err
	}
	tableSQL := ""
	if err := s.db.QueryRowContext(ctx, `
SELECT sql FROM sqlite_master WHERE type='table' AND name='ledger_quarantine_resolutions'`).Scan(&tableSQL); err != nil {
		return err
	}
	hasMaturesColumn, err := s.columnExists(ctx, "ledger_quarantine_resolutions", "force_credit_matures_at_utc")
	if err != nil {
		return err
	}
	hasDeadlineColumn, err := s.columnExists(ctx, "ledger_quarantine_resolutions", "correction_deadline_at_utc")
	if err != nil {
		return err
	}
	hasForceCreditEnum := strings.Contains(tableSQL, "'force_credit'")
	hasUniqueRequestCredit, err := s.hasUniqueIndexOnColumns(ctx, "ledger_quarantine_resolutions", []string{"request_credit_id"})
	if err != nil {
		return err
	}
	if hasMaturesColumn && hasDeadlineColumn && hasForceCreditEnum && !hasUniqueRequestCredit {
		_, err := s.db.ExecContext(ctx, `
CREATE INDEX IF NOT EXISTS idx_lqr_kind_created ON ledger_quarantine_resolutions(resolution_kind, created_at_utc);
CREATE INDEX IF NOT EXISTS idx_lqr_request_latest ON ledger_quarantine_resolutions(request_credit_id, created_at_utc DESC, id DESC);
`)
		return err
	}
	return sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var oldCount int64
		if err := conn.QueryRowContext(ctx, `SELECT COUNT(*) FROM ledger_quarantine_resolutions`).Scan(&oldCount); err != nil {
			return err
		}
		if _, err := conn.ExecContext(ctx, `
DROP VIEW IF EXISTS spec022_payable_request_credits;
DROP INDEX IF EXISTS idx_lqr_kind_created;
DROP INDEX IF EXISTS idx_lqr_request_latest;
DROP TABLE IF EXISTS ledger_quarantine_resolutions_v05;
CREATE TABLE ledger_quarantine_resolutions_v05 (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    request_credit_id INTEGER NOT NULL REFERENCES ledger_request_credits(id),
    resolution_kind TEXT NOT NULL CHECK(resolution_kind IN ('force_void','force_credit')),
    operator_id TEXT NOT NULL CHECK(length(operator_id) BETWEEN 1 AND 64),
    resolution_reason TEXT NOT NULL CHECK(length(resolution_reason) BETWEEN 1 AND 500),
    created_at_utc TEXT NOT NULL,
    force_credit_matures_at_utc TEXT NULL,
    correction_deadline_at_utc TEXT NOT NULL
);
INSERT INTO ledger_quarantine_resolutions_v05 (
    id, request_credit_id, resolution_kind, operator_id, resolution_reason,
    created_at_utc, force_credit_matures_at_utc, correction_deadline_at_utc
)
SELECT id, request_credit_id, resolution_kind, operator_id, resolution_reason,
       created_at_utc,
       CASE WHEN resolution_kind = 'force_credit'
            THEN strftime('%Y-%m-%dT%H:%M:%fZ', created_at_utc, '+86400 seconds')
            ELSE NULL
       END,
       strftime('%Y-%m-%dT%H:%M:%fZ', created_at_utc, '+86400 seconds')
  FROM ledger_quarantine_resolutions;
`); err != nil {
			return err
		}
		var newCount int64
		if err := conn.QueryRowContext(ctx, `SELECT COUNT(*) FROM ledger_quarantine_resolutions_v05`).Scan(&newCount); err != nil {
			return err
		}
		if newCount != oldCount {
			return fmt.Errorf("ledger_quarantine_resolutions v0.5 rebuild count mismatch: old=%d new=%d", oldCount, newCount)
		}
		_, err := conn.ExecContext(ctx, `
DROP TABLE ledger_quarantine_resolutions;
ALTER TABLE ledger_quarantine_resolutions_v05 RENAME TO ledger_quarantine_resolutions;
CREATE INDEX IF NOT EXISTS idx_lqr_kind_created ON ledger_quarantine_resolutions(resolution_kind, created_at_utc);
CREATE INDEX IF NOT EXISTS idx_lqr_request_latest ON ledger_quarantine_resolutions(request_credit_id, created_at_utc DESC, id DESC);
`)
		return err
	})
}

func (s *Store) recoverLedgerQuarantineResolutionsV05(ctx context.Context) error {
	leftover, err := s.tableExists(ctx, "ledger_quarantine_resolutions_v05")
	if err != nil || !leftover {
		return err
	}
	return sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var canonicalCount, leftoverCount int64
		if err := conn.QueryRowContext(ctx, `SELECT COUNT(*) FROM ledger_quarantine_resolutions`).Scan(&canonicalCount); err != nil {
			return err
		}
		if err := conn.QueryRowContext(ctx, `SELECT COUNT(*) FROM ledger_quarantine_resolutions_v05`).Scan(&leftoverCount); err != nil {
			return err
		}
		switch {
		case leftoverCount == 0:
			_, err := conn.ExecContext(ctx, `DROP TABLE ledger_quarantine_resolutions_v05`)
			return err
		case canonicalCount == 0:
			_, err := conn.ExecContext(ctx, `
DROP VIEW IF EXISTS spec022_payable_request_credits;
DROP TABLE ledger_quarantine_resolutions;
ALTER TABLE ledger_quarantine_resolutions_v05 RENAME TO ledger_quarantine_resolutions;
CREATE INDEX IF NOT EXISTS idx_lqr_kind_created ON ledger_quarantine_resolutions(resolution_kind, created_at_utc);
CREATE INDEX IF NOT EXISTS idx_lqr_request_latest ON ledger_quarantine_resolutions(request_credit_id, created_at_utc DESC, id DESC);
`)
			return err
		default:
			return fmt.Errorf("ambiguous ledger_quarantine_resolutions_v05 recovery: canonical=%d leftover=%d", canonicalCount, leftoverCount)
		}
	})
}

func (s *Store) tableExists(ctx context.Context, table string) (bool, error) {
	var name string
	err := s.db.QueryRowContext(ctx, `SELECT name FROM sqlite_master WHERE type='table' AND name=?`, table).Scan(&name)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

func (s *Store) hasUniqueIndexOnColumns(ctx context.Context, table string, want []string) (bool, error) {
	rows, err := s.db.QueryContext(ctx, "PRAGMA index_list("+table+")")
	if err != nil {
		return false, err
	}
	var indexes []string
	for rows.Next() {
		var seq int
		var name string
		var unique int
		var origin string
		var partial int
		if err := rows.Scan(&seq, &name, &unique, &origin, &partial); err != nil {
			_ = rows.Close()
			return false, err
		}
		if unique == 1 {
			indexes = append(indexes, name)
		}
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return false, err
	}
	if err := rows.Close(); err != nil {
		return false, err
	}
	for _, indexName := range indexes {
		cols, err := s.indexColumns(ctx, indexName)
		if err != nil {
			return false, err
		}
		if sameStringSlice(cols, want) {
			return true, nil
		}
	}
	return false, nil
}

func (s *Store) indexColumns(ctx context.Context, indexName string) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, "PRAGMA index_info("+indexName+")")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	type indexColumn struct {
		seq  int
		name string
	}
	var cols []indexColumn
	for rows.Next() {
		var seqno, cid int
		var name string
		if err := rows.Scan(&seqno, &cid, &name); err != nil {
			return nil, err
		}
		cols = append(cols, indexColumn{seq: seqno, name: name})
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	out := make([]string, len(cols))
	for _, c := range cols {
		if c.seq >= 0 && c.seq < len(out) {
			out[c.seq] = c.name
		}
	}
	return out, nil
}

func sameStringSlice(a, b []string) bool {
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

func (s *Store) ensureCachedPromptTokensColumn(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(ledger_request_credits)`)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull int
		var defaultValue sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
			return err
		}
		if name == "cached_prompt_tokens" {
			return nil
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `
ALTER TABLE ledger_request_credits
ADD COLUMN cached_prompt_tokens INTEGER NULL CHECK(cached_prompt_tokens IS NULL OR (cached_prompt_tokens >= 0 AND cached_prompt_tokens <= prompt_tokens))`)
	return err
}

func (s *Store) ensureLedgerRequestCreditPromptSplitColumns(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(ledger_request_credits)`)
	if err != nil {
		return err
	}
	defer rows.Close()
	cols := map[string]bool{}
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull, pk int
		var dflt any
		if err := rows.Scan(&cid, &name, &typ, &notNull, &dflt, &pk); err != nil {
			return err
		}
		cols[name] = true
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if !cols["charged_prompt_tokens"] {
		if _, err := s.db.ExecContext(ctx, `ALTER TABLE ledger_request_credits ADD COLUMN charged_prompt_tokens INTEGER NULL CHECK(charged_prompt_tokens IS NULL OR charged_prompt_tokens >= 0)`); err != nil {
			return err
		}
	}
	if _, err := s.db.ExecContext(ctx, `UPDATE ledger_request_credits SET charged_prompt_tokens = prompt_tokens WHERE charged_prompt_tokens IS NULL AND prompt_tokens IS NOT NULL`); err != nil {
		return err
	}
	if !cols["provider_reported_prompt_tokens"] {
		if _, err := s.db.ExecContext(ctx, `ALTER TABLE ledger_request_credits ADD COLUMN provider_reported_prompt_tokens INTEGER NULL CHECK(provider_reported_prompt_tokens IS NULL OR provider_reported_prompt_tokens >= 0)`); err != nil {
			return err
		}
	}
	if _, err := s.db.ExecContext(ctx, `UPDATE ledger_request_credits SET provider_reported_prompt_tokens = prompt_tokens WHERE provider_reported_prompt_tokens IS NULL AND prompt_tokens IS NOT NULL`); err != nil {
		return err
	}
	return nil
}

func (s *Store) normalizeBillingTimeTextColumns(ctx context.Context) error {
	for _, target := range []struct {
		table  string
		column string
	}{
		{"request_log", "ts_utc"},
		{"ledger_request_credits", "ts_utc"},
		{"ledger_request_credits", "created_at_utc"},
		{"ledger_request_credits", "updated_at_utc"},
		{"ledger_provider_identity_snapshots", "created_at_utc"},
		{"ledger_config_snapshots", "effective_at_utc"},
		{"ledger_config_audit_events", "created_at_utc"},
		{"ledger_payout_ready", "window_start_utc"},
		{"ledger_payout_ready", "window_end_utc"},
		{"ledger_payout_ready", "created_at_utc"},
		{"ledger_payout_ready", "updated_at_utc"},
	} {
		if err := s.normalizeTimeColumn(ctx, target.table, target.column); err != nil {
			return err
		}
	}
	return nil
}

type timeColumnUpdate struct {
	rowid int64
	value string
}

func (s *Store) normalizeTimeColumn(ctx context.Context, table, column string) error {
	exists, err := s.columnExists(ctx, table, column)
	if err != nil {
		return err
	}
	if !exists {
		return nil
	}
	const batchSize = 500
	lastRowID := int64(0)
	for {
		rows, err := s.db.QueryContext(ctx, "SELECT rowid, "+column+" FROM "+table+" WHERE rowid > ? AND "+column+" IS NOT NULL AND "+column+" != '' ORDER BY rowid LIMIT ?", lastRowID, batchSize)
		if err != nil {
			return fmt.Errorf("scan %s.%s timestamps: %w", table, column, err)
		}
		var updates []timeColumnUpdate
		scanned := 0
		for rows.Next() {
			var rowid int64
			var raw string
			if err := rows.Scan(&rowid, &raw); err != nil {
				_ = rows.Close()
				return err
			}
			scanned++
			lastRowID = rowid
			normalized, ok := normalizeSQLiteTimeText(raw)
			if ok && normalized != raw {
				updates = append(updates, timeColumnUpdate{rowid: rowid, value: normalized})
			}
		}
		if err := rows.Err(); err != nil {
			_ = rows.Close()
			return err
		}
		if err := rows.Close(); err != nil {
			return err
		}
		if len(updates) > 0 {
			if err := s.applyTimeColumnNormalizations(ctx, table, column, updates); err != nil {
				return err
			}
		}
		if scanned < batchSize {
			return nil
		}
	}
}

func (s *Store) applyTimeColumnNormalizations(ctx context.Context, table, column string, updates []timeColumnUpdate) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	stmt, err := tx.PrepareContext(ctx, "UPDATE "+table+" SET "+column+" = ? WHERE rowid = ?")
	if err != nil {
		return err
	}
	defer stmt.Close()
	for _, u := range updates {
		if _, err := stmt.ExecContext(ctx, u.value, u.rowid); err != nil {
			return fmt.Errorf("normalize %s.%s rowid %d: %w", table, column, u.rowid, err)
		}
	}
	return tx.Commit()
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
		var notNull, pk int
		var dflt any
		if err := rows.Scan(&cid, &name, &typ, &notNull, &dflt, &pk); err != nil {
			return false, err
		}
		if name == column {
			return true, nil
		}
	}
	return false, rows.Err()
}

func (s *Store) ensureLedgerProviderIdentityColumns(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(ledger_provider_identity_snapshots)`)
	if err != nil {
		return err
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
			return err
		}
		cols[name] = true
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if !cols["config_snapshot_id"] {
		if _, err := s.db.ExecContext(ctx, `
ALTER TABLE ledger_provider_identity_snapshots
ADD COLUMN config_snapshot_id INTEGER NULL CHECK(config_snapshot_id IS NULL OR config_snapshot_id > 0)`); err != nil {
			return err
		}
	}
	if !cols["provider_reported_prompt_tokens"] {
		if _, err := s.db.ExecContext(ctx, `
ALTER TABLE ledger_provider_identity_snapshots
ADD COLUMN provider_reported_prompt_tokens INTEGER NULL CHECK(provider_reported_prompt_tokens IS NULL OR provider_reported_prompt_tokens >= 0)`); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) ensureLedgerRequestCreditSettlementPolicyGuards(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
CREATE TRIGGER IF NOT EXISTS trg_lrc_settlement_policy_insert_guard
BEFORE INSERT ON ledger_request_credits
WHEN NEW.settlement_policy_mode IS NULL
  OR NEW.settlement_policy_mode NOT IN ('legacy','observe','enforce')
  OR (
      NEW.settlement_account_scope_hash IS NOT NULL
      AND (
          length(NEW.settlement_account_scope_hash) != 64
          OR NEW.settlement_account_scope_hash GLOB '*[^0-9a-f]*'
      )
  )
BEGIN
    SELECT RAISE(ABORT, 'invalid ledger_request_credits settlement policy');
END;
CREATE TRIGGER IF NOT EXISTS trg_lrc_settlement_policy_update_guard
BEFORE UPDATE OF settlement_account_scope_hash, settlement_policy_mode, settlement_policy_version ON ledger_request_credits
WHEN NEW.settlement_policy_mode IS NULL
  OR NEW.settlement_policy_mode NOT IN ('legacy','observe','enforce')
  OR (
      NEW.settlement_account_scope_hash IS NOT NULL
      AND (
          length(NEW.settlement_account_scope_hash) != 64
          OR NEW.settlement_account_scope_hash GLOB '*[^0-9a-f]*'
      )
  )
BEGIN
    SELECT RAISE(ABORT, 'invalid ledger_request_credits settlement policy');
END;
CREATE TRIGGER IF NOT EXISTS trg_lrc_settlement_policy_immutable
BEFORE UPDATE OF settlement_account_scope_hash, settlement_policy_mode, settlement_policy_version ON ledger_request_credits
WHEN COALESCE(OLD.settlement_account_scope_hash, '') != COALESCE(NEW.settlement_account_scope_hash, '')
  OR COALESCE(OLD.settlement_policy_mode, '') != COALESCE(NEW.settlement_policy_mode, '')
  OR COALESCE(OLD.settlement_policy_version, '') != COALESCE(NEW.settlement_policy_version, '')
BEGIN
    SELECT RAISE(ABORT, 'ledger_request_credits settlement policy is immutable');
END;
DROP TRIGGER IF EXISTS trg_lrc_settled_money_immutable;
DROP TRIGGER IF EXISTS trg_lrc_settled_link_immutable;
CREATE TRIGGER trg_lrc_settled_money_immutable
BEFORE UPDATE OF prompt_tokens, completion_tokens, estimated_completion_tokens,
                 charged_prompt_tokens, provider_reported_prompt_tokens,
                 usage_source, prompt_rate_per_mtok, completion_rate_per_mtok,
                 cached_prompt_tokens,
                 global_multiplier_ppm, gross_credits, provider_share_bps,
                 provider_credits, fault_flag ON ledger_request_credits
WHEN (OLD.settled = 1 OR NEW.settled = 1)
  AND (
      COALESCE(OLD.prompt_tokens, -1) != COALESCE(NEW.prompt_tokens, -1)
      OR COALESCE(OLD.charged_prompt_tokens, -1) != COALESCE(NEW.charged_prompt_tokens, -1)
      OR COALESCE(OLD.provider_reported_prompt_tokens, -1) != COALESCE(NEW.provider_reported_prompt_tokens, -1)
      OR COALESCE(OLD.completion_tokens, -1) != COALESCE(NEW.completion_tokens, -1)
      OR COALESCE(OLD.estimated_completion_tokens, -1) != COALESCE(NEW.estimated_completion_tokens, -1)
      OR OLD.usage_source != NEW.usage_source
      OR OLD.prompt_rate_per_mtok != NEW.prompt_rate_per_mtok
      OR COALESCE(OLD.cached_prompt_tokens, -1) != COALESCE(NEW.cached_prompt_tokens, -1)
      OR OLD.completion_rate_per_mtok != NEW.completion_rate_per_mtok
      OR OLD.global_multiplier_ppm != NEW.global_multiplier_ppm
      OR OLD.gross_credits != NEW.gross_credits
      OR OLD.provider_share_bps != NEW.provider_share_bps
      OR OLD.provider_credits != NEW.provider_credits
      OR OLD.fault_flag != NEW.fault_flag
  )
BEGIN
    SELECT RAISE(ABORT, 'settled ledger_request_credits money fields are immutable');
END;
CREATE TRIGGER trg_lrc_settled_link_immutable
BEFORE UPDATE OF settled, settlement_id ON ledger_request_credits
WHEN OLD.settled = 1
  AND (
      OLD.settled != NEW.settled
      OR COALESCE(OLD.settlement_id, -1) != COALESCE(NEW.settlement_id, -1)
  )
BEGIN
    SELECT RAISE(ABORT, 'settled ledger_request_credits settlement link is immutable');
END;
`)
	return err
}

func (s *Store) rebuildSpec022PayableRequestCreditsView(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
CREATE INDEX IF NOT EXISTS idx_lrc_spec022_payable ON ledger_request_credits(
    settlement_policy_mode, settlement_account_scope_hash, request_id, attempt_n, provider_id,
    quarantined, settled, settlement_id, ts_utc
);
CREATE INDEX IF NOT EXISTS idx_srs_spec022_payable ON settlement_route_snapshots(
    request_id, attempt_n, provider_id, route_snapshot_mode, route_snapshot_digest, account_scope
);
CREATE INDEX IF NOT EXISTS idx_srv_spec022_payable ON settlement_receipt_verdicts(
    account_scope_hash, request_id, attempt_n, provider_id, route_snapshot_digest, closed, settlement_outcome
);
CREATE INDEX IF NOT EXISTS idx_sao_spec022_payable ON settlement_attempt_outputs(
    account_scope, request_id, attempt_n, provider_id, overlapping_or_duplicate
);
DROP VIEW IF EXISTS spec022_payable_request_credits;
CREATE VIEW spec022_payable_request_credits AS
SELECT lrc.*
  FROM ledger_request_credits lrc
 WHERE (
       lrc.quarantined = 0
       OR EXISTS (
           SELECT 1
             FROM ledger_quarantine_resolutions lqr
            WHERE lqr.request_credit_id = lrc.id
              AND lqr.id = (
                  SELECT latest.id
                    FROM ledger_quarantine_resolutions latest
                   WHERE latest.request_credit_id = lrc.id
                   ORDER BY latest.created_at_utc DESC, latest.id DESC
                   LIMIT 1
              )
              AND lqr.resolution_kind = 'force_credit'
              AND lqr.force_credit_matures_at_utc IS NOT NULL
              AND lqr.force_credit_matures_at_utc <= strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
       )
   )
   AND (
       COALESCE(lrc.settlement_policy_mode, 'legacy') IN ('legacy', 'observe')
       OR (
           lrc.settlement_policy_mode = 'enforce'
           AND lrc.settlement_account_scope_hash IS NOT NULL
           AND lrc.settlement_policy_version IS NOT NULL
           AND EXISTS (
               SELECT 1
                 FROM settlement_route_snapshots srs
                 JOIN settlement_receipt_verdicts srv
                   ON srv.account_scope_hash = lrc.settlement_account_scope_hash
                  AND srv.request_id = srs.request_id
                  AND srv.attempt_n = srs.attempt_n
                  AND srv.provider_id = srs.provider_id
                  AND srv.route_snapshot_digest = srs.route_snapshot_digest
                 JOIN settlement_attempt_outputs sao
                   ON sao.account_scope = srs.account_scope
                  AND sao.request_id = srs.request_id
                  AND sao.attempt_n = srs.attempt_n
                  AND sao.provider_id = srs.provider_id
                WHERE srs.request_id = lrc.request_id
                  AND srs.attempt_n = lrc.attempt_n
                  AND srs.provider_id = lrc.provider_id
                  AND srs.route_snapshot_mode = 'enforce'
                  AND srs.route_snapshot_policy_version = lrc.settlement_policy_version
                  AND srv.route_snapshot_mode = 'enforce'
                  AND srv.route_snapshot_policy_version = lrc.settlement_policy_version
                  AND srv.closed = 1
                  AND srv.settlement_outcome = 'verified'
                  AND sao.overlapping_or_duplicate = 0
           )
       )
   );
`)
	return err
}

func (s *Store) rebuildLegacyConfigSnapshots(ctx context.Context) error {
	// Two-pass to avoid holding the outer PRAGMA index_list cursor open while
	// running per-index PRAGMA index_info queries. Issue #21 / ARCH-3 — at
	// MaxOpenConns(1) on the requestlog-shared *sql.DB the nested-cursor
	// variant deadlocks because the inner Query waits for the connection the
	// outer cursor still pins. Collect the unique-index names first, close
	// the outer cursor, then run the inner PRAGMA per name. The set is small
	// (one table, a handful of indexes), so the extra slice has no cost.
	rows, err := s.db.QueryContext(ctx, `PRAGMA index_list(ledger_config_snapshots)`)
	if err != nil {
		return err
	}
	uniqueIndexNames := []string{}
	for rows.Next() {
		var seq int
		var name string
		var unique int
		var origin, partial any
		if err := rows.Scan(&seq, &name, &unique, &origin, &partial); err != nil {
			rows.Close()
			return err
		}
		if unique == 1 {
			uniqueIndexNames = append(uniqueIndexNames, name)
		}
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	rows.Close()

	hasLegacyUnique := false
	for _, name := range uniqueIndexNames {
		indexInfo, err := s.db.QueryContext(ctx, `PRAGMA index_info(`+name+`)`)
		if err != nil {
			return err
		}
		cols := []string{}
		for indexInfo.Next() {
			var seqno, cid int
			var col string
			if err := indexInfo.Scan(&seqno, &cid, &col); err != nil {
				indexInfo.Close()
				return err
			}
			cols = append(cols, col)
		}
		if err := indexInfo.Err(); err != nil {
			indexInfo.Close()
			return err
		}
		indexInfo.Close()
		if len(cols) == 1 && cols[0] == "config_hash" {
			hasLegacyUnique = true
			break
		}
	}
	if !hasLegacyUnique {
		return nil
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	_, err = tx.ExecContext(ctx, `
DROP TABLE IF EXISTS ledger_config_snapshots_rebuild;
CREATE TABLE ledger_config_snapshots_rebuild (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    effective_at_utc TEXT NOT NULL,
    config_hash TEXT NOT NULL,
    provider_share_bps INTEGER NOT NULL CHECK(provider_share_bps BETWEEN 0 AND 10000),
    global_multiplier_ppm INTEGER NOT NULL CHECK(global_multiplier_ppm >= 0),
    rate_card_json TEXT NOT NULL,
    created_at_utc TEXT NOT NULL
);
INSERT INTO ledger_config_snapshots_rebuild (
    id, effective_at_utc, config_hash, provider_share_bps,
    global_multiplier_ppm, rate_card_json, created_at_utc
)
SELECT id, effective_at_utc, config_hash, provider_share_bps,
       global_multiplier_ppm, rate_card_json, created_at_utc
  FROM ledger_config_snapshots;
DROP TABLE ledger_config_snapshots;
ALTER TABLE ledger_config_snapshots_rebuild RENAME TO ledger_config_snapshots;
CREATE INDEX IF NOT EXISTS idx_lcs_effective_at ON ledger_config_snapshots(effective_at_utc);
`)
	if err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) SetSettlementConfig(cfg SettlementConfig) {
	s.settlementMu.Lock()
	defer s.settlementMu.Unlock()
	s.settlement = cfg
}

// usdcBaseUnitsPerUSDC is the USDC fixed-point scale (6 decimals): one USDC
// equals 1,000,000 base units.
const usdcBaseUnitsPerUSDC = 1_000_000

// providerCreditsToUSDC converts ledger provider_credits into a USDC amount
// using the SAME invariant the payout runner enforces at settlement time —
// SPEC-016 §4.3 step 2: the on-chain payout amount in USDC base units equals
// provider_credits exactly (phase4-coordinator/internal/payout/runner.go). So
// the displayed usdc_* figure is, by construction, the amount the provider is
// actually owed/paid, independent of any tunable stats display rate.
func providerCreditsToUSDC(credits int64) float64 {
	if credits <= 0 {
		return 0
	}
	return float64(credits) / usdcBaseUnitsPerUSDC
}

func (s *Store) SettlementConfig(defaultCfg SettlementConfig) SettlementConfig {
	s.settlementMu.RLock()
	defer s.settlementMu.RUnlock()
	if s.settlement.CadenceDays == 0 {
		return defaultCfg
	}
	return s.settlement
}

func (s *Store) validateRequestLog(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(request_log)`)
	if err != nil {
		return err
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
			return err
		}
		cols[name] = true
	}
	if err := rows.Err(); err != nil {
		return err
	}
	required := []string{"id", "ts_utc", "request_id", "model", "provider_assigned_id", "prompt_tokens", "completion_tokens", "estimated_completion_tokens", "error_code", "retried"}
	missing := []string{}
	for _, col := range required {
		if !cols[col] {
			missing = append(missing, col)
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("request_log missing required SPEC-005 columns: %s", strings.Join(missing, ", "))
	}
	return nil
}

func boolInt(v bool) int {
	if v {
		return 1
	}
	return 0
}

func nullString(v string) sql.NullString {
	if v == "" {
		return sql.NullString{}
	}
	return sql.NullString{String: v, Valid: true}
}

func nullInt64(v *int64) sql.NullInt64 {
	if v == nil {
		return sql.NullInt64{}
	}
	return sql.NullInt64{Int64: *v, Valid: true}
}

func nullPositiveInt64(v int64) sql.NullInt64 {
	if v <= 0 {
		return sql.NullInt64{}
	}
	return sql.NullInt64{Int64: v, Valid: true}
}

// ForceVoidEnabled returns the current value of the SPEC-005 v0.4
// route-layer flag. Reads are atomic; safe under concurrent flips
// from SIGHUP-driven config reload.
func (s *Store) ForceVoidEnabled() bool {
	return s.forceVoidEnabled.Load()
}

func (s *Store) ForceCreditEnabled() bool {
	return s.forceCreditEnabled.Load()
}

func (s *Store) ForceCreditSettlementHoldSeconds() int64 {
	hold := s.forceCreditHoldSeconds.Load()
	if hold <= 0 {
		return defaultForceCreditSettlementHoldSeconds
	}
	return hold
}

func (s *Store) SetForceCreditSettlementHoldSeconds(seconds int64) {
	if seconds <= 0 {
		seconds = defaultForceCreditSettlementHoldSeconds
	}
	s.forceCreditHoldSeconds.Store(seconds)
}

// SetForceVoidEnabled atomically updates the route-layer flag and,
// on actual flips (old != new), emits the SPEC-005 v0.4 §11.6.4
// `billing_config_flag_changed` audit-log row inside the billing
// store's `audit_log` table via a dedicated BEGIN IMMEDIATE tx. No
// audit row is written when the value is unchanged (SPEC §13.2
// "reload-no-change" rule).
//
// reloadSource MUST be one of "startup" | "sighup" | "http_reload".
// "startup" callers MUST pass a zero-value old (we infer first-time
// init from changed == false on the swap).
func (s *Store) SetForceVoidEnabled(ctx context.Context, newValue bool, reloadSource string) error {
	return s.setQuarantineFlagEnabled(ctx, "quarantine_resolution_force_void_enabled", &s.forceVoidEnabled, newValue, reloadSource)
}

func (s *Store) SetForceCreditEnabled(ctx context.Context, newValue bool, reloadSource string) error {
	return s.setQuarantineFlagEnabled(ctx, "quarantine_resolution_force_credit_enabled", &s.forceCreditEnabled, newValue, reloadSource)
}

func (s *Store) setQuarantineFlagEnabled(ctx context.Context, flagName string, flag *atomic.Bool, newValue bool, reloadSource string) error {
	// R6 fix (CODE-M1): reloadSource enum is documented as restricted
	// to "startup" | "sighup" | "http_reload". Validate before doing
	// any state mutation or DB write — otherwise a typo in a caller
	// silently writes a malformed audit row.
	switch reloadSource {
	case "startup", "sighup", "http_reload":
	default:
		return fmt.Errorf("SetForceVoidEnabled: invalid reloadSource %q (want startup|sighup|http_reload)", reloadSource)
	}
	// Serialize so that the (audit insert, publish) pair is atomic:
	// no other reloader can change the value between our Load() and
	// Store(), and no handler can observe a value whose audit row has
	// not been committed yet (R2: ARCH-H1 / SEC-M2 / CODE-H4 fix).
	s.forceVoidReloadMu.Lock()
	defer s.forceVoidReloadMu.Unlock()

	oldValue := flag.Load()
	if oldValue == newValue {
		return nil
	}
	// Startup writes do NOT emit an audit row per SPEC §11.6.4:
	// "v0.4 does NOT emit at startup, because 'no prior acknowledged
	// value' has no defined `old_value` and the startup
	// `ledger_config_snapshots` row already captures the initial
	// state."
	if reloadSource == "startup" {
		flag.Store(newValue)
		return nil
	}
	payload := map[string]any{
		"flag":          flagName,
		"old_value":     oldValue,
		"new_value":     newValue,
		"reload_source": reloadSource,
		"ts_utc":        time.Now().UTC().Format(time.RFC3339Nano),
	}
	payloadJSON, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshal flag-change payload: %w", err)
	}
	if err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		now := payload["ts_utc"].(string)
		if _, err := conn.ExecContext(ctx, `
INSERT INTO audit_log (ts_utc, event_type, provider_id, payload_json)
VALUES (?, 'billing_config_flag_changed', NULL, ?)`, now, string(payloadJSON)); err != nil {
			return fmt.Errorf("insert flag-change audit: %w", err)
		}
		return nil
	}); err != nil {
		return err
	}
	// Audit is durable: publish the new value. No handler could
	// observe newValue before this point because the only reader is
	// h.store.Force*Enabled() which reads the corresponding atomic.
	flag.Store(newValue)
	return nil
}
