package poolmanifest

import (
	"encoding/hex"
	"errors"
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

// --- SPEC-042-R001 policy-core/v2 (0.0.32, #1690) golden vectors ---

// samplePolicyV2 is the sample core re-encoded as v2 with the given allowlist.
func samplePolicyV2(poolID string, allowlist ...string) PolicyCore {
	pc := samplePolicy(poolID)
	pc.Encoding = PolicyCoreEncodingV2
	pc.RuntimeAllowlist = allowlist
	return pc
}

// GOLDEN VECTORS — freeze the v2 grammar next to the unchanged v1 vectors above.
const (
	goldenPolicyCoreV2EmptyHex        = "6d616370726f76696465722f737065633034322f706f6c6963792d636f72652f763200000016696a556e632d5a51662d4c4a6552766b68692d3069510000000000000001000000200000000000000000000000000000000000000000000000000000000000000000000000000000000100000002000000076d6f64656c2d61000000076d6f64656c2d6200000005312e382e300000000b73656c665f7369676e65640100000007656e666f7263650000000000000000000000156465636c617265645f6e6f745f6578656375746564000000057265742d310000000000000001000000046e6f6e65000000000000000000000000000000000000000003e800000000000007d00000000000000000"
	goldenPolicyCoreV2EmptyDigest     = "7c243fd4d761b44f9378743dba10c65e0fa8c99c280d1bb224a90e5b741919f1"
	goldenPolicyCoreV2AllowlistHex    = "6d616370726f76696465722f737065633034322f706f6c6963792d636f72652f763200000016696a556e632d5a51662d4c4a6552766b68692d3069510000000000000001000000200000000000000000000000000000000000000000000000000000000000000000000000000000000100000002000000076d6f64656c2d61000000076d6f64656c2d6200000005312e382e300000000b73656c665f7369676e65640100000007656e666f7263650000000000000000000000156465636c617265645f6e6f745f6578656375746564000000057265742d310000000000000001000000046e6f6e65000000000000000000000000000000000000000003e800000000000007d000000002000000116c6c616d616370705f6c6f6f706261636b0000000f6f6c6c616d615f6c6f6f706261636b00000000"
	goldenPolicyCoreV2AllowlistDigest = "c53cd675a6203ed47ad34e407a897dcead849d1a456a02cc644fb881ddc87fa9"
	goldenPolicyCoreV2SigMsgHex       = "6d616370726f76696465722f737065633034322f706f6c6963792d636f72652d7369672f7632c53cd675a6203ed47ad34e407a897dcead849d1a456a02cc644fb881ddc87fa9"
)

func TestPolicyCoreV2GoldenVectors(t *testing.T) {
	pid, _ := sampleIdentity().PoolID()
	empty := samplePolicyV2(pid)
	if got := hex.EncodeToString(must(empty.CanonicalBytes())); got != goldenPolicyCoreV2EmptyHex {
		t.Fatalf("v2 empty-allowlist bytes drifted:\n got=%s\nwant=%s", got, goldenPolicyCoreV2EmptyHex)
	}
	emptyDigest := hex.EncodeToString(must(empty.ManifestCoreDigest()))
	if emptyDigest != goldenPolicyCoreV2EmptyDigest {
		t.Fatalf("v2 empty-allowlist digest=%s, want %s", emptyDigest, goldenPolicyCoreV2EmptyDigest)
	}
	// Same fields, different domain tag: the v2 digest differs from v1.
	if emptyDigest == goldenManifestDigest {
		t.Fatal("v2 core with an empty allowlist digests like the v1 core")
	}
	// The v1 golden vector is unchanged by the v2 encoder.
	if got := hex.EncodeToString(must(samplePolicy(pid).CanonicalBytes())); got != goldenPolicyCoreHex {
		t.Fatal("v1 bytes changed")
	}
	allow := samplePolicyV2(pid, RuntimeSourceLlamacppLoopback, RuntimeSourceOllamaLoopback)
	if got := hex.EncodeToString(must(allow.CanonicalBytes())); got != goldenPolicyCoreV2AllowlistHex {
		t.Fatalf("v2 allowlist bytes drifted:\n got=%s\nwant=%s", got, goldenPolicyCoreV2AllowlistHex)
	}
	allowDigest := must(allow.ManifestCoreDigest())
	if got := hex.EncodeToString(allowDigest); got != goldenPolicyCoreV2AllowlistDigest {
		t.Fatalf("v2 allowlist digest=%s, want %s", got, goldenPolicyCoreV2AllowlistDigest)
	}
	msg := must(allow.SigningMessage())
	if got := hex.EncodeToString(msg); got != goldenPolicyCoreV2SigMsgHex {
		t.Fatalf("v2 signing message drifted:\n got=%s\nwant=%s", got, goldenPolicyCoreV2SigMsgHex)
	}
	if got := hex.EncodeToString(must(PolicyCoreSigningMessageV2(allowDigest))); got != goldenPolicyCoreV2SigMsgHex {
		t.Fatal("PolicyCoreSigningMessageV2 disagrees with SigningMessage")
	}
	if !allow.AllowsRuntimeSource(RuntimeSourceLlamacppLoopback) || allow.AllowsRuntimeSource("mlx_cache") {
		t.Fatal("AllowsRuntimeSource wrong for the v2 allowlist vector")
	}
	if empty.AllowsRuntimeSource(RuntimeSourceLlamacppLoopback) || samplePolicy(pid).AllowsRuntimeSource(RuntimeSourceLlamacppLoopback) {
		t.Fatal("v1 core or empty v2 allowlist must mean native MLX only")
	}
}

func TestPolicyCoreV2RejectionVectors(t *testing.T) {
	pid, _ := sampleIdentity().PoolID()
	cases := map[string]struct {
		mut  func(*PolicyCore)
		want error
	}{
		"allowlist unsorted": {func(p *PolicyCore) {
			p.RuntimeAllowlist = []string{RuntimeSourceOllamaLoopback, RuntimeSourceLlamacppLoopback}
		}, errRuntimeAllowlistOrder},
		"allowlist duplicated": {func(p *PolicyCore) {
			p.RuntimeAllowlist = []string{RuntimeSourceLlamacppLoopback, RuntimeSourceLlamacppLoopback}
		}, errRuntimeAllowlistOrder},
		"allowlist mlx_cache": {func(p *PolicyCore) { p.RuntimeAllowlist = []string{"mlx_cache"} }, errRuntimeAllowlistValue},
		"allowlist lmstudio":  {func(p *PolicyCore) { p.RuntimeAllowlist = []string{"lmstudio_loopback"} }, errRuntimeAllowlistValue},
		"allowlist openai":    {func(p *PolicyCore) { p.RuntimeAllowlist = []string{"openai_compatible_loopback"} }, errRuntimeAllowlistValue},
		"allowlist unknown":   {func(p *PolicyCore) { p.RuntimeAllowlist = []string{"vllm"} }, errRuntimeAllowlistValue},
		"allowlist under observe": {func(p *PolicyCore) {
			p.RuntimeAllowlist = []string{RuntimeSourceLlamacppLoopback}
			p.SettlementMode = "observe"
		}, errRuntimeAllowlistObserve},
		"unknown extension": {func(p *PolicyCore) {
			p.Extensions = []PolicyExtension{{ID: "relay_blind/v1", Body: []byte{1}}}
		}, errExtensionUnknown},
		"extension grammar": {func(p *PolicyCore) {
			p.Extensions = []PolicyExtension{{ID: "Relay/v1"}}
		}, errExtensionGrammar},
		"extension version zero": {func(p *PolicyCore) {
			p.Extensions = []PolicyExtension{{ID: "relay_blind/v0"}}
		}, errExtensionGrammar},
		"extensions unsorted": {func(p *PolicyCore) {
			p.Extensions = []PolicyExtension{{ID: "b_ext/v1"}, {ID: "a_ext/v1"}}
		}, errExtensionOrder},
		"extensions duplicated": {func(p *PolicyCore) {
			p.Extensions = []PolicyExtension{{ID: "a_ext/v1"}, {ID: "a_ext/v1"}}
		}, errExtensionOrder},
		"unknown encoding": {func(p *PolicyCore) { p.Encoding = 3 }, errPolicyEncoding},
	}
	for name, tc := range cases {
		p := samplePolicyV2(pid)
		tc.mut(&p)
		if err := p.ValidateAcceptance(); !errors.Is(err, tc.want) {
			t.Errorf("%s: err=%v, want %v", name, err, tc.want)
		}
	}
	// Grammar failures have no canonical preimage at all.
	for _, name := range []string{"allowlist unsorted", "allowlist duplicated", "extension grammar", "extensions unsorted", "extensions duplicated", "unknown encoding"} {
		p := samplePolicyV2(pid)
		cases[name].mut(&p)
		if _, err := p.CanonicalBytes(); !errors.Is(err, cases[name].want) {
			t.Errorf("%s: CanonicalBytes err=%v, want %v", name, err, cases[name].want)
		}
	}
	// A v1 core can never carry the v2 fields.
	v1 := samplePolicy(pid)
	v1.RuntimeAllowlist = []string{RuntimeSourceLlamacppLoopback}
	if _, err := v1.CanonicalBytes(); !errors.Is(err, errV1CarriesV2Fields) {
		t.Fatalf("v1 core with a runtime_allowlist: err=%v", err)
	}
	v1 = samplePolicy(pid)
	v1.Extensions = []PolicyExtension{{ID: "a_ext/v1"}}
	if _, err := v1.CanonicalBytes(); !errors.Is(err, errV1CarriesV2Fields) {
		t.Fatalf("v1 core with extensions: err=%v", err)
	}
	// An explicit v1 encoding is byte-identical to the zero value.
	explicit := samplePolicy(pid)
	explicit.Encoding = PolicyCoreEncodingV1
	if hex.EncodeToString(must(explicit.CanonicalBytes())) != goldenPolicyCoreHex {
		t.Fatal("explicit v1 encoding changed the v1 bytes")
	}
	// Every v2 field change moves the digest.
	base := must(samplePolicyV2(pid).ManifestCoreDigest())
	loosened := must(samplePolicyV2(pid, RuntimeSourceLlamacppLoopback).ManifestCoreDigest())
	if string(base) == string(loosened) {
		t.Fatal("adding a runtime to the allowlist did not change manifest_core_digest")
	}
}
