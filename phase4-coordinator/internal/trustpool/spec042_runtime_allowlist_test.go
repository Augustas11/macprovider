package trustpool_test

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// SPEC-042-R001 0.0.32 (#1690 M4): the coordinator accepts policy-core/v2,
// projects the signed runtime_allowlist into the routeable snapshot, and
// discloses it (SPEC-043-R013).

func allowLlamacpp(core *poolmanifest.PolicyCore) {
	core.Encoding = poolmanifest.PolicyCoreEncodingV2
	core.SettlementMode = "enforce"
	core.RuntimeAllowlist = []string{poolmanifest.RuntimeSourceLlamacppLoopback}
}

func runtimePoolEvents(t *testing.T, ts time.Time, root rootFixture, mutate func(*poolmanifest.PolicyCore)) []trustpool.DurableEvent {
	t.Helper()
	return []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistration(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", root),
		signedManifestWithPolicyCoreMutation(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root, mutate),
	}
}

func TestReconstructEvents_AcceptsPolicyCoreV2RuntimeAllowlist(t *testing.T) {
	t.Parallel()
	ts := time.Unix(1800020000, 0).UTC()
	root := newRootFixture(t)
	events := runtimePoolEvents(t, ts, root, allowLlamacpp)
	events = append(events,
		ev("op-member-owned", ts.Add(3*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-a"
		}),
	)
	state, err := trustpool.ReconstructEvents(events)
	if err != nil {
		t.Fatalf("ReconstructEvents v2: %v", err)
	}
	p := state.Pools[root.poolID]
	if !p.ManifestPolicyCoreV2 || len(p.ManifestRuntimeAllowlist) != 1 || p.ManifestRuntimeAllowlist[0] != poolmanifest.RuntimeSourceLlamacppLoopback {
		t.Fatalf("v2 allowlist not projected: v2=%v allowlist=%v", p.ManifestPolicyCoreV2, p.ManifestRuntimeAllowlist)
	}
	snaps := state.RouteableSnapshots()
	if len(snaps) != 1 || len(snaps[0].RuntimeAllowlist) != 1 || snaps[0].RuntimeAllowlist[0] != poolmanifest.RuntimeSourceLlamacppLoopback {
		t.Fatalf("routeable snapshot runtime allowlist=%+v", snaps)
	}
	registry := trustpool.NewRegistry()
	snap := snaps[0]
	snap.Routeable = true
	snap.Members = []string{"provider-a", "provider-delegated"}
	snap.DelegatedMembers = []string{"provider-delegated"}
	if err := registry.LoadRouteableSnapshot(snap); err != nil {
		t.Fatalf("LoadRouteableSnapshot: %v", err)
	}
	got := registry.Snapshot(root.poolID)
	if len(got.RuntimeAllowlist) != 1 || got.CreatorAccountID != "creator-a" {
		t.Fatalf("registry snapshot runtime allowlist=%v creator=%q", got.RuntimeAllowlist, got.CreatorAccountID)
	}
	if !got.CreatorOwnedMembers["provider-a"] || got.CreatorOwnedMembers["provider-delegated"] {
		t.Fatalf("creator-owned members=%v, want only provider-a", got.CreatorOwnedMembers)
	}
	// A malformed durable projection never authorizes an external runtime.
	bad := snaps[0]
	bad.RuntimeAllowlist = []string{"lmstudio_loopback"}
	if err := trustpool.NewRegistry().LoadRouteableSnapshot(bad); err == nil {
		t.Fatal("registry accepted an out-of-vocabulary runtime allowlist")
	}
}

