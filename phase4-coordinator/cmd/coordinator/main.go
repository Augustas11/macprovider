package main

import (
	"context"
	"database/sql"
	"flag"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"reflect"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/audit"
	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/explorer"
	"github.com/augstar/macprovider-coordinator/internal/mdm"
	"github.com/augstar/macprovider-coordinator/internal/onboarding"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/pow"
	"github.com/augstar/macprovider-coordinator/internal/providerhttp"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/augstar/macprovider-coordinator/internal/rewards"
	"github.com/augstar/macprovider-coordinator/internal/stats"
	statshardware "github.com/augstar/macprovider-coordinator/internal/stats/hardware"
	statsmetrics "github.com/augstar/macprovider-coordinator/internal/stats/metrics"
	"github.com/augstar/macprovider-coordinator/internal/stats/poolsnapshot"
	statsprewarm "github.com/augstar/macprovider-coordinator/internal/stats/prewarm"
	statsrollup "github.com/augstar/macprovider-coordinator/internal/stats/rollup"
	statsstore "github.com/augstar/macprovider-coordinator/internal/stats/store"

	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	prom "github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	// SPEC-017 v0.1.8 — register the Postgres driver under the
	// "postgres" name used by internal/stats.Open. lib/pq is the
	// only Postgres driver in go.mod for v0.1; switching to pgx
	// requires a SPEC v0.2 conversation.
	_ "github.com/lib/pq"

	"github.com/rs/zerolog"
)

// parseRFC3339Strict parses an RFC 3339 timestamp and returns an
// explicit error on parse failure. Used in the stats rollup
// boot path where backfill_mode = "partial" requires the
// boundary to be valid (round-1 ARCH r1 HIGH 2 fix).
func parseRFC3339Strict(s string) (time.Time, error) {
	return time.Parse(time.RFC3339, s)
}

// version is overridden at build time via
//
//	go build -ldflags "-X main.version=$(git describe --always --dirty --tags)"
//
// (see scripts/build-linux.sh). Defaults to "dev" for local `go run`.
var version = "dev"

