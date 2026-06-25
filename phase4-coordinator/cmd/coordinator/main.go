package main

import (
	"context"
	"database/sql"
	"encoding/hex"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/audit"
	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/explorer"
	"github.com/augstar/macprovider-coordinator/internal/payout"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/providerhttp"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// version is overridden at build time via
//
//	go build -ldflags "-X main.version=$(git describe --always --dirty --tags)"
//
// (see scripts/build-linux.sh). Defaults to "dev" for local `go run`.
var version = "dev"

func main() {
	configPath := flag.String("config", "coordinator.yaml", "path to coordinator YAML config")
	showVersion := flag.Bool("version", false, "print build version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}

	cfg, err := config.Load(*configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "config: %v\n", err)
		os.Exit(1)
	}
	providerhttp.Init(cfg.ProviderHTTP.TimeoutS)

	logger := zerolog.New(os.Stdout).With().Timestamp().Logger()
	if err := tier2.Configure(cfg.Tier2, logger); err != nil {
		fmt.Fprintf(os.Stderr, "tier2: %v\n", err)
		os.Exit(1)
	}
	registry := pool.NewRegistry(cfg.Providers)
	startedAt := time.Now().UTC()
	tokenStore, err := auth.OpenStore(cfg.Storage.DBPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "storage: %v\n", err)
		os.Exit(1)
	}
	defer tokenStore.Close()
	reqLogStore, err := requestlog.OpenStore(cfg.Storage.DBPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "requestlog: %v\n", err)
		os.Exit(1)
	}
	defer reqLogStore.Close()
	canaryStore, err := setupCanarySanctionStore(context.Background(), cfg, reqLogStore.DB(), registry)
	if err != nil {
		fmt.Fprintf(os.Stderr, "canary sanction storage: %v\n", err)
		os.Exit(1)
	}
	auditStore, err := audit.OpenStore(cfg.Storage.DBPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "audit log storage: %v\n", err)
		os.Exit(1)
	}
	defer auditStore.Close()
	admissionStore, err := providerws.NewSQLiteAdmissionStore(reqLogStore.DB())
	if err != nil {
		fmt.Fprintf(os.Stderr, "admission storage: %v\n", err)
		os.Exit(1)
	}
	billingStore, err := billing.NewStore(reqLogStore.DB())
	if err != nil {
		fmt.Fprintf(os.Stderr, "billing: %v\n", err)
		os.Exit(1)
	}
	snapshotID, err := billingStore.InsertConfigSnapshot(context.Background(), cfg.Rewards, time.Now().UTC())
	if err != nil {
		fmt.Fprintf(os.Stderr, "billing config snapshot: %v\n", err)
		os.Exit(1)
	}
	shutdownCtx, stopBackground := context.WithCancel(context.Background())
	defer stopBackground()
	wsOpts := []providerws.Option{}
	wsOpts = append(wsOpts, providerws.WithVersion(version))
	wsOpts = append(wsOpts, providerws.WithAdmissionStore(admissionStore))
	if canaryStore != nil {
		wsOpts = append(wsOpts, providerws.WithCanarySanctionStore(canaryStore))
	}
	// SPEC-003 v0.8 FR-C9.1 — the token validator is always wired now,
	// even when require_provider_tokens=false, because the same store
	// is the issuance backend for self-serve provisional tokens. Pre-
	// v0.8 the conditional made `s.tokens != nil` mean "enforce
	// strictly"; v0.8 separates issuance from enforcement so the store
	// is always available for FR-C9.1 mint-on-first-admit even during
	// the settling window before the operator flips the flag.
	wsOpts = append(wsOpts, providerws.WithTokenValidator(tokenStore))
	// SPEC-003 v0.8 FR-C9.1/FR-C9.4 — separate TokenIssuer wiring for
	// minting + TOFU. Same concrete store today; the split is at the
	// interface layer (codex architect review on PR #44, interface
	// segregation MINOR).
	wsOpts = append(wsOpts, providerws.WithTokenIssuer(tokenStore))
	wsOpts = append(wsOpts, providerws.WithGitHubAuthStore(tokenStore))
	if cfg.Auth.RequireProviderTokens {
		logger.Info().
			Bool("allow_tokenless_provisional_bootstrap", cfg.Auth.AllowTokenlessProvisionalBootstrap).
			Msg("provider WS token validation REQUIRED (auth.require_provider_tokens=true)")
	} else {
		logger.Info().Msg("provider WS token validation NOT required (auth.require_provider_tokens=false); tokenless provisional admissions will self-mint per SPEC-003 FR-C9")
	}
	if cfg.Explorer.Enabled {
		wsOpts = append(wsOpts, providerws.WithExplorerHandler(explorer.NewHandler(cfg, reqLogStore.DB(), registry, startedAt)))
		logger.Info().Str("path", cfg.Explorer.BindPath).Msg("operator explorer enabled")
	}
	// M2-2 / ARCH-2: hand the pool emitter a non-blocking channel send
	// instead of the synchronous SQLite write. The pool already releases
	// Registry.mu before invoking the emitter (see ApplyHeartbeat), and
	// a dedicated drain goroutine performs the EmitSwap write so a
	// SQLite busy_timeout stall (~5s worst case) cannot back-pressure
	// the heartbeat handler. R-7.10.8 best-effort semantics permit
	// dropping on overflow — logged at WARN.
	//
	// Shutdown ordering (code-auditor flagged a race in the close-based
	// design): swapCh is NEVER closed. Both sender (swapEmitter) and
	// receiver (drain goroutine) coordinate via shutdownCtx.Done() so
	// late heartbeats arriving after shutdown can never panic on
	// send-on-closed-channel. Late events accumulate in the cap-64
	// buffer until full, then drop with a WARN.
	swapCh := make(chan pool.SwapEvent, 64)
	swapDrained := make(chan struct{})
	receiptRotationCh := make(chan pool.ReceiptRotationEvent, 64)
	receiptRotationDrained := make(chan struct{})
	logSwapAuditFailure := func(event pool.SwapEvent, err error) {
		loadingWindowMS := int64(0)
		if !event.LoadingStartedAt.IsZero() {
			loadingWindowMS = event.CompletedAt.Sub(event.LoadingStartedAt).Milliseconds()
		}
		logger.Warn().
			Err(err).
			Str("provider_id", event.ProviderID).
			Str("assigned_id", event.AssignedID).
			Str("from_model_id", event.FromModelID).
			Str("to_model_id", event.ToModelID).
			Str("to_model_hash", event.ToModelHash).
			Int64("loading_window_ms", loadingWindowMS).
			Str("hash_verification_result", string(event.HashVerificationResult)).
			Msg("operator_model_swap audit write failed")
	}
	go func() {
		defer close(swapDrained)
		for {
			select {
			case <-shutdownCtx.Done():
				// Drain any remaining buffered events (best-effort) and
				// return. New sends after this point hit swapEmitter's
				// own shutdownCtx guard and become silent drops.
				for {
					select {
					case event := <-swapCh:
						if err := auditStore.EmitSwap(context.Background(), event); err != nil {
							logSwapAuditFailure(event, err)
						}
					default:
						return
					}
				}
			case event := <-swapCh:
				// Use a fresh background context here so a slow audit
				// write near shutdown isn't truncated by ctx cancellation
				// — the event was already accepted into the queue.
				if err := auditStore.EmitSwap(context.Background(), event); err != nil {
					logSwapAuditFailure(event, err)
				}
			}
		}
	}()
	logReceiptRotationAuditFailure := func(event pool.ReceiptRotationEvent, err error) {
		logger.Warn().
			Err(err).
			Str("provider_id", event.ProviderID).
			Time("rotated_at", event.RotatedAt).
			Msg("receipt_rotation_detected audit write failed")
	}
	go func() {
		defer close(receiptRotationDrained)
		for {
			select {
			case <-shutdownCtx.Done():
				for {
					select {
					case event := <-receiptRotationCh:
						if err := auditStore.EmitReceiptRotation(context.Background(), event); err != nil {
							logReceiptRotationAuditFailure(event, err)
						}
					default:
						return
					}
				}
			case event := <-receiptRotationCh:
				if err := auditStore.EmitReceiptRotation(context.Background(), event); err != nil {
					logReceiptRotationAuditFailure(event, err)
				}
			}
		}
	}()
	logSwapDropped := func(event pool.SwapEvent, reason string) {
		// Symmetry with logSwapAuditFailure: a dropped event must be
		// reconstructable from the log line. Include the same identity
		// fields plus loading_window_ms so an auditor can confirm what
		// was lost.
		loadingWindowMS := int64(0)
		if !event.LoadingStartedAt.IsZero() {
			loadingWindowMS = event.CompletedAt.Sub(event.LoadingStartedAt).Milliseconds()
		}
		logger.Warn().
			Str("reason", reason).
			Str("provider_id", event.ProviderID).
			Str("assigned_id", event.AssignedID).
			Str("from_model_id", event.FromModelID).
			Str("from_model_hash", event.FromModelHash).
			Str("to_model_id", event.ToModelID).
			Str("to_model_hash", event.ToModelHash).
			Int64("loading_window_ms", loadingWindowMS).
			Str("hash_verification_result", string(event.HashVerificationResult)).
			Msg("operator_model_swap event dropped (best-effort per R-7.10.8)")
	}
	swapEmitter := func(event pool.SwapEvent) {
		// shutdownCtx.Done() check ordering: select picks randomly when
		// multiple cases are ready, so we can't both rely on it AND let
		// the buffered send race it. The double-check is cheap and the
		// inner select handles steady-state.
		if shutdownCtx.Err() != nil {
			logSwapDropped(event, "shutdown")
			return
		}
		select {
		case swapCh <- event:
		default:
			logSwapDropped(event, "queue_full_cap_64")
		}
	}
	receiptRotationEmitter := func(event pool.ReceiptRotationEvent) {
		if shutdownCtx.Err() != nil {
			logger.Warn().Str("provider_id", event.ProviderID).Str("reason", "shutdown").Msg("receipt_rotation_detected event dropped")
			return
		}
		select {
		case receiptRotationCh <- event:
		default:
			logger.Warn().Str("provider_id", event.ProviderID).Str("reason", "queue_full_cap_64").Msg("receipt_rotation_detected event dropped")
		}
	}
	wsOpts = append(wsOpts, providerws.WithRegistryOptions(
		pool.WithSwapEmitter(swapEmitter),
		pool.WithReceiptRotationEmitter(receiptRotationEmitter),
	))
	wsServer := providerws.NewServer(cfg, registry, logger, wsOpts...)
	buyerServer := buyer.NewServer(
		registry,
		logger,
		startedAt,
		buyer.WithVersion(version),
		buyer.WithPreflightConfig(cfg.Routing.PreflightThresholdTokens, time.Duration(cfg.Routing.PreflightTimeoutS)*time.Second),
		buyer.WithRecoveryConfig(time.Duration(cfg.Pool.DegradedBackoffS)*time.Second, cfg.Pool.DegradedMaxRetries, cfg.Pool.DegradedProbeAfter502),
		buyer.WithBreakerConfig(cfg.Pool.BreakerFailureThreshold, time.Duration(cfg.Pool.BreakerWindowS)*time.Second),
		buyer.WithFailoverConfig(cfg.Routing.FailoverEnabled, time.Duration(cfg.Routing.FailoverTimeoutS)*time.Second),
		buyer.WithRoutingConfig(cfg.Routing),
		buyer.WithTier2Config(cfg.Tier2),
		buyer.WithLimitsConfig(cfg.Limits),
		buyer.WithInternalAuthKey(cfg.Auth.OperatorKey),
		buyer.WithGatewayServiceToken(cfg.Auth.GatewayServiceToken),
		buyer.WithRelay(wsServer.DispatchInference, time.Duration(cfg.Routing.RequestTimeoutS)*time.Second),
		buyer.WithAdmission(wsServer.Admission(), cfg.Admission.ProvisionalTierWeight),
		buyer.WithRequestLog(reqLogStore),
		buyer.WithBilling(billingStore, cfg.Rewards),
		buyer.WithBillingSnapshotID(snapshotID),
		buyer.WithPreflight(func(provider pool.Provider, requestID string, estimatedTokens int, timeout time.Duration) (buyer.PreflightResult, bool, error) {
			ack, ok, err := wsServer.Preflight(provider, requestID, estimatedTokens, timeout)
			return buyer.PreflightResult{Accepted: ack.Accepted, Reason: ack.Reason}, ok, err
		}),
	)
	providerAddr := fmt.Sprintf("%s:%d", cfg.Listen.BindAddress, cfg.Listen.ProviderPort)
	buyerAddr := fmt.Sprintf("%s:%d", cfg.Listen.BindAddress, cfg.Listen.BuyerPort)
	providerMux := http.NewServeMux()
	providerMux.Handle("/", wsServer.Handler())
	providerMux.Handle("/internal/", buyerServer.InternalHandler())
	billingHandler := billingStore.HandlersWithBridge(
		cfg.Auth.OperatorKey,
		cfg.Auth.GatewayServiceToken,
		tokenStore,
		cfg.Auth.RequireProviderTokens,
		cfg.Endpoints.ProviderEarnings.RateLimitPerMinute,
	)
	providerMux.Handle("/admin/ledger/", billingHandler)

	// SPEC-016 §4.1 — wire the payout package. Migrations + asserts
	// run unconditionally so a future flip of payout.enabled does
	// not require a schema migration window; the §3.3 handler is
	// only mounted on the listener when payout.enabled is true.
	// Adapt billingStore to the payout.PayoutClaimer interface — the
	// concrete ClaimPayoutReady method satisfies it without modification.
	payoutAddresses, payoutMuxHandler, payoutS2, err := setupPayout(context.Background(), reqLogStore.DB(), cfg, tokenStore, billingStore, billingHandler, logger)
	if err != nil {
		fmt.Fprintf(os.Stderr, "payout: %v\n", err)
		os.Exit(1)
	}
	_ = payoutAddresses // satisfies billing.PayoutAddressReader (used by Step 4 reconcile)
	if cfg.Auth.RequireProviderTokens {
		if payoutMuxHandler != nil {
			// Mount payout mux at BOTH /providers/ (for §3.3) and
			// /admin/payout/ (for §4.6 abandon + §4.2 run-now).
			// Per architect r1 [arch:3.2]: a single /providers/ mount
			// makes /admin/payout/* unreachable; mounting at both
			// roots lets chi route to the right handler.
			providerMux.Handle("/providers/", payoutMuxHandler)
			providerMux.Handle("/admin/payout/", payoutMuxHandler)
		} else {
			providerMux.Handle("/providers/", billingHandler)
		}
	}
	// Start the runner lifecycle if Step 2 is wired.
	if payoutS2 != nil {
		payoutS2.runner.Start(shutdownCtx)
		startPayoutReorgPoller(shutdownCtx, payoutS2.reorg, cfg.Payout.Tuning.RunInterval, logger)
		// Step 3 §4.8a + §4.8c reaper.
		if payoutS2.reaper != nil {
			payoutS2.reaper.Start(shutdownCtx)
		}
	}
	providerHTTP := newHTTPServer(providerAddr, providerMux)
	buyerHTTP := newHTTPServer(buyerAddr, buyerServer.Handler())
	errs := make(chan error, 2)

	if err := billingStore.StartStartupScan(context.Background(), cfg.Settlement, time.Now().UTC()); err != nil {
		logger.Warn().Err(err).Msg("billing startup scan failed")
	}
	billingStore.StartNightlyReconcile(shutdownCtx, cfg.Settlement)
	billingStore.StartWeeklySettlement(shutdownCtx, cfg.Settlement)
	startRequestLogRetentionPruner(shutdownCtx, reqLogStore, cfg.Storage.RequestLogRetentionDays, logger)
	startAuditLogRetentionPruner(shutdownCtx, auditStore, cfg.Storage.AuditLogRetentionDays, logger)
	startAdmissionRetentionPruner(shutdownCtx, wsServer.Admission(), cfg.Admission.ProvisionalRetentionDays, logger)
	startGitHubAuthStatePruner(shutdownCtx, tokenStore, logger)
	startPayoutNoncePruner(shutdownCtx, payoutAddresses, logger)

	go func() {
		logger.Info().Str("addr", providerAddr).Msg("provider websocket server listening")
		errs <- providerHTTP.ListenAndServe()
	}()
	go func() {
		logger.Info().Str("addr", buyerAddr).Msg("buyer http server listening")
		errs <- buyerHTTP.ListenAndServe()
	}()

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	for {
		select {
		case sig := <-signals:
			if sig == syscall.SIGHUP {
				reloadTier2Config(*configPath, cfg.Tier2, logger, wsServer, buyerServer, billingStore)
				continue
			}
			timeout := 30 * time.Second
			if sig == syscall.SIGINT {
				timeout = 5 * time.Second
			}
			logger.Info().Str("signal", sig.String()).Dur("timeout", timeout).Msg("coordinator shutdown requested")
			stopBackground()
			// Stop the payout runner BEFORE WS drain so any
			// in-flight §4.3 cycle finishes cleanly and the lease
			// is released (next process can re-acquire without
			// waiting the stale window per §4.8b).
			if payoutS2 != nil {
				stopCtx, stopCancel := context.WithTimeout(context.Background(), timeout)
				payoutS2.stop(stopCtx)
				stopCancel()
			}
			wsServer.DrainAll("coordinator shutdown")
			ctx, cancel := context.WithTimeout(context.Background(), timeout)
			defer cancel()
			if err := buyerHTTP.Shutdown(ctx); err != nil {
				logger.Error().Err(err).Msg("buyer http shutdown failed")
				os.Exit(1)
			}
			if err := providerHTTP.Shutdown(ctx); err != nil {
				logger.Error().Err(err).Msg("provider http shutdown failed")
				os.Exit(1)
			}
			// M2-2: wait for the swap-audit drain goroutine to finish so
			// the last few model swaps are persisted. The drain goroutine
			// exits on shutdownCtx.Done() (already cancelled by
			// stopBackground above) after flushing any buffered events.
			// We deliberately do NOT close(swapCh): a late heartbeat that
			// arrives while DrainAll is still tearing down WS handlers
			// could otherwise panic with send-on-closed-channel (the
			// 2026-06-11 code-audit caught this). The sender's emitter
			// has its own shutdownCtx guard so late sends drop silently
			// with a WARN.
			select {
			case <-swapDrained:
			case <-ctx.Done():
				logger.Warn().Msg("swap audit drain timed out at shutdown")
			}
			select {
			case <-receiptRotationDrained:
			case <-ctx.Done():
				logger.Warn().Msg("receipt rotation audit drain timed out at shutdown")
			}
			logger.Info().Msg("coordinator shutdown complete")
			return
		case err := <-errs:
			if err != nil && err != http.ErrServerClosed {
				logger.Fatal().Err(err).Msg("coordinator server stopped")
			}
			return
		}
	}
}

