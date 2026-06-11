package config

import (
	"fmt"
	"net"
	"net/url"
	"os"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Listen      ListenConfig      `yaml:"listen"`
	Proxy       ProxyConfig       `yaml:"proxy"`
	Public      PublicConfig      `yaml:"public"`
	Coordinator CoordinatorConfig `yaml:"coordinator"`
	Storage     StorageConfig     `yaml:"storage"`
	Auth        AuthConfig        `yaml:"auth"`
	Quotas      QuotasConfig      `yaml:"quotas"`
	Limits      LimitsConfig      `yaml:"limits"`
	KillSwitch  KillSwitchConfig  `yaml:"kill_switch"`
	Capacity    CapacityConfig    `yaml:"capacity"`
	Timeouts    TimeoutsConfig    `yaml:"timeouts"`
	CORS        CORSConfig        `yaml:"cors"`
	Routing     RoutingConfig     `yaml:"routing"`
	Explorer    ExplorerConfig    `yaml:"explorer"`
}

type ListenConfig struct {
	BindAddress string `yaml:"bind_address"`
	Port        int    `yaml:"port"`
}

type ProxyConfig struct {
	TrustedCIDRs []string `yaml:"trusted_cidrs"`
}

type PublicConfig struct {
	BaseURL     string `yaml:"base_url"`
	AccountPath string `yaml:"account_path"`
}

type CoordinatorConfig struct {
	BuyerURL          string `yaml:"buyer_url"`
	OperatorURL       string `yaml:"operator_url"`
	OperatorKey       string `yaml:"operator_key"`
	PoolzPollInterval int    `yaml:"poolz_poll_interval_s"`
}

type StorageConfig struct {
	Driver string `yaml:"driver"`
	DBPath string `yaml:"db_path"`
}

type AuthConfig struct {
	KeyPrefix             string      `yaml:"key_prefix"`
	KeyHash               string      `yaml:"key_hash"`
	KeyHashSecret         string      `yaml:"key_hash_secret"`
	GitHubOAuthEnabled    bool        `yaml:"github_oauth_enabled"`
	EmailMagicLinkEnabled bool        `yaml:"email_magic_link_enabled"`
	OAuth                 OAuthConfig `yaml:"oauth"`
	Demo                  DemoConfig  `yaml:"demo"`
}

type OAuthConfig struct {
	CallbackAllowlist []string          `yaml:"callback_allowlist"`
	GitHub            GitHubOAuthConfig `yaml:"github"`
}

type GitHubOAuthConfig struct {
	ClientID     string `yaml:"client_id"`
	ClientSecret string `yaml:"client_secret"`
	AuthorizeURL string `yaml:"authorize_url"`
	TokenURL     string `yaml:"token_url"`
	UserURL      string `yaml:"user_url"`
}

type DemoConfig struct {
	SigningSecret string `yaml:"signing_secret"`
}

type QuotasConfig struct {
	AccountDailyTokens        int64 `yaml:"account_daily_tokens"`
	DemoDailyTokensPerIP      int64 `yaml:"demo_daily_tokens_per_ip"`
	DemoSessionsPerIPPerHour  int   `yaml:"demo_sessions_per_ip_per_hour"`
	AccountConcurrency        int   `yaml:"account_concurrency"`
	DemoConcurrency           int   `yaml:"demo_concurrency"`
	SignupAccountsPerIPPerDay int   `yaml:"signup_accounts_per_ip_per_day"`
	ReaperIntervalHours       uint  `yaml:"reaper_interval_hours"`
	ReservationMaxAgeHours    uint  `yaml:"reservation_max_age_hours"`
}

type LimitsConfig struct {
	MaxTokensPerRequest     int64 `yaml:"max_tokens_per_request"`
	DemoMaxTokensPerRequest int64 `yaml:"demo_max_tokens_per_request"`
	MaxFeedbackCommentBytes int   `yaml:"max_feedback_comment_bytes"`
	RequestBodyBytes        int64 `yaml:"request_body_bytes"`
}

type KillSwitchConfig struct {
	DemoOnly     bool `yaml:"demo_only"`
	AllPublicAPI bool `yaml:"all_public_api"`
}

