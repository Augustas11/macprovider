package config

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"gopkg.in/yaml.v3"
)

const testAutotunePublicKeyBase64 = "zTKDIdMmKKkO1Cgf5OdTzMOytVqW7U8SGsJ9XrzAltU="

func validTestConfig() Config {
	cfg := Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Auth.GatewayServiceToken = "gateway-service-token"
	return cfg
}

func enableReferralAdmissionForTest(cfg *Config) {
	cfg.Referrals.RequireForRegistration = true
	cfg.Referrals.Campaign = "prebeta_2026"
	cfg.Referrals.CurrentKeyID = "k1"
	cfg.Referrals.HMACKeys = map[string]string{"k1": strings.Repeat("s", 32)}
}

func TestAutotuneFeedsRequirePublicKeyringWhenConfigured(t *testing.T) {
	cfg := validTestConfig()
	setSignedAutotuneFeedPathsForTest(&cfg)

	err := cfg.Validate()
	if err == nil || !strings.Contains(err.Error(), "autotune.public_keys") {
		t.Fatalf("Validate error=%v, want public keyring requirement", err)
	}

	cfg.AutotuneFeeds.PublicKeys = map[string]string{
		"streamvc-autotune-static-v4": testAutotunePublicKeyBase64,
	}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("Validate configured signed feed: %v", err)
	}
}

func TestAutotuneFeedsRejectPartialFeedSet(t *testing.T) {
	cfg := validTestConfig()
	cfg.AutotuneFeeds.AutotuneCandidatesPath = "/tmp/autotune-candidates.json"
	cfg.AutotuneFeeds.AutotuneCandidatesSigPath = "/tmp/autotune-candidates.json.sig"
	cfg.AutotuneFeeds.PublicKeys = map[string]string{
		"streamvc-autotune-static-v4": testAutotunePublicKeyBase64,
	}

	err := cfg.Validate()
	if err == nil || !strings.Contains(err.Error(), "required when any autotune feed is configured") {
		t.Fatalf("Validate error=%v, want partial feed-set rejection", err)
	}
}

func setSignedAutotuneFeedPathsForTest(cfg *Config) {
	cfg.AutotuneFeeds.RateCardPath = "/tmp/rate-card.json"
	cfg.AutotuneFeeds.RateCardSigPath = "/tmp/rate-card.json.sig"
	cfg.AutotuneFeeds.DemandRankPath = "/tmp/demand-rank.json"
	cfg.AutotuneFeeds.DemandRankSigPath = "/tmp/demand-rank.json.sig"
	cfg.AutotuneFeeds.AutotuneCandidatesPath = "/tmp/autotune-candidates.json"
	cfg.AutotuneFeeds.AutotuneCandidatesSigPath = "/tmp/autotune-candidates.json.sig"
}

func TestAdmissionTrustedQuotaDefaultUnlimitedAndRejectsNegative(t *testing.T) {
	cfg := validTestConfig()
	if cfg.Admission.TrustedQuotaPerHour != 0 {
		t.Fatalf("trusted quota default = %d, want 0 unlimited", cfg.Admission.TrustedQuotaPerHour)
	}
	cfg.Admission.TrustedQuotaPerHour = -1
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "trusted_quota_per_hour") {
		t.Fatalf("Validate error=%v, want trusted quota rejection", err)
	}
}

func TestReferralLaunchPolicyDefaultsOffAndRejectsUnsafeEnablement(t *testing.T) {
	cfg := validTestConfig()
	if cfg.Referrals.RequireForRegistration || cfg.Referrals.EnablePublicValidation || cfg.Referrals.EnableJoinLinks || cfg.Referrals.EnableSocialInviteBonus {
		t.Fatal("referral launch policy must default off")
	}
	if cfg.Referrals.JoinBaseURL != "https://malibu.tech/j" {
		t.Fatalf("default join_base_url=%q, want canonical public origin", cfg.Referrals.JoinBaseURL)
	}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("disabled referral defaults should validate: %v", err)
	}

	cfg.Referrals.RequireForRegistration = true
	cfg.Referrals.Campaign = "prebeta_2026"
	cfg.Referrals.CurrentKeyID = "k1"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "hmac_keys") {
		t.Fatalf("unsafe enablement error=%v", err)
	}
	cfg.Referrals.HMACKeys = map[string]string{"k1": strings.Repeat("s", 32)}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("valid referral gate: %v", err)
	}
}

func TestFreshRegistrationMintSurfacesRequireReferralAdmission(t *testing.T) {
	cfg := validTestConfig()
	cfg.Auth.AllowTokenlessProvisionalBootstrap = true
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "fresh provider registration mint surfaces") {
		t.Fatalf("tokenless bootstrap without referral gate err=%v", err)
	}
	enableReferralAdmissionForTest(&cfg)
	if err := cfg.Validate(); err != nil {
		t.Fatalf("tokenless bootstrap with referral gate: %v", err)
	}

	cfg = validTestConfig()
	cfg.Onboarding.AppTrackRegisterEnabled = true
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "fresh provider registration mint surfaces") {
		t.Fatalf("app-track register without referral gate err=%v", err)
	}
}

func TestReferralJoinLinksRequireAdmissionAndPublicValidation(t *testing.T) {
	cfg := validTestConfig()
	cfg.Referrals.EnableJoinLinks = true
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "requires require_for_registration") {
		t.Fatalf("join without admission error=%v", err)
	}

	cfg.Referrals.RequireForRegistration = true
	cfg.Referrals.Campaign = "prebeta_2026"
	cfg.Referrals.CurrentKeyID = "k1"
	cfg.Referrals.HMACKeys = map[string]string{"k1": strings.Repeat("s", 32)}
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "requires enable_public_validation") {
		t.Fatalf("join without public validation error=%v", err)
	}
	cfg.Referrals.EnablePublicValidation = true
	if err := cfg.Validate(); err != nil {
		t.Fatalf("join with admission and public validation: %v", err)
	}
}

func TestReferralSocialBonusRequiresDarkStackAndConfiguredDwell(t *testing.T) {
	cfg := validTestConfig()
	cfg.Referrals.EnableSocialInviteBonus = true
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "requires referral admission, public validation, and join links") {
		t.Fatalf("social without server stack error=%v", err)
	}

	cfg.Referrals.RequireForRegistration = true
	cfg.Referrals.EnableJoinLinks = true
	cfg.Referrals.EnablePublicValidation = true
	cfg.Referrals.Campaign = "prebeta_2026"
	cfg.Referrals.CurrentKeyID = "k1"
	cfg.Referrals.HMACKeys = map[string]string{"k1": strings.Repeat("s", 32)}
	cfg.Referrals.XAPIBearerToken = "secret"
	cfg.Referrals.SocialBonusUses = 2
	cfg.Referrals.ChallengeTTLS = 900
	cfg.Referrals.SocialVerificationDwellS = 0
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "social_verification_dwell_s") {
		t.Fatalf("social without dwell error=%v", err)
	}
	cfg.Referrals.SocialVerificationDwellS = 1800
	if err := cfg.Validate(); err != nil {
		t.Fatalf("valid dark social stack: %v", err)
	}

	cfg.Referrals.JoinBaseURL = "https://user:secret@malibu.tech/j"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "exactly https://malibu.tech/j") {
		t.Fatalf("noncanonical join URL error=%v", err)
	}

	for _, raw := range []string{
		"https://evil.test/j",
		"https://malibu.tech:443/j",
		"https://MALIBU.tech/j",
		"https://malibu.tech/j/",
		"https://malibu.tech/other/j",
	} {
		cfg.Referrals.JoinBaseURL = raw
		if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "exactly https://malibu.tech/j") {
			t.Fatalf("join_base_url=%q error=%v", raw, err)
		}
	}
}