type requestLogPruner interface {
	PruneBefore(context.Context, time.Time) (int64, error)
}

func setupCanarySanctionStore(ctx context.Context, cfg config.Config, db *sql.DB, registry *pool.Registry) (providerws.CanarySanctionStore, error) {
	if !cfg.Pool.CanaryEnabled {
		return nil, nil
	}
	store, err := providerws.NewSQLiteCanarySanctionStore(db)
	if err != nil {
		return nil, err
	}
	canarySanctions, err := store.LoadCanarySanctions(ctx)
	if err != nil {
		return nil, fmt.Errorf("load canary sanctions: %w", err)
	}
	registry.LoadCanarySanctions(canarySanctions)
	return store, nil
}

func startRequestLogRetentionPruner(ctx context.Context, store requestLogPruner, retentionDays int, logger zerolog.Logger) {
	if store == nil || retentionDays <= 0 {
		return
	}
	prune := func() {
		cutoff := time.Now().UTC().AddDate(0, 0, -retentionDays)
		deleted, err := store.PruneBefore(ctx, cutoff)
		if err != nil {
			logger.Warn().Err(err).Time("cutoff", cutoff).Msg("request_log retention prune failed")
			return
		}
		if deleted > 0 {
			logger.Info().Int64("deleted_rows", deleted).Time("cutoff", cutoff).Msg("request_log retention pruned rows")
		}
	}
	prune()
	go func() {
		ticker := time.NewTicker(24 * time.Hour)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				prune()
			}
		}
	}()
}

