package trustpool

import (
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
)

// SPEC-042-R001: routing projects the policy core ACTIVE at the route-gate
// instant, never simply the highest accepted version.
func TestRouteableSnapshotsUseActivePolicyWindow(t *testing.T) {
	v1Start := time.Unix(1_000, 0).UTC()
	v1End := time.Unix(2_000, 0).UTC()
	v2Start := time.Unix(3_000, 0).UTC()
	v2End := time.Unix(4_000, 0).UTC()
	state := func(at time.Time) *ReconstructedState {
		p := &ReconstructedPoolState{
			PoolID:                     "pool-window",
			Lifecycle:                  LifecycleActive,
			Generation:                 5,
			Members:                    map[string]bool{"provider-a": true},
			Revoked:                    map[string]bool{},
			BuyerAccounts:              map[string]bool{"acct": true},
			MemberDelegationIDs:        map[string]string{},
			MemberDelegationExpiresUTC: map[string]time.Time{},
			// The newest accepted core (v2) is what the Manifest* fields hold.
			ManifestVersion:           2,
			ManifestCoreDigest:        "digest-v2",
			ManifestSettlementMode:    "enforce",
			ManifestPolicyCoreV2:      true,
			ManifestRuntimeAllowlist:  []string{"llamacpp_loopback"},
			ManifestRetentionPolicyID: "standard",
			ManifestPolicies: []manifestPolicyWindow{
				{Version: 1, CoreDigest: "digest-v1", NotBeforeUnix: uint64(v1Start.Unix()), ExpiresAtUnix: uint64(v1End.Unix()), SettlementMode: "observe", RetentionPolicyID: "standard"},
				{Version: 2, CoreDigest: "digest-v2", NotBeforeUnix: uint64(v2Start.Unix()), ExpiresAtUnix: uint64(v2End.Unix()), SettlementMode: "enforce", PolicyCoreV2: true, RuntimeAllowlist: []string{"llamacpp_loopback"}, RetentionPolicyID: "standard"},
			},
		}
		return &ReconstructedState{Pools: map[string]*ReconstructedPoolState{p.PoolID: p}, RouteGateCheckedAt: at}
	}

	// Inside v1: the future-dated v2 must not route early.
	snaps := state(v1Start.Add(time.Minute)).RouteableSnapshots()
	if len(snaps) != 1 || !snaps[0].Routeable {
		t.Fatalf("v1 window: %+v, want routeable", snaps)
	}
	if got := snaps[0]; got.ManifestVersion != 1 || got.ManifestCoreDigest != "digest-v1" || len(got.RuntimeAllowlist) != 0 || got.SettlementMode != "observe" {
		t.Fatalf("v1 window labels=%d/%s allowlist=%v mode=%s, want the active v1 core", got.ManifestVersion, got.ManifestCoreDigest, got.RuntimeAllowlist, got.SettlementMode)
	}
	if !snaps[0].RouteableUntilUTC.Equal(v1End) {
		t.Fatalf("v1 window routeable_until=%s, want v1 expiry %s", snaps[0].RouteableUntilUTC, v1End)
	}

	// Between windows: no core is active, so the pool fails closed.
	gap := state(v1End.Add(time.Minute)).RouteableSnapshots()
	if gap[0].Routeable || len(gap[0].Members) != 0 {
		t.Fatalf("gap: routeable=%v members=%v, want not routeable (pool_policy_stale)", gap[0].Routeable, gap[0].Members)
	}
	if gap[0].Generation != 6 {
		t.Fatalf("gap generation=%d, want bumped 6 so in-flight fences trip", gap[0].Generation)
	}

	// Inside v2: v2 labels and allowlist route.
	v2 := state(v2Start.Add(time.Minute)).RouteableSnapshots()
	if !v2[0].Routeable || v2[0].ManifestVersion != 2 || len(v2[0].RuntimeAllowlist) != 1 {
		t.Fatalf("v2 window: %+v, want routeable v2 with its allowlist", v2[0])
	}

	// After every window: an expired core never keeps routing.
	if after := state(v2End.Add(time.Minute)).RouteableSnapshots(); after[0].Routeable {
		t.Fatalf("after v2 expiry: routeable, want pool_policy_stale")
	}
}

