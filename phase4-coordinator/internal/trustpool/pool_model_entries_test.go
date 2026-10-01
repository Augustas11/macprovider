package trustpool_test

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

const (
	poolEntryGGUFHash     = "4444444444444444444444444444444444444444444444444444444444444444"
	poolEntrySnapshotHash = "5555555555555555555555555555555555555555555555555555555555555555"
)

func poolEntriesFor(poolID string) []poolmanifest.PoolModelEntry {
	return []poolmanifest.PoolModelEntry{
		{
			PoolModelID: "pool/" + poolID + "/creator-gguf", ArtifactHashAlgorithm: poolmanifest.ArtifactHashAlgorithmGGUFFileV1,
			ArtifactHash: poolEntryGGUFHash, AllowedRuntimeSources: []string{poolmanifest.RuntimeSourceLlamacppLoopback},
			License: "Apache-2.0", PaidServingAttested: true,
			Pricing:         poolmanifest.PoolModelPricing{PromptRatePerMtok: 100, PromptCacheHitRatePerMtok: 10, CompletionRatePerMtok: 300},
			DisclosureClass: poolmanifest.PoolModelDisclosureClass, MaxContextTokens: 32768,
		},
		{
			PoolModelID: "pool/" + poolID + "/creator-mlx", ArtifactHashAlgorithm: poolmanifest.ArtifactHashAlgorithmSnapshotManifestV1,
			ArtifactHash: poolEntrySnapshotHash, AllowedRuntimeSources: []string{poolmanifest.RuntimeSourceNativeMLX},
			License: "MIT", PaidServingAttested: true,
			Pricing:         poolmanifest.PoolModelPricing{PromptRatePerMtok: 50, PromptCacheHitRatePerMtok: 5, CompletionRatePerMtok: 150},
			DisclosureClass: poolmanifest.PoolModelDisclosureClass, MaxContextTokens: 8192,
		},
	}
}

func acceptAllPoolModels() poolmanifest.PoolModelAcceptanceContext {
	return poolmanifest.PoolModelAcceptanceContext{
		PricingBounds:     &poolmanifest.PoolModelPricingBounds{MaxPromptRatePerMtok: 1 << 40, MaxPromptCacheHitRatePerMtok: 1 << 40, MaxCompletionRatePerMtok: 1 << 40},
		IsCatalogModelID:  func(string) bool { return false },
		ArtifactInCatalog: func(string, string) bool { return false },
	}
}

func withPoolModels(poolID string, members []poolmanifest.AttestedMember) func(*poolmanifest.PolicyCore) {
	return func(core *poolmanifest.PolicyCore) {
		allowLlamacpp(core)
		if err := core.SetPoolExtensions(poolEntriesFor(poolID), members); err != nil {
			panic(err)
		}
	}
}

