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
