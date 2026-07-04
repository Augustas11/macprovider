package billing

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

var ErrNoSnapshot = errors.New("no config snapshot found")

type canonicalConfig struct {
	ProviderShareBps    int64                    `json:"provider_share_bps"`
	GlobalMultiplierPPM int64                    `json:"global_multiplier_ppm"`
	RateCard            map[string]RateCardEntry `json:"rate_card"`
	// R4 fix (CODE-M2): SPEC-005 v0.4 §11.6.4 / §13.2 require the
	// startup `ledger_config_snapshots` row to capture the initial
	// `quarantine_resolution_force_void_enabled` value. Including
	// the boolean in the canonical hash makes the snapshot a
	// forensic record of the flag state at that reload.
	QuarantineResolutionForceVoidEnabled bool `json:"quarantine_resolution_force_void_enabled"`
}

func (s *Store) InsertConfigSnapshot(ctx context.Context, cfg RewardsConfig, now time.Time) (int64, error) {
	canon := canonicalConfig{
		ProviderShareBps:                     ParseShareBps(cfg.ProviderShare),
		GlobalMultiplierPPM:                  ParseMultiplierPPM(cfg.GlobalMultiplier),
		RateCard:                             cfg.RateCard,
		QuarantineResolutionForceVoidEnabled: s.forceVoidEnabled.Load(),
	}
	rateJSON, err := json.Marshal(canon.RateCard)
	if err != nil {
		return 0, err
	}
	fullJSON, err := json.Marshal(canon)
	if err != nil {
		return 0, err
	}
	sum := sha256.Sum256(fullJSON)
	hash := hex.EncodeToString(sum[:])
	ts := sqliteTimeText(now)
	res, err := s.db.ExecContext(ctx, `
INSERT INTO ledger_config_snapshots (
    effective_at_utc, config_hash, provider_share_bps, global_multiplier_ppm,
    rate_card_json, created_at_utc
) VALUES (?, ?, ?, ?, ?, ?)`,
		ts, hash, canon.ProviderShareBps, canon.GlobalMultiplierPPM, string(rateJSON), ts,
	)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// ReloadBillingConfig writes the config-snapshot row and (if the
// route-layer flag is actually changing) the
// `billing_config_flag_changed` audit row in ONE `BEGIN IMMEDIATE`
// transaction, then publishes the in-memory force-void flag only
// after COMMIT.
//
// R3 fix (ARCH-H1): the prior reload sequence wrote
// `ledger_config_snapshots` first, applied the in-memory rewards /
// settlement configs second, and emitted the flag-change audit row
// last. If the flag-change audit INSERT failed, the snapshot row
// and the in-memory configs were already published — a partially
// applied reload with no audit trail for the flag flip.
//
// This method atomically commits the snapshot row and the optional
// flag-change audit row, and only THEN (after COMMIT) publishes the
// new force-void value via `forceVoidEnabled.Store`. If COMMIT
// fails the in-memory flag remains at the prior value. The caller
// continues to publish the rewards/settlement in-memory state via
// the returned snapshot id.
//
// reloadSource MUST be "sighup" or "http_reload"; "startup" callers
// continue to use InsertConfigSnapshot (which never writes a flag
// audit) and HandlersWithQuarantineGate (which uses
// SetForceVoidEnabled with reloadSource="startup").
func (s *Store) ReloadBillingConfig(ctx context.Context, cfg RewardsConfig, forceVoidEnabled bool, reloadSource string, now time.Time) (int64, error) {
	if reloadSource != "sighup" && reloadSource != "http_reload" {
		return 0, errors.New("ReloadBillingConfig: reloadSource must be sighup or http_reload")
	}
	s.forceVoidReloadMu.Lock()
	defer s.forceVoidReloadMu.Unlock()

	// R4 fix (CODE-M2): snapshot captures the POST-reload force-void
	// value so the ledger_config_snapshots row reflects what the
	// next handler-request observes (not the pre-reload value).
	canon := canonicalConfig{
		ProviderShareBps:                     ParseShareBps(cfg.ProviderShare),
		GlobalMultiplierPPM:                  ParseMultiplierPPM(cfg.GlobalMultiplier),
		RateCard:                             cfg.RateCard,
		QuarantineResolutionForceVoidEnabled: forceVoidEnabled,
	}
	rateJSON, err := json.Marshal(canon.RateCard)
	if err != nil {
		return 0, err
	}
	fullJSON, err := json.Marshal(canon)
	if err != nil {
		return 0, err
	}
	sum := sha256.Sum256(fullJSON)
	hash := hex.EncodeToString(sum[:])
	ts := sqliteTimeText(now)

	oldFlag := s.forceVoidEnabled.Load()
	flagChanged := oldFlag != forceVoidEnabled

	var flagPayloadJSON []byte
	if flagChanged {
		flagPayload := map[string]any{
			"flag":          "quarantine_resolution_force_void_enabled",
			"old_value":     oldFlag,
			"new_value":     forceVoidEnabled,
			"reload_source": reloadSource,
			"ts_utc":        ts,
		}
		flagPayloadJSON, err = json.Marshal(flagPayload)
		if err != nil {
			return 0, err
		}
	}

	var snapshotID int64
	if err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		res, err := conn.ExecContext(ctx, `
INSERT INTO ledger_config_snapshots (
    effective_at_utc, config_hash, provider_share_bps, global_multiplier_ppm,
    rate_card_json, created_at_utc
) VALUES (?, ?, ?, ?, ?, ?)`,
			ts, hash, canon.ProviderShareBps, canon.GlobalMultiplierPPM, string(rateJSON), ts,
		)
		if err != nil {
			return err
		}
		id, err := res.LastInsertId()
		if err != nil {
			return err
		}
		if flagChanged {
			if _, err := conn.ExecContext(ctx, `
INSERT INTO audit_log (ts_utc, event_type, provider_id, payload_json)
VALUES (?, 'billing_config_flag_changed', NULL, ?)`, ts, string(flagPayloadJSON)); err != nil {
				return err
			}
		}
		snapshotID = id
		return nil
	}); err != nil {
		return 0, err
	}
	// Only after the snapshot row and (optional) flag-change audit
	// row are durably committed do we publish the in-memory force-
	// void flag. Handlers cannot observe the new value before the
	// COMMIT lands.
	if flagChanged {
		s.forceVoidEnabled.Store(forceVoidEnabled)
	}
	return snapshotID, nil
}

