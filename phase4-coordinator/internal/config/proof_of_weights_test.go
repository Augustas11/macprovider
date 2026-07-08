package config_test

import (
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

func TestValidateProofOfWeightsRequiresFeedsAndOnboarding(t *testing.T) {
	cfg := config.Default()
	cfg.Auth.OperatorKey = "test-operator-key"
	cfg.ProofOfWeights.RequireAutotuneHelloGate = true
	cfg.ProofOfWeights.AutotuneEvidenceTTLDays = 30
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "autotune.autotune_candidates_path") {
		t.Fatalf("Validate() = %v, want autotune feed requirement", err)
	}

	cfg.AutotuneFeeds.AutotuneCandidatesPath = "/tmp/autotune-candidates.json"
	cfg.AutotuneFeeds.AutotuneCandidatesSigPath = "/tmp/autotune-candidates.json.sig"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "onboarding.app_track_register_enabled") {
		t.Fatalf("Validate() = %v, want onboarding requirement", err)
	}
}

func proofOfWeightsOnboardingBaseline(cfg *config.Config) {
	cfg.AutotuneFeeds.AutotuneCandidatesPath = "/tmp/autotune-candidates.json"
	cfg.AutotuneFeeds.AutotuneCandidatesSigPath = "/tmp/autotune-candidates.json.sig"
	cfg.Onboarding.AppTrackRegisterEnabled = true
	cfg.Onboarding.PostgresDSN = "postgres://provider_onboarding@127.0.0.1/db?sslmode=disable"
	cfg.Onboarding.AuthPolicyRequestDSN = "postgres://provider_auth_policy_requester@127.0.0.1/db?sslmode=disable"
	cfg.Onboarding.AuthPolicyApproveDSN = "postgres://provider_auth_policy_approver@127.0.0.1/db?sslmode=disable"
	cfg.Onboarding.AuthPolicyCutoverDSN = "postgres://provider_auth_policy_cutover@127.0.0.1/db?sslmode=disable"
	cfg.Onboarding.AppleTeamID = "TEAM12345"
	cfg.Onboarding.ASNPrefixes = map[string]string{"198.51.100.0/24": "AS64500"}
	cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
}

func TestValidateProofOfWeightsTelemetryDriftRequiresCanaryWhenWindowSet(t *testing.T) {
	cfg := config.Default()
	cfg.Auth.OperatorKey = "test-operator-key"
	cfg.ProofOfWeights.AutotuneEvidenceTTLDays = 30
	cfg.ProofOfWeights.TelemetryDrift.Enabled = true
	cfg.ProofOfWeights.TelemetryDrift.OPoIPassRateWindow = 10
	proofOfWeightsOnboardingBaseline(&cfg)
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "pool.canary_enabled") {
		t.Fatalf("Validate() = %v, want canary requirement", err)
	}
}
