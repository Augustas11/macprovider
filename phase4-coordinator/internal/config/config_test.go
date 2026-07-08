package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestModelClassRejectsMembersAndModelsTogether(t *testing.T) {
	cfg := Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Routing.ModelClasses = map[string]ModelClassConfig{
		"alias": {Members: []string{"model-a"}, Models: []string{"model-b"}, Objective: "fast"},
	}

	err := cfg.Validate()
	if err == nil || !strings.Contains(err.Error(), "must not set both members and models") {
		t.Fatalf("Validate error=%v", err)
	}
}

func TestProviderTokensRequiredByDefault(t *testing.T) {
	cfg := Default()
	if !cfg.Auth.RequireProviderTokens {
		t.Fatal("auth.require_provider_tokens should default to true")
	}
	if cfg.Auth.AllowTokenlessProvisionalBootstrap {
		t.Fatal("auth.allow_tokenless_provisional_bootstrap should default to false")
	}
}

func TestLoadRejectsWeakOperatorKeys(t *testing.T) {
	tests := []struct {
		name string
		key  string
		want string
	}{
		{name: "placeholder", key: "changeme", want: "placeholder_denied"},
		{name: "too_short", key: "short-but-not-placeholder", want: "too_short"},
		{name: "low_entropy", key: strings.Repeat("a", 32), want: "low_entropy"},
		{name: "repeated_zero", key: strings.Repeat("0", 32), want: "repeated_zero"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := loadConfigFromYAML(t, "auth:\n  operator_key: "+tc.key+"\n")
			if err == nil {
				t.Fatal("Load accepted weak operator key")
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error=%v want %q", err, tc.want)
			}
		})
	}
}

func TestLoadAcceptsStrongOperatorKey(t *testing.T) {
	cfg := writeMinimalConfig(t, `
auth:
  operator_key: 0123456789abcdefABCDEFghijklmnop
`)
	if cfg.Auth.OperatorKey != "0123456789abcdefABCDEFghijklmnop" {
		t.Fatalf("OperatorKey=%q", cfg.Auth.OperatorKey)
	}
}

func TestLoadRejectsWeakNamedOperatorKeys(t *testing.T) {
	tests := []struct {
		name string
		key  string
		want string
	}{
		{name: "placeholder", key: "changeme", want: "placeholder_denied"},
		{name: "too_short", key: "short-but-not-placeholder", want: "too_short"},
		{name: "low_entropy", key: strings.Repeat("a", 32), want: "low_entropy"},
		{name: "repeated_zero", key: strings.Repeat("0", 32), want: "repeated_zero"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := loadConfigFromYAML(t, `
auth:
  operator_key: 0123456789abcdefABCDEFghijklmnop
  operator_keys:
    alice: `+tc.key+`
    bob: fedcba9876543210PONMLKJIHGFEDCBA
`)
			if err == nil {
				t.Fatal("Load accepted weak named operator key")
			}
			if !strings.Contains(err.Error(), "auth.operator_keys.alice") || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error=%v want field auth.operator_keys.alice and %q", err, tc.want)
			}
		})
	}
}

func TestCanaryValidationRequiresPrivateChallengeBankWhenEnabled(t *testing.T) {
	cfg := Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Pool.CanaryEnabled = true
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "canary_challenges") {
		t.Fatalf("enabled canary without challenges validation err=%v", err)
	}

	cfg.Pool.CanaryChallenges = []CanaryChallengeConfig{{
		Prompt:   "Which US state uses postal abbreviation VT?",
		Expected: "Vermont-{nonce}",
	}}
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "{nonce}") {
		t.Fatalf("challenge without prompt nonce validation err=%v", err)
	}

	cfg.Pool.CanaryChallenges = []CanaryChallengeConfig{{
		Prompt:   "Which US state uses postal abbreviation VT? Append -{nonce}.",
		Expected: "Vermont-{nonce}",
	}}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("enabled canary with private challenge bank should validate: %v", err)
	}
}

