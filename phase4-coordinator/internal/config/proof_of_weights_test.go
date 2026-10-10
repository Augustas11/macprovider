package config_test

import (
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

func TestValidateProofOfWeightsRequiresFeedsAndOnboarding(t *testing.T) {
	cfg := config.Default()
	cfg.Auth.OperatorKey = "test-operator-key"
	cfg.Auth.GatewayServiceToken = "test-gateway-service-token"
	cfg.ProofOfWeights.RequireAutotuneHelloGate = true
	cfg.ProofOfWeights.AutotuneEvidenceTTLDays = 30
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "autotune.autotune_candidates_path") {
		t.Fatalf("Validate() = %v, want autotune feed requirement", err)
	}

	setSignedAutotuneFeedPathsForProofTest(&cfg)
	cfg.AutotuneFeeds.PublicKeys = map[string]string{
		"streamvc-autotune-static-v4": "zTKDIdMmKKkO1Cgf5OdTzMOytVqW7U8SGsJ9XrzAltU=",
	}
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "onboarding.app_track_register_enabled") {
		t.Fatalf("Validate() = %v, want onboarding requirement", err)
	}
}

func proofOfWeightsOnboardingBaseline(cfg *config.Config) {
	setSignedAutotuneFeedPathsForProofTest(cfg)
	cfg.AutotuneFeeds.PublicKeys = map[string]string{
		"streamvc-autotune-static-v4": "zTKDIdMmKKkO1Cgf5OdTzMOytVqW7U8SGsJ9XrzAltU=",
	}
	cfg.Onboarding.AppTrackRegisterEnabled = true
	cfg.Onboarding.PostgresDSN = "postgres://provider_onboarding@127.0.0.1/db?sslmode=disable"
	cfg.Onboarding.AuthPolicyRequestDSN = "postgres://provider_auth_policy_requester@127.0.0.1/db?sslmode=disable"
	cfg.Onboarding.AuthPolicyApproveDSN = "postgres://provider_auth_policy_approver@127.0.0.1/db?sslmode=disable"
	cfg.Onboarding.AuthPolicyCutoverDSN = "postgres://provider_auth_policy_cutover@127.0.0.1/db?sslmode=disable"
	cfg.Onboarding.HardwareTrustRequestDSN = "postgres://hardware_trust_requester@127.0.0.1/db?sslmode=disable"
	cfg.Onboarding.HardwareTrustApproveDSN = "postgres://hardware_trust_approver@127.0.0.1/db?sslmode=disable"
	cfg.Onboarding.AppleTeamID = "TEAM12345"
	cfg.Onboarding.ASNPrefixes = map[string]string{"198.51.100.0/24": "AS64500"}
	cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	cfg.Referrals.RequireForRegistration = true
	cfg.Referrals.Campaign = "prebeta_2026"
	cfg.Referrals.CurrentKeyID = "k1"
	cfg.Referrals.HMACKeys = map[string]string{"k1": strings.Repeat("s", 32)}
}

func setSignedAutotuneFeedPathsForProofTest(cfg *config.Config) {
	cfg.AutotuneFeeds.RateCardPath = "/tmp/rate-card.json"
	cfg.AutotuneFeeds.RateCardSigPath = "/tmp/rate-card.json.sig"
	cfg.AutotuneFeeds.DemandRankPath = "/tmp/demand-rank.json"
	cfg.AutotuneFeeds.DemandRankSigPath = "/tmp/demand-rank.json.sig"
	cfg.AutotuneFeeds.AutotuneCandidatesPath = "/tmp/autotune-candidates.json"
	cfg.AutotuneFeeds.AutotuneCandidatesSigPath = "/tmp/autotune-candidates.json.sig"
}

// #1938: autotune_evidence_ttl_days is accepted for overlay compatibility and
// ignored; it never blocks enabling the hello gate.
func TestValidateProofOfWeightsHelloGateIgnoresEvidenceTTL(t *testing.T) {
	cfg := config.Default()
	cfg.Auth.OperatorKey = "test-operator-key"
	cfg.Auth.GatewayServiceToken = "test-gateway-service-token"
	cfg.ProofOfWeights.RequireAutotuneHelloGate = true
	proofOfWeightsOnboardingBaseline(&cfg)
	for _, ttl := range []int{-1, 0, 1, 30} {
		cfg.ProofOfWeights.AutotuneEvidenceTTLDays = ttl
		if err := cfg.Validate(); err != nil {
			t.Fatalf("Validate() with autotune_evidence_ttl_days=%d = %v, want nil", ttl, err)
		}
	}
}

func TestValidateProofOfWeightsTelemetryDriftRequiresCanaryWhenWindowSet(t *testing.T) {
	cfg := config.Default()
	cfg.Auth.OperatorKey = "test-operator-key"
	cfg.Auth.GatewayServiceToken = "test-gateway-service-token"
	cfg.ProofOfWeights.AutotuneEvidenceTTLDays = 30
	cfg.ProofOfWeights.TelemetryDrift.Enabled = true
	cfg.ProofOfWeights.TelemetryDrift.OPoIPassRateWindow = 10
	proofOfWeightsOnboardingBaseline(&cfg)
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "pool.canary_enabled") {
		t.Fatalf("Validate() = %v, want canary requirement", err)
	}
}