func main() {
	// SPEC-017 v0.1.8 Step 4.A — subcommand dispatch. When the
	// first positional arg is a known operator-CLI verb, route
	// to the corresponding handler and exit with its code. The
	// daemon path is preserved below for argv shapes that DON'T
	// match (the historical `coordinator --config=... --version`
	// invocations).
	//
	// Why before flag.Parse(): the daemon's flag set rejects
	// non-flag positional args ("partner-keys" would error out
	// of flag.Parse with "flag provided but not defined"). We
	// intercept first.
	if len(os.Args) >= 2 {
		arg1 := os.Args[1]
		switch arg1 {
		case "partner-keys":
			os.Exit(runPartnerKeys(os.Args[2:]))
		case "visibility":
			os.Exit(runVisibility(os.Args[2:]))
		case "migrate-indexes":
			os.Exit(runMigrateIndexes(os.Args[2:]))
		case "backfill-attempt-n":
			os.Exit(runBackfillAttemptN(os.Args[2:]))
		case "stats-migrate":
			os.Exit(runStatsMigrate(os.Args[2:]))
		}
		// Round-1 CODE H1 fix: a non-flag first positional that
		// is NEITHER a known daemon flag NOR a known CLI verb is
		// a typo. Reject with usage so an operator who mistypes
		// `coordinator visiblity revert ...` doesn't silently
		// start the daemon (which would try to load
		// coordinator.yaml). Daemon flags begin with `-`; CLI
		// verbs are enumerated below.
		if !strings.HasPrefix(arg1, "-") {
			fmt.Fprintf(os.Stderr, "coordinator: unknown subcommand %q\n", arg1)
			fmt.Fprintln(os.Stderr, "usage:")
			fmt.Fprintln(os.Stderr, "  coordinator --config <path> [--config-overlay <path>] [--validate-config]")
			fmt.Fprintln(os.Stderr, "  coordinator --version           (print build version)")
			fmt.Fprintln(os.Stderr, "  coordinator partner-keys <issue|revoke|list> [flags]")
			fmt.Fprintln(os.Stderr, "  coordinator visibility revert --id <pid> --reason TEXT")
			fmt.Fprintln(os.Stderr, "  coordinator migrate-indexes --config <path>  (one-shot operator migration)")
			fmt.Fprintln(os.Stderr, "  coordinator backfill-attempt-n --config <path>  (one-shot attempt_n backfill)")
			fmt.Fprintln(os.Stderr, "  coordinator stats-migrate [--admin-dsn DSN] [--check]  (SPEC-017 stats/rewards migrations)")
			os.Exit(2)
		}
	}

	configPath := flag.String("config", "coordinator.yaml", "path to coordinator YAML config")
	configOverlay := flag.String("config-overlay", "", "optional YAML overlay merged after --config (overlay keys override)")
	validateConfig := flag.Bool("validate-config", false, "load config (with overlay if set), validate, and exit")
	showVersion := flag.Bool("version", false, "print build version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}

	cfg, err := config.LoadWithOverlay(*configPath, *configOverlay)
	if err != nil {
		fmt.Fprintf(os.Stderr, "config: %v\n", err)
		os.Exit(1)
	}
	if *validateConfig {
		fmt.Println("config: ok")
		return
	}
	autotuneFeeds, err := buyer.LoadAutotuneFeeds(cfg.AutotuneFeeds)
	if err != nil {
		fmt.Fprintf(os.Stderr, "autotune feeds: %v\n", err)
		os.Exit(1)
	}
	var autotuneCatalog *autotune.Catalog
	if len(autotuneFeeds.AutotuneCandidatesJSON) > 0 {
		autotuneCatalog, err = autotune.ParseCatalog(autotuneFeeds.AutotuneCandidatesJSON)
		if err != nil {
			fmt.Fprintf(os.Stderr, "autotune candidate catalog: %v\n", err)
			os.Exit(1)
		}
	}
	providerhttp.Init(cfg.ProviderHTTP.TimeoutS)

	logger := zerolog.New(os.Stdout).With().Timestamp().Logger()
	if err := tier2.Configure(cfg.Tier2, logger); err != nil {
		fmt.Fprintf(os.Stderr, "tier2: %v\n", err)
		os.Exit(1)
	}
	metricsRegistry := prom.NewRegistry()
	metricsHandle := statsmetrics.New(metricsRegistry)
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
	// SPEC-002 v1.4.2 R-2 / ISS-188: request_log.external_request_id
	// is added by OpenStore as an additive column. The matching partial-
	// NULL reconciliation index is NOT auto-built here — the request-log
	// store caps the pool at one writer connection (see
	// requestlog.OpenStore SetMaxOpenConns(1)), so running CREATE INDEX
	// from the daemon would contend with the 6s-timeout INSERT hot
	// path. The index ships via the `coordinator migrate-indexes`
	// subcommand, intended to be invoked once per deploy by the
	// operator runbook before binding traffic (or during a maintenance
	// window).
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
	// R4 fix (CODE-M2): set the route-layer flag atomic BEFORE the
	// startup snapshot so the snapshot's canonical hash captures the
	// initial flag state (SPEC-005 v0.4 §11.6.4 / §13.2). The
	// "startup" source suppresses the billing_config_flag_changed
	// audit emit per SPEC §11.6.4 (no prior acknowledged value).
	if err := billingStore.SetForceVoidEnabled(context.Background(), cfg.Billing.QuarantineResolutionForceVoidEnabled, "startup"); err != nil {
		fmt.Fprintf(os.Stderr, "billing force-void flag init: %v\n", err)
		os.Exit(1)
	}
	if err := billingStore.SetForceCreditEnabled(context.Background(), cfg.Billing.QuarantineResolutionForceCreditEnabled, "startup"); err != nil {
		fmt.Fprintf(os.Stderr, "billing force-credit flag init: %v\n", err)
		os.Exit(1)
	}
	billingStore.SetForceCreditSettlementHoldSeconds(int64(cfg.Billing.ForceCreditSettlementHoldSeconds))
	snapshotID, err := billingStore.InsertConfigSnapshot(context.Background(), cfg.Rewards, time.Now().UTC())
	if err != nil {
		fmt.Fprintf(os.Stderr, "billing config snapshot: %v\n", err)
		os.Exit(1)
	}
	// SPEC-017 v0.1.8 Step 1 — Postgres pools for the Network
	// Stats API. Fail-closed per BUILD §C.3: any missing required
	// runtime DSN or any failed startup smoke aborts coordinator
	// boot BEFORE any HTTP listener binds. When cfg.Stats.Enabled
	// is false (the v0.1 default), Open returns stats.ErrDisabled
	// and the /v1/stats/* mux subtree is NOT registered later;
	// 404 from the existing mux fallback is the correct posture
	// (NOT a custom JSON envelope, which would violate the §5.9
	// closed code vocabulary — BUILD §C.4).
	//
	// The CLI operator DSN (cfg.Stats.PartnerKeysAdminDSN) is
	// declared but INTENTIONALLY NOT OPENED here — the
	// coordinator process should never hold an
	// INSERT-on-partner_keys connection at runtime. Step 4.A's
	// `coordinator partner-keys issue/revoke` subcommands open
	// that DSN at invocation time only. SECURITY §B.1 invariant.
	var statsPools *stats.Pools
	if cfg.Stats.Enabled {
		statsCfg := stats.Config{
			Enabled:             cfg.Stats.Enabled,
			ReaderDSN:           cfg.Stats.ReaderDSN,
			RollupDSN:           cfg.Stats.RollupDSN,
			PartnerKeys:         stats.PartnerKeysConfig{LastUsedAtUpdatesEnabled: cfg.Stats.PartnerKeys.LastUsedAtUpdatesEnabled, WriterDSN: cfg.Stats.PartnerKeys.WriterDSN},
			PartnerKeysAdminDSN: cfg.Stats.PartnerKeysAdminDSN,
			Rollup: stats.RollupConfig{
				BackfillMode:            cfg.Stats.Rollup.BackfillMode,
				PartialHistorySince:     cfg.Stats.Rollup.PartialHistorySince,
				LateEventsRetentionDays: cfg.Stats.Rollup.LateEventsRetentionDays,
				UsdPerMillionCredits:    cfg.Stats.Rollup.UsdPerMillionCredits,
				DriftThresholdRatio:     cfg.Stats.Rollup.DriftThresholdRatio,
				NightlyRebuildHourUTC:   cfg.Stats.Rollup.NightlyRebuildHourUTC,
				LateEventsLookbackHours: cfg.Stats.Rollup.LateEventsLookbackHours,
			},
			CORS: stats.CORSConfig{
				AccessControlMaxAgeSeconds: cfg.Stats.CORS.AccessControlMaxAgeSeconds,
				PartnerOriginAllowlist:     cfg.Stats.CORS.PartnerOriginAllowlist,
			},
			TrustedProxies: cfg.Stats.TrustedProxies,
		}
		var err error
		statsPools, err = stats.Open(context.Background(), statsCfg)
		if err != nil {
			fmt.Fprintf(os.Stderr, "stats: %v\n", err)
			os.Exit(1)
		}
		// MIGRATIONS ARE NOT RUN AT COORDINATOR BOOT (round-1
		// CRITICAL fix across all three lanes: SECURITY r1
		// CRIT-2, CODE r1 HIGH C2, ARCH r1 HIGH C1). The earlier
		// draft applied migrations through the stats_rollup
		// runtime pool with a STATS_SKIP_MIGRATIONS_AT_BOOT=1
		// opt-out — that defaulted to over-privileging the
		// runtime role and made the safe production path a
		// remember-this-env-var footgun. Migrations are now
		// operator-side: invoke `statsmigrations.Apply` from an
		// admin DSN via psql or a follow-up
		// `coordinator stats migrate --admin-dsn=...`
		// subcommand. The integration test harness applies
		// migrations through its own admin DSN.
		logger.Info().Msg("SPEC-017 stats pools opened (reader, rollup); migrations are operator-applied; /v1/stats/* will be mounted by Step 3")
	} else {
		logger.Info().Msg("SPEC-017 stats DISABLED via config (default); /v1/stats/* not registered")
	}
	defer func() {
		if statsPools != nil {
			_ = statsPools.Close()
		}
	}()
	shutdownCtx, stopBackground := context.WithCancel(context.Background())
	defer stopBackground()
	// SPEC-017 v0.1.8 Step 2 — rollup runner. Reads OLTP source
	// tables via `statsPools.Rollup`, writes the seven
	// stats_* + stats_components_health + stats_rewards_populated
	// surfaces, and emits structured drift-detection events. Per
	// SPEC §7.2.5 the rollup MUST NOT use Reader / ProviderPortal
	// pools — `New(statsPools.Rollup, ...)` enforces.
	//
	// poolsnapshot.NewWithHardware wires the live §5.1.1 snapshot fields
	// (nodes_online, nodes_hardware_attested, utilization, RAM,
	// models_serving) from the in-process pool.Registry and enriches
	// hardware capacity from an async stats_rollup-side cache. The
	// snapshot path itself remains memory-only: no DB lookups on buyer,
	// routing, streaming, heartbeat, or public stats request paths.
	var statsRollup *statsrollup.Runner
	if statsPools != nil {
		// Round-1 ARCH r1 HIGH 2 fix: BackfillMode must be the
		// authoritative selector. "full" forces
		// PartialHistorySinceUnix = 0 (the boundary the rollup
		// queries against; 0 = no lower-bound filter); "partial"
		// requires a non-empty partial_history_since and fails
		// startup if it doesn't parse.
		mode := cfg.Stats.Rollup.BackfillMode
		if mode == "" {
			mode = "partial"
		}
		var partialUnix int64
		switch mode {
		case "full":
			partialUnix = 0
		case "partial":
			// Round-2 ARCH r2 HIGH 2 fix: backfill_mode = "partial"
			// requires a non-empty RFC 3339 partial_history_since
			// when stats.enabled = true. Path A semantics demand
			// a rollup-start boundary that Step 3 can emit as
			// the JSON `partial_history_since` field. Empty +
			// partial would silently behave like "full" while
			// leaving Step 3 with no field to emit — two
			// conforming sessions could disagree about which
			// path is in effect. Force the operator to be
			// explicit.
			if cfg.Stats.Rollup.PartialHistorySince == "" {
				fmt.Fprintf(os.Stderr, "stats rollup: stats.rollup.partial_history_since must be non-empty when backfill_mode = 'partial'; use backfill_mode = 'full' for unconstrained history\n")
				os.Exit(1)
			}
			parsed, perr := parseRFC3339Strict(cfg.Stats.Rollup.PartialHistorySince)
			if perr != nil {
				fmt.Fprintf(os.Stderr, "stats rollup: stats.rollup.partial_history_since must parse as RFC 3339 when backfill_mode = 'partial' (got %q): %v\n", cfg.Stats.Rollup.PartialHistorySince, perr)
				os.Exit(1)
			}
			partialUnix = parsed.Unix()
		default:
			fmt.Fprintf(os.Stderr, "stats rollup: stats.rollup.backfill_mode must be 'partial' or 'full' (got %q)\n", mode)
			os.Exit(1)
		}

		rollupCfg := statsrollup.Config{
			BackfillMode:            mode,
			PartialHistorySinceUnix: partialUnix,
			LateEventsRetentionDays: cfg.Stats.Rollup.LateEventsRetentionDays,
			UsdPerMillionCredits:    cfg.Stats.Rollup.UsdPerMillionCredits,
			DriftThresholdRatio:     cfg.Stats.Rollup.DriftThresholdRatio,
			NightlyRebuildHourUTC:   cfg.Stats.Rollup.NightlyRebuildHourUTC,
			LateEventsLookbackHours: cfg.Stats.Rollup.LateEventsLookbackHours,
		}
		hardwareCache := statshardware.NewCache(statsPools.Rollup)
		hardwareCtx, cancelHardwareRefresh := context.WithTimeout(shutdownCtx, 2*time.Second)
		if err := hardwareCache.Refresh(hardwareCtx); err != nil {
			logger.Warn().Err(err).Msg("stats hardware cache initial refresh failed; hardware overview fields will remain zero until refresh succeeds")
		}
		cancelHardwareRefresh()
		hardwareCache.Start(shutdownCtx, func(err error) {
			logger.Warn().Err(err).Msg("stats hardware cache refresh failed; retaining previous hardware snapshot")
		})

		var err error
		statsRollup, err = statsrollup.New(statsPools.Rollup, rollupCfg, poolsnapshot.NewWithHardware(registry, hardwareCache), logger.With().Str("subsystem", "stats_rollup").Logger())
		if err != nil {
			fmt.Fprintf(os.Stderr, "stats rollup: %v\n", err)
			os.Exit(1)
		}
		statsRollup.Start(shutdownCtx)
		logger.Info().Str("backfill_mode", mode).Int64("partial_history_since_unix", partialUnix).Msg("SPEC-017 stats rollup started (overview/timeseries/leaderboards/rewards_populated/nightly_rebuild)")
	}

	// SPEC-MALIBU-EMISSION-LEDGER — bootstrap accrual worker (default-off).
	var rewardsRunner *rewards.Runner
	var rewardsDB *sql.DB
	if strings.TrimSpace(cfg.MalibuEmission.WriterDSN) != "" {
		var err error
		rewardsDB, err = sql.Open("postgres", cfg.MalibuEmission.WriterDSN)
		if err != nil {
			fmt.Fprintf(os.Stderr, "malibu_emission: open writer pool: %v\n", err)
			os.Exit(1)
		}
		rewardsDB.SetMaxOpenConns(4)
		rewardsDB.SetMaxIdleConns(2)
		rewardsDB.SetConnMaxLifetime(5 * time.Minute)
		defer rewardsDB.Close()
	}
	if cfg.MalibuEmission.Enabled {
		if rewardsDB == nil {
			fmt.Fprintf(os.Stderr, "malibu_emission: writer_dsn is required when enabled\n")
			os.Exit(1)
		}
		sqlitePath := strings.TrimSpace(cfg.MalibuEmission.SQLitePayoutDBPath)
		if sqlitePath == "" {
			sqlitePath = cfg.Storage.DBPath
		}
		rewardsCfg := rewards.Config{
			Enabled:                true,
			WriterDSN:              cfg.MalibuEmission.WriterDSN,
			TickInterval:           time.Duration(cfg.MalibuEmission.TickIntervalSeconds) * time.Second,
			ProviderDailyCapMALIBU: cfg.MalibuEmission.ProviderDailyCapMALIBU,
			WalletDailyCapMALIBU:   cfg.MalibuEmission.WalletDailyCapMALIBU,
			SQLitePayoutDBPath:     sqlitePath,
			WalletMirrorInterval:   time.Duration(cfg.MalibuEmission.WalletMirrorIntervalSeconds) * time.Second,
			UnlockEvalInterval:     time.Duration(cfg.MalibuEmission.UnlockEvalIntervalSeconds) * time.Second,
			MaxSerializableRetries: cfg.MalibuEmission.MaxSerializableRetries,
			BaseUSDCBalanceRPCURLs: cfg.MalibuEmission.BaseUSDCBalanceRPCURLs,
		}
		var err error
		rewardsRunner, err = rewards.New(rewardsDB, rewardsCfg, logger.With().Str("subsystem", "malibu_emission").Logger(), rewards.RunnerDeps{})
		if err != nil {
			fmt.Fprintf(os.Stderr, "malibu_emission: %v\n", err)
			os.Exit(1)
		}
		rewardsRunner.Start(shutdownCtx)
		logger.Info().Msg("SPEC-MALIBU-EMISSION-LEDGER accrual runner started")
	} else {
		logger.Info().Msg("malibu_emission DISABLED via config (default)")
	}
	// Round-3 ARCH r3 LOW 2 fix: defers run LIFO, so a non-signal
	// return path would call `Wait()` BEFORE the
	// `stopBackground()` registered earlier — blocking forever on
	// still-running rollup goroutines. Combining cancellation +
	// drain in one defer registered AFTER the rollup is
	// constructed guarantees cancellation always precedes Wait.
	defer func() {
		stopBackground()
		if statsRollup != nil {
			statsRollup.Wait()
		}
	}()
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
	if statsPools != nil {
		wsOpts = append(wsOpts, providerws.WithIdlePrewarmRecorder(statsprewarm.NewRecorder(statsPools.Rollup)))
		wsOpts = append(wsOpts, providerws.WithIdlePrewarmMetrics(metricsHandle))
		wsOpts = append(wsOpts, providerws.WithModelHashMismatchMetrics(metricsHandle))
	}
	var onboardingStore *onboarding.PGStore
	if cfg.Onboarding.AppTrackRegisterEnabled {
		onboardingStore, err = onboarding.OpenPGStoreWithAuthPolicyDSNs(
			cfg.Onboarding.PostgresDSN,
			cfg.Onboarding.AuthPolicyRequestDSN,
			cfg.Onboarding.AuthPolicyApproveDSN,
			cfg.Onboarding.AuthPolicyCutoverDSN,
		)
		if err != nil {
			logger.Fatal().Err(err).Msg("open onboarding postgres store")
		}
		defer onboardingStore.Close()
		if err := onboardingStore.Smoke(context.Background()); err != nil {
			logger.Fatal().Err(err).Msg("onboarding postgres smoke failed")
		}
		wsOpts = append(wsOpts, providerws.WithIdentitySignatureStore(onboardingStore))
		wsOpts = append(wsOpts, providerws.WithProviderAuthPolicyAdminStore(onboardingStore))
	}
	if cfg.ProofOfWeights.RequireAutotuneHelloGate {
		if autotuneCatalog == nil {
			logger.Fatal().Msg("proof_of_weights.require_autotune_hello_gate requires autotune candidate catalog feeds")
		}
		if onboardingStore == nil || onboardingStore.DB() == nil {
			logger.Fatal().Msg("proof_of_weights.require_autotune_hello_gate requires onboarding postgres store")
		}
		wsOpts = append(wsOpts, providerws.WithAutotuneHelloGate(autotuneCatalog, autotune.NewPGEvidenceStore(onboardingStore.DB())))
		logger.Info().
			Int("autotune_evidence_ttl_days", cfg.ProofOfWeights.AutotuneEvidenceTTLDays).
			Str("autotune_catalog_version", autotuneCatalog.Version).
			Msg("proof-of-weights autotune hello gate enabled")
	}
	if cfg.ProofOfWeights.TelemetryDrift.Enabled {
		if autotuneCatalog == nil {
			logger.Fatal().Msg("proof_of_weights.telemetry_drift.enabled requires autotune candidate catalog feeds")
		}
		if onboardingStore == nil || onboardingStore.DB() == nil {
			logger.Fatal().Msg("proof_of_weights.telemetry_drift.enabled requires onboarding postgres store")
		}
		driftCfg, err := pow.TelemetryDriftConfigFrom(
			true,
			cfg.ProofOfWeights.TelemetryDrift.TPSRatioThreshold,
			cfg.ProofOfWeights.TelemetryDrift.TPSMinAbsolute,
			cfg.ProofOfWeights.TelemetryDrift.TPSMinRequestsWindow,
			cfg.ProofOfWeights.TelemetryDrift.HashAlertOnStatus,
			cfg.ProofOfWeights.TelemetryDrift.HashAlertOnArtifactDrift,
			cfg.ProofOfWeights.TelemetryDrift.OPoIPassRateWindow,
			cfg.ProofOfWeights.TelemetryDrift.OPoIPassRateThreshold,
			cfg.ProofOfWeights.TelemetryDrift.AlertCooldownSeconds,
		)
		if err != nil {
			logger.Fatal().Err(err).Msg("proof_of_weights.telemetry_drift config invalid")
		}
		evidenceStore := autotune.NewPGEvidenceStore(onboardingStore.DB())
		ttl := time.Duration(cfg.ProofOfWeights.AutotuneEvidenceTTLDays) * 24 * time.Hour
		wsOpts = append(wsOpts, providerws.WithTelemetryDriftEvaluator(pow.NewEvaluator(driftCfg, autotuneCatalog, evidenceStore, ttl)))
		logger.Info().
			Float64("tps_ratio_threshold", driftCfg.TPSRatioThreshold).
			Int("tps_min_requests_window", driftCfg.TPSMinRequestsWindow).
			Int("opoi_pass_rate_window", driftCfg.OPoIPassRateWindow).
			Msg("proof-of-weights telemetry drift alerts enabled")
	}
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
	if rewardsRunner != nil {
		rewardsRunner.SetConnectivity(rewards.NewPoolHeartbeatBridge(wsServer.PoolSnapshot))
	}
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
		buyer.WithTrustedProxies(mustParseTrustedProxies(cfg, logger)),
		buyer.WithInternalAuthKey(cfg.Auth.OperatorKey),
		buyer.WithGatewayServiceToken(cfg.Auth.GatewayServiceToken),
		buyer.WithRequireGatewayContext(cfg.Coordinator.RequireGatewayContext),
		buyer.WithRelay(wsServer.DispatchInference, time.Duration(cfg.Routing.RequestTimeoutS)*time.Second),
		buyer.WithSettlementRelay(wsServer.DispatchInferenceWithSettlement),
		buyer.WithAdmission(wsServer.Admission(), cfg.Admission.ProvisionalTierWeight),
		buyer.WithRequestLog(reqLogStore),
		buyer.WithBilling(billingStore, cfg.Rewards),
		buyer.WithBillingSnapshotID(snapshotID),
		buyer.WithRateCardUSDPerMillionCredits(cfg.Stats.Rollup.UsdPerMillionCredits),
		buyer.WithAutotuneFeeds(autotuneFeeds),
		buyer.WithStreamingMetricsMaxSamples(cfg.Stats.StreamingMetrics.MaxSamples),
		buyer.WithPreflight(func(provider pool.Provider, requestID string, estimatedTokens int, timeout time.Duration) (buyer.PreflightResult, bool, error) {
			ack, ok, err := wsServer.Preflight(provider, requestID, estimatedTokens, timeout)
			return buyer.PreflightResult{Accepted: ack.Accepted, Reason: ack.Reason}, ok, err
		}),
	)
	providerAddr := listenAddress(cfg.Listen.BindAddress, cfg.Listen.ProviderPort)
	buyerAddr := listenAddress(cfg.Listen.BindAddress, cfg.Listen.BuyerPort)
	providerMux := http.NewServeMux()
	providerMux.Handle("/", wsServer.Handler())
	providerMux.Handle("/internal/", buyerServer.InternalHandler())
	// SPEC-005 v0.4 (issue #169) — `billing.quarantine_resolution_force_void_enabled`
	// gates the §11.6 force-void endpoint at the route layer. Default
	// false: endpoint returns HTTP 404 until the operator explicitly
	// flips the flag via the existing config-reload primitive.
	// The flag is held as an atomic on billingStore; SIGHUP reload
	// calls billingStore.SetForceVoidEnabled which emits the
	// `billing_config_flag_changed` audit event on real flips.
	var idlePrewarmReader *statsprewarm.Reader
	if statsPools != nil {
		idlePrewarmReader = statsprewarm.NewReader(statsPools.Reader)
	}
	billingHandler := billingStore.HandlersWithQuarantineGatesAndIdlePrewarm(
		cfg.Auth.OperatorKey,
		tokenStore,
		cfg.Auth.RequireProviderTokens,
		cfg.Endpoints.ProviderEarnings.RateLimitPerMinute,
		cfg.Billing.QuarantineResolutionForceVoidEnabled,
		cfg.Billing.QuarantineResolutionForceCreditEnabled,
		idlePrewarmReader,
	)
	// §11.5 launch-gate item 10 — operator-visible startup state.
	logger.Info().
		Bool("billing.quarantine_resolution_force_void_enabled", cfg.Billing.QuarantineResolutionForceVoidEnabled).
		Bool("billing.quarantine_resolution_force_credit_enabled", cfg.Billing.QuarantineResolutionForceCreditEnabled).
		Int("billing.force_credit_settlement_hold_seconds", cfg.Billing.ForceCreditSettlementHoldSeconds).
		Str("event", "spec005_v0_4_route_layer_flag_init").
		Msg("quarantine force-void route-layer flag initialized")
	providerMux.Handle("/admin/ledger/", billingHandler)
	if rewardsDB != nil {
		providerMux.Handle("/admin/trust-promotion/", rewards.TrustPromotionMux(rewards.TrustAdminDeps{
			DB:           rewardsDB,
			OperatorKeys: cfg.Auth.OperatorKeys,
		}))
	}
	if cfg.Auth.RequireProviderTokens {
		providerMux.Handle("/providers/", billingHandler)
	}

	// SPEC-017 v0.1.8 Step 3 — /v1/stats/* mux subtree. Mounts
	// only when stats.enabled = true. The handler stack uses
	// the stats_reader pool exclusively (no admin DSN, no
	// rollup pool). Per BUILD §2 Step 3 the same binary serves
	// both coordinator.streamvc.live/v1/stats/* and
	// stats.streamvc.live/v1/stats/*; nginx vhost config
	// (Step 4.B) routes both to this provider port.
	if statsPools != nil {
		// SPEC-017 v0.1.8 Step 4.C — Prometheus metrics. The
		// coordinator owns its own registry (not the global
		// DefaultRegisterer) so concurrent test runs don't
		// double-register. SPEC-026 adds /admin/metrics below;
		// /metrics remains as a loopback-compatible alias only.
		statsHandler := stats.NewMuxWithMetricsAndRateLimit(
			statsstore.New(statsPools.Reader),
			stats.CORSConfig{
				AccessControlMaxAgeSeconds: cfg.Stats.CORS.AccessControlMaxAgeSeconds,
				PartnerOriginAllowlist:     cfg.Stats.CORS.PartnerOriginAllowlist,
			},
			cfg.Stats.Rollup.BackfillMode,
			cfg.Stats.Rollup.PartialHistorySince,
			cfg.Stats.TrustedProxies,
			logger.With().Str("subsystem", "stats_handlers").Logger(),
			metricsHandle,
			stats.RateLimitConfig{
				MaxBuckets:   cfg.Stats.RateLimit.MaxBuckets,
				IdleTTL:      time.Duration(cfg.Stats.RateLimit.IdleTTLSeconds) * time.Second,
				PreflightRPM: cfg.Stats.RateLimit.PreflightRPM,
			},
		).Handler()
		providerMux.Handle("/v1/stats/", statsHandler)
		providerMux.Handle("/metrics", promhttp.HandlerFor(metricsRegistry, promhttp.HandlerOpts{}))
		logger.Info().Msg("SPEC-017 stats handlers + /metrics mounted on provider port")

		// Wire rollup lag observation periodically — gauge value
		// = now - stats_components_health.generated_at per
		// component. Background goroutine; cancelled with
		// shutdownCtx.
		if statsRollup != nil {
			statsRollup.WithMetrics(metricsHandle)
			go observeRollupLag(shutdownCtx, statsPools.Reader, metricsHandle, logger)
		}
	}
	providerMux.Handle("/admin/metrics", operatorMetricsHandler(cfg.Auth.OperatorKey, metricsRegistry))

	var register http.HandlerFunc
	var hardwareEvidence http.HandlerFunc
	if cfg.Onboarding.AppTrackRegisterEnabled {
		asnResolver, err := onboarding.NewStaticASNResolver(cfg.Onboarding.ASNPrefixes)
		if err != nil {
			logger.Fatal().Err(err).Msg("onboarding ASN resolver config invalid")
		}
		registerHandler := &onboarding.Handler{
			StatsDB:                             onboardingStore,
			AuthTokenStore:                      tokenStore,
			CoordinatorDomain:                   cfg.Onboarding.CoordinatorDomain,
			CoordinatorWSURL:                    "wss://" + cfg.Onboarding.CoordinatorDomain + "/v2/provider",
			TrustedProxies:                      mustParseTrustedProxies(cfg, logger),
			IPRateLimiter:                       onboarding.NewMemoryRateLimiter(5, time.Minute),
			ASNRateLimiter:                      onboarding.NewMemoryRateLimiter(30, time.Minute),
			ASNResolver:                         asnResolver,
			HardwareEvidenceIPRateLimiter:       onboarding.NewMemoryRateLimiter(10, time.Minute),
			HardwareEvidenceProviderRateLimiter: onboarding.NewMemoryRateLimiter(1, 10*time.Minute),
			AppAttestVerifier: onboarding.AppleAppAttestVerifier{
				Config: onboarding.AppAttestConfig{
					CoordinatorDomain: cfg.Onboarding.CoordinatorDomain,
					BundleID:          cfg.Onboarding.BundleID,
					TeamID:            cfg.Onboarding.AppleTeamID,
				},
			},
			Metrics: metricsHandle,
			AppAttestConfig: onboarding.AppAttestConfig{
				CoordinatorDomain: cfg.Onboarding.CoordinatorDomain,
				BundleID:          cfg.Onboarding.BundleID,
				TeamID:            cfg.Onboarding.AppleTeamID,
			},
		}
		register = registerHandler.HandleAppTrackRegister
		hardwareEvidence = registerHandler.HandleHardwareEvidence
		logger.Info().Msg("SPEC-026 app-track register route mounted on buyer port")
	}
	// Phase 2 Track P2-A: MDM enrollment profile endpoint.
	// Enabled when tier2.mdm.enrollment_base_url is configured.
	var enrollHandler http.HandlerFunc
	if cfg.Tier2.MDM.EnrollmentBaseURL != "" {
		eh := buildEnrollHandler(cfg, logger)
		enrollHandler = eh.HandleEnroll
		logger.Info().
			Str("base_url", cfg.Tier2.MDM.EnrollmentBaseURL).
			Msg("MDM enrollment profile route mounted on buyer port (/v1/enroll)")
	}
	buyerHandler := buyerHandlerWithOptionalProviderEndpoints(
		buyerServer.Handler(),
		cfg.Onboarding.AppTrackRegisterEnabled,
		register,
		hardwareEvidence,
		enrollHandler,
		malibuAccrualHandler(cfg, tokenStore, rewardsDB, rewards.NewPoolHeartbeatBridge(wsServer.PoolSnapshot)),
	)

	providerHTTP := newHTTPServer(providerAddr, providerMux)
	buyerHTTP := newHTTPServer(buyerAddr, buyerHandler)
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

// mustParseTrustedProxies parses cfg.Proxy.TrustedProxies into the
// netip.Prefix slice the buyer Server's rate-limit keying expects.
// Validate() at config.Load already rejected malformed CIDRs and
// default-route prefixes, so this helper should never fail in
// practice. If it DOES fail post-Validate (drift between Validate
// and TrustedProxyPrefixes, e.g. a future contributor splits the
// validation), the architect-lane r1 audit (issue #125 L3) called
// out the prior silent-nil fallback as a weakening of the
// validation contract — a proxied-clients-collapse bug masquerading
// as a non-event. Fail-fast at startup instead. Issue #125.
func mustParseTrustedProxies(cfg config.Config, logger zerolog.Logger) []netip.Prefix {
	prefixes, err := cfg.TrustedProxyPrefixes()
	if err != nil {
		logger.Fatal().Err(err).Msg("trusted_proxies parse failed at startup")
	}
	return prefixes
}

func setupCanarySanctionStore(ctx context.Context, cfg config.Config, db *sql.DB, registry *pool.Registry) (providerws.CanarySanctionStore, error) {
	store, err := providerws.NewSQLiteCanarySanctionStore(db)
	if err != nil {
		return nil, err
	}
	if !cfg.Pool.CanaryEnabled {
		// Keep the store wired so an authenticated operator recovery can delete
		// durable sanctions while probes are disabled. Do not load sanctions
		// into the registry until canaries are enabled again.
		return store, nil
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

func newHTTPServer(addr string, handler http.Handler) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       310 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
}

func listenAddress(host string, port int) string {
	return net.JoinHostPort(host, strconv.Itoa(port))
}

func operatorMetricsHandler(operatorKey string, registry *prom.Registry) http.Handler {
	metrics := promhttp.HandlerFor(registry, promhttp.HandlerOpts{})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !auth.OperatorOnlyBearerMatches(r.Header, operatorKey) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"error":{"code":"unauthorized","message":"operator bearer token required"}}` + "\n"))
			return
		}
		metrics.ServeHTTP(w, r)
	})
}

func buyerHandlerWithOptionalProviderEndpoints(base http.Handler, enabled bool, register, hardwareEvidence, enroll http.HandlerFunc, malibuAccrual http.Handler) http.Handler {
	mux := http.NewServeMux()
	if enabled {
		mux.HandleFunc("/v1/providers/register", register)
		mux.HandleFunc("/v1/providers/hardware-evidence", hardwareEvidence)
	}
	mux.HandleFunc("/v1/provider/wallet", appTrackWalletNotImplementedHandler)
	if enroll != nil {
		mux.HandleFunc("/v1/enroll", enroll)
	}
	if malibuAccrual != nil {
		mux.Handle("/v1/provider/malibu-accrual", malibuAccrual)
	}
	mux.Handle("/", base)
	return mux
}

// buildEnrollHandler constructs the MDM enrollment handler for POST /v1/enroll.
// Called only when tier2.mdm.enrollment_base_url is configured.
func buildEnrollHandler(cfg config.Config, logger zerolog.Logger) *onboarding.EnrollHandler {
	mdmCfg := cfg.Tier2.MDM
	eh := &onboarding.EnrollHandler{
		MDMConfig: mdm.Config{
			EnrollmentBaseURL: mdmCfg.EnrollmentBaseURL,
			MDMServerURL:      mdmCfg.MDMServerURL,
			SCEPUrl:           mdmCfg.SCEPUrl,
			PushTopic:         mdmCfg.PushTopic,
		},
		Logger: logger,
	}
	if mdmCfg.ProfileSignerCertPath != "" && mdmCfg.ProfileSignerKeyPath != "" {
		signer, err := onboarding.NewFileProfileSigner(mdmCfg.ProfileSignerCertPath, mdmCfg.ProfileSignerKeyPath)
		if err != nil {
			logger.Error().Err(err).
				Str("cert_path", mdmCfg.ProfileSignerCertPath).
				Str("key_path", mdmCfg.ProfileSignerKeyPath).
				Msg("MDM profile signer init failed — profiles will be served unsigned")
		} else {
			eh.Signer = signer
			logger.Info().Msg("MDM enrollment profile CMS signer loaded")
		}
	}
	return eh
}

func malibuAccrualHandler(cfg config.Config, tokenStore *auth.Store, rewardsDB *sql.DB, connectivity rewards.ProviderConnectivity) http.Handler {
	if rewardsDB == nil {
		return nil
	}
	rewardsCfg := rewards.Config{
		ProviderDailyCapMALIBU: cfg.MalibuEmission.ProviderDailyCapMALIBU,
		WalletDailyCapMALIBU:   cfg.MalibuEmission.WalletDailyCapMALIBU,
		SQLitePayoutDBPath:     cfg.MalibuEmission.SQLitePayoutDBPath,
	}
	if rewardsCfg.SQLitePayoutDBPath == "" {
		rewardsCfg.SQLitePayoutDBPath = cfg.Storage.DBPath
	}
	return rewards.NewAccrualHandler(rewards.AccrualHandlerDeps{
		DB:                    rewardsDB,
		TokenStore:            tokenStore,
		RequireProviderTokens: cfg.Auth.RequireProviderTokens,
		Config:                rewardsCfg,
		Connectivity:          connectivity,
	})
}

func appTrackWalletNotImplementedHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusMethodNotAllowed)
		_, _ = w.Write([]byte(`{"error":"method_not_allowed"}` + "\n"))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusNotImplemented)
	_, _ = w.Write([]byte(`{"error":"wallet_change_requires_spec_027"}` + "\n"))
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
		// R3 fix (ARCH-H1): snapshot + flag-change audit + in-memory
		// publish are now ONE atomic operation in
		// billing.Store.ReloadBillingConfig. If COMMIT fails, the
		// snapshot is not written, the flag-change audit is not
		// written, and the force-void flag stays at its prior value.
		// Only AFTER COMMIT do we publish the rewards / settlement
		// in-memory configs that depend on the snapshot id.
		snapshotID, err := billingStores[0].ReloadBillingConfigV05(
			context.Background(),
			cfg.Rewards,
			cfg.Billing.QuarantineResolutionForceVoidEnabled,
			cfg.Billing.QuarantineResolutionForceCreditEnabled,
			int64(cfg.Billing.ForceCreditSettlementHoldSeconds),
			"sighup",
			time.Now().UTC(),
		)
		if err != nil {
			logger.Error().Err(err).Msg("billing config reload rejected (snapshot + flag audit atomic)")
			return
		}
		buyerServer.SetBillingConfig(cfg.Rewards, snapshotID, cfg.Stats.Rollup.UsdPerMillionCredits)
		billingStores[0].SetSettlementConfig(cfg.Settlement)
		logger.Info().
			Bool("billing.quarantine_resolution_force_void_enabled", cfg.Billing.QuarantineResolutionForceVoidEnabled).
			Bool("billing.quarantine_resolution_force_credit_enabled", cfg.Billing.QuarantineResolutionForceCreditEnabled).
			Int("billing.force_credit_settlement_hold_seconds", cfg.Billing.ForceCreditSettlementHoldSeconds).
			Str("event", "spec005_v0_4_route_layer_flag_reload").
			Msg("quarantine force-void route-layer flag reloaded")
	}
	updated := wsServer.RefreshTier2HashStatuses()
	logger.Info().Int("provider_hash_statuses_updated", updated).Msg("tier2 config reloaded")
	// Issue #266 T1 — wire SPEC-004 FR-SR-5 paragraph 2 ("invalidate
	// on class reconfig"): swap the buyer-server's routing.model_classes
	// snapshot and purge sticky-affinity entries for any class whose
	// membership shape changed. Default-OFF posture preserved: when
	// model_classes is unset / unchanged the call returns 0 changes.
	changed, invalidated := buyerServer.SetRoutingClasses(cfg.Routing.ModelClasses)
	if len(changed) > 0 {
		logger.Info().
			Strs("changed_classes", changed).
			Int("sticky_entries_invalidated", invalidated).
			Str("event", "spec004_fr_sr_5_class_reload").
			Msg("routing.model_classes reload: shape changed; sticky entries invalidated")
	}
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
	"SELivenessIntervalS":             tier2HotReloadable,
	"SELivenessTimeoutS":              tier2HotReloadable,
	"SELivenessMaxFailures":           tier2HotReloadable,
	"BehavioralSafetyEnabled":        tier2HotReloadable,
	"OutputSizeCapBytes":             tier2HotReloadable,
	"OutputBytesPerTokenCeiling":     tier2HotReloadable,
	"DefaultOutputSizeCapBytes":      tier2HotReloadable,
	"EncodingValidationEnabled":      tier2HotReloadable,
	"ResponseTimeAnomalyEnabled":     tier2HotReloadable,
	"ResponseTimeAnomalyFactor":      tier2HotReloadable,
	"ResponseTimeAnomalyMinMS":       tier2HotReloadable,
	// MDM enrollment config — startup-only: changing push cert or SCEP
	// settings mid-flight would invalidate already-issued profiles.
	"MDM": tier2StartupOnly,
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

// observeRollupLag periodically updates the
// stats_rollup_lag_seconds gauge per §9.5 component, reading
// each component's generated_at from stats_components_health.
// Runs at a 15s cadence; cancelled when ctx.Done() fires.
//
// Read-only via the reader pool — does NOT contend with the
// rollup writer pool.
//
// Round-3 ARCH r3 MEDIUM 1 / CODE r3 MEDIUM 2 fix: the per-tick
// SQL pass moved into `statsrollup.ObserveRollupLagOnce` so the
// Step 4.C wired-mux hygiene test can drive the gauge through the
// same production code path instead of a synthetic Set() call.
func observeRollupLag(ctx context.Context, readerDB *sql.DB, m *statsmetrics.Metrics, logger zerolog.Logger) {
	tick := time.NewTicker(15 * time.Second)
	defer tick.Stop()
	_ = logger // keep import used; no per-tick log line
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			statsrollup.ObserveRollupLagOnce(ctx, readerDB, m)
		}
	}
}
