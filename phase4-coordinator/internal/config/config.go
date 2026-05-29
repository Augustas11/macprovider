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
	WS                           WSConfig                     `yaml:"ws"`
	Admission                    AdmissionConfig              `yaml:"admission"`
	CoordinatorAdvertisedVersion CoordinatorAdvertisedVersion `yaml:"coordinator_advertised_version"`
	Auth                         AuthConfig                   `yaml:"auth"`
	Storage                      StorageConfig                `yaml:"storage"`
	Logging                      LoggingConfig                `yaml:"logging"`
	Providers                    []ProviderConfig             `yaml:"providers"`
}

type ListenConfig struct {
	BuyerPort    int    `yaml:"buyer_port"`
	ProviderPort int    `yaml:"provider_port"`
	BindAddress  string `yaml:"bind_address"`
}

type PoolConfig struct {
	HeartbeatIntervalS     int  `yaml:"heartbeat_interval_s"`
	DisconnectGracePeriodS int  `yaml:"disconnect_grace_period_s"`
	WakeGapThresholdS      int  `yaml:"wake_gap_threshold_s"`
	DegradedBackoffS       int  `yaml:"degraded_backoff_s"`
	DegradedMaxRetries     int  `yaml:"degraded_max_retries"`
	DegradedProbeAfter502  bool `yaml:"degraded_probe_after_502"`
}

type RoutingConfig struct {
	PreflightThresholdTokens int  `yaml:"preflight_threshold_tokens"`
	PreflightTimeoutS        int  `yaml:"preflight_timeout_s"`
	RequestTimeoutS          int  `yaml:"request_timeout_s"`
	FailoverEnabled          bool `yaml:"failover_enabled"`
	FailoverTimeoutS         int  `yaml:"failover_timeout_s"`
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
			HeartbeatIntervalS:     30,
			DisconnectGracePeriodS: 30,
			WakeGapThresholdS:      120,
			DegradedBackoffS:       30,
			DegradedMaxRetries:     3,
			DegradedProbeAfter502:  true,
		},
		Routing: RoutingConfig{
			PreflightThresholdTokens: 4096,
			PreflightTimeoutS:        5,
			RequestTimeoutS:          300,
			FailoverEnabled:          true,
			FailoverTimeoutS:         5,
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
		Storage: StorageConfig{
			DBPath:            "coordinator.db",
			SnapshotIntervalS: 300,
		},
		Logging: LoggingConfig{
			Level:  "info",
			Format: "json",
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