// #1816 S5: a routeable snapshot published shortly before a window-only
// rotation must not expire at the old core boundary before the registry refresh
// can publish the newly active manifest. Same-terms adjacent windows are the
// safe case: the terms digest excludes only version/prev/window fields, so no
// entry, price, attestation, allowlist, or settlement semantics changed.
func TestRouteableSnapshotsExtendSameTermsAdjacentPolicyWindow(t *testing.T) {
	v1Start := time.Unix(1_000, 0).UTC()
	v1End := time.Unix(2_000, 0).UTC()
	v2End := time.Unix(3_000, 0).UTC()

	snaps := sameTermsRolloverState(v1Start.Add(time.Minute), "terms-same").RouteableSnapshots()
	if len(snaps) != 1 || !snaps[0].Routeable {
		t.Fatalf("snapshot = %+v, want routeable active v1", snaps)
	}
	if got := snaps[0]; got.ManifestVersion != 1 || got.ManifestCoreDigest != "digest-v1" {
		t.Fatalf("manifest labels = %d/%s, want active v1", got.ManifestVersion, got.ManifestCoreDigest)
	}
	if !snaps[0].RouteableUntilUTC.Equal(v2End) {
		t.Fatalf("routeable_until=%s, want extended through adjacent same-terms v2 expiry %s", snaps[0].RouteableUntilUTC, v2End)
	}
	if snaps[0].RouteableUntilUTC.Equal(v1End) {
		t.Fatalf("routeable_until stopped at old boundary %s", v1End)
	}
}

func TestRouteableSnapshotsDoNotExtendChangedTermsAdjacentPolicyWindow(t *testing.T) {
	v1Start := time.Unix(1_000, 0).UTC()
	v1End := time.Unix(2_000, 0).UTC()

	snaps := sameTermsRolloverState(v1Start.Add(time.Minute), "terms-changed").RouteableSnapshots()
	if len(snaps) != 1 || !snaps[0].Routeable {
		t.Fatalf("snapshot = %+v, want routeable active v1", snaps)
	}
	if !snaps[0].RouteableUntilUTC.Equal(v1End) {
		t.Fatalf("changed-terms routeable_until=%s, want old boundary %s", snaps[0].RouteableUntilUTC, v1End)
	}
}

func sameTermsRolloverState(at time.Time, v2TermsDigest string) *ReconstructedState {
	v1Start := time.Unix(1_000, 0).UTC()
	v1End := time.Unix(2_000, 0).UTC()
	v2End := time.Unix(3_000, 0).UTC()
	entries := []poolmanifest.PoolModelEntry{{
		PoolModelID:           "pool/QpsclmzwdJaWJTk3zowcXQ/gguf-g",
		ArtifactHashAlgorithm: poolmanifest.ArtifactHashAlgorithmGGUFFileV1,
		ArtifactHash:          "1111111111111111111111111111111111111111111111111111111111111111",
		AllowedRuntimeSources: []string{poolmanifest.RuntimeSourceLlamacppLoopback},
		License:               "Apache-2.0",
		PaidServingAttested:   true,
		Pricing:               poolmanifest.PoolModelPricing{PromptRatePerMtok: 10, PromptCacheHitRatePerMtok: 5, CompletionRatePerMtok: 20},
		DisclosureClass:       poolmanifest.PoolModelDisclosureClass,
		MaxContextTokens:      4096,
	}}
	p := &ReconstructedPoolState{
		PoolID:                     "QpsclmzwdJaWJTk3zowcXQ",
		Lifecycle:                  LifecycleActive,
		Generation:                 5,
		Members:                    map[string]bool{"provider-a": true},
		Revoked:                    map[string]bool{},
		BuyerAccounts:              map[string]bool{"acct": true},
		MemberDelegationIDs:        map[string]string{},
		MemberDelegationExpiresUTC: map[string]time.Time{},
		ManifestVersion:            2,
		ManifestCoreDigest:         "digest-v2",
		ManifestTermsDigest:        v2TermsDigest,
		ManifestSettlementMode:     "enforce",
		ManifestPolicyCoreV2:       true,
		ManifestRuntimeAllowlist:   []string{poolmanifest.RuntimeSourceLlamacppLoopback},
		ManifestModelEntries:       entries,
		ManifestRetentionPolicyID:  "standard",
		ManifestPolicies: []manifestPolicyWindow{
			{
				Version: 1, CoreDigest: "digest-v1", TermsDigest: "terms-same",
				NotBeforeUnix: uint64(v1Start.Unix()), ExpiresAtUnix: uint64(v1End.Unix()),
				SettlementMode: "enforce", PolicyCoreV2: true, RuntimeAllowlist: []string{poolmanifest.RuntimeSourceLlamacppLoopback},
				ModelEntries: entries, RetentionPolicyID: "standard",
			},
			{
				Version: 2, CoreDigest: "digest-v2", TermsDigest: v2TermsDigest,
				NotBeforeUnix: uint64(v1End.Unix()), ExpiresAtUnix: uint64(v2End.Unix()),
				SettlementMode: "enforce", PolicyCoreV2: true, RuntimeAllowlist: []string{poolmanifest.RuntimeSourceLlamacppLoopback},
				ModelEntries: entries, RetentionPolicyID: "standard",
			},
		},
	}
	return &ReconstructedState{Pools: map[string]*ReconstructedPoolState{p.PoolID: p}, RouteGateCheckedAt: at}
}