// admissionPruner is the interface satisfied by *ws.AdmissionManager.Prune.
// Kept narrow so tests can substitute a stub.
type admissionPruner interface {
	Prune(cutoff time.Time) (deletedRecords, deletedRejected, deletedTimePoints int)
}

// startAdmissionRetentionPruner wires ProvisionalRetentionDays
// (coordinator.yaml admission.provisional_retention_days, default 30)
// into the daily retention loop. M2-5 / XPERF-2: the config knob existed
// since SPEC-003 but no code path consumed it.
func startAdmissionRetentionPruner(ctx context.Context, mgr admissionPruner, retentionDays int, logger zerolog.Logger) {
	if mgr == nil || retentionDays <= 0 {
		return
	}
	prune := func() {
		cutoff := time.Now().UTC().AddDate(0, 0, -retentionDays)
		records, rejected, timePoints := mgr.Prune(cutoff)
		if records > 0 || rejected > 0 || timePoints > 0 {
			logger.Info().
				Int("deleted_records", records).
				Int("deleted_rejected", rejected).
				Int("deleted_time_points", timePoints).
				Time("cutoff", cutoff).
				Msg("admission state retention pruned")
		}
	}
	prune()
	nextRun := time.Now().UTC().Add(24 * time.Hour)
	logger.Info().Time("next_prune_at", nextRun).Int("retention_days", retentionDays).Msg("admission state retention pruner armed")
	go func() {
		ticker := time.NewTicker(24 * time.Hour)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				prune()
			}
		}
	}()
}

