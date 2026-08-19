package rewards

import (
	"context"
	"database/sql"
	"time"
)

// WithdrawableRow is a MALIBU ledger row eligible for withdrawal.
type WithdrawableRow struct {
	ID           int64
	ProviderID   string
	UnixTS       int64
	AmountMALIBU string
}

// SelectWithdrawableMALIBU returns ledger rows with no withdrawal hold.
// Used by the future MALIBU withdrawal runner per spec §4.5.
func SelectWithdrawableMALIBU(ctx context.Context, db *sql.DB, providerID string, limit int) ([]WithdrawableRow, error) {
	if limit <= 0 {
		limit = 100
	}
	rows, err := db.QueryContext(ctx, `
        SELECT prl.id, prl.provider_id, prl.unix_ts, prl.amount_malibu::TEXT
          FROM malibu_rewards_ledger_with_disposition prl
         WHERE prl.provider_id = $1
           AND prl.amount_malibu IS NOT NULL
           AND prl.amount_malibu > 0
           AND prl.withdrawal_hold_reason IS NULL
           AND NOT prl.epoch_disposition_blocked
         ORDER BY prl.id ASC
         LIMIT $2
    `, providerID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []WithdrawableRow
	for rows.Next() {
		var row WithdrawableRow
		if err := rows.Scan(&row.ID, &row.ProviderID, &row.UnixTS, &row.AmountMALIBU); err != nil {
			return nil, err
		}
		out = append(out, row)
	}
	return out, rows.Err()
}

// SetTrustTier updates provider trust tier (unlock/demotion path).
func SetTrustTier(ctx context.Context, db *sql.DB, providerID, tier string) error {
	return setTrustTier(ctx, db, providerID, tier)
}

type trustTierWriter interface {
	ExecContext(context.Context, string, ...interface{}) (sql.Result, error)
}

func setTrustTier(ctx context.Context, q trustTierWriter, providerID, tier string) error {
	now := time.Now().UTC()
	var cooldown interface{}
	if tier == TierProvisional {
		cooldown = now.Add(trustRequalifyWindow)
	}
	_, err := q.ExecContext(ctx, `
        INSERT INTO provider_emission_state (provider_id, trust_tier, demotion_cooldown_until, updated_at)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (provider_id) DO UPDATE SET
            trust_tier = EXCLUDED.trust_tier,
            demotion_cooldown_until = CASE
                WHEN EXCLUDED.trust_tier = 'trusted' THEN NULL
                ELSE EXCLUDED.demotion_cooldown_until
            END,
            updated_at = EXCLUDED.updated_at
    `, providerID, tier, cooldown, now)
	return err
}
