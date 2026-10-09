package poolmanifest

import (
	"crypto/ed25519"
	"encoding/hex"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"
)

// --- SPEC-042-R015/R016 pool extensions (#1816) ---

const (
	testGGUFHash     = "1111111111111111111111111111111111111111111111111111111111111111"
	testSnapshotHash = "2222222222222222222222222222222222222222222222222222222222222222"
)

func sampleEntries(poolID string) []PoolModelEntry {
	return []PoolModelEntry{
		{
			PoolModelID: "pool/" + poolID + "/mistral-small-q4", ArtifactHashAlgorithm: ArtifactHashAlgorithmGGUFFileV1,
			ArtifactHash: testGGUFHash, AllowedRuntimeSources: []string{RuntimeSourceLlamacppLoopback, RuntimeSourceOllamaLoopback},
			License: "Apache-2.0", PaidServingAttested: true,
			Pricing:         PoolModelPricing{PromptRatePerMtok: 100, PromptCacheHitRatePerMtok: 10, CompletionRatePerMtok: 300},
			DisclosureClass: PoolModelDisclosureClass, MaxContextTokens: 32768,
		},
		{
			PoolModelID: "pool/" + poolID + "/tiny-mlx", ArtifactHashAlgorithm: ArtifactHashAlgorithmSnapshotManifestV1,
			ArtifactHash: testSnapshotHash, AllowedRuntimeSources: []string{RuntimeSourceNativeMLX, RuntimeSourceMLXLMLoopback},
			License: "LicenseRef-Creator-Weights-1.0", PaidServingAttested: true,
			Pricing:         PoolModelPricing{PromptRatePerMtok: 50, PromptCacheHitRatePerMtok: 50, CompletionRatePerMtok: 150},
			DisclosureClass: PoolModelDisclosureClass, MaxContextTokens: 8192,
		},
	}
}

func sampleMembers() []AttestedMember {
	return []AttestedMember{
		{ProviderAccountID: "acct-member-a", RuntimeClasses: []string{RuntimeSourceLlamacppLoopback}},
		{ProviderAccountID: "acct-member-b", RuntimeClasses: []string{RuntimeSourceMLXLMLoopback, RuntimeSourceOllamaLoopback}},
	}
}

// rawPoolCore is the v2 sample core with the three loopback classes the
// sample entries name, carrying the given lists encoded WITHOUT validation
// (acceptance must catch every rule).
func rawPoolCore(t *testing.T, poolID string, entries []PoolModelEntry, members []AttestedMember) PolicyCore {
	t.Helper()
	pc := samplePolicyV2(poolID, RuntimeSourceLlamacppLoopback, RuntimeSourceMLXLMLoopback, RuntimeSourceOllamaLoopback)
	// pool_attested_members/v1 sorts before pool_model_entries/v1.
	if len(members) > 0 {
		pc.Extensions = append(pc.Extensions, PolicyExtension{ID: ExtensionPoolAttestedMembersV1, Body: must(EncodeAttestedMembers(members))})
	}
	if len(entries) > 0 {
		pc.Extensions = append(pc.Extensions, PolicyExtension{ID: ExtensionPoolModelEntriesV1, Body: must(EncodePoolModelEntries(entries))})
	}
	return pc
}