type githubAuthStatePruner interface {
	PruneGitHubAuthState(context.Context, time.Time) error
}

func startGitHubAuthStatePruner(ctx context.Context, store githubAuthStatePruner, logger zerolog.Logger) {
	if store == nil {
		return
	}
	prune := func() {
		now := time.Now().UTC()
		if err := store.PruneGitHubAuthState(ctx, now); err != nil {
			logger.Warn().Err(err).Msg("github auth state prune failed")
		}
	}
	prune()
	logger.Info().Time("next_prune_at", time.Now().UTC().Add(time.Hour)).Msg("github auth state pruner armed")
	go func() {
		ticker := time.NewTicker(time.Hour)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				prune()
			}
		}
	}()
}

func startAuditLogRetentionPruner(ctx context.Context, store requestLogPruner, retentionDays int, logger zerolog.Logger) {
	if store == nil || retentionDays <= 0 {
		return
	}
	prune := func() {
		cutoff := time.Now().UTC().AddDate(0, 0, -retentionDays)
		deleted, err := store.PruneBefore(ctx, cutoff)
		if err != nil {
			logger.Warn().Err(err).Time("cutoff", cutoff).Msg("audit_log retention prune failed")
			return
		}
		if deleted > 0 {
			logger.Info().Int64("deleted_rows", deleted).Time("cutoff", cutoff).Msg("audit_log retention pruned rows")
		}
	}
	prune()
	go func() {
		ticker := time.NewTicker(24 * time.Hour)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				prune()
			}
		}
	}()
}

// setupPayout runs SPEC-016 §4.1 / §4.8 / §4.8a startup
// invariants — apply migrations, assert PRAGMAs and same-DB
// pin, INSERT OR IGNORE the payout_runner_state row, bootstrap-
// seed runtime_flags (gated by the three-table empty check),
// assert trigger presence, and return an AddressesService
// satisfying billing.PayoutAddressReader plus an http.Handler
// for the §3.3 endpoint.
//
// When payout.enabled = false the migrations + asserts still
// run (so the schema is ready) but the returned http.Handler
// is nil and the runner does not start. This matches SPEC-016
// §0 "design-only" disposition at v0.1.x.
// payoutStep2 bundles the Step 2 components so main.go can run
// the runner lifecycle alongside the existing shutdown ordering.
// Step 3 extends it with the §4.8a + §4.7 reaper.
type payoutStep2 struct {
	runner *payout.Runner
	reorg  *payout.ReorgPoller
	state  payout.LeaseState
	reaper *payout.Reaper       // Step 3 §4.8a + §4.8c outbox reaper
	stop   func(context.Context) // calls runner.Stop, reaper.Stop, then Release
}

