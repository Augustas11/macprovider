package main

import (
	"context"
	"database/sql"
	"os"

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
// from provider ownership. Startup fails closed: a coordinator that cannot
// load compute-integrity state would route suspended providers again, so it
// does not start.
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
	corpus := computeintegrity.DefaultCorpus()
	switch {
	case !cfg.Enabled:
	case cfg.CorpusPath != "":
		// A bad private corpus stops scheduling only; state still loads so
		// failed keys stay out of routing, and the coordinator serves.
		raw, err := os.ReadFile(cfg.CorpusPath)
		if err == nil {
			corpus, err = computeintegrity.ParseCorpus(raw)
		}
		if err != nil {
			logger.Error().Err(err).Str("event", "compute_integrity_corpus_invalid").Msg("compute-integrity private corpus unusable; verification scheduling stays off")
			cfg.Enabled = false
			corpus = computeintegrity.DefaultCorpus()
		} else {
			logger.Info().Str("event", "compute_integrity_corpus_loaded").Int("prompts", corpus.Len()).Str("version", corpus.Version()).Msg("compute-integrity private corpus loaded")
		}
	default:
		logger.Warn().Str("event", "compute_integrity_public_corpus").Msg("compute-integrity scoring uses the public checked-in corpus; configure compute_integrity.scoring.corpus_path")
	}
	store, err := computeintegrity.NewScoringStore(ctx, db)
	if err != nil {
		logger.Fatal().Err(err).Str("event", "compute_integrity_scoring_start_failed").Msg("compute-integrity scoring store unavailable")
	}
	err = wsServer.StartComputeScoring(ctx, providerws.ComputeScoringDeps{
		Config: cfg,
		Store:  store,
		Dispatch: func(ctx context.Context, d providerws.ComputeIntegrityProbeDispatch) (providerws.ComputeIntegrityProbeResponse, error) {
			got, err := buyerServer.DispatchComputeIntegrityProbe(ctx, d.AssignedID, d.Body, d.MaxTokens)
			if err != nil {
				return providerws.ComputeIntegrityProbeResponse{}, err
			}
			return providerws.ComputeIntegrityProbeResponse{OutputText: got.OutputText, ReasoningText: got.ReasoningText, Complete: got.Complete}, nil
		},
		OperatorKey: tokens.ProviderOperatorKey,
		Corpus:      corpus,
		Holds:       holds,
		Metrics:     metrics,
	})
	if err != nil {
		logger.Fatal().Err(err).Str("event", "compute_integrity_scoring_start_failed").Msg("compute-integrity scoring not started")
	}
	logger.Info().Str("event", "compute_integrity_scoring_started").Bool("enabled", cfg.Enabled).Msg("compute-integrity scoring started")
}

var _ providerws.ComputeScoringMetrics = (*statsmetrics.Metrics)(nil)
