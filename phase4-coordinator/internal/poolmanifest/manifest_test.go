package poolmanifest

import (
	"encoding/hex"
	"regexp"
	"testing"
)

// sampleIdentity / samplePolicy are the fixed inputs the golden vectors pin.
func sampleIdentity() IdentityCore {
	return IdentityCore{RootIssuerKeyID: "root-key-1", GenesisNonce: []byte("genesis-nonce-abc")}
}

func samplePolicy(poolID string) PolicyCore {
	return PolicyCore{
		PoolID: poolID, ManifestVersion: 1, PrevManifestCoreHash: GenesisPrevHash(), SignerSetVersion: 1,
		ModelAllowlist:   []string{"model-b", "model-a"}, // deliberately out of order
		MinBinaryVersion: "1.8.0", MinAttestationTier: "self_signed", RequireEncryptedLeg: true,
		SettlementMode: "enforce", RevenueSplitBps: 0, SplitExecutionStatus: "declared_not_executed",
		RetentionPolicyID: "ret-1", MinEligibleMembers: 1, PrivacyMode: "none",
		NotBeforeUnix: 1000, ExpiresAtUnix: 2000,
	}
}

// GOLDEN VECTORS — freeze the SPEC-042-R001 canonical wire format. Any change to
// the grammar breaks these on purpose.
const (
	goldenIdentityCoreHex  = "6d616370726f76696465722f737065633034322f6964656e746974792d636f72652f76310000000a726f6f742d6b65792d310000001167656e657369732d6e6f6e63652d616263"
	goldenPoolID           = "ijUnc-ZQf-LJeRvkhi-0iQ"
	goldenPoolIDMin        = "b9BZHgbPy9CckfctwRuRQw"
	goldenPolicyCoreHex    = "6d616370726f76696465722f737065633034322f706f6c6963792d636f72652f763100000016696a556e632d5a51662d4c4a6552766b68692d3069510000000000000001000000200000000000000000000000000000000000000000000000000000000000000000000000000000000100000002000000076d6f64656c2d61000000076d6f64656c2d6200000005312e382e300000000b73656c665f7369676e65640100000007656e666f7263650000000000000000000000156465636c617265645f6e6f745f6578656375746564000000057265742d310000000000000001000000046e6f6e65000000000000000000000000000000000000000003e800000000000007d0"
	goldenManifestDigest   = "237806f14c4bef1a2a0ec853c0309b24fc3db7c6cd14d5d71b9e186245ead2b6"
	goldenManifestDigestV2 = "cea4a9b115f9f4d54bbedafa24fb130662990212efabf279e73fbfdad2f6dbfa"
	// Empty model allowlist: list count encodes as 0x00000000 with no elements.
	goldenEmptyAllowlistPolicyHex = "6d616370726f76696465722f737065633034322f706f6c6963792d636f72652f763100000016696a556e632d5a51662d4c4a6552766b68692d306951000000000000000100000020000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000005312e382e300000000b73656c665f7369676e65640100000007656e666f7263650000000000000000000000156465636c617265645f6e6f745f6578656375746564000000057265742d310000000000000001000000046e6f6e65000000000000000000000000000000000000000003e800000000000007d0"
	goldenEmptyAllowlistDigest    = "25ddd6d6ceb19de9d1d5ce1017dd742fc3c804c3187f8d6df2b314d5c828b59b"
)

func must(b []byte, err error) []byte {
	if err != nil {
		panic(err)
	}
	return b
}

func TestGoldenVectors(t *testing.T) {
	ic := sampleIdentity()
	if got := hex.EncodeToString(must(ic.CanonicalBytes())); got != goldenIdentityCoreHex {
		t.Fatalf("identity core bytes drifted:\n got=%s\nwant=%s", got, goldenIdentityCoreHex)
	}
	pid, err := ic.PoolID()
	if err != nil || pid != goldenPoolID {
		t.Fatalf("pool_id=%q err=%v, want %q", pid, err, goldenPoolID)
	}
	pc := samplePolicy(pid)
	if got := hex.EncodeToString(must(pc.CanonicalBytes())); got != goldenPolicyCoreHex {
		t.Fatalf("policy core bytes drifted:\n got=%s\nwant=%s", got, goldenPolicyCoreHex)
	}
	if got := hex.EncodeToString(must(pc.ManifestCoreDigest())); got != goldenManifestDigest {
		t.Fatalf("manifest_core_digest=%s, want %s", got, goldenManifestDigest)
	}
	// v2 core chains prev = v1 digest.
	pc2 := samplePolicy(pid)
	pc2.ManifestVersion = 2
	pc2.PrevManifestCoreHash = must(pc.ManifestCoreDigest())
	if got := hex.EncodeToString(must(pc2.ManifestCoreDigest())); got != goldenManifestDigestV2 {
		t.Fatalf("v2 manifest_core_digest=%s, want %s", got, goldenManifestDigestV2)
	}
}

