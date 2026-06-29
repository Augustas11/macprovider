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
		// Codex Step 3 r1 [arch:3.1] MAJOR closure: the poller
		// owns its own lifecycle via Start/Stop; shutdownCtx is
		// threaded into every poll cycle so a graceful shutdown
		// interrupts mid-RPC instead of using context.Background().
		payoutS2.reorg.Start(shutdownCtx)
		// Step 3 §4.8a + §4.8c reaper.
		if payoutS2.reaper != nil {
			payoutS2.reaper.Start(shutdownCtx)
		}
		// Step 4 §7.4 chain-balance worker.
		if payoutS2.chainWorker != nil {
			payoutS2.chainWorker.Start(shutdownCtx)
		}
		// Step 4 §6.5 SIGHUP-only payout.tuning.* reload. Reading
		// the YAML on SIGHUP MUST NOT touch payout.security.* (the
		// loader is read-only on the security namespace); the
		// TuningProvider.Reload helper applies bound re-enforcement
		// AND emits payout_config_reloaded / payout_config_reload_rejected
		// per SPEC §6.5.
		go startPayoutSIGHUPListener(shutdownCtx, *configPath, payoutS2.tuning, payoutS2.rpcs, logger)
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
// Step 3 extends it with the §4.8a + §4.7 reaper. Step 4 adds the
// §7.4 chain-balance worker + §6.5 tuning provider for SIGHUP.
type payoutStep2 struct {
	runner      *payout.Runner
	reorg       *payout.ReorgPoller
	state       payout.LeaseState
	reaper      *payout.Reaper             // Step 3 §4.8a + §4.8c outbox reaper
	chainWorker *payout.ChainBalanceWorker // Step 4 §7.4
	tuning      *payout.TuningProvider     // Step 4 §6.5 SIGHUP-reloadable
	rpcs        payout.TwoRPCs             // Step 4 r3 [sec:r3-1] SPKI pin rotation: CloseIdleConnections on SIGHUP
	stop        func(context.Context)      // calls Stop on every component then Release
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
	// SPEC §3.3 + §6.3 co-residency / Linux-only invariant — assert
	// BEFORE building any service so a misconfigured deployment
	// fails fast at startup, not on the first request.
	//
	// FULL-r1 [full-arch:r1-1] MEDIUM closure: SPEC §6.3 requires
	// "IMPL MUST refuse to start the runner on runtime.GOOS !=
	// \"linux\"". Step 1 r2 convergence carried LinuxRequired=true
	// as a Step 2 tightening; this flip lands it. The topology
	// assertion is now the single startup authority for §6.3
	// Linux-only refusal, not a downstream comment in signer.go.
	if err := payout.AssertPayoutRuntimeTopology(payout.PayoutRuntimeTopology{
		HandlerEnabled:         true,
		RunnerCoResident:       true,
		HotWalletAddressPinned: sec.HotWalletAddress,
		LinuxRequired:          true,
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

	if claimer == nil {
		return nil, nil, nil, fmt.Errorf("payout: PayoutClaimer is required when payout.enabled=true (SPEC §4.3 step 8)")
	}

	// Step 4 §6.5 — SIGHUP-reloadable tuning provider. Built
	// BEFORE the RPC clients so the live pin func() string closures
	// can reference it. Step 4 r1 [code:r1-1]/[sec:r1-2]/[arch:4.2]
	// convergent closure — accepting a SIGHUP reload without consumer
	// plumbing was the original defect. Step 4 r2 [arch:r2-4.2] MAJOR
	// closure: moved BEFORE NewHTTPRPCClient so the pin func reads the
	// live snapshot at every TLS handshake rather than the startup value.
	initialTuning := payout.TuningSnapshot{
		AddressCoolingOffPeriod: cfg.Payout.Tuning.AddressCoolingOffPeriod,
		RunInterval:             cfg.Payout.Tuning.RunInterval,
		RunNowMinInterval:       cfg.Payout.Tuning.RunNowMinInterval,
		ConfirmationBlocks:      cfg.Payout.Tuning.ConfirmationBlocks,
		MaxRowsPerRun:           cfg.Payout.Tuning.MaxRowsPerRun,
		ReorgPollWindow:         cfg.Payout.Tuning.ReorgPollWindow,
		LowBalanceThreshold:     cfg.Payout.Tuning.LowBalanceThreshold,
		LowNativeThreshold:      cfg.Payout.Tuning.LowNativeThreshold,
		RPCURLPrimaryPinSPKI:    cfg.Payout.Tuning.RPCURLPrimaryPinSPKI,
		RPCURLSecondaryPinSPKI:  cfg.Payout.Tuning.RPCURLSecondaryPinSPKI,
	}
	tuningProvider, err := payout.NewTuningProvider(initialTuning, cfg.Payout.Security.PerDayCapUSDCBaseUnits, logger)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("NewTuningProvider: %w", err)
	}

	// Two-RPC client + chain id assertion + cold-start nonce sync.
	// SPKI pinning per SPEC §4.4 (Step 2 [arch:3.3] closure).
	// Step 4 r2 [arch:r2-4.2] MAJOR closure: pin is now func() string
	// reading the live TuningProvider snapshot so SIGHUP SPKI rotations
	// take effect at the next TLS handshake (not just accepted and logged).
	// #165 A2: chronic-outage tracker wraps both RPC clients so every
	// JSON-RPC call records success/failure into a sliding-window
	// detector. Runner evaluates per cycle and emits
	// payout_rpc_chronic_outage PAGE if either RPC's per-label error
	// rate crosses the threshold. Tracker uses SPEC defaults (10min
	// window / 50% threshold / 10 minSamples / 10min PAGE cooldown).
	chronicTracker := payout.NewChronicOutageTracker(logger, nil)
	rpcs := payout.TwoRPCs{
		Primary: payout.NewTrackingRPCClient(payout.NewHTTPRPCClient(
			cfg.Payout.Security.RPCURLPrimary, "primary",
			func() string { return tuningProvider.Snapshot().RPCURLPrimaryPinSPKI },
			20*time.Second,
		), chronicTracker),
		Secondary: payout.NewTrackingRPCClient(payout.NewHTTPRPCClient(
			cfg.Payout.Security.RPCURLSecondary, "secondary",
			func() string { return tuningProvider.Snapshot().RPCURLSecondaryPinSPKI },
			20*time.Second,
		), chronicTracker),
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
	// Capture the cold-start timestamp once so the log event and the
	// cursor write share the same wall time.
	coldStartTS := time.Now().UTC().Format(time.RFC3339Nano)
	if within {
		// Step 4 r5 [code:r5-3] MEDIUM closure: §7.1 line 3729
		// requires ts_utc in payout_nonce_cold_start_within_tolerance.
		logger.Warn().
			Str("event", "payout_nonce_cold_start_within_tolerance").
			Str("from_address", sec.HotWalletAddress).
			Uint64("rpc_a_nonce", rpcA).
			Uint64("rpc_b_nonce", rpcB).
			Uint64("chosen_nonce", chosen).
			Str("ts_utc", coldStartTS).
			Send()
	}
	if err := payout.UpsertNonceCursor(ctx, db, sec.HotWalletAddress, chosen, rpcA, rpcB, coldStartTS); err != nil {
		return nil, nil, nil, fmt.Errorf("UpsertNonceCursor: %w", err)
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
	// Wire live tuning so address cooling-off reads at write time.
	svc.Tuning = tuningProvider

	// Acquire the lease IMMEDIATELY before runner construction.
	state, _, err := payout.Acquire(ctx, db, cfg.Payout.Tuning.RunInterval, logger)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("Acquire lease: %w", err)
	}

	// Construct runner. Step 4 r1 closures:
	//   - Tuning is wired so MaxRowsPerRun/ConfirmationBlocks/
	//     LowBalance/LowNative reads come from the SIGHUP-reloadable
	//     snapshot at the top of every cycle ([code:r1-1]/
	//     [code:r1-2]/[arch:4.2]/[arch:4.3]/[sec:r1-2]/[sec:r1-3]).
	//   - LowBalanceThreshold/LowNativeThreshold also passed as
	//     static fields so a missing Tuning (test path) still has
	//     a sane fallback.
	//   - RunInterval is still captured here for the cadence ticker;
	//     SIGHUP changes to run_interval require restart (documented
	//     limitation per [arch:4.2]).
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
		LowBalanceThreshold:   cfg.Payout.Tuning.LowBalanceThreshold,
		LowNativeThreshold:    cfg.Payout.Tuning.LowNativeThreshold,
		Tuning:                tuningProvider,
		ChronicOutage:         chronicTracker,
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
		Tuning:      tuningProvider,
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
		Actor:            "operator_key:coordinator",
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
		// §4.7 stale cutoff = 3 × run_interval. With Tuning wired,
		// ReapOnce reads 3 × Tuning.Snapshot().RunInterval per
		// cycle so SIGHUP changes land at the next tick (the ticker
		// cadence itself remains captured until restart).
		StaleAge: 3 * cfg.Payout.Tuning.RunInterval,
		Tuning:   tuningProvider,
		Logger:   logger,
	})
	if err != nil {
		_ = payout.Release(context.Background(), db, state, logger)
		return nil, nil, nil, fmt.Errorf("NewReaper: %w", err)
	}

	// Step 4 §7.4 — chain-balance worker. The haltRunner callback
	// calls runner.RequestHalt to stop the next cycle from running;
	// the in-flight broadcast (if any) still gets to complete since
	// the halt flag is read at the TOP of the next RunOnce, not
	// mid-cycle.
	//
	// Step 4 r1 [arch:4.1]/[sec:r1-1] convergent closure: the
	// previous wiring emitted the PAGE but DID NOT actually halt
	// the runner, so subsequent cycles continued after fake-funding
	// detection. SPEC §7.4 says drift beyond tolerance MUST halt.
	chainCfg := payout.ChainBalanceConfig{
		Interval:      cfg.Payout.Security.ChainReconInterval,
		ToleranceUSDC: cfg.Payout.Security.ChainReconToleranceUSDCBaseUnits,
		HotWalletAddr: sec.HotWalletAddress,
		USDCContract:  payout.USDCContractAddressBase,
	}
	chainWorker, err := payout.NewChainBalanceWorker(db, rpcs, chainCfg, func(reason string) {
		// RequestHalt is idempotent and emits payout_runner_halted
		// PAGE on the first invocation. Subsequent calls are no-ops
		// preserving the first reason.
		runner.RequestHalt(reason)
	}, logger)
	if err != nil {
		_ = payout.Release(context.Background(), db, state, logger)
		return nil, nil, nil, fmt.Errorf("NewChainBalanceWorker: %w", err)
	}

	// Step 4 §7.3 provider-token payouts read endpoint.
	payoutsHandler, err := payout.NewPayoutsHandler(payout.PayoutsHandlerOptions{
		DB:           db,
		Tokens:       tokenStore,
		RateLimitMin: 60, // mirror billing/earnings 60/min default
		Logger:       logger,
	})
	if err != nil {
		_ = payout.Release(context.Background(), db, state, logger)
		return nil, nil, nil, fmt.Errorf("NewPayoutsHandler: %w", err)
	}

	// Step 4 r2 [code:r2-1]/[sec:r2-1]/[arch:r2-4.1] CONVERGENT MAJOR
	// closure: shared RunNowController enforces run_now_min_interval
	// rate-limit and emits payout_run_now_invoked on EVERY outcome.
	// Uses the live tuningProvider so SIGHUP interval changes land at
	// the next invocation without restart.
	runNowCtrl, err := payout.NewRunNowController(
		runner,
		tuningProvider,
		cfg.Payout.Tuning.RunNowMinInterval, // fallback when tuning nil
		logger,
	)
	if err != nil {
		_ = payout.Release(context.Background(), db, state, logger)
		return nil, nil, nil, fmt.Errorf("NewRunNowController: %w", err)
	}

	mux, err := payout.NewMuxStep4(payout.Step4MuxOptions{
		Step3MuxOptions: payout.Step3MuxOptions{
			Step2MuxOptions: payout.Step2MuxOptions{
				Addresses:   svc,
				Abandon:     abandonSvc,
				Runner:      runner,
				RunNow:      runNowCtrl,
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
			// of its sha-derived label. For Step 3+ we use a stable
			// non-secret label tied to the deployment.
			Actor: "operator_key:coordinator",
		},
		Payouts: payoutsHandler,
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
		runner:      runner,
		reorg:       reorgPoller,
		state:       state,
		reaper:      reaper,
		chainWorker: chainWorker,
		tuning:      tuningProvider,
		rpcs:        rpcs,
		stop: func(stopCtx context.Context) {
			// Codex Step 3 r1 [arch:3.1] MAJOR closure: shutdown
			// ordering is runner → poller → reaper → Release.
			// Each Stop returns bool; we release the lease only
			// when ALL THREE confirm clean exit. If any returned
			// false the runner OR the poller may still be holding
			// the chain-write critical section, and releasing the
			// lease would let the next process Acquire mid-write.
			//
			// Codex round-2 [arch:3.1-r2] MEDIUM closure (Step 2):
			// lease left to stale takeover (3 × run_interval) on
			// timeout per SPEC §4.8b.
			//
			// Step 4 adds chainWorker.Stop — read-only RPC worker
			// without lease implications, but we still want it to
			// drain before the runner so a final balance reconcile
			// gets a chance to fire on clean shutdown.
			_ = chainWorker.Stop(stopCtx)
			runnerClean := runner.Stop(stopCtx)
			pollerClean := reorgPoller.Stop(stopCtx)
			// Reaper has no lease to release but Stop must still
			// complete; we don't gate Release on its bool because
			// reaper.Stop hitting the timeout cannot corrupt
			// chain state.
			_ = reaper.Stop(stopCtx)
			if runnerClean && pollerClean {
				_ = payout.Release(stopCtx, db, state, logger)
			} else {
				logger.Warn().
					Str("event", "payout_runner_lease_left_to_stale_out").
					Str("holder_token_prefix", state.HolderToken[:8]).
					Bool("runner_clean", runnerClean).
					Bool("poller_clean", pollerClean).
					Msg("payout shutdown timed out before runner+poller drained; lease left for stale takeover (SPEC §4.8b)")
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

// Codex Step 3 r1 [arch:3.1] MAJOR closure: the standalone
// startPayoutReorgPoller helper that used to live here is
// retired; the poller now owns its own Start/Stop lifecycle so
// the shutdown closure can wait for it to drain alongside the
// runner before the lease is released. See
// internal/payout/reorg.go for the Start/Stop primitives.

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

// startPayoutSIGHUPListener installs a SIGHUP-only signal handler
// for the §6.5 `payout.tuning.*` namespace. SPEC §6.5 normative:
//
//   - SIGHUP MUST be the ONLY trigger. fsnotify / runtime-debug
//     endpoint / config-file-mtime-watch are FORBIDDEN.
//   - Reload re-reads the YAML via config.LoadPayoutTuningOnly,
//     captures the candidate snapshot, and calls TuningProvider.Reload
//     — which re-runs the §6.5 bound matrix and either commits +
//     PAGE-emits OR retains the live value + PAGE-emits-rejected.
//   - Step 4 r1 [code:r1-3] MEDIUM closure: the security namespace is
//     genuinely NOT parsed on this path. LoadPayoutTuningOnly only
//     reads `payout.tuning.*` keys; it does NOT resolve env: sentinels
//     for payout.security.*, does NOT call Validate on security fields,
//     and will NOT reject a SIGHUP because a security key changed.
//   - Step 4 r3 [sec:r3-1]/[arch:r3-4.2] closure: when an SPKI pin
//     key is in the changed set, CloseIdleConnections is called on
//     both RPC clients so the next RPC forces a fresh TLS handshake
//     under the new pin instead of reusing a pooled connection that
//     was verified under the old pin.
func startPayoutSIGHUPListener(
	ctx context.Context,
	configPath string,
	tuning *payout.TuningProvider,
	rpcs payout.TwoRPCs,
	log zerolog.Logger,
) {
	if tuning == nil {
		return
	}
	sigCh := make(chan os.Signal, 4)
	signal.Notify(sigCh, syscall.SIGHUP)
	defer signal.Stop(sigCh)
	defer close(sigCh)
	for {
		select {
		case <-ctx.Done():
			return
		case <-sigCh:
			// Step 4 r1 [code:r1-3] MEDIUM closure: use tuning-only
			// loader so payout.security.* is never parsed, resolved, or
			// validated on the SIGHUP path.
			t, err := config.LoadPayoutTuningOnly(configPath)
			if err != nil {
				// Step 4 r4 [code:r4-1]/[sec:r4-1] CONVERGENT MEDIUM closure:
				// structured §7.1 fields on YAML-load failure path. Use sanitized
				// literal "config_load_failed" for attempted_value — do NOT log raw
				// YAML contents because the full coordinator file can contain
				// secrets outside payout.tuning.
				tsUTC := time.Now().UTC().Format(time.RFC3339Nano)
				log.Error().Err(err).
					Str("event", "payout_config_reload_rejected").
					Str("key", "yaml_parse").
					Str("attempted_value", "config_load_failed").
					Str("bound", "valid payout.tuning YAML").
					Str("actor", "operator_key:coordinator").
					Str("ts_utc", tsUTC).
					Str("severity", "PAGE").
					Msg("payout tuning SIGHUP reload: LoadPayoutTuningOnly failed; live value retained")
				continue
			}
			candidate := payout.TuningSnapshot{
				AddressCoolingOffPeriod: t.AddressCoolingOffPeriod,
				RunInterval:             t.RunInterval,
				RunNowMinInterval:       t.RunNowMinInterval,
				ConfirmationBlocks:      t.ConfirmationBlocks,
				MaxRowsPerRun:           t.MaxRowsPerRun,
				ReorgPollWindow:         t.ReorgPollWindow,
				LowBalanceThreshold:     t.LowBalanceThreshold,
				LowNativeThreshold:      t.LowNativeThreshold,
				RPCURLPrimaryPinSPKI:    t.RPCURLPrimaryPinSPKI,
				RPCURLSecondaryPinSPKI:  t.RPCURLSecondaryPinSPKI,
			}
			// Reload itself emits payout_config_reloaded /
			// payout_config_reload_rejected per §7.1; we just
			// surface the wrapper error for the runner log so
			// operators see SIGHUP arrived.
			changedKeys, reloadErr := tuning.Reload(ctx, candidate)
			if reloadErr != nil {
				log.Info().Err(reloadErr).
					Str("event", "payout_tuning_sighup_received").
					Msg("payout tuning SIGHUP processed (rejected; see payout_config_reload_rejected)")
			} else {
				log.Info().
					Str("event", "payout_tuning_sighup_received").
					Msg("payout tuning SIGHUP processed (accepted; see payout_config_reloaded)")
				// Step 4 r3 [sec:r3-1]/[arch:r3-4.2] CONVERGENT HIGH/MEDIUM
				// closure: drain idle TLS connections so the next RPC call
				// forces a fresh handshake under the new SPKI pin. Without
				// this, the 90s IdleConnTimeout can keep the old verified
				// connection alive after operators believe the new pin is
				// active. Called only on accepted reloads where the pin key
				// actually changed; no-op for non-SPKI reload cycles.
				for _, k := range changedKeys {
					if k == "payout.tuning.rpc_url_primary_pin_spki" ||
						k == "payout.tuning.rpc_url_secondary_pin_spki" {
						if rpc, ok := rpcs.Primary.(*payout.HTTPRPCClient); ok {
							rpc.CloseIdleConnections()
						}
						if rpc, ok := rpcs.Secondary.(*payout.HTTPRPCClient); ok {
							rpc.CloseIdleConnections()
						}
						break
					}
				}
			}
		}
	}
}