// SPEC-042-R015/R016, SPEC-022-R013.3 (#1816): the durable authority replays
// the exact pool entry and the creator's member attestation.
func TestVerifyPoolManifestClaimsFromDurableRecords(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db, trustpool.WithPoolModelAcceptance(acceptAllPoolModels))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800030000, 0).UTC()
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	members := []poolmanifest.AttestedMember{{ProviderAccountID: "acct-member-d", RuntimeClasses: []string{poolmanifest.RuntimeSourceLlamacppLoopback}}}
	v1 := signedManifestWithPolicyCoreMutation(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root, func(core *poolmanifest.PolicyCore) {
		core.SettlementMode = "enforce"
	})
	v2 := signedManifestExtendingWithPolicyCoreMutation(t, "op-manifest-2", ts.Add(3*time.Second), v1, root, withPoolModels(root.poolID, members))
	appendTrustPoolEvents(t, ctx, store,
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		v1,
		v2,
		ev("op-member-owned", ts.Add(4*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) { e.ProviderID = "provider-a" }),
	)
	state, err := store.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	if got := state.Pools[root.poolID]; got == nil || len(got.ManifestModelEntries) != 2 || len(got.ManifestAttestedMembers) != 1 {
		t.Fatalf("pool model projection = %+v", got)
	}
	// A delegated admission (written directly; the signed delegation ledger
	// is out of scope here) is never creator-owned.
	insertPromotedEvent(t, ctx, db, ev("op-member-delegated", ts.Add(5*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
		e.ProviderID = "provider-d"
		e.DelegationID = "delegation-1"
	}))

	loopback := billing.PoolOperatorAttestationClaim{
		PoolID: root.poolID, ManifestVersion: 2, ManifestCoreDigest: v2.ManifestCoreDigest,
		RuntimeSource: poolmanifest.RuntimeSourceLlamacppLoopback, PoolGeneration: 100,
		PoolOperatorAccountID: "creator-a", ProviderID: "provider-a",
		ExpectedModelHashSource:    billing.ExpectedModelHashSourcePoolManifest,
		PoolModelID:                "pool/" + root.poolID + "/creator-gguf",
		ExpectedModelHashAlgorithm: poolmanifest.ArtifactHashAlgorithmGGUFFileV1, ExpectedModelHash: poolEntryGGUFHash,
	}
	if err := store.VerifyPoolOperatorAttestation(ctx, loopback); err != nil {
		t.Fatalf("creator-owned member serving its pool entry: %v", err)
	}
	attested := loopback
	attested.ProviderID = "provider-d"
	attested.PoolMemberAccountID = "acct-member-d"
	if err := store.VerifyPoolOperatorAttestation(ctx, attested); err != nil {
		t.Fatalf("R016-attested delegated member: %v", err)
	}
	for name, mutate := range map[string]func(*billing.PoolOperatorAttestationClaim){
		"entry missing": func(c *billing.PoolOperatorAttestationClaim) { c.PoolModelID = "pool/" + root.poolID + "/absent" },
		"hash differs":  func(c *billing.PoolOperatorAttestationClaim) { c.ExpectedModelHash = poolEntrySnapshotHash },
		"algorithm differs": func(c *billing.PoolOperatorAttestationClaim) {
			c.ExpectedModelHashAlgorithm = poolmanifest.ArtifactHashAlgorithmSnapshotManifestV1
		},
		"v1 core has no entry": func(c *billing.PoolOperatorAttestationClaim) {
			c.ManifestVersion, c.ManifestCoreDigest = 1, v1.ManifestCoreDigest
		},
		"unknown source":        func(c *billing.PoolOperatorAttestationClaim) { c.ExpectedModelHashSource = "global" },
		"delegated, no account": func(c *billing.PoolOperatorAttestationClaim) { c.ProviderID = "provider-d" },
		"delegated, unattested account": func(c *billing.PoolOperatorAttestationClaim) {
			c.ProviderID, c.PoolMemberAccountID = "provider-d", "acct-other"
		},
		"owned with member account": func(c *billing.PoolOperatorAttestationClaim) { c.PoolMemberAccountID = "acct-member-d" },
		"attested at wrong runtime": func(c *billing.PoolOperatorAttestationClaim) {
			c.ProviderID, c.PoolMemberAccountID, c.RuntimeSource = "provider-d", "acct-member-d", poolmanifest.RuntimeSourceOllamaLoopback
		},
	} {
		bad := loopback
		mutate(&bad)
		if err := store.VerifyPoolOperatorAttestation(ctx, bad); !errors.Is(err, trustpool.ErrPoolOperatorAttestation) {
			t.Errorf("%s: err=%v, want ErrPoolOperatorAttestation", name, err)
		}
	}

	native := billing.PoolOperatorAttestationClaim{
		PoolID: root.poolID, ManifestVersion: 2, ManifestCoreDigest: v2.ManifestCoreDigest,
		PoolGeneration: 100, ProviderID: "provider-d",
		ExpectedModelHashSource:    billing.ExpectedModelHashSourcePoolManifest,
		PoolModelID:                "pool/" + root.poolID + "/creator-mlx",
		ExpectedModelHashAlgorithm: poolmanifest.ArtifactHashAlgorithmSnapshotManifestV1, ExpectedModelHash: poolEntrySnapshotHash,
	}
	if err := store.VerifyPoolManifestRoute(ctx, native); err != nil {
		t.Fatalf("native member serving a native pool entry: %v", err)
	}
	for name, mutate := range map[string]func(*billing.PoolOperatorAttestationClaim){
		"gguf entry on native": func(c *billing.PoolOperatorAttestationClaim) {
			c.PoolModelID = loopback.PoolModelID
			c.ExpectedModelHashAlgorithm, c.ExpectedModelHash = loopback.ExpectedModelHashAlgorithm, loopback.ExpectedModelHash
		},
		"non-member":       func(c *billing.PoolOperatorAttestationClaim) { c.ProviderID = "provider-z" },
		"before admission": func(c *billing.PoolOperatorAttestationClaim) { c.PoolGeneration = 4 },
		"loopback runtime set": func(c *billing.PoolOperatorAttestationClaim) {
			c.RuntimeSource = poolmanifest.RuntimeSourceLlamacppLoopback
		},
		"catalog source": func(c *billing.PoolOperatorAttestationClaim) { c.ExpectedModelHashSource = "" },
	} {
		bad := native
		mutate(&bad)
		if err := store.VerifyPoolManifestRoute(ctx, bad); !errors.Is(err, trustpool.ErrPoolOperatorAttestation) {
			t.Errorf("native %s: err=%v, want ErrPoolOperatorAttestation", name, err)
		}
	}
}

