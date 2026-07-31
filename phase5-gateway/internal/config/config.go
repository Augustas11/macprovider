package config

import (
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
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
	Features    FeaturesConfig    `yaml:"features"`
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
	// ServiceToken is the REQUIRED service-to-service credential the
	// gateway sends on UPSTREAM /internal/* calls to the coordinator
	// (M3-2 / SECU-4). After PR #87 item 3 this is the ONLY accepted
	// credential on the coordinator's /internal/routing and
	// /internal/sticky endpoints — the legacy OperatorKey fallback was
	// removed after the 30-day clean-cutover gate in the M3-2 tracker.
	// OperatorKey remains for /poolz proxying (operator-only path).
	// Validate() now requires ServiceToken non-empty.
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
	// IdlessDedupeWindowSeconds bounds how long after attempt 1's terminal
	// an identical, id-less re-send is treated as a retry of that attempt
	// (issue #762). 0 DISABLES id-less dedupe entirely — the operator kill
	// switch that restores the pre-#762 bill-every-attempt behavior.
	IdlessDedupeWindowSeconds uint `yaml:"idless_dedupe_window_seconds"`
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
	// Issue #760 per-phase deadlines. These replace the single flat
	// request wall on the STREAMING path; the non-streaming path keeps a
	// flat wall (non_stream_request_seconds). YAML-only by design — the
	// env: resolver is secrets-only, so there are no env overrides here.
	//
	// CoordinatorConnectSeconds bounds TCP dial + TLS handshake to the
	// coordinator (transport-level, per connection attempt).
	CoordinatorConnectSeconds int `yaml:"coordinator_connect_seconds"`
	// CoordinatorAdmissionSeconds bounds gateway first-byte-of-request to
	// coordinator response headers, ACROSS the 503/502 retry loop.
	CoordinatorAdmissionSeconds int `yaml:"coordinator_admission_seconds"`
	// FirstTokenSeconds (0 = derive: min(120, coordinator_header_timeout_
	// seconds)) bounds response headers to the first
	// content-bearing delta on a streaming response.
	FirstTokenSeconds int `yaml:"first_token_seconds"`
	// StreamCeiling* derive the hard streaming safety bound from the
	// request's max_tokens: clamp(floor + max_tokens*per_token,
	// >= coordinator_request_seconds, <= max).
	StreamCeilingFloorSeconds int `yaml:"stream_ceiling_floor_seconds"`
	StreamCeilingPerTokenMS   int `yaml:"stream_ceiling_per_token_ms"`
	StreamCeilingMaxSeconds   int `yaml:"stream_ceiling_max_seconds"`
	// NonStreamRequestSeconds is the flat wall retained for non-streaming
	// requests, where the coordinator buffers the whole response and there
	// are no intermediate phases to observe. 0 (the default) inherits
	// coordinator_request_seconds, so a pre-#760 config that raised only the
	// legacy wall keeps its non-streaming bound unchanged.
	NonStreamRequestSeconds int `yaml:"non_stream_request_seconds"`
	StreamingCancelMS       int `yaml:"streaming_cancel_ms"`
	StreamingIdleMS         int `yaml:"streaming_idle_ms"`
}