// GOLDEN VECTORS — freeze both extension bodies and the digests of v2 cores
// carrying them. The v1/v2 vectors without extensions (manifest_test.go) are
// unchanged by this feature.
const (
	goldenPoolModelEntriesBodyHex = "000000020000002c706f6f6c2f696a556e632d5a51662d4c4a6552766b68692d3069512f6d69737472616c2d736d616c6c2d7134000000186d616370726f76696465722e676775662d66696c652e7631000000403131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313100000002000000116c6c616d616370705f6c6f6f706261636b0000000f6f6c6c616d615f6c6f6f706261636b0000000a4170616368652d322e30010000000000000064000000000000000a000000000000012c00000018706f6f6c5f61747465737465645f756e7665726966696564000000000000800000000024706f6f6c2f696a556e632d5a51662d4c4a6552766b68692d3069512f74696e792d6d6c78000000206d616370726f76696465722e736e617073686f742d6d616e69666573742e7631000000403232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323200000002000000096d6c785f63616368650000000e6d6c786c6d5f6c6f6f706261636b0000001e4c6963656e73655265662d43726561746f722d576569676874732d312e300100000000000000320000000000000032000000000000009600000018706f6f6c5f61747465737465645f756e76657269666965640000000000002000"
	goldenAttestedMembersBodyHex  = "000000020000000d616363742d6d656d6265722d6100000001000000116c6c616d616370705f6c6f6f706261636b0000000d616363742d6d656d6265722d62000000020000000e6d6c786c6d5f6c6f6f706261636b0000000f6f6c6c616d615f6c6f6f706261636b"
	goldenPoolEntriesCoreDigest   = "2b3124d85499484c1907a65b4621adecef23562d908b3c5c67bace38d0815a4c"
	goldenPoolMembersCoreDigest   = "fc2656a5f572a6a72b0b7de651e83d87c84e79c8ced5ad6e20fb8ed9ebd55d8f"
	goldenPoolBothCoreDigest      = "de9b0fc5303d8dcac2fccf230371ab69a19eeba8e06d4c4afdae626723405415"
)

func TestPoolExtensionGoldenVectors(t *testing.T) {
	pid, _ := sampleIdentity().PoolID()
	if got := hex.EncodeToString(must(EncodePoolModelEntries(sampleEntries(pid)))); got != goldenPoolModelEntriesBodyHex {
		t.Fatalf("pool_model_entries/v1 body drifted:\n got=%s\nwant=%s", got, goldenPoolModelEntriesBodyHex)
	}
	if got := hex.EncodeToString(must(EncodeAttestedMembers(sampleMembers()))); got != goldenAttestedMembersBodyHex {
		t.Fatalf("pool_attested_members/v1 body drifted:\n got=%s\nwant=%s", got, goldenAttestedMembersBodyHex)
	}
	for name, tc := range map[string]struct {
		entries []PoolModelEntry
		members []AttestedMember
		want    string
	}{
		"entries": {sampleEntries(pid), nil, goldenPoolEntriesCoreDigest},
		"members": {nil, sampleMembers(), goldenPoolMembersCoreDigest},
		"both":    {sampleEntries(pid), sampleMembers(), goldenPoolBothCoreDigest},
	} {
		core := samplePolicyV2(pid, RuntimeSourceLlamacppLoopback, RuntimeSourceMLXLMLoopback, RuntimeSourceOllamaLoopback)
		if err := core.SetPoolExtensions(tc.entries, tc.members); err != nil {
			t.Fatalf("%s: SetPoolExtensions: %v", name, err)
		}
		if !reflect.DeepEqual(core, rawPoolCore(t, pid, tc.entries, tc.members)) {
			t.Fatalf("%s: SetPoolExtensions disagrees with the canonical extension order", name)
		}
		if err := core.ValidateAcceptance(); err != nil {
			t.Fatalf("%s: core rejected: %v", name, err)
		}
		digest := must(core.ManifestCoreDigest())
		if got := hex.EncodeToString(digest); got != tc.want {
			t.Errorf("%s: core digest=%s, want %s", name, got, tc.want)
		}
		// The signing message stays the v2 policy-core-sig tag.
		if hex.EncodeToString(must(core.SigningMessage())) != hex.EncodeToString(must(PolicyCoreSigningMessageV2(digest))) {
			t.Errorf("%s: signing message is not policy-core-sig/v2 || digest", name)
		}
		gotEntries, err := core.PoolModelEntries()
		if err != nil || !reflect.DeepEqual(gotEntries, tc.entries) {
			t.Errorf("%s: PoolModelEntries=%+v err=%v", name, gotEntries, err)
		}
		gotMembers, err := core.PoolAttestedMembers()
		if err != nil || !reflect.DeepEqual(gotMembers, tc.members) {
			t.Errorf("%s: PoolAttestedMembers=%+v err=%v", name, gotMembers, err)
		}
	}
	// v1/v2 cores without the extensions keep their exact golden bytes.
	if hex.EncodeToString(must(samplePolicyV2(pid).CanonicalBytes())) != goldenPolicyCoreV2EmptyHex ||
		hex.EncodeToString(must(samplePolicy(pid).CanonicalBytes())) != goldenPolicyCoreHex {
		t.Fatal("v1/v2 bytes without pool extensions changed")
	}
	// SetPoolExtensions with empty lists removes them.
	core := rawPoolCore(t, pid, sampleEntries(pid), sampleMembers())
	if err := core.SetPoolExtensions(nil, nil); err != nil || len(core.Extensions) != 0 {
		t.Fatalf("clearing pool extensions: %v %+v", err, core.Extensions)
	}
	// Every trust-bearing field moves the digest.
	base := hex.EncodeToString(must(rawPoolCore(t, pid, sampleEntries(pid), sampleMembers()).ManifestCoreDigest()))
	for name, mut := range map[string]func([]PoolModelEntry, []AttestedMember) []AttestedMember{
		"price": func(e []PoolModelEntry, m []AttestedMember) []AttestedMember {
			e[0].Pricing.CompletionRatePerMtok++
			return m
		},
		"cache": func(e []PoolModelEntry, m []AttestedMember) []AttestedMember {
			e[0].Pricing.PromptCacheHitRatePerMtok--
			return m
		},
		"hash": func(e []PoolModelEntry, m []AttestedMember) []AttestedMember {
			e[0].ArtifactHash = strings.Repeat("3", 64)
			return m
		},
		"context": func(e []PoolModelEntry, m []AttestedMember) []AttestedMember { e[0].MaxContextTokens++; return m },
		"license": func(e []PoolModelEntry, m []AttestedMember) []AttestedMember { e[0].License = "MIT"; return m },
		"member":  func(e []PoolModelEntry, m []AttestedMember) []AttestedMember { return m[:1] },
	} {
		e := sampleEntries(pid)
		m := mut(e, sampleMembers())
		if hex.EncodeToString(must(rawPoolCore(t, pid, e, m).ManifestCoreDigest())) == base {
			t.Errorf("%s: change did not move the digest", name)
		}
	}
}