func setupPayout(ctx context.Context, db *sql.DB, cfg config.Config, tokenStore *auth.Store, claimer payout.PayoutClaimer, billingFallback http.Handler, logger zerolog.Logger) (*payout.AddressesService, http.Handler, *payoutStep2, error) {
	if db == nil {
		return nil, nil, nil, fmt.Errorf("db is required")
	}
	if err := payout.Migrate(ctx, db); err != nil {
		return nil, nil, nil, fmt.Errorf("migrate: %w", err)
	}
	if err := payout.AssertPragmas(ctx, db); err != nil {
		return nil, nil, nil, fmt.Errorf("assert pragmas: %w", err)
	}
	if err := payout.AssertSameDB(ctx, db); err != nil {
		return nil, nil, nil, fmt.Errorf("assert same-db: %w", err)
	}
	now := time.Now().UTC()
	if err := payout.InitRunnerStateRow(ctx, db, now); err != nil {
		return nil, nil, nil, fmt.Errorf("init runner_state: %w", err)
	}
	if err := payout.BootstrapRuntimeFlags(ctx, db, now, logger); err != nil {
		// payout_invariant_violation already emitted by
		// BootstrapRuntimeFlags. HALT before listeners come up.
		return nil, nil, nil, fmt.Errorf("bootstrap runtime_flags: %w", err)
	}
	if err := payout.AssertTriggersPresent(ctx, db); err != nil {
		return nil, nil, nil, fmt.Errorf("assert triggers: %w", err)
	}
	if !cfg.Payout.Enabled {
		logger.Info().Msg("payout pipeline disabled (payout.enabled=false); schema applied, handlers idle")
		return nil, nil, nil, nil
	}
	sec, err := payout.LoadSecurityConfig(cfg.Payout.Security.HotWalletAddress)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("load security config: %w", err)
	}
	// SPEC §3.3 co-residency invariant — assert BEFORE building
	// any service so a misconfigured deployment fails fast at
	// startup, not on the first request. Step 2 tightens to
	// require RunnerCoResident=true.
	if err := payout.AssertPayoutRuntimeTopology(payout.PayoutRuntimeTopology{
		HandlerEnabled:         true,
		RunnerCoResident:       true,
		HotWalletAddressPinned: sec.HotWalletAddress,
		LinuxRequired:          false, // Step 4 will flip this true in production deploys
	}); err != nil {
		return nil, nil, nil, fmt.Errorf("payout topology: %w", err)
	}

	// Load signer. Production path = LoadLocalFileSigner against
	// the systemd-LoadCredential= KEK + the encrypted wallet file.
	// Dev path requires explicit payout.security.dev_mode=true
	// AND MACPROVIDER_PAYOUT_WALLET_KEY_HEX_DEV_ONLY env var.
	signer, err := loadPayoutSigner(cfg.Payout, logger)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("load signer: %w", err)
	}
	if !strings.EqualFold(signer.FromAddress(), sec.HotWalletAddress) {
		return nil, nil, nil, fmt.Errorf("signer address %s != payout.security.hot_wallet_address %s",
			signer.FromAddress(), sec.HotWalletAddress)
	}

	// Two-RPC client + chain id assertion + cold-start nonce sync.
	// SPKI pinning per SPEC §4.4 (Step 2 [arch:3.3] closure).
	rpcs := payout.TwoRPCs{
		Primary:   payout.NewHTTPRPCClient(cfg.Payout.Security.RPCURLPrimary, "primary", cfg.Payout.Tuning.RPCURLPrimaryPinSPKI, 20*time.Second),
		Secondary: payout.NewHTTPRPCClient(cfg.Payout.Security.RPCURLSecondary, "secondary", cfg.Payout.Tuning.RPCURLSecondaryPinSPKI, 20*time.Second),
	}
	rpcCtx, rpcCancel := context.WithTimeout(ctx, 15*time.Second)
	defer rpcCancel()
	if err := rpcs.AssertChainID(rpcCtx, payout.BaseMainnetChainID); err != nil {
		return nil, nil, nil, fmt.Errorf("RPC chain id: %w", err)
	}
	chosen, rpcA, rpcB, within, err := rpcs.ColdStartNonceSync(rpcCtx, sec.HotWalletAddress)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("nonce cold-start: %w", err)
	}
	if within {
		logger.Warn().
			Str("event", "payout_nonce_cold_start_within_tolerance").
			Str("from_address", sec.HotWalletAddress).
			Uint64("rpc_a_nonce", rpcA).
			Uint64("rpc_b_nonce", rpcB).
			Uint64("chosen_nonce", chosen).
			Send()
	}
	if err := payout.UpsertNonceCursor(ctx, db, sec.HotWalletAddress, chosen, rpcA, rpcB, time.Now().UTC().Format(time.RFC3339Nano)); err != nil {
		return nil, nil, nil, fmt.Errorf("UpsertNonceCursor: %w", err)
	}

	if claimer == nil {
		return nil, nil, nil, fmt.Errorf("payout: PayoutClaimer is required when payout.enabled=true (SPEC §4.3 step 8)")
	}

	// Build address service first — needed before NewMuxStep2.
	denyList, err := payout.NewDenyList(sec.HotWalletAddress)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("deny-list: %w", err)
	}
	pauseReader, err := payout.NewPauseReader(db)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("pause reader: %w", err)
	}
	svc, err := payout.NewAddressesService(db, sec, denyList, tokenStore, tokenStore, pauseReader, cfg.Payout.Tuning.AddressCoolingOffPeriod, logger)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("addresses service: %w", err)
	}

	// Acquire the lease IMMEDIATELY before runner construction.
	state, _, err := payout.Acquire(ctx, db, cfg.Payout.Tuning.RunInterval, logger)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("Acquire lease: %w", err)
	}

	// Construct runner.
	runner, err := payout.NewRunner(payout.RunnerOptions{
		DB:                    db,
		Security:              sec,
		RPCs:                  rpcs,
		Signer:                signer,
		Claimer:               claimer,
		Logger:                logger,
		RunInterval:           cfg.Payout.Tuning.RunInterval,
		MaxRowsPerRun:         cfg.Payout.Tuning.MaxRowsPerRun,
		ConfirmationBlocks:    cfg.Payout.Tuning.ConfirmationBlocks,
		PerPayoutCapBaseUnits: cfg.Payout.Security.PerPayoutCapUSDCBaseUnits,
		PerDayCapBaseUnits:    cfg.Payout.Security.PerDayCapUSDCBaseUnits,
	}, state)
	if err != nil {
		// Release the lease on construction failure so the next
		// process can acquire without waiting the stale window.
		_ = payout.Release(context.Background(), db, state, logger)
		return nil, nil, nil, fmt.Errorf("NewRunner: %w", err)
	}

	// Reorg poller is constructed and exposed via step2 for main.go
	// to ticker. Per SPEC §4.7 it shares the same RPCs and the same
	// lease — the runner cycle's heartbeat is the canonical liveness
	// signal.
	reorgPoller := &payout.ReorgPoller{
		DB:          db,
		RPCs:        rpcs,
		HotWallet:   sec.HotWalletAddress,
		PollWindow:  cfg.Payout.Tuning.ReorgPollWindow,
		RunInterval: cfg.Payout.Tuning.RunInterval,
		Logger:      logger,
	}

	// Build the Step 2 mux — replaces NewMux. The abandon service
	// shares the same RPCs + signer + lease, and uses the runner's
	// RunInterval as the IsLeaseActive window.
	abandonSvc, err := payout.NewAbandonService(db, sec, rpcs, signer, cfg.Payout.Tuning.RunInterval, logger)
	if err != nil {
		_ = payout.Release(context.Background(), db, state, logger)
		return nil, nil, nil, fmt.Errorf("NewAbandonService: %w", err)
	}
	// Step 3 services: §4.8a flag-write primitive, §6.4.1 pause/
	// resume, §4.9 record-funding, §4.7 record-orphan, and the
	// background reaper for the §4.8a + §4.8c outboxes.
	flagWriter, err := payout.NewRuntimeFlagWriter(db, logger)
	if err != nil {
		_ = payout.Release(context.Background(), db, state, logger)
		return nil, nil, nil, fmt.Errorf("NewRuntimeFlagWriter: %w", err)
	}
	pauseSvc, err := payout.NewPauseResumeService(payout.PauseResumeOptions{
		Writer:      flagWriter,
		MinInterval: cfg.Payout.Security.PauseResumeMinInterval,
		Logger:      logger,
	})
	if err != nil {
		_ = payout.Release(context.Background(), db, state, logger)
		return nil, nil, nil, fmt.Errorf("NewPauseResumeService: %w", err)
	}
	fundingSvc, err := payout.NewFundingService(payout.FundingOptions{
		DB:               db,
		RPCs:             &rpcs,
		HotWalletAddress: sec.HotWalletAddress,
		USDCAddress:      payout.USDCContractAddressBase,
		Logger:           logger,
	})
	if err != nil {
		_ = payout.Release(context.Background(), db, state, logger)
		return nil, nil, nil, fmt.Errorf("NewFundingService: %w", err)
	}
	orphansSvc, err := payout.NewOrphansService(payout.OrphansOptions{
		DB:     db,
		Logger: logger,
	})
	if err != nil {
		_ = payout.Release(context.Background(), db, state, logger)
		return nil, nil, nil, fmt.Errorf("NewOrphansService: %w", err)
	}
	reaper, err := payout.NewReaper(payout.ReaperOptions{
		DB:        db,
		PauseSvc:  pauseSvc,
		TickEvery: cfg.Payout.Tuning.RunInterval,
		// §4.7 stale cutoff = 3 × run_interval.
		StaleAge: 3 * cfg.Payout.Tuning.RunInterval,
		Logger:   logger,
	})
	if err != nil {
		_ = payout.Release(context.Background(), db, state, logger)
		return nil, nil, nil, fmt.Errorf("NewReaper: %w", err)
	}

	mux, err := payout.NewMuxStep3(payout.Step3MuxOptions{
		Step2MuxOptions: payout.Step2MuxOptions{
			Addresses:   svc,
			Abandon:     abandonSvc,
			Runner:      runner,
			OperatorKey: cfg.Auth.OperatorKey,
			Caps: payout.AbandonCaps{
				CancelMaxTipMultiplier:      cfg.Payout.Security.CancelMaxTipMultiplier,
				CancelMaxGasNativeWei:       cfg.Payout.Security.CancelMaxGasNativeWei,
				CancelMaxGasNativeWeiPer24h: cfg.Payout.Security.CancelMaxGasNativeWeiPer24h,
				AbandonRatePerHour:          cfg.Payout.Security.AbandonRatePerHour,
			},
			Fallback: billingFallback,
		},
		Pause:   pauseSvc,
		Funding: fundingSvc,
		Orphans: orphansSvc,
		// SPEC §4.8a actor format: "operator_key:<key_id>". The
		// raw key is not the id (it's a secret); use the prefix
		// of its sha-derived label. For Step 3 we use a stable
		// non-secret label tied to the deployment.
		Actor: "operator_key:coordinator",
	})
	if err != nil {
		_ = payout.Release(context.Background(), db, state, logger)
		return nil, nil, nil, fmt.Errorf("payout mux: %w", err)
	}

	logger.Info().
		Str("hot_wallet_address", sec.HotWalletAddress).
		Dur("address_cooling_off_period", cfg.Payout.Tuning.AddressCoolingOffPeriod).
		Uint64("nonce_cursor", chosen).
		Msg("payout pipeline enabled (Step 3: §3.3 handler + §4.3 runner + §4.6 abandon + §4.7 reorg/record-orphan + §4.9 record-funding + §6.4.1 pause/resume + §4.8a reaper)")

	step2 := &payoutStep2{
		runner: runner,
		reorg:  reorgPoller,
		state:  state,
		reaper: reaper,
		stop: func(stopCtx context.Context) {
			// Runner.Stop waits for any in-flight cycle to finish.
			// Codex round-2 [arch:3.1-r2] MEDIUM closure: only
			// Release the lease when Stop confirms a CLEAN exit;
			// on shutdown-timeout the runner may still be holding
			// the broadcast critical section, and releasing the
			// lease would let the next process acquire and race
			// the original holder's in-flight tx.
			cleanExit := runner.Stop(stopCtx)
			// Reaper has no lease to release; stop it after the
			// runner so any final §4.8a write that COMMITs during
			// runner shutdown still has the reaper's safety net.
			_ = reaper.Stop(stopCtx)
			if cleanExit {
				_ = payout.Release(stopCtx, db, state, logger)
			} else {
				logger.Warn().
					Str("event", "payout_runner_lease_left_to_stale_out").
					Str("holder_token_prefix", state.HolderToken[:8]).
					Msg("payout shutdown timed out before runner cycle finished; lease left for stale takeover (SPEC §4.8b)")
			}
		},
	}
	return svc, mux, step2, nil
}

