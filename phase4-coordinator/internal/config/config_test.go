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
	if err := cfg.Validate(); err != nil {
		t.Fatalf("phase 2 attestation enforcement should validate with roots: %v", err)
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