func TestReferralRequestAccessURLMustBeCredentialFreeHTTPSEvenWhenGateIsOff(t *testing.T) {
	for _, raw := range []string{
		"http://access.example.test/waitlist",
		"/relative-access",
		"https://user:secret@access.example.test/waitlist",
		"https://access.example.test:443/waitlist",
		"https://access.example.test/waitlist#invite",
		"https://ACCESS.example.test/waitlist",
		"https://access.example.test",
	} {
		cfg := validTestConfig()
		cfg.Referrals.RequestAccessURL = raw
		if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "request_access_url") {
			t.Fatalf("request_access_url=%q error=%v", raw, err)
		}
	}

	cfg := validTestConfig()
	cfg.Referrals.RequestAccessURL = "https://access.example.test/waitlist?campaign=prebeta"
	if err := cfg.Validate(); err != nil {
		t.Fatalf("valid request access URL: %v", err)
	}
}

func TestAutotuneFeedsRejectInvalidPublicKeys(t *testing.T) {
	tests := []struct {
		name    string
		keyID   string
		encoded string
		want    string
	}{
		{name: "invalid base64", keyID: "test-key", encoded: "not-base64", want: "canonical padded base64"},
		{name: "wrong key length", keyID: "test-key", encoded: base64.StdEncoding.EncodeToString(make([]byte, 31)), want: "decode to 32 bytes"},
		{name: "noncanonical base64", keyID: "test-key", encoded: strings.TrimSuffix(testAutotunePublicKeyBase64, "="), want: "canonical padded base64"},
		{name: "whitespace key ID", keyID: " test-key", encoded: testAutotunePublicKeyBase64, want: "invalid key ID"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cfg := validTestConfig()
			cfg.AutotuneFeeds.PublicKeys = map[string]string{tc.keyID: tc.encoded}
			err := cfg.Validate()
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("Validate error=%v, want %q", err, tc.want)
			}
		})
	}
}

func TestAutotuneProviderAdmissionEnforcementDefaultsStrictAndParsesExplicitly(t *testing.T) {
	cfg := Default()
	if !cfg.AutotuneFeeds.EnforceProviderAdmission {
		t.Fatal("autotune.enforce_provider_admission should default to true")
	}

	var parsed Config
	if err := yaml.Unmarshal([]byte("autotune:\n  enforce_provider_admission: false\n  provider_admission_bridge_deadline: \"2026-07-12T00:00:00Z\"\n"), &parsed); err != nil {
		t.Fatalf("unmarshal enforcement flag: %v", err)
	}
	if parsed.AutotuneFeeds.EnforceProviderAdmission {
		t.Fatal("autotune.enforce_provider_admission=false was not parsed")
	}
	if parsed.AutotuneFeeds.ProviderAdmissionBridgeDeadline != "2026-07-12T00:00:00Z" {
		t.Fatalf("bridge deadline = %q", parsed.AutotuneFeeds.ProviderAdmissionBridgeDeadline)
	}
}

func TestAutotuneProviderAdmissionBridgeDeadlineValidation(t *testing.T) {
	now := time.Now().UTC()
	tests := []struct {
		name     string
		deadline string
		want     string
	}{
		{name: "missing", want: "is required"},
		{name: "malformed", deadline: "tomorrow", want: "must be RFC3339"},
		{name: "past", deadline: now.Add(-time.Minute).Format(time.RFC3339), want: "must be in the future"},
		{name: "over 24 hours", deadline: now.Add(25 * time.Hour).Format(time.RFC3339), want: "no more than 24 hours"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cfg := validTestConfig()
			cfg.AutotuneFeeds.EnforceProviderAdmission = false
			cfg.AutotuneFeeds.ProviderAdmissionBridgeDeadline = tc.deadline
			if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("Validate error=%v, want %q", err, tc.want)
			}
		})
	}

	cfg := validTestConfig()
	cfg.AutotuneFeeds.EnforceProviderAdmission = false
	cfg.AutotuneFeeds.ProviderAdmissionBridgeDeadline = now.Add(time.Hour).Format(time.RFC3339)
	if err := cfg.Validate(); err != nil {
		t.Fatalf("Validate bounded bridge: %v", err)
	}
	deadline, err := cfg.AutotuneFeeds.ProviderAdmissionBridgeDeadlineTime()
	if err != nil {
		t.Fatalf("parse bridge deadline: %v", err)
	}
	if deadline.IsZero() || !deadline.After(now) {
		t.Fatalf("parsed bridge deadline = %v", deadline)
	}
}

func TestModelClassRejectsMembersAndModelsTogether(t *testing.T) {
	cfg := validTestConfig()
	cfg.Routing.ModelClasses = map[string]ModelClassConfig{
		"alias": {Members: []string{"model-a"}, Models: []string{"model-b"}, Objective: "fast"},
	}

	err := cfg.Validate()
	if err == nil || !strings.Contains(err.Error(), "must not set both members and models") {
		t.Fatalf("Validate error=%v", err)
	}
}

// TestValidateRejectsWhitespaceEquivalentServiceToken pins the audit-r2
// fix for the whitespace-bypass MEDIUM: auth.BearerTokenMatchesHeader
// trims both sides before matching, so "X" and "X " or "X\n" collapse
// to the same value on the wire. Validate must reject that collision
// instead of relying on a strict == that misses it.
func TestValidateRejectsWhitespaceEquivalentServiceToken(t *testing.T) {
	for _, tc := range []struct {
		name    string
		op, svc string
	}{
		{"trailing space", "operator-key", "operator-key "},
		{"leading space", "operator-key", " operator-key"},
		{"trailing newline", "operator-key", "operator-key\n"},
		{"both padded", "  operator-key", "operator-key  "},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := Default()
			cfg.Auth.OperatorKey = tc.op
			cfg.Auth.GatewayServiceToken = tc.svc
			err := cfg.Validate()
			if err == nil || !strings.Contains(err.Error(), "must differ from auth.operator_key") {
				t.Fatalf("Validate err=%v want distinctness rejection", err)
			}
		})
	}
}

func TestValidateRejectsBlankServiceToken(t *testing.T) {
	cfg := Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Auth.GatewayServiceToken = " \t\n "
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "gateway_service_token must be set") {
		t.Fatalf("Validate err=%v want blank-token rejection", err)
	}
}

func TestValidateRejectsServiceTokenMatchingNamedOperatorKey(t *testing.T) {
	cfg := validTestConfig()
	cfg.Auth.OperatorKeys = map[string]string{"alice": " gateway-service-token "}
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "auth.operator_keys.alice") {
		t.Fatalf("Validate err=%v want named-operator collision rejection", err)
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
	if cfg.Auth.CredentialBootstrapMintsGlobalHour != 128 || cfg.Auth.CredentialBootstrapUnconfirmedMax != 64 {
		t.Fatalf("credential bootstrap global defaults = %d/%d, want 128/64",
			cfg.Auth.CredentialBootstrapMintsGlobalHour, cfg.Auth.CredentialBootstrapUnconfirmedMax)
	}
	if cfg.Auth.CredentialBootstrapIdentityRetentionS != 7*24*60*60 {
		t.Fatalf("credential bootstrap identity retention=%d want seven days", cfg.Auth.CredentialBootstrapIdentityRetentionS)
	}
}