type SettlementConfig struct {
	ReconcileEnabled               bool `yaml:"reconcile_enabled"`
	ReconcileIntervalSeconds       int  `yaml:"reconcile_interval_s"`
	ReconcileBatchLimit            int  `yaml:"reconcile_batch_limit"`
	ReconcileRequestTimeoutSeconds int  `yaml:"reconcile_request_timeout_s"`

	// Issue #763 durable settlement journal. Every knob defaults to a
	// working value in Default(), and Load() decodes YAML ON TOP of
	// Default(), so a pre-#763 config that sets none of these boots with the
	// journal on — the same back-compat mechanism reconcile_enabled relies
	// on.
	//
	// JournalEnabled mirrors ReconcileEnabled: Validate REQUIRES true. The
	// journal is the only thing standing between an after-commit settle
	// failure and an unbillable delivered request, so disabling it is not an
	// operator-tunable posture.
	JournalEnabled bool `yaml:"journal_enabled"`
	// JournalDir defaults to <dir of storage.db_path>/settlement-journal.
	// See Config.SettlementJournalDir.
	JournalDir string `yaml:"journal_dir"`
	// JournalFsync controls the per-effect fsync. Validate requires true:
	// without it the journal survives a process crash but NOT a power loss,
	// which is most of the point. The field exists as an escape hatch for
	// throwaway environments that construct Config directly (tests,
	// benchmarks) and never call Validate.
	JournalFsync bool `yaml:"journal_fsync"`
	// JournalSegmentMaxBytes bounds one segment file.
	JournalSegmentMaxBytes int64 `yaml:"journal_segment_max_bytes"`
	// JournalMaxTotalBytes is the HARD cap across all segments. Past it the
	// journal refuses records with a CRITICAL log instead of filling the
	// disk out from under sqlite (settlement still runs: journal writes are
	// fail-open).
	JournalMaxTotalBytes int64 `yaml:"journal_max_total_bytes"`
	// JournalRetentionHours bounds how long a fully-sealed, quarantine-free
	// segment is kept before pruning.
	JournalRetentionHours int `yaml:"journal_retention_hours"`
	// JournalRecoveryIntervalSeconds paces the recovery loop. It is
	// deliberately its OWN knob rather than a reuse of
	// reconcile_interval_s: the SPEC-022 reconciler talks to the
	// coordinator, this pass only touches local disk plus the local DB.
	JournalRecoveryIntervalSeconds int `yaml:"journal_recovery_interval_s"`
	// JournalRecoveryBatchLimit bounds effects re-driven per pass. The store
	// runs at MaxOpenConns=1, so an unbounded pass would stall the money
	// path behind recovery work.
	JournalRecoveryBatchLimit int `yaml:"journal_recovery_batch_limit"`
	// JournalRecoveryGraceSeconds holds back effects written within the
	// window, so recovery cannot race a settle that is still in flight on
	// its request goroutine.
	JournalRecoveryGraceSeconds int `yaml:"journal_recovery_grace_s"`
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

type FeaturesConfig struct {
	ResponsesAPIEnabled      bool `yaml:"responses_api_enabled"`
	AnthropicMessagesEnabled bool `yaml:"anthropic_messages_enabled"`
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
			// #762: 60s covers the SDK/OpenRouter retry ladder (which
			// re-sends within seconds) without turning the gateway into a
			// general response cache. Longer windows widen the only real
			// false-positive: a deliberate re-roll at temperature > 0.
			IdlessDedupeWindowSeconds: 60,
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
		Timeouts: TimeoutsConfig{
			CoordinatorRequestSeconds:       300,
			CoordinatorHeaderTimeoutSeconds: 300,
			// #760 defaults. Connect 60s (NOT 15s) so a provider warmup
			// window behind a cold coordinator does not 503 the buyer.
			// Admission 120s fails a pre-header hang ~2.5x faster than the
			// old 300s wall. First token 120s covers a slow prefill.
			// Ceiling 60s + 250ms/token, capped at 900s and floored at
			// coordinator_request_seconds so it is never shorter than the
			// flat wall it replaces.
			CoordinatorConnectSeconds:   60,
			CoordinatorAdmissionSeconds: 120,
			FirstTokenSeconds:           0, // derive min(120, header timeout)
			StreamCeilingFloorSeconds:   60,
			StreamCeilingPerTokenMS:     250,
			StreamCeilingMaxSeconds:     900,
			NonStreamRequestSeconds:     0, // inherit coordinator_request_seconds
			StreamingCancelMS:           500,
			StreamingIdleMS:             10000,
		},
		Settlement: SettlementConfig{
			ReconcileEnabled:               true,
			ReconcileIntervalSeconds:       30,
			ReconcileBatchLimit:            100,
			ReconcileRequestTimeoutSeconds: 10,
			// #763. journal_enabled must DEFAULT to true because Validate
			// requires it: a pre-#763 gateway.yaml sets no journal keys, and
			// a false default would refuse to boot every existing config.
			JournalEnabled:                 true,
			JournalDir:                     "", // derive from storage.db_path
			JournalFsync:                   true,
			JournalSegmentMaxBytes:         16 << 20,
			JournalMaxTotalBytes:           512 << 20,
			JournalRetentionHours:          168,
			JournalRecoveryIntervalSeconds: 30,
			JournalRecoveryBatchLimit:      100,
			JournalRecoveryGraceSeconds:    60,
		},
		CORS:     CORSConfig{AllowedOrigins: []string{"https://console.streamvc.live", "https://streamvc.live"}},
		Routing:  RoutingConfig{StickyEnabled: false, StickyTTLS: 1800},
		Retry503: Retry503Config{Enabled: true, MaxAttempts: 3, BackoffBaseMs: 100, BackoffMaxMs: 500},
		Explorer: ExplorerConfig{Enabled: false},
		Features: FeaturesConfig{ResponsesAPIEnabled: false, AnthropicMessagesEnabled: false},
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
	// After PR #87 item 3, service_token is
	// REQUIRED — the coordinator no longer accepts the legacy operator_key
	// fallback on /internal/*, so a gateway without service_token can't
	// route any buyer traffic.
	serviceToken := strings.TrimSpace(c.Coordinator.ServiceToken)
	if serviceToken == "" {
		return fmt.Errorf("coordinator.service_token must be set (post-M3-2 cutover: required for /internal/* upstream calls)")
	}
	// Compare after TrimSpace: the coordinator strips both sides before
	// matching the bearer, so "X" and "X " collapse to the same value
	// on the wire. A strict == on the raw fields would let an operator
	// pass distinctness while effectively reusing the operator credential.
	if serviceToken == strings.TrimSpace(c.Coordinator.OperatorKey) {
		return fmt.Errorf("coordinator.service_token must differ from coordinator.operator_key (rotation discipline: equal values — including whitespace-equivalent — would let the operator credential authenticate /internal/* by value)")
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
	// 0 is legal (kill switch). The upper bound keeps a typo from turning the
	// bounded retry-dedupe index into a long-lived response cache.
	if c.Quotas.IdlessDedupeWindowSeconds > 3600 {
		return fmt.Errorf("quotas.idless_dedupe_window_seconds must be <= 3600")
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
	// Issue #760 per-phase deadline orderings.
	if c.Timeouts.CoordinatorConnectSeconds <= 0 || c.Timeouts.CoordinatorAdmissionSeconds <= 0 ||
		c.Timeouts.FirstTokenSeconds < 0 || c.Timeouts.StreamCeilingFloorSeconds <= 0 ||
		c.Timeouts.StreamCeilingPerTokenMS <= 0 || c.Timeouts.StreamCeilingMaxSeconds <= 0 ||
		c.Timeouts.NonStreamRequestSeconds < 0 {
		return fmt.Errorf("timeouts phase budgets must be positive")
	}
	if c.Timeouts.CoordinatorAdmissionSeconds < c.Timeouts.CoordinatorConnectSeconds {
		return fmt.Errorf("timeouts.coordinator_admission_seconds (%d) must be >= timeouts.coordinator_connect_seconds (%d) — admission spans the connect attempt plus the retry loop",
			c.Timeouts.CoordinatorAdmissionSeconds, c.Timeouts.CoordinatorConnectSeconds)
	}
	// Post-#92 / PR #167, retargeted after #760/#784: the transport header
	// timeout must cover every path that can legitimately defer coordinator
	// response headers. Streaming headers commit at the first commit-worthy
	// SSE event and are bounded by admission; non-streaming headers arrive only
	// after the buffered response completes and are bounded by the effective
	// non-streaming wall. The deploy gate at phase4-coordinator/dist/
	// check-deploy-config.sh (C2b) enforces this at deploy time; this runtime
	// check covers direct `gateway -config` / `gateway -check` starts outside
	// the deploy gate.
	effectiveNonStreamSeconds := c.Timeouts.CoordinatorRequestSeconds
	if c.Timeouts.NonStreamRequestSeconds > 0 {
		effectiveNonStreamSeconds = c.Timeouts.NonStreamRequestSeconds
	}
	requiredHeaderSeconds := c.Timeouts.CoordinatorAdmissionSeconds
	if effectiveNonStreamSeconds > requiredHeaderSeconds {
		requiredHeaderSeconds = effectiveNonStreamSeconds
	}
	if c.Timeouts.CoordinatorHeaderTimeoutSeconds < requiredHeaderSeconds {
		return fmt.Errorf("timeouts.coordinator_header_timeout_seconds (%d) must be >= max(timeouts.coordinator_admission_seconds (%d), effective timeouts.non_stream_request_seconds (%d)) — see SPEC-002 FR-P11a C2b",
			c.Timeouts.CoordinatorHeaderTimeoutSeconds, c.Timeouts.CoordinatorAdmissionSeconds, effectiveNonStreamSeconds)
	}
	// Twin of the C2b rule above, for the first-token phase: the transport
	// gives up on a header-less coordinator after coordinator_header_timeout_
	// seconds, so a first_token budget beyond that can never be observed —
	// streaming headers commit at the first commit-worthy SSE event (post-#92).
	// Only an EXPLICIT first_token budget can conflict with the transport
	// header timeout; the derived default (0) clamps itself to it. Admission
	// coverage is validated separately by the C2b relation above.
	if c.Timeouts.FirstTokenSeconds > 0 && c.Timeouts.CoordinatorHeaderTimeoutSeconds < c.Timeouts.FirstTokenSeconds {
		return fmt.Errorf("timeouts.coordinator_header_timeout_seconds (%d) must be >= timeouts.first_token_seconds (%d) — the transport header timeout bounds the first commit-worthy SSE event; set first_token_seconds to 0 to derive it",
			c.Timeouts.CoordinatorHeaderTimeoutSeconds, c.Timeouts.FirstTokenSeconds)
	}
	if c.Timeouts.StreamCeilingMaxSeconds < c.Timeouts.StreamCeilingFloorSeconds {
		return fmt.Errorf("timeouts.stream_ceiling_max_seconds (%d) must be >= timeouts.stream_ceiling_floor_seconds (%d)",
			c.Timeouts.StreamCeilingMaxSeconds, c.Timeouts.StreamCeilingFloorSeconds)
	}
	// Monotonicity invariant (#760): the derived streaming ceiling floors at
	// coordinator_request_seconds, so a max BELOW it would make the clamp
	// self-contradictory and hide a config that intended to SHORTEN the wall.
	if c.Timeouts.StreamCeilingMaxSeconds < c.Timeouts.CoordinatorRequestSeconds {
		return fmt.Errorf("timeouts.stream_ceiling_max_seconds (%d) must be >= timeouts.coordinator_request_seconds (%d) — the per-phase streaming ceiling must never be shorter than the flat wall it replaces",
			c.Timeouts.StreamCeilingMaxSeconds, c.Timeouts.CoordinatorRequestSeconds)
	}
	if c.Timeouts.NonStreamRequestSeconds > 0 && c.Timeouts.NonStreamRequestSeconds < c.Timeouts.CoordinatorConnectSeconds {
		return fmt.Errorf("timeouts.non_stream_request_seconds (%d) must be >= timeouts.coordinator_connect_seconds (%d), or 0 to inherit coordinator_request_seconds",
			c.Timeouts.NonStreamRequestSeconds, c.Timeouts.CoordinatorConnectSeconds)
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
	// #763 durable settlement journal. Mirrors the reconcile_enabled rule:
	// the money-path invariant it protects (a delivered request is always
	// billable) is not an operator posture.
	if !c.Settlement.JournalEnabled {
		return fmt.Errorf("settlement.journal_enabled must be true (issue #763: without the journal an after-commit settle failure permanently drops the bill)")
	}
	if !c.Settlement.JournalFsync {
		return fmt.Errorf("settlement.journal_fsync must be true (an unsynced journal survives a process crash but not a power loss)")
	}
	if c.Settlement.JournalSegmentMaxBytes <= 0 {
		return fmt.Errorf("settlement.journal_segment_max_bytes must be > 0")
	}
	if c.Settlement.JournalMaxTotalBytes < c.Settlement.JournalSegmentMaxBytes {
		return fmt.Errorf("settlement.journal_max_total_bytes (%d) must be >= settlement.journal_segment_max_bytes (%d)",
			c.Settlement.JournalMaxTotalBytes, c.Settlement.JournalSegmentMaxBytes)
	}
	if c.Settlement.JournalRetentionHours <= 0 {
		return fmt.Errorf("settlement.journal_retention_hours must be > 0")
	}
	if c.Settlement.JournalRecoveryIntervalSeconds <= 0 {
		return fmt.Errorf("settlement.journal_recovery_interval_s must be > 0")
	}
	if c.Settlement.JournalRecoveryBatchLimit <= 0 || c.Settlement.JournalRecoveryBatchLimit > 500 {
		return fmt.Errorf("settlement.journal_recovery_batch_limit must be between 1 and 500")
	}
	if c.Settlement.JournalRecoveryGraceSeconds < 0 {
		return fmt.Errorf("settlement.journal_recovery_grace_s must be >= 0")
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

// SettlementJournalDir resolves the #763 journal directory. An explicit
// settlement.journal_dir wins; otherwise it is a sibling of the sqlite file,
// which keeps the journal on the same volume as the database it protects (a
// journal on a different, unmounted volume would fail open silently).
func (c Config) SettlementJournalDir() string {
	if dir := strings.TrimSpace(c.Settlement.JournalDir); dir != "" {
		return dir
	}
	return filepath.Join(filepath.Dir(c.Storage.DBPath), "settlement-journal")
}

func (c Config) Address() string {
	return fmt.Sprintf("%s:%d", c.Listen.BindAddress, c.Listen.Port)
}

// UpstreamCoordinatorBearer returns the credential the gateway sends on
// UPSTREAM /internal/* calls to the coordinator (M3-2 / SECU-4). After
// PR #87 item 3, this is the
// gateway_service_token ONLY — the legacy OperatorKey fallback was
// removed once 30 days of clean audit-log evidence showed zero
// gateway-origin operator_key admits on /internal/*. Empty return means
// the gateway is misconfigured; Validate guarantees ServiceToken is
// non-empty, so this only returns "" if a future caller bypasses Load.
func (c CoordinatorConfig) UpstreamCoordinatorBearer() string {
	return c.ServiceToken
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
// Therefore this MUST be >= max(CoordinatorAdmissionSeconds, effective
// NonStreamRequestSeconds) so a slow first-event stream or slow non-streaming
// completion does not false-fail as coordinator_unavailable before its phase
// budget has elapsed. The deploy-time guard at
// phase4-coordinator/dist/check-deploy-config.sh C2b enforces this.
func (c Config) CoordinatorHeaderTimeout() time.Duration {
	return time.Duration(c.Timeouts.CoordinatorHeaderTimeoutSeconds) * time.Second
}

func (c Config) StreamingIdleTimeout() time.Duration {
	return time.Duration(c.Timeouts.StreamingIdleMS) * time.Millisecond
}

// The accessors below back the issue #760 per-phase deadlines. See
// TimeoutsConfig for what each phase bounds and
// phase5-gateway/internal/router/request_deadlines.go for how they are armed.

// CoordinatorConnectTimeout bounds TCP dial + TLS handshake on the
// coordinator transport. It is deliberately NOT applied to response headers:
// making the header timeout this short reintroduces the #92/#171 regression
// where a slow-but-valid first SSE event false-failed as coordinator_unavailable.
func (c Config) CoordinatorConnectTimeout() time.Duration {
	return time.Duration(c.Timeouts.CoordinatorConnectSeconds) * time.Second
}

// CoordinatorAdmissionTimeout bounds gateway first byte of request to
// coordinator response headers, across the whole 503/502 retry loop.
func (c Config) CoordinatorAdmissionTimeout() time.Duration {
	return time.Duration(c.Timeouts.CoordinatorAdmissionSeconds) * time.Second
}

// FirstTokenTimeout bounds response headers to the first content-bearing
// streaming delta. Unset (0) derives min(120s, the transport header timeout):
// the header timeout already acts as a de-facto first-token bound (streaming
// headers commit at the first SSE event, post-#92), so the derived budget can
// never promise more time than the transport allows, and short-header configs
// (CI fixtures, conservative prod overlays) keep booting unchanged (#760 CI
// integration failure).
func (c Config) FirstTokenTimeout() time.Duration {
	if c.Timeouts.FirstTokenSeconds <= 0 {
		derived := 120 * time.Second
		if header := c.CoordinatorHeaderTimeout(); header > 0 && header < derived {
			derived = header
		}
		return derived
	}
	return time.Duration(c.Timeouts.FirstTokenSeconds) * time.Second
}

// NonStreamRequestTimeout is the flat wall retained for non-streaming
// requests. Unset (0) inherits CoordinatorTimeout so a pre-#760 config that
// raised only coordinator_request_seconds keeps its non-streaming bound
// (#760 audit, architect lane).
func (c Config) NonStreamRequestTimeout() time.Duration {
	if c.Timeouts.NonStreamRequestSeconds <= 0 {
		return c.CoordinatorTimeout()
	}
	return time.Duration(c.Timeouts.NonStreamRequestSeconds) * time.Second
}
