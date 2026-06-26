package config

import (
	"strings"
	"testing"
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
		cfg.Rewards.RateCard["default"].CompletionCreditsPerMtok != 1000000 {
		t.Fatalf("unexpected default rate card: %+v", cfg.Rewards.RateCard["default"])
	}
	if cfg.Settlement.CadenceDays != 7 || cfg.Settlement.MinPayoutCredits != 500000 ||
		cfg.Settlement.StartupReconcileWindowHours != 24 || cfg.Settlement.NightlyReconcileWindowDays != 7 ||
		cfg.Settlement.RecoveryGraceSeconds != 30 || !cfg.Settlement.JobEnabled {
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
