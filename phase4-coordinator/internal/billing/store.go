package billing

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"sync"

	"github.com/augstar/macprovider-coordinator/internal/config"
	_ "modernc.org/sqlite"
)

type RateCardEntry = config.RateCardEntry
type RewardsConfig = config.RewardsConfig
type SettlementConfig = config.SettlementConfig

type Store struct {
	db           *sql.DB
	settlementMu sync.RWMutex
	settlement   SettlementConfig
}

func NewStore(db *sql.DB) (*Store, error) {
	if db == nil {
		return nil, fmt.Errorf("db is required")
	}
	s := &Store{db: db}
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
    created_at_utc TEXT NOT NULL,
    UNIQUE(request_id, attempt_n, provider_assigned_id)
);
CREATE INDEX IF NOT EXISTS idx_lpis_request ON ledger_provider_identity_snapshots(request_id, attempt_n);
CREATE INDEX IF NOT EXISTS idx_lpis_provider ON ledger_provider_identity_snapshots(provider_id, created_at_utc);
`); err != nil {
		return err
	}
	if err := s.rebuildLegacyConfigSnapshots(ctx); err != nil {
		return err
	}
	return s.validateRequestLog(ctx)
}

func (s *Store) rebuildLegacyConfigSnapshots(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA index_list(ledger_config_snapshots)`)
	if err != nil {
		return err
	}
	hasLegacyUnique := false
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
			indexInfo, err := s.db.QueryContext(ctx, `PRAGMA index_info(`+name+`)`)
			if err != nil {
				rows.Close()
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
			}
		}
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	rows.Close()
	if !hasLegacyUnique {
		return nil
	}
	_, err = s.db.ExecContext(ctx, `
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
	return err
}

func (s *Store) SetSettlementConfig(cfg SettlementConfig) {
	s.settlementMu.Lock()
	defer s.settlementMu.Unlock()
	s.settlement = cfg
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
