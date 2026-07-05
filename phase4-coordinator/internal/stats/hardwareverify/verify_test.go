package hardwareverify

import (
	"encoding/json"
	"testing"
	"time"
)

func TestEvaluateVerifiesTrustedHardwareWithPositiveBenchmark(t *testing.T) {
	evidence := Evidence{
		ProviderID: "mac",
		Hardware: Hardware{
			HardwareIdentityHash: "hash",
		},
		Benchmarks: []Benchmark{{
			ModelKey:     "qwen-7b",
			SustainedTPS: 42.5,
			TTFTMS:       1200,
		}},
	}
	raw, err := json.Marshal(evidence)
	if err != nil {
		t.Fatal(err)
	}
	decision := Evaluate(Job{
		ID:                 1,
		ProviderID:         "mac",
		Chip:               "Apple M5",
		ChipNormalized:     "apple m5",
		MemoryGB:           32,
		BandwidthTier:      "C",
		GeneratedAt:        time.Now().UTC(),
		Evidence:           raw,
		TrustMatched:       true,
		ChipProfileMatched: true,
	})
	if !decision.Verified {
		t.Fatalf("decision.Verified = false, reason=%s", decision.Reason)
	}
	if decision.Reason != "hardware-verifier.v1:verified_trusted_hardware" {
		t.Fatalf("reason = %q, want trusted hardware verification", decision.Reason)
	}
}

func TestEvaluateAllowsHigherTierChipsWhenOperatorInventoryMatches(t *testing.T) {
	for _, tc := range []struct {
		name string
		chip string
		tier string
	}{
		{name: "pro", chip: "Apple M4 Pro", tier: "B"},
		{name: "max", chip: "Apple M4 Max", tier: "A"},
		{name: "ultra", chip: "Apple M3 Ultra", tier: "S"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			raw, err := json.Marshal(Evidence{
				ProviderID: "mac",
				Hardware: Hardware{
					HardwareIdentityHash: "hash",
				},
				Benchmarks: []Benchmark{{ModelKey: "x", SustainedTPS: 1}},
			})
			if err != nil {
				t.Fatal(err)
			}
			decision := Evaluate(Job{
				ProviderID:         "mac",
				Chip:               tc.chip,
				ChipNormalized:     "apple m4 " + tc.name,
				MemoryGB:           64,
				BandwidthTier:      tc.tier,
				GeneratedAt:        time.Now().UTC(),
				Evidence:           raw,
				TrustMatched:       true,
				ChipProfileMatched: true,
			})
			if !decision.Verified {
				t.Fatalf("decision.Verified = false for %s, reason=%s", tc.chip, decision.Reason)
			}
		})
	}
}

func TestEvaluateRejectsProviderMismatch(t *testing.T) {
	raw, err := json.Marshal(Evidence{
		ProviderID: "other",
		Hardware: Hardware{
			HardwareIdentityHash: "hash",
		},
		Benchmarks: []Benchmark{{ModelKey: "x", SustainedTPS: 1}},
	})
	if err != nil {
		t.Fatal(err)
	}
	decision := Evaluate(Job{
		ProviderID:         "mac",
		Chip:               "Apple M4",
		ChipNormalized:     "apple m4",
		MemoryGB:           32,
		BandwidthTier:      "C",
		GeneratedAt:        time.Now().UTC(),
		Evidence:           raw,
		TrustMatched:       true,
		ChipProfileMatched: true,
	})
	if decision.Verified {
		t.Fatal("decision.Verified = true, want false")
	}
	if decision.Reason != "provider_id_mismatch" {
		t.Fatalf("reason = %q, want provider_id_mismatch", decision.Reason)
	}
}

func TestEvaluateRejectsWithoutTrustMatch(t *testing.T) {
	raw, err := json.Marshal(Evidence{
		ProviderID: "mac",
		Hardware: Hardware{
			HardwareIdentityHash: "hash",
		},
		Benchmarks: []Benchmark{{ModelKey: "x", SustainedTPS: 1}},
	})
	if err != nil {
		t.Fatal(err)
	}
	decision := Evaluate(Job{
		ProviderID:         "mac",
		Chip:               "Apple M5",
		ChipNormalized:     "apple m5",
		MemoryGB:           32,
		BandwidthTier:      "C",
		GeneratedAt:        time.Now().UTC(),
		Evidence:           raw,
		ChipProfileMatched: true,
	})
	if decision.Verified {
		t.Fatal("decision.Verified = true, want false")
	}
	if decision.Reason != "missing_trusted_hardware_identity" {
		t.Fatalf("reason = %q, want missing_trusted_hardware_identity", decision.Reason)
	}
}

func TestEvaluateRejectsMalformedEvidenceBeforeWaitingForTrust(t *testing.T) {
	raw, err := json.Marshal(Evidence{
		ProviderID: "mac",
		Benchmarks: []Benchmark{{ModelKey: "x", SustainedTPS: 1}},
	})
	if err != nil {
		t.Fatal(err)
	}
	decision := Evaluate(Job{
		ProviderID:     "mac",
		Chip:           "Apple M5",
		ChipNormalized: "apple m5",
		MemoryGB:       32,
		BandwidthTier:  "C",
		GeneratedAt:    time.Now().UTC(),
		Evidence:       raw,
	})
	if decision.Verified {
		t.Fatal("decision.Verified = true, want false")
	}
	if decision.Reason != "missing_hardware_identity_hash" {
		t.Fatalf("reason = %q, want missing_hardware_identity_hash", decision.Reason)
	}
}

func TestEvaluateWaitsWithoutTrustedChipProfile(t *testing.T) {
	raw, err := json.Marshal(Evidence{
		ProviderID: "mac",
		Hardware: Hardware{
			HardwareIdentityHash: "hash",
		},
		Benchmarks: []Benchmark{{ModelKey: "x", SustainedTPS: 1}},
	})
	if err != nil {
		t.Fatal(err)
	}
	decision := Evaluate(Job{
		ProviderID:     "mac",
		Chip:           "Apple M5",
		ChipNormalized: "apple m5",
		MemoryGB:       32,
		BandwidthTier:  "C",
		GeneratedAt:    time.Now().UTC(),
		Evidence:       raw,
		TrustMatched:   true,
	})
	if decision.Verified {
		t.Fatal("decision.Verified = true, want false")
	}
	if decision.Reason != "missing_trusted_chip_profile" {
		t.Fatalf("reason = %q, want missing_trusted_chip_profile", decision.Reason)
	}
}