func TestPoolExtensionSignature(t *testing.T) {
	ss, privs := signerSet3(1)
	pid, _ := sampleIdentity().PoolID()
	core := rawPoolCore(t, pid, sampleEntries(pid), sampleMembers())
	core.SignerSetVersion = ss.Version
	core.NotBeforeUnix = ss.NotBeforeUnix
	msg := must(core.SigningMessage())
	sig := []Signature{{KeyID: ss.Keys[0].KeyID, Sig: ed25519.Sign(privs[0], msg)}}
	if err := VerifyPolicyCore(core, sig, ss); err != nil {
		t.Fatalf("signed pool-extension core rejected: %v", err)
	}
	// Re-pricing one entry after signing breaks the signature.
	entries := sampleEntries(pid)
	entries[0].Pricing.PromptRatePerMtok = 99
	if err := core.SetPoolExtensions(entries, sampleMembers()); err != nil {
		t.Fatal(err)
	}
	if err := VerifyPolicyCore(core, sig, ss); !errors.Is(err, errBadSignature) {
		t.Fatalf("re-priced entry under the old signature: err=%v", err)
	}
}

func TestPoolExtensionRejectionVectors(t *testing.T) {
	pid, _ := sampleIdentity().PoolID()
	entry := func(f func(*PoolModelEntry)) func([]PoolModelEntry, []AttestedMember) {
		return func(e []PoolModelEntry, _ []AttestedMember) { f(&e[0]) }
	}
	member := func(f func([]AttestedMember)) func([]PoolModelEntry, []AttestedMember) {
		return func(_ []PoolModelEntry, m []AttestedMember) { f(m) }
	}
	cases := map[string]struct {
		mut  func([]PoolModelEntry, []AttestedMember)
		want error
	}{
		"entries unsorted":    {func(e []PoolModelEntry, _ []AttestedMember) { e[0], e[1] = e[1], e[0] }, errModelEntriesOrder},
		"entries dup id":      {func(e []PoolModelEntry, _ []AttestedMember) { e[1].PoolModelID = e[0].PoolModelID }, errModelEntriesOrder},
		"entries dup hash":    {func(e []PoolModelEntry, _ []AttestedMember) { e[1].ArtifactHash = testGGUFHash }, errModelEntryDupHash},
		"id grammar":          {entry(func(x *PoolModelEntry) { x.PoolModelID = "pool/" + pid + "/Upper" }), errModelEntryID},
		"id namespace":        {entry(func(x *PoolModelEntry) { x.PoolModelID = "mistral-small-q4" }), errModelEntryID},
		"id other pool":       {entry(func(x *PoolModelEntry) { x.PoolModelID = "pool/AAAAAAAAAAAAAAAAAAAAAA/mistral-small-q4" }), errModelEntryPoolID},
		"algorithm":           {entry(func(x *PoolModelEntry) { x.ArtifactHashAlgorithm = "sha256" }), errModelEntryAlgorithm},
		"hash upper":          {entry(func(x *PoolModelEntry) { x.ArtifactHash = strings.Repeat("A", 64) }), errModelEntryHash},
		"hash short":          {entry(func(x *PoolModelEntry) { x.ArtifactHash = "abc" }), errModelEntryHash},
		"runtimes empty":      {entry(func(x *PoolModelEntry) { x.AllowedRuntimeSources = nil }), errModelEntryRuntimes},
		"runtimes unsorted":   {entry(func(x *PoolModelEntry) { x.AllowedRuntimeSources = []string{"ollama_loopback", "llamacpp_loopback"} }), errModelEntryRuntimes},
		"runtime unlisted":    {entry(func(x *PoolModelEntry) { x.AllowedRuntimeSources = []string{RuntimeSourceLMStudioLoopback} }), errModelEntryRuntimes},
		"gguf on native":      {entry(func(x *PoolModelEntry) { x.AllowedRuntimeSources = []string{RuntimeSourceNativeMLX} }), errModelEntryPairing},
		"gguf on mlxlm":       {entry(func(x *PoolModelEntry) { x.AllowedRuntimeSources = []string{RuntimeSourceMLXLMLoopback} }), errModelEntryPairing},
		"license unknown":     {entry(func(x *PoolModelEntry) { x.License = "Llama-Community" }), errModelEntryLicense},
		"license ref":         {entry(func(x *PoolModelEntry) { x.License = "LicenseRef-" }), errModelEntryLicense},
		"paid not attested":   {entry(func(x *PoolModelEntry) { x.PaidServingAttested = false }), errModelEntryPaidServing},
		"price overflow":      {entry(func(x *PoolModelEntry) { x.Pricing.CompletionRatePerMtok = 1 << 63 }), errModelEntryPriceRange},
		"cache above prompt":  {entry(func(x *PoolModelEntry) { x.Pricing.PromptCacheHitRatePerMtok = x.Pricing.PromptRatePerMtok + 1 }), errModelEntryPriceRange},
		"disclosure":          {entry(func(x *PoolModelEntry) { x.DisclosureClass = "network_verified" }), errModelEntryDisclosure},
		"context zero":        {entry(func(x *PoolModelEntry) { x.MaxContextTokens = 0 }), errModelEntryContext},
		"context huge":        {entry(func(x *PoolModelEntry) { x.MaxContextTokens = MaxPoolModelContext + 1 }), errModelEntryContext},
		"members unsorted":    {member(func(m []AttestedMember) { m[0], m[1] = m[1], m[0] }), errAttestedMembersOrder},
		"members dup":         {member(func(m []AttestedMember) { m[1].ProviderAccountID = m[0].ProviderAccountID }), errAttestedMembersOrder},
		"member runtime none": {member(func(m []AttestedMember) { m[0].RuntimeClasses = nil }), errAttestedMemberRuntimes},
		"member runtime out":  {member(func(m []AttestedMember) { m[0].RuntimeClasses = []string{RuntimeSourceOMLXLoopback} }), errAttestedMemberRuntimes},
		"member native":       {member(func(m []AttestedMember) { m[0].RuntimeClasses = []string{RuntimeSourceNativeMLX} }), errAttestedMemberRuntimes},
		"member account":      {member(func(m []AttestedMember) { m[0].ProviderAccountID = " bad" }), errAttestedMemberAccount},
	}
	for name, tc := range cases {
		e, m := sampleEntries(pid), sampleMembers()
		tc.mut(e, m)
		if err := rawPoolCore(t, pid, e, m).ValidateAcceptance(); !errors.Is(err, tc.want) {
			t.Errorf("%s: err=%v, want %v", name, err, tc.want)
		}
	}
	// The 257th entry and the 1025th member are rejected by the codec itself.
	var big []PoolModelEntry
	for i := 0; i <= MaxPoolModelEntries; i++ {
		x := sampleEntries(pid)[0]
		x.PoolModelID = fmt.Sprintf("pool/%s/m%04d", pid, i)
		x.ArtifactHash = fmt.Sprintf("%064x", i+1)
		big = append(big, x)
	}
	if _, err := EncodePoolModelEntries(big); !errors.Is(err, errModelEntriesBound) {
		t.Fatalf("257 entries: err=%v", err)
	}
	if _, err := EncodePoolModelEntries(big[:MaxPoolModelEntries]); err != nil {
		t.Fatalf("256 entries: err=%v", err)
	}
	var many []AttestedMember
	for i := 0; i <= MaxAttestedMembers; i++ {
		many = append(many, AttestedMember{ProviderAccountID: fmt.Sprintf("acct-%05d", i), RuntimeClasses: []string{RuntimeSourceLlamacppLoopback}})
	}
	if _, err := EncodeAttestedMembers(many); !errors.Is(err, errAttestedMembersBound) {
		t.Fatalf("1025 members: err=%v", err)
	}
	// Entries require enforce: a native-only entry under observe (no
	// runtime allowlist) is still rejected.
	native := sampleEntries(pid)[1]
	native.AllowedRuntimeSources = []string{RuntimeSourceNativeMLX}
	observe := samplePolicyV2(pid)
	observe.SettlementMode = "observe"
	if err := observe.SetPoolExtensions([]PoolModelEntry{native}, nil); err != nil {
		t.Fatal(err)
	}
	if err := observe.ValidateAcceptance(); !errors.Is(err, errModelEntriesObserve) {
		t.Fatalf("entries under observe: err=%v", err)
	}
	observe.SettlementMode = "enforce"
	if err := observe.ValidateAcceptance(); err != nil {
		t.Fatalf("native-only snapshot entry with no runtime allowlist: %v", err)
	}
	// A non-canonical or trailing body is rejected.
	trailing := rawPoolCore(t, pid, sampleEntries(pid), nil)
	trailing.Extensions[0].Body = append(trailing.Extensions[0].Body, 0)
	if err := trailing.ValidateAcceptance(); !errors.Is(err, errExtensionBody) {
		t.Fatalf("trailing body byte: err=%v", err)
	}
	empty := samplePolicyV2(pid)
	empty.Extensions = []PolicyExtension{{ID: ExtensionPoolModelEntriesV1, Body: []byte{0, 0, 0, 0}}}
	if err := empty.ValidateAcceptance(); !errors.Is(err, errExtensionEmptyList) {
		t.Fatalf("empty list body: err=%v", err)
	}
	// Any other extension id stays rejected.
	other := samplePolicyV2(pid)
	other.Extensions = []PolicyExtension{{ID: "pool_model_entries/v2", Body: []byte{1}}}
	if err := other.ValidateAcceptance(); !errors.Is(err, errExtensionUnknown) {
		t.Fatalf("unknown extension version: err=%v", err)
	}
	// A v1 core can never carry the pool extensions.
	v1 := samplePolicy(pid)
	if err := v1.SetPoolExtensions(sampleEntries(pid), nil); !errors.Is(err, errV1CarriesV2Fields) {
		t.Fatalf("v1 SetPoolExtensions: err=%v", err)
	}
}

