package main

import (
	"database/sql"
	"net/http"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/rewards"
	"github.com/augstar/macprovider-coordinator/internal/stakeallowance"
	"github.com/rs/zerolog"
)

// setupStakeAllowance builds the SPEC-050 internal handler. Without a rewards
// database the stake source is unavailable and stake calls answer 503; the
// rest of the coordinator is unaffected.
func setupStakeAllowance(cfg *config.Config, coordinatorDB, rewardsDB *sql.DB, logger zerolog.Logger) http.Handler {
	logger = logger.With().Str("subsystem", "stake_allowance").Logger()
	deps := stakeallowance.Deps{
		GatewayServiceToken: cfg.Auth.GatewayServiceToken,
		OwnedProviderIDs:    stakeallowance.OwnedProviderLookup(coordinatorDB),
		Logger:              logger,
	}
	if rewardsDB != nil {
		ledger, err := rewards.NewStakeLedger(rewardsDB,
			time.Duration(cfg.StakeAllowance.UnlockCooldownHours)*time.Hour,
			stakeallowance.ProviderOwnerLookup(coordinatorDB))
		if err != nil {
			logger.Warn().Err(err).Msg("SPEC-050 stake ledger unavailable")
		} else {
			deps.Ledger = ledger
		}
	} else {
		logger.Warn().Msg("SPEC-050 stake ledger unavailable: malibu_emission.writer_dsn is not set")
	}
	return stakeallowance.NewHandler(deps)
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
