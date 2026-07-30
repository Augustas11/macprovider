package rewards

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/lib/pq"
)

// RunEmissionTickOnce runs a single accrual tick (test/export hook).
func (r *Runner) RunEmissionTickOnce(ctx context.Context) error {
	return r.runEmissionTick(ctx)
}

// RunWalletMirrorOnce runs a single wallet projection sync.
func (r *Runner) RunWalletMirrorOnce(ctx context.Context) error {
	return r.runWalletMirror(ctx)
}

func (r *Runner) runEmissionTick(ctx context.Context) error {
	providers, err := r.listEligibleProviders(ctx)
	if err != nil {
		return err
	}
	tickAmount := r.cfg.ProviderDailyCapMALIBU / r.ticksPerDay()
	for _, pid := range providers {
		if err := r.accrueProvider(ctx, pid, tickAmount); err != nil {
			r.logger.Warn().Err(err).Str("provider_id", pid).Msg("accrual failed")
		}
	}
	return nil
}

func (r *Runner) ticksPerDay() float64 {
	secs := r.cfg.TickInterval.Seconds()
	if secs <= 0 {
		return 96 // 15m default
	}
	return 86400 / secs
}

func (r *Runner) listEligibleProviders(ctx context.Context) ([]string, error) {
	// Seed emission state for App-track identities not yet seen.
	if _, err := r.db.ExecContext(ctx, `
        INSERT INTO provider_emission_state (provider_id, trust_tier)
        SELECT i.provider_id, $1
          FROM provider_identities i
         WHERE NOT EXISTS (
            SELECT 1 FROM provider_emission_state s WHERE s.provider_id = i.provider_id
         )
    `, TierProvisional); err != nil {
		return nil, err
	}
	rows, err := r.db.QueryContext(ctx, `
        SELECT provider_id FROM provider_emission_state
    `)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var pid string
		if err := rows.Scan(&pid); err != nil {
			return nil, err
		}
		out = append(out, pid)
	}
	return out, rows.Err()
}

type providerState struct {
	TrustTier             string
	BoundWallet           sql.NullString
	CapReplayPending      bool
	ProviderDayMALIBU     float64
	EmissionDay           sql.NullTime
	DemotionCooldownUntil sql.NullTime
}

func (r *Runner) accrueProvider(ctx context.Context, providerID string, tickAmount float64) error {
	if tickAmount <= 0 {
		return nil
	}
	return r.withSerializableRetry(ctx, func(tx *sql.Tx) error {
		if _, err := tx.ExecContext(ctx, `
            INSERT INTO provider_emission_state (provider_id, trust_tier)
            VALUES ($1, $2)
            ON CONFLICT (provider_id) DO NOTHING
        `, providerID, TierProvisional); err != nil {
			return err
		}
		st, err := loadProviderState(ctx, tx, providerID)
		if err != nil {
			return err
		}
		today := utcDay(time.Now().UTC())
		if !st.EmissionDay.Valid || !sameUTCDay(st.EmissionDay.Time, today) {
			st.ProviderDayMALIBU = 0
		}
		remaining := r.cfg.ProviderDailyCapMALIBU - st.ProviderDayMALIBU
		if remaining <= 0 {
			return nil
		}
		accrue := math.Min(tickAmount, remaining)
		if accrue <= 0 {
			return nil
		}

		hold := holdReasonForState(st)
		wallet := strings.ToLower(st.BoundWallet.String)
		if wallet != "" && strings.HasPrefix(wallet, "0x") {
			walletHeld, walletAccrue, err := applyWalletCap(ctx, tx, wallet, today, accrue, r.cfg.WalletDailyCapMALIBU, st.TrustTier)
			if err != nil {
				return err
			}
			if walletAccrue <= 0 {
				return nil
			}
			accrue = walletAccrue
			if walletHeld {
				if hold == "" {
					hold = HoldPerWalletDailyCap
				}
			}
		}

		var holdArg sql.NullString
		if hold != "" {
			holdArg = sql.NullString{String: hold, Valid: true}
		}

		now := time.Now().UTC()
		if _, err := tx.ExecContext(ctx, `
            INSERT INTO provider_rewards_ledger
                (provider_id, unix_ts, amount_malibu, withdrawal_hold_reason, reason)
            VALUES ($1, $2, $3, $4, 'malibu_bootstrap_tick')
        `, providerID, now.Unix(), formatMALIBU(accrue), holdArg); err != nil {
			return err
		}

		newDayTotal := st.ProviderDayMALIBU + accrue
		if _, err := tx.ExecContext(ctx, `
            INSERT INTO provider_emission_state
                (provider_id, trust_tier, bound_wallet, provider_day_malibu, emission_day, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6)
            ON CONFLICT (provider_id) DO UPDATE SET
                provider_day_malibu = $4,
                emission_day = $5,
                updated_at = $6
        `, providerID, st.TrustTier, nullString(st.BoundWallet), newDayTotal, today, now); err != nil {
			return err
		}

		if wallet != "" && strings.HasPrefix(wallet, "0x") {
			if err := bumpWalletDaily(ctx, tx, wallet, today, accrue); err != nil {
				return err
			}
		}

		if st.CapReplayPending && wallet != "" {
			return replayCapPending(ctx, tx, wallet, r.cfg.WalletDailyCapMALIBU)
		}
		return nil
	})
}