func TestReconstructEvents_V1CoreIsNativeOnly(t *testing.T) {
	t.Parallel()
	ts := time.Unix(1800020100, 0).UTC()
	root := newRootFixture(t)
	state, err := trustpool.ReconstructEvents(runtimePoolEvents(t, ts, root, nil))
	if err != nil {
		t.Fatalf("ReconstructEvents v1: %v", err)
	}
	if snaps := state.RouteableSnapshots(); len(snaps) != 1 || len(snaps[0].RuntimeAllowlist) != 0 {
		t.Fatalf("v1 core projected a runtime allowlist: %+v", snaps)
	}
	// A v2 core with an empty allowlist is native only too.
	root2 := newRootFixture(t)
	state, err = trustpool.ReconstructEvents(runtimePoolEvents(t, ts, root2, func(core *poolmanifest.PolicyCore) {
		core.Encoding = poolmanifest.PolicyCoreEncodingV2
	}))
	if err != nil {
		t.Fatalf("ReconstructEvents v2 empty: %v", err)
	}
	if snaps := state.RouteableSnapshots(); len(snaps) != 1 || len(snaps[0].RuntimeAllowlist) != 0 {
		t.Fatalf("empty v2 allowlist projected a runtime: %+v", snaps)
	}
}

func TestReconstructEvents_RejectsPolicyCoreV2AcceptanceViolations(t *testing.T) {
	t.Parallel()
	ts := time.Unix(1800020200, 0).UTC()
	for name, mutate := range map[string]func(*poolmanifest.PolicyCore){
		"allowlist under observe": func(core *poolmanifest.PolicyCore) {
			allowLlamacpp(core)
			core.SettlementMode = "observe"
		},
		"allowlist mlx_cache": func(core *poolmanifest.PolicyCore) {
			allowLlamacpp(core)
			core.RuntimeAllowlist = []string{"mlx_cache"}
		},
		"allowlist lmstudio": func(core *poolmanifest.PolicyCore) {
			allowLlamacpp(core)
			core.RuntimeAllowlist = []string{"lmstudio_loopback"}
		},
		"unknown extension": func(core *poolmanifest.PolicyCore) {
			allowLlamacpp(core)
			core.Extensions = []poolmanifest.PolicyExtension{{ID: "relay_blind/v1"}}
		},
	} {
		name, mutate := name, mutate
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			root := newRootFixture(t)
			if _, err := trustpool.ReconstructEvents(runtimePoolEvents(t, ts, root, mutate)); !errors.Is(err, trustpool.ErrMalformedDurableEvent) {
				t.Fatalf("%s: err=%v, want ErrMalformedDurableEvent", name, err)
			}
		})
	}
}

// Loosening (v1 -> v2 with a runtime) mints a new manifest_version and a new
// digest, and advances the routeable generation, so routes fenced under the
// prior core fail pool_state_stale.
func TestReconstructEvents_RuntimeAllowlistLooseningMintsNewManifestVersion(t *testing.T) {
	t.Parallel()
	ts := time.Unix(1800020300, 0).UTC()
	root := newRootFixture(t)
	events := runtimePoolEvents(t, ts, root, func(core *poolmanifest.PolicyCore) { core.SettlementMode = "enforce" })
	before, err := trustpool.ReconstructEvents(events)
	if err != nil {
		t.Fatalf("ReconstructEvents v1: %v", err)
	}
	loosened := signedManifestExtendingWithPolicyCoreMutation(t, "op-manifest-2", ts.Add(3*time.Second), events[2], root, allowLlamacpp)
	after, err := trustpool.ReconstructEvents(append(events, loosened))
	if err != nil {
		t.Fatalf("ReconstructEvents v1->v2: %v", err)
	}
	b, a := before.Pools[root.poolID], after.Pools[root.poolID]
	if a.ManifestVersion != b.ManifestVersion+1 || a.ManifestCoreDigest == b.ManifestCoreDigest || !a.ManifestPolicyCoreV2 {
		t.Fatalf("loosening did not mint a new version: before=%d/%s after=%d/%s v2=%v", b.ManifestVersion, b.ManifestCoreDigest, a.ManifestVersion, a.ManifestCoreDigest, a.ManifestPolicyCoreV2)
	}
	if after.RouteableSnapshots()[0].Generation == before.RouteableSnapshots()[0].Generation {
		t.Fatal("loosening did not advance the pool generation fence")
	}
	// Re-using the prior manifest_version for the loosened core is a rollback.
	sameVersion := signedManifestWithPolicyCoreMutation(t, "op-manifest-same", ts.Add(3*time.Second), root.poolID, 1, root, allowLlamacpp)
	if _, err := trustpool.ReconstructEvents(append(events, sameVersion)); !errors.Is(err, trustpool.ErrMalformedDurableEvent) {
		t.Fatalf("same-version loosening err=%v, want ErrMalformedDurableEvent", err)
	}
}

