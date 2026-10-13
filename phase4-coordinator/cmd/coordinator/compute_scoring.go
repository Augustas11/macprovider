package main

import (
	"context"
	"database/sql"

	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/computeintegrity"
	"github.com/augstar/macprovider-coordinator/internal/config"
	statsmetrics "github.com/augstar/macprovider-coordinator/internal/stats/metrics"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// startComputeScoring wires SPEC-036 §5A cross-provider scoring: the
// verification dispatcher is the buyer server's ordinary chat-completions
// path, holds are the SPEC-022 R-16 billing store, and operator keys come
// from provider ownership. A wiring failure is logged and leaves scoring off;
// it never blocks the coordinator from serving.
func startComputeScoring(
	ctx context.Context,
	cfg config.ComputeIntegrityScoringConfig,
	db *sql.DB,
	wsServer *providerws.Server,
	buyerServer *buyer.Server,
	tokens *auth.Store,
	holds *billing.Store,
	metrics providerws.ComputeScoringMetrics,
	logger zerolog.Logger,
) {
	store, err := computeintegrity.NewScoringStore(ctx, db)
	if err != nil {
		logger.Error().Err(err).Str("event", "compute_integrity_scoring_start_failed").Msg("compute-integrity scoring store unavailable")
		return
	}
	err = wsServer.StartComputeScoring(ctx, providerws.ComputeScoringDeps{
		Config: cfg,
		Store:  store,
		Dispatch: func(ctx context.Context, d providerws.ComputeIntegrityProbeDispatch) (providerws.ComputeIntegrityProbeResponse, error) {
			got, err := buyerServer.DispatchComputeIntegrityProbe(ctx, d.ProviderID, d.Body, d.MaxTokens)
			if err != nil {
				return providerws.ComputeIntegrityProbeResponse{}, err
			}
			return providerws.ComputeIntegrityProbeResponse{OutputText: got.OutputText, ReasoningText: got.ReasoningText, Complete: got.Complete}, nil
		},
		OperatorKey: tokens.ProviderOperatorKey,
		Holds:       holds,
		Metrics:     metrics,
	})
	if err != nil {
		logger.Error().Err(err).Str("event", "compute_integrity_scoring_start_failed").Msg("compute-integrity scoring not started")
		return
	}
	logger.Info().Str("event", "compute_integrity_scoring_started").Bool("enabled", cfg.Enabled).Msg("compute-integrity scoring started")
}

var _ providerws.ComputeScoringMetrics = (*statsmetrics.Metrics)(nil)