func TestCredentialBootstrapIdentityRetentionMustExceedTokenTTL(t *testing.T) {
	cfg := validTestConfig()
	cfg.Auth.CredentialBootstrapIdentityRetentionS = cfg.Auth.CredentialBootstrapTokenTTLS
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "identity_retention_s must exceed") {
		t.Fatalf("Validate error=%v", err)
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
			_, err := loadConfigFromYAML(t, "auth:\n  operator_key: "+tc.key+"\n  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA\n")
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
  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA
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
  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA
  operator_keys:
    alice: `+tc.key+`
    bob: ZXCVbnm1234567890qwertyASDFGHJKL
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
	cfg := validTestConfig()
	cfg.Pool.CanaryEnabled = true
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "canary_challenges") {
		t.Fatalf("enabled canary without challenges validation err=%v", err)
	}

	cfg.Pool.ModelClassChallenges = map[string][]CanaryChallengeConfig{
		"model-a": {{
			Prompt:   "Reply with exactly: CANARY-{nonce}",
			Expected: "CANARY-{nonce}",
		}},
	}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("enabled canary with model_class_challenges only should validate: %v", err)
	}
	cfg.Pool.ModelClassChallenges = nil

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

func TestCanaryColdStartGraceValidation(t *testing.T) {
	cfg := validTestConfig()
	cfg.Pool.CanaryColdStartGraceS = -1
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "canary_cold_start_grace_s") {
		t.Fatalf("negative cold-start grace validation err=%v", err)
	}
	cfg.Pool.CanaryColdStartGraceS = 300
	if err := cfg.Validate(); err != nil {
		t.Fatalf("valid cold-start grace should validate: %v", err)
	}
	cfg.Pool.CanaryColdStartGraceS = 0
	if err := cfg.Validate(); err != nil {
		t.Fatalf("zero cold-start grace (disabled) should validate: %v", err)
	}
}

func TestCanaryLatencyEnforcementValidation(t *testing.T) {
	cfg := validTestConfig()

	// Default (empty) normalizes to observe and validates.
	if cfg.Pool.CanaryLatencyEnforcement != "" {
		t.Fatalf("default canary_latency_enforcement should be empty, got %q", cfg.Pool.CanaryLatencyEnforcement)
	}
	if cfg.Pool.CanaryLatencyMode() != "observe" || cfg.Pool.CanaryLatencyEnforced() {
		t.Fatalf("empty enforcement must normalize to observe (not enforced)")
	}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("empty enforcement should validate: %v", err)
	}
	for _, mode := range []string{"observe", "enforce", "ENFORCE", "Observe"} {
		cfg.Pool.CanaryLatencyEnforcement = mode
		if err := cfg.Validate(); err != nil {
			t.Fatalf("mode %q should validate: %v", mode, err)
		}
	}
	if cfg.Pool.CanaryLatencyEnforcement = "enforce"; !cfg.Pool.CanaryLatencyEnforced() {
		t.Fatal("enforce mode must report enforced")
	}
	cfg.Pool.CanaryLatencyEnforcement = "sanction"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "canary_latency_enforcement") {
		t.Fatalf("invalid enforcement should fail validation, got %v", err)
	}
}

func TestProviderWebSocketBoundsDefaultAndValidate(t *testing.T) {
	cfg := validTestConfig()
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

	cfg = validTestConfig()
	cfg.WS.MaxFrameBytes = 65 << 20
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "max_frame_bytes") {
		t.Fatalf("oversize frame cap validation err=%v", err)
	}
}

func TestSpec005BillingDefaultsAndValidation(t *testing.T) {
	cfg := validTestConfig()
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
		cfg.Settlement.RecoveryGraceSeconds != 30 || cfg.Settlement.PendingDeadlineSeconds != 300 ||
		cfg.Settlement.VerifiedModelSettlementMode != "observe" || !cfg.Settlement.JobEnabled {
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

	cfg = validTestConfig()
	cfg.Settlement.RecoveryGraceSeconds = 901
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "recovery_grace_seconds") {
		t.Fatalf("settlement recovery grace above verified receipt cap should fail; err=%v", err)
	}

	cfg = validTestConfig()
	cfg.Settlement.PendingDeadlineSeconds = 0
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "pending_deadline_seconds") {
		t.Fatalf("settlement pending deadline below floor should fail; err=%v", err)
	}

	cfg = validTestConfig()
	cfg.Settlement.PendingDeadlineSeconds = 901
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "pending_deadline_seconds") {
		t.Fatalf("settlement pending deadline above cap should fail; err=%v", err)
	}

	cfg = validTestConfig()
	cfg.Settlement.VerifiedModelSettlementMode = "shadow"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "verified_model_settlement_mode") {
		t.Fatalf("settlement verified model mode validation err=%v", err)
	}

	cfg = validTestConfig()
	cfg.Storage.RequestLogRetentionDays = 0
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "request_log_retention_days") {
		t.Fatalf("request log retention validation err=%v", err)
	}

	cfg = validTestConfig()
	cfg.Storage.AuditLogRetentionDays = 0
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "audit_log_retention_days") {
		t.Fatalf("audit log retention=0 validation err=%v", err)
	}

	cfg = validTestConfig()
	cfg.Storage.AuditLogRetentionDays = 89
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "compliance floor") {
		t.Fatalf("audit log retention=89 (below 90-day floor) should fail; err=%v", err)
	}

	cfg = validTestConfig()
	cfg.Storage.AuditLogRetentionDays = 90
	if err := cfg.Validate(); err != nil {
		t.Fatalf("audit log retention=90 should pass validation: %v", err)
	}

	cfg = validTestConfig()
	cfg.Storage.RequestLogRetentionDays = 3
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "nightly_reconcile_window_days") {
		t.Fatalf("request log retention reconcile validation err=%v", err)
	}

	cfg = validTestConfig()
	delete(cfg.Rewards.RateCard, "default")
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "rate_card") {
		t.Fatalf("default rate-card validation err=%v", err)
	}

	cfg = validTestConfig()
	cfg.Rewards.RateCard["default"] = RateCardEntry{
		PromptCreditsPerMtok:         500000,
		PromptCacheHitCreditsPerMtok: 600000,
		CompletionCreditsPerMtok:     1000000,
	}
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "prompt_cache_hit_credits_per_mtok") {
		t.Fatalf("cache rate above prompt validation err=%v", err)
	}
}

func TestTrustedPoolsEnabledRequiresGatewayContext(t *testing.T) {
	cfg := validTestConfig()
	cfg.TrustedPools.Enabled = true
	cfg.Coordinator.RequireGatewayContext = false
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "trusted_pools.enabled") {
		t.Fatalf("trusted pools without gateway context validation err=%v", err)
	}

	cfg.Coordinator.RequireGatewayContext = true
	if err := cfg.Validate(); err != nil {
		t.Fatalf("trusted pools with gateway context should validate: %v", err)
	}
}

