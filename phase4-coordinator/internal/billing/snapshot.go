package billing

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"time"
)

var ErrNoSnapshot = errors.New("no config snapshot found")

type canonicalConfig struct {
	ProviderShareBps    int64                    `json:"provider_share_bps"`
	GlobalMultiplierPPM int64                    `json:"global_multiplier_ppm"`
	RateCard            map[string]RateCardEntry `json:"rate_card"`
}

func (s *Store) InsertConfigSnapshot(ctx context.Context, cfg RewardsConfig, now time.Time) (int64, error) {
	canon := canonicalConfig{
		ProviderShareBps:    ParseShareBps(cfg.ProviderShare),
		GlobalMultiplierPPM: ParseMultiplierPPM(cfg.GlobalMultiplier),
		RateCard:            cfg.RateCard,
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
	ts := now.UTC().Format(time.RFC3339Nano)
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

func (s *Store) LatestConfigSnapshotAt(ctx context.Context, t time.Time) (int64, error) {
	var id int64
	err := s.db.QueryRowContext(ctx, `
SELECT id FROM ledger_config_snapshots
 WHERE effective_at_utc <= ?
 ORDER BY effective_at_utc DESC, id DESC
 LIMIT 1`, t.UTC().Format(time.RFC3339Nano)).Scan(&id)
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

func snapshotAtQueryer(ctx context.Context, q snapshotQueryer, t time.Time) (int64, RewardsConfig, int64, int64, error) {
	var id, providerShareBps, multiplierPPM int64
	var rateJSON string
	err := q.QueryRowContext(ctx, `
SELECT id, provider_share_bps, global_multiplier_ppm, rate_card_json
  FROM ledger_config_snapshots
 WHERE effective_at_utc <= ?
 ORDER BY effective_at_utc DESC, id DESC
 LIMIT 1`, t.UTC().Format(time.RFC3339Nano)).Scan(&id, &providerShareBps, &multiplierPPM, &rateJSON)
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
