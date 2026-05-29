package main

import (
	"context"
	"flag"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/augstar/macprovider-gateway/internal/auth"
	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/router"
	"github.com/augstar/macprovider-gateway/internal/storage/sqlite"
)

func main() {
	configPath := flag.String("config", "gateway.yaml", "path to gateway YAML config")
	checkOnly := flag.Bool("check", false, "load config, migrate storage, then exit")
	flag.Parse()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	cfg, err := config.Load(*configPath)
	if err != nil {
		slog.Error("load config failed", "path", *configPath, "error", err)
		os.Exit(1)
	}

	store, err := sqlite.Open(ctx, cfg.Storage.DBPath)
	if err != nil {
		slog.Error("open storage failed", "driver", cfg.Storage.Driver, "path", cfg.Storage.DBPath, "error", err)
		os.Exit(1)
	}
	defer func() {
		if err := store.Close(); err != nil {
			slog.Warn("close storage failed", "error", err)
		}
	}()

	slog.Info("gateway initialized", "address", cfg.Address(), "db_path", cfg.Storage.DBPath)
	if *checkOnly {
		return
	}

	go runReservationReaper(ctx, store)

	upstreamClient := &http.Client{Timeout: cfg.CoordinatorTimeout()}
	oauth := auth.NewGitHubProvider(cfg.Auth.OAuth.GitHub, upstreamClient)
	httpServer := &http.Server{
		Addr:              cfg.Address(),
		Handler:           router.New(cfg, store, oauth, router.WithHTTPClient(upstreamClient)).Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	go func() {
		slog.Info("gateway listening", "address", cfg.Address())
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("gateway listen failed", "error", err)
			stop()
		}
	}()

	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		slog.Warn("gateway shutdown error", "error", err)
	}
	slog.Info("gateway shutdown complete")
}

type reservationReaper interface {
	ReapExpiredReservations(context.Context, time.Time) (int64, error)
}

func runReservationReaper(ctx context.Context, store reservationReaper) {
	reap := func() {
		n, err := store.ReapExpiredReservations(ctx, time.Now().UTC())
		if err != nil {
			slog.Warn("quota reservation reaper failed", "error", err)
			return
		}
		if n > 0 {
			slog.Info("expired quota reservations reaped", "count", n)
		}
	}
	reap()
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			reap()
		}
	}
}
