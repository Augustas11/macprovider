package poolmanifest

import (
	"encoding/hex"
	"testing"
)

// GOLDEN VECTORS — freeze the SPEC-043-R006 policy-terms preimage and digest
// (the rotation-invariant digest a ProviderPoolDelegationV1 grant binds to).
const (
	goldenPolicyTermsV1Hex          = "6d616370726f76696465722f737065633034332f706f6c6963792d7465726d732f7631000000226d616370726f76696465722f737065633034322f706f6c6963792d636f72652f763100000016696a556e632d5a51662d4c4a6552766b68692d306951000000000000000100000002000000076d6f64656c2d61000000076d6f64656c2d6200000005312e382e300000000b73656c665f7369676e65640100000007656e666f7263650000000000000000000000156465636c617265645f6e6f745f6578656375746564000000057265742d310000000000000001000000046e6f6e650000000000000000000000000000"
	goldenPolicyTermsV1Digest       = "67e7fb0a4ef6ffa5fa85e02474f0d766a3b40cbcf8e9888fc16f6905613786f0"
	goldenPolicyTermsV2AllowDigest  = "0dbb9e4d385567a7df8d20dcece1d4876329da9c45d7955a28b27b5c61030754"
	goldenPolicyTermsPoolBothDigest = "3b63b860c8743ce15cbd254cc4d5bdce7d9482ee2e4bf7d3a132438f6ed4a558"
)

func TestPolicyTermsGoldenVectors(t *testing.T) {
	pid, _ := sampleIdentity().PoolID()
	v1 := samplePolicy(pid)
	if got := hex.EncodeToString(must(v1.PolicyTermsBytes())); got != goldenPolicyTermsV1Hex {
		t.Fatalf("v1 policy-terms bytes drifted:\n got=%s\nwant=%s", got, goldenPolicyTermsV1Hex)
	}
	if got := hex.EncodeToString(must(v1.PolicyTermsDigest())); got != goldenPolicyTermsV1Digest {
		t.Fatalf("v1 policy_terms_digest=%s, want %s", got, goldenPolicyTermsV1Digest)
	}
	// The terms encoder leaves the core preimage byte-identical.
	if got := hex.EncodeToString(must(v1.CanonicalBytes())); got != goldenPolicyCoreHex {
		t.Fatal("policy-core bytes changed")
	}
	if goldenPolicyTermsV1Digest == goldenManifestDigest {
		t.Fatal("policy-terms digest collides with the core digest")
	}
	v2 := samplePolicyV2(pid, RuntimeSourceLlamacppLoopback, RuntimeSourceOllamaLoopback)
	if got := hex.EncodeToString(must(v2.PolicyTermsDigest())); got != goldenPolicyTermsV2AllowDigest {
		t.Fatalf("v2 policy_terms_digest=%s, want %s", got, goldenPolicyTermsV2AllowDigest)
	}
	both := rawPoolCore(t, pid, sampleEntries(pid), sampleMembers())
	if got := hex.EncodeToString(must(both.PolicyTermsDigest())); got != goldenPolicyTermsPoolBothDigest {
		t.Fatalf("pool-extension policy_terms_digest=%s, want %s", got, goldenPolicyTermsPoolBothDigest)
	}
	// Same fields, different core encoding: the terms digests differ.
	v2Empty := samplePolicyV2(pid)
	if string(must(v2Empty.PolicyTermsDigest())) == string(must(v1.PolicyTermsDigest())) {
		t.Fatal("v1 and v2 cores with the same fields share a terms digest")
	}
	// An invalid core has no terms digest.
	bad := samplePolicy(pid)
	bad.PrevManifestCoreHash = []byte{0x00}
	if _, err := bad.PolicyTermsDigest(); err == nil {
		t.Fatal("terms digest computed for a core without a canonical preimage")
	}
}