func TestTrustedPoolsEnabledRequiresBoundedRefreshInterval(t *testing.T) {
	for _, interval := range []int{0, 61} {
		cfg := validTestConfig()
		cfg.TrustedPools.Enabled = true
		cfg.TrustedPools.RefreshIntervalS = interval
		if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "trusted_pools.refresh_interval_s") {
			t.Fatalf("trusted pools refresh interval %d validation err=%v", interval, err)
		}
	}

	cfg := validTestConfig()
	cfg.TrustedPools.Enabled = true
	cfg.TrustedPools.RefreshIntervalS = 60
	if err := cfg.Validate(); err != nil {
		t.Fatalf("trusted pools refresh interval 60 should validate: %v", err)
	}
}

func TestTrustedPoolsCreatorAdminCredentialsRequireEnabledTrustedPools(t *testing.T) {
	cfg := validTestConfig()
	cfg.TrustedPools.CreatorAdminCredentials = []TrustedPoolsCreatorAdminCredentialConfig{trustedPoolsCreatorCredentialConfig("creator-a", "creator-a-cred", "creator-token-a")}
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "creator_admin_credentials requires trusted_pools.enabled=true") {
		t.Fatalf("Validate err=%v, want creator admin credential enablement rejection", err)
	}

	cfg.TrustedPools.Enabled = true
	cfg.Coordinator.RequireGatewayContext = true
	cfg.TrustedPools.CreatorAdminProviderIDs = map[string][]string{"creator-a": {"provider-a"}}
	cfg.TrustedPools.CreatorAdminProviderDelegatedIDs = map[string][]string{"creator-a": {"provider-a"}}
	cfg.TrustedPools.CreatorAdminBuyerAccountIDs = map[string][]string{"creator-a": {"acct-a"}}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("creator admin credentials with trusted pools enabled should validate: %v", err)
	}
}

func TestTrustedPoolsCreatorAdminCredentialsRejectInvalidCredential(t *testing.T) {
	tests := []struct {
		name  string
		build func(*Config)
		want  string
	}{
		{
			name: "operator key",
			build: func(cfg *Config) {
				cfg.TrustedPools.CreatorAdminCredentials = []TrustedPoolsCreatorAdminCredentialConfig{trustedPoolsCreatorCredentialConfig("creator-a", "creator-a-cred", " operator-key ")}
			},
			want: "auth.operator_key",
		},
		{
			name: "gateway service token",
			build: func(cfg *Config) {
				cfg.TrustedPools.CreatorAdminCredentials = []TrustedPoolsCreatorAdminCredentialConfig{trustedPoolsCreatorCredentialConfig("creator-a", "creator-a-cred", "gateway-service-token")}
			},
			want: "auth.gateway_service_token",
		},
		{
			name: "named operator key",
			build: func(cfg *Config) {
				cfg.Auth.OperatorKeys = map[string]string{"alice": "named-operator-secret"}
				cfg.TrustedPools.CreatorAdminCredentials = []TrustedPoolsCreatorAdminCredentialConfig{trustedPoolsCreatorCredentialConfig("creator-a", "creator-a-cred", "named-operator-secret")}
			},
			want: "auth.operator_keys.alice",
		},
		{
			name: "duplicate creator credential token",
			build: func(cfg *Config) {
				cfg.TrustedPools.CreatorAdminCredentials = []TrustedPoolsCreatorAdminCredentialConfig{
					trustedPoolsCreatorCredentialConfig("creator-a", "creator-a-cred", "shared-creator-token"),
					trustedPoolsCreatorCredentialConfig("creator-b", "creator-b-cred", "shared-creator-token"),
				}
				cfg.TrustedPools.CreatorAdminProviderIDs["creator-b"] = []string{"provider-b"}
				cfg.TrustedPools.CreatorAdminProviderDelegatedIDs["creator-b"] = []string{"provider-b"}
				cfg.TrustedPools.CreatorAdminBuyerAccountIDs["creator-b"] = []string{"acct-b"}
			},
			want: "must not reuse secret",
		},
		{
			name: "slash creator id",
			build: func(cfg *Config) {
				cfg.TrustedPools.CreatorAdminCredentials = []TrustedPoolsCreatorAdminCredentialConfig{trustedPoolsCreatorCredentialConfig("creator/a", "creator-a-cred", "creator-token-a")}
			},
			want: "invalid creator id",
		},
		{
			name: "non-canonical creator id",
			build: func(cfg *Config) {
				cfg.TrustedPools.CreatorAdminCredentials = []TrustedPoolsCreatorAdminCredentialConfig{trustedPoolsCreatorCredentialConfig(" creator-a ", "creator-a-cred", "creator-token-a")}
			},
			want: "creator_account_id must be canonical",
		},
		{
			name: "slash credential id",
			build: func(cfg *Config) {
				cfg.TrustedPools.CreatorAdminCredentials = []TrustedPoolsCreatorAdminCredentialConfig{trustedPoolsCreatorCredentialConfig("creator-a", "credential/a", "creator-token-a")}
			},
			want: "invalid credential id",
		},
		{
			name: "expires before not before",
			build: func(cfg *Config) {
				credential := trustedPoolsCreatorCredentialConfig("creator-a", "creator-a-cred", "creator-token-a")
				credential.ExpiresAtUTC = "2026-01-01T00:00:00Z"
				credential.NotBeforeUTC = "2026-01-02T00:00:00Z"
				cfg.TrustedPools.CreatorAdminCredentials = []TrustedPoolsCreatorAdminCredentialConfig{credential}
			},
			want: "expires_at_utc must be after not_before_utc",
		},
		{
			name: "invalid status",
			build: func(cfg *Config) {
				credential := trustedPoolsCreatorCredentialConfig("creator-a", "creator-a-cred", "creator-token-a")
				credential.Status = "pending"
				cfg.TrustedPools.CreatorAdminCredentials = []TrustedPoolsCreatorAdminCredentialConfig{credential}
			},
			want: "status must be enabled or disabled",
		},
	}
	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			cfg := validTestConfig()
			cfg.TrustedPools.Enabled = true
			cfg.Coordinator.RequireGatewayContext = true
			cfg.TrustedPools.CreatorAdminCredentials = []TrustedPoolsCreatorAdminCredentialConfig{trustedPoolsCreatorCredentialConfig("creator-a", "creator-a-cred", "creator-token-a")}
			cfg.TrustedPools.CreatorAdminProviderIDs = map[string][]string{"creator-a": {"provider-a"}}
			cfg.TrustedPools.CreatorAdminProviderDelegatedIDs = map[string][]string{"creator-a": {"provider-a"}}
			cfg.TrustedPools.CreatorAdminBuyerAccountIDs = map[string][]string{"creator-a": {"acct-a"}}
			tc.build(&cfg)
			if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("Validate err=%v, want substring %q", err, tc.want)
			}
		})
	}
}

func TestLoadRejectsWeakTrustedPoolsCreatorAdminCredentialToken(t *testing.T) {
	yaml := `
auth:
  operator_key: 0123456789abcdefABCDEFghijklmnop
  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA
coordinator:
  require_gateway_context: true
trusted_pools:
  enabled: true
  creator_admin_credentials:
    - creator_account_id: creator-a
      credential_id: creator-a-cred
      token: changeme
      not_before_utc: 2026-01-01T00:00:00Z
      expires_at_utc: 2027-01-01T00:00:00Z
      status: enabled
  creator_admin_provider_ids:
    creator-a: [provider-a]
  creator_admin_provider_delegated_ids:
    creator-a: [provider-a]
  creator_admin_buyer_account_ids:
    creator-a: [acct-a]
`
	_, err := loadConfigFromYAML(t, yaml)
	if err == nil || !strings.Contains(err.Error(), "trusted_pools.creator_admin_credentials[0].token") || !strings.Contains(err.Error(), "placeholder_denied") {
		t.Fatalf("Load error=%v, want weak creator credential token rejection", err)
	}
}