// SPEC-042-R015 / SPEC-005-R015: online manifest acceptance applies the
// configured pricing bounds and the catalog shadow/overlap rules; missing
// bounds fail closed; a core without entries needs none.
func TestPoolModelEntriesOnlineAcceptance(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	ts := time.Unix(1800030000, 0).UTC()
	bounds := &poolmanifest.PoolModelPricingBounds{
		MaxPromptRatePerMtok: 1000, MaxPromptCacheHitRatePerMtok: 1000, MaxCompletionRatePerMtok: 1000,
	}
	for name, tc := range map[string]struct {
		acceptance func() poolmanifest.PoolModelAcceptanceContext
		wantCode   string
	}{
		"accepted": {func() poolmanifest.PoolModelAcceptanceContext {
			return poolmanifest.PoolModelAcceptanceContext{PricingBounds: bounds, IsCatalogModelID: func(string) bool { return false }, ArtifactInCatalog: func(string, string) bool { return false }}
		}, ""},
		"no bounds configured": {nil, trustpool.PoolModelRejectPricingBounds},
		"price above ceiling": {func() poolmanifest.PoolModelAcceptanceContext {
			tight := *bounds
			tight.MaxCompletionRatePerMtok = 200
			return poolmanifest.PoolModelAcceptanceContext{PricingBounds: &tight, IsCatalogModelID: func(string) bool { return false }, ArtifactInCatalog: func(string, string) bool { return false }}
		}, trustpool.PoolModelRejectPricingBounds},
		"artifact already catalogued": {func() poolmanifest.PoolModelAcceptanceContext {
			return poolmanifest.PoolModelAcceptanceContext{PricingBounds: bounds, IsCatalogModelID: func(string) bool { return false },
				ArtifactInCatalog: func(_, hash string) bool { return hash == poolEntryGGUFHash }}
		}, trustpool.PoolModelRejectCatalogOverlap},
		"slug shadows catalog id": {func() poolmanifest.PoolModelAcceptanceContext {
			return poolmanifest.PoolModelAcceptanceContext{PricingBounds: bounds, IsCatalogModelID: func(id string) bool { return id == "creator-mlx" },
				ArtifactInCatalog: func(string, string) bool { return false }}
		}, trustpool.PoolModelRejectCatalogShadow},
	} {
		db := openTrustPoolDB(t)
		var opts []trustpool.StoreOption
		if tc.acceptance != nil {
			opts = append(opts, trustpool.WithPoolModelAcceptance(tc.acceptance))
		}
		store, err := trustpool.NewStore(db, opts...)
		if err != nil {
			t.Fatalf("%s: NewStore: %v", name, err)
		}
		root := newRootFixture(t)
		approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
		appendTrustPoolEvents(t, ctx, store,
			ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
				e.CreatorAccountID = "creator-a"
				e.ApprovalRecordID = "approval-v1"
			}),
			signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		)
		manifest := signedManifestWithPolicyCoreMutation(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root, func(core *poolmanifest.PolicyCore) {
			core.SettlementMode = "enforce"
			core.Encoding = poolmanifest.PolicyCoreEncodingV2
			withPoolModels(root.poolID, nil)(core)
		})
		_, _, _, err = store.AppendValidatedEvent(ctx, manifest)
		switch {
		case tc.wantCode == "" && err != nil:
			t.Errorf("%s: append: %v", name, err)
		case tc.wantCode != "" && (!errors.Is(err, trustpool.ErrPoolModelEntryRejected) || !strings.Contains(err.Error(), tc.wantCode)):
			t.Errorf("%s: err=%v, want %s", name, err, tc.wantCode)
		}
	}
}

