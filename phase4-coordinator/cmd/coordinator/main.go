package main

import (
	"flag"
	"fmt"
	"net/http"
	"os"

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
	wsServer := providerws.NewServer(cfg, registry, logger)
	addr := fmt.Sprintf("%s:%d", cfg.Listen.BindAddress, cfg.Listen.ProviderPort)

	logger.Info().Str("addr", addr).Msg("provider websocket server listening")
	if err := http.ListenAndServe(addr, wsServer.Handler()); err != nil {
		logger.Fatal().Err(err).Msg("provider websocket server stopped")
	}
}