func TestProviderWebSocketBoundsDefaultAndValidate(t *testing.T) {
	cfg := Default()
	cfg.Auth.OperatorKey = "operator-key"
	if cfg.WS.HandshakeTimeoutS != 10 || cfg.WS.WriteTimeoutS != 10 ||
		cfg.WS.MaxFrameBytes != 4<<20 || cfg.WS.MaxUnauthenticatedConn != 64 ||
		cfg.WS.MaxUnauthenticatedConnPerIP != 4 {
		t.Fatalf("unexpected ws bounds defaults: %+v", cfg.WS)
	}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("default ws bounds should validate: %v", err)
	}

	cfg.WS.MaxFrameBytes = 0
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "ws handshake") {
		t.Fatalf("zero frame cap validation err=%v", err)
	}

	cfg = Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.WS.MaxFrameBytes = 65 << 20
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "max_frame_bytes") {
		t.Fatalf("oversize frame cap validation err=%v", err)
	}
}

func TestSpec005BillingDefaultsAndValidation(t *testing.T) {
	cfg := Default()
	cfg.Auth.OperatorKey = "operator-key"
	if cfg.Rewards.GlobalMultiplier != 1.0 || cfg.Rewards.ProviderShare != 0.90 {
		t.Fatalf("unexpected rewards defaults: %+v", cfg.Rewards)
	}
	if cfg.Rewards.RateCard["default"].PromptCreditsPerMtok != 500000 ||
		cfg.Rewards.RateCard["default"].EffectivePromptCacheHitCreditsPerMtok() != 500000 ||
		cfg.Rewards.RateCard["default"].CompletionCreditsPerMtok != 1000000 {
		t.Fatalf("unexpected default rate card: %+v", cfg.Rewards.RateCard["default"])
	}
	if cfg.Settlement.CadenceDays != 7 || cfg.Settlement.MinPayoutCredits != 500000 ||
		cfg.Settlement.StartupReconcileWindowHours != 24 || cfg.Settlement.NightlyReconcileWindowDays != 7 ||
		cfg.Settlement.RecoveryGraceSeconds != 30 || cfg.Settlement.VerifiedModelSettlementMode != "observe" || !cfg.Settlement.JobEnabled {
		t.Fatalf("unexpected settlement defaults: %+v", cfg.Settlement)
	}
	if cfg.Endpoints.ProviderEarnings.RateLimitPerMinute != 60 {
		t.Fatalf("unexpected endpoints defaults: %+v", cfg.Endpoints)
	}
	if cfg.Storage.RequestLogRetentionDays != 90 {
		t.Fatalf("request log retention default=%d want 90", cfg.Storage.RequestLogRetentionDays)
	}
	if cfg.Storage.AuditLogRetentionDays != 90 {
		t.Fatalf("audit log retention default=%d want 90", cfg.Storage.AuditLogRetentionDays)
	}

	cfg.Rewards.ProviderShare = 1.01
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "provider_share") {
		t.Fatalf("provider share validation err=%v", err)
	}

	cfg = Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Settlement.RecoveryGraceSeconds = 901
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "recovery_grace_seconds") {
		t.Fatalf("settlement recovery grace above verified receipt cap should fail; err=%v", err)
	}

	cfg = Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Settlement.VerifiedModelSettlementMode = "shadow"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "verified_model_settlement_mode") {
		t.Fatalf("settlement verified model mode validation err=%v", err)
	}

	cfg = Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Storage.RequestLogRetentionDays = 0
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "request_log_retention_days") {
		t.Fatalf("request log retention validation err=%v", err)
	}

	cfg = Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Storage.AuditLogRetentionDays = 0
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "audit_log_retention_days") {
		t.Fatalf("audit log retention=0 validation err=%v", err)
	}

	cfg = Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Storage.AuditLogRetentionDays = 89
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "compliance floor") {
		t.Fatalf("audit log retention=89 (below 90-day floor) should fail; err=%v", err)
	}

	cfg = Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Storage.AuditLogRetentionDays = 90
	if err := cfg.Validate(); err != nil {
		t.Fatalf("audit log retention=90 should pass validation: %v", err)
	}

	cfg = Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Storage.RequestLogRetentionDays = 3
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "nightly_reconcile_window_days") {
		t.Fatalf("request log retention reconcile validation err=%v", err)
	}

	cfg = Default()
	cfg.Auth.OperatorKey = "operator-key"
	delete(cfg.Rewards.RateCard, "default")
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "rate_card") {
		t.Fatalf("default rate-card validation err=%v", err)
	}

	cfg = Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Rewards.RateCard["default"] = RateCardEntry{
		PromptCreditsPerMtok:         500000,
		PromptCacheHitCreditsPerMtok: 600000,
		CompletionCreditsPerMtok:     1000000,
	}
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "prompt_cache_hit_credits_per_mtok") {
		t.Fatalf("cache rate above prompt validation err=%v", err)
	}
}