func TestTrustedPoolsCreatorAdminProviderIDsValidateCreatorAndProviders(t *testing.T) {
	tests := []struct {
		name  string
		build func(*Config)
		want  string
	}{
		{
			name: "credential without provider allowlist",
			build: func(cfg *Config) {
				cfg.TrustedPools.CreatorAdminProviderIDs = map[string][]string{}
			},
			want: "must be configured for every trusted_pools.creator_admin_credentials entry",
		},
		{
			name: "disabled trusted pools",
			build: func(cfg *Config) {
				cfg.TrustedPools.Enabled = false
				cfg.TrustedPools.CreatorAdminCredentials = nil
				cfg.TrustedPools.CreatorAdminProviderIDs = map[string][]string{"creator-a": {"provider-a"}}
				cfg.TrustedPools.CreatorAdminBuyerAccountIDs = nil
			},
			want: "creator_admin_provider_ids requires trusted_pools.enabled=true",
		},
		{
			name: "missing creator credential",
			build: func(cfg *Config) {
				cfg.TrustedPools.CreatorAdminCredentials = nil
				cfg.TrustedPools.CreatorAdminProviderIDs = map[string][]string{"creator-b": {"provider-a"}}
				cfg.TrustedPools.CreatorAdminBuyerAccountIDs = nil
			},
			want: "requires matching trusted_pools.creator_admin_credentials entry",
		},
		{
			name: "non-canonical provider-map creator id",
			build: func(cfg *Config) {
				cfg.TrustedPools.CreatorAdminProviderIDs = map[string][]string{
					"creator-a":   {"provider-a"},
					" creator-a ": {"provider-b"},
				}
			},
			want: "non-canonical creator id",
		},
		{
			name: "invalid provider id",
			build: func(cfg *Config) {
				cfg.TrustedPools.CreatorAdminProviderIDs = map[string][]string{"creator-a": {"bad/provider"}}
			},
			want: "invalid provider_id",
		},
		{
			name: "non-canonical provider id",
			build: func(cfg *Config) {
				cfg.TrustedPools.CreatorAdminProviderIDs = map[string][]string{"creator-a": {" provider-a "}}
			},
			want: "non-canonical provider_id",
		},
		{
			name: "duplicate provider id",
			build: func(cfg *Config) {
				cfg.TrustedPools.CreatorAdminProviderIDs = map[string][]string{"creator-a": {"provider-a", "provider-a"}}
			},
			want: "unique provider ids",
		},
	}
	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			cfg := validTestConfig()
			cfg.TrustedPools.Enabled = true
			cfg.Coordinator.RequireGatewayContext = true
			cfg.TrustedPools.CreatorAdminCredentials = []TrustedPoolsCreatorAdminCredentialConfig{trustedPoolsCreatorCredentialConfig("creator-a", "creator-a-cred", "creator-token-a")}
			cfg.TrustedPools.CreatorAdminProviderIDs = map[string][]string{"creator-a": {"provider-a"}}
			cfg.TrustedPools.CreatorAdminProviderDelegatedIDs = map[string][]string{"creator-a": {"provider-a"}}
			cfg.TrustedPools.CreatorAdminBuyerAccountIDs = map[string][]string{"creator-a": {"acct-a"}}
			tc.build(&cfg)
			if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("Validate err=%v, want substring %q", err, tc.want)
			}
		})
	}
}

func TestTrustedPoolsCreatorAdminProviderDelegatedIDsValidateCreatorAndProviders(t *testing.T) {
	tests := []struct {
		name  string
		build func(*Config)
		want  string
	}{
		{
			name: "credential without provider delegation projection",
			build: func(cfg *Config) {
				cfg.TrustedPools.CreatorAdminProviderDelegatedIDs = map[string][]string{}
			},
			want: "must be configured for every trusted_pools.creator_admin_credentials entry",
		},
		{
			name: "disabled trusted pools",
			build: func(cfg *Config) {
				cfg.TrustedPools.Enabled = false
				cfg.TrustedPools.CreatorAdminCredentials = nil
				cfg.TrustedPools.CreatorAdminProviderIDs = nil
				cfg.TrustedPools.CreatorAdminProviderDelegatedIDs = map[string][]string{"creator-a": {"provider-a"}}
				cfg.TrustedPools.CreatorAdminBuyerAccountIDs = nil
			},
			want: "creator_admin_provider_delegated_ids requires trusted_pools.enabled=true",
		},
		{
			name: "missing creator credential",
			build: func(cfg *Config) {
				cfg.TrustedPools.CreatorAdminCredentials = nil
				cfg.TrustedPools.CreatorAdminProviderIDs = nil
				cfg.TrustedPools.CreatorAdminProviderDelegatedIDs = map[string][]string{"creator-b": {"provider-a"}}
				cfg.TrustedPools.CreatorAdminBuyerAccountIDs = nil
			},
			want: "requires matching trusted_pools.creator_admin_credentials entry",
		},
		{
			name: "invalid provider id",
			build: func(cfg *Config) {
				cfg.TrustedPools.CreatorAdminProviderDelegatedIDs = map[string][]string{"creator-a": {"bad/provider"}}
			},
			want: "invalid provider_id",
		},
		{
			name: "non-canonical provider id",
			build: func(cfg *Config) {
				cfg.TrustedPools.CreatorAdminProviderDelegatedIDs = map[string][]string{"creator-a": {" provider-a "}}
			},
			want: "non-canonical provider_id",
		},
		{
			name: "duplicate provider id",
			build: func(cfg *Config) {
				cfg.TrustedPools.CreatorAdminProviderDelegatedIDs = map[string][]string{"creator-a": {"provider-a", "provider-a"}}
			},
			want: "unique provider ids",
		},
	}
	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			cfg := validTestConfig()
			cfg.TrustedPools.Enabled = true
			cfg.Coordinator.RequireGatewayContext = true
			cfg.TrustedPools.CreatorAdminCredentials = []TrustedPoolsCreatorAdminCredentialConfig{trustedPoolsCreatorCredentialConfig("creator-a", "creator-a-cred", "creator-token-a")}
			cfg.TrustedPools.CreatorAdminProviderIDs = map[string][]string{"creator-a": {"provider-a"}}
			cfg.TrustedPools.CreatorAdminProviderDelegatedIDs = map[string][]string{"creator-a": {"provider-a"}}
			cfg.TrustedPools.CreatorAdminBuyerAccountIDs = map[string][]string{"creator-a": {"acct-a"}}
			tc.build(&cfg)
			if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("Validate err=%v, want substring %q", err, tc.want)
			}
		})
	}
}

