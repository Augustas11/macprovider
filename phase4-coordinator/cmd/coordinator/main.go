package main

import (
	"flag"
	"fmt"
	"net/http"
	"os"
	"time"

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
	wsServer := providerws.NewServer(cfg, registry, logger)
	buyerServer := buyer.NewServer(registry, logger, startedAt)
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
