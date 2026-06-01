package config

import (
	"fmt"
	"net/url"
	"os"
	"regexp"
	"time"

	"gopkg.in/yaml.v3"
)

var providerIDPattern = regexp.MustCompile(`^[a-zA-Z0-9_.-]{1,64}$`)

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
	Providers                    []ProviderConfig             `yaml:"providers"`
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
	HeartbeatMissThresholdS int  `yaml:"heartbeat_miss_threshold_s"`
	WakeGapThresholdS       int  `yaml:"wake_gap_threshold_s"`
	WarmupFallbackS         int  `yaml:"warmup_fallback_s"`
	WarmupGateEnabled       bool `yaml:"warmup_gate_enabled"`
	WarmupGateTimeoutS      int  `yaml:"warmup_gate_timeout_s"`
	WarmupGateMaxTokens     int  `yaml:"warmup_gate_max_tokens"`
	DegradedBackoffS        int  `yaml:"degraded_backoff_s"`
	DegradedMaxRetries      int  `yaml:"degraded_max_retries"`
	DegradedProbeAfter502   bool `yaml:"degraded_probe_after_502"`
	BreakerFailureThreshold int  `yaml:"breaker_failure_threshold"`
	BreakerWindowS          int  `yaml:"breaker_window_s"`
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
	WriteBufferSize int `yaml:"write_buffer_size"`
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
	// RequireProviderTokens gates the pinned-provider token check added by
	// the Go stream's integration audit. Defaults to false: pinned providers
	// connect by hello.provider_id matching config.providers[] (legacy
	// pre-token behavior). Set true once you've issued tokens to every
	// pinned provider AND every pinned provider's binary sends them in the
	// WS upgrade — anonymous pinned spoofing is then blocked. Filed
	// 2026-05-28 after the v1.1.2 deploy silently rejected M4/M1 (which
	// don't send tokens).
	RequireProviderTokens bool `yaml:"require_provider_tokens"`
}

type StorageConfig struct {
	DBPath            string `yaml:"db_path"`
	SnapshotIntervalS int    `yaml:"snapshot_interval_s"`
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
			WriteBufferSize: 64,
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
			DBPath:            "coordinator.db",
			SnapshotIntervalS: 300,
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
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
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
	if c.WS.WriteBufferSize <= 0 {
		return fmt.Errorf("ws.write_buffer_size must be > 0")
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
	if c.Endpoints.ProviderEarnings.RateLimitPerMinute <= 0 {
		return fmt.Errorf("endpoints.provider_earnings.rate_limit_per_minute must be > 0")
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