func TestRateCardEntryCacheRateDefaultAndExplicitZero(t *testing.T) {
	var omitted RateCardEntry
	if err := yaml.Unmarshal([]byte("prompt_credits_per_mtok: 500000\ncompletion_credits_per_mtok: 1000000\n"), &omitted); err != nil {
		t.Fatal(err)
	}
	if got := omitted.EffectivePromptCacheHitCreditsPerMtok(); got != 500000 {
		t.Fatalf("omitted YAML cache rate=%d want prompt rate", got)
	}

	var explicitZero RateCardEntry
	if err := yaml.Unmarshal([]byte("prompt_credits_per_mtok: 500000\nprompt_cache_hit_credits_per_mtok: 0\ncompletion_credits_per_mtok: 1000000\n"), &explicitZero); err != nil {
		t.Fatal(err)
	}
	if got := explicitZero.EffectivePromptCacheHitCreditsPerMtok(); got != 0 {
		t.Fatalf("explicit zero YAML cache rate=%d want 0", got)
	}

	var snapshot RateCardEntry
	if err := json.Unmarshal([]byte(`{"prompt_rate_per_mtok":500000,"prompt_cache_hit_rate_per_mtok":250000,"completion_rate_per_mtok":1000000}`), &snapshot); err != nil {
		t.Fatal(err)
	}
	if got := snapshot.EffectivePromptCacheHitCreditsPerMtok(); got != 250000 {
		t.Fatalf("snapshot cache rate=%d want 250000", got)
	}
}

func TestCoordinatorYAMLExamplesIncludePromptCacheHitRate(t *testing.T) {
	for _, rel := range []string{
		"../../coordinator.yaml.example",
		"../../dist/coordinator.yaml.example",
	} {
		t.Run(rel, func(t *testing.T) {
			b, err := os.ReadFile(filepath.Clean(rel))
			if err != nil {
				t.Fatalf("read %s: %v", rel, err)
			}
			if !strings.Contains(string(b), "prompt_cache_hit_credits_per_mtok") {
				t.Fatalf("%s missing prompt_cache_hit_credits_per_mtok", rel)
			}
		})
	}
}

func TestTier2ValidationPreservesDefaultsAndRejectsUnsafeConfig(t *testing.T) {
	cfg := Default()
	cfg.Auth.OperatorKey = "operator-key"
	if err := cfg.Validate(); err != nil {
		t.Fatalf("default Tier2 config should validate: %v", err)
	}

	cfg = Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Tier2.CatalogPath = "/tmp/catalog.json"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "catalog_public_key") {
		t.Fatalf("catalog without public key err=%v", err)
	}

	cfg = Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Tier2.RequireHashVerified = true
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "require_hash_verified") {
		t.Fatalf("require_hash_verified without catalog err=%v", err)
	}

	cfg = Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Tier2.EncryptedLegAEAD = "unknown"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "encrypted_leg_aead") {
		t.Fatalf("unsupported AEAD err=%v", err)
	}

	cfg = Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Tier2.RequireEncryptedLeg = true
	if err := cfg.Validate(); err != nil {
		t.Fatalf("phase 2 encrypted leg enforcement should validate with default A256GCM: %v", err)
	}

	cfg = Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Tier2.RequireAttestation = true
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "require_attestation") {
		t.Fatalf("attestation without roots err=%v", err)
	}

	cfg = Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Tier2.RequireAttestation = true
	cfg.Tier2.AttestationRoots = []string{"mock-root"}
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "require_attestation") {
		t.Fatalf("mock attestation root without opt-in err=%v", err)
	}

	cfg.Tier2.AllowMockAttestation = true
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "require_attestation") {
		t.Fatalf("mock attestation root should not validate with require_attestation: %v", err)
	}

	cfg = Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Tier2.BehavioralSafetyEnabled = true
	cfg.Tier2.EncodingValidationEnabled = true
	cfg.Tier2.ResponseTimeAnomalyEnabled = true
	if err := cfg.Validate(); err != nil {
		t.Fatalf("phase 3 behavioral safety flags should validate: %v", err)
	}

	cfg = Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Tier2.OutputSizeCapBytes = -1
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "output_size_cap_bytes") {
		t.Fatalf("negative output size cap err=%v", err)
	}

	cfg = Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Tier2.ResponseTimeAnomalyFactor = 1.0
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "response_time_anomaly_factor") {
		t.Fatalf("response anomaly factor err=%v", err)
	}
}