func TestTrustedPoolsCreatorAdminBuyerAccountIDsValidateCreatorAndBuyers(t *testing.T) {
	tests := []struct {
		name  string
		build func(*Config)
		want  string
	}{
		{
			name: "credential without buyer allowlist",
			build: func(cfg *Config) {
				cfg.TrustedPools.CreatorAdminBuyerAccountIDs = map[string][]string{}
			},
			want: "must be configured for every trusted_pools.creator_admin_credentials entry",
		},
		{
			name: "disabled trusted pools",
			build: func(cfg *Config) {
				cfg.TrustedPools.Enabled = false
				cfg.TrustedPools.CreatorAdminCredentials = nil
				cfg.TrustedPools.CreatorAdminProviderIDs = nil
				cfg.TrustedPools.CreatorAdminProviderDelegatedIDs = nil
				cfg.TrustedPools.CreatorAdminBuyerAccountIDs = map[string][]string{"creator-a": {"acct-a"}}
			},
			want: "creator_admin_buyer_account_ids requires trusted_pools.enabled=true",
		},
		{
			name: "missing creator credential",
			build: func(cfg *Config) {
				cfg.TrustedPools.CreatorAdminCredentials = nil
				cfg.TrustedPools.CreatorAdminProviderIDs = nil
				cfg.TrustedPools.CreatorAdminProviderDelegatedIDs = nil
				cfg.TrustedPools.CreatorAdminBuyerAccountIDs = map[string][]string{"creator-b": {"acct-a"}}
			},
			want: "requires matching trusted_pools.creator_admin_credentials entry",
		},
		{
			name: "non-canonical buyer-map creator id",
			build: func(cfg *Config) {
				cfg.TrustedPools.CreatorAdminBuyerAccountIDs = map[string][]string{
					"creator-a":   {"acct-a"},
					" creator-a ": {"acct-b"},
				}
			},
			want: "non-canonical creator id",
		},
		{
			name: "empty buyer account id",
			build: func(cfg *Config) {
				cfg.TrustedPools.CreatorAdminBuyerAccountIDs = map[string][]string{"creator-a": {""}}
			},
			want: "empty buyer account id",
		},
		{
			name: "duplicate buyer account id",
			build: func(cfg *Config) {
				cfg.TrustedPools.CreatorAdminBuyerAccountIDs = map[string][]string{"creator-a": {"acct-a", "acct-a"}}
			},
			want: "unique buyer account ids",
		},
	}
	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			cfg := validTestConfig()
			cfg.TrustedPools.Enabled = true
			cfg.Coordinator.RequireGatewayContext = true
			cfg.TrustedPools.CreatorAdminCredentials = []TrustedPoolsCreatorAdminCredentialConfig{trustedPoolsCreatorCredentialConfig("creator-a", "creator-a-cred", "creator-token-a")}
			cfg.TrustedPools.CreatorAdminProviderIDs = map[string][]string{"creator-a": {"provider-a"}}
			cfg.TrustedPools.CreatorAdminProviderDelegatedIDs = map[string][]string{"creator-a": {"provider-a"}}
			cfg.TrustedPools.CreatorAdminBuyerAccountIDs = map[string][]string{"creator-a": {"acct-a"}}
			tc.build(&cfg)
			if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("Validate err=%v, want substring %q", err, tc.want)
			}
		})
	}
}

func trustedPoolsCreatorCredentialConfig(creatorID, credentialID, token string) TrustedPoolsCreatorAdminCredentialConfig {
	return TrustedPoolsCreatorAdminCredentialConfig{
		CreatorAccountID: creatorID,
		CredentialID:     credentialID,
		Token:            token,
		NotBeforeUTC:     "2026-01-01T00:00:00Z",
		ExpiresAtUTC:     "2027-01-01T00:00:00Z",
		Status:           "enabled",
	}
}

func TestTrustedPoolsProductionActivationRequiresCompleteExplicitGate(t *testing.T) {
	digest := strings.Repeat("a", 64)
	tests := []struct {
		name  string
		build func(*Config)
		want  string
	}{
		{
			name: "disabled trusted pools",
			build: func(cfg *Config) {
				cfg.TrustedPools.ProductionActivation.EvidenceSHA256 = digest
				cfg.TrustedPools.ProductionActivation.AllowedLaunchEnvironments = []string{"production"}
				cfg.TrustedPools.ProductionActivation.RootCustodyHashes = []string{digest}
			},
			want: "trusted_pools.enabled=true",
		},
		{
			name: "invalid evidence digest",
			build: func(cfg *Config) {
				cfg.TrustedPools.Enabled = true
				cfg.TrustedPools.ProductionActivation.EvidenceSHA256 = strings.ToUpper(digest)
				cfg.TrustedPools.ProductionActivation.AllowedLaunchEnvironments = []string{"production"}
				cfg.TrustedPools.ProductionActivation.RootCustodyHashes = []string{digest}
			},
			want: "evidence_sha256",
		},
		{
			name: "candidate environment rejected",
			build: func(cfg *Config) {
				cfg.TrustedPools.Enabled = true
				cfg.TrustedPools.ProductionActivation.EvidenceSHA256 = digest
				cfg.TrustedPools.ProductionActivation.AllowedLaunchEnvironments = []string{"candidate"}
				cfg.TrustedPools.ProductionActivation.RootCustodyHashes = []string{digest}
			},
			want: "non-candidate",
		},
		{
			name: "invalid custody digest",
			build: func(cfg *Config) {
				cfg.TrustedPools.Enabled = true
				cfg.TrustedPools.ProductionActivation.EvidenceSHA256 = digest
				cfg.TrustedPools.ProductionActivation.AllowedLaunchEnvironments = []string{"production"}
				cfg.TrustedPools.ProductionActivation.RootCustodyHashes = []string{"not-a-digest"}
			},
			want: "root_custody_hashes",
		},
	}
	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			cfg := validTestConfig()
			cfg.TrustedPools.RefreshIntervalS = 30
			tc.build(&cfg)
			if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("Validate err=%v, want substring %q", err, tc.want)
			}
		})
	}

	cfg := validTestConfig()
	cfg.TrustedPools.Enabled = true
	cfg.TrustedPools.RefreshIntervalS = 30
	cfg.TrustedPools.ProductionActivation.EvidenceSHA256 = digest
	cfg.TrustedPools.ProductionActivation.AllowedLaunchEnvironments = []string{"production"}
	cfg.TrustedPools.ProductionActivation.RootCustodyHashes = []string{digest}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("complete production activation gate should validate: %v", err)
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

func TestCoordinatorYAMLExampleSignedFeedsIncludePublicKeys(t *testing.T) {
	b, err := os.ReadFile(filepath.Clean("../../dist/coordinator.yaml.example"))
	if err != nil {
		t.Fatalf("read dist coordinator example: %v", err)
	}
	var cfg Config
	if err := yaml.Unmarshal(b, &cfg); err != nil {
		t.Fatalf("parse dist coordinator example: %v", err)
	}
	if cfg.AutotuneFeeds.RateCardPath == "" || cfg.AutotuneFeeds.DemandRankPath == "" || cfg.AutotuneFeeds.AutotuneCandidatesPath == "" {
		t.Fatal("dist coordinator example must show the complete signed feed set")
	}
	if len(cfg.AutotuneFeeds.PublicKeys) == 0 {
		t.Fatal("dist coordinator example signed feeds must include autotune.public_keys")
	}
}