// loadPayoutSigner selects the wallet-load path per SPEC §6.3.
//
// Production path (cfg.Payout.Security.DevMode = false):
//   - Resolve KEK from systemd CREDENTIALS_DIRECTORY (preferred)
//     OR from MACPROVIDER_PAYOUT_WALLET_KEK env var.
//   - LoadLocalFileSigner against the encrypted wallet file at
//     cfg.Payout.Security.EncryptedWalletPath.
//
// Dev path (cfg.Payout.Security.DevMode = true):
//   - Loads from MACPROVIDER_PAYOUT_WALLET_KEY_HEX_DEV_ONLY.
//   - Logs a loud warning. Config-validate enforces that
//     EncryptedWalletPath must be set in production mode; this
//     function double-checks DevMode == true before honoring the
//     env path so a misconfigured deploy can't silently downgrade
//     to dev semantics. Closes codex round-1 [sec:2.3] HIGH.
func loadPayoutSigner(cfg config.PayoutConfig, logger zerolog.Logger) (payout.Signer, error) {
	if !cfg.Security.DevMode {
		// Production path.
		if cfg.Security.EncryptedWalletPath == "" {
			return nil, fmt.Errorf("payout: encrypted_wallet_path required in production mode (SPEC §6.3)")
		}
		kek, err := resolvePayoutKEK()
		if err != nil {
			return nil, fmt.Errorf("payout: resolve KEK: %w", err)
		}
		// Codex round-2 [sec:r2-2.1] MEDIUM closure: zeroize KEK
		// on ALL paths (success + error). The defer wipes the
		// slice before returning from this function, so an error
		// during LoadLocalFileSigner doesn't leave KEK material
		// in heap longer than necessary.
		defer func() {
			for i := range kek {
				kek[i] = 0
			}
		}()
		signer, err := payout.LoadLocalFileSigner(payout.EncryptedWalletFile{
			Path:      cfg.Security.EncryptedWalletPath,
			OnDiskHex: cfg.Security.EncryptedWalletOnDiskHex,
		}, kek)
		if err != nil {
			return nil, fmt.Errorf("payout: LoadLocalFileSigner: %w", err)
		}
		logger.Info().
			Str("from_address", signer.FromAddress()).
			Str("wallet_path", cfg.Security.EncryptedWalletPath).
			Msg("payout signer loaded from encrypted wallet file (SPEC §6.3 production path)")
		return signer, nil
	}
	// Dev path — explicit opt-in only.
	rawHex := os.Getenv("MACPROVIDER_PAYOUT_WALLET_KEY_HEX_DEV_ONLY")
	if rawHex == "" {
		return nil, fmt.Errorf("payout: dev_mode=true but MACPROVIDER_PAYOUT_WALLET_KEY_HEX_DEV_ONLY not set")
	}
	raw, err := hexDecode(rawHex)
	if err != nil {
		return nil, fmt.Errorf("payout signer hex decode: %w", err)
	}
	// Codex round-2 [sec:r2-2.1] MEDIUM closure: zeroize the dev
	// plaintext on all paths.
	defer func() {
		for i := range raw {
			raw[i] = 0
		}
	}()
	signer, err := payout.NewLocalFileSignerFromKey(raw)
	if err != nil {
		return nil, fmt.Errorf("NewLocalFileSignerFromKey: %w", err)
	}
	logger.Warn().
		Str("from_address", signer.FromAddress()).
		Msg("PAYOUT SIGNER LOADED FROM DEV ENV VAR — payout.security.dev_mode=true — NOT FOR PRODUCTION (SPEC §6.3)")
	return signer, nil
}