// Issue #125: trusted-proxy CIDR validation pins for ProxyConfig.

func TestDefaultProxyConfigTrustsLoopbackOnly(t *testing.T) {
	cfg := Default()
	if got, want := len(cfg.Proxy.TrustedProxies), 2; got != want {
		t.Fatalf("default trusted_proxies len=%d want %d", got, want)
	}
	prefixes, err := cfg.TrustedProxyPrefixes()
	if err != nil {
		t.Fatalf("TrustedProxyPrefixes default parse: %v", err)
	}
	if len(prefixes) != 2 {
		t.Fatalf("default prefixes len=%d want 2", len(prefixes))
	}
	if !prefixes[0].Contains(prefixes[0].Addr()) || prefixes[0].String() != "127.0.0.0/8" {
		t.Fatalf("default[0] = %q want 127.0.0.0/8", prefixes[0].String())
	}
	if prefixes[1].String() != "::1/128" {
		t.Fatalf("default[1] = %q want ::1/128", prefixes[1].String())
	}
}

func TestTrustedProxyPrefixesRejectsDefaultRouteIPv4(t *testing.T) {
	cfg := Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Proxy.TrustedProxies = []string{"0.0.0.0/0"}
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "default-route prefix") {
		t.Fatalf("Validate(0.0.0.0/0) err=%v, want default-route rejection (every caller would be header-trusted)", err)
	}
}

func TestTrustedProxyPrefixesRejectsDefaultRouteIPv6(t *testing.T) {
	cfg := Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Proxy.TrustedProxies = []string{"::/0"}
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "default-route prefix") {
		t.Fatalf("Validate(::/0) err=%v, want default-route rejection", err)
	}
}

func TestTrustedProxyPrefixesRejectsMalformedCIDR(t *testing.T) {
	cfg := Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Proxy.TrustedProxies = []string{"not-a-cidr"}
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "proxy.trusted_proxies") {
		t.Fatalf("Validate(not-a-cidr) err=%v, want parse-error rejection", err)
	}
}

func TestTrustedProxyPrefixesEmptyAllowed(t *testing.T) {
	cfg := Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Proxy.TrustedProxies = nil // strictest posture
	if err := cfg.Validate(); err != nil {
		t.Fatalf("empty trusted_proxies Validate err=%v, want nil (empty list is strictest posture, valid)", err)
	}
}

func TestDefaultStatsConfigTrustsLoopbackOnly(t *testing.T) {
	cfg := Default()
	if got, want := len(cfg.Stats.TrustedProxies), 2; got != want {
		t.Fatalf("default stats.trusted_proxies len=%d want %d", got, want)
	}
	prefixes, err := cfg.StatsTrustedProxyPrefixes()
	if err != nil {
		t.Fatalf("StatsTrustedProxyPrefixes default parse: %v", err)
	}
	if len(prefixes) != 2 {
		t.Fatalf("default stats prefixes len=%d want 2", len(prefixes))
	}
	if prefixes[0].String() != "127.0.0.0/8" {
		t.Fatalf("default stats[0] = %q want 127.0.0.0/8", prefixes[0].String())
	}
	if prefixes[1].String() != "::1/128" {
		t.Fatalf("default stats[1] = %q want ::1/128", prefixes[1].String())
	}
}

func TestStatsTrustedProxyValidation(t *testing.T) {
	mkCfg := func(trusted []string, trustDirect bool) Config {
		cfg := Default()
		cfg.Auth.OperatorKey = "operator-key"
		cfg.Listen.BindAddress = "127.0.0.1"
		cfg.Stats.Enabled = true
		cfg.Stats.ReaderDSN = "postgres://r@/x"
		cfg.Stats.RollupDSN = "postgres://w@/x"
		cfg.Stats.TrustedProxies = trusted
		cfg.Stats.TrustDirectPeer = trustDirect
		return cfg
	}

	if err := mkCfg([]string{"not-a-cidr"}, false).Validate(); err == nil || !strings.Contains(err.Error(), "stats.trusted_proxies") {
		t.Fatalf("malformed stats trusted proxy err=%v, want stats.trusted_proxies parse error", err)
	}
	if err := mkCfg([]string{"0.0.0.0/0"}, false).Validate(); err == nil || !strings.Contains(err.Error(), "default-route prefix") {
		t.Fatalf("default-route stats trusted proxy err=%v, want rejection", err)
	}
	if err := mkCfg(nil, false).Validate(); err == nil || !strings.Contains(err.Error(), "trust_direct_peer") {
		t.Fatalf("empty stats trusted proxies err=%v, want direct-peer opt-in rejection", err)
	}
	if err := mkCfg(nil, true).Validate(); err != nil {
		t.Fatalf("empty stats trusted proxies with direct-peer opt-in err=%v, want nil", err)
	}
}

