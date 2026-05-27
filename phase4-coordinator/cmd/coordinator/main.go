package main

import (
	"flag"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

func main() {
	configPath := flag.String("config", "coordinator.yaml", "path to coordinator YAML config")
	flag.Parse()

	cfg, err := config.Load(*configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "config: %v\n", err)
		os.Exit(1)
	}

	logger := zerolog.New(os.Stdout).With().Timestamp().Logger()
	registry := pool.NewRegistry(cfg.Providers)
	startedAt := time.Now().UTC()
	tokenStore, err := auth.OpenStore(cfg.Storage.DBPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "storage: %v\n", err)
		os.Exit(1)
	}
	defer tokenStore.Close()
	wsServer := providerws.NewServer(cfg, registry, logger, providerws.WithTokenValidator(tokenStore))
	buyerServer := buyer.NewServer(
		registry,
		logger,
		startedAt,
		buyer.WithPreflightConfig(cfg.Routing.PreflightThresholdTokens, time.Duration(cfg.Routing.PreflightTimeoutS)*time.Second),
		buyer.WithRecoveryConfig(time.Duration(cfg.Pool.DegradedBackoffS)*time.Second, cfg.Pool.DegradedMaxRetries, cfg.Pool.DegradedProbeAfter502),
		buyer.WithPreflight(func(provider pool.Provider, requestID string, estimatedTokens int, timeout time.Duration) (buyer.PreflightResult, bool, error) {
			ack, ok, err := wsServer.Preflight(provider, requestID, estimatedTokens, timeout)
			return buyer.PreflightResult{Accepted: ack.Accepted, Reason: ack.Reason}, ok, err
		}),
	)
	providerAddr := fmt.Sprintf("%s:%d", cfg.Listen.BindAddress, cfg.Listen.ProviderPort)
	buyerAddr := fmt.Sprintf("%s:%d", cfg.Listen.BindAddress, cfg.Listen.BuyerPort)
	errs := make(chan error, 2)

	go func() {
		logger.Info().Str("addr", providerAddr).Msg("provider websocket server listening")
		errs <- http.ListenAndServe(providerAddr, wsServer.Handler())
	}()
	go func() {
		logger.Info().Str("addr", buyerAddr).Msg("buyer http server listening")
		errs <- http.ListenAndServe(buyerAddr, buyerServer.Handler())
	}()

	logger.Fatal().Err(<-errs).Msg("coordinator server stopped")
}