type CapacityConfig struct {
	MonthlyBudgetUSD               int64 `yaml:"monthly_budget_usd"`
	ReadyProviderDegradedThreshold int   `yaml:"ready_provider_degraded_threshold"`
	ProjectedCostTier1Percent      int   `yaml:"projected_cost_tier1_percent"`
	TierCooldownSeconds            int   `yaml:"tier_cooldown_seconds"`
}

type TimeoutsConfig struct {
	CoordinatorRequestSeconds       int `yaml:"coordinator_request_seconds"`
	CoordinatorHeaderTimeoutSeconds int `yaml:"coordinator_header_timeout_seconds"`
	StreamingCancelMS               int `yaml:"streaming_cancel_ms"`
}

type CORSConfig struct {
	AllowedOrigins []string `yaml:"allowed_origins"`
}

type RoutingConfig struct {
	StickyEnabled bool `yaml:"sticky_enabled"`
	StickyTTLS    int  `yaml:"sticky_ttl_s"`
}

type ExplorerConfig struct {
	Enabled bool `yaml:"enabled"`
}

func Default() Config {
	return Config{
		Listen: ListenConfig{BindAddress: "127.0.0.1", Port: 9443},
		Proxy:  ProxyConfig{TrustedCIDRs: []string{"127.0.0.0/8", "::1/128"}},
		Public: PublicConfig{BaseURL: "https://api.streamvc.live", AccountPath: "/account"},
		Coordinator: CoordinatorConfig{
			BuyerURL: "http://127.0.0.1:8443", OperatorURL: "http://127.0.0.1:8444", PoolzPollInterval: 10,
		},
		Storage: StorageConfig{Driver: "sqlite", DBPath: "gateway.db"},
		Auth: AuthConfig{
			KeyPrefix:             "mp_",
			KeyHash:               "hmac_sha256",
			GitHubOAuthEnabled:    true,
			EmailMagicLinkEnabled: false,
			OAuth: OAuthConfig{CallbackAllowlist: []string{
				"https://api.streamvc.live/auth/github/callback",
			}, GitHub: GitHubOAuthConfig{
				AuthorizeURL: "https://github.com/login/oauth/authorize",
				TokenURL:     "https://github.com/login/oauth/access_token",
				UserURL:      "https://api.github.com/user",
			}},
		},
		Quotas: QuotasConfig{
			AccountDailyTokens:        100000,
			DemoDailyTokensPerIP:      1000,
			DemoSessionsPerIPPerHour:  10,
			AccountConcurrency:        2,
			DemoConcurrency:           2,
			SignupAccountsPerIPPerDay: 3,
			ReaperIntervalHours:       1,
			ReservationMaxAgeHours:    24,
		},
		Limits: LimitsConfig{
			MaxTokensPerRequest:     4096,
			DemoMaxTokensPerRequest: 512,
			MaxFeedbackCommentBytes: 2000,
			RequestBodyBytes:        1048576,
		},
		Capacity: CapacityConfig{
			MonthlyBudgetUSD: 500, ReadyProviderDegradedThreshold: 1, ProjectedCostTier1Percent: 80, TierCooldownSeconds: 3600,
		},
		Timeouts: TimeoutsConfig{CoordinatorRequestSeconds: 300, CoordinatorHeaderTimeoutSeconds: 10, StreamingCancelMS: 500},
		CORS:     CORSConfig{AllowedOrigins: []string{"https://console.streamvc.live", "https://streamvc.live"}},
		Routing:  RoutingConfig{StickyEnabled: false, StickyTTLS: 1800},
		Explorer: ExplorerConfig{Enabled: false},
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
	cfg.resolveEnv()
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func (c *Config) resolveEnv() {
	c.Coordinator.OperatorKey = resolveEnvValue(c.Coordinator.OperatorKey)
	c.Auth.KeyHashSecret = resolveEnvValue(c.Auth.KeyHashSecret)
	c.Auth.OAuth.GitHub.ClientID = resolveEnvValue(c.Auth.OAuth.GitHub.ClientID)
	c.Auth.OAuth.GitHub.ClientSecret = resolveEnvValue(c.Auth.OAuth.GitHub.ClientSecret)
	c.Auth.Demo.SigningSecret = resolveEnvValue(c.Auth.Demo.SigningSecret)
}

func resolveEnvValue(v string) string {
	if !strings.HasPrefix(v, "env:") {
		return v
	}
	return os.Getenv(strings.TrimPrefix(v, "env:"))
}

func (c Config) Validate() error {
	if c.Listen.BindAddress == "" {
		return fmt.Errorf("listen.bind_address must be set")
	}
	if c.Listen.Port <= 0 || c.Listen.Port > 65535 {
		return fmt.Errorf("listen.port must be between 1 and 65535")
	}
	if len(c.Proxy.TrustedCIDRs) == 0 {
		return fmt.Errorf("proxy.trusted_cidrs must contain at least one trusted proxy CIDR")
	}
	for i, cidr := range c.Proxy.TrustedCIDRs {
		if _, _, err := parseCIDROrIP(cidr); err != nil {
			return fmt.Errorf("proxy.trusted_cidrs[%d] must be a valid CIDR or IP: %w", i, err)
		}
	}
	if err := requireURL("public.base_url", c.Public.BaseURL); err != nil {
		return err
	}
	if c.Public.AccountPath == "" || !strings.HasPrefix(c.Public.AccountPath, "/") {
		return fmt.Errorf("public.account_path must start with /")
	}
	if c.Storage.Driver != "sqlite" {
		return fmt.Errorf("storage.driver must be sqlite for v1")
	}
	if c.Storage.DBPath == "" {
		return fmt.Errorf("storage.db_path must be set")
	}
	if c.Coordinator.BuyerURL == "" {
		return fmt.Errorf("coordinator.buyer_url must be set")
	}
	if err := requireURL("coordinator.buyer_url", c.Coordinator.BuyerURL); err != nil {
		return err
	}
	if c.Coordinator.OperatorURL == "" {
		return fmt.Errorf("coordinator.operator_url must be set")
	}
	if err := requireURL("coordinator.operator_url", c.Coordinator.OperatorURL); err != nil {
		return err
	}
	if c.Coordinator.OperatorKey == "" {
		return fmt.Errorf("coordinator.operator_key must be set")
	}
	if c.Coordinator.PoolzPollInterval <= 0 {
		return fmt.Errorf("coordinator.poolz_poll_interval_s must be > 0")
	}
	if c.Auth.KeyPrefix != "mp_" {
		return fmt.Errorf("auth.key_prefix must be mp_")
	}
	if c.Auth.KeyHash != "hmac_sha256" && c.Auth.KeyHash != "sha256" {
		return fmt.Errorf("auth.key_hash must be hmac_sha256 or sha256")
	}
	if c.Auth.KeyHash == "hmac_sha256" && c.Auth.KeyHashSecret == "" {
		return fmt.Errorf("auth.key_hash_secret must be set when auth.key_hash is hmac_sha256")
	}
	if c.Routing.StickyEnabled && c.Auth.KeyHashSecret == "" {
		return fmt.Errorf("auth.key_hash_secret must be set when routing.sticky_enabled is true")
	}
	if c.Auth.Demo.SigningSecret == "" {
		return fmt.Errorf("auth.demo.signing_secret must be set")
	}
	if len(c.Auth.OAuth.CallbackAllowlist) == 0 {
		return fmt.Errorf("auth.oauth.callback_allowlist must not be empty")
	}
	for i, callback := range c.Auth.OAuth.CallbackAllowlist {
		if err := requireURL(fmt.Sprintf("auth.oauth.callback_allowlist[%d]", i), callback); err != nil {
			return err
		}
	}
	if c.Auth.GitHubOAuthEnabled {
		if c.Auth.OAuth.GitHub.ClientID == "" || c.Auth.OAuth.GitHub.ClientSecret == "" {
			return fmt.Errorf("auth.oauth.github.client_id and client_secret must be set when GitHub OAuth is enabled")
		}
		if err := requireURL("auth.oauth.github.authorize_url", c.Auth.OAuth.GitHub.AuthorizeURL); err != nil {
			return err
		}
		if err := requireURL("auth.oauth.github.token_url", c.Auth.OAuth.GitHub.TokenURL); err != nil {
			return err
		}
		if err := requireURL("auth.oauth.github.user_url", c.Auth.OAuth.GitHub.UserURL); err != nil {
			return err
		}
	}
	if c.Quotas.AccountDailyTokens <= 0 || c.Quotas.DemoDailyTokensPerIP <= 0 {
		return fmt.Errorf("quotas must be positive")
	}
	if c.Quotas.DemoSessionsPerIPPerHour <= 0 || c.Quotas.AccountConcurrency <= 0 || c.Quotas.SignupAccountsPerIPPerDay <= 0 {
		return fmt.Errorf("quota counters must be positive")
	}
	if c.Quotas.DemoConcurrency <= 0 {
		return fmt.Errorf("quotas.demo_concurrency must be positive")
	}
	if c.Quotas.ReaperIntervalHours < 1 {
		return fmt.Errorf("quotas.reaper_interval_hours must be >= 1")
	}
	if c.Quotas.ReservationMaxAgeHours < 2 {
		return fmt.Errorf("quotas.reservation_max_age_hours must be >= 2")
	}
	if c.Limits.MaxTokensPerRequest <= 0 || c.Limits.DemoMaxTokensPerRequest <= 0 || c.Limits.RequestBodyBytes <= 0 {
		return fmt.Errorf("limits must be positive")
	}
	if c.Limits.MaxFeedbackCommentBytes <= 0 {
		return fmt.Errorf("limits.max_feedback_comment_bytes must be > 0")
	}
	if c.Capacity.MonthlyBudgetUSD <= 0 || c.Capacity.ReadyProviderDegradedThreshold <= 0 || c.Capacity.ProjectedCostTier1Percent <= 0 || c.Capacity.TierCooldownSeconds <= 0 {
		return fmt.Errorf("capacity thresholds must be positive")
	}
	if c.Timeouts.CoordinatorRequestSeconds <= 0 || c.Timeouts.CoordinatorHeaderTimeoutSeconds <= 0 || c.Timeouts.StreamingCancelMS <= 0 {
		return fmt.Errorf("timeouts must be positive")
	}
	if c.Routing.StickyTTLS <= 0 {
		return fmt.Errorf("routing.sticky_ttl_s must be > 0")
	}
	for i, origin := range c.CORS.AllowedOrigins {
		if origin == "*" || origin == "null" {
			return fmt.Errorf("cors.allowed_origins[%d] must not be wildcard or null", i)
		}
		u, err := url.Parse(origin)
		if err != nil || u.Scheme == "" || u.Host == "" || u.Path != "" || u.RawQuery != "" || u.Fragment != "" {
			return fmt.Errorf("cors.allowed_origins[%d] must be an exact origin", i)
		}
	}
	return nil
}

func (c Config) TrustedProxyNets() ([]*net.IPNet, error) {
	nets := make([]*net.IPNet, 0, len(c.Proxy.TrustedCIDRs))
	for _, raw := range c.Proxy.TrustedCIDRs {
		_, network, err := parseCIDROrIP(raw)
		if err != nil {
			return nil, err
		}
		nets = append(nets, network)
	}
	return nets, nil
}

func parseCIDROrIP(raw string) (string, *net.IPNet, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", nil, fmt.Errorf("empty")
	}
	if strings.Contains(raw, "/") {
		ip, network, err := net.ParseCIDR(raw)
		if err != nil {
			return "", nil, err
		}
		network.IP = ip
		return raw, network, nil
	}
	ip := net.ParseIP(raw)
	if ip == nil {
		return "", nil, fmt.Errorf("invalid IP")
	}
	bits := 32
	if ip.To4() == nil {
		bits = 128
	}
	return raw, &net.IPNet{IP: ip, Mask: net.CIDRMask(bits, bits)}, nil
}

func requireURL(field, raw string) error {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme == "" || u.Host == "" {
		return fmt.Errorf("%s must be an absolute URL", field)
	}
	return nil
}

func (c Config) Address() string {
	return fmt.Sprintf("%s:%d", c.Listen.BindAddress, c.Listen.Port)
}

func (c Config) CoordinatorTimeout() time.Duration {
	return time.Duration(c.Timeouts.CoordinatorRequestSeconds) * time.Second
}

// CoordinatorHeaderTimeout is the max time to wait for the coordinator to
// start sending response headers after the request is fully written. This
// bounds buyer-visible hangs during coordinator restarts or empty-pool windows
// without capping long-running inference streams (ResponseHeaderTimeout only
// covers the header phase; body streaming continues unaffected).
func (c Config) CoordinatorHeaderTimeout() time.Duration {
	return time.Duration(c.Timeouts.CoordinatorHeaderTimeoutSeconds) * time.Second
}