func TestOnboardingDefaultsProductionDisabled(t *testing.T) {
	cfg := Default()
	if cfg.Onboarding.AppTrackRegisterEnabled {
		t.Fatal("app-track register should default disabled")
	}
	if cfg.Onboarding.BundleID != "tech.malibu.app" {
		t.Fatalf("bundle_id=%q", cfg.Onboarding.BundleID)
	}
	if cfg.Onboarding.CoordinatorDomain != "coordinator.streamvc.live" {
		t.Fatalf("coordinator_domain=%q", cfg.Onboarding.CoordinatorDomain)
	}
}

func TestOnboardingEnabledRequiresStartupSecrets(t *testing.T) {
	cfg := Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Onboarding.AppTrackRegisterEnabled = true
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "onboarding.postgres_dsn") {
		t.Fatalf("enabled without postgres_dsn err=%v", err)
	}

	cfg.Onboarding.PostgresDSN = "postgres://provider_onboarding@127.0.0.1/db?sslmode=disable"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "onboarding.auth_policy_request_dsn") {
		t.Fatalf("enabled without auth_policy_request_dsn err=%v", err)
	}

	cfg.Onboarding.AuthPolicyRequestDSN = "postgres://provider_auth_policy_requester@127.0.0.1/db?sslmode=disable"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "onboarding.auth_policy_approve_dsn") {
		t.Fatalf("enabled without auth_policy_approve_dsn err=%v", err)
	}

	cfg.Onboarding.AuthPolicyApproveDSN = "postgres://provider_auth_policy_approver@127.0.0.1/db?sslmode=disable"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "onboarding.auth_policy_cutover_dsn") {
		t.Fatalf("enabled without auth_policy_cutover_dsn err=%v", err)
	}

	cfg.Onboarding.AuthPolicyCutoverDSN = "postgres://provider_auth_policy_cutover@127.0.0.1/db?sslmode=disable"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "onboarding.apple_team_id") {
		t.Fatalf("enabled without apple_team_id err=%v", err)
	}

	cfg.Onboarding.AppleTeamID = "TEAM12345"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "onboarding.asn_prefixes") {
		t.Fatalf("enabled without asn_prefixes err=%v", err)
	}

	cfg.Onboarding.ASNPrefixes = map[string]string{"198.51.100.0/24": "AS64500"}
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "auth.operator_keys") {
		t.Fatalf("enabled without per-operator keys err=%v", err)
	}

	cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("enabled with required secrets should validate: %v", err)
	}

	cfg.Auth.OperatorKey = ""
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "auth.operator_key") {
		t.Fatalf("enabled without operator_key err=%v", err)
	}
}

func TestOnboardingOperatorKeysRejectSharedDualControlSecrets(t *testing.T) {
	cfg := Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Onboarding.AppTrackRegisterEnabled = true
	cfg.Onboarding.PostgresDSN = "postgres://provider_onboarding@127.0.0.1/db?sslmode=disable"
	cfg.Onboarding.AuthPolicyRequestDSN = "postgres://provider_auth_policy_requester@127.0.0.1/db?sslmode=disable"
	cfg.Onboarding.AuthPolicyApproveDSN = "postgres://provider_auth_policy_approver@127.0.0.1/db?sslmode=disable"
	cfg.Onboarding.AuthPolicyCutoverDSN = "postgres://provider_auth_policy_cutover@127.0.0.1/db?sslmode=disable"
	cfg.Onboarding.AppleTeamID = "TEAM12345"
	cfg.Onboarding.ASNPrefixes = map[string]string{"198.51.100.0/24": "AS64500"}

	cfg.Auth.OperatorKeys = map[string]string{"alice": "same-secret", "bob": "same-secret"}
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "must not reuse secret") {
		t.Fatalf("duplicate operator secret err=%v", err)
	}
}

func TestOnboardingCoordinatorDomainMustBeBareLowercaseHost(t *testing.T) {
	cfg := Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Onboarding.CoordinatorDomain = "https://Coordinator.streamvc.live/"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "bare lowercase host") {
		t.Fatalf("domain validation err=%v", err)
	}
}

