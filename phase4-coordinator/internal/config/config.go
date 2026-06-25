package config

import (
	"fmt"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

var providerIDPattern = regexp.MustCompile(`^[a-zA-Z0-9_.-]{1,64}$`)

// minAuditLogRetentionDays is the compliance floor for audit_log retention.
// Operators may not set audit_log_retention_days below this value.
const minAuditLogRetentionDays = 90

type Config struct {
	Listen                       ListenConfig                 `yaml:"listen"`
	Pool                         PoolConfig                   `yaml:"pool"`
	Routing                      RoutingConfig                `yaml:"routing"`
	ProviderHTTP                 ProviderHTTPConfig           `yaml:"provider_http"`
	Limits                       LimitsConfig                 `yaml:"limits"`
	WS                           WSConfig                     `yaml:"ws"`
	Admission                    AdmissionConfig              `yaml:"admission"`
	Tier2                        Tier2Config                  `yaml:"tier2"`
	CoordinatorAdvertisedVersion CoordinatorAdvertisedVersion `yaml:"coordinator_advertised_version"`
	Auth                         AuthConfig                   `yaml:"auth"`
	Storage                      StorageConfig                `yaml:"storage"`
	Logging                      LoggingConfig                `yaml:"logging"`
	Rewards                      RewardsConfig                `yaml:"rewards"`
	Settlement                   SettlementConfig             `yaml:"settlement"`
	Endpoints                    EndpointsConfig              `yaml:"endpoints"`
	Explorer                     ExplorerConfig               `yaml:"explorer"`
	Providers                    []ProviderConfig             `yaml:"providers"`
	// Payout is the SPEC-016 payout-pipeline configuration.
	// Default Enabled=false ships the schema migrations + handlers
	// idle; flipping to true activates the §3.3 endpoint (Step 1)
	// and the runner cycle (Step 2+, not present yet). See SPEC-016
	// §6.5 for the dual-loader namespace split (Step 4).
	Payout PayoutConfig `yaml:"payout"`
}

// PayoutConfig is the operator-facing root of the SPEC-016
// `payout.*` namespace. At Step 1 only the security.hot_wallet_address
// and a single tuning knob (address_cooling_off_period) are read;
// the §6.5 dual-loader split lands in Step 4 with the full key set.
type PayoutConfig struct {
	Enabled  bool                 `yaml:"enabled"`
	Security PayoutSecurityConfig `yaml:"security"`
	Tuning   PayoutTuningConfig   `yaml:"tuning"`
}

// PayoutSecurityConfig holds SPEC-016 §6.5 `payout.security.*` keys
// — the IMMUTABLE-at-startup subset. Step 2 grows this struct with
// caps + RPC URLs + abandon caps; Step 4 will land the full §6.5
// dual-loader split (SIGHUP-only tuning, fsnotify-forbidden, etc.).
// At Step 2 the values are read once at process start and not
// re-loaded; no SIGHUP handler touches these.
type PayoutSecurityConfig struct {
	// HotWalletAddress is the operator hot wallet on Base mainnet.
	// SPEC §3.2 step 5 uses it as the EIP-712 verifyingContract;
	// §3.4 stamps it into provider_payout_addresses.registered_against_hot_wallet
	// on every successful INSERT/UPDATE.
	HotWalletAddress string `yaml:"hot_wallet_address"`

	// RPCURLPrimary / RPCURLSecondary are the two Base mainnet
	// JSON-RPC endpoints. SPEC §4.4 REQUIRES two; single-RPC is
	// REJECTED at v0.1.x. The two MUST be loaded from SEPARATE
	// secrets paths (§4.4 trust-separation requirement); this is
	// enforced operationally via config-file layout, not by IMPL.
	RPCURLPrimary   string `yaml:"rpc_url_primary"`
	RPCURLSecondary string `yaml:"rpc_url_secondary"`

	// PerPayoutCapUSDCBaseUnits is the §5.2 per-payout ceiling.
	// Default $500 = 500_000_000 base units.
	PerPayoutCapUSDCBaseUnits int64 `yaml:"per_payout_cap_usdc_base_units"`

	// PerDayCapUSDCBaseUnits is the §5.3 rolling 24h ceiling.
	// Default $5,000 = 5_000_000_000 base units.
	PerDayCapUSDCBaseUnits int64 `yaml:"per_day_cap_usdc_base_units"`

	// CancelMaxTipMultiplier is the §4.6 cap on the tip multiplier
	// supplied by the operator on /admin/payout/abandon-attempt.
	// Default 5×. Requests above are silently floored with a
	// cap_applied log entry.
	CancelMaxTipMultiplier float64 `yaml:"cancel_max_tip_multiplier"`

	// CancelMaxGasNativeWei is the §4.6 per-cancel gas ceiling.
	// Default 0.01 ETH = 1e16 wei. Requests above 422 reject.
	CancelMaxGasNativeWei int64 `yaml:"cancel_max_gas_native_wei"`

	// CancelMaxGasNativeWeiPer24h is the §4.6 24h aggregate gas
	// ceiling. Default 0.05 ETH = 5e16 wei. SUM over confirmed
	// cancels in the window + the current-request estimate.
	CancelMaxGasNativeWeiPer24h int64 `yaml:"cancel_max_gas_native_wei_per_24h"`

	// AbandonRatePerHour is the §4.6 per-operator-token rate
	// limit on the abandon endpoint. Default 3.
	AbandonRatePerHour int `yaml:"abandon_rate_per_hour"`

	// ChainReconInterval is the §4.4 / §7.4 chain-balance recon
	// cadence (Step 4 wiring, Step 2 reads the value). Default 1h.
	ChainReconInterval time.Duration `yaml:"chain_recon_interval"`

	// ChainReconToleranceUSDCBaseUnits is the §4.4 drift
	// threshold. Default $0.10 = 100_000 base units.
	ChainReconToleranceUSDCBaseUnits int64 `yaml:"chain_recon_tolerance_usdc_base_units"`

	// PauseResumeMinInterval is the §6.4.1 endpoint rate-limit
	// floor. Default 60s. Step 3 wiring.
	PauseResumeMinInterval time.Duration `yaml:"pause_resume_min_interval"`

	// EncryptedWalletPath is the on-disk AES-256-GCM-encrypted
	// secp256k1 wallet file. SPEC §6.3 production path; the
	// runner decrypts at startup using the KEK supplied via
	// systemd LoadCredential= (preferred) or
	// MACPROVIDER_PAYOUT_WALLET_KEK env var. Required when
	// payout.enabled=true unless DevMode is also true.
	EncryptedWalletPath string `yaml:"encrypted_wallet_path"`

	// EncryptedWalletOnDiskHex indicates the wallet file is
	// stored as hex-encoded bytes (vs raw bytes). Default false
	// (raw bytes).
	EncryptedWalletOnDiskHex bool `yaml:"encrypted_wallet_on_disk_hex"`

	// DevMode permits loading the wallet from the dev-only env
	// var (MACPROVIDER_PAYOUT_WALLET_KEY_HEX_DEV_ONLY) instead
	// of the encrypted file + KEK production path. NEVER enable
	// in production. Step 2 [sec:2.3] HIGH closure: dev path
	// MUST be explicitly opted-in.
	DevMode bool `yaml:"dev_mode"`
}

// PayoutTuningConfig holds SPEC-016 §6.5 `payout.tuning.*` keys —
// the SIGHUP-reloadable subset (full hot-reload semantics land in
// Step 4; Step 2 just reads the values at startup). Hard bounds
// per §6.5 are enforced at parse time.
type PayoutTuningConfig struct {
	// AddressCoolingOffPeriod is the §3.3 cooling-off window for
	// freshly-registered or rotated addresses. Default 24h.
	// SPEC §3.1 floor: 1h.
	AddressCoolingOffPeriod time.Duration `yaml:"address_cooling_off_period"`

	// RunInterval is the §4.2 runner cadence. Default 6h.
	// SPEC §6.5 bounds: [5m, 24h].
	RunInterval time.Duration `yaml:"run_interval"`

	// RunNowMinInterval rate-limits the §4.2 admin run-now endpoint.
	// Default 60s. SPEC §6.5 bounds: [10s, 1h].
	RunNowMinInterval time.Duration `yaml:"run_now_min_interval"`

	// ConfirmationBlocks is the §4.3 step 7 receipt-depth threshold
	// for the two-RPC confirm. Default 5. SPEC §6.5 bounds
	// [5, 200] (v0.1.20 round-20 M2 closure widened from [2, 50]).
	ConfirmationBlocks int `yaml:"confirmation_blocks"`

	// MaxRowsPerRun caps the §4.3 step 1 SELECT. Default 50.
	// SPEC §6.5 bounds: [1, 500].
	MaxRowsPerRun int `yaml:"max_rows_per_run"`

	// ReorgPollWindow is the §4.7 re-poll window for already-
	// confirmed rows. Default 24h. SPEC §6.5 bounds [1h, 168h]
	// (v0.1.20 round-20 M1 closure).
	ReorgPollWindow time.Duration `yaml:"reorg_poll_window"`

	// LowBalanceThreshold / LowNativeThreshold drive §6.2 alerts
	// (Step 4 wiring; Step 2 reads). Defaults: 0 (disabled).
	LowBalanceThreshold int64 `yaml:"low_balance_threshold"`
	LowNativeThreshold  int64 `yaml:"low_native_threshold"`

	// RPCURLPrimaryPinSPKI / RPCURLSecondaryPinSPKI are optional
	// SHA-256 SPKI cert pins for the two RPCs (§4.4). 64-hex chars
	// or empty.
	RPCURLPrimaryPinSPKI   string `yaml:"rpc_url_primary_pin_spki"`
	RPCURLSecondaryPinSPKI string `yaml:"rpc_url_secondary_pin_spki"`
}

type ListenConfig struct {
	BuyerPort    int    `yaml:"buyer_port"`
	ProviderPort int    `yaml:"provider_port"`
	BindAddress  string `yaml:"bind_address"`
}

type PoolConfig struct {
	HeartbeatIntervalS     int `yaml:"heartbeat_interval_s"`
	DisconnectGracePeriodS int `yaml:"disconnect_grace_period_s"`
	// HeartbeatMissThresholdS bounds how long a provider may go without ANY
	// inbound frame (heartbeat OR in-flight inference response) before the
	// liveness monitor closes its WebSocket. It MUST be generous relative to
	// HeartbeatIntervalS: a provider doing single-threaded MLX inference may
	// not emit a heartbeat for the duration of a generation, but its response
	// chunks count as activity and keep the socket alive. Decoupled from
	// routing.failover_timeout_s (which governs replacement selection, not
	// liveness). Defaults to 90s (3x the 30s heartbeat interval).
	HeartbeatMissThresholdS int `yaml:"heartbeat_miss_threshold_s"`
	WakeGapThresholdS       int `yaml:"wake_gap_threshold_s"`
	// WakeGapThresholdMs, when > 0, overrides WakeGapThresholdS for
	// millisecond-precision test scenarios. Not for production use.
	WakeGapThresholdMs      int                     `yaml:"wake_gap_threshold_ms"`
	WarmupFallbackS         int                     `yaml:"warmup_fallback_s"`
	WarmupGateEnabled       bool                    `yaml:"warmup_gate_enabled"`
	WarmupGateTimeoutS      int                     `yaml:"warmup_gate_timeout_s"`
	WarmupGateMaxTokens     int                     `yaml:"warmup_gate_max_tokens"`
	DegradedBackoffS        int                     `yaml:"degraded_backoff_s"`
	DegradedMaxRetries      int                     `yaml:"degraded_max_retries"`
	DegradedProbeAfter502   bool                    `yaml:"degraded_probe_after_502"`
	BreakerFailureThreshold int                     `yaml:"breaker_failure_threshold"`
	BreakerWindowS          int                     `yaml:"breaker_window_s"`
	CanaryEnabled           bool                    `yaml:"canary_enabled"`
	CanaryIntervalS         int                     `yaml:"canary_interval_s"`
	CanaryTimeoutS          int                     `yaml:"canary_timeout_s"`
	CanaryMaxTokens         int                     `yaml:"canary_max_tokens"`
	CanaryFailureThreshold  int                     `yaml:"canary_failure_threshold"`
	CanaryChallenges        []CanaryChallengeConfig `yaml:"canary_challenges"`
}

type CanaryChallengeConfig struct {
	Prompt   string `yaml:"prompt"`
	Expected string `yaml:"expected"`
}

type RoutingConfig struct {
	PreflightThresholdTokens      int                         `yaml:"preflight_threshold_tokens"`
	PreflightTimeoutS             int                         `yaml:"preflight_timeout_s"`
	RequestTimeoutS               int                         `yaml:"request_timeout_s"`
	FailoverEnabled               bool                        `yaml:"failover_enabled"`
	FailoverTimeoutS              int                         `yaml:"failover_timeout_s"`
	TiebreakRandomize             bool                        `yaml:"tiebreak_randomize"`
	TiebreakEpsilon               float64                     `yaml:"tiebreak_epsilon"`
	MaxRetries                    int                         `yaml:"max_retries"`
	RetryPerAttemptTimeoutS       int                         `yaml:"retry_per_attempt_timeout_s"`
	MaxProvidersFaultedPerRequest int                         `yaml:"max_providers_faulted_per_request"`
	StickyEnabled                 bool                        `yaml:"sticky_enabled"`
	StickyTTLS                    int                         `yaml:"sticky_ttl_s"`
	StickyMaxEntries              int                         `yaml:"sticky_max_entries"`
	ModelClasses                  map[string]ModelClassConfig `yaml:"model_classes"`
}

type ModelClassConfig struct {
	Members   []string `yaml:"members"`
	Models    []string `yaml:"models"`
	Objective string   `yaml:"objective"`
}

type ProviderHTTPConfig struct {
	TimeoutS int `yaml:"timeout_s"`
}

type LimitsConfig struct {
	MaxChatRequestBodyBytes int64 `yaml:"max_chat_request_body_bytes"`
}

type WSConfig struct {
	WriteBufferSize        int   `yaml:"write_buffer_size"`
	HandshakeTimeoutS      int   `yaml:"handshake_timeout_s"`
	WriteTimeoutS          int   `yaml:"write_timeout_s"`
	MaxFrameBytes          int64 `yaml:"max_frame_bytes"`
	MaxUnauthenticatedConn int   `yaml:"max_unauthenticated_conn"`
	// MaxUnauthenticatedConnPerIP caps concurrent unauthenticated WS
	// handshakes from a single remote IP. Defense-in-depth against a single
	// host starving all provider readmissions even if it slips past nginx's
	// limit_conn (M1-4 / SECU-1). Default 4. Must be > 0.
	MaxUnauthenticatedConnPerIP int `yaml:"max_unauthenticated_conn_per_ip"`
}

type AdmissionConfig struct {
	PinnedOnly                      bool    `yaml:"pinned_only"`
	ProvisionalAdmissionRatePerHour int     `yaml:"provisional_admission_rate_per_hour"`
	ProvisionalPoolMax              int     `yaml:"provisional_pool_max"`
	ProvisionalQuotaPerHour         int     `yaml:"provisional_quota_per_hour"`
	ProvisionalTierWeight           float64 `yaml:"provisional_tier_weight"`
	ProvisionalRetentionDays        int     `yaml:"provisional_retention_days"`
}

type Tier2Config struct {
	ObserveEnabled bool `yaml:"observe_enabled"`

	CatalogPath         string `yaml:"catalog_path"`
	CatalogPublicKey    string `yaml:"catalog_public_key"`
	RequireHashVerified bool   `yaml:"require_hash_verified"`
	// PublicCatalogBaseURL is the public base URL the coordinator
	// advertises for SPEC-015 §M.4 catalog endpoints
	// (`GET /catalog/<catalog_id>` and `GET /catalog/pubkey`). When
	// non-empty, `/poolz` emits absolute catalog URLs derived from
	// this base (trailing slashes trimmed). When empty, `/poolz`
	// falls back to deriving an absolute URL from the inbound
	// request's scheme + `Host` header. If neither source yields a
	// usable base (catalog_id present but no host available),
	// `catalog_url` and `catalog_pubkey_url` are OMITTED from the
	// `/poolz` response — only `catalog_id` is emitted, so a
	// verifier invoked with `--catalog <path>` + `--catalog-pubkey`
	// (file-based, no URL resolution) still works.
	PublicCatalogBaseURL string `yaml:"public_catalog_base_url"`

	RequireEncryptedLeg            bool   `yaml:"require_encrypted_leg"`
	EncryptedLegAEAD               string `yaml:"encrypted_leg_aead"`
	EncryptedLegRekeyAfterRequests int    `yaml:"encrypted_leg_rekey_after_requests"`
	EncryptedLegRekeyAfterSeconds  int    `yaml:"encrypted_leg_rekey_after_seconds"`

	RequireAttestation   bool     `yaml:"require_attestation"`
	AttestationRoots     []string `yaml:"attestation_roots"`
	AttestationMaxAgeS   int      `yaml:"attestation_max_age_s"`
	AttestationFormats   []string `yaml:"attestation_formats"`
	AllowMockAttestation bool     `yaml:"allow_mock_attestation"`

	BehavioralSafetyEnabled    bool    `yaml:"behavioral_safety_enabled"`
	OutputSizeCapBytes         int64   `yaml:"output_size_cap_bytes"`
	OutputBytesPerTokenCeiling int     `yaml:"output_bytes_per_token_ceiling"`
	DefaultOutputSizeCapBytes  int64   `yaml:"default_output_size_cap_bytes"`
	EncodingValidationEnabled  bool    `yaml:"encoding_validation_enabled"`
	ResponseTimeAnomalyEnabled bool    `yaml:"response_time_anomaly_enabled"`
	ResponseTimeAnomalyFactor  float64 `yaml:"response_time_anomaly_factor"`
	ResponseTimeAnomalyMinMS   int64   `yaml:"response_time_anomaly_min_ms"`
}

type CoordinatorAdvertisedVersion struct {
	LatestBinaryVersion   string `yaml:"latest_binary_version"`
	RequiredBinaryVersion string `yaml:"required_binary_version"`
}

type AuthConfig struct {
	OperatorKey string `yaml:"operator_key"`
	// GatewayServiceToken is the optional service-to-service credential
	// the gateway uses when calling internal/admin coordinator endpoints
	// (M3-2 / SECU-4). When set, the coordinator accepts EITHER
	// OperatorKey OR GatewayServiceToken on the internal-bearer auth
	// path; this allows the operator key to be rotated independently of
	// the live gateway upstream credential. Empty = legacy-only
	// (OperatorKey is the sole accepted credential), preserving
	// pre-bridge behavior.
	GatewayServiceToken string `yaml:"gateway_service_token"`
	// RequireProviderTokens fails closed for public provider WebSocket
	// exposure. Disable only for isolated local development or one-off
	// migrations where anonymous pinned-provider admission is acceptable.
	RequireProviderTokens bool `yaml:"require_provider_tokens"`
	// AllowTokenlessProvisionalBootstrap keeps RequireProviderTokens
	// fail-closed for normal reconnects while allowing a first tokenless
	// provisional provider to reach the self-serve mint/TOFU path. Existing
	// used-token identities still reject tokenless reconnects; enable only
	// for public onboarding.
	AllowTokenlessProvisionalBootstrap bool              `yaml:"allow_tokenless_provisional_bootstrap"`
	GitHubOAuth                        GitHubOAuthConfig `yaml:"github_oauth"`
}

type GitHubOAuthConfig struct {
	Enabled             bool   `yaml:"enabled"`
	ClientID            string `yaml:"client_id"`
	ClientSecret        string `yaml:"client_secret"`
	RedirectURI         string `yaml:"redirect_uri"`
	PortalBaseURL       string `yaml:"portal_base_url"`
	SessionCookieDomain string `yaml:"session_cookie_domain"`
}

type StorageConfig struct {
	DBPath                  string `yaml:"db_path"`
	SnapshotIntervalS       int    `yaml:"snapshot_interval_s"`
	RequestLogRetentionDays int    `yaml:"request_log_retention_days"`
	// SPEC-002 v1.3.5 §7.10.1 R-7.10.2 — retention for the
	// operator_model_swap audit_log table (and any future audit event
	// types). Default 90 days mirrors request_log_retention_days.
	AuditLogRetentionDays int `yaml:"audit_log_retention_days"`
}

type LoggingConfig struct {
	Level  string `yaml:"level"`
	Format string `yaml:"format"`
}

type RateCardEntry struct {
	PromptCreditsPerMtok     int64 `yaml:"prompt_credits_per_mtok"`
	CompletionCreditsPerMtok int64 `yaml:"completion_credits_per_mtok"`
}

type RewardsConfig struct {
	GlobalMultiplier float64                  `yaml:"global_multiplier"`
	ProviderShare    float64                  `yaml:"provider_share"`
	RateCard         map[string]RateCardEntry `yaml:"rate_card"`
}

type SettlementConfig struct {
	CadenceDays                 int   `yaml:"cadence_days"`
	MinPayoutCredits            int64 `yaml:"min_payout_credits"`
	StartupReconcileWindowHours int   `yaml:"startup_reconcile_window_hours"`
	NightlyReconcileWindowDays  int   `yaml:"nightly_reconcile_window_days"`
	RecoveryGraceSeconds        int   `yaml:"recovery_grace_seconds"`
	JobEnabled                  bool  `yaml:"job_enabled"`
}

type EndpointsConfig struct {
	ProviderEarnings EndpointsProviderEarningsConfig `yaml:"provider_earnings"`
}

type EndpointsProviderEarningsConfig struct {
	RateLimitPerMinute int `yaml:"rate_limit_per_minute"`
}

type ExplorerConfig struct {
	Enabled                       bool   `yaml:"enabled"`
	BindPath                      string `yaml:"bind_path"`
	GatewayBaseURL                string `yaml:"gateway_base_url"`
	GatewayTimeoutMs              int    `yaml:"gateway_timeout_ms"`
	QueryTimeoutMs                int    `yaml:"query_timeout_ms"`
	PollMinIntervalSeconds        int    `yaml:"poll_min_interval_seconds"`
	ActivityMaxWindowDays         int    `yaml:"activity_max_window_days"`
	ActivityDefaultWindowHours    int    `yaml:"activity_default_window_hours"`
	BuyersMaxWindowDays           int    `yaml:"buyers_max_window_days"`
	BuyersDefaultWindowHours      int    `yaml:"buyers_default_window_hours"`
	LedgerMaxWindowDays           int    `yaml:"ledger_max_window_days"`
	LedgerDefaultWindowHours      int    `yaml:"ledger_default_window_hours"`
	SessionsMaxWindowDays         int    `yaml:"sessions_max_window_days"`
	SessionsDefaultWindowHours    int    `yaml:"sessions_default_window_hours"`
	SettlementsMaxWindowDays      int    `yaml:"settlements_max_window_days"`
	SettlementsDefaultWindowHours int    `yaml:"settlements_default_window_hours"`
	RequestsPerMinuteCap          int    `yaml:"requests_per_minute_cap"`
}

type ProviderConfig struct {
	ProviderID  string `yaml:"provider_id"`
	EndpointURL string `yaml:"endpoint_url"`
	DisplayName string `yaml:"display_name"`
}

func Default() Config {
	return Config{
		Listen: ListenConfig{
			BuyerPort:    8443,
			ProviderPort: 8444,
			BindAddress:  "127.0.0.1",
		},
		Pool: PoolConfig{
			HeartbeatIntervalS:      30,
			DisconnectGracePeriodS:  30,
			HeartbeatMissThresholdS: 90,
			WakeGapThresholdS:       120,
			WarmupFallbackS:         60,
			WarmupGateEnabled:       true,
			WarmupGateTimeoutS:      90,
			WarmupGateMaxTokens:     2,
			DegradedBackoffS:        30,
			DegradedMaxRetries:      3,
			DegradedProbeAfter502:   true,
			BreakerFailureThreshold: 2,
			BreakerWindowS:          120,
			CanaryEnabled:           false,
			CanaryIntervalS:         300,
			CanaryTimeoutS:          30,
			CanaryMaxTokens:         8,
			CanaryFailureThreshold:  3,
		},
		Routing: RoutingConfig{
			PreflightThresholdTokens:      4096,
			PreflightTimeoutS:             5,
			RequestTimeoutS:               280,
			FailoverEnabled:               true,
			FailoverTimeoutS:              5,
			TiebreakRandomize:             false,
			TiebreakEpsilon:               0,
			MaxRetries:                    0,
			RetryPerAttemptTimeoutS:       60,
			MaxProvidersFaultedPerRequest: 0,
			StickyEnabled:                 false,
			StickyTTLS:                    1800,
			StickyMaxEntries:              10000,
			ModelClasses:                  map[string]ModelClassConfig{},
		},
		ProviderHTTP: ProviderHTTPConfig{
			TimeoutS: 300,
		},
		Limits: LimitsConfig{
			MaxChatRequestBodyBytes: 1 << 20,
		},
		WS: WSConfig{
			WriteBufferSize:             64,
			HandshakeTimeoutS:           10,
			WriteTimeoutS:               10,
			MaxFrameBytes:               4 << 20,
			MaxUnauthenticatedConn:      64,
			MaxUnauthenticatedConnPerIP: 4,
		},
		Admission: AdmissionConfig{
			PinnedOnly:                      false,
			ProvisionalAdmissionRatePerHour: 10,
			ProvisionalPoolMax:              100,
			ProvisionalQuotaPerHour:         100,
			ProvisionalTierWeight:           0.3,
			ProvisionalRetentionDays:        30,
		},
		Tier2: Tier2Config{
			ObserveEnabled:                 false,
			CatalogPath:                    "",
			CatalogPublicKey:               "",
			RequireHashVerified:            false,
			RequireEncryptedLeg:            false,
			EncryptedLegAEAD:               "A256GCM",
			EncryptedLegRekeyAfterRequests: 10000,
			EncryptedLegRekeyAfterSeconds:  3600,
			RequireAttestation:             false,
			AttestationRoots:               []string{},
			AttestationMaxAgeS:             600,
			AttestationFormats:             []string{"apple-managed-device-attestation-acme-v1"},
			AllowMockAttestation:           false,
			BehavioralSafetyEnabled:        false,
			OutputSizeCapBytes:             0,
			OutputBytesPerTokenCeiling:     16,
			DefaultOutputSizeCapBytes:      1048576,
			EncodingValidationEnabled:      false,
			ResponseTimeAnomalyEnabled:     false,
			ResponseTimeAnomalyFactor:      5.0,
			ResponseTimeAnomalyMinMS:       10000,
		},
		Storage: StorageConfig{
			DBPath:                  "coordinator.db",
			SnapshotIntervalS:       300,
			RequestLogRetentionDays: 90,
			AuditLogRetentionDays:   90,
		},
		Logging: LoggingConfig{
			Level:  "info",
			Format: "json",
		},
		Rewards: RewardsConfig{
			GlobalMultiplier: 1.0,
			ProviderShare:    0.90,
			RateCard: map[string]RateCardEntry{
				"default": {
					PromptCreditsPerMtok:     500000,
					CompletionCreditsPerMtok: 1000000,
				},
			},
		},
		Settlement: SettlementConfig{
			CadenceDays:                 7,
			MinPayoutCredits:            500000,
			StartupReconcileWindowHours: 24,
			NightlyReconcileWindowDays:  7,
			RecoveryGraceSeconds:        30,
			JobEnabled:                  true,
		},
		Endpoints: EndpointsConfig{
			ProviderEarnings: EndpointsProviderEarningsConfig{
				RateLimitPerMinute: 60,
			},
		},
		Explorer: ExplorerConfig{
			Enabled:                       false,
			BindPath:                      "/admin/explorer/",
			GatewayTimeoutMs:              1500,
			QueryTimeoutMs:                3000,
			PollMinIntervalSeconds:        5,
			ActivityMaxWindowDays:         7,
			ActivityDefaultWindowHours:    24,
			BuyersMaxWindowDays:           31,
			BuyersDefaultWindowHours:      168,
			LedgerMaxWindowDays:           31,
			LedgerDefaultWindowHours:      168,
			SessionsMaxWindowDays:         7,
			SessionsDefaultWindowHours:    24,
			SettlementsMaxWindowDays:      180,
			SettlementsDefaultWindowHours: 720,
			RequestsPerMinuteCap:          60,
		},
		Auth: AuthConfig{
			RequireProviderTokens: true,
		},
		Payout: PayoutConfig{
			Enabled: false,
			Security: PayoutSecurityConfig{
				PerPayoutCapUSDCBaseUnits:        500_000_000,    // $500
				PerDayCapUSDCBaseUnits:           5_000_000_000,  // $5,000
				CancelMaxTipMultiplier:           5.0,
				CancelMaxGasNativeWei:            10_000_000_000_000_000, // 0.01 ETH (1e16)
				CancelMaxGasNativeWeiPer24h:      50_000_000_000_000_000, // 0.05 ETH (5e16)
				AbandonRatePerHour:               3,
				ChainReconInterval:               time.Hour,
				ChainReconToleranceUSDCBaseUnits: 100_000, // $0.10
				PauseResumeMinInterval:           60 * time.Second,
			},
			Tuning: PayoutTuningConfig{
				AddressCoolingOffPeriod: 24 * time.Hour,
				RunInterval:             6 * time.Hour,
				RunNowMinInterval:       60 * time.Second,
				ConfirmationBlocks:      5,
				MaxRowsPerRun:           50,
				ReorgPollWindow:         24 * time.Hour,
			},
		},
	}
}

func Load(path string) (Config, error) {
	cfg := Default()
	b, err := os.ReadFile(path)
	if err != nil {
		return Config{}, err
	}
	if err := yaml.Unmarshal(b, &cfg); err != nil {
		return Config{}, err
	}
	if err := cfg.resolveEnv(); err != nil {
		return Config{}, err
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// payoutTuningOnlyWrapper is a minimal YAML envelope that surfaces
// only the payout.tuning.* namespace. Used by LoadPayoutTuningOnly
// so SIGHUP parsing cannot accidentally read or validate payout.security.*.
type payoutTuningOnlyWrapper struct {
	Payout struct {
		Tuning PayoutTuningConfig `yaml:"tuning"`
	} `yaml:"payout"`
}

// LoadPayoutTuningOnly parses ONLY the `payout.tuning.*` keys from
// the YAML at path and returns the validated snapshot. It intentionally
// does NOT read `payout.security.*`, does NOT call resolveEnv on any
// other field, and does NOT run full Config.Validate.
//
// Step 4 r1 [code:r1-3] MEDIUM closure: the SIGHUP loader MUST NOT
// couple tuning-reload success to immutable security fields. Callers
// that need the full config should use Load instead.
//
// Bound enforcement mirrors the §6.5 sub-set that applies to the
// tuning namespace only. The per_day_cap cross-check on
// low_balance_threshold is skipped because the security config is
// deliberately not loaded here; the bound is enforced by Validate at
// startup. On SIGHUP, TuningProvider.Reload applies its own in-memory
// cap check using the startup PerDayCapUSDCBaseUnits.
func LoadPayoutTuningOnly(path string) (PayoutTuningConfig, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return PayoutTuningConfig{}, err
	}
	// Start from defaults so missing keys inherit the startup values.
	defaults := Default()
	wrapper := payoutTuningOnlyWrapper{}
	wrapper.Payout.Tuning = defaults.Payout.Tuning
	if err := yaml.Unmarshal(b, &wrapper); err != nil {
		return PayoutTuningConfig{}, err
	}
	t := wrapper.Payout.Tuning
	// §6.5 tuning-namespace bound matrix — same as Validate's payout.tuning.* block.
	if t.AddressCoolingOffPeriod < time.Hour {
		return PayoutTuningConfig{}, fmt.Errorf("payout.tuning.address_cooling_off_period must be >= 1h (SPEC-016 §3.1)")
	}
	if t.RunInterval < 5*time.Minute || t.RunInterval > 24*time.Hour {
		return PayoutTuningConfig{}, fmt.Errorf("payout.tuning.run_interval must be in [5m, 24h] (SPEC-016 §6.5)")
	}
	if t.RunNowMinInterval < 10*time.Second || t.RunNowMinInterval > time.Hour {
		return PayoutTuningConfig{}, fmt.Errorf("payout.tuning.run_now_min_interval must be in [10s, 1h] (SPEC-016 §6.5)")
	}
	if t.ConfirmationBlocks < 5 || t.ConfirmationBlocks > 200 {
		return PayoutTuningConfig{}, fmt.Errorf("payout.tuning.confirmation_blocks must be in [5, 200] (SPEC-016 §6.5)")
	}
	if t.MaxRowsPerRun < 1 || t.MaxRowsPerRun > 500 {
		return PayoutTuningConfig{}, fmt.Errorf("payout.tuning.max_rows_per_run must be in [1, 500] (SPEC-016 §6.5)")
	}
	if t.ReorgPollWindow < time.Hour || t.ReorgPollWindow > 168*time.Hour {
		return PayoutTuningConfig{}, fmt.Errorf("payout.tuning.reorg_poll_window must be in [1h, 168h] (SPEC-016 §6.5)")
	}
	if t.LowBalanceThreshold < 0 {
		return PayoutTuningConfig{}, fmt.Errorf("payout.tuning.low_balance_threshold must be >= 0")
	}
	if t.LowNativeThreshold < 0 || t.LowNativeThreshold > 1_000_000_000_000_000_000 {
		return PayoutTuningConfig{}, fmt.Errorf("payout.tuning.low_native_threshold must be in [0, 1e18] (SPEC-016 §6.5)")
	}
	if err := validateSPKIPin(t.RPCURLPrimaryPinSPKI, "payout.tuning.rpc_url_primary_pin_spki"); err != nil {
		return PayoutTuningConfig{}, err
	}
	if err := validateSPKIPin(t.RPCURLSecondaryPinSPKI, "payout.tuning.rpc_url_secondary_pin_spki"); err != nil {
		return PayoutTuningConfig{}, err
	}
	return t, nil
}

// resolveEnv expands "env:NAME" sentinels in secret-bearing fields by
// reading the named environment variable. Mirrors the gateway-side
// resolver (M3-2 / DEVE-7) but is intentionally duplicated to avoid a
// cross-module import; the audit recorded "intentional duplication" as
// the house pattern for config plumbing.
//
// FAIL-CLOSED contract: when the YAML uses an env: sentinel and the
// referenced variable is unset OR empty, Load returns an error. Silent
// fall-through to "" would let the coordinator boot with an empty
// operator_key in places where Validate's "must be set" guard does not
// catch the substitution (e.g. future fields added to this resolver).
func (c *Config) resolveEnv() error {
	if v, err := resolveEnvValue("auth.operator_key", c.Auth.OperatorKey); err != nil {
		return err
	} else {
		c.Auth.OperatorKey = v
	}
	if v, err := resolveEnvValue("auth.gateway_service_token", c.Auth.GatewayServiceToken); err != nil {
		return err
	} else {
		c.Auth.GatewayServiceToken = v
	}
	if raw, ok := os.LookupEnv("GITHUB_OAUTH_ENABLED"); ok {
		switch raw {
		case "true":
			c.Auth.GitHubOAuth.Enabled = true
		case "false":
			c.Auth.GitHubOAuth.Enabled = false
		default:
			return fmt.Errorf("GITHUB_OAUTH_ENABLED must be \"true\" or \"false\"")
		}
	}
	if c.Auth.GitHubOAuth.Enabled {
		if v := strings.TrimSpace(os.Getenv("GITHUB_OAUTH_CLIENT_ID")); v != "" {
			c.Auth.GitHubOAuth.ClientID = v
		}
		if v := strings.TrimSpace(os.Getenv("GITHUB_OAUTH_CLIENT_SECRET")); v != "" {
			c.Auth.GitHubOAuth.ClientSecret = v
		}
		if v := strings.TrimSpace(os.Getenv("GITHUB_OAUTH_REDIRECT_URI")); v != "" {
			c.Auth.GitHubOAuth.RedirectURI = v
		}
		if v := strings.TrimSpace(os.Getenv("PORTAL_BASE_URL")); v != "" {
			c.Auth.GitHubOAuth.PortalBaseURL = strings.TrimRight(v, "/")
		}
		if v := strings.TrimSpace(os.Getenv("MP_SESSION_COOKIE_DOMAIN")); v != "" {
			c.Auth.GitHubOAuth.SessionCookieDomain = v
		}
	}
	// Step 4 r1 [sec:r1-4] MEDIUM closure: payout.security.* string
	// fields must honor the env:NAME indirection rule. The deploy gate
	// already validates env: presence; without this resolver the
	// coordinator boots with literal "env:..." RPC/wallet strings.
	if c.Payout.Enabled {
		if v, err := resolveEnvValue("payout.security.rpc_url_primary", c.Payout.Security.RPCURLPrimary); err != nil {
			return err
		} else {
			c.Payout.Security.RPCURLPrimary = v
		}
		if v, err := resolveEnvValue("payout.security.rpc_url_secondary", c.Payout.Security.RPCURLSecondary); err != nil {
			return err
		} else {
			c.Payout.Security.RPCURLSecondary = v
		}
		if v, err := resolveEnvValue("payout.security.hot_wallet_address", c.Payout.Security.HotWalletAddress); err != nil {
			return err
		} else {
			c.Payout.Security.HotWalletAddress = v
		}
		if v, err := resolveEnvValue("payout.security.encrypted_wallet_path", c.Payout.Security.EncryptedWalletPath); err != nil {
			return err
		} else {
			c.Payout.Security.EncryptedWalletPath = v
		}
	}
	return nil
}

func resolveEnvValue(field, v string) (string, error) {
	if !strings.HasPrefix(v, "env:") {
		return v, nil
	}
	name := strings.TrimPrefix(v, "env:")
	resolved := os.Getenv(name)
	if resolved == "" {
		return "", fmt.Errorf("%s references env:%s but the environment variable is unset or empty", field, name)
	}
	return resolved, nil
}

func (c Config) HeartbeatInterval() time.Duration {
	seconds := c.Pool.HeartbeatIntervalS
	if seconds <= 0 {
		seconds = Default().Pool.HeartbeatIntervalS
	}
	return time.Duration(seconds) * time.Second
}

func (c Config) FailoverTimeout() time.Duration {
	seconds := c.Routing.FailoverTimeoutS
	if seconds <= 0 {
		seconds = Default().Routing.FailoverTimeoutS
	}
	return time.Duration(seconds) * time.Second
}

// HeartbeatMissThreshold is how long a provider may go without any inbound
// frame before the liveness monitor closes its WebSocket. See PoolConfig.
func (c Config) HeartbeatMissThreshold() time.Duration {
	seconds := c.Pool.HeartbeatMissThresholdS
	if seconds <= 0 {
		seconds = Default().Pool.HeartbeatMissThresholdS
	}
	return time.Duration(seconds) * time.Second
}

func (c Config) ProviderWSHandshakeTimeout() time.Duration {
	seconds := c.WS.HandshakeTimeoutS
	if seconds <= 0 {
		seconds = Default().WS.HandshakeTimeoutS
	}
	return time.Duration(seconds) * time.Second
}

func (c Config) ProviderWSWriteTimeout() time.Duration {
	seconds := c.WS.WriteTimeoutS
	if seconds <= 0 {
		seconds = Default().WS.WriteTimeoutS
	}
	return time.Duration(seconds) * time.Second
}

func (c Config) ProviderWSMaxFrameBytes() int64 {
	bytes := c.WS.MaxFrameBytes
	if bytes <= 0 {
		bytes = Default().WS.MaxFrameBytes
	}
	return bytes
}

func (c Config) ProviderWSMaxUnauthenticatedConn() int {
	count := c.WS.MaxUnauthenticatedConn
	if count <= 0 {
		count = Default().WS.MaxUnauthenticatedConn
	}
	return count
}

func (c Config) ProviderWSMaxUnauthenticatedConnPerIP() int {
	count := c.WS.MaxUnauthenticatedConnPerIP
	if count <= 0 {
		count = Default().WS.MaxUnauthenticatedConnPerIP
	}
	return count
}

func (c Config) ProviderByID() map[string]ProviderConfig {
	out := make(map[string]ProviderConfig, len(c.Providers))
	for _, p := range c.Providers {
		out[p.ProviderID] = p
	}
	return out
}

func (c Config) Validate() error {
	if c.Auth.OperatorKey == "" {
		return fmt.Errorf("auth.operator_key must be set")
	}
	if err := c.validateGitHubOAuth(); err != nil {
		return err
	}
	if c.WS.WriteBufferSize <= 0 {
		return fmt.Errorf("ws.write_buffer_size must be > 0")
	}
	if c.WS.HandshakeTimeoutS <= 0 || c.WS.WriteTimeoutS <= 0 || c.WS.MaxFrameBytes <= 0 || c.WS.MaxUnauthenticatedConn <= 0 {
		return fmt.Errorf("ws handshake, write, frame, and unauthenticated connection limits must be > 0")
	}
	if c.WS.MaxUnauthenticatedConnPerIP <= 0 {
		return fmt.Errorf("ws.max_unauthenticated_conn_per_ip must be > 0")
	}
	if c.WS.MaxFrameBytes > 64<<20 {
		return fmt.Errorf("ws.max_frame_bytes must be <= 67108864")
	}
	if c.Routing.PreflightTimeoutS <= 0 || c.Routing.RequestTimeoutS <= 0 || c.Routing.FailoverTimeoutS <= 0 {
		return fmt.Errorf("routing timeouts must be > 0")
	}
	if c.Routing.TiebreakEpsilon < 0 {
		return fmt.Errorf("routing.tiebreak_epsilon must be >= 0")
	}
	if c.Routing.MaxRetries < 0 {
		return fmt.Errorf("routing.max_retries must be >= 0")
	}
	if c.Routing.RetryPerAttemptTimeoutS <= 0 {
		return fmt.Errorf("routing.retry_per_attempt_timeout_s must be > 0")
	}
	if c.Routing.MaxProvidersFaultedPerRequest < 0 {
		return fmt.Errorf("routing.max_providers_faulted_per_request must be >= 0")
	}
	if c.Routing.StickyTTLS <= 0 || c.Routing.StickyMaxEntries <= 0 {
		return fmt.Errorf("routing sticky settings must be > 0")
	}
	if c.ProviderHTTP.TimeoutS <= 0 {
		return fmt.Errorf("provider_http.timeout_s must be > 0")
	}
	if c.Limits.MaxChatRequestBodyBytes <= 0 {
		return fmt.Errorf("limits.max_chat_request_body_bytes must be > 0")
	}
	if c.Limits.MaxChatRequestBodyBytes > 128<<20 {
		return fmt.Errorf("limits.max_chat_request_body_bytes must be <= 128 MiB")
	}
	for name, class := range c.Routing.ModelClasses {
		if name == "" {
			return fmt.Errorf("routing.model_classes name must not be empty")
		}
		switch class.Objective {
		case "fast", "balanced", "accurate":
		default:
			return fmt.Errorf("routing.model_classes.%s.objective must be fast, balanced, or accurate", name)
		}
		if len(class.Members) == 0 && len(class.Models) == 0 {
			return fmt.Errorf("routing.model_classes.%s.models must not be empty", name)
		}
		if len(class.Members) > 0 && len(class.Models) > 0 {
			return fmt.Errorf("routing.model_classes.%s must not set both members and models", name)
		}
	}
	if c.Pool.DegradedBackoffS <= 0 || c.Pool.DegradedMaxRetries <= 0 {
		return fmt.Errorf("pool degraded recovery settings must be > 0")
	}
	if c.Pool.WarmupFallbackS <= 0 {
		return fmt.Errorf("pool warmup_fallback_s must be > 0")
	}
	if c.Pool.WarmupGateEnabled && (c.Pool.WarmupGateTimeoutS <= 0 || c.Pool.WarmupGateMaxTokens <= 0) {
		return fmt.Errorf("pool warmup gate settings must be > 0 when enabled")
	}
	if c.Pool.BreakerFailureThreshold <= 0 || c.Pool.BreakerWindowS <= 0 {
		return fmt.Errorf("pool breaker settings must be > 0")
	}
	if c.Pool.CanaryEnabled && (c.Pool.CanaryIntervalS <= 0 || c.Pool.CanaryTimeoutS <= 0 || c.Pool.CanaryMaxTokens <= 0 || c.Pool.CanaryFailureThreshold <= 0) {
		return fmt.Errorf("pool canary settings must be > 0 when enabled")
	}
	if c.Pool.CanaryEnabled {
		if len(c.Pool.CanaryChallenges) == 0 {
			return fmt.Errorf("pool canary_challenges must not be empty when enabled")
		}
		for i, challenge := range c.Pool.CanaryChallenges {
			if strings.TrimSpace(challenge.Prompt) == "" || strings.TrimSpace(challenge.Expected) == "" {
				return fmt.Errorf("pool canary_challenges[%d] prompt and expected must not be empty", i)
			}
			if !strings.Contains(challenge.Prompt, "{nonce}") || !strings.Contains(challenge.Expected, "{nonce}") {
				return fmt.Errorf("pool canary_challenges[%d] prompt and expected must contain {nonce}", i)
			}
		}
	}
	if c.Admission.ProvisionalAdmissionRatePerHour <= 0 {
		return fmt.Errorf("admission.provisional_admission_rate_per_hour must be > 0")
	}
	if c.Admission.ProvisionalPoolMax <= 0 {
		return fmt.Errorf("admission.provisional_pool_max must be > 0")
	}
	if c.Admission.ProvisionalQuotaPerHour <= 0 {
		return fmt.Errorf("admission.provisional_quota_per_hour must be > 0")
	}
	if c.Admission.ProvisionalTierWeight <= 0 {
		return fmt.Errorf("admission.provisional_tier_weight must be > 0")
	}
	if c.Tier2.CatalogPath != "" && c.Tier2.CatalogPublicKey == "" {
		return fmt.Errorf("tier2.catalog_public_key must be set when tier2.catalog_path is set")
	}
	if c.Tier2.RequireHashVerified && (c.Tier2.CatalogPath == "" || c.Tier2.CatalogPublicKey == "") {
		return fmt.Errorf("tier2.require_hash_verified requires a valid signed catalog configuration")
	}
	if c.Tier2.EncryptedLegAEAD != "A256GCM" {
		return fmt.Errorf("tier2.encrypted_leg_aead must be A256GCM")
	}
	if c.Tier2.EncryptedLegRekeyAfterRequests <= 0 {
		return fmt.Errorf("tier2.encrypted_leg_rekey_after_requests must be > 0")
	}
	if c.Tier2.EncryptedLegRekeyAfterSeconds <= 0 {
		return fmt.Errorf("tier2.encrypted_leg_rekey_after_seconds must be > 0")
	}
	if c.Tier2.RequireAttestation && len(c.Tier2.AttestationRoots) == 0 {
		return fmt.Errorf("tier2.require_attestation requires at least one attestation root")
	}
	for _, root := range c.Tier2.AttestationRoots {
		if c.Tier2.RequireAttestation && root == "mock-root" {
			return fmt.Errorf("tier2.attestation_roots must not include mock-root when tier2.require_attestation is true")
		}
		if root == "mock-root" && !c.Tier2.AllowMockAttestation {
			return fmt.Errorf("tier2.attestation_roots must not include mock-root unless tier2.allow_mock_attestation is true")
		}
	}
	if c.Tier2.AttestationMaxAgeS <= 0 {
		return fmt.Errorf("tier2.attestation_max_age_s must be > 0")
	}
	if c.Tier2.OutputSizeCapBytes < 0 {
		return fmt.Errorf("tier2.output_size_cap_bytes must be >= 0")
	}
	if c.Tier2.OutputBytesPerTokenCeiling <= 0 {
		return fmt.Errorf("tier2.output_bytes_per_token_ceiling must be > 0")
	}
	if c.Tier2.DefaultOutputSizeCapBytes <= 0 {
		return fmt.Errorf("tier2.default_output_size_cap_bytes must be > 0")
	}
	if c.Tier2.ResponseTimeAnomalyFactor <= 1.0 {
		return fmt.Errorf("tier2.response_time_anomaly_factor must be > 1.0")
	}
	if c.Tier2.ResponseTimeAnomalyMinMS < 0 {
		return fmt.Errorf("tier2.response_time_anomaly_min_ms must be >= 0")
	}
	if c.Rewards.ProviderShare < 0 || c.Rewards.ProviderShare > 1 {
		return fmt.Errorf("rewards.provider_share must be in [0.0, 1.0]")
	}
	if c.Rewards.GlobalMultiplier <= 0 {
		return fmt.Errorf("rewards.global_multiplier must be > 0")
	}
	if c.Settlement.CadenceDays <= 0 {
		return fmt.Errorf("settlement.cadence_days must be > 0")
	}
	if c.Settlement.MinPayoutCredits < 0 {
		return fmt.Errorf("settlement.min_payout_credits must be >= 0")
	}
	if c.Settlement.StartupReconcileWindowHours <= 0 {
		return fmt.Errorf("settlement.startup_reconcile_window_hours must be > 0")
	}
	if c.Settlement.NightlyReconcileWindowDays <= 0 {
		return fmt.Errorf("settlement.nightly_reconcile_window_days must be > 0")
	}
	if c.Settlement.RecoveryGraceSeconds < 0 {
		return fmt.Errorf("settlement.recovery_grace_seconds must be >= 0")
	}
	if c.Storage.RequestLogRetentionDays <= 0 {
		return fmt.Errorf("storage.request_log_retention_days must be > 0")
	}
	if c.Storage.AuditLogRetentionDays < minAuditLogRetentionDays {
		return fmt.Errorf("storage.audit_log_retention_days must be >= %d (compliance floor)", minAuditLogRetentionDays)
	}
	if c.Storage.RequestLogRetentionDays < c.Settlement.NightlyReconcileWindowDays {
		return fmt.Errorf("storage.request_log_retention_days must be >= settlement.nightly_reconcile_window_days")
	}
	if c.Endpoints.ProviderEarnings.RateLimitPerMinute <= 0 {
		return fmt.Errorf("endpoints.provider_earnings.rate_limit_per_minute must be > 0")
	}
	if err := c.validateExplorer(); err != nil {
		return err
	}
	if _, ok := c.Rewards.RateCard["default"]; !ok {
		return fmt.Errorf("rewards.rate_card must contain default")
	}
	for model, entry := range c.Rewards.RateCard {
		if entry.PromptCreditsPerMtok < 0 || entry.CompletionCreditsPerMtok < 0 {
			return fmt.Errorf("rewards.rate_card.%s rates must be >= 0", model)
		}
	}
	seen := map[string]struct{}{}
	for _, p := range c.Providers {
		if !providerIDPattern.MatchString(p.ProviderID) {
			return fmt.Errorf("invalid provider_id %q", p.ProviderID)
		}
		if _, ok := seen[p.ProviderID]; ok {
			return fmt.Errorf("duplicate provider_id %q", p.ProviderID)
		}
		seen[p.ProviderID] = struct{}{}
		if p.EndpointURL != "" {
			if err := ValidateEndpointURL(p.EndpointURL); err != nil {
				return fmt.Errorf("provider %q endpoint_url must be a valid https URL (http allowed only for 127.0.0.1/localhost)", p.ProviderID)
			}
		}
	}
	if c.Payout.Enabled {
		if c.Payout.Security.HotWalletAddress == "" {
			return fmt.Errorf("payout.security.hot_wallet_address must be set when payout.enabled is true")
		}
		if c.Payout.Security.RPCURLPrimary == "" || c.Payout.Security.RPCURLSecondary == "" {
			return fmt.Errorf("payout.security.rpc_url_primary and rpc_url_secondary must both be set (SPEC-016 §4.4 two-RPC discipline)")
		}
		if c.Payout.Security.RPCURLPrimary == c.Payout.Security.RPCURLSecondary {
			return fmt.Errorf("payout.security.rpc_url_primary and rpc_url_secondary must differ (SPEC-016 §4.4 trust separation)")
		}
		if c.Payout.Security.PerPayoutCapUSDCBaseUnits <= 0 {
			return fmt.Errorf("payout.security.per_payout_cap_usdc_base_units must be > 0")
		}
		if c.Payout.Security.PerDayCapUSDCBaseUnits <= 0 {
			return fmt.Errorf("payout.security.per_day_cap_usdc_base_units must be > 0")
		}
		if c.Payout.Security.PerDayCapUSDCBaseUnits < c.Payout.Security.PerPayoutCapUSDCBaseUnits {
			return fmt.Errorf("payout.security.per_day_cap_usdc_base_units must be >= per_payout_cap_usdc_base_units")
		}
		if c.Payout.Security.CancelMaxTipMultiplier < 1.0 {
			return fmt.Errorf("payout.security.cancel_max_tip_multiplier must be >= 1.0")
		}
		if c.Payout.Security.CancelMaxGasNativeWei <= 0 {
			return fmt.Errorf("payout.security.cancel_max_gas_native_wei must be > 0")
		}
		if c.Payout.Security.CancelMaxGasNativeWeiPer24h < c.Payout.Security.CancelMaxGasNativeWei {
			return fmt.Errorf("payout.security.cancel_max_gas_native_wei_per_24h must be >= cancel_max_gas_native_wei")
		}
		if c.Payout.Security.AbandonRatePerHour <= 0 {
			return fmt.Errorf("payout.security.abandon_rate_per_hour must be > 0")
		}
		if c.Payout.Security.ChainReconInterval < time.Minute {
			return fmt.Errorf("payout.security.chain_recon_interval must be >= 1m")
		}
		if c.Payout.Security.ChainReconToleranceUSDCBaseUnits <= 0 {
			return fmt.Errorf("payout.security.chain_recon_tolerance_usdc_base_units must be > 0")
		}
		if c.Payout.Security.PauseResumeMinInterval < time.Second {
			return fmt.Errorf("payout.security.pause_resume_min_interval must be >= 1s")
		}
		if !c.Payout.Security.DevMode && c.Payout.Security.EncryptedWalletPath == "" {
			return fmt.Errorf("payout.security.encrypted_wallet_path must be set when payout.enabled=true (SPEC §6.3); set payout.security.dev_mode=true ONLY for non-production hosts")
		}
		if c.Payout.Tuning.AddressCoolingOffPeriod < time.Hour {
			return fmt.Errorf("payout.tuning.address_cooling_off_period must be >= 1h (SPEC-016 §3.1)")
		}
		if c.Payout.Tuning.RunInterval < 5*time.Minute || c.Payout.Tuning.RunInterval > 24*time.Hour {
			return fmt.Errorf("payout.tuning.run_interval must be in [5m, 24h] (SPEC-016 §6.5)")
		}
		if c.Payout.Tuning.RunNowMinInterval < 10*time.Second || c.Payout.Tuning.RunNowMinInterval > time.Hour {
			return fmt.Errorf("payout.tuning.run_now_min_interval must be in [10s, 1h] (SPEC-016 §6.5)")
		}
		if c.Payout.Tuning.ConfirmationBlocks < 5 || c.Payout.Tuning.ConfirmationBlocks > 200 {
			return fmt.Errorf("payout.tuning.confirmation_blocks must be in [5, 200] (SPEC-016 §6.5 v0.1.20 round-20 M2 closure widened from [2, 50])")
		}
		if c.Payout.Tuning.MaxRowsPerRun < 1 || c.Payout.Tuning.MaxRowsPerRun > 500 {
			return fmt.Errorf("payout.tuning.max_rows_per_run must be in [1, 500] (SPEC-016 §6.5)")
		}
		if c.Payout.Tuning.ReorgPollWindow < time.Hour || c.Payout.Tuning.ReorgPollWindow > 168*time.Hour {
			return fmt.Errorf("payout.tuning.reorg_poll_window must be in [1h, 168h] (SPEC-016 §6.5 v0.1.20 round-20 M1 closure)")
		}
		if c.Payout.Tuning.LowBalanceThreshold < 0 {
			return fmt.Errorf("payout.tuning.low_balance_threshold must be >= 0")
		}
		if c.Payout.Tuning.LowBalanceThreshold > 0 && c.Payout.Tuning.LowBalanceThreshold > 2*c.Payout.Security.PerDayCapUSDCBaseUnits {
			return fmt.Errorf("payout.tuning.low_balance_threshold must be <= 2 * per_day_cap_usdc_base_units (SPEC-016 §6.5)")
		}
		if c.Payout.Tuning.LowNativeThreshold < 0 || c.Payout.Tuning.LowNativeThreshold > 1_000_000_000_000_000_000 {
			return fmt.Errorf("payout.tuning.low_native_threshold must be in [0, 1e18] (SPEC-016 §6.5)")
		}
		if err := validateSPKIPin(c.Payout.Tuning.RPCURLPrimaryPinSPKI, "payout.tuning.rpc_url_primary_pin_spki"); err != nil {
			return err
		}
		if err := validateSPKIPin(c.Payout.Tuning.RPCURLSecondaryPinSPKI, "payout.tuning.rpc_url_secondary_pin_spki"); err != nil {
			return err
		}
	}
	return nil
}

func (c Config) validateGitHubOAuth() error {
	oauth := c.Auth.GitHubOAuth
	if !oauth.Enabled {
		return nil
	}
	if strings.TrimSpace(oauth.ClientID) == "" {
		return fmt.Errorf("GITHUB_OAUTH_CLIENT_ID must be set when GITHUB_OAUTH_ENABLED=true")
	}
	if strings.TrimSpace(oauth.ClientSecret) == "" {
		return fmt.Errorf("GITHUB_OAUTH_CLIENT_SECRET must be set when GITHUB_OAUTH_ENABLED=true")
	}
	redirect, err := url.Parse(strings.TrimSpace(oauth.RedirectURI))
	if err != nil || redirect.Scheme != "https" || redirect.Host == "" || redirect.Path != "/v1/auth/github/callback" || redirect.RawQuery != "" || redirect.Fragment != "" {
		return fmt.Errorf("GITHUB_OAUTH_REDIRECT_URI must be https://.../v1/auth/github/callback when GITHUB_OAUTH_ENABLED=true")
	}
	portal, err := url.Parse(strings.TrimSpace(oauth.PortalBaseURL))
	if err != nil || portal.Scheme != "https" || portal.Host == "" || portal.Path != "" || portal.RawQuery != "" || portal.Fragment != "" || portal.User != nil {
		return fmt.Errorf("PORTAL_BASE_URL must be https://<host>[:<port>] with no path or query when GITHUB_OAUTH_ENABLED=true")
	}
	if oauth.SessionCookieDomain != "" {
		domain := strings.TrimPrefix(strings.ToLower(strings.TrimSpace(oauth.SessionCookieDomain)), ".")
		host := strings.ToLower(portal.Hostname())
		if domain == "" || host != domain && !strings.HasSuffix(host, "."+domain) {
			return fmt.Errorf("MP_SESSION_COOKIE_DOMAIN must match PORTAL_BASE_URL host scope")
		}
	}
	return nil
}

func (c Config) validateExplorer() error {
	if c.Explorer.Enabled && c.Auth.OperatorKey == "" {
		return fmt.Errorf("auth.operator_key must be set when explorer.enabled is true")
	}
	if !strings.HasPrefix(c.Explorer.BindPath, "/admin/explorer/") || !strings.HasSuffix(c.Explorer.BindPath, "/") {
		return fmt.Errorf("explorer.bind_path must begin with /admin/explorer/ and end with /")
	}
	if err := validateExplorerWindow("explorer.activity", c.Explorer.ActivityMaxWindowDays, c.Explorer.ActivityDefaultWindowHours, 1, 31); err != nil {
		return err
	}
	if err := validateExplorerWindow("explorer.buyers", c.Explorer.BuyersMaxWindowDays, c.Explorer.BuyersDefaultWindowHours, 1, 31); err != nil {
		return err
	}
	if err := validateExplorerWindow("explorer.ledger", c.Explorer.LedgerMaxWindowDays, c.Explorer.LedgerDefaultWindowHours, 1, 31); err != nil {
		return err
	}
	if err := validateExplorerWindow("explorer.sessions", c.Explorer.SessionsMaxWindowDays, c.Explorer.SessionsDefaultWindowHours, 1, 31); err != nil {
		return err
	}
	if err := validateExplorerWindow("explorer.settlements", c.Explorer.SettlementsMaxWindowDays, c.Explorer.SettlementsDefaultWindowHours, 31, 365); err != nil {
		return err
	}
	if c.Explorer.GatewayTimeoutMs < 100 || c.Explorer.GatewayTimeoutMs > 5000 {
		return fmt.Errorf("explorer.gateway_timeout_ms must be between 100 and 5000")
	}
	if c.Explorer.QueryTimeoutMs < 100 || c.Explorer.QueryTimeoutMs > 5000 {
		return fmt.Errorf("explorer.query_timeout_ms must be between 100 and 5000")
	}
	if c.Explorer.PollMinIntervalSeconds < 1 || c.Explorer.PollMinIntervalSeconds > 60 {
		return fmt.Errorf("explorer.poll_min_interval_seconds must be between 1 and 60")
	}
	if c.Explorer.RequestsPerMinuteCap < 1 || c.Explorer.RequestsPerMinuteCap > 60 {
		return fmt.Errorf("explorer.requests_per_minute_cap must be between 1 and 60")
	}
	if c.Explorer.Enabled && c.Explorer.GatewayBaseURL != "" {
		u, err := url.Parse(c.Explorer.GatewayBaseURL)
		if err != nil || u.Scheme == "" || u.Host == "" {
			return fmt.Errorf("explorer.gateway_base_url must be an absolute URL when set")
		}
		if u.User != nil {
			return fmt.Errorf("explorer.gateway_base_url must not contain userinfo")
		}
		if u.Scheme != "https" && !(u.Scheme == "http" && isLoopbackHost(u.Hostname())) {
			return fmt.Errorf("explorer.gateway_base_url must use https unless targeting loopback")
		}
	}
	return nil
}

func isLoopbackHost(host string) bool {
	switch strings.ToLower(host) {
	case "localhost", "127.0.0.1", "::1":
		return true
	default:
		return false
	}
}

func validateExplorerWindow(prefix string, maxDays, defaultHours, minDays, maxDaysAllowed int) error {
	if maxDays < minDays || maxDays > maxDaysAllowed {
		return fmt.Errorf("%s_max_window_days must be between %d and %d", prefix, minDays, maxDaysAllowed)
	}
	if defaultHours < 1 || defaultHours > maxDays*24 {
		return fmt.Errorf("%s_default_window_hours must be between 1 and %d", prefix, maxDays*24)
	}
	return nil
}

// validateSPKIPin checks SPEC-016 §6.5 syntactic bounds on a
// pinned SHA-256 SPKI fingerprint. Empty disables pinning;
// otherwise the value MUST be exactly 64 hex chars (lowercase
// or uppercase). Content-correctness (the value actually matching
// the RPC's served cert) is operational, not parse-time.
func validateSPKIPin(value, name string) error {
	if value == "" {
		return nil
	}
	if len(value) != 64 {
		return fmt.Errorf("%s must be empty or 64 hex chars (got %d chars)", name, len(value))
	}
	for _, r := range value {
		if (r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F') {
			continue
		}
		return fmt.Errorf("%s must be empty or a valid 64-hex-char SHA-256", name)
	}
	return nil
}

func ValidateEndpointURL(endpoint string) error {
	u, err := url.Parse(endpoint)
	if err != nil || u.Host == "" {
		return fmt.Errorf("endpoint_url must be a valid URL")
	}
	isLocal := u.Hostname() == "127.0.0.1" || u.Hostname() == "localhost"
	if u.Scheme != "https" && !(u.Scheme == "http" && isLocal) {
		return fmt.Errorf("endpoint_url must be a valid https URL")
	}
	return nil
}
