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
	Settlement  SettlementConfig  `yaml:"settlement"`
	CORS        CORSConfig        `yaml:"cors"`
	Routing     RoutingConfig     `yaml:"routing"`
	Retry503    Retry503Config    `yaml:"retry_503"`
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
	BuyerURL    string `yaml:"buyer_url"`
	OperatorURL string `yaml:"operator_url"`
	OperatorKey string `yaml:"operator_key"`
	// ServiceToken is the optional service-to-service credential the
	// gateway sends on UPSTREAM calls to the coordinator (M3-2 /
	// SECU-4). When set, it is preferred over OperatorKey on every
	// outbound /poolz, /internal/*, /admin/* request; OperatorKey
	// remains the fallback so an upgraded gateway can still talk to a
	// not-yet-upgraded coordinator. Gateway's OWN admin-plane auth
	// (operatorAuthorized) keeps using OperatorKey — that's the
	// human-admin credential and is intentionally separate.
	ServiceToken      string `yaml:"service_token"`
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
	ReturnToAllowlist []string          `yaml:"return_to_allowlist"`
	StateMaxPerIP     int               `yaml:"state_max_per_ip"`
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
	AccountDailyTokens          int64 `yaml:"account_daily_tokens"`
	DemoDailyTokensPerIP        int64 `yaml:"demo_daily_tokens_per_ip"`
	DemoSessionsPerIPPerHour    int   `yaml:"demo_sessions_per_ip_per_hour"`
	AccountConcurrency          int   `yaml:"account_concurrency"`
	AccountRequestRatePerSecond int   `yaml:"account_request_rate_per_second"`
	DemoConcurrency             int   `yaml:"demo_concurrency"`
	SignupAccountsPerIPPerDay   int   `yaml:"signup_accounts_per_ip_per_day"`
	ReaperIntervalHours         uint  `yaml:"reaper_interval_hours"`
	ReservationMaxAgeHours      uint  `yaml:"reservation_max_age_hours"`
}

type LimitsConfig struct {
	MaxTokensPerRequest          int64 `yaml:"max_tokens_per_request"`
	DemoMaxTokensPerRequest      int64 `yaml:"demo_max_tokens_per_request"`
	MaxFeedbackCommentBytes      int   `yaml:"max_feedback_comment_bytes"`
	MaxFeedbackBodyBytes         int64 `yaml:"max_feedback_body_bytes"`
	FeedbackRequestsPerIPPerHour int   `yaml:"feedback_requests_per_ip_per_hour"`
	RequestBodyBytes             int64 `yaml:"request_body_bytes"`
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
	StreamingIdleMS                 int `yaml:"streaming_idle_ms"`
}

type SettlementConfig struct {
	ReconcileEnabled               bool `yaml:"reconcile_enabled"`
	ReconcileIntervalSeconds       int  `yaml:"reconcile_interval_s"`
	ReconcileBatchLimit            int  `yaml:"reconcile_batch_limit"`
	ReconcileRequestTimeoutSeconds int  `yaml:"reconcile_request_timeout_s"`
}

type CORSConfig struct {
	AllowedOrigins []string `yaml:"allowed_origins"`
}

type RoutingConfig struct {
	StickyEnabled bool `yaml:"sticky_enabled"`
	StickyTTLS    int  `yaml:"sticky_ttl_s"`
}