// resolvePayoutKEK reads the AES-256 KEK from systemd
// LoadCredential= (preferred — directory in CREDENTIALS_DIRECTORY)
// or from the MACPROVIDER_PAYOUT_WALLET_KEK env var (hex-encoded).
// Returns exactly 32 bytes or an error.
func resolvePayoutKEK() ([]byte, error) {
	credDir := os.Getenv("CREDENTIALS_DIRECTORY")
	if credDir != "" {
		candidate := filepath.Join(credDir, "payout-wallet-kek")
		if buf, err := os.ReadFile(candidate); err == nil {
			// Accept both raw bytes (32 bytes) and hex (64 chars).
			trimmed := strings.TrimSpace(string(buf))
			if len(buf) == 32 {
				return buf, nil
			}
			if decoded, decErr := hexDecode(trimmed); decErr == nil && len(decoded) == 32 {
				return decoded, nil
			}
			return nil, fmt.Errorf("payout KEK at %s: unexpected format (want 32 bytes or 64 hex chars)", candidate)
		}
	}
	envHex := os.Getenv("MACPROVIDER_PAYOUT_WALLET_KEK")
	if envHex == "" {
		return nil, fmt.Errorf("payout KEK not found: set systemd LoadCredential=payout-wallet-kek OR env MACPROVIDER_PAYOUT_WALLET_KEK (hex)")
	}
	decoded, err := hexDecode(strings.TrimSpace(envHex))
	if err != nil {
		return nil, fmt.Errorf("MACPROVIDER_PAYOUT_WALLET_KEK hex decode: %w", err)
	}
	if len(decoded) != 32 {
		return nil, fmt.Errorf("MACPROVIDER_PAYOUT_WALLET_KEK must decode to 32 bytes (got %d)", len(decoded))
	}
	return decoded, nil
}

// hexDecode is the local shim for the signer-loading path.
func hexDecode(s string) ([]byte, error) {
	return hex.DecodeString(s)
}

// startPayoutReorgPoller runs the SPEC §4.7 reorg-poll cycle at
// the configured cadence. Lifecycle is bound to shutdownCtx.
func startPayoutReorgPoller(ctx context.Context, poller *payout.ReorgPoller, interval time.Duration, logger zerolog.Logger) {
	if poller == nil {
		return
	}
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		// Run immediately at startup so the first cycle catches any
		// reorg that happened during the previous process's lifetime.
		if _, err := poller.Run(context.Background()); err != nil {
			logger.Warn().Err(err).Msg("payout reorg poller first cycle errored")
		}
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if _, err := poller.Run(context.Background()); err != nil {
					logger.Warn().Err(err).Msg("payout reorg poller errored")
				}
			}
		}
	}()
}

