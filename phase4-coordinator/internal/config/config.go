package config

import (
	"encoding/json"
	"fmt"
	"math"
	"net/netip"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

var providerIDPattern = regexp.MustCompile(`^[a-zA-Z0-9_.-]{1,64}$`)

// ValidateProviderID is the canonical validator for ProviderID across every
// registration path. Issue #274: WS self-serve registration previously
// accepted any non-empty / non-control-char string, while configured pinned
// providers were already gated on providerIDPattern. The "/" delimiter used
// by pool.Provider.SortKey (ProviderID + "/" + AssignedID) is only
// unambiguous when no ProviderID contains "/" — so every code path that
// onboards a provider (configured pinned, WS Hello, WS auth_request
// initial/proof, admission IssueToken, MintAdmissionTokenAndPairOT) MUST
// funnel through this helper to keep that invariant.
func ValidateProviderID(s string) error {
	if !providerIDPattern.MatchString(s) {
		return fmt.Errorf("invalid provider_id %q", s)
	}
	return nil
}

// minAuditLogRetentionDays is the compliance floor for audit_log retention.
// Operators may not set audit_log_retention_days below this value.
const minAuditLogRetentionDays = 90

type Config struct {
	Listen                       ListenConfig                 `yaml:"listen"`
	Coordinator                  CoordinatorConfig            `yaml:"coordinator"`
	Pool                         PoolConfig                   `yaml:"pool"`
	Routing                      RoutingConfig                `yaml:"routing"`
	ProviderHTTP                 ProviderHTTPConfig           `yaml:"provider_http"`
	Limits                       LimitsConfig                 `yaml:"limits"`
	WS                           WSConfig                     `yaml:"ws"`
	Relay                        RelayConfig                  `yaml:"relay"`
	Admission                    AdmissionConfig              `yaml:"admission"`
	Tier2                        Tier2Config                  `yaml:"tier2"`
	CoordinatorAdvertisedVersion CoordinatorAdvertisedVersion `yaml:"coordinator_advertised_version"`
	Auth                         AuthConfig                   `yaml:"auth"`
	Storage                      StorageConfig                `yaml:"storage"`
	Logging                      LoggingConfig                `yaml:"logging"`
	Rewards                      RewardsConfig                `yaml:"rewards"`
	Settlement                   SettlementConfig             `yaml:"settlement"`
	Billing                      BillingConfig                `yaml:"billing"`
	Endpoints                    EndpointsConfig              `yaml:"endpoints"`
	Explorer                     ExplorerConfig               `yaml:"explorer"`
	Stats                        StatsConfig                  `yaml:"stats"`
	Onboarding                   OnboardingConfig             `yaml:"onboarding"`
	MalibuEmission               MalibuEmissionConfig         `yaml:"malibu_emission"`
	AutotuneFeeds                AutotuneFeedsConfig          `yaml:"autotune"`
	ProofOfWeights               ProofOfWeightsConfig         `yaml:"proof_of_weights"`
	Proxy                        ProxyConfig                  `yaml:"proxy"`
	Providers                    []ProviderConfig             `yaml:"providers"`
}

// ProofOfWeightsConfig gates Session B integrity controls. Defaults keep
// legacy self-declared hello model_id behavior until the operator enables
// the autotune hello gate explicitly.
type ProofOfWeightsConfig struct {
	RequireAutotuneHelloGate bool                 `yaml:"require_autotune_hello_gate"`
	AutotuneEvidenceTTLDays  int                  `yaml:"autotune_evidence_ttl_days"`
	TelemetryDrift           TelemetryDriftConfig `yaml:"telemetry_drift"`
}

// TelemetryDriftConfig enables observe-only operator alerts when live
// provider telemetry diverges from verified autotune evidence or W3 OPoI
// pass-rate baselines. Default-off; does not change routing or sanctions.
type TelemetryDriftConfig struct {
	Enabled                  bool     `yaml:"enabled"`
	TPSRatioThreshold        float64  `yaml:"tps_ratio_threshold"`
	TPSMinAbsolute           float64  `yaml:"tps_min_absolute"`
	TPSMinRequestsWindow     int      `yaml:"tps_min_requests_window"`
	HashAlertOnStatus        []string `yaml:"hash_alert_on_status"`
	HashAlertOnArtifactDrift bool     `yaml:"hash_alert_on_artifact_drift"`
	OPoIPassRateWindow       int      `yaml:"opoi_pass_rate_window"`
	OPoIPassRateThreshold    float64  `yaml:"opoi_pass_rate_threshold"`
	AlertCooldownSeconds     int      `yaml:"alert_cooldown_s"`
}

type CoordinatorConfig struct {
	RequireGatewayContext bool `yaml:"require_gateway_context"`
}

// OnboardingConfig gates SPEC-026 App-track `/v1/providers/register`.
// Default-off preserves backward-compatible binary rollout; production
// traffic enablement waits for the SPEC-026 §4.3 proof-stage verifier.
type OnboardingConfig struct {
	AppTrackRegisterEnabled bool              `yaml:"app_track_register_enabled"`
	PostgresDSN             string            `yaml:"postgres_dsn"`
	AuthPolicyRequestDSN    string            `yaml:"auth_policy_request_dsn"`
	AuthPolicyApproveDSN    string            `yaml:"auth_policy_approve_dsn"`
	AuthPolicyCutoverDSN    string            `yaml:"auth_policy_cutover_dsn"`
	BundleID                string            `yaml:"bundle_id"`
	AppleTeamID             string            `yaml:"apple_team_id"`
	CoordinatorDomain       string            `yaml:"coordinator_domain"`
	ASNPrefixes             map[string]string `yaml:"asn_prefixes"`
}

// MalibuEmissionConfig gates SPEC-MALIBU-EMISSION-LEDGER bootstrap accrual.
// Default-off; money-path changes require PR + audit.
type MalibuEmissionConfig struct {
	Enabled                     bool     `yaml:"enabled"`
	WriterDSN                   string   `yaml:"writer_dsn"`
	TickIntervalSeconds         int      `yaml:"tick_interval_seconds"`
	ProviderDailyCapMALIBU      float64  `yaml:"provider_daily_cap_malibu"`
	WalletDailyCapMALIBU        float64  `yaml:"wallet_daily_cap_malibu"`
	SQLitePayoutDBPath          string   `yaml:"sqlite_payout_db_path"`
	WalletMirrorIntervalSeconds int      `yaml:"wallet_mirror_interval_seconds"`
	UnlockEvalIntervalSeconds   int      `yaml:"unlock_eval_interval_seconds"`
	MaxSerializableRetries      int      `yaml:"max_serializable_retries"`
	BaseUSDCBalanceRPCURLs      []string `yaml:"base_usdc_balance_rpc_urls"`
}

// AutotuneFeedsConfig points at the signed SPEC-023 recommendation feeds
// served on the buyer mux (/v1/demand-rank, /v1/autotune-candidates, and
// their .sig sidecars). Empty paths disable that feed (404).
type AutotuneFeedsConfig struct {
	DemandRankPath            string `yaml:"demand_rank_path"`
	DemandRankSigPath         string `yaml:"demand_rank_sig_path"`
	AutotuneCandidatesPath    string `yaml:"autotune_candidates_path"`
	AutotuneCandidatesSigPath string `yaml:"autotune_candidates_sig_path"`
}

// StatsConfig is the SPEC-017 Network Stats API config block.
//
// All DSN fields are sourced from env at deploy time per the
// existing config-loader env-override pattern; storing plaintext
// DSNs in coordinator.yaml is a SECURITY violation and the
// validator MAY refuse to start if a DSN appears literal-shaped
// in the YAML file. v0.1 IMPL trusts the env-override path; the
// validator does not pattern-match against the YAML body
// (operator-managed secret hygiene).
//
// Stats.Enabled defaults to false so existing coordinator
// deployments continue to function unchanged at upgrade time —
// the /v1/stats/* mux subtree is not registered until the
// operator flips this flag (BUILD §C.4).
type StatsConfig struct {
	Enabled bool `yaml:"enabled"`

	// DSNs per active daemon role. When Enabled = true, the
	// reader and rollup DSNs MUST be non-empty. ProviderPortalDSN
	// is retained for portal/operator tooling compatibility but
	// is not opened by the public stats daemon.
	ReaderDSN         string `yaml:"reader_dsn"`
	RollupDSN         string `yaml:"rollup_dsn"`
	ProviderPortalDSN string `yaml:"provider_portal_dsn"`

	// PartnerKeys gates the optional partner_keys_writer pool.
	// v0.1 default: LastUsedAtUpdatesEnabled=false; WriterDSN
	// unused (BUILD §C.2).
	PartnerKeys StatsPartnerKeysConfig `yaml:"partner_keys"`

	// PartnerKeysAdminDSN is the CLI operator DSN (Step 4.A).
	// Step 1 declares the field; coordinator startup MUST NOT
	// open a pool for it (BUILD §D.6 / SECURITY §B.1).
	PartnerKeysAdminDSN string `yaml:"partner_keys_admin_dsn"`

	Rollup           StatsRollupConfig           `yaml:"rollup"`
	CORS             StatsCORSConfig             `yaml:"cors"`
	RateLimit        StatsRateLimitConfig        `yaml:"rate_limit"`
	StreamingMetrics StatsStreamingMetricsConfig `yaml:"streaming_metrics"`

	// TrustedProxies — operator-allowlisted X-Forwarded-For
	// trusted hops, consumed by Step 3's auth-failure tier
	// limiter for client-IP derivation (SPEC §5.6 v0.1.8 +
	// SECURITY r5 H1). Step 1 declares; Step 3 consumes.
	TrustedProxies  []string `yaml:"trusted_proxies"`
	TrustDirectPeer bool     `yaml:"trust_direct_peer"`
}

type StatsRateLimitConfig struct {
	MaxBuckets              int `yaml:"max_buckets"`
	IdleTTLSeconds          int `yaml:"idle_ttl_seconds"`
	EvictionIntervalSeconds int `yaml:"eviction_interval_seconds"`
	PreflightRPM            int `yaml:"preflight_rpm"`
}

type StatsStreamingMetricsConfig struct {
	MaxSamples int `yaml:"max_samples"`
}

type StatsPartnerKeysConfig struct {
	LastUsedAtUpdatesEnabled bool   `yaml:"last_used_at_updates_enabled"`
	WriterDSN                string `yaml:"writer_dsn"`

	// ProductionSignoffPath is the v0.1.8 erratum
	// (2026-06-26) mechanical gate for SPEC §6.6.2's
	// launch-sequencing precondition. When this field is set
	// on a deployed coordinator config, `partner-keys issue`
	// reads the file at this path AND requires its content
	// to match the SPEC-014 SHA + YYYY-MM-DD sign-off
	// template (see OPS.md §10.5). Issuance fails closed if
	// the file is missing, empty, or malformed.
	//
	// When this field is UNSET (empty), the coordinator is
	// treated as staging — no preconditions apply, and
	// `partner-keys issue` operates against fixture DSNs
	// without sign-off. Production deploys MUST set this
	// field in coordinator.yaml; staging / test fixtures
	// MUST NOT.
	//
	// ARCH r3 CRITICAL closure: the gate is config-driven
	// (rather than opt-in via a `--production` CLI flag) so
	// a wrapper-script automation that forgets the flag
	// cannot accidentally bypass the runbook sign-off. The
	// deployed config is the source of truth for
	// "is this coordinator production".
	ProductionSignoffPath string `yaml:"production_signoff_path"`
}

type StatsRollupConfig struct {
	// BackfillMode is "partial" (Path A, default per
	// [[macprovider-vercel-demo]] thin-ship pattern) or "full"
	// (Path B). See SPEC §9.7.
	BackfillMode string `yaml:"backfill_mode"`
	// PartialHistorySince is the RFC 3339 rollup-start
	// timestamp. Empty when BackfillMode = "full". Step 2/3
	// consume.
	PartialHistorySince string `yaml:"partial_history_since"`
	// LateEventsRetentionDays — SPEC §9.3 (v0.1.7). Default 90;
	// floor 30. Step 2 floor-clamps with a WARN log; below-floor
	// values DO NOT fail startup (chosen pin: clamp+warn).
	LateEventsRetentionDays int `yaml:"late_events_retention_days"`
	// UsdPerMillionCredits — credits→USD conversion factor.
	// SPEC-005 v0.3 stores `ledger_request_credits.provider_credits`
	// as INTEGER credits; SPEC-016 v0.1.19 has not normatively
	// pinned a credit→USD ratio. SPEC-017 v0.1 IMPL exposes this
	// as a single operator-tunable factor: rollup computes
	// `earnings_work_usd = provider_credits * UsdPerMillionCredits
	// / 1_000_000`. Default 1.0 (1 USD per million credits).
	// Operator MAY override per ramp; the formula is documented
	// in OPS.md.
	UsdPerMillionCredits float64 `yaml:"usd_per_million_credits"`
	// DriftThresholdRatio — fractional divergence (>0.005 = >0.5%
	// per SPEC §9.4) at which the nightly rebuild emits
	// `stats_rollup_drift_detected`. Operator MAY tune within
	// [0.001, 0.05]; default 0.005.
	DriftThresholdRatio float64 `yaml:"drift_threshold_ratio"`
	// NightlyRebuildHourUTC — UTC hour [0,23] for the nightly
	// `stats_leaderboard_all` + `stats_leaderboard_30d` rebuild.
	// Default 9 per SPEC §9.3 (operator-pin off-hours).
	NightlyRebuildHourUTC int `yaml:"nightly_rebuild_hour_utc"`
	// LateEventsLookbackHours — SPEC §9.3 48h default; operator
	// MAY raise to 72/96. Lower than 24 breaks the 1× SPEC-005
	// reconciliation-margin invariant.
	LateEventsLookbackHours int `yaml:"late_events_lookback_hours"`
}

type StatsCORSConfig struct {
	// AccessControlMaxAgeSeconds — SPEC §5.7 v0.1.7 default 60,
	// operator may raise via runtime config to ≤300; >300
	// requires a SPEC bump. Step 3 consumes; Step 1 only
	// declares.
	AccessControlMaxAgeSeconds int      `yaml:"access_control_max_age_seconds"`
	PartnerOriginAllowlist     []string `yaml:"partner_origin_allowlist"`
}

// ProxyConfig configures how the coordinator interprets `X-Forwarded-For` /
// `X-Real-IP` headers when deriving per-buyer rate-limit keys. Issue #125
// (post-PR-#124 follow-up): production sits behind nginx on loopback, so
// the default trusted-proxies list `["127.0.0.0/8", "::1/128"]` covers
// that topology. Operators deploying behind a remote LB or non-loopback
// reverse proxy MUST add the proxy's CIDR(s) here; otherwise the
// coordinator will treat the proxy as untrusted and key the rate-limit
// bucket on the proxy's IP — collapsing all upstream buyers into one
// shared bucket. Conversely, expanding this list to non-actual-proxy
// CIDRs lets attackers in those CIDRs spoof their bucket key via
// `X-Forwarded-For`; treat the list as security-sensitive.
type ProxyConfig struct {
	// TrustedProxies is a list of CIDR ranges whose `X-Forwarded-For` /
	// `X-Real-IP` headers the coordinator will honor when deriving the
	// per-source rate-limit key for `/v1/pool/check`, `/v1/receipt-keys/*`,
	// and `/catalog/*`. Default `["127.0.0.0/8", "::1/128"]` matches the
	// production nginx-on-localhost topology (see
	// `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf`).
	// Invalid CIDRs and default-route prefixes (`0.0.0.0/0`, `::/0`)
	// fail `config.Load` at startup via `TrustedProxyPrefixes`.
	TrustedProxies []string `yaml:"trusted_proxies"`
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
	WakeGapThresholdMs      int                                `yaml:"wake_gap_threshold_ms"`
	WarmupFallbackS         int                                `yaml:"warmup_fallback_s"`
	WarmupGateEnabled       bool                               `yaml:"warmup_gate_enabled"`
	WarmupGateTimeoutS      int                                `yaml:"warmup_gate_timeout_s"`
	WarmupGateMaxTokens     int                                `yaml:"warmup_gate_max_tokens"`
	DegradedBackoffS        int                                `yaml:"degraded_backoff_s"`
	DegradedMaxRetries      int                                `yaml:"degraded_max_retries"`
	DegradedProbeAfter502   bool                               `yaml:"degraded_probe_after_502"`
	BreakerFailureThreshold int                                `yaml:"breaker_failure_threshold"`
	BreakerWindowS          int                                `yaml:"breaker_window_s"`
	CanaryEnabled           bool                               `yaml:"canary_enabled"`
	CanaryIntervalS         int                                `yaml:"canary_interval_s"`
	CanaryTimeoutS          int                                `yaml:"canary_timeout_s"`
	CanaryMaxTokens         int                                `yaml:"canary_max_tokens"`
	CanaryFailureThreshold  int                                `yaml:"canary_failure_threshold"`
	// CanaryColdStartGraceS relaxes the WALL-TIME latency gates (max_ttft_ms and
	// min_sustained_tps) for the first grace-window seconds after a provider
	// connects. Canary probes are non-streaming, so both metrics are measured
	// over wall time and are dominated by a cold large-model load; a
	// correct-but-slow answer must not trip a latency sanction on (re)connect.
	// 0 (default) disables it. The nonce-correctness gate is NEVER relaxed, a
	// graced probe is neutral for the sanction counter, and it forces the next
	// probe to be enforced — so this cannot be used to evade sanctions. Size it
	// to cover a cold large-model load (observed ~8s TTFT for a cold 30B; a full
	// load can take tens of seconds).
	CanaryColdStartGraceS   int                                `yaml:"canary_cold_start_grace_s"`
	CanaryChallenges        []CanaryChallengeConfig            `yaml:"canary_challenges"`
	ModelClassChallenges    map[string][]CanaryChallengeConfig `yaml:"model_class_challenges"`
}

type CanaryChallengeConfig struct {
	Prompt          string  `yaml:"prompt"`
	Expected        string  `yaml:"expected"`
	MaxTTFTMS       int     `yaml:"max_ttft_ms,omitempty"`
	MinSustainedTPS float64 `yaml:"min_sustained_tps,omitempty"`
}

func validateCanaryChallengeList(prefix string, challenges []CanaryChallengeConfig) error {
	for i, challenge := range challenges {
		if strings.TrimSpace(challenge.Prompt) == "" || strings.TrimSpace(challenge.Expected) == "" {
			return fmt.Errorf("%s[%d] prompt and expected must not be empty", prefix, i)
		}
		if !strings.Contains(challenge.Prompt, "{nonce}") || !strings.Contains(challenge.Expected, "{nonce}") {
			return fmt.Errorf("%s[%d] prompt and expected must contain {nonce}", prefix, i)
		}
		if challenge.MaxTTFTMS < 0 {
			return fmt.Errorf("%s[%d] max_ttft_ms must be >= 0", prefix, i)
		}
		if math.IsNaN(challenge.MinSustainedTPS) || math.IsInf(challenge.MinSustainedTPS, 0) || challenge.MinSustainedTPS < 0 {
			return fmt.Errorf("%s[%d] min_sustained_tps is invalid", prefix, i)
		}
	}
	return nil
}

func (p PoolConfig) CanaryChallengesForModel(modelID string) ([]CanaryChallengeConfig, bool) {
	modelID = strings.TrimSpace(modelID)
	if modelID == "" {
		return p.CanaryChallenges, false
	}
	if bank, ok := p.ModelClassChallenges[modelID]; ok && len(bank) > 0 {
		return bank, true
	}
	for key, bank := range p.ModelClassChallenges {
		if strings.EqualFold(strings.TrimSpace(key), modelID) && len(bank) > 0 {
			return bank, true
		}
	}
	return p.CanaryChallenges, false
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

type RelayConfig struct {
	MaxRequestBufferBytes int64 `yaml:"max_request_buffer_bytes"`
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

	// SE liveness challenge settings (Phase 1, Track P1-C).
	// Only sent to providers whose SE pubkey is recorded (attestation_tier=self_signed).
	SELivenessIntervalS   int `yaml:"se_liveness_interval_s"`
	SELivenessTimeoutS    int `yaml:"se_liveness_timeout_s"`
	SELivenessMaxFailures int `yaml:"se_liveness_max_failures"`

	// MDM enrollment profile generation (Phase 2, Track P2-A, Scenario B).
	// Profile generation is enabled when MDM.EnrollmentBaseURL is non-empty.
	MDM Tier2MDMConfig `yaml:"mdm"`

	BehavioralSafetyEnabled    bool    `yaml:"behavioral_safety_enabled"`
	OutputSizeCapBytes         int64   `yaml:"output_size_cap_bytes"`
	OutputBytesPerTokenCeiling int     `yaml:"output_bytes_per_token_ceiling"`
	DefaultOutputSizeCapBytes  int64   `yaml:"default_output_size_cap_bytes"`
	EncodingValidationEnabled  bool    `yaml:"encoding_validation_enabled"`
	ResponseTimeAnomalyEnabled bool    `yaml:"response_time_anomaly_enabled"`
	ResponseTimeAnomalyFactor  float64 `yaml:"response_time_anomaly_factor"`
	ResponseTimeAnomalyMinMS   int64   `yaml:"response_time_anomaly_min_ms"`
}

// Tier2MDMConfig holds Phase 2 Track P2-A MDM enrollment profile settings.
// All fields are optional — profile generation is disabled when
// EnrollmentBaseURL is empty. Signer fields are optional; profiles are served
// unsigned (with a loud error log) when signing is not configured or fails.
type Tier2MDMConfig struct {
	// EnrollmentBaseURL is the canonical HTTPS base URL used to build SCEP and
	// MDM connect URLs inside the generated .mobileconfig. MUST be set
	// explicitly; the coordinator never derives this from the inbound request's
	// Host header — a client-controlled Host would let an attacker obtain a
	// coordinator-signed profile pointing enrollment at their own server.
	EnrollmentBaseURL string `yaml:"enrollment_base_url"`

	// MDMServerURL is the full MicroMDM /mdm/connect URL. When empty, falls
	// back to EnrollmentBaseURL + "/mdm/connect".
	MDMServerURL string `yaml:"mdm_server_url"`

	// SCEPUrl is the full SCEP endpoint URL. When empty, falls back to
	// EnrollmentBaseURL + "/scep".
	SCEPUrl string `yaml:"scep_url"`

	// PushTopic is the APNs push topic tied to the MDM push certificate,
	// e.g. "com.apple.mgmt.External.<uuid>". This is a placeholder until the
	// macprovider APNs certificate is provisioned; the profile is syntactically
	// valid without it but push-based MDM commands will not function.
	PushTopic string `yaml:"push_topic"`

	// ProfileSignerCertPath and ProfileSignerKeyPath point to PEM-encoded
	// signing cert + private key for optional CMS signing of generated
	// profiles. When empty, profiles are served unsigned (macOS will show
	// "Unsigned" in the install prompt, which is acceptable for enrollment).
	ProfileSignerCertPath string `yaml:"profile_signer_cert_path"`
	ProfileSignerKeyPath  string `yaml:"profile_signer_key_path"`
}

type CoordinatorAdvertisedVersion struct {
	LatestBinaryVersion   string `yaml:"latest_binary_version"`
	RequiredBinaryVersion string `yaml:"required_binary_version"`
}

type AuthConfig struct {
	OperatorKey  string            `yaml:"operator_key"`
	OperatorKeys map[string]string `yaml:"operator_keys"`
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
	PromptCreditsPerMtok         int64 `yaml:"prompt_credits_per_mtok"`
	PromptCacheHitCreditsPerMtok int64 `yaml:"prompt_cache_hit_credits_per_mtok"`
	CompletionCreditsPerMtok     int64 `yaml:"completion_credits_per_mtok"`

	promptCacheHitRateSet bool
}

func (e RateCardEntry) EffectivePromptCacheHitCreditsPerMtok() int64 {
	if e.promptCacheHitRateSet || e.PromptCacheHitCreditsPerMtok != 0 || e.PromptCreditsPerMtok == 0 {
		return e.PromptCacheHitCreditsPerMtok
	}
	return e.PromptCreditsPerMtok
}

func (e *RateCardEntry) SetPromptCacheHitCreditsPerMtok(v int64) {
	e.PromptCacheHitCreditsPerMtok = v
	e.promptCacheHitRateSet = true
}

func (e RateCardEntry) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		PromptRatePerMtok         int64 `json:"prompt_rate_per_mtok"`
		PromptCacheHitRatePerMtok int64 `json:"prompt_cache_hit_rate_per_mtok"`
		CompletionRatePerMtok     int64 `json:"completion_rate_per_mtok"`
	}{
		PromptRatePerMtok:         e.PromptCreditsPerMtok,
		PromptCacheHitRatePerMtok: e.EffectivePromptCacheHitCreditsPerMtok(),
		CompletionRatePerMtok:     e.CompletionCreditsPerMtok,
	})
}