// TestPolicyTermsDigestExclusions pins the exact SPEC-043-R006 exclusion
// list: the four rotation-only fields leave the terms digest unchanged (while
// changing the core digest), and every other field changes it.
func TestPolicyTermsDigestExclusions(t *testing.T) {
	pid, _ := sampleIdentity().PoolID()
	base := rawPoolCore(t, pid, sampleEntries(pid), sampleMembers())
	baseTerms := must(base.PolicyTermsDigest())
	baseCore := must(base.ManifestCoreDigest())
	excluded := map[string]func(*PolicyCore){
		"manifest_version":        func(p *PolicyCore) { p.ManifestVersion = 7 },
		"prev_manifest_core_hash": func(p *PolicyCore) { p.PrevManifestCoreHash = baseCore },
		"not_before_unix":         func(p *PolicyCore) { p.NotBeforeUnix = 5000 },
		"expires_at_unix":         func(p *PolicyCore) { p.ExpiresAtUnix = 9000 },
	}
	for name, mut := range excluded {
		p := rawPoolCore(t, pid, sampleEntries(pid), sampleMembers())
		mut(&p)
		if string(must(p.PolicyTermsDigest())) != string(baseTerms) {
			t.Errorf("rotation-only field %q changed the policy-terms digest", name)
		}
		if string(must(p.ManifestCoreDigest())) == string(baseCore) {
			t.Errorf("rotation-only field %q did not change the core digest", name)
		}
	}
	entries := sampleEntries(pid)
	entries[0].Pricing.CompletionRatePerMtok++
	included := map[string]func(*PolicyCore){
		"pool_id":                func(p *PolicyCore) { p.PoolID = "another-pool-id-xxxxxx" },
		"signer_set_version":     func(p *PolicyCore) { p.SignerSetVersion = 2 },
		"model_allowlist":        func(p *PolicyCore) { p.ModelAllowlist = []string{"model-c"} },
		"min_binary_version":     func(p *PolicyCore) { p.MinBinaryVersion = "9.9.9" },
		"min_attestation_tier":   func(p *PolicyCore) { p.MinAttestationTier = "hardware" },
		"require_encrypted_leg":  func(p *PolicyCore) { p.RequireEncryptedLeg = false },
		"settlement_mode":        func(p *PolicyCore) { p.SettlementMode = "observe" },
		"revenue_split_bps":      func(p *PolicyCore) { p.RevenueSplitBps = 500 },
		"split_execution_status": func(p *PolicyCore) { p.SplitExecutionStatus = "executed" },
		"retention_policy_id":    func(p *PolicyCore) { p.RetentionPolicyID = "ret-2" },
		"min_eligible_members":   func(p *PolicyCore) { p.MinEligibleMembers = 3 },
		"privacy_mode":           func(p *PolicyCore) { p.PrivacyMode = "relay_blind" },
		"relay_blind_capable":    func(p *PolicyCore) { p.RelayBlindCapable = true },
		"receipt_contract":       func(p *PolicyCore) { p.ReceiptContract = "v0.4" },
		"metadata_visible":       func(p *PolicyCore) { p.MetadataVisible = "minimal" },
		"downgrade_policy":       func(p *PolicyCore) { p.DowngradePolicy = "reject" },
		"sticky_routing_allowed": func(p *PolicyCore) { p.StickyRoutingAllowed = true },
		"runtime_allowlist":      func(p *PolicyCore) { p.RuntimeAllowlist = []string{RuntimeSourceLlamacppLoopback} },
		"pool_model_entries/v1": func(p *PolicyCore) {
			p.Extensions[1].Body = must(EncodePoolModelEntries(entries))
		},
		"pool_attested_members/v1": func(p *PolicyCore) { p.Extensions = p.Extensions[1:] },
		"encoding":                 func(p *PolicyCore) { p.Encoding = PolicyCoreEncodingV1; p.RuntimeAllowlist = nil; p.Extensions = nil },
	}
	for name, mut := range included {
		p := rawPoolCore(t, pid, sampleEntries(pid), sampleMembers())
		mut(&p)
		got, err := p.PolicyTermsDigest()
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if string(got) == string(baseTerms) {
			t.Errorf("term %q did not change the policy-terms digest", name)
		}
	}
}