func holdReasonForState(st providerState) string {
	if st.DemotionCooldownUntil.Valid && time.Now().UTC().Before(st.DemotionCooldownUntil.Time) {
		return HoldDemotionCooldown
	}
	if st.TrustTier != TierTrusted {
		return HoldTrustTierProvisional
	}
	return ""
}

func loadProviderState(ctx context.Context, tx *sql.Tx, providerID string) (providerState, error) {
	var st providerState
	err := tx.QueryRowContext(ctx, `
        SELECT trust_tier, bound_wallet, cap_replay_pending,
               provider_day_malibu::FLOAT8, emission_day, demotion_cooldown_until
          FROM provider_emission_state
         WHERE provider_id = $1
         FOR UPDATE
    `, providerID).Scan(
		&st.TrustTier, &st.BoundWallet, &st.CapReplayPending,
		&st.ProviderDayMALIBU, &st.EmissionDay, &st.DemotionCooldownUntil,
	)
	if err == sql.ErrNoRows {
		return providerState{TrustTier: TierProvisional}, nil
	}
	return st, err
}

func applyWalletCap(ctx context.Context, tx *sql.Tx, wallet string, day time.Time, want float64, cap float64, tier string) (held bool, accrue float64, err error) {
	sum, err := walletDaySum(ctx, tx, wallet, day)
	if err != nil {
		return false, 0, err
	}
	remaining := cap - sum
	if remaining <= 0 {
		// Still accrue at zero? Spec says accrue with hold when cap hit.
		// Accrue the requested amount but mark held — caller sets hold.
		return true, want, nil
	}
	if want > remaining {
		return true, remaining, nil
	}
	_ = tier
	return false, want, nil
}