// startPayoutNoncePruner runs the SPEC §3.2 step 5 background
// cleanup at a steady cadence. Runs every minute; the actual
// retention is enforced inside PruneNonces against a fixed
// 10-minute window. Lifecycle is bound to shutdownCtx.
func startPayoutNoncePruner(ctx context.Context, svc *payout.AddressesService, logger zerolog.Logger) {
	if svc == nil {
		return
	}
	prune := func() {
		n, err := svc.PruneNonces(context.Background())
		if err != nil {
			logger.Warn().Err(err).Msg("payout address-nonce prune failed")
			return
		}
		if n > 0 {
			logger.Debug().Int64("deleted", n).Msg("payout address-nonce pruned")
		}
	}
	prune()
	go func() {
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				prune()
			}
		}
	}()
}

func newHTTPServer(addr string, handler http.Handler) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       310 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
}

func reloadTier2Config(configPath string, startupTier2 config.Tier2Config, logger zerolog.Logger, wsServer *providerws.Server, buyerServer *buyer.Server, billingStores ...*billing.Store) {
	cfg, err := config.Load(configPath)
	if err != nil {
		logger.Error().Err(err).Msg("tier2 config reload rejected")
		return
	}
	if tier2StartupFieldsChangedWithLogger(startupTier2, cfg.Tier2, logger) {
		logger.Error().Msg("tier2 config reload rejected: startup-only tier2 fields require restart")
		return
	}
	// M3-8d (audit TEST-4): build a fresh *Catalog and atomically swap the
	// package singleton, rather than mutating the in-place global. A reader
	// holding the old pointer mid-VerifyProviderHash completes against the
	// old (still-valid) catalog; the next call lands on the new one. If
	// ConfigureStrict on the new *Catalog fails, the SIGHUP is rejected
	// and the in-flight singleton is left untouched — same semantics as
	// the pre-M3-8d in-place mutation, but without the SIGHUP-reload race
	// the audit flagged on catalog.go:81-84.
	//
	// M3-8d fixup (codex MED): build + validate + require_hash_verified
	// post-condition + swap now happen atomically inside
	// ConfigureDefaultStrict so this path cannot be bypassed by a future
	// caller skipping a step.
	if _, err := tier2.ConfigureDefaultStrict(cfg.Tier2, logger); err != nil {
		logger.Error().Err(err).Msg("tier2 config reload rejected")
		return
	}
	wsServer.SetTier2Config(cfg.Tier2)
	buyerServer.SetTier2Config(cfg.Tier2)
	if len(billingStores) > 0 && billingStores[0] != nil {
		snapshotID, err := billingStores[0].InsertConfigSnapshot(context.Background(), cfg.Rewards, time.Now().UTC())
		if err != nil {
			logger.Error().Err(err).Msg("billing config snapshot reload rejected")
			return
		}
		buyerServer.SetBillingConfig(cfg.Rewards, snapshotID)
		billingStores[0].SetSettlementConfig(cfg.Settlement)
	}
	updated := wsServer.RefreshTier2HashStatuses()
	logger.Info().Int("provider_hash_statuses_updated", updated).Msg("tier2 config reloaded")
}

func tier2StartupFieldsChanged(startup, next config.Tier2Config) bool {
	return tier2StartupFieldsChangedWithLogger(startup, next, zerolog.Nop())
}

func tier2StartupFieldsChangedWithLogger(startup, next config.Tier2Config, logger zerolog.Logger) bool {
	startupValue := reflect.ValueOf(startup)
	nextValue := reflect.ValueOf(next)
	fields := reflect.TypeOf(config.Tier2Config{})
	for i := 0; i < fields.NumField(); i++ {
		name := fields.Field(i).Name
		class, ok := tier2ReloadFieldClasses[name]
		if !ok || class != tier2HotReloadable {
			if tier2ReloadFieldChanged(name, startupValue.Field(i), nextValue.Field(i)) {
				logger.Error().Str("field", name).Msg("tier2 config reload rejected: startup-only or unregistered tier2 field changed")
				return true
			}
		}
	}
	return false
}

type tier2ReloadFieldClass string

const (
	tier2HotReloadable tier2ReloadFieldClass = "hot_reloadable"
	tier2StartupOnly   tier2ReloadFieldClass = "startup_only"
)

// Fields not listed here default to startup-only (SIGHUP rejected if changed).
// Phase-1-blocked fields (RequireEncryptedLeg, RequireAttestation,
// BehavioralSafetyEnabled, etc.) are listed as hot-reloadable because
// config.Load() -> config.Validate() rejects them before reloadTier2Config
// reaches the field-class check. When Phase 2/3 removes those blocks, update
// the field class here.
var tier2ReloadFieldClasses = map[string]tier2ReloadFieldClass{
	"ObserveEnabled":      tier2HotReloadable,
	"RequireHashVerified": tier2HotReloadable,

	"CatalogPath":      tier2StartupOnly,
	"CatalogPublicKey": tier2StartupOnly,
	// SPEC-015 §M.4 — public catalog base URL is operator-visible
	// only; hot-reloadable so an operator can flip it without
	// restarting the coordinator.
	"PublicCatalogBaseURL":           tier2HotReloadable,
	"EncryptedLegAEAD":               tier2StartupOnly,
	"EncryptedLegRekeyAfterRequests": tier2StartupOnly,
	"EncryptedLegRekeyAfterSeconds":  tier2StartupOnly,
	"AttestationRoots":               tier2StartupOnly,
	"AttestationFormats":             tier2StartupOnly,
	"AllowMockAttestation":           tier2StartupOnly,
	"RequireEncryptedLeg":            tier2HotReloadable,
	"RequireAttestation":             tier2HotReloadable,
	"AttestationMaxAgeS":             tier2HotReloadable,
	"BehavioralSafetyEnabled":        tier2HotReloadable,
	"OutputSizeCapBytes":             tier2HotReloadable,
	"OutputBytesPerTokenCeiling":     tier2HotReloadable,
	"DefaultOutputSizeCapBytes":      tier2HotReloadable,
	"EncodingValidationEnabled":      tier2HotReloadable,
	"ResponseTimeAnomalyEnabled":     tier2HotReloadable,
	"ResponseTimeAnomalyFactor":      tier2HotReloadable,
	"ResponseTimeAnomalyMinMS":       tier2HotReloadable,
}

func tier2ReloadFieldChanged(name string, startup, next reflect.Value) bool {
	switch name {
	case "CatalogPath":
		return startup.String() != next.String()
	case "CatalogPublicKey":
		return strings.TrimSpace(startup.String()) != strings.TrimSpace(next.String())
	default:
		return !reflect.DeepEqual(startup.Interface(), next.Interface())
	}
}