func TestTier2ValidationPreservesDefaultsAndRejectsUnsafeConfig(t *testing.T) {
	cfg := validTestConfig()
	if err := cfg.Validate(); err != nil {
		t.Fatalf("default Tier2 config should validate: %v", err)
	}

	cfg = validTestConfig()
	cfg.Tier2.CatalogPath = "/tmp/catalog.json"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "catalog_public_key") {
		t.Fatalf("catalog without public key err=%v", err)
	}

	cfg = validTestConfig()
	cfg.Tier2.RequireHashVerified = true
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "require_hash_verified") {
		t.Fatalf("require_hash_verified without catalog err=%v", err)
	}

	cfg = Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Auth.GatewayServiceToken = "gateway-service-token"
	cfg.Tier2.ModelHashLegacyUntil = "tomorrow"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "model_hash_legacy_until") {
		t.Fatalf("invalid model hash legacy deadline err=%v", err)
	}

	cfg = Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Auth.GatewayServiceToken = "gateway-service-token"
	cfg.Tier2.ModelHashLegacyUntil = "2026-07-19T00:00:00Z"
	if err := cfg.Validate(); err != nil {
		t.Fatalf("RFC3339 model hash legacy deadline should validate: %v", err)
	}

	cfg = validTestConfig()
	cfg.Tier2.EncryptedLegAEAD = "unknown"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "encrypted_leg_aead") {
		t.Fatalf("unsupported AEAD err=%v", err)
	}

	cfg = validTestConfig()
	cfg.Tier2.RequireEncryptedLeg = true
	if err := cfg.Validate(); err != nil {
		t.Fatalf("phase 2 encrypted leg enforcement should validate with default A256GCM: %v", err)
	}

	cfg = validTestConfig()
	cfg.Tier2.RequireAttestation = true
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "require_attestation") {
		t.Fatalf("attestation without roots err=%v", err)
	}

	cfg = validTestConfig()
	cfg.Tier2.RequireAttestation = true
	cfg.Tier2.AttestationRoots = []string{"mock-root"}
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "require_attestation") {
		t.Fatalf("mock attestation root without opt-in err=%v", err)
	}

	cfg.Tier2.AllowMockAttestation = true
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "require_attestation") {
		t.Fatalf("mock attestation root should not validate with require_attestation: %v", err)
	}

	cfg = validTestConfig()
	cfg.Tier2.BehavioralSafetyEnabled = true
	cfg.Tier2.EncodingValidationEnabled = true
	cfg.Tier2.ResponseTimeAnomalyEnabled = true
	if err := cfg.Validate(); err != nil {
		t.Fatalf("phase 3 behavioral safety flags should validate: %v", err)
	}

	cfg = validTestConfig()
	cfg.Tier2.OutputSizeCapBytes = -1
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "output_size_cap_bytes") {
		t.Fatalf("negative output size cap err=%v", err)
	}

	cfg = validTestConfig()
	cfg.Tier2.ResponseTimeAnomalyFactor = 1.0
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "response_time_anomaly_factor") {
		t.Fatalf("response anomaly factor err=%v", err)
	}
}

func TestModelHashLegacyDeadlineEnvResolutionFailsClosed(t *testing.T) {
	const deadline = "2099-07-19T00:00:00Z"
	t.Setenv("MODEL_HASH_LEGACY_UNTIL_TEST", deadline)

	cfg := Default()
	cfg.Tier2.ModelHashLegacyUntil = "env:MODEL_HASH_LEGACY_UNTIL_TEST"
	if err := cfg.resolveEnv(); err != nil {
		t.Fatalf("resolve configured deadline: %v", err)
	}
	if cfg.Tier2.ModelHashLegacyUntil != deadline {
		t.Fatalf("resolved deadline=%q want %q", cfg.Tier2.ModelHashLegacyUntil, deadline)
	}

	t.Setenv("MODEL_HASH_LEGACY_UNTIL_TEST", "")
	cfg = Default()
	cfg.Tier2.ModelHashLegacyUntil = "env:MODEL_HASH_LEGACY_UNTIL_TEST"
	if err := cfg.resolveEnv(); err == nil || !strings.Contains(err.Error(), "tier2.model_hash_legacy_until") {
		t.Fatalf("missing deadline environment error=%v", err)
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
	cfg := validTestConfig()
	cfg.Proxy.TrustedProxies = []string{"0.0.0.0/0"}
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "default-route prefix") {
		t.Fatalf("Validate(0.0.0.0/0) err=%v, want default-route rejection (every caller would be header-trusted)", err)
	}
}

func TestTrustedProxyPrefixesRejectsDefaultRouteIPv6(t *testing.T) {
	cfg := validTestConfig()
	cfg.Proxy.TrustedProxies = []string{"::/0"}
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "default-route prefix") {
		t.Fatalf("Validate(::/0) err=%v, want default-route rejection", err)
	}
}

func TestTrustedProxyPrefixesRejectsMalformedCIDR(t *testing.T) {
	cfg := validTestConfig()
	cfg.Proxy.TrustedProxies = []string{"not-a-cidr"}
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "proxy.trusted_proxies") {
		t.Fatalf("Validate(not-a-cidr) err=%v, want parse-error rejection", err)
	}
}

func TestTrustedProxyPrefixesEmptyAllowed(t *testing.T) {
	cfg := validTestConfig()
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
		cfg := validTestConfig()
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
	if cfg.Onboarding.CoordinatorDomain != "coordinator.malibu.tech" {
		t.Fatalf("coordinator_domain=%q", cfg.Onboarding.CoordinatorDomain)
	}
}

func TestOnboardingEnabledRequiresStartupSecrets(t *testing.T) {
	cfg := validTestConfig()
	cfg.Onboarding.AppTrackRegisterEnabled = true
	enableReferralAdmissionForTest(&cfg)
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
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "onboarding.hardware_trust_request_dsn") {
		t.Fatalf("enabled without hardware_trust_request_dsn err=%v", err)
	}

	cfg.Onboarding.HardwareTrustRequestDSN = "postgres://hardware_trust_requester@127.0.0.1/db?sslmode=disable"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "onboarding.hardware_trust_approve_dsn") {
		t.Fatalf("enabled without hardware_trust_approve_dsn err=%v", err)
	}

	cfg.Onboarding.HardwareTrustApproveDSN = "postgres://hardware_trust_approver@127.0.0.1/db?sslmode=disable"
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
	cfg := validTestConfig()
	cfg.Onboarding.AppTrackRegisterEnabled = true
	enableReferralAdmissionForTest(&cfg)
	cfg.Onboarding.PostgresDSN = "postgres://provider_onboarding@127.0.0.1/db?sslmode=disable"
	cfg.Onboarding.AuthPolicyRequestDSN = "postgres://provider_auth_policy_requester@127.0.0.1/db?sslmode=disable"
	cfg.Onboarding.AuthPolicyApproveDSN = "postgres://provider_auth_policy_approver@127.0.0.1/db?sslmode=disable"
	cfg.Onboarding.AuthPolicyCutoverDSN = "postgres://provider_auth_policy_cutover@127.0.0.1/db?sslmode=disable"
	cfg.Onboarding.HardwareTrustRequestDSN = "postgres://hardware_trust_requester@127.0.0.1/db?sslmode=disable"
	cfg.Onboarding.HardwareTrustApproveDSN = "postgres://hardware_trust_approver@127.0.0.1/db?sslmode=disable"
	cfg.Onboarding.AppleTeamID = "TEAM12345"
	cfg.Onboarding.ASNPrefixes = map[string]string{"198.51.100.0/24": "AS64500"}

	cfg.Auth.OperatorKeys = map[string]string{"alice": "same-secret", "bob": "same-secret"}
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "must not reuse secret") {
		t.Fatalf("duplicate operator secret err=%v", err)
	}
}

