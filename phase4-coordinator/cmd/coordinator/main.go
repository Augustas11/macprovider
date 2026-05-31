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

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/providerhttp"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
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
	wsOpts := []providerws.Option{}
	if cfg.Auth.RequireProviderTokens {
		wsOpts = append(wsOpts, providerws.WithTokenValidator(tokenStore))
		logger.Info().Msg("provider WS token validation REQUIRED (auth.require_provider_tokens=true)")
	} else {
		logger.Info().Msg("provider WS token validation NOT required (auth.require_provider_tokens=false); pinned providers connect by provider_id match only")
	}
	wsServer := providerws.NewServer(cfg, registry, logger, wsOpts...)
	buyerServer := buyer.NewServer(
		registry,
		logger,
		startedAt,
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
	providerHTTP := &http.Server{Addr: providerAddr, Handler: providerMux}
	buyerHTTP := &http.Server{Addr: buyerAddr, Handler: buyerServer.Handler()}
	errs := make(chan error, 2)

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
				reloadTier2Config(*configPath, cfg.Tier2, logger, wsServer, buyerServer)
				continue
			}
			timeout := 30 * time.Second
			if sig == syscall.SIGINT {
				timeout = 5 * time.Second
			}
			logger.Info().Str("signal", sig.String()).Dur("timeout", timeout).Msg("coordinator shutdown requested")
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

func reloadTier2Config(configPath string, startupTier2 config.Tier2Config, logger zerolog.Logger, wsServer *providerws.Server, buyerServer *buyer.Server) {
	cfg, err := config.Load(configPath)
	if err != nil {
		logger.Error().Err(err).Msg("tier2 config reload rejected")
		return
	}
	if tier2StartupFieldsChangedWithLogger(startupTier2, cfg.Tier2, logger) {
		logger.Error().Msg("tier2 config reload rejected: startup-only tier2 fields require restart")
		return
	}
	if err := tier2.Configure(cfg.Tier2, logger); err != nil {
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