func (e *RateCardEntry) UnmarshalJSON(data []byte) error {
	var raw struct {
		PromptCreditsPerMtok         *int64 `json:"PromptCreditsPerMtok"`
		PromptRatePerMtok            *int64 `json:"prompt_rate_per_mtok"`
		PromptCreditsPerMtokSnake    *int64 `json:"prompt_credits_per_mtok"`
		PromptCacheHitCreditsPerMtok *int64 `json:"PromptCacheHitCreditsPerMtok"`
		PromptCacheHitRatePerMtok    *int64 `json:"prompt_cache_hit_rate_per_mtok"`
		PromptCacheHitCreditsSnake   *int64 `json:"prompt_cache_hit_credits_per_mtok"`
		CompletionCreditsPerMtok     *int64 `json:"CompletionCreditsPerMtok"`
		CompletionRatePerMtok        *int64 `json:"completion_rate_per_mtok"`
		CompletionCreditsSnake       *int64 `json:"completion_credits_per_mtok"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	if raw.PromptRatePerMtok != nil {
		e.PromptCreditsPerMtok = *raw.PromptRatePerMtok
	} else if raw.PromptCreditsPerMtokSnake != nil {
		e.PromptCreditsPerMtok = *raw.PromptCreditsPerMtokSnake
	} else if raw.PromptCreditsPerMtok != nil {
		e.PromptCreditsPerMtok = *raw.PromptCreditsPerMtok
	}
	if raw.CompletionRatePerMtok != nil {
		e.CompletionCreditsPerMtok = *raw.CompletionRatePerMtok
	} else if raw.CompletionCreditsSnake != nil {
		e.CompletionCreditsPerMtok = *raw.CompletionCreditsSnake
	} else if raw.CompletionCreditsPerMtok != nil {
		e.CompletionCreditsPerMtok = *raw.CompletionCreditsPerMtok
	}
	switch {
	case raw.PromptCacheHitRatePerMtok != nil:
		e.PromptCacheHitCreditsPerMtok = *raw.PromptCacheHitRatePerMtok
		e.promptCacheHitRateSet = true
	case raw.PromptCacheHitCreditsSnake != nil:
		e.PromptCacheHitCreditsPerMtok = *raw.PromptCacheHitCreditsSnake
		e.promptCacheHitRateSet = true
	case raw.PromptCacheHitCreditsPerMtok != nil:
		e.PromptCacheHitCreditsPerMtok = *raw.PromptCacheHitCreditsPerMtok
		e.promptCacheHitRateSet = true
	default:
		e.PromptCacheHitCreditsPerMtok = e.PromptCreditsPerMtok
		e.promptCacheHitRateSet = false
	}
	return nil
}

func (e *RateCardEntry) UnmarshalYAML(value *yaml.Node) error {
	var raw struct {
		PromptCreditsPerMtok         int64  `yaml:"prompt_credits_per_mtok"`
		PromptCacheHitCreditsPerMtok *int64 `yaml:"prompt_cache_hit_credits_per_mtok"`
		CompletionCreditsPerMtok     int64  `yaml:"completion_credits_per_mtok"`
	}
	if err := value.Decode(&raw); err != nil {
		return err
	}
	e.PromptCreditsPerMtok = raw.PromptCreditsPerMtok
	e.CompletionCreditsPerMtok = raw.CompletionCreditsPerMtok
	if raw.PromptCacheHitCreditsPerMtok != nil {
		e.PromptCacheHitCreditsPerMtok = *raw.PromptCacheHitCreditsPerMtok
		e.promptCacheHitRateSet = true
	} else {
		e.PromptCacheHitCreditsPerMtok = raw.PromptCreditsPerMtok
		e.promptCacheHitRateSet = false
	}
	return nil
}

type RewardsConfig struct {
	GlobalMultiplier float64                  `yaml:"global_multiplier"`
	ProviderShare    float64                  `yaml:"provider_share"`
	RateCard         map[string]RateCardEntry `yaml:"rate_card"`
}

type SettlementConfig struct {
	CadenceDays                 int    `yaml:"cadence_days"`
	MinPayoutCredits            int64  `yaml:"min_payout_credits"`
	StartupReconcileWindowHours int    `yaml:"startup_reconcile_window_hours"`
	NightlyReconcileWindowDays  int    `yaml:"nightly_reconcile_window_days"`
	RecoveryGraceSeconds        int    `yaml:"recovery_grace_seconds"`
	VerifiedModelSettlementMode string `yaml:"verified_model_settlement_mode"`
	JobEnabled                  bool   `yaml:"job_enabled"`
}

// BillingConfig is the SPEC-005 billing-side operator-toggleable surface.
type BillingConfig struct {
	// QuarantineResolutionForceVoidEnabled gates POST
	// /admin/ledger/quarantine/{id}/force-void (SPEC-005 v0.4
	// §11.6.1). Default false — the endpoint returns HTTP 404
	// `not_found` (route-layer gate per §11.5 launch-gate item
	// 10) until the operator explicitly flips this to true via
	// the existing config-reload primitive.
	QuarantineResolutionForceVoidEnabled bool `yaml:"quarantine_resolution_force_void_enabled"`
	// QuarantineResolutionForceCreditEnabled gates POST
	// /admin/ledger/quarantine/{id}/force-credit. Default false.
	QuarantineResolutionForceCreditEnabled bool `yaml:"quarantine_resolution_force_credit_enabled"`
	// ForceCreditSettlementHoldSeconds is the pre-payout hold for
	// force-credit resolutions. Zero means the SPEC-005 v0.5 default
	// of 24 hours.
	ForceCreditSettlementHoldSeconds int `yaml:"force_credit_settlement_hold_seconds"`
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
		Coordinator: CoordinatorConfig{
			RequireGatewayContext: true,
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
		Relay: RelayConfig{
			MaxRequestBufferBytes: 16 * 1024 * 1024,
		},
		Admission: AdmissionConfig{
			PinnedOnly:                      false,
			ProvisionalAdmissionRatePerHour: 10,
			ProvisionalPoolMax:              100,
			ProvisionalQuotaPerHour:         100,
			ProvisionalTierWeight:           0.3,
			ProvisionalRetentionDays:        30,
		},
		ProofOfWeights: ProofOfWeightsConfig{
			RequireAutotuneHelloGate: false,
			AutotuneEvidenceTTLDays:  30,
			TelemetryDrift: TelemetryDriftConfig{
				Enabled:                  false,
				TPSRatioThreshold:        0.70,
				TPSMinAbsolute:           5.0,
				TPSMinRequestsWindow:     2,
				HashAlertOnStatus:        []string{"hash_mismatch", "hash_invalid"},
				HashAlertOnArtifactDrift: true,
				OPoIPassRateWindow:       10,
				OPoIPassRateThreshold:    0.80,
				AlertCooldownSeconds:     900,
			},
		},
		Tier2: Tier2Config{
			SELivenessIntervalS:            300,
			SELivenessTimeoutS:             30,
			SELivenessMaxFailures:          3,
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
			AttestationFormats:             []string{"apple-managed-device-attestation-acme-v1", "macprovider-se-p256-v1"},
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
					PromptCreditsPerMtok:         500000,
					PromptCacheHitCreditsPerMtok: 500000,
					CompletionCreditsPerMtok:     1000000,
				},
			},
		},
		Settlement: SettlementConfig{
			CadenceDays:                 7,
			MinPayoutCredits:            500000,
			StartupReconcileWindowHours: 24,
			NightlyReconcileWindowDays:  7,
			RecoveryGraceSeconds:        30,
			VerifiedModelSettlementMode: "observe",
			JobEnabled:                  true,
		},
		Endpoints: EndpointsConfig{
			ProviderEarnings: EndpointsProviderEarningsConfig{
				RateLimitPerMinute: 60,
			},
		},
		Stats: StatsConfig{
			Enabled: false,
			Rollup: StatsRollupConfig{
				BackfillMode:            "partial",
				LateEventsRetentionDays: 90,
				UsdPerMillionCredits:    1.0,
				DriftThresholdRatio:     0.005,
				NightlyRebuildHourUTC:   9,
				LateEventsLookbackHours: 48,
			},
			CORS: StatsCORSConfig{
				AccessControlMaxAgeSeconds: 60,
			},
			RateLimit: StatsRateLimitConfig{
				MaxBuckets:              100000,
				IdleTTLSeconds:          15 * 60,
				EvictionIntervalSeconds: 60,
				PreflightRPM:            10,
			},
			StreamingMetrics: StatsStreamingMetricsConfig{
				MaxSamples: 10000,
			},
			TrustedProxies: []string{"127.0.0.0/8", "::1/128"},
		},
		Onboarding: OnboardingConfig{
			AppTrackRegisterEnabled: false,
			BundleID:                "tech.malibu.app",
			CoordinatorDomain:       "coordinator.streamvc.live",
		},
		MalibuEmission: MalibuEmissionConfig{
			Enabled:                     false,
			TickIntervalSeconds:         900,
			ProviderDailyCapMALIBU:      25,
			WalletDailyCapMALIBU:        100,
			WalletMirrorIntervalSeconds: 300,
			UnlockEvalIntervalSeconds:   3600,
			MaxSerializableRetries:      5,
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
		Proxy: ProxyConfig{
			// Default trusts loopback only. Production sits behind nginx on
			// localhost, so the default keys rate-limit buckets on the
			// X-Real-IP / X-Forwarded-For headers nginx sets. Operators with
			// a remote LB MUST add the proxy CIDR(s) explicitly; spoofing
			// risk if anything else is added. Issue #125.
			TrustedProxies: []string{"127.0.0.0/8", "::1/128"},
		},
	}
}

func Load(path string) (Config, error) {
	return LoadWithOverlay(path, "")
}

// LoadWithOverlay reads basePath into defaults, then merges overlayPath when
// non-empty (overlay keys override). Used for OPoI v0 staging overlays without
// editing production coordinator.yaml.
func LoadWithOverlay(basePath, overlayPath string) (Config, error) {
	cfg := Default()
	if err := unmarshalYAMLFile(basePath, &cfg); err != nil {
		return Config{}, fmt.Errorf("base config %s: %w", basePath, err)
	}
	if strings.TrimSpace(overlayPath) != "" {
		if err := unmarshalYAMLFile(overlayPath, &cfg); err != nil {
			return Config{}, fmt.Errorf("overlay config %s: %w", overlayPath, err)
		}
	}
	if err := finalizeLoadedConfig(&cfg); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func unmarshalYAMLFile(path string, cfg *Config) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return yaml.Unmarshal(b, cfg)
}

func finalizeLoadedConfig(cfg *Config) error {
	if err := cfg.resolveEnv(); err != nil {
		return err
	}
	if err := cfg.Validate(); err != nil {
		return err
	}
	if err := validateOperatorSecretStrength("auth.operator_key", cfg.Auth.OperatorKey); err != nil {
		return err
	}
	for name, key := range cfg.Auth.OperatorKeys {
		if err := validateOperatorSecretStrength("auth.operator_keys."+name, key); err != nil {
			return err
		}
	}
	return nil
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
	for name, raw := range c.Auth.OperatorKeys {
		v, err := resolveEnvValue("auth.operator_keys."+name, raw)
		if err != nil {
			return err
		}
		c.Auth.OperatorKeys[name] = v
	}
	// Round-1 SECURITY r1 MEDIUM 1: stats DSN fields go through
	// the same env-indirection resolver. Operators inject DSNs
	// at deploy time as `env:STATS_READER_DSN` etc.; storing
	// plaintext DSNs in coordinator.yaml is a SECURITY footgun.
	statsDSNs := []struct {
		field string
		dst   *string
	}{
		{"stats.reader_dsn", &c.Stats.ReaderDSN},
		{"stats.rollup_dsn", &c.Stats.RollupDSN},
		{"stats.provider_portal_dsn", &c.Stats.ProviderPortalDSN},
		{"stats.partner_keys.writer_dsn", &c.Stats.PartnerKeys.WriterDSN},
		{"stats.partner_keys_admin_dsn", &c.Stats.PartnerKeysAdminDSN},
		{"malibu_emission.writer_dsn", &c.MalibuEmission.WriterDSN},
	}
	for _, f := range statsDSNs {
		v, err := resolveEnvValue(f.field, *f.dst)
		if err != nil {
			return err
		}
		*f.dst = v
	}
	onboardingSecrets := []struct {
		field string
		dst   *string
	}{
		{"onboarding.postgres_dsn", &c.Onboarding.PostgresDSN},
		{"onboarding.auth_policy_request_dsn", &c.Onboarding.AuthPolicyRequestDSN},
		{"onboarding.auth_policy_approve_dsn", &c.Onboarding.AuthPolicyApproveDSN},
		{"onboarding.auth_policy_cutover_dsn", &c.Onboarding.AuthPolicyCutoverDSN},
		{"onboarding.apple_team_id", &c.Onboarding.AppleTeamID},
	}
	for _, f := range onboardingSecrets {
		v, err := resolveEnvValue(f.field, *f.dst)
		if err != nil {
			return err
		}
		*f.dst = v
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

var weakOperatorKeyDenylist = map[string]struct{}{
	"":            {},
	"changeme":    {},
	"placeholder": {},
	"test":        {},
	"secret":      {},
	"password":    {},
	"admin":       {},
}

func validateOperatorSecretStrength(field, key string) error {
	trimmed := strings.TrimSpace(key)
	if _, denied := weakOperatorKeyDenylist[strings.ToLower(trimmed)]; denied {
		return fmt.Errorf("%s strength check failed: placeholder_denied", field)
	}
	if len([]byte(trimmed)) < 32 {
		return fmt.Errorf("%s strength check failed: too_short (minimum 32 bytes)", field)
	}
	allZero := true
	for _, b := range []byte(trimmed) {
		if b != 0 && b != '0' {
			allZero = false
			break
		}
	}
	if allZero {
		return fmt.Errorf("%s strength check failed: repeated_zero", field)
	}
	if entropyBitsPerByte(trimmed) < 3.5 {
		return fmt.Errorf("%s strength check failed: low_entropy", field)
	}
	return nil
}

func entropyBitsPerByte(s string) float64 {
	data := []byte(s)
	if len(data) == 0 {
		return 0
	}
	counts := make(map[byte]int, len(data))
	for _, b := range data {
		counts[b]++
	}
	var entropy float64
	n := float64(len(data))
	for _, count := range counts {
		p := float64(count) / n
		entropy -= p * math.Log2(p)
	}
	return entropy
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

func (c Config) RelayMaxRequestBufferBytes() int64 {
	bytes := c.Relay.MaxRequestBufferBytes
	if bytes <= 0 {
		bytes = Default().Relay.MaxRequestBufferBytes
	}
	return bytes
}

// TrustedProxyPrefixes parses c.Proxy.TrustedProxies into a slice of
// netip.Prefix values for the buyer Server's rate-limit-key derivation.
// Returns an error if any CIDR is malformed OR if the operator has
// listed a default-route prefix (0.0.0.0/0, ::/0); those would let
// every public caller spoof their bucket key via X-Forwarded-For —
// almost certainly a config bug, never a deliberate posture, so
// reject at Validate time. Issue #125 security-lane finding.
//
// Callers should invoke this at startup (config.Load already calls
// it via Validate) so the hot path never re-parses. An empty
// TrustedProxies list returns a nil slice (callers treat as "no
// proxy is trusted; always use r.RemoteAddr").
func (c Config) TrustedProxyPrefixes() ([]netip.Prefix, error) {
	if len(c.Proxy.TrustedProxies) == 0 {
		return nil, nil
	}
	out := make([]netip.Prefix, 0, len(c.Proxy.TrustedProxies))
	for _, raw := range c.Proxy.TrustedProxies {
		trimmed := strings.TrimSpace(raw)
		if trimmed == "" {
			continue
		}
		p, err := netip.ParsePrefix(trimmed)
		if err != nil {
			return nil, fmt.Errorf("proxy.trusted_proxies[%q]: %w", raw, err)
		}
		// Reject default-route prefixes — trusting every IP means
		// every caller can spoof their bucket key. Issue #125
		// security-lane L2.
		if p.Bits() == 0 {
			return nil, fmt.Errorf("proxy.trusted_proxies[%q]: default-route prefix is not a valid trusted proxy (every caller would be header-trusted)", raw)
		}
		out = append(out, p)
	}
	return out, nil
}

func (c Config) StatsTrustedProxyPrefixes() ([]netip.Prefix, error) {
	return parseTrustedProxyCIDRs("stats.trusted_proxies", c.Stats.TrustedProxies)
}

func parseTrustedProxyCIDRs(name string, cidrs []string) ([]netip.Prefix, error) {
	if len(cidrs) == 0 {
		return nil, nil
	}
	out := make([]netip.Prefix, 0, len(cidrs))
	for _, raw := range cidrs {
		trimmed := strings.TrimSpace(raw)
		if trimmed == "" {
			continue
		}
		p, err := netip.ParsePrefix(trimmed)
		if err != nil {
			return nil, fmt.Errorf("%s[%q]: %w", name, raw, err)
		}
		if p.Bits() == 0 {
			return nil, fmt.Errorf("%s[%q]: default-route prefix is not a valid trusted proxy (every caller would be header-trusted)", name, raw)
		}
		out = append(out, p)
	}
	return out, nil
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
	if c.Coordinator.RequireGatewayContext && c.Auth.GatewayServiceToken == "" && c.Auth.OperatorKey == "" {
		return fmt.Errorf("auth.gateway_service_token or auth.operator_key must be set when coordinator.require_gateway_context is true")
	}
	if _, err := c.TrustedProxyPrefixes(); err != nil {
		return err
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
	if c.Relay.MaxRequestBufferBytes <= 0 {
		return fmt.Errorf("relay.max_request_buffer_bytes must be > 0")
	}
	if c.Relay.MaxRequestBufferBytes > 128<<20 {
		return fmt.Errorf("relay.max_request_buffer_bytes must be <= 134217728")
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
	if c.Pool.CanaryColdStartGraceS < 0 {
		return fmt.Errorf("pool canary_cold_start_grace_s must be >= 0")
	}
	if c.Pool.CanaryEnabled {
		if len(c.Pool.CanaryChallenges) == 0 && len(c.Pool.ModelClassChallenges) == 0 {
			return fmt.Errorf("pool canary_challenges or model_class_challenges must not be empty when enabled")
		}
		if err := validateCanaryChallengeList("pool.canary_challenges", c.Pool.CanaryChallenges); err != nil {
			return err
		}
		for modelID, challenges := range c.Pool.ModelClassChallenges {
			if strings.TrimSpace(modelID) == "" {
				return fmt.Errorf("pool.model_class_challenges model id must not be empty")
			}
			if err := validateCanaryChallengeList("pool.model_class_challenges."+modelID, challenges); err != nil {
				return err
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
	if c.Settlement.RecoveryGraceSeconds > 900 {
		return fmt.Errorf("settlement.recovery_grace_seconds must be <= 900")
	}
	if c.Settlement.VerifiedModelSettlementMode != "observe" && c.Settlement.VerifiedModelSettlementMode != "enforce" {
		return fmt.Errorf("settlement.verified_model_settlement_mode must be observe or enforce")
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
	if err := c.validateStats(); err != nil {
		return err
	}
	if err := c.validateOnboarding(); err != nil {
		return err
	}
	if err := c.validateMalibuEmission(); err != nil {
		return err
	}
	if err := c.validateAutotuneFeeds(); err != nil {
		return err
	}
	if err := c.validateProofOfWeights(); err != nil {
		return err
	}
	if _, ok := c.Rewards.RateCard["default"]; !ok {
		return fmt.Errorf("rewards.rate_card must contain default")
	}
	for model, entry := range c.Rewards.RateCard {
		cacheRate := entry.EffectivePromptCacheHitCreditsPerMtok()
		if entry.PromptCreditsPerMtok < 0 || entry.CompletionCreditsPerMtok < 0 || cacheRate < 0 {
			return fmt.Errorf("rewards.rate_card.%s rates must be >= 0", model)
		}
		if cacheRate > entry.PromptCreditsPerMtok {
			return fmt.Errorf("rewards.rate_card.%s prompt_cache_hit_credits_per_mtok must be <= prompt_credits_per_mtok", model)
		}
	}
	seen := map[string]struct{}{}
	for _, p := range c.Providers {
		if err := ValidateProviderID(p.ProviderID); err != nil {
			return err
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
	return nil
}

func (c Config) validateProofOfWeights() error {
	p := c.ProofOfWeights
	if p.AutotuneEvidenceTTLDays < 0 {
		return fmt.Errorf("proof_of_weights.autotune_evidence_ttl_days must be >= 0")
	}
	if p.RequireAutotuneHelloGate {
		if p.AutotuneEvidenceTTLDays <= 0 {
			return fmt.Errorf("proof_of_weights.autotune_evidence_ttl_days must be > 0 when require_autotune_hello_gate is true")
		}
		if err := c.requireAutotuneEvidenceFeeds(); err != nil {
			return err
		}
	}
	if !p.TelemetryDrift.Enabled {
		return nil
	}
	if p.AutotuneEvidenceTTLDays <= 0 {
		return fmt.Errorf("proof_of_weights.autotune_evidence_ttl_days must be > 0 when telemetry_drift.enabled is true")
	}
	if err := c.requireAutotuneEvidenceFeeds(); err != nil {
		return err
	}
	d := p.TelemetryDrift
	if d.TPSRatioThreshold <= 0 || d.TPSRatioThreshold > 1 || math.IsNaN(d.TPSRatioThreshold) || math.IsInf(d.TPSRatioThreshold, 0) {
		return fmt.Errorf("proof_of_weights.telemetry_drift.tps_ratio_threshold must be in (0,1]")
	}
	if d.TPSMinAbsolute < 0 || math.IsNaN(d.TPSMinAbsolute) || math.IsInf(d.TPSMinAbsolute, 0) {
		return fmt.Errorf("proof_of_weights.telemetry_drift.tps_min_absolute must be >= 0")
	}
	if d.TPSMinRequestsWindow < 0 {
		return fmt.Errorf("proof_of_weights.telemetry_drift.tps_min_requests_window must be >= 0")
	}
	if d.OPoIPassRateWindow < 0 {
		return fmt.Errorf("proof_of_weights.telemetry_drift.opoi_pass_rate_window must be >= 0")
	}
	if d.OPoIPassRateThreshold < 0 || d.OPoIPassRateThreshold > 1 || math.IsNaN(d.OPoIPassRateThreshold) || math.IsInf(d.OPoIPassRateThreshold, 0) {
		return fmt.Errorf("proof_of_weights.telemetry_drift.opoi_pass_rate_threshold must be in [0,1]")
	}
	if d.AlertCooldownSeconds < 0 {
		return fmt.Errorf("proof_of_weights.telemetry_drift.alert_cooldown_s must be >= 0")
	}
	for _, status := range d.HashAlertOnStatus {
		switch strings.TrimSpace(status) {
		case "hash_mismatch", "hash_invalid", "hash_verified", "uncatalogued", "catalog_unavailable":
		default:
			return fmt.Errorf("proof_of_weights.telemetry_drift.hash_alert_on_status contains unsupported value %q", status)
		}
	}
	if !c.Pool.CanaryEnabled && d.OPoIPassRateWindow > 0 {
		return fmt.Errorf("proof_of_weights.telemetry_drift.opoi_pass_rate_window requires pool.canary_enabled when > 0")
	}
	return nil
}

func (c Config) requireAutotuneEvidenceFeeds() error {
	a := c.AutotuneFeeds
	if strings.TrimSpace(a.AutotuneCandidatesPath) == "" || strings.TrimSpace(a.AutotuneCandidatesSigPath) == "" {
		return fmt.Errorf("proof_of_weights autotune evidence requires autotune.autotune_candidates_path and autotune.autotune_candidates_sig_path")
	}
	if !c.Onboarding.AppTrackRegisterEnabled || strings.TrimSpace(c.Onboarding.PostgresDSN) == "" {
		return fmt.Errorf("proof_of_weights autotune evidence requires onboarding.app_track_register_enabled and onboarding.postgres_dsn")
	}
	return nil
}

func (c Config) validateAutotuneFeeds() error {
	a := c.AutotuneFeeds
	pairs := []struct {
		label    string
		jsonPath string
		sigPath  string
	}{
		{"demand_rank", a.DemandRankPath, a.DemandRankSigPath},
		{"autotune_candidates", a.AutotuneCandidatesPath, a.AutotuneCandidatesSigPath},
	}
	for _, p := range pairs {
		jsonPath := strings.TrimSpace(p.jsonPath)
		sigPath := strings.TrimSpace(p.sigPath)
		if jsonPath == "" && sigPath == "" {
			continue
		}
		if jsonPath == "" || sigPath == "" {
			return fmt.Errorf("autotune.%s_path and autotune.%s_sig_path must both be set", p.label, p.label)
		}
	}
	return nil
}

func (c Config) validateOnboarding() error {
	o := c.Onboarding
	if strings.TrimSpace(o.BundleID) == "" {
		return fmt.Errorf("onboarding.bundle_id must be set")
	}
	if strings.TrimSpace(o.CoordinatorDomain) == "" {
		return fmt.Errorf("onboarding.coordinator_domain must be set")
	}
	if strings.Contains(o.CoordinatorDomain, "://") || strings.HasSuffix(o.CoordinatorDomain, "/") {
		return fmt.Errorf("onboarding.coordinator_domain must be a bare lowercase host with no scheme or trailing slash")
	}
	if o.CoordinatorDomain != strings.ToLower(o.CoordinatorDomain) {
		return fmt.Errorf("onboarding.coordinator_domain must be lowercase")
	}
	if !o.AppTrackRegisterEnabled {
		return nil
	}
	if strings.TrimSpace(o.PostgresDSN) == "" {
		return fmt.Errorf("onboarding.postgres_dsn must be set when onboarding.app_track_register_enabled is true")
	}
	if strings.TrimSpace(o.AuthPolicyRequestDSN) == "" {
		return fmt.Errorf("onboarding.auth_policy_request_dsn must be set when onboarding.app_track_register_enabled is true")
	}
	if strings.TrimSpace(o.AuthPolicyApproveDSN) == "" {
		return fmt.Errorf("onboarding.auth_policy_approve_dsn must be set when onboarding.app_track_register_enabled is true")
	}
	if strings.TrimSpace(o.AuthPolicyCutoverDSN) == "" {
		return fmt.Errorf("onboarding.auth_policy_cutover_dsn must be set when onboarding.app_track_register_enabled is true")
	}
	if strings.TrimSpace(o.AppleTeamID) == "" {
		return fmt.Errorf("onboarding.apple_team_id must be set when onboarding.app_track_register_enabled is true")
	}
	if strings.TrimSpace(c.Auth.OperatorKey) == "" {
		return fmt.Errorf("auth.operator_key must be set when onboarding.app_track_register_enabled is true")
	}
	if len(o.ASNPrefixes) == 0 {
		return fmt.Errorf("onboarding.asn_prefixes must be set when onboarding.app_track_register_enabled is true")
	}
	for prefix, asn := range o.ASNPrefixes {
		if _, err := netip.ParsePrefix(strings.TrimSpace(prefix)); err != nil {
			return fmt.Errorf("onboarding.asn_prefixes contains invalid CIDR %q: %w", prefix, err)
		}
		if strings.TrimSpace(asn) == "" {
			return fmt.Errorf("onboarding.asn_prefixes[%q] must be non-empty", prefix)
		}
	}
	if err := validateOperatorKeyMap(c.Auth.OperatorKeys); err != nil {
		return err
	}
	return nil
}

func (c Config) validateMalibuEmission() error {
	m := c.MalibuEmission
	if !m.Enabled {
		return nil
	}
	if strings.TrimSpace(m.WriterDSN) == "" {
		return fmt.Errorf("malibu_emission.writer_dsn must be set when malibu_emission.enabled is true")
	}
	if m.TickIntervalSeconds <= 0 {
		return fmt.Errorf("malibu_emission.tick_interval_seconds must be > 0")
	}
	if m.ProviderDailyCapMALIBU <= 0 {
		return fmt.Errorf("malibu_emission.provider_daily_cap_malibu must be > 0")
	}
	if m.WalletDailyCapMALIBU <= 0 {
		return fmt.Errorf("malibu_emission.wallet_daily_cap_malibu must be > 0")
	}
	if m.WalletMirrorIntervalSeconds <= 0 {
		return fmt.Errorf("malibu_emission.wallet_mirror_interval_seconds must be > 0")
	}
	if m.UnlockEvalIntervalSeconds <= 0 {
		return fmt.Errorf("malibu_emission.unlock_eval_interval_seconds must be > 0")
	}
	if m.MaxSerializableRetries <= 0 {
		return fmt.Errorf("malibu_emission.max_serializable_retries must be > 0")
	}
	return nil
}

func validateOperatorKeyMap(keys map[string]string) error {
	if len(keys) < 2 {
		return fmt.Errorf("auth.operator_keys must contain at least two operators when onboarding.app_track_register_enabled is true")
	}
	seenSecrets := map[string]string{}
	for actor, secret := range keys {
		trimmedActor := strings.TrimSpace(actor)
		if trimmedActor == "" || strings.ContainsAny(trimmedActor, " \t\r\n") {
			return fmt.Errorf("auth.operator_keys contains invalid operator id %q", actor)
		}
		if strings.HasPrefix(trimmedActor, "operator:") {
			trimmedActor = strings.TrimPrefix(trimmedActor, "operator:")
			if trimmedActor == "" || strings.ContainsAny(trimmedActor, " \t\r\n") {
				return fmt.Errorf("auth.operator_keys contains invalid operator id %q", actor)
			}
		}
		secret = strings.TrimSpace(secret)
		if secret == "" {
			return fmt.Errorf("auth.operator_keys.%s must be non-empty", actor)
		}
		if previous, ok := seenSecrets[secret]; ok {
			return fmt.Errorf("auth.operator_keys.%s must not reuse secret from auth.operator_keys.%s", actor, previous)
		}
		seenSecrets[secret] = actor
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

// validateStats enforces the SPEC-017 §7.2 + BUILD §C structural
// constraints on the stats config block.
//
// Stats.Enabled=false (the v0.1 default) skips ALL validation
// below; an operator that has not flipped the gate cannot brick
// startup by leaving Stats fields empty.
//
// When Stats.Enabled=true the required daemon DSNs MUST be set
// (fail-closed per BUILD §C.3). PartnerKeys.WriterDSN is
// only required when last_used_at_updates_enabled=true. The CLI
// admin DSN is OPTIONAL even when stats is enabled (BUILD §B.2).
//
// Numeric ranges:
//   - LateEventsRetentionDays — SPEC §9.3 v0.1.7 floor 30; default 90.
//   - AccessControlMaxAgeSeconds — SPEC §5.7 v0.1.7 cap 300; default 60.
//   - BackfillMode — SPEC §9.7 enum {"partial","full"}; default "partial".
func (c Config) validateStats() error {
	s := c.Stats
	if !s.Enabled {
		return nil
	}
	// Final adversarial audit (codex SECURITY MEDIUM 1) — when
	// stats are enabled, `/metrics` is mounted on the provider
	// mux at provider-port. The Prometheus metric
	// `stats_partner_key_request_total{partner_key_id=...}`
	// is a partner-key enumeration oracle if it ever lands on
	// a public interface, so fail closed at config-validation
	// time: refuse to start if listen.bind_address is not a
	// loopback host. Pearl deploy runs `127.0.0.1:8444`; a
	// future operator who mis-types `0.0.0.0` or `::` gets a
	// clear startup error instead of an exposed enumeration
	// surface.
	bindHost := strings.TrimSpace(c.Listen.BindAddress)
	if bindHost == "" {
		return fmt.Errorf("listen.bind_address must be set (loopback required when stats.enabled is true)")
	}
	if !isLoopbackHost(bindHost) {
		return fmt.Errorf("stats.enabled=true requires listen.bind_address to be a loopback host (127.0.0.1, ::1, or localhost); got %q. The /metrics endpoint mounts on the provider port and a non-loopback bind exposes the stats_partner_key_request_total enumeration oracle. Place the coordinator behind a reverse proxy that terminates the public surface (e.g. nginx) and keep the binary bound to loopback", bindHost)
	}
	if strings.TrimSpace(s.ReaderDSN) == "" {
		return fmt.Errorf("stats.reader_dsn must be set when stats.enabled is true")
	}
	if strings.TrimSpace(s.RollupDSN) == "" {
		return fmt.Errorf("stats.rollup_dsn must be set when stats.enabled is true")
	}
	if s.PartnerKeys.LastUsedAtUpdatesEnabled && strings.TrimSpace(s.PartnerKeys.WriterDSN) == "" {
		return fmt.Errorf("stats.partner_keys.writer_dsn must be set when stats.partner_keys.last_used_at_updates_enabled is true")
	}
	switch s.Rollup.BackfillMode {
	case "", "partial", "full":
	default:
		return fmt.Errorf("stats.rollup.backfill_mode must be one of {partial, full} (got %q)", s.Rollup.BackfillMode)
	}
	// LateEventsRetentionDays: chosen pin per BUILD §2 Step 2 is
	// CLAMP+WARN (handled at rollup boot, not config validation).
	// We still reject below 30 here ONLY if explicitly set to
	// a negative value; zero = use default (90). A value in
	// (0, 30) is permitted but will be clamped to 30 by the
	// rollup with a WARN log.
	if s.Rollup.LateEventsRetentionDays < 0 {
		return fmt.Errorf("stats.rollup.late_events_retention_days must be >= 0 (0 = default 90, values in (0,30) clamped to 30 with WARN)")
	}
	if s.Rollup.UsdPerMillionCredits < 0 {
		return fmt.Errorf("stats.rollup.usd_per_million_credits must be >= 0")
	}
	if s.Rollup.DriftThresholdRatio != 0 && (s.Rollup.DriftThresholdRatio < 0.001 || s.Rollup.DriftThresholdRatio > 0.05) {
		return fmt.Errorf("stats.rollup.drift_threshold_ratio must be in [0.001, 0.05] when set (SPEC §9.4 default 0.005)")
	}
	if s.Rollup.NightlyRebuildHourUTC < 0 || s.Rollup.NightlyRebuildHourUTC > 23 {
		return fmt.Errorf("stats.rollup.nightly_rebuild_hour_utc must be in [0, 23]")
	}
	if s.Rollup.LateEventsLookbackHours != 0 && s.Rollup.LateEventsLookbackHours < 24 {
		return fmt.Errorf("stats.rollup.late_events_lookback_hours must be >= 24 (SPEC §9.3 1× reconciliation-margin floor)")
	}
	if s.CORS.AccessControlMaxAgeSeconds < 0 || s.CORS.AccessControlMaxAgeSeconds > 300 {
		return fmt.Errorf("stats.cors.access_control_max_age_seconds must be between 0 and 300 (SPEC §5.7)")
	}
	prefixes, err := c.StatsTrustedProxyPrefixes()
	if err != nil {
		return err
	}
	if len(prefixes) == 0 && !s.TrustDirectPeer {
		return fmt.Errorf("stats.trusted_proxies must be set when stats.enabled is true; set stats.trust_direct_peer=true only for direct-client deployments")
	}
	if s.RateLimit.MaxBuckets < 0 {
		return fmt.Errorf("stats.rate_limit.max_buckets must be >= 0")
	}
	if s.RateLimit.IdleTTLSeconds < 0 {
		return fmt.Errorf("stats.rate_limit.idle_ttl_seconds must be >= 0")
	}
	if s.RateLimit.EvictionIntervalSeconds < 0 {
		return fmt.Errorf("stats.rate_limit.eviction_interval_seconds must be >= 0")
	}
	if s.RateLimit.PreflightRPM < 0 {
		return fmt.Errorf("stats.rate_limit.preflight_rpm must be >= 0")
	}
	if s.StreamingMetrics.MaxSamples < 0 {
		return fmt.Errorf("stats.streaming_metrics.max_samples must be >= 0")
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
