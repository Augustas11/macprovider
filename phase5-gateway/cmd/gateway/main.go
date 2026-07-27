package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/augstar/macprovider-gateway/internal/auth"
	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/router"
	"github.com/augstar/macprovider-gateway/internal/settlement/journal"
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

	// #763: open the durable settlement journal next to the database it
	// protects. FAIL-CLOSED: a gateway that cannot journal cannot recover a
	// dropped settlement, and a silently-disabled journal is exactly the
	// hole the router's discard implementation would create.
	settlementJournal, err := openSettlementJournal(cfg)
	if err != nil {
		slog.Error("open settlement journal failed", "dir", cfg.SettlementJournalDir(), "error", err)
		os.Exit(1)
	}
	defer func() {
		if err := settlementJournal.Close(); err != nil {
			slog.Warn("close settlement journal failed", "error", err)
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
	slog.Info("gateway oauth", "github_oauth", cfg.Auth.GitHubOAuthEnabled)
	if *checkOnly {
		return
	}

	go runReservationReaper(ctx, store, time.Duration(cfg.Quotas.ReaperIntervalHours)*time.Hour)
	go runOAuthStatePruner(ctx, store, time.Minute)

	coordinatorClient := newCoordinatorClient(cfg)
	oauthClient := &http.Client{Timeout: 30 * time.Second}
	oauth := auth.NewGitHubProvider(cfg.Auth.OAuth.GitHub, oauthClient)
	gatewayRouter := newGatewayRouter(cfg, store, readStore, oauth, coordinatorClient, settlementJournal)
	// #763: drain whatever the previous process left unsealed BEFORE
	// listening, then keep draining on a ticker. Startup alone is not
	// enough — the H7 failure is a logical double-failure inside a running
	// process, which nothing would ever restart the gateway to fix.
	if cfg.Settlement.JournalEnabled {
		recoverCtx, cancel := context.WithTimeout(ctx, settlementJournalRecoveryTimeout)
		summary, err := gatewayRouter.RecoverSettlementJournal(recoverCtx, cfg.Settlement.JournalRecoveryBatchLimit)
		cancel()
		if err != nil {
			// CRITICAL but not fatal: refusing to serve because recovery
			// failed would turn a recoverable billing gap into an outage.
			slog.Error("CRITICAL gateway settlement journal startup recovery failed; serving anyway",
				"error", err)
		} else if summary.Scanned > 0 || summary.Unsealed > 0 || summary.Malformed > 0 {
			slog.Info("gateway settlement journal startup recovery completed",
				"scanned", summary.Scanned,
				"recovered", summary.Recovered,
				"quarantined", summary.Quarantined,
				"skipped", summary.Skipped,
				"errors", summary.Errors,
				"unsealed", summary.Unsealed,
				"malformed", summary.Malformed,
			)
		}
		go runSettlementJournalRecovery(ctx, gatewayRouter,
			time.Duration(cfg.Settlement.JournalRecoveryIntervalSeconds)*time.Second,
			cfg.Settlement.JournalRecoveryBatchLimit,
			settlementJournalRecoveryTimeout,
		)
	}
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

// newCoordinatorClient builds the coordinator-facing HTTP client.
//
// Client.Timeout is deliberately ZERO. Pre-#760 it was
// coordinator_request_seconds, which made it a SECOND flat wall — one that
// covers body reads, so it cut a healthy streaming generation at 300s no
// matter what the request context allowed. The router's per-phase deadlines
// (internal/router/request_deadlines.go) are the only request-level clock now;
// leaving Client.Timeout set would silently override them and make the
// decomposition a production no-op (the router tests inject a Timeout-less
// client, so they cannot see this wall — hence this function exists to be
// tested directly).
//
// The transport keeps two bounded budgets:
//   - dial + TLS handshake = coordinator_connect_seconds. A hung TCP/TLS
//     handshake is never legitimate work, so it fails fast.
//   - ResponseHeaderTimeout = coordinator_header_timeout_seconds, UNCHANGED.
//     It must NOT be lowered to the connect budget: neither non-streaming
//     (full-buffer) nor streaming (post-#92: first commit-worthy SSE event)
//     coordinator responses commit headers before provider work completes,
//     and shortening it reintroduces the #92 / #171 regression where a
//     slow-but-valid inference false-failed as coordinator_unavailable.
func newCoordinatorClient(cfg config.Config) *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.ResponseHeaderTimeout = cfg.CoordinatorHeaderTimeout()
	connect := cfg.CoordinatorConnectTimeout()
	transport.DialContext = (&net.Dialer{Timeout: connect, KeepAlive: 30 * time.Second}).DialContext
	transport.TLSHandshakeTimeout = connect
	return &http.Client{Timeout: 0, Transport: transport}
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

// openSettlementJournal builds the real #763 journal from config. It is a
// named function so TestOpenSettlementJournal* can drive the same code path
// production does (the wiring, not a re-implementation of it).
func openSettlementJournal(cfg config.Config) (*journal.Journal, error) {
	return journal.Open(journal.Options{
		Dir:             cfg.SettlementJournalDir(),
		Fsync:           cfg.Settlement.JournalFsync,
		SegmentMaxBytes: cfg.Settlement.JournalSegmentMaxBytes,
		MaxTotalBytes:   cfg.Settlement.JournalMaxTotalBytes,
	})
}

// newGatewayRouter assembles the production router. Extracted from main so
// TestGatewayRouterCarriesSettlementJournal can assert that the real journal
// actually reaches the Server — a nil/discard journal here would disable
// settlement durability with no other visible symptom.
func newGatewayRouter(
	cfg config.Config,
	store router.Store,
	readStore router.ReadStore,
	oauth auth.OAuthProvider,
	coordinatorClient *http.Client,
	settlementJournal router.SettlementJournal,
) *router.Server {
	return router.New(cfg, store, oauth,
		router.WithHTTPClient(coordinatorClient),
		router.WithVersion(version),
		router.WithReadStore(readStore),
		router.WithSettlementJournal(settlementJournal),
	)
}

// settlementJournalRecoveryTimeout bounds one recovery pass (startup and
// periodic alike). Recovery shares the store's single write connection with
// the money path, so a pass that cannot finish promptly must yield rather
// than hold the connection.
const settlementJournalRecoveryTimeout = 30 * time.Second

type settlementJournalRecoverer interface {
	RecoverSettlementJournal(context.Context, int) (router.SettlementJournalRecoverySummary, error)
}

// runSettlementJournalRecovery is modeled on runSettlementReconciler but is a
// SEPARATE loop on purpose: the SPEC-022 reconciler round-trips the
// coordinator for reservations that are still held, while this pass only
// re-drives locally journaled effects — different failure modes, different
// cadence, and folding them together would make one stall the other.
func runSettlementJournalRecovery(ctx context.Context, recoverer settlementJournalRecoverer, interval time.Duration, limit int, requestTimeout time.Duration) {
	if interval <= 0 {
		interval = 30 * time.Second
	}
	if limit <= 0 {
		limit = 100
	}
	if requestTimeout <= 0 {
		requestTimeout = settlementJournalRecoveryTimeout
	}
	recoverPass := func() {
		runCtx, cancel := context.WithTimeout(ctx, requestTimeout)
		defer cancel()
		summary, err := recoverer.RecoverSettlementJournal(runCtx, limit)
		if err != nil {
			slog.Warn("gateway settlement journal recovery failed", "error", err)
			return
		}
		if summary.Scanned > 0 || summary.Errors > 0 || summary.Quarantined > 0 {
			slog.Info("gateway settlement journal recovery completed",
				"scanned", summary.Scanned,
				"recovered", summary.Recovered,
				"settled", summary.Settled,
				"usage_events", summary.UsageEvents,
				"quarantined", summary.Quarantined,
				"retried", summary.Retried,
				"skipped", summary.Skipped,
				"errors", summary.Errors,
				"pruned", summary.Pruned,
			)
		}
	}
	recoverPass()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			recoverPass()
		}
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

type oauthStatePruner interface {
	PruneExpiredOAuthState(context.Context, time.Time) (int64, error)
	PruneExpiredOAuthHandoffs(context.Context, time.Time) (int64, error)
}

// runOAuthStatePruner deletes expired oauth_states AND expired oauth_handoffs
// rows on a fixed cadence. Both tables are populated by /auth/github/*
// traffic and grow unbounded without this loop; handoffs additionally hold
// the recently-minted API key until consumed, so timely cleanup limits how
// long an unclaimed key sits in the DB after its 5-minute validity window.
func runOAuthStatePruner(ctx context.Context, store oauthStatePruner, interval time.Duration) {
	if interval <= 0 {
		interval = time.Minute
	}
	prune := func() {
		now := time.Now().UTC()
		if deleted, err := store.PruneExpiredOAuthState(ctx, now); err != nil {
			slog.Warn("oauth state prune failed", "error", err)
		} else if deleted > 0 {
			slog.Info("expired oauth states pruned", "count", deleted)
		}
		if deleted, err := store.PruneExpiredOAuthHandoffs(ctx, now); err != nil {
			slog.Warn("oauth handoff prune failed", "error", err)
		} else if deleted > 0 {
			slog.Info("expired oauth handoffs pruned", "count", deleted)
		}
	}
	prune()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			prune()
		}
	}
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