// SPEC-043-R013: pool_policy.json and pool_status.json list the runtime
// allowlist and the administrative-trust statement; a v1 core says native only.
func TestPolicyAndStatusDiscloseRuntimeAllowlist(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name      string
		mutate    func(*poolmanifest.PolicyCore)
		wantScope string
		wantList  []string
		wantText  string
	}{
		{"v2 allowlist", allowLlamacpp, trustpool.RuntimeScopeNativeAndExternalRuntimes, []string{poolmanifest.RuntimeSourceLlamacppLoopback}, "administrative trust"},
		{"v1 native", nil, trustpool.RuntimeScopeNativeMLXOnly, []string{}, "native MLX only"},
	} {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			ctx := context.Background()
			store, err := trustpool.NewStore(openTrustPoolDB(t))
			if err != nil {
				t.Fatalf("NewStore: %v", err)
			}
			ts := time.Unix(1800020400, 0).UTC()
			root := newRootFixture(t)
			approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
			for _, e := range []trustpool.DurableEvent{
				ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
					e.CreatorAccountID = "creator-a"
					e.ApprovalRecordID = "approval-v1"
				}),
				signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
				signedManifestWithPolicyCoreMutation(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root, tc.mutate),
				ev("op-member", ts.Add(3*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) { e.ProviderID = "provider-a" }),
				ev("op-buyer", ts.Add(4*time.Second), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) { e.BuyerAccountID = "acct-a" }),
			} {
				if _, _, _, err := store.AppendValidatedEvent(ctx, e); err != nil {
					t.Fatalf("AppendValidatedEvent(%s): %v", e.OperationID, err)
				}
			}
			state, err := store.Reconstruct(ctx)
			if err != nil {
				t.Fatalf("Reconstruct: %v", err)
			}
			registry, err := state.BuildRegistry()
			if err != nil {
				t.Fatalf("BuildRegistry: %v", err)
			}
			policy, found, err := trustpool.BuildPolicyDocument(ctx, store, registry, root.poolID, "acct-a", time.Unix(1800020500, 0).UTC())
			if err != nil || !found {
				t.Fatalf("BuildPolicyDocument found=%v err=%v", found, err)
			}
			status, found, err := trustpool.BuildStatusDocument(ctx, store, registry, root.poolID, "acct-a", time.Unix(1800020500, 0).UTC())
			if err != nil || !found {
				t.Fatalf("BuildStatusDocument found=%v err=%v", found, err)
			}
			if policy.Policy.RuntimeScope != tc.wantScope || status.Policy.RuntimeScope != tc.wantScope {
				t.Fatalf("runtime_scope policy=%q status=%q want %q", policy.Policy.RuntimeScope, status.Policy.RuntimeScope, tc.wantScope)
			}
			if strings.Join(policy.Policy.RuntimeAllowlist, ",") != strings.Join(tc.wantList, ",") ||
				strings.Join(status.Policy.RuntimeAllowlist, ",") != strings.Join(tc.wantList, ",") {
				t.Fatalf("runtime_allowlist policy=%v status=%v want %v", policy.Policy.RuntimeAllowlist, status.Policy.RuntimeAllowlist, tc.wantList)
			}
			for _, doc := range []any{policy, status} {
				raw, err := json.Marshal(doc)
				if err != nil {
					t.Fatalf("Marshal: %v", err)
				}
				body := string(raw)
				if !strings.Contains(body, tc.wantText) || !strings.Contains(body, `"runtime_allowlist":[`) {
					t.Fatalf("document missing runtime disclosure %q: %s", tc.wantText, body)
				}
				for _, banned := range []string{"attested runtime", "verified runtime"} {
					if strings.Contains(body, banned) {
						t.Fatalf("document overclaims %q: %s", banned, body)
					}
				}
			}
		})
	}
}
