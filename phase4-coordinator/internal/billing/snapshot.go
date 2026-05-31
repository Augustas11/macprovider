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
) VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(config_hash) DO NOTHING`,
		ts, hash, canon.ProviderShareBps, canon.GlobalMultiplierPPM, string(rateJSON), ts,
	)
	if err != nil {
		return 0, err
	}
	if id, _ := res.LastInsertId(); id > 0 {
		return id, nil
	}
	var id int64
	err = s.db.QueryRowContext(ctx, `SELECT id FROM ledger_config_snapshots WHERE config_hash = ?`, hash).Scan(&id)
	return id, err
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

func (s *Store) snapshotAt(ctx context.Context, t time.Time) (int64, RewardsConfig, int64, int64, error) {
	var id, providerShareBps, multiplierPPM int64
	var rateJSON string
	err := s.db.QueryRowContext(ctx, `
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