// The registry carries the active core's pool models from the durable
// routeable snapshot, and the SPEC-042-R016 owner-account map is the only
// owner input: ambiguous providers get none, and a change advances the
// routing generation.
func TestRegistryPoolModelsAndOwnerAccounts(t *testing.T) {
	t.Parallel()
	r := trustpool.NewRegistry()
	entries := poolEntriesFor("QpsclmzwdJaWJTk3zowcXQ")
	members := []poolmanifest.AttestedMember{{ProviderAccountID: "acct-d", RuntimeClasses: []string{poolmanifest.RuntimeSourceLlamacppLoopback}}}
	if err := r.LoadRouteableSnapshots([]trustpool.RouteableSnapshot{{
		PoolID: "QpsclmzwdJaWJTk3zowcXQ", CreatorAccountID: "creator-a", Members: []string{"provider-a", "provider-d", "provider-x"},
		DelegatedMembers: []string{"provider-d"}, RuntimeAllowlist: []string{poolmanifest.RuntimeSourceLlamacppLoopback},
		ModelEntries: entries, AttestedMembers: members, SettlementMode: "enforce", Routeable: true, Generation: 3,
		ManifestVersion: 2, ManifestCoreDigest: hexDigest("core"),
	}}); err != nil {
		t.Fatalf("LoadRouteableSnapshots: %v", err)
	}
	before := r.Snapshot("QpsclmzwdJaWJTk3zowcXQ")
	if len(before.ModelEntries) != 2 || len(before.AttestedMembers) != 1 || len(before.MemberOwnerAccounts) != 0 {
		t.Fatalf("snapshot pool models = %+v", before)
	}
	before.ModelEntries[0].AllowedRuntimeSources[0] = "mutated"
	if r.Snapshot("QpsclmzwdJaWJTk3zowcXQ").ModelEntries[0].AllowedRuntimeSources[0] == "mutated" {
		t.Fatal("snapshot aliases the registry's model entries")
	}
	r.SetProviderOwnerAccounts(map[string][]string{"acct-d": {"provider-d"}, "acct-x": {"provider-x"}, "acct-y": {"provider-x"}})
	after := r.Snapshot("QpsclmzwdJaWJTk3zowcXQ")
	if after.MemberOwnerAccounts["provider-d"] != "acct-d" || after.MemberOwnerAccounts["provider-x"] != "" {
		t.Fatalf("owner accounts = %+v", after.MemberOwnerAccounts)
	}
	if after.Generation == before.Generation {
		t.Fatal("owner-account change did not advance the routing generation")
	}
	r.SetProviderOwnerAccounts(map[string][]string{"acct-d": {"provider-d"}, "acct-x": {"provider-x"}, "acct-y": {"provider-x"}})
	if again := r.Snapshot("QpsclmzwdJaWJTk3zowcXQ"); again.Generation != after.Generation {
		t.Fatal("an unchanged owner map advanced the generation")
	}
}