func (s *Store) LatestConfigSnapshotAt(ctx context.Context, t time.Time) (int64, error) {
	var id int64
	err := s.db.QueryRowContext(ctx, `
SELECT id FROM ledger_config_snapshots
 WHERE effective_at_utc <= ?
 ORDER BY effective_at_utc DESC, id DESC
 LIMIT 1`, sqliteTimeText(t)).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNoSnapshot
	}
	return id, err
}

// snapshotQueryer is the narrow surface snapshotAt needs — both *sql.DB and
// *sql.Tx satisfy it. Issue #21: recovery.RecoverLedger runs inside a tx,
// and at MaxOpenConns(1) it MUST issue per-row snapshot lookups against
// the SAME tx (i.e. on the connection the tx pins) — calling s.db.* there
// asks the pool for a second connection and deadlocks. Callers outside a
// tx pass s.db; callers inside one pass their *sql.Tx.
type snapshotQueryer interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

func (s *Store) snapshotAt(ctx context.Context, t time.Time) (int64, RewardsConfig, int64, int64, error) {
	return snapshotAtQueryer(ctx, s.db, t)
}

func snapshotAtTx(ctx context.Context, tx *sql.Tx, t time.Time) (int64, RewardsConfig, int64, int64, error) {
	return snapshotAtQueryer(ctx, tx, t)
}

func snapshotByIDQueryer(ctx context.Context, q snapshotQueryer, id int64) (RewardsConfig, int64, int64, error) {
	var providerShareBps, multiplierPPM int64
	var rateJSON string
	err := q.QueryRowContext(ctx, `
SELECT provider_share_bps, global_multiplier_ppm, rate_card_json
  FROM ledger_config_snapshots
 WHERE id = ?`, id).Scan(&providerShareBps, &multiplierPPM, &rateJSON)
	if errors.Is(err, sql.ErrNoRows) {
		return RewardsConfig{}, 0, 0, ErrNoSnapshot
	}
	if err != nil {
		return RewardsConfig{}, 0, 0, err
	}
	var rateCard map[string]RateCardEntry
	if err := json.Unmarshal([]byte(rateJSON), &rateCard); err != nil {
		return RewardsConfig{}, 0, 0, err
	}
	return RewardsConfig{RateCard: rateCard}, multiplierPPM, providerShareBps, nil
}

func snapshotAtQueryer(ctx context.Context, q snapshotQueryer, t time.Time) (int64, RewardsConfig, int64, int64, error) {
	var id, providerShareBps, multiplierPPM int64
	var rateJSON string
	err := q.QueryRowContext(ctx, `
SELECT id, provider_share_bps, global_multiplier_ppm, rate_card_json
  FROM ledger_config_snapshots
 WHERE effective_at_utc <= ?
 ORDER BY effective_at_utc DESC, id DESC
 LIMIT 1`, sqliteTimeText(t)).Scan(&id, &providerShareBps, &multiplierPPM, &rateJSON)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, RewardsConfig{}, 0, 0, ErrNoSnapshot
	}
	if err != nil {
		return 0, RewardsConfig{}, 0, 0, err
	}
	var rateCard map[string]RateCardEntry
	if err := json.Unmarshal([]byte(rateJSON), &rateCard); err != nil {
		return 0, RewardsConfig{}, 0, 0, err
	}
	return id, RewardsConfig{RateCard: rateCard}, multiplierPPM, providerShareBps, nil
}