func TestCLIOnlyOperatorKeysAllowPartialConfigurationWhileRoutesFailClosed(t *testing.T) {
	cfg := validTestConfig()
	cfg.Auth.OperatorKey = "legacy-operator"
	cfg.Onboarding.AppTrackRegisterEnabled = false
	cfg.Auth.OperatorKeys = map[string]string{"alice": "same-secret", "bob": "same-secret"}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("CLI-only duplicate operator map must remain startup-compatible: %v", err)
	}

	cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret"}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("CLI-only single operator map must remain startup-compatible: %v", err)
	}

	cfg.Auth.OperatorKeys = nil
	if err := cfg.Validate(); err != nil {
		t.Fatalf("CLI-only deployment without named admin operators should remain valid: %v", err)
	}
}

func TestOnboardingCoordinatorDomainMustBeBareLowercaseHost(t *testing.T) {
	cfg := validTestConfig()
	cfg.Onboarding.CoordinatorDomain = "https://Coordinator.malibu.tech/"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "bare lowercase host") {
		t.Fatalf("domain validation err=%v", err)
	}
}

// TestCanaryOPoIV0StagingOverlayParsesAndValidates verifies that the OPoI v0
// staging overlay YAML unmarshals into a valid canary config block, including
// the output budget needed to avoid truncating a nonce response.
func TestCanaryOPoIV0StagingOverlayParsesAndValidates(t *testing.T) {
	if got := Default().Pool.CanaryMaxTokens; got < 32 {
		t.Fatalf("default canary_max_tokens = %d, want >= 32", got)
	}
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
	if cfg.Pool.CanaryMaxTokens < 32 {
		t.Fatalf("staging overlay canary_max_tokens = %d, want >= 32", cfg.Pool.CanaryMaxTokens)
	}
	if len(cfg.Pool.CanaryChallenges) == 0 {
		t.Fatal("staging overlay must have at least one canary_challenge")
	}
	for i, ch := range cfg.Pool.CanaryChallenges {
		if !strings.Contains(ch.Prompt, "{nonce}") || !strings.Contains(ch.Expected, "{nonce}") {
			t.Fatalf("canary_challenges[%d] missing {nonce} in prompt or expected", i)
		}
	}
	if len(cfg.Pool.ModelClassChallenges) == 0 {
		t.Fatal("staging overlay must include model_class_challenges for W3 lab smoke")
	}
	for modelID, bank := range cfg.Pool.ModelClassChallenges {
		for i, ch := range bank {
			if !strings.Contains(ch.Prompt, "{nonce}") || !strings.Contains(ch.Expected, "{nonce}") {
				t.Fatalf("model_class_challenges.%s[%d] missing {nonce}", modelID, i)
			}
		}
	}
}

func TestLoadWithOverlayMergesPoolCanaryBlock(t *testing.T) {
	dir := t.TempDir()
	basePath := filepath.Join(dir, "base.yaml")
	overlayPath := filepath.Join(dir, "overlay.yaml")
	if err := os.WriteFile(basePath, []byte("auth:\n  operator_key: test-operator-key-with-32-byte-minimum-length\n  gateway_service_token: test-gateway-token-with-32-byte-minimum-length\npool:\n  canary_enabled: false\n"), 0o644); err != nil {
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
	if err := os.WriteFile(basePath, []byte("auth:\n  operator_key: test-operator-key-with-32-byte-minimum-length\n  gateway_service_token: test-gateway-token-with-32-byte-minimum-length\n"), 0o644); err != nil {
		t.Fatalf("write base: %v", err)
	}
	overlay := strings.TrimSpace(`
malibu_emission:
  enabled: false
  bootstrap_tick_enabled: false
  epoch_enabled: false
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
	if cfg.MalibuEmission.BootstrapTickEnabled {
		t.Fatal("bootstrap tick should remain disabled in staging overlay")
	}
	if cfg.MalibuEmission.EpochEnabled {
		t.Fatal("epoch mode should remain disabled until the policy engine is active")
	}
	if cfg.MalibuEmission.WriterDSN != "postgres://rewards_writer:pw@127.0.0.1:5432/stats?sslmode=disable" {
		t.Fatalf("writer_dsn=%q", cfg.MalibuEmission.WriterDSN)
	}
	if cfg.MalibuEmission.ProviderDailyCapMALIBU != 25 {
		t.Fatalf("provider cap=%v", cfg.MalibuEmission.ProviderDailyCapMALIBU)
	}
}

func TestValidateMalibuEmissionRejectsEpochBootstrapCoexistence(t *testing.T) {
	cfg := validTestConfig()
	cfg.MalibuEmission.Enabled = true
	cfg.MalibuEmission.BootstrapTickEnabled = true
	cfg.MalibuEmission.EpochEnabled = true
	cfg.MalibuEmission.WriterDSN = "postgres://rewards_writer:pw@127.0.0.1:5432/stats?sslmode=disable"
	cfg.MalibuEmission.TickIntervalSeconds = 900
	cfg.MalibuEmission.UsefulWorkIntervalSeconds = 900
	cfg.MalibuEmission.ProviderDailyCapMALIBU = 25
	cfg.MalibuEmission.WalletDailyCapMALIBU = 100
	cfg.MalibuEmission.UsefulWorkMALIBUPer1KCredits = 1
	cfg.MalibuEmission.WalletMirrorIntervalSeconds = 300
	cfg.MalibuEmission.UnlockEvalIntervalSeconds = 3600
	cfg.MalibuEmission.MaxSerializableRetries = 5

	err := cfg.Validate()
	if err == nil || !strings.Contains(err.Error(), "bootstrap_tick_enabled") {
		t.Fatalf("Validate error=%v, want bootstrap/epoch coexistence rejection", err)
	}
}

func TestValidateRegistrationOnlyCoolingOffFloor(t *testing.T) {
	cfg := validTestConfig()
	cfg.Payout.Enabled = false
	cfg.Payout.Security.HotWalletAddress = "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	cfg.Payout.Tuning.AddressCoolingOffPeriod = 30 * time.Minute
	err := cfg.Validate()
	if err == nil || !strings.Contains(err.Error(), "address_cooling_off_period") {
		t.Fatalf("Validate error=%v, want cooling-off floor for registration-only", err)
	}

	cfg.Payout.Tuning.AddressCoolingOffPeriod = 24 * time.Hour
	if err := cfg.Validate(); err != nil {
		t.Fatalf("Validate registration-only with valid cooling-off: %v", err)
	}
}

func TestValidateRegistrationOnlyRejectsPlaceholderHotWallet(t *testing.T) {
	cfg := validTestConfig()
	cfg.Payout.Enabled = false
	cfg.Payout.Security.HotWalletAddress = "<0x... EIP-55 checksummed hot wallet>"
	cfg.Payout.Tuning.AddressCoolingOffPeriod = 24 * time.Hour
	err := cfg.Validate()
	if err == nil || !strings.Contains(err.Error(), "hot_wallet_address") {
		t.Fatalf("Validate error=%v, want placeholder hot wallet rejection", err)
	}
}

func TestValidateDisabledWithoutHotWalletSkipsCoolingOff(t *testing.T) {
	cfg := validTestConfig()
	cfg.Payout.Enabled = false
	cfg.Payout.Security.HotWalletAddress = ""
	cfg.Payout.Tuning.AddressCoolingOffPeriod = 30 * time.Minute
	if err := cfg.Validate(); err != nil {
		t.Fatalf("fully disabled payout should not enforce cooling-off: %v", err)
	}
}