func TestPoolModelAcceptanceContext(t *testing.T) {
	pid, _ := sampleIdentity().PoolID()
	core := rawPoolCore(t, pid, sampleEntries(pid), nil)
	bounds := PoolModelPricingBounds{
		MinPromptRatePerMtok: 50, MaxPromptRatePerMtok: 100,
		MinPromptCacheHitRatePerMtok: 10, MaxPromptCacheHitRatePerMtok: 50,
		MinCompletionRatePerMtok: 150, MaxCompletionRatePerMtok: 300,
	}
	ok := PoolModelAcceptanceContext{
		PricingBounds:     &bounds,
		IsCatalogModelID:  func(string) bool { return false },
		ArtifactInCatalog: func(string, string, []string) bool { return false },
	}
	if err := core.ValidatePoolModelAcceptance(ok); err != nil {
		t.Fatalf("inclusive bounds rejected: %v", err)
	}
	missing := ok
	missing.PricingBounds = nil
	if err := core.ValidatePoolModelAcceptance(missing); !errors.Is(err, ErrPoolModelPricingBounds) {
		t.Fatalf("missing bounds must fail closed: %v", err)
	}
	for name, mut := range map[string]func(*PoolModelPricingBounds){
		"completion ceiling": func(b *PoolModelPricingBounds) { b.MaxCompletionRatePerMtok = 299 },
		"prompt floor":       func(b *PoolModelPricingBounds) { b.MinPromptRatePerMtok = 51 },
		"cache ceiling":      func(b *PoolModelPricingBounds) { b.MaxPromptCacheHitRatePerMtok = 49 },
		"inverted":           func(b *PoolModelPricingBounds) { b.MinPromptRatePerMtok = 101 },
		"negative":           func(b *PoolModelPricingBounds) { b.MinCompletionRatePerMtok = -1 },
	} {
		b := bounds
		mut(&b)
		c := ok
		c.PricingBounds = &b
		if err := core.ValidatePoolModelAcceptance(c); !errors.Is(err, ErrPoolModelPricingBounds) {
			t.Errorf("%s: err=%v", name, err)
		}
	}
	shadow := ok
	shadow.IsCatalogModelID = func(id string) bool { return id == "mistral-small-q4" }
	if err := core.ValidatePoolModelAcceptance(shadow); !errors.Is(err, ErrPoolModelShadowsCatalog) {
		t.Fatalf("slug shadowing a catalog id accepted: %v", err)
	}
	overlap := ok
	overlap.ArtifactInCatalog = func(alg, hash string, runtimes []string) bool {
		return alg == ArtifactHashAlgorithmGGUFFileV1 && hash == testGGUFHash && len(runtimes) == 2
	}
	if err := core.ValidatePoolModelAcceptance(overlap); !errors.Is(err, ErrPoolModelCatalogOverlap) {
		t.Fatalf("artifact already in catalog accepted: %v", err)
	}
	if err := samplePolicyV2(pid).ValidatePoolModelAcceptance(PoolModelAcceptanceContext{}); err != nil {
		t.Fatalf("a core without entries needs no context: %v", err)
	}
	if poolID, slug, ok := ParsePoolModelID("pool/" + pid + "/tiny-mlx"); !ok || poolID != pid || slug != "tiny-mlx" {
		t.Fatal("ParsePoolModelID failed")
	}
}

