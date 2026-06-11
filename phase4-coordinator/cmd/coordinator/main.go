package main

import (
	"context"
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
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/providerhttp"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// version is overridden at build time via
//   go build -ldflags "-X main.version=$(git describe --always --dirty --tags)"
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
	if cfg.Auth.RequireProviderTokens {
		logger.Info().Msg("provider WS token validation REQUIRED (auth.require_provider_tokens=true)")
	} else {
		logger.Info().Msg("provider WS token validation NOT required (auth.require_provider_tokens=false); tokenless provisional admissions will self-mint per SPEC-003 FR-C9")
	}
	if cfg.Explorer.Enabled {
		wsOpts = append(wsOpts, providerws.WithExplorerHandler(explorer.NewHandler(cfg, reqLogStore.DB(), registry, startedAt)))
		logger.Info().Str("path", cfg.Explorer.BindPath).Msg("operator explorer enabled")
	}
	swapEmitter := func(event pool.SwapEvent) {
		if err := auditStore.EmitSwap(shutdownCtx, event); err != nil {
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
	}
	wsOpts = append(wsOpts, providerws.WithRegistryOptions(
		pool.WithSwapEmitter(swapEmitter),
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
	billingHandler := billingStore.Handlers(
		cfg.Auth.OperatorKey,
		tokenStore,
		cfg.Auth.RequireProviderTokens,
		cfg.Endpoints.ProviderEarnings.RateLimitPerMinute,
	)
	providerMux.Handle("/admin/ledger/", billingHandler)
	if cfg.Auth.RequireProviderTokens {
		providerMux.Handle("/providers/", billingHandler)
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
	if err := tier2.ConfigureStrict(cfg.Tier2, logger); err != nil {
		logger.Error().Err(err).Msg("tier2 config reload rejected")
		return
	}
	if cfg.Tier2.RequireHashVerified && !tier2.Active() {
		if tier2.Configured() {
			logger.Error().Msg("tier2 config reload rejected: require_hash_verified requires an active (non-expired) catalog; the current catalog has expired or failed to load")
		} else {
			logger.Error().Msg("tier2 config reload rejected: require_hash_verified requires a configured catalog")
		}
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

	"CatalogPath":                    tier2StartupOnly,
	"CatalogPublicKey":               tier2StartupOnly,
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