type Retry503Config struct {
	Enabled       bool `yaml:"enabled"`
	MaxAttempts   int  `yaml:"max_attempts"`
	BackoffBaseMs int  `yaml:"backoff_base_ms"`
	BackoffMaxMs  int  `yaml:"backoff_max_ms"`
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
			OAuth: OAuthConfig{StateMaxPerIP: 20, CallbackAllowlist: []string{
				"https://api.streamvc.live/auth/github/callback",
			}, GitHub: GitHubOAuthConfig{
				AuthorizeURL: "https://github.com/login/oauth/authorize",
				TokenURL:     "https://github.com/login/oauth/access_token",
				UserURL:      "https://api.github.com/user",
			}},
		},
		Quotas: QuotasConfig{
			AccountDailyTokens:       100000,
			DemoDailyTokensPerIP:     1000,
			DemoSessionsPerIPPerHour: 10,
			// Issue #375: AccountConcurrency=4 gives one runaway
			// buyer enough headroom for normal multi-agent fan-out
			// without letting a large local burst monopolize the
			// provider pool. AccountRequestRatePerSecond is the
			// gateway-edge steady request-start bucket for the same
			// account_id.
			// DemoConcurrency stays at 2 because M1-8 / PERF-6
			// documented that 3+ parallel demo requests from one
			// IP saturate the MLX-serialized provider pool for up
			// to CoordinatorTimeout — an accidental DoS against
			// paying buyers. Bumping the demo default to 3 would
			// re-introduce that regression. Operators can override
			// account_concurrency, account_request_rate_per_second,
			// or demo_concurrency in gateway.yaml.
			AccountConcurrency:          4,
			AccountRequestRatePerSecond: 30,
			DemoConcurrency:             2,
			SignupAccountsPerIPPerDay:   3,
			ReaperIntervalHours:         1,
			ReservationMaxAgeHours:      24,
		},
		Limits: LimitsConfig{
			MaxTokensPerRequest:          4096,
			DemoMaxTokensPerRequest:      512,
			MaxFeedbackCommentBytes:      2000,
			MaxFeedbackBodyBytes:         16 * 1024,
			FeedbackRequestsPerIPPerHour: 10,
			RequestBodyBytes:             1048576,
		},
		Capacity: CapacityConfig{
			MonthlyBudgetUSD: 500, ReadyProviderDegradedThreshold: 1, ProjectedCostTier1Percent: 80, TierCooldownSeconds: 3600,
		},
		Timeouts: TimeoutsConfig{CoordinatorRequestSeconds: 300, CoordinatorHeaderTimeoutSeconds: 300, StreamingCancelMS: 500, StreamingIdleMS: 10000},
		Settlement: SettlementConfig{
			ReconcileEnabled:               true,
			ReconcileIntervalSeconds:       30,
			ReconcileBatchLimit:            100,
			ReconcileRequestTimeoutSeconds: 10,
		},
		CORS:     CORSConfig{AllowedOrigins: []string{"https://console.streamvc.live", "https://streamvc.live"}},
		Routing:  RoutingConfig{StickyEnabled: false, StickyTTLS: 1800},
		Retry503: Retry503Config{Enabled: true, MaxAttempts: 3, BackoffBaseMs: 100, BackoffMaxMs: 500},
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
	if err := cfg.resolveEnv(); err != nil {
		return Config{}, err
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// resolveEnv expands "env:NAME" sentinels in secret-bearing fields by
// reading the named environment variable. This is intentionally
// duplicated from the coordinator-side resolver at
// phase4-coordinator/internal/config/config.go:410-422 to avoid a
// cross-module import; the M3-2 audit recorded that as the house
// pattern for config plumbing.
//
// FAIL-CLOSED contract (codex PR #73 MED fix): when the YAML uses an
// env: sentinel and the referenced variable is unset OR empty, Load
// returns an error. Pre-fix, the silent fall-through to "" let the
// gateway boot with an empty ServiceToken — at which point
// UpstreamCoordinatorBearer() silently fell back to OperatorKey,
// defeating the M3-2 cutover the operator had configured. Matches the
// coordinator-side fail-closed pattern.
func (c *Config) resolveEnv() error {
	for _, f := range []struct {
		field string
		dst   *string
	}{
		{"coordinator.operator_key", &c.Coordinator.OperatorKey},
		{"coordinator.service_token", &c.Coordinator.ServiceToken},
		{"auth.key_hash_secret", &c.Auth.KeyHashSecret},
		{"auth.oauth.github.client_id", &c.Auth.OAuth.GitHub.ClientID},
		{"auth.oauth.github.client_secret", &c.Auth.OAuth.GitHub.ClientSecret},
		{"auth.demo.signing_secret", &c.Auth.Demo.SigningSecret},
	} {
		v, err := resolveEnvValue(f.field, *f.dst)
		if err != nil {
			return err
		}
		*f.dst = v
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
	for i, returnTo := range c.Auth.OAuth.ReturnToAllowlist {
		if err := requireURL(fmt.Sprintf("auth.oauth.return_to_allowlist[%d]", i), returnTo); err != nil {
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
	if c.Auth.OAuth.StateMaxPerIP <= 0 {
		return fmt.Errorf("auth.oauth.state_max_per_ip must be > 0")
	}
	if c.Quotas.AccountDailyTokens <= 0 || c.Quotas.DemoDailyTokensPerIP <= 0 {
		return fmt.Errorf("quotas must be positive")
	}
	if c.Quotas.DemoSessionsPerIPPerHour <= 0 || c.Quotas.AccountConcurrency <= 0 || c.Quotas.SignupAccountsPerIPPerDay <= 0 {
		return fmt.Errorf("quota counters must be positive")
	}
	if c.Quotas.AccountRequestRatePerSecond <= 0 {
		return fmt.Errorf("quotas.account_request_rate_per_second must be positive")
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
	if c.Limits.MaxFeedbackCommentBytes <= 0 || c.Limits.MaxFeedbackBodyBytes <= 0 || c.Limits.FeedbackRequestsPerIPPerHour <= 0 {
		return fmt.Errorf("feedback limits must be positive")
	}
	if int64(c.Limits.MaxFeedbackCommentBytes) > c.Limits.MaxFeedbackBodyBytes {
		return fmt.Errorf("limits.max_feedback_comment_bytes must be <= limits.max_feedback_body_bytes")
	}
	if c.Capacity.MonthlyBudgetUSD <= 0 || c.Capacity.ReadyProviderDegradedThreshold <= 0 || c.Capacity.ProjectedCostTier1Percent <= 0 || c.Capacity.TierCooldownSeconds <= 0 {
		return fmt.Errorf("capacity thresholds must be positive")
	}
	if c.Timeouts.CoordinatorRequestSeconds <= 0 || c.Timeouts.CoordinatorHeaderTimeoutSeconds <= 0 || c.Timeouts.StreamingCancelMS <= 0 || c.Timeouts.StreamingIdleMS <= 0 {
		return fmt.Errorf("timeouts must be positive")
	}
	// Post-#92 / PR #167: header timeout must be >= request budget so a
	// slow-but-valid streaming first-event (or non-streaming completion)
	// doesn't false-fail before the coordinator's own request_timeout_s
	// runs out. The deploy gate at phase4-coordinator/dist/check-deploy-config.sh
	// (C2b) enforces this at deploy time; this runtime check ensures a
	// gateway started outside the deploy gate (direct `gateway -config` /
	// `gateway -check`) also refuses an unsafe local config.
	if c.Timeouts.CoordinatorHeaderTimeoutSeconds < c.Timeouts.CoordinatorRequestSeconds {
		return fmt.Errorf("timeouts.coordinator_header_timeout_seconds (%d) must be >= timeouts.coordinator_request_seconds (%d) — see SPEC-002 FR-P11a (post-#92)",
			c.Timeouts.CoordinatorHeaderTimeoutSeconds, c.Timeouts.CoordinatorRequestSeconds)
	}
	if !c.Settlement.ReconcileEnabled {
		return fmt.Errorf("settlement.reconcile_enabled must be true")
	}
	if c.Settlement.ReconcileIntervalSeconds <= 0 {
		return fmt.Errorf("settlement.reconcile_interval_s must be > 0 when settlement.reconcile_enabled is true")
	}
	if c.Settlement.ReconcileBatchLimit <= 0 || c.Settlement.ReconcileBatchLimit > 500 {
		return fmt.Errorf("settlement.reconcile_batch_limit must be between 1 and 500 when settlement.reconcile_enabled is true")
	}
	if c.Settlement.ReconcileRequestTimeoutSeconds <= 0 {
		return fmt.Errorf("settlement.reconcile_request_timeout_s must be > 0 when settlement.reconcile_enabled is true")
	}
	if c.Routing.StickyTTLS <= 0 {
		return fmt.Errorf("routing.sticky_ttl_s must be > 0")
	}
	if c.Retry503.MaxAttempts < 1 || c.Retry503.MaxAttempts > 10 {
		return fmt.Errorf("retry_503.max_attempts must be between 1 and 10")
	}
	if c.Retry503.BackoffBaseMs < 10 || c.Retry503.BackoffBaseMs > 5000 {
		return fmt.Errorf("retry_503.backoff_base_ms must be between 10 and 5000")
	}
	if c.Retry503.BackoffMaxMs < 10 || c.Retry503.BackoffMaxMs > 10000 {
		return fmt.Errorf("retry_503.backoff_max_ms must be between 10 and 10000")
	}
	if c.Retry503.BackoffMaxMs < c.Retry503.BackoffBaseMs {
		return fmt.Errorf("retry_503.backoff_max_ms must be >= retry_503.backoff_base_ms")
	}
	corsOrigins := make(map[string]struct{}, len(c.CORS.AllowedOrigins))
	for i, origin := range c.CORS.AllowedOrigins {
		if origin == "*" || origin == "null" {
			return fmt.Errorf("cors.allowed_origins[%d] must not be wildcard or null", i)
		}
		u, err := url.Parse(origin)
		if err != nil || u.Scheme == "" || u.Host == "" || u.Path != "" || u.RawQuery != "" || u.Fragment != "" {
			return fmt.Errorf("cors.allowed_origins[%d] must be an exact origin", i)
		}
		corsOrigins[strings.ToLower(u.Scheme)+"://"+strings.ToLower(u.Host)] = struct{}{}
	}
	// Every return_to allowlist entry must have a matching CORS origin,
	// otherwise the browser-side POST /auth/handoff/exchange call from the
	// return-to page's origin fails CORS after the OAuth redirect succeeds,
	// leaving the user on the return-to page with no API key and no
	// operator-visible signal beyond a browser console error.
	for i, returnTo := range c.Auth.OAuth.ReturnToAllowlist {
		u, err := url.Parse(returnTo)
		if err != nil || u.Scheme == "" || u.Host == "" {
			continue // requireURL above already covered this.
		}
		origin := strings.ToLower(u.Scheme) + "://" + strings.ToLower(u.Host)
		if _, ok := corsOrigins[origin]; !ok {
			return fmt.Errorf("auth.oauth.return_to_allowlist[%d] origin %q missing matching cors.allowed_origins entry", i, origin)
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

// UpstreamCoordinatorBearer returns the credential the gateway should
// send on UPSTREAM calls to the coordinator (M3-2 / SECU-4). Prefer
// ServiceToken when set; fall back to OperatorKey for backward
// compatibility with not-yet-upgraded coordinators. Empty return means
// the gateway is misconfigured — Validate guarantees OperatorKey is
// non-empty, so this only returns "" if a future caller bypasses Load.
//
// TODO(m3-2-cleanup): remove the OperatorKey fallback in a dedicated PR
// once live coordinator audit logs show zero gateway-origin
// `key=operator_key` for 30 days post-OperatorKey-rotation. Tracked in
// audits/2026-06-10/M3-2_LEGACY_FALLBACK_REMOVAL.md. Until that gate is
// met, removing the fallback would break the cutover for not-yet-
// upgraded operators.
func (c CoordinatorConfig) UpstreamCoordinatorBearer() string {
	if c.ServiceToken != "" {
		return c.ServiceToken
	}
	return c.OperatorKey
}

func (c Config) CoordinatorTimeout() time.Duration {
	return time.Duration(c.Timeouts.CoordinatorRequestSeconds) * time.Second
}

// CoordinatorHeaderTimeout is the max time to wait for the coordinator to
// start sending response headers after the request is fully written. Both
// modes can defer header-commit until the full request budget elapses:
//   - Non-streaming: coordinator buffers the entire response, so headers
//     arrive at completion (bounded by provider inference latency).
//   - Streaming (post-#92): headers wait for the first commit-worthy SSE
//     event from the provider; pre-event garbage no longer commits.
//
// Therefore this MUST be >= CoordinatorRequestSeconds so a slow-but-valid
// provider does not false-fail as coordinator_unavailable before the
// coordinator's own routing.request_timeout_s has elapsed. The deploy-time
// guard at phase4-coordinator/dist/check-deploy-config.sh C2b enforces this.
func (c Config) CoordinatorHeaderTimeout() time.Duration {
	return time.Duration(c.Timeouts.CoordinatorHeaderTimeoutSeconds) * time.Second
}

func (c Config) StreamingIdleTimeout() time.Duration {
	return time.Duration(c.Timeouts.StreamingIdleMS) * time.Millisecond
}
