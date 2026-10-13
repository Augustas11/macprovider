package main

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/rewards"
	"github.com/augstar/macprovider-coordinator/internal/stakeallowance"
	"github.com/rs/zerolog"
)

// setupStakeAllowance wires SPEC-050: the stake ledger over the rewards
// database, the daily allowance refresh, and the internal handler. Without a
// rewards database the stake source is unavailable: stake calls answer 503
// and no allowance is granted; the rest of the coordinator is unaffected.
func setupStakeAllowance(ctx context.Context, cfg *config.Config, coordinatorDB, rewardsDB *sql.DB, billingStore *billing.Store, logger zerolog.Logger) http.Handler {
	logger = logger.With().Str("subsystem", "stake_allowance").Logger()
	deps := stakeallowance.Deps{
		GatewayServiceToken: cfg.Auth.GatewayServiceToken,
		OwnedProviderIDs:    stakeallowance.OwnedProviderLookup(coordinatorDB),
		PayoutAddresses:     stakeallowance.PayoutAddressLookup(coordinatorDB),
		Logger:              logger,
	}
	if billingStore != nil {
		deps.Allowance = billingStore
	}
	var source billing.AllowanceStakeSource
	if rewardsDB != nil {
		ledger, err := rewards.NewStakeLedger(rewardsDB,
			time.Duration(cfg.StakeAllowance.UnlockCooldownHours)*time.Hour,
			stakeallowance.ProviderOwnerLookup(coordinatorDB))
		if err != nil {
			logger.Warn().Err(err).Msg("SPEC-050 stake ledger unavailable")
		} else {
			deps.Ledger = ledger
			source = stakeSourceAdapter{ledger: ledger}
		}
	} else {
		logger.Warn().Msg("SPEC-050 stake ledger unavailable: malibu_emission.writer_dsn is not set")
	}
	if billingStore != nil {
		startAllowanceRefresher(ctx, billingStore, source, allowancePolicy(cfg.StakeAllowance),
			time.Duration(cfg.StakeAllowance.RefreshCheckIntervalSeconds)*time.Second, time.Now().UTC(), logger)
	}
	return stakeallowance.NewHandler(deps)
}

func allowancePolicy(c config.StakeAllowanceConfig) billing.AllowancePolicy {
	return billing.AllowancePolicy{
		DailyBudgetCredits:        c.DailyBudgetCredits,
		CreditsPerMALIBU:          c.CreditsPerMALIBU,
		PerAccountDailyCapCredits: c.PerAccountDailyCapCredits,
		MinStakeAge:               time.Duration(c.MinStakeAgeHours) * time.Hour,
	}
}

// stakeSourceAdapter presents the rewards stake ledger as billing's
// SPEC-050-R001 stake source.
type stakeSourceAdapter struct {
	ledger *rewards.StakeLedger
}

func (a stakeSourceAdapter) Name() string { return a.ledger.Name() }

func (a stakeSourceAdapter) EarningStakes(ctx context.Context, dayStart time.Time, minAge time.Duration) ([]billing.AllowanceStake, error) {
	stakes, err := a.ledger.EarningStakes(ctx, dayStart, minAge)
	if err != nil {
		return nil, err
	}
	out := make([]billing.AllowanceStake, 0, len(stakes))
	for _, s := range stakes {
		out = append(out, billing.AllowanceStake{AccountID: s.AccountID, GitHubUserID: s.GitHubUserID, Units: s.Units})
	}
	return out, nil
}

// startAllowanceRefresher records each UTC day's allowance at the first check
// after 00:00 UTC (SPEC-050-R005) and closes allowance holds left by an
// earlier coordinator process (SPEC-050-R008). A run that fails is retried at the next check; a day
// already recorded is left unchanged.
func startAllowanceRefresher(ctx context.Context, store *billing.Store, source billing.AllowanceStakeSource, policy billing.AllowancePolicy, interval time.Duration, processStart time.Time, logger zerolog.Logger) {
	if interval <= 0 {
		interval = time.Minute
	}
	go func() {
		tick := func() {
			tickCtx, cancel := context.WithTimeout(ctx, interval)
			defer cancel()
			if closed, err := store.ReapAllowanceReservations(tickCtx, time.Now().UTC(), processStart); err != nil {
				logger.Warn().Err(err).Msg("allowance reservation reaper failed")
			} else if closed > 0 {
				logger.Info().Int64("closed", closed).Msg("stale allowance holds closed")
			}
			created, totals, err := store.RefreshAllowanceDay(tickCtx, time.Now().UTC(), source, policy)
			switch {
			case errors.Is(err, billing.ErrAllowanceStakeSourceUnavailable):
				logger.Debug().Msg("allowance refresh skipped: stake source unavailable")
			case err != nil:
				if tickCtx.Err() == nil {
					logger.Warn().Err(err).Msg("allowance refresh failed; retrying at next check")
				}
			case created:
				logger.Info().
					Int64("total_stake_units", totals.TotalStakeUnits).
					Int64("total_raw_credits", totals.TotalRawCredits).
					Int64("total_granted_credits", totals.TotalGrantedCredits).
					Int64("scale_ppm", totals.ScalePPM).
					Msg("allowance refresh recorded")
			}
		}
		tick()
		t := time.NewTicker(interval)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				tick()
			}
		}
	}()
}

func withStakeAllowance(base, stake http.Handler) http.Handler {
	if stake == nil {
		return base
	}
	mux := http.NewServeMux()
	mux.Handle(stakeallowance.Prefix, stake)
	mux.Handle("/", base)
	return mux
}
