package config

import (
	"fmt"
	"net/netip"
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
	Proxy                        ProxyConfig                  `yaml:"proxy"`
	Providers                    []ProviderConfig             `yaml:"providers"`
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