// TestEmptyAllowlistVector pins the count-zero encoding of an empty model
// allowlist so the "no elements" branch of the list grammar is frozen too.
func TestEmptyAllowlistVector(t *testing.T) {
	pid, _ := sampleIdentity().PoolID()
	pc := samplePolicy(pid)
	pc.ModelAllowlist = nil
	if got := hex.EncodeToString(must(pc.CanonicalBytes())); got != goldenEmptyAllowlistPolicyHex {
		t.Fatalf("empty-allowlist policy bytes drifted:\n got=%s\nwant=%s", got, goldenEmptyAllowlistPolicyHex)
	}
	if got := hex.EncodeToString(must(pc.ManifestCoreDigest())); got != goldenEmptyAllowlistDigest {
		t.Fatalf("empty-allowlist digest=%s, want %s", got, goldenEmptyAllowlistDigest)
	}
	// An empty allowlist (nil) and a zero-length slice encode identically.
	pc2 := samplePolicy(pid)
	pc2.ModelAllowlist = []string{}
	if string(must(pc.CanonicalBytes())) != string(must(pc2.CanonicalBytes())) {
		t.Fatal("nil and empty allowlist encode differently")
	}
}

func TestPoolIDShape(t *testing.T) {
	pid, _ := sampleIdentity().PoolID()
	// base64url (no pad), 16 bytes -> 22 chars — matches the coordinator/gateway
	// pool_id header contract (base64url).
	if !regexp.MustCompile(`^[A-Za-z0-9_-]{22}$`).MatchString(pid) {
		t.Fatalf("pool_id %q is not 22-char base64url", pid)
	}
	// A different identity yields a different pool_id.
	min := IdentityCore{RootIssuerKeyID: "k"}
	pidMin, _ := min.PoolID()
	if pidMin != goldenPoolIDMin {
		t.Fatalf("min pool_id=%q, want %q", pidMin, goldenPoolIDMin)
	}
	if pidMin == pid {
		t.Fatal("distinct identities produced the same pool_id")
	}
}

func TestDeterministicAndSetOrdered(t *testing.T) {
	pid, _ := sampleIdentity().PoolID()
	// Encoding is deterministic across calls.
	a := must(samplePolicy(pid).CanonicalBytes())
	b := must(samplePolicy(pid).CanonicalBytes())
	if string(a) != string(b) {
		t.Fatal("policy core encoding is not deterministic")
	}
	// The model allowlist is set-ordered: input order does not affect the bytes.
	p1 := samplePolicy(pid)
	p1.ModelAllowlist = []string{"model-a", "model-b"}
	p2 := samplePolicy(pid)
	p2.ModelAllowlist = []string{"model-b", "model-a"}
	if string(must(p1.CanonicalBytes())) != string(must(p2.CanonicalBytes())) {
		t.Fatal("model allowlist ordering is not normalized")
	}
}

func TestPolicyCoreValidation(t *testing.T) {
	pid, _ := sampleIdentity().PoolID()
	// prev_manifest_core_hash must be exactly 32 bytes.
	bad := samplePolicy(pid)
	bad.PrevManifestCoreHash = []byte{0x00}
	if _, err := bad.CanonicalBytes(); err == nil {
		t.Fatal("short prev_manifest_core_hash accepted")
	}
	// duplicate allowlist entry is rejected.
	dup := samplePolicy(pid)
	dup.ModelAllowlist = []string{"model-a", "model-a"}
	if _, err := dup.CanonicalBytes(); err == nil {
		t.Fatal("duplicate allowlist entry accepted")
	}
}

func TestDigestSensitivity(t *testing.T) {
	pid, _ := sampleIdentity().PoolID()
	base := must(samplePolicy(pid).ManifestCoreDigest())
	// Every scalar field change must change the digest.
	muts := map[string]func(*PolicyCore){
		"version":       func(p *PolicyCore) { p.ManifestVersion = 99 },
		"signer_set":    func(p *PolicyCore) { p.SignerSetVersion = 99 },
		"min_binary":    func(p *PolicyCore) { p.MinBinaryVersion = "9.9.9" },
		"attestation":   func(p *PolicyCore) { p.MinAttestationTier = "hardware" },
		"encrypted_leg": func(p *PolicyCore) { p.RequireEncryptedLeg = false },
		"settlement":    func(p *PolicyCore) { p.SettlementMode = "observe" },
		"split_bps":     func(p *PolicyCore) { p.RevenueSplitBps = 500 },
		"min_members":   func(p *PolicyCore) { p.MinEligibleMembers = 3 },
		"privacy_mode":  func(p *PolicyCore) { p.PrivacyMode = "relay_blind" },
		"relay_capable": func(p *PolicyCore) { p.RelayBlindCapable = true },
		"receipt_ctr":   func(p *PolicyCore) { p.ReceiptContract = "v0.4" },
		"metadata_vis":  func(p *PolicyCore) { p.MetadataVisible = "minimal" },
		"downgrade":     func(p *PolicyCore) { p.DowngradePolicy = "reject" },
		"sticky":        func(p *PolicyCore) { p.StickyRoutingAllowed = true },
		"not_before":    func(p *PolicyCore) { p.NotBeforeUnix = 1 },
		"expires":       func(p *PolicyCore) { p.ExpiresAtUnix = 9 },
		"allowlist":     func(p *PolicyCore) { p.ModelAllowlist = []string{"model-c"} },
		"pool_id_ref":   func(p *PolicyCore) { p.PoolID = "another-pool-id-xxxxxx" },
	}
	for name, mut := range muts {
		p := samplePolicy(pid)
		mut(&p)
		if got := must(p.ManifestCoreDigest()); string(got) == string(base) {
			t.Errorf("mutation %q did not change manifest_core_digest", name)
		}
	}
}