func TestManifestSnapshotPoolExtensionsRoundTrip(t *testing.T) {
	root, entries, _ := genesisAuthLog(t)
	v1 := policyCore(t, 1, GenesisPrevHash(), 1000, 2000)
	v2 := policyCore(t, 2, must(v1.ManifestCoreDigest()), 2000, 3000)
	v2.Encoding = PolicyCoreEncodingV2
	v2.RuntimeAllowlist = []string{RuntimeSourceLlamacppLoopback, RuntimeSourceMLXLMLoopback, RuntimeSourceOllamaLoopback}
	if err := v2.SetPoolExtensions(sampleEntries(v2.PoolID), sampleMembers()); err != nil {
		t.Fatal(err)
	}
	snap := ManifestSnapshot{
		IdentityCore: sampleIdentity(), RootIssuerKey: root, AuthorityLog: entries,
		Policies: []AcceptedPolicyRecord{
			{SignedCore: signPolicy2of3Any(t, v1), AcceptedAtUnix: 1500},
			{SignedCore: signPolicy2of3Any(t, v2), AcceptedAtUnix: 2500},
		},
	}
	got, err := ParseManifestSnapshot(must(snap.CanonicalBytes()))
	if err != nil || !reflect.DeepEqual(got, snap) {
		t.Fatalf("round-trip: err=%v", err)
	}
	rec, err := ReconstructPool(got)
	if err != nil {
		t.Fatalf("ReconstructPool: %v", err)
	}
	active, err := rec.PolicyHistory.ActivePolicy(2500)
	if err != nil {
		t.Fatal(err)
	}
	if gotEntries, err := active.PoolModelEntries(); err != nil || len(gotEntries) != 2 {
		t.Fatalf("active entries=%+v err=%v", gotEntries, err)
	}
	// A successor removing every entry is a plain new policy; the removed
	// entries do not resurface.
	v3 := policyCore(t, 3, must(v2.ManifestCoreDigest()), 3000, 4000)
	v3.Encoding = PolicyCoreEncodingV2
	snap.Policies = append(snap.Policies, AcceptedPolicyRecord{SignedCore: signPolicy2of3Any(t, v3), AcceptedAtUnix: 3500})
	rec, err = ReconstructPool(snap)
	if err != nil {
		t.Fatalf("successor without entries rejected: %v", err)
	}
	latest, _ := rec.PolicyHistory.ActivePolicy(3500)
	if e, _ := latest.PoolModelEntries(); len(e) != 0 {
		t.Fatal("removed entries resurfaced")
	}
	// Rolling back to the entry-bearing core (lower version) is rejected.
	rollback := snap
	rollback.Policies = append(append([]AcceptedPolicyRecord(nil), snap.Policies...), snap.Policies[1])
	if _, err := ReconstructPool(rollback); !errors.Is(err, errPolicyRollback) {
		t.Fatalf("manifest rollback resurrecting entries: err=%v", err)
	}
}

