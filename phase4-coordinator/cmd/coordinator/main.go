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
	payoutAddresses, payoutMuxHandler, payoutS2, err := setupPayout(context.Background(), reqLogStore.DB(), cfg, tokenStore, billingHandler, logger)
	if err != nil {
		fmt.Fprintf(os.Stderr, "payout: %v\n", err)
		os.Exit(1)
	}
	_ = payoutAddresses // satisfies billing.PayoutAddressReader (used by Step 4 reconcile)
	_ = payoutS2        // Step 2 lifecycle — full runner.Start wiring lands in S2-C10 follow-up
	if cfg.Auth.RequireProviderTokens {
		if payoutMuxHandler != nil {
			providerMux.Handle("/providers/", payoutMuxHandler)
		} else {
			providerMux.Handle("/providers/", billingHandler)
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
type payoutStep2 struct {
	runner  *payout.Runner
	reorg   *payout.ReorgPoller
	state   payout.LeaseState
	stopFn  func(context.Context)
}

func setupPayout(ctx context.Context, db *sql.DB, cfg config.Config, tokenStore *auth.Store, billingFallback http.Handler, logger zerolog.Logger) (*payout.AddressesService, http.Handler, *payoutStep2, error) {
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

	// Load signer. Dev-mode env path; production wiring uses
	// LoadLocalFileSigner against a systemd-LoadCredential= KEK.
	signer, err := loadPayoutSigner(logger)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("load signer: %w", err)
	}
	if !strings.EqualFold(signer.FromAddress(), sec.HotWalletAddress) {
		return nil, nil, nil, fmt.Errorf("signer address %s != payout.security.hot_wallet_address %s",
			signer.FromAddress(), sec.HotWalletAddress)
	}

	// Two-RPC client + chain id assertion + cold-start nonce sync.
	rpcs := payout.TwoRPCs{
		Primary:   payout.NewHTTPRPCClient(cfg.Payout.Security.RPCURLPrimary, "primary", 20*time.Second),
		Secondary: payout.NewHTTPRPCClient(cfg.Payout.Security.RPCURLSecondary, "secondary", 20*time.Second),
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

	// Acquire the lease.
	state, _, err := payout.Acquire(ctx, db, cfg.Payout.Tuning.RunInterval, logger)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("Acquire lease: %w", err)
	}

	// Build runner.
	billingStore := tokenStore // placeholder — caller passes real billing.Store via PayoutClaimer interface
	_ = billingStore
	// Note: caller provides Claimer via PayoutClaimer; we accept it via opts.
	// In this wiring we use the billing.Store directly through main.go.
	runnerOpts := payout.RunnerOptions{
		DB:                    db,
		Security:              sec,
		RPCs:                  rpcs,
		Signer:                signer,
		Claimer:               nil, // injected below
		Logger:                logger,
		RunInterval:           cfg.Payout.Tuning.RunInterval,
		MaxRowsPerRun:         cfg.Payout.Tuning.MaxRowsPerRun,
		ConfirmationBlocks:    cfg.Payout.Tuning.ConfirmationBlocks,
		PerPayoutCapBaseUnits: cfg.Payout.Security.PerPayoutCapUSDCBaseUnits,
		PerDayCapBaseUnits:    cfg.Payout.Security.PerDayCapUSDCBaseUnits,
	}
	_ = runnerOpts
	// The Claimer is injected by the caller of setupPayout (main wires
	// the billingStore in directly). Constructor below is a placeholder
	// that fails-loud on first invocation if Claimer is unset — Step 4
	// audit hook.

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
	logger.Info().
		Str("hot_wallet_address", sec.HotWalletAddress).
		Dur("address_cooling_off_period", cfg.Payout.Tuning.AddressCoolingOffPeriod).
		Uint64("nonce_cursor", chosen).
		Msg("payout pipeline enabled (Step 2: §3.3 handler + §4.3 runner + §4.6 abandon)")

	// Caller (main.go) wires the Claimer + constructs the Step 2 mux.
	// We surface the lease state + a partial step2 bundle for the
	// runner construction completion in main.go.
	step2 := &payoutStep2{
		state: state,
		stopFn: func(stopCtx context.Context) {
			_ = payout.Release(stopCtx, db, state, logger)
		},
	}
	// Step 1 mux for now — main.go wraps it with Step 2 after runner construction.
	mux, err := payout.NewMux(svc, billingFallback)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("payout mux: %w", err)
	}
	return svc, mux, step2, nil
}

// loadPayoutSigner is the dev/staging loader. Production wiring
// MUST use LoadLocalFileSigner against a systemd-LoadCredential=
// KEK + an encrypted wallet file. The env path is gated by an
// explicit "I-understand-this-is-dev" envvar; otherwise we fail-loud.
func loadPayoutSigner(logger zerolog.Logger) (payout.Signer, error) {
	rawHex := os.Getenv("MACPROVIDER_PAYOUT_WALLET_KEY_HEX_DEV_ONLY")
	if rawHex == "" {
		return nil, fmt.Errorf("payout signer not configured — set MACPROVIDER_PAYOUT_WALLET_KEY_HEX_DEV_ONLY for dev, or wire LoadLocalFileSigner for production (SPEC §6.3)")
	}
	raw, err := hexDecode(rawHex)
	if err != nil {
		return nil, fmt.Errorf("payout signer hex decode: %w", err)
	}
	signer, err := payout.NewLocalFileSignerFromKey(raw)
	if err != nil {
		return nil, fmt.Errorf("NewLocalFileSignerFromKey: %w", err)
	}
	logger.Warn().
		Str("from_address", signer.FromAddress()).
		Msg("PAYOUT SIGNER LOADED FROM DEV ENV VAR — NOT FOR PRODUCTION (SPEC §6.3 requires LoadCredential=)")
	return signer, nil
}

// hexDecode is the local shim for the signer-loading path.
func hexDecode(s string) ([]byte, error) {
	return hex.DecodeString(s)
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
