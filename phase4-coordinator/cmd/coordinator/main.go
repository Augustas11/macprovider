package main

import (
	"context"
	"database/sql"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"path/filepath"
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
	"github.com/augstar/macprovider-coordinator/internal/catalogbind"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/explorer"
	"github.com/augstar/macprovider-coordinator/internal/mdm"
	"github.com/augstar/macprovider-coordinator/internal/onboarding"
	"github.com/augstar/macprovider-coordinator/internal/payout"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/pow"
	"github.com/augstar/macprovider-coordinator/internal/providerevents"
	"github.com/augstar/macprovider-coordinator/internal/providerhttp"
	"github.com/augstar/macprovider-coordinator/internal/referralapi"
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
	var autotuneCompatibleCatalogs []*autotune.Catalog
	if len(autotuneFeeds.AutotuneCandidatesJSON) > 0 {
		autotuneCatalog, err = autotune.ParseCatalog(autotuneFeeds.AutotuneCandidatesJSON)
		if err != nil {
			fmt.Fprintf(os.Stderr, "autotune candidate catalog: %v\n", err)
			os.Exit(1)
		}
		if autotune.IsPermanentlyRejectedReleaseID(autotuneCatalog.Version) {
			fmt.Fprintf(os.Stderr, "autotune candidate catalog: release ID %q is permanently rejected\n", autotuneCatalog.Version)
			os.Exit(1)
		}
		autotuneCatalog.SignerKeyID = autotuneFeeds.AutotuneCandidatesVerification.KeyID
		autotuneCompatibleCatalogs, err = loadPreviousAutotuneCatalog(cfg.AutotuneFeeds)
		if err != nil {
			fmt.Fprintf(os.Stderr, "autotune previous catalog: %v\n", err)
			os.Exit(1)
		}
	}
	providerhttp.Init(cfg.ProviderHTTP.TimeoutS)

	logger := zerolog.New(os.Stdout).With().Timestamp().Logger()
	compatibilityPolicyMode := "unconfigured"
	if cfg.Coordinator.CompatibilitySet.Configured() {
		compatibilityPolicyMode = "configured"
	}
	logger.Info().
		Str("compatibility_policy", compatibilityPolicyMode).
		Str("recommended_compatibility_set_id", cfg.Coordinator.CompatibilitySet.TargetID).
		Int("accepted_compatibility_set_count", len(cfg.Coordinator.CompatibilitySet.AcceptedIDs)).
		Int("first_hop_bridge_set_count", len(cfg.Coordinator.CompatibilitySet.FirstHopBridgeIDs)).
		Msg("provider compatibility-set admission policy initialized")
	if err := tier2.Configure(cfg.Tier2, logger); err != nil {
		fmt.Fprintf(os.Stderr, "tier2: %v\n", err)
		os.Exit(1)
	}
	// #608 Partial: fail closed when active Tier-2 rows conflict with the
	// current autotune admission identity for the same model_id. Does not
	// introduce a Tier-2 fallback (Entry 170 / #609); only rejects drift.
	if err := catalogbind.RequireActiveReleaseBinding(autotuneCatalog, tier2.Default()); err != nil {
		fmt.Fprintf(os.Stderr, "catalog binding: %v\n", err)
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
	connectionEventStore, err := providerevents.Open(providerevents.DefaultDBPath(cfg.Storage.DBPath))
	if err != nil {
		fmt.Fprintf(os.Stderr, "provider connection events storage: %v\n", err)
		os.Exit(1)
	}
	defer connectionEventStore.Close()
	if err := connectionEventStore.ReconcileBounds(context.Background()); err != nil {
		fmt.Fprintf(os.Stderr, "provider connection events reconcile: %v\n", err)
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
	var grandfatherBefore *time.Time
	if raw := strings.TrimSpace(cfg.Referrals.GrandfatherBefore); raw != "" && cfg.Referrals.RequireForRegistration {
		parsed, err := time.Parse(time.RFC3339, raw)
		if err != nil {
			logger.Fatal().Err(err).Msg("parse referral grandfather cutoff")
		}
		grandfatherBefore = &parsed
	}
	referralPolicy := auth.ReferralPolicy{
		RequireForRegistration:  cfg.Referrals.RequireForRegistration,
		EnableSocialBonus:       cfg.Referrals.EnableSocialInviteBonus,
		Campaign:                cfg.Referrals.Campaign,
		PolicyVersion:           cfg.Referrals.PolicyVersion,
		GrandfatherBefore:       grandfatherBefore,
		CurrentKeyID:            cfg.Referrals.CurrentKeyID,
		HMACKeys:                cfg.Referrals.HMACKeys,
		ProviderBaseUses:        cfg.Referrals.ProviderBaseUses,
		SocialBonusUses:         cfg.Referrals.SocialBonusUses,
		ChallengeTTL:            time.Duration(cfg.Referrals.ChallengeTTLS) * time.Second,
		SocialVerificationDwell: time.Duration(cfg.Referrals.SocialVerificationDwellS) * time.Second,
	}
	wsOpts = append(wsOpts, providerws.WithVersion(version))
	wsOpts = append(wsOpts, providerws.WithReferralPolicy(referralPolicy))
	wsOpts = append(wsOpts, providerws.WithAdmissionStore(admissionStore))
	wsOpts = append(wsOpts, providerws.WithConnectionEventStore(connectionEventStore))
	wsOpts = append(wsOpts, providerws.WithConnectionEventMetrics(metricsHandle))
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
	wsOpts = append(wsOpts, providerws.WithBootstrapTokenStore(tokenStore))
	wsOpts = append(wsOpts, providerws.WithGitHubAuthStore(tokenStore))
	// Issue #585: request, dual-control approval, one-shot consumption,
	// admission-key CAS, and recovery audit share the token store's SQLite
	// transaction boundary. Generic Postgres signature exemptions are never
	// recovery authority.
	wsOpts = append(wsOpts, providerws.WithAdmissionIdentityRecoveryAdminStore(tokenStore))
	// Issue #764 tripwire. Deliberately OUTSIDE the statsPools branch: the
	// capacity ceiling is always active, so its counter must always be wired —
	// a coordinator without a stats database must not silently lose the signal.
	wsOpts = append(wsOpts, providerws.WithCapacityOverClaimMetrics(metricsHandle))
	if statsPools != nil {
		wsOpts = append(wsOpts, providerws.WithIdlePrewarmRecorder(statsprewarm.NewRecorder(statsPools.Rollup)))
		wsOpts = append(wsOpts, providerws.WithIdlePrewarmMetrics(metricsHandle))
		wsOpts = append(wsOpts, providerws.WithModelHashMismatchMetrics(metricsHandle))
		wsOpts = append(wsOpts, providerws.WithCredentialBootstrapMetrics(metricsHandle))
	}
	if autotuneCatalog != nil {
		bridgeDeadline, err := cfg.AutotuneFeeds.ProviderAdmissionBridgeDeadlineTime()
		if err != nil {
			logger.Fatal().Err(err).Msg("parse provider catalog admission bridge deadline")
		}
		wsOpts = append(wsOpts,
			providerws.WithAutotuneCatalog(autotuneCatalog, autotuneCompatibleCatalogs...),
			providerws.WithAutotuneCatalogEnforcement(cfg.AutotuneFeeds.EnforceProviderAdmission, bridgeDeadline),
		)
		catalogLog := logger.Info().
			Str("autotune_catalog_version", autotuneCatalog.Version).
			Int("autotune_compatible_previous_releases", len(autotuneCompatibleCatalogs)).
			Str("autotune_catalog_signer_key_id", autotuneCatalog.SignerKeyID).
			Bool("autotune_provider_admission_enforced", cfg.AutotuneFeeds.EnforceProviderAdmission)
		if !cfg.AutotuneFeeds.EnforceProviderAdmission {
			catalogLog = catalogLog.
				Time("autotune_provider_admission_bridge_deadline", bridgeDeadline).
				Dur("autotune_provider_admission_bridge_remaining", time.Until(bridgeDeadline))
		}
		catalogLog.Msg("provider catalog compatibility enabled")
	}
	var onboardingStore *onboarding.PGStore
	if shouldOpenOnboardingStore(cfg.Onboarding) {
		if cfg.Onboarding.AppTrackRegisterEnabled {
			onboardingStore, err = onboarding.OpenPGStoreWithAuthPolicyDSNs(
				cfg.Onboarding.PostgresDSN,
				cfg.Onboarding.AuthPolicyRequestDSN,
				cfg.Onboarding.AuthPolicyApproveDSN,
				cfg.Onboarding.AuthPolicyCutoverDSN,
				cfg.Onboarding.HardwareTrustRequestDSN,
				cfg.Onboarding.HardwareTrustApproveDSN,
			)
		} else {
			// Keep the primary authority available to reconcile referral mints
			// created before an operator disabled the public registration route.
			onboardingStore, err = onboarding.OpenPGStore(cfg.Onboarding.PostgresDSN)
		}
		if err != nil {
			logger.Fatal().Err(err).Msg("open onboarding postgres store")
		}
		defer onboardingStore.Close()
		if err := onboardingStore.Smoke(context.Background()); err != nil {
			logger.Fatal().Err(err).Msg("onboarding postgres smoke failed")
		}
		if cfg.Onboarding.AppTrackRegisterEnabled {
			wsOpts = append(wsOpts, providerws.WithIdentitySignatureStore(onboardingStore))
			wsOpts = append(wsOpts, providerws.WithProviderAuthPolicyAdminStore(onboardingStore))
			wsOpts = append(wsOpts, providerws.WithHardwareTrustAdminStore(onboardingStore))
		}
	}
	var autotuneEvidenceStore autotune.EvidenceStore
	if autotuneCatalog != nil && onboardingStore != nil && onboardingStore.DB() != nil {
		autotuneEvidenceStore = autotune.NewPGEvidenceStore(onboardingStore.DB())
		wsOpts = append(wsOpts, providerws.WithAutotuneEvidenceStore(autotuneEvidenceStore))
	}
	if autotuneEvidenceStore != nil && cfg.ProofOfWeights.AutotuneEvidenceTTLDays > 0 {
		logger.Info().
			Int("autotune_evidence_ttl_days", cfg.ProofOfWeights.AutotuneEvidenceTTLDays).
			Str("autotune_catalog_version", autotuneCatalog.Version).
			Msg("proof-of-weights admission cap observation enabled")
	} else if autotuneEvidenceStore != nil {
		logger.Info().
			Int("autotune_evidence_ttl_days", cfg.ProofOfWeights.AutotuneEvidenceTTLDays).
			Msg("proof-of-weights admission cap observation disabled because evidence TTL is not positive")
	}
	if cfg.ProofOfWeights.RequireAutotuneHelloGate {
		if autotuneCatalog == nil {
			logger.Fatal().Msg("proof_of_weights.require_autotune_hello_gate requires autotune candidate catalog feeds")
		}
		if onboardingStore == nil || onboardingStore.DB() == nil {
			logger.Fatal().Msg("proof_of_weights.require_autotune_hello_gate requires onboarding postgres store")
		}
		if autotuneEvidenceStore == nil {
			autotuneEvidenceStore = autotune.NewPGEvidenceStore(onboardingStore.DB())
		}
		wsOpts = append(wsOpts, providerws.WithAutotuneHelloGate(autotuneCatalog, autotuneEvidenceStore))
		// Issue #582 FIX A/B: active-session trust enforcement (bounded
		// revalidation sweep + advisory-locked registration re-check) rides the
		// same provider_onboarding handle and is wired alongside the admission
		// trust join so it is active exactly when the hello gate is.
		wsOpts = append(wsOpts, providerws.WithProviderTrustChecker(onboardingStore))
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
			cfg.ProofOfWeights.TelemetryDrift.QuarantineMissingBenchmark,
		)
		if err != nil {
			logger.Fatal().Err(err).Msg("proof_of_weights.telemetry_drift config invalid")
		}
		if autotuneEvidenceStore == nil {
			autotuneEvidenceStore = autotune.NewPGEvidenceStore(onboardingStore.DB())
		}
		ttl := time.Duration(cfg.ProofOfWeights.AutotuneEvidenceTTLDays) * 24 * time.Hour
		wsOpts = append(wsOpts, providerws.WithTelemetryDriftEvaluator(pow.NewEvaluator(driftCfg, autotuneCatalog, autotuneEvidenceStore, ttl)))
		logger.Info().
			Float64("tps_ratio_threshold", driftCfg.TPSRatioThreshold).
			Int("tps_min_requests_window", driftCfg.TPSMinRequestsWindow).
			Int("opoi_pass_rate_window", driftCfg.OPoIPassRateWindow).
			Bool("quarantine_missing_benchmark", driftCfg.QuarantineMissingBenchmark).
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
		buyer.WithModelVersionFloors(cfg.CoordinatorAdvertisedVersion.PerModelRequiredBinaryVersion),
		buyer.WithLimitsConfig(cfg.Limits),
		buyer.WithTrustedProxies(mustParseTrustedProxies(cfg, logger)),
		buyer.WithOperatorKey(cfg.Auth.OperatorKey),
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
	// SPEC-005 vX.Y+1 §9.5b — the `/admin/ledger/payout-ready`
	// reorg-compensation endpoint caps provider_credits at the same
	// immutable §5.2 per-payout ceiling the runner enforces
	// (payout.security.per_payout_cap_usdc_base_units). payout.security.*
	// is not live-reloaded, so the cap is threaded in as a scalar here.
	billingHandler := billingStore.HandlersWithQuarantineGatesIdlePrewarmAndPayoutCap(
		cfg.Auth.OperatorKey,
		tokenStore,
		cfg.Auth.RequireProviderTokens,
		cfg.Endpoints.ProviderEarnings.RateLimitPerMinute,
		cfg.Billing.QuarantineResolutionForceVoidEnabled,
		cfg.Billing.QuarantineResolutionForceCreditEnabled,
		idlePrewarmReader,
		cfg.Payout.Security.PerPayoutCapUSDCBaseUnits,
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
		// #165 R1 architect HIGH closure: drive the chronic-outage
		// Evaluate on a window-internal cadence independent of the
		// runner ticker. RunInterval can be up to 24h per §6.5 but
		// the tracker window defaults to 10min, so per-cycle Evaluate
		// would prune samples before observing them. Run() ticks at
		// min(window/2, 1min).
		if payoutS2.chronic != nil {
			go payoutS2.chronic.Run(shutdownCtx)
		}
		// Step 4 §6.5 SIGHUP-only payout.tuning.* reload. Reading
		// the YAML on SIGHUP MUST NOT touch payout.security.* (the
		// loader is read-only on the security namespace); the
		// TuningProvider.Reload helper applies bound re-enforcement
		// AND emits payout_config_reloaded / payout_config_reload_rejected
		// per SPEC §6.5.
		go startPayoutSIGHUPListener(shutdownCtx, *configPath, *configOverlay, payoutS2.tuning, payoutS2.rpcs, logger)
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
	registerHandler := &onboarding.Handler{
		StatsDB:                             onboardingStore,
		AuthTokenStore:                      tokenStore,
		ReferralStore:                       tokenStore,
		ReferralPolicy:                      referralPolicy,
		CoordinatorDomain:                   cfg.Onboarding.CoordinatorDomain,
		CoordinatorWSURL:                    "wss://" + cfg.Onboarding.CoordinatorDomain + "/v2/provider",
		TrustedProxies:                      mustParseTrustedProxies(cfg, logger),
		IPRateLimiter:                       onboarding.NewMemoryRateLimiter(5, time.Minute),
		CommittedRetryRateLimiter:           onboarding.NewMemoryRateLimiter(5, time.Minute),
		CommittedRetryGlobalRateLimiter:     onboarding.NewMemoryRateLimiter(60, time.Minute),
		CommittedRetrySlots:                 make(chan struct{}, 4),
		ASNRateLimiter:                      onboarding.NewMemoryRateLimiter(30, time.Minute),
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
	// Pending cross-store referral mints must converge even when operators
	// disable the admission route or referral enforcement after a crash.
	startAppTrackReferralMintReconciler(shutdownCtx, registerHandler, logger)
	if cfg.Onboarding.AppTrackRegisterEnabled {
		asnResolver, err := onboarding.NewStaticASNResolver(cfg.Onboarding.ASNPrefixes)
		if err != nil {
			logger.Fatal().Err(err).Msg("onboarding ASN resolver config invalid")
		}
		registerHandler.ASNResolver = asnResolver
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
	var buyerHandler http.Handler = buyerHandlerWithOptionalProviderEndpoints(
		buyerServer.Handler(),
		cfg.Onboarding.AppTrackRegisterEnabled,
		register,
		hardwareEvidence,
		enrollHandler,
		malibuAccrualHandler(cfg, tokenStore, rewardsDB, rewards.NewPoolHeartbeatBridge(wsServer.PoolSnapshot)),
	)
	var trustedReferralProxies []netip.Prefix
	if cfg.Referrals.EnablePublicValidation || cfg.Referrals.EnableJoinLinks || cfg.Referrals.RequireForRegistration {
		trustedReferralProxies = mustParseTrustedProxies(cfg, logger)
	}
	var referralValidationHandler http.HandlerFunc
	if cfg.Referrals.EnablePublicValidation {
		referralValidation := newReferralValidationHandler(tokenStore, referralPolicy, trustedReferralProxies, cfg.Referrals.RequestAccessURL, metricsHandle)
		referralValidationHandler = referralValidation.ServeHTTP
	}
	// Public invite credentials live exclusively in the browser fragment at
	// malibu.tech/j. The coordinator exposes only body-based validation and
	// must not mount the legacy credential-bearing /j/<code> route.
	buyerHandler = withReferralValidation(buyerHandler, referralValidationHandler)
	var referralStatus, referralChallenge, referralVerify http.HandlerFunc
	if cfg.Referrals.RequireForRegistration {
		advocacy := &referralapi.AdvocacyHandler{
			Store:            tokenStore,
			Tokens:           tokenStore,
			Policy:           referralPolicy,
			PublicLimiter:    referralapi.NewBoundedLimiter(60, time.Minute, 4096),
			ProviderLimiter:  referralapi.NewBoundedLimiter(10, time.Minute, 4096),
			AuthSlots:        make(chan struct{}, 16),
			VerifySlots:      make(chan struct{}, 8),
			JoinBaseURL:      cfg.Referrals.JoinBaseURL,
			JoinLinksEnabled: cfg.Referrals.EnableJoinLinks,
			Metrics:          metricsHandle,
			SourceIP: func(r *http.Request) string {
				return onboarding.ClientIP(r, trustedReferralProxies)
			},
		}
		referralStatus = advocacy.HandleStatus
		startReferralServingReconciler(shutdownCtx, referralapi.ServingReconciler{
			Source: referralapi.SQLiteServingEvidence{Path: cfg.Storage.DBPath},
			Store:  tokenStore,
			Policy: referralPolicy,
		}, logger)
		if cfg.Referrals.EnableSocialInviteBonus {
			xClient, err := referralapi.NewXAPIClient(cfg.Referrals.XAPIBearerToken, cfg.Referrals.JoinBaseURL)
			if err != nil {
				logger.Fatal().Err(err).Msg("invalid social verification configuration")
			}
			advocacy.PostVerifier = xClient
			referralChallenge = advocacy.HandleChallenge
			referralVerify = advocacy.HandleVerify
			startSocialVerificationPromotionReconciler(shutdownCtx, tokenStore, referralPolicy, xClient, logger)
		}
		logger.Info().
			Bool("social_invite_bonus", cfg.Referrals.EnableSocialInviteBonus).
			Str("campaign", cfg.Referrals.Campaign).
			Msg("provider referral status endpoint mounted; mutation routes remain feature-gated")
	}
	buyerHandler = withReferralAdvocacy(buyerHandler, referralStatus, referralChallenge, referralVerify)

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
	startProviderConnectionEventPruner(shutdownCtx, connectionEventStore, logger)
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
				reloadCoordinatorConfig(*configPath, cfg.Tier2, logger, wsServer, buyerServer, autotuneCatalog, autotuneEvidenceStore, billingStore)
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
			wsServer.CloseAllProviderSessions("coordinator shutdown")
			wsServer.WaitProviderConnections(2 * time.Second)
			wsServer.FlushConnectionEvents(2 * time.Second)
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

// loadPreviousAutotuneCatalog loads exactly the release recorded by the
// deployer's root-owned .previous-target marker. It is signature/schema
// verified through the same loader as the active feed and is never discovered
// from an unbounded directory scan.
func loadPreviousAutotuneCatalog(cfg config.AutotuneFeedsConfig) ([]*autotune.Catalog, error) {
	if cfg.AutotuneCandidatesPath == "" {
		return nil, nil
	}
	root := filepath.Dir(filepath.Dir(cfg.AutotuneCandidatesPath))
	targetBytes, err := os.ReadFile(filepath.Join(root, ".previous-target"))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("read previous-target: %w", err)
	}
	target := strings.TrimSpace(string(targetBytes))
	if target == "" {
		return nil, nil
	}
	releaseID := strings.TrimPrefix(target, "releases/")
	if releaseID == target || releaseID == "" || strings.Contains(releaseID, "/") {
		return nil, fmt.Errorf("invalid previous-target %q", target)
	}
	for _, r := range releaseID {
		if !(r >= 'A' && r <= 'Z') && !(r >= 'a' && r <= 'z') && !(r >= '0' && r <= '9') && !strings.ContainsRune("._-", r) {
			return nil, fmt.Errorf("invalid previous-target %q", target)
		}
	}
	// Compatibility is optional. Never let a stale tombstoned bridge prevent a
	// verified current catalog from starting. The deploy rollback restores the
	// previous binary, config, and catalog as one unit if current activation fails.
	if autotune.IsPermanentlyRejectedReleaseID(releaseID) {
		return nil, nil
	}
	previousCfg := cfg
	previousCfg.DemandRankPath = ""
	previousCfg.DemandRankSigPath = ""
	previousCfg.AutotuneCandidatesPath = filepath.Join(root, target, "autotune-candidates.json")
	previousCfg.AutotuneCandidatesSigPath = previousCfg.AutotuneCandidatesPath + ".sig"
	feeds, err := buyer.LoadPreviousAutotuneCandidateFeed(previousCfg)
	if err != nil {
		return nil, fmt.Errorf("verify %s: %w", target, err)
	}
	previous, err := autotune.ParseCatalog(feeds.AutotuneCandidatesJSON)
	if err != nil {
		return nil, fmt.Errorf("parse %s: %w", target, err)
	}
	previous.SignerKeyID = feeds.AutotuneCandidatesVerification.KeyID
	return []*autotune.Catalog{previous}, nil
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

func startProviderConnectionEventPruner(ctx context.Context, store *providerevents.SQLiteStore, logger zerolog.Logger) {
	if store == nil {
		return
	}
	prune := func() {
		if err := store.ReconcileBounds(ctx); err != nil {
			logger.Warn().Err(err).Msg("provider connection events reconcile failed")
			return
		}
		logger.Info().Msg("provider connection events bounds reconciled")
	}
	prune()
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

type appTrackReferralMintReconciler interface {
	ReconcilePendingAppTrackReferralMints(context.Context) error
}

func shouldOpenOnboardingStore(cfg config.OnboardingConfig) bool {
	return cfg.AppTrackRegisterEnabled || strings.TrimSpace(cfg.PostgresDSN) != ""
}

func startAppTrackReferralMintReconciler(ctx context.Context, handler appTrackReferralMintReconciler, logger zerolog.Logger) {
	if handler == nil {
		return
	}
	go func() {
		reconcile := func() {
			reconcileCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
			defer cancel()
			if err := handler.ReconcilePendingAppTrackReferralMints(reconcileCtx); err != nil && ctx.Err() == nil {
				logger.Error().Err(err).Msg("App-track referral mint reconciliation failed")
			}
		}
		reconcile()
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				reconcile()
			}
		}
	}()
}

func startReferralServingReconciler(ctx context.Context, reconciler referralapi.ServingReconciler, logger zerolog.Logger) {
	if reconciler.Source == nil || reconciler.Store == nil || !reconciler.Policy.RequireForRegistration {
		return
	}
	go func() {
		reconcile := func() {
			reconcileCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
			defer cancel()
			qualified, err := reconciler.Reconcile(reconcileCtx)
			if err != nil && ctx.Err() == nil {
				logger.Error().Err(err).Msg("referral serving qualification reconciliation failed")
				return
			}
			if qualified > 0 {
				logger.Info().Int("qualified", qualified).Msg("provider referral invite capacity awarded from verified serving evidence")
			}
		}
		reconcile()
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				reconcile()
			}
		}
	}()
}

type socialAuthorLookup interface {
	RecheckPost(context.Context, string, string) (string, error)
}

func startSocialVerificationPromotionReconciler(
	ctx context.Context,
	store *auth.Store,
	policy auth.ReferralPolicy,
	verifier socialAuthorLookup,
	logger zerolog.Logger,
) {
	if store == nil || verifier == nil || !policy.EnableSocialBonus {
		return
	}
	recheck := func(ctx context.Context, postID, boundAuthorID, shareURLHash string) error {
		authorID, err := verifier.RecheckPost(ctx, postID, shareURLHash)
		if err != nil {
			if errors.Is(err, referralapi.ErrXPostTransient) {
				return fmt.Errorf("%w: x lookup unavailable", auth.ErrSocialRecheckTransient)
			}
			return err
		}
		if boundAuthorID == "" || authorID != boundAuthorID {
			return fmt.Errorf("x post author no longer matches")
		}
		return nil
	}
	go func() {
		reconcile := func() {
			reconcileCtx, cancel := context.WithTimeout(ctx, 45*time.Second)
			defer cancel()
			granted, err := store.PromoteMaturedSocialVerifications(reconcileCtx, policy, time.Now().UTC(), recheck)
			if err != nil && ctx.Err() == nil {
				logger.Error().Err(err).Msg("social verification promotion failed")
				return
			}
			if granted > 0 {
				logger.Info().Int("granted", granted).Msg("social invite bonus granted exactly once")
			}
		}
		reconcile()
		ticker := time.NewTicker(5 * time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				reconcile()
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
	reaper      *payout.Reaper               // Step 3 §4.8a + §4.8c outbox reaper
	chainWorker *payout.ChainBalanceWorker   // Step 4 §7.4
	tuning      *payout.TuningProvider       // Step 4 §6.5 SIGHUP-reloadable
	rpcs        payout.TwoRPCs               // Step 4 r3 [sec:r3-1] SPKI pin rotation: CloseIdleConnections on SIGHUP
	chronic     *payout.ChronicOutageTracker // #165 A2 — per-RPC sliding-window error tracker; Run() goroutine drives Evaluate
	stop        func(context.Context)        // calls Stop on every component then Release
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
		chronic:     chronicTracker,
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

func withReferralValidation(base http.Handler, validate http.HandlerFunc) http.Handler {
	if validate == nil {
		return base
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/referrals/validate", validate)
	mux.Handle("/", base)
	return mux
}

func withReferralAdvocacy(base http.Handler, status, challenge, verify http.HandlerFunc) http.Handler {
	if status == nil && challenge == nil && verify == nil {
		return base
	}
	mux := http.NewServeMux()
	if status != nil {
		mux.HandleFunc("/v1/provider/referrals", status)
	}
	if challenge != nil {
		mux.HandleFunc("/v1/provider/referrals/x/challenge", challenge)
	}
	if verify != nil {
		mux.HandleFunc("/v1/provider/referrals/x/verify", verify)
	}
	mux.Handle("/", base)
	return mux
}

func newReferralValidationHandler(store referralapi.ValidationStore, policy auth.ReferralPolicy, trustedProxies []netip.Prefix, requestAccessURL string, metrics referralapi.ReferralMetrics) *referralapi.ValidationHandler {
	return &referralapi.ValidationHandler{
		Store:            store,
		Policy:           policy,
		PublicLimiter:    referralapi.NewBoundedLimiter(30, time.Minute, 4096),
		ValidateSlots:    make(chan struct{}, 4),
		RequestAccessURL: strings.TrimSpace(requestAccessURL),
		Metrics:          metrics,
		SourceIP: func(r *http.Request) string {
			return onboarding.ClientIP(r, trustedProxies)
		},
	}
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

func reloadTier2Config(configPath string, startupTier2 config.Tier2Config, logger zerolog.Logger, wsServer *providerws.Server, buyerServer *buyer.Server, autotuneCatalog *autotune.Catalog, billingStores ...*billing.Store) {
	reloadCoordinatorConfig(configPath, startupTier2, logger, wsServer, buyerServer, autotuneCatalog, nil, billingStores...)
}

func reloadCoordinatorConfig(configPath string, startupTier2 config.Tier2Config, logger zerolog.Logger, wsServer *providerws.Server, buyerServer *buyer.Server, autotuneCatalog *autotune.Catalog, autotuneEvidenceStore autotune.EvidenceStore, billingStores ...*billing.Store) {
	// SPEC-016 v0.1.23 §6.5: the general SIGHUP reload must not parse,
	// env-resolve, or validate payout.security.*, and a payout.* key
	// edited on disk must not reject a tier2/billing reload. Payout
	// tuning has its own dedicated SIGHUP listener
	// (startPayoutSIGHUPListener); this path never applies payout fields.
	cfg, err := config.LoadForSIGHUPReload(configPath)
	if err != nil {
		logger.Error().Err(err).Msg("tier2 config reload rejected")
		return
	}
	telemetryDrift, err := telemetryDriftEvaluatorForReload(cfg, autotuneCatalog, autotuneEvidenceStore)
	if err != nil {
		logger.Error().Err(err).Msg("proof_of_weights config reload rejected")
		return
	}
	if cfg.ProofOfWeights.RequireAutotuneHelloGate && (autotuneCatalog == nil || autotuneEvidenceStore == nil) {
		logger.Error().Msg("proof_of_weights config reload rejected: autotune hello gate dependencies are not wired")
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
	//
	// #608 Partial: the optional guard rejects a reload that would install
	// Tier-2 rows conflicting with the in-memory autotune admission catalog
	// before the package singleton is swapped.
	if _, err := tier2.ConfigureDefaultStrict(cfg.Tier2, logger, func(next *tier2.Catalog) error {
		return catalogbind.RequireActiveReleaseBinding(autotuneCatalog, next)
	}); err != nil {
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
	proofReload := wsServer.SetProofOfWeightsConfig(cfg.ProofOfWeights)
	wsServer.SetTelemetryDriftEvaluator(telemetryDrift)
	benchmarkQuarantinesCleared := 0
	if telemetryDrift == nil || !cfg.ProofOfWeights.TelemetryDrift.QuarantineMissingBenchmark {
		benchmarkQuarantinesCleared = wsServer.ClearBenchmarkQuarantines()
	}
	updated := wsServer.RefreshTier2HashStatuses()
	logger.Info().
		Int("provider_hash_statuses_updated", updated).
		Uint64("proof_of_weights_generation", proofReload.Generation).
		Int("proof_of_weights_pre_quarantined", proofReload.PreQuarantined).
		Int("proof_of_weights_revalidated", proofReload.Revalidated).
		Int("proof_of_weights_sandboxed", proofReload.Sandboxed).
		Int("proof_of_weights_route_excluded", proofReload.RouteExcluded).
		Int("proof_of_weights_still_evidence_stale", proofReload.StillEvidenceStale).
		Int("proof_of_weights_cleared_gate_exclusions", proofReload.ClearedGateExclusions).
		Int("benchmark_quarantines_cleared", benchmarkQuarantinesCleared).
		Msg("tier2/proof_of_weights config reloaded")
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

func telemetryDriftEvaluatorForReload(cfg config.Config, autotuneCatalog *autotune.Catalog, autotuneEvidenceStore autotune.EvidenceStore) (*pow.Evaluator, error) {
	if !cfg.ProofOfWeights.TelemetryDrift.Enabled {
		return nil, nil
	}
	if autotuneCatalog == nil {
		return nil, fmt.Errorf("proof_of_weights.telemetry_drift.enabled requires autotune candidate catalog feeds")
	}
	if autotuneEvidenceStore == nil {
		return nil, fmt.Errorf("proof_of_weights.telemetry_drift.enabled requires onboarding evidence store")
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
		cfg.ProofOfWeights.TelemetryDrift.QuarantineMissingBenchmark,
	)
	if err != nil {
		return nil, err
	}
	ttl := time.Duration(cfg.ProofOfWeights.AutotuneEvidenceTTLDays) * 24 * time.Hour
	return pow.NewEvaluator(driftCfg, autotuneCatalog, autotuneEvidenceStore, ttl), nil
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
	"ObserveEnabled":       tier2HotReloadable,
	"RequireHashVerified":  tier2HotReloadable,
	"ModelHashLegacyUntil": tier2HotReloadable,

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
	"SELivenessIntervalS":            tier2HotReloadable,
	"SELivenessTimeoutS":             tier2HotReloadable,
	"SELivenessMaxFailures":          tier2HotReloadable,
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
	configOverlayPath string,
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
			t, err := config.LoadPayoutTuningOnly(configPath, configOverlayPath)
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
				// #165 R1/R2 code/arch HIGH+MEDIUM (convergent): assert
				// on a CloseIdleConnections-shaped interface so the
				// SPKI reload drain still fires through the chronic-
				// outage TrackingRPCClient wrapper. Both
				// *payout.HTTPRPCClient and *trackingRPC implement
				// this method. The miss-branch logs at WARN so a
				// future RPCClient implementation that lacks the
				// method is operator-visible at SPKI rotation time
				// (rather than silently failing to drain).
				type idleCloser interface{ CloseIdleConnections() }
				for _, k := range changedKeys {
					if k == "payout.tuning.rpc_url_primary_pin_spki" ||
						k == "payout.tuning.rpc_url_secondary_pin_spki" {
						if rpc, ok := rpcs.Primary.(idleCloser); ok {
							rpc.CloseIdleConnections()
						} else {
							log.Warn().
								Str("event", "payout_spki_drain_skipped_unsupported_client").
								Str("rpc_label", "primary").
								Str("severity", "WARN").
								Str("ts_utc", time.Now().UTC().Format(time.RFC3339Nano)).
								Msg("SPKI pin rotated but primary RPC client does not implement CloseIdleConnections — pooled TLS conns survive the rotation")
						}
						if rpc, ok := rpcs.Secondary.(idleCloser); ok {
							rpc.CloseIdleConnections()
						} else {
							log.Warn().
								Str("event", "payout_spki_drain_skipped_unsupported_client").
								Str("rpc_label", "secondary").
								Str("severity", "WARN").
								Str("ts_utc", time.Now().UTC().Format(time.RFC3339Nano)).
								Msg("SPKI pin rotated but secondary RPC client does not implement CloseIdleConnections — pooled TLS conns survive the rotation")
						}
						break
					}
				}
			}
		}
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