func walletDaySum(ctx context.Context, tx *sql.Tx, wallet string, day time.Time) (float64, error) {
	var sum sql.NullFloat64
	err := tx.QueryRowContext(ctx, `
        SELECT sum_malibu::FLOAT8
          FROM wallet_daily_malibu_emission
         WHERE bound_wallet = $1 AND emission_day = $2
         FOR UPDATE
    `, wallet, day).Scan(&sum)
	if err == sql.ErrNoRows {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	if !sum.Valid {
		return 0, nil
	}
	return sum.Float64, nil
}

func bumpWalletDaily(ctx context.Context, tx *sql.Tx, wallet string, day time.Time, delta float64) error {
	now := time.Now().UTC()
	_, err := tx.ExecContext(ctx, `
        INSERT INTO wallet_daily_malibu_emission (bound_wallet, emission_day, sum_malibu, updated_at)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (bound_wallet, emission_day) DO UPDATE SET
            sum_malibu = wallet_daily_malibu_emission.sum_malibu + EXCLUDED.sum_malibu,
            updated_at = EXCLUDED.updated_at
    `, wallet, day, formatMALIBU(delta), now)
	return err
}

func replayCapPending(ctx context.Context, tx *sql.Tx, wallet string, walletCap float64) error {
	// Oldest-first replay: for trusted providers, clear per_wallet_daily_cap
	// holds where aggregate now permits withdrawal.
	rows, err := tx.QueryContext(ctx, `
        SELECT prl.id, prl.amount_malibu::FLOAT8, pes.trust_tier
          FROM provider_rewards_ledger prl
          JOIN provider_emission_state pes ON pes.provider_id = prl.provider_id
         WHERE pes.bound_wallet = $1
           AND prl.withdrawal_hold_reason = $2
           AND pes.trust_tier = $3
         ORDER BY prl.unix_ts ASC, prl.id ASC
         FOR UPDATE OF prl
    `, wallet, HoldPerWalletDailyCap, TierTrusted)
	if err != nil {
		return err
	}
	defer rows.Close()

	day := utcDay(time.Now().UTC())
	var running float64
	if s, err := walletDaySum(ctx, tx, wallet, day); err != nil {
		return err
	} else {
		running = s
	}

	for rows.Next() {
		var id int64
		var amt float64
		var tier string
		if err := rows.Scan(&id, &amt, &tier); err != nil {
			return err
		}
		if tier != TierTrusted {
			continue
		}
		if running+amt <= walletCap {
			if _, err := tx.ExecContext(ctx, `
                UPDATE provider_rewards_ledger
                   SET withdrawal_hold_reason = NULL
                 WHERE id = $1
            `, id); err != nil {
				return err
			}
		}
		running += amt
	}
	if err := rows.Err(); err != nil {
		return err
	}

	_, err = tx.ExecContext(ctx, `
        UPDATE provider_emission_state
           SET cap_replay_pending = FALSE, updated_at = $2
         WHERE bound_wallet = $1 AND cap_replay_pending = TRUE
    `, wallet, time.Now().UTC())
	return err
}

func (r *Runner) withSerializableRetry(ctx context.Context, fn func(*sql.Tx) error) error {
	var lastErr error
	for attempt := 0; attempt < r.cfg.MaxSerializableRetries; attempt++ {
		if attempt > 0 {
			backoff := time.Duration(10*(1<<attempt)) * time.Millisecond
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(backoff):
			}
		}
		tx, err := r.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable})
		if err != nil {
			return err
		}
		err = fn(tx)
		if err == nil {
			if commitErr := tx.Commit(); commitErr != nil {
				if isSerializationFailure(commitErr) {
					lastErr = commitErr
					continue
				}
				return commitErr
			}
			return nil
		}
		_ = tx.Rollback()
		if isSerializationFailure(err) {
			lastErr = err
			continue
		}
		return err
	}
	if lastErr != nil {
		return fmt.Errorf("serializable retries exhausted: %w", lastErr)
	}
	return errors.New("serializable retries exhausted")
}

func isSerializationFailure(err error) bool {
	var pqErr *pq.Error
	if errors.As(err, &pqErr) {
		return pqErr.Code == "40001"
	}
	return false
}

func utcDay(t time.Time) time.Time {
	y, m, d := t.Date()
	return time.Date(y, m, d, 0, 0, 0, 0, time.UTC)
}

func sameUTCDay(a, b time.Time) bool {
	return utcDay(a).Equal(utcDay(b))
}

func formatMALIBU(v float64) string {
	return fmt.Sprintf("%.8f", v)
}

func nullString(ns sql.NullString) interface{} {
	if ns.Valid {
		return ns.String
	}
	return nil
}
