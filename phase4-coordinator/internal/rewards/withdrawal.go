package rewards

import (
	"context"
	"database/sql"
	"fmt"
	"math/big"
	"time"
)

// WithdrawableRow is a MALIBU ledger row eligible for withdrawal.
type WithdrawableRow struct {
	ID           int64
	ProviderID   string
	UnixTS       int64
	AmountMALIBU string
}

// SelectWithdrawableMALIBU returns ledger rows with no withdrawal hold,
// oldest first, leaving out MALIBU locked by SPEC-050 stakes
// (SPEC-050-R003). It runs SelectWithdrawableMALIBUTx in its own
// transaction; a withdrawal runner must instead call SelectWithdrawableMALIBUTx
// inside the transaction that claims the rows, so no stake lock can commit
// between selection and claim.
func SelectWithdrawableMALIBU(ctx context.Context, db *sql.DB, providerID string, limit int) ([]WithdrawableRow, error) {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	rows, err := SelectWithdrawableMALIBUTx(ctx, tx, providerID, limit)
	if err != nil {
		return nil, err
	}
	return rows, tx.Commit()
}

// SelectWithdrawableMALIBUTx selects withdrawable rows while holding the
// provider's stake advisory lock for the rest of tx, so stake locks and
// withdrawal claims are serialized per provider. Rows are taken oldest first
// while their running total stays within withdrawable minus every MALIBU
// still locked on the provider; a row only partly covered by the stake is
// left out too. Amounts are summed with arbitrary precision.
func SelectWithdrawableMALIBUTx(ctx context.Context, tx *sql.Tx, providerID string, limit int) ([]WithdrawableRow, error) {
	if limit <= 0 {
		limit = 100
	}
	if err := lockAdvisory(ctx, tx, "malibu_stake_provider:"+providerID); err != nil {
		return nil, fmt.Errorf("withdrawable: provider lock: %w", err)
	}
	rows, err := tx.QueryContext(ctx, `
        SELECT prl.id, prl.provider_id, prl.unix_ts, prl.amount_malibu::TEXT,
               (prl.amount_malibu * 100000000)::NUMERIC(38,0)::TEXT
          FROM malibu_rewards_ledger_with_disposition prl
         WHERE prl.provider_id = $1
           AND prl.amount_malibu IS NOT NULL
           AND prl.amount_malibu > 0
           AND prl.withdrawal_hold_reason IS NULL
           AND NOT prl.epoch_disposition_blocked
         ORDER BY prl.id ASC
    `, providerID)
	if err != nil {
		return nil, err
	}
	var all []WithdrawableRow
	var units []*big.Int
	total := new(big.Int)
	for rows.Next() {
		var row WithdrawableRow
		var unitText string
		if err := rows.Scan(&row.ID, &row.ProviderID, &row.UnixTS, &row.AmountMALIBU, &unitText); err != nil {
			rows.Close()
			return nil, err
		}
		u, ok := new(big.Int).SetString(unitText, 10)
		if !ok || u.Sign() <= 0 {
			rows.Close()
			return nil, fmt.Errorf("withdrawable row %d amount %q is not a positive ledger amount", row.ID, row.AmountMALIBU)
		}
		all = append(all, row)
		units = append(units, u)
		total.Add(total, u)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, err
	}
	rows.Close()
	lockedUnits, err := stakeLockedUnits(ctx, tx, providerID)
	if err != nil {
		return nil, err
	}
	locked := big.NewInt(lockedUnits)
	available := new(big.Int).Sub(total, locked)
	running := new(big.Int)
	var out []WithdrawableRow
	for i, row := range all {
		next := new(big.Int).Add(running, units[i])
		if len(out) >= limit || next.Cmp(available) > 0 {
			break
		}
		running = next
		out = append(out, row)
	}
	return out, nil
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
