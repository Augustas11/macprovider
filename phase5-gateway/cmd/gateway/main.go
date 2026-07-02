package main

import (
	"context"
	"flag"
	"fmt"
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

// version is overridden at build time via
//
//	go build -ldflags "-X main.version=$(git describe --always --dirty --tags)"
//
// (see scripts/build-linux.sh). Defaults to "dev" for local `go run`.
var version = "dev"

func main() {
	configPath := flag.String("config", "gateway.yaml", "path to gateway YAML config")
	checkOnly := flag.Bool("check", false, "load config, migrate storage, then exit")
	showVersion := flag.Bool("version", false, "print build version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}

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

	// M2-4 / PERF-4: open a SECOND handle in read-only mode for the
	// explorer + /v1/usage GET-only handlers. The primary handle is
	// SetMaxOpenConns(1) so BEGIN IMMEDIATE writes serialize cleanly,
	// but that also means a slow explorer query stalls ReserveQuota
	// on the money path. The read handle is conn cap 4 and runs against
	// the same WAL file, so reads compose with writes without contention.
	readStore, err := sqlite.OpenReadOnly(ctx, cfg.Storage.DBPath)
	if err != nil {
		slog.Error("open read-only storage failed", "path", cfg.Storage.DBPath, "error", err)
		os.Exit(1)
	}
	defer func() {
		if err := readStore.Close(); err != nil {
			slog.Warn("close read-only storage failed", "error", err)
		}
	}()

	slog.Info("gateway initialized", "address", cfg.Address(), "db_path", cfg.Storage.DBPath)
	if *checkOnly {
		return
	}

	go runReservationReaper(ctx, store, time.Duration(cfg.Quotas.ReaperIntervalHours)*time.Hour)

	// coordinatorTransport clones the default transport and adds
	// ResponseHeaderTimeout so buyers get a bounded failure if the coordinator
	// holds the connection without sending headers. This timeout must be at
	// least as long as coordinator_request_seconds — neither non-streaming
	// (full-buffer) nor streaming (post-#92: first commit-worthy SSE event)
	// coordinator responses commit headers earlier than provider work
	// completion. A 60s default pre-#92 silently failed any non-streaming
	// inference > 60s and now any streaming inference whose first valid event
	// took > 60s; the new 300s default tracks the full request budget.
	coordinatorTransport := http.DefaultTransport.(*http.Transport).Clone()
	coordinatorTransport.ResponseHeaderTimeout = cfg.CoordinatorHeaderTimeout()
	coordinatorClient := &http.Client{
		Timeout:   cfg.CoordinatorTimeout(),
		Transport: coordinatorTransport,
	}
	oauthClient := &http.Client{Timeout: 30 * time.Second}
	oauth := auth.NewGitHubProvider(cfg.Auth.OAuth.GitHub, oauthClient)
	gatewayRouter := router.New(cfg, store, oauth,
		router.WithHTTPClient(coordinatorClient),
		router.WithVersion(version),
		router.WithReadStore(readStore),
	)
	if cfg.Settlement.ReconcileEnabled {
		go runSettlementReconciler(ctx, gatewayRouter,
			time.Duration(cfg.Settlement.ReconcileIntervalSeconds)*time.Second,
			cfg.Settlement.ReconcileBatchLimit,
			time.Duration(cfg.Settlement.ReconcileRequestTimeoutSeconds)*time.Second,
		)
	}
	httpServer := newHTTPServer(cfg.Address(), gatewayRouter.Handler())
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

func newHTTPServer(addr string, handler http.Handler) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
}

type settlementReconciler interface {
	ReconcileSettlementHolds(context.Context, int) (router.SettlementReconcileSummary, error)
}

func runSettlementReconciler(ctx context.Context, reconciler settlementReconciler, interval time.Duration, limit int, requestTimeout time.Duration) {
	if interval <= 0 {
		interval = 30 * time.Second
	}
	if limit <= 0 {
		limit = 100
	}
	if requestTimeout <= 0 {
		requestTimeout = 10 * time.Second
	}
	reconcile := func() {
		runCtx, cancel := context.WithTimeout(ctx, requestTimeout)
		defer cancel()
		summary, err := reconciler.ReconcileSettlementHolds(runCtx, limit)
		if err != nil {
			slog.Warn("SPEC-022 settlement reconciler failed", "error", err)
			return
		}
		if summary.Scanned > 0 || summary.Errors > 0 {
			slog.Info("SPEC-022 settlement reconciler completed",
				"scanned", summary.Scanned,
				"verified", summary.Verified,
				"refunded", summary.Refunded,
				"held", summary.Held,
				"skipped", summary.Skipped,
				"errors", summary.Errors,
				"coordinator_404", summary.Coordinator404,
			)
		}
	}
	reconcile()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			reconcile()
		}
	}
}

// terminalReservationRetention is the threshold below which terminal-state
// quota_reservations rows carry no audit value (the usage_events row is
// the durable record) — M2-4 / PERF-1 Part B.
const terminalReservationRetention = 7 * 24 * time.Hour

type reservationReaper interface {
	ReapExpiredReservations(context.Context, time.Time) (int64, error)
	DeleteTerminalQuotaReservations(context.Context, time.Time) (int64, error)
}

func runReservationReaper(ctx context.Context, store reservationReaper, interval time.Duration) {
	if interval <= 0 {
		interval = time.Hour
	}
	reap := func() {
		now := time.Now().UTC()
		n, err := store.ReapExpiredReservations(ctx, now)
		if err != nil {
			slog.Warn("quota reservation reaper failed", "error", err)
		} else if n > 0 {
			slog.Info("expired quota reservations reaped", "count", n)
		}
		// M2-4 / PERF-1 Part B: after marking expired, prune terminal-state
		// rows past the retention window. concurrency_reservations has an
		// append-only trigger; only quota_reservations is touched here.
		deleted, err := store.DeleteTerminalQuotaReservations(ctx, now.Add(-terminalReservationRetention))
		if err != nil {
			slog.Warn("quota reservation terminal-prune failed", "error", err)
		} else if deleted > 0 {
			slog.Info("terminal quota reservations pruned", "count", deleted, "retention_hours", int(terminalReservationRetention.Hours()))
		}
	}
	reap()
	ticker := time.NewTicker(interval)
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