// TestCanaryOPoIV0StagingOverlayParsesAndValidates verifies that the OPoI v0
// staging overlay YAML unmarshals into a valid canary config block (both
// challenges contain {nonce} in prompt and expected).
func TestCanaryOPoIV0StagingOverlayParsesAndValidates(t *testing.T) {
	b, err := os.ReadFile(filepath.Clean("../../coordinator.opoi-v0-staging.yaml"))
	if err != nil {
		t.Fatalf("read staging overlay: %v", err)
	}
	var cfg Config
	if err := yaml.Unmarshal(b, &cfg); err != nil {
		t.Fatalf("unmarshal staging overlay: %v", err)
	}
	if !cfg.Pool.CanaryEnabled {
		t.Fatal("staging overlay must have canary_enabled: true")
	}
	if len(cfg.Pool.CanaryChallenges) == 0 {
		t.Fatal("staging overlay must have at least one canary_challenge")
	}
	for i, ch := range cfg.Pool.CanaryChallenges {
		if !strings.Contains(ch.Prompt, "{nonce}") || !strings.Contains(ch.Expected, "{nonce}") {
			t.Fatalf("canary_challenges[%d] missing {nonce} in prompt or expected", i)
		}
	}
}

func TestLoadWithOverlayMergesPoolCanaryBlock(t *testing.T) {
	dir := t.TempDir()
	basePath := filepath.Join(dir, "base.yaml")
	overlayPath := filepath.Join(dir, "overlay.yaml")
	if err := os.WriteFile(basePath, []byte("auth:\n  operator_key: test-operator-key-with-32-byte-minimum-length\npool:\n  canary_enabled: false\n"), 0o644); err != nil {
		t.Fatalf("write base: %v", err)
	}
	overlay := strings.TrimSpace(`
pool:
  canary_enabled: true
  canary_challenges:
    - prompt: "Reply with exactly: CANARY-{nonce}"
      expected: "CANARY-{nonce}"
`)
	if err := os.WriteFile(overlayPath, []byte(overlay), 0o644); err != nil {
		t.Fatalf("write overlay: %v", err)
	}
	cfg, err := LoadWithOverlay(basePath, overlayPath)
	if err != nil {
		t.Fatalf("LoadWithOverlay: %v", err)
	}
	if !cfg.Pool.CanaryEnabled {
		t.Fatal("overlay should enable canaries")
	}
	if len(cfg.Pool.CanaryChallenges) != 1 {
		t.Fatalf("canary challenges=%d want 1", len(cfg.Pool.CanaryChallenges))
	}
}

func TestLoadWithOverlayMalibuEmissionBlock(t *testing.T) {
	t.Setenv("MALIBU_EMISSION_WRITER_DSN", "postgres://rewards_writer:pw@127.0.0.1:5432/stats?sslmode=disable")
	dir := t.TempDir()
	basePath := filepath.Join(dir, "base.yaml")
	overlayPath := filepath.Join(dir, "malibu.yaml")
	if err := os.WriteFile(basePath, []byte("auth:\n  operator_key: test-operator-key-with-32-byte-minimum-length\n"), 0o644); err != nil {
		t.Fatalf("write base: %v", err)
	}
	overlay := strings.TrimSpace(`
malibu_emission:
  enabled: false
  writer_dsn: env:MALIBU_EMISSION_WRITER_DSN
  provider_daily_cap_malibu: 25
`)
	if err := os.WriteFile(overlayPath, []byte(overlay), 0o644); err != nil {
		t.Fatalf("write overlay: %v", err)
	}
	cfg, err := LoadWithOverlay(basePath, overlayPath)
	if err != nil {
		t.Fatalf("LoadWithOverlay: %v", err)
	}
	if cfg.MalibuEmission.Enabled {
		t.Fatal("malibu overlay should keep enabled false for C4 staging")
	}
	if cfg.MalibuEmission.WriterDSN != "postgres://rewards_writer:pw@127.0.0.1:5432/stats?sslmode=disable" {
		t.Fatalf("writer_dsn=%q", cfg.MalibuEmission.WriterDSN)
	}
	if cfg.MalibuEmission.ProviderDailyCapMALIBU != 25 {
		t.Fatalf("provider cap=%v", cfg.MalibuEmission.ProviderDailyCapMALIBU)
	}
}
