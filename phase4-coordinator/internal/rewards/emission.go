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

const (
	ReasonMalibuBootstrapTick         = "malibu_bootstrap_tick"
	ReasonMalibuVerifiedUsefulWorkV02 = "malibu_verified_useful_work_v0_2"
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
	if !r.cfg.BootstrapTickEnabled {
		return nil
	}
	if r.cfg.EpochEnabled {
		return ErrEpochPolicyEngineUnavailable
	}
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
	return r.accrueProviderReward(ctx, providerID, tickAmount, ReasonMalibuBootstrapTick, "")
}

func (r *Runner) accrueProviderReward(ctx context.Context, providerID string, amount float64, reason, externalRef string) error {
	if amount <= 0 {
		return nil
	}
	return r.withSerializableRetry(ctx, func(tx *sql.Tx) error {
		if externalRef != "" {
			exists, err := rewardExternalRefExists(ctx, tx, externalRef)
			if err != nil {
				return err
			}
			if exists {
				return nil
			}
		}
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
			return r.recordFullyCappedAccrual(ctx, tx, providerID, "", st.TrustTier, reason, externalRef)
		}
		accrue := math.Min(amount, remaining)
		if accrue <= 0 {
			return nil
		}

		hold := holdReasonForState(st)
		walletCapApplied := false
		wallet := strings.ToLower(st.BoundWallet.String)
		if wallet != "" && strings.HasPrefix(wallet, "0x") {
			walletHeld, walletAccrue, err := applyWalletCap(ctx, tx, wallet, today, accrue, r.cfg.WalletDailyCapMALIBU, st.TrustTier)
			if err != nil {
				return err
			}
			if walletAccrue <= 0 {
				return r.recordFullyCappedAccrual(ctx, tx, providerID, HoldPerWalletDailyCap, st.TrustTier, reason, externalRef)
			}
			accrue = walletAccrue
			if walletHeld {
				walletCapApplied = true
				if hold == "" {
					hold = HoldPerWalletDailyCap
				}
			}
		}

		var holdArg sql.NullString
		if hold != "" {
			holdArg = sql.NullString{String: hold, Valid: true}
		}
		var refArg sql.NullString
		if externalRef != "" {
			refArg = sql.NullString{String: externalRef, Valid: true}
		}

		now := time.Now().UTC()
		var ledgerID int64
		if err := tx.QueryRowContext(ctx, `
            INSERT INTO provider_rewards_ledger
                (provider_id, unix_ts, amount_malibu, withdrawal_hold_reason, reason, external_ref)
            VALUES ($1, $2, $3, $4, $5, $6)
            RETURNING id
        `, providerID, now.Unix(), formatMALIBU(accrue), holdArg, reason, refArg).Scan(&ledgerID); err != nil {
			return err
		}
		if err := auditAccrualInserted(ctx, tx, providerID, ledgerID, formatMALIBU(accrue), hold, st.TrustTier, reason, externalRef, now); err != nil {
			return err
		}
		if hold != "" {
			if err := auditHoldApplied(ctx, tx, providerID, ledgerID, formatMALIBU(accrue), hold, st.TrustTier, reason, externalRef, now); err != nil {
				return err
			}
		}
		if walletCapApplied {
			if err := auditWalletDailyCapApplied(ctx, tx, providerID, ledgerID, formatMALIBU(accrue), HoldPerWalletDailyCap, st.TrustTier, reason, externalRef, now); err != nil {
				return err
			}
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

func (r *Runner) recordFullyCappedAccrual(ctx context.Context, tx *sql.Tx, providerID, hold, tier, reason, externalRef string) error {
	if externalRef == "" {
		return nil
	}
	now := time.Now().UTC()
	var ledgerID int64
	if err := tx.QueryRowContext(ctx, `
        INSERT INTO provider_rewards_ledger
            (provider_id, unix_ts, amount_malibu, withdrawal_hold_reason, reason, external_ref)
        VALUES ($1, $2, $3, $4, $5, $6)
        RETURNING id
    `, providerID, now.Unix(), formatMALIBU(0), sql.NullString{String: hold, Valid: hold != ""}, reason, externalRef).Scan(&ledgerID); err != nil {
		return err
	}
	if hold == "" {
		return auditAccrualInserted(ctx, tx, providerID, ledgerID, formatMALIBU(0), "", tier, reason, externalRef, now)
	}
	return auditWalletDailyCapApplied(ctx, tx, providerID, ledgerID, formatMALIBU(0), hold, tier, reason, externalRef, now)
}

func rewardExternalRefExists(ctx context.Context, tx *sql.Tx, externalRef string) (bool, error) {
	var exists bool
	err := tx.QueryRowContext(ctx, `
        SELECT EXISTS (
            SELECT 1 FROM provider_rewards_ledger
             WHERE external_ref = $1
               AND amount_malibu IS NOT NULL
        )
    `, externalRef).Scan(&exists)
	return exists, err
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
		return true, 0, nil
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

type pendingReplayRow struct {
	id         int64
	providerID string
	amt        float64
	amountText string
	tier       string
	reason     sql.NullString
}

func replayCapPending(ctx context.Context, tx *sql.Tx, wallet string, walletCap float64) error {
	// Oldest-first replay: for trusted providers, clear per_wallet_daily_cap
	// holds where aggregate now permits withdrawal.
	//
	// The candidate rows are read to completion and the *sql.Rows is closed
	// BEFORE any further statement runs on this tx/connection. lib/pq does
	// not buffer query results like libpq does; issuing an Exec on the same
	// connection while a Rows result set from an earlier Query is still
	// open desyncs the wire protocol (surfaces as
	// `pq: unexpected Parse response "(C) CommandComplete"`).
	rows, err := tx.QueryContext(ctx, `
        SELECT prl.id, prl.provider_id, prl.amount_malibu::FLOAT8, prl.amount_malibu::TEXT,
               pes.trust_tier, prl.reason
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
	var pending []pendingReplayRow
	for rows.Next() {
		var row pendingReplayRow
		if err := rows.Scan(&row.id, &row.providerID, &row.amt, &row.amountText, &row.tier, &row.reason); err != nil {
			_ = rows.Close()
			return err
		}
		pending = append(pending, row)
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return err
	}
	if err := rows.Close(); err != nil {
		return err
	}

	day := utcDay(time.Now().UTC())
	running, err := walletDaySum(ctx, tx, wallet, day)
	if err != nil {
		return err
	}

	for _, row := range pending {
		if row.tier != TierTrusted {
			continue
		}
		if running+row.amt <= walletCap {
			if _, err := tx.ExecContext(ctx, `
                UPDATE provider_rewards_ledger
                   SET withdrawal_hold_reason = NULL
                 WHERE id = $1
            `, row.id); err != nil {
				return err
			}
			if err := auditHoldCleared(ctx, tx, row.providerID, row.id, row.amountText, HoldPerWalletDailyCap, row.tier, row.reason.String, time.Now().UTC()); err != nil {
				return err
			}
		}
		running += row.amt
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