// #1880: Violation names the first broken bound and its configured value, and
// the acceptance error carries them while staying ErrPoolModelPricingBounds.
func TestPoolModelPricingBoundsViolation(t *testing.T) {
	b := PoolModelPricingBounds{MinPromptRatePerMtok: 10, MaxPromptRatePerMtok: 100, MaxPromptCacheHitRatePerMtok: 50, MinCompletionRatePerMtok: 5, MaxCompletionRatePerMtok: 200}
	for _, tc := range []struct {
		p     PoolModelPricing
		bound string
		limit int64
	}{
		{PoolModelPricing{PromptRatePerMtok: 9, CompletionRatePerMtok: 10}, "min_prompt_rate_per_mtok", 10},
		{PoolModelPricing{PromptRatePerMtok: 101, CompletionRatePerMtok: 10}, "max_prompt_rate_per_mtok", 100},
		{PoolModelPricing{PromptRatePerMtok: 50, PromptCacheHitRatePerMtok: 51, CompletionRatePerMtok: 10}, "max_prompt_cache_hit_rate_per_mtok", 50},
		{PoolModelPricing{PromptRatePerMtok: 50, CompletionRatePerMtok: 4}, "min_completion_rate_per_mtok", 5},
		{PoolModelPricing{PromptRatePerMtok: 50, CompletionRatePerMtok: 1 << 63}, "max_completion_rate_per_mtok", 200},
	} {
		bound, limit, ok := b.Violation(tc.p)
		if !ok || bound != tc.bound || limit != tc.limit || b.Contains(tc.p) {
			t.Fatalf("Violation(%+v) = %q %d %v, want %q %d", tc.p, bound, limit, ok, tc.bound, tc.limit)
		}
	}
	if _, _, ok := b.Violation(PoolModelPricing{PromptRatePerMtok: 50, CompletionRatePerMtok: 100}); ok {
		t.Fatal("in-bounds pricing reported a violation")
	}
	err := error(&PoolModelPricingBoundsError{PoolModelID: "pool/x/y", Bound: "max_prompt_rate_per_mtok", Limit: 100})
	if !errors.Is(err, ErrPoolModelPricingBounds) || PoolModelRejectCode(err) != RejectCodePricingOutOfBounds {
		t.Fatalf("bounds error classification: %v", err)
	}
}
