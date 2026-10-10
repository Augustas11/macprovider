package trustpool_test

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// SPEC-043-R014: pool_policy.json and pool_status.json enumerate every active
// pool model with the active core's pool_model_id, artifact pair, engine set,
// price, and disclosure class, each labelled pool-attested, not network-
// verified; a core without entries discloses an empty list.
func TestPolicyAndStatusEnumeratePoolModels(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name    string
		mutate  func(string) func(*poolmanifest.PolicyCore)
		entries bool
	}{
		{"v2 core with entries", func(poolID string) func(*poolmanifest.PolicyCore) {
			return func(core *poolmanifest.PolicyCore) {
				core.SettlementMode = "enforce"
				withPoolModels(poolID, nil)(core)
			}
		}, true},
		{"v1 core", func(string) func(*poolmanifest.PolicyCore) { return nil }, false},
	} {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			ctx := context.Background()
			store, err := trustpool.NewStore(openTrustPoolDB(t), trustpool.WithPoolModelAcceptance(acceptAllPoolModels))
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
				signedManifestWithPolicyCoreMutation(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root, tc.mutate(root.poolID)),
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
			at := time.Unix(1800020500, 0).UTC()
			policy, found, err := trustpool.BuildPolicyDocument(ctx, store, registry, root.poolID, "acct-a", at)
			if err != nil || !found {
				t.Fatalf("BuildPolicyDocument found=%v err=%v", found, err)
			}
			status, found, err := trustpool.BuildStatusDocument(ctx, store, registry, root.poolID, "acct-a", at)
			if err != nil || !found {
				t.Fatalf("BuildStatusDocument found=%v err=%v", found, err)
			}
			raw, _ := json.Marshal(policy.Policy)
			if !strings.Contains(string(raw), `"pool_models":[`) {
				t.Fatalf("pool_models is not an array: %s", raw)
			}
			if !tc.entries {
				if len(policy.Policy.PoolModels) != 0 || len(status.Policy.PoolModels) != 0 {
					t.Fatalf("a core without entries enumerated %+v / %+v", policy.Policy.PoolModels, status.Policy.PoolModels)
				}
				return
			}
			want := poolEntriesFor(root.poolID)
			for name, got := range map[string][]trustpool.PolicyPoolModel{"policy": policy.Policy.PoolModels, "status": status.Policy.PoolModels} {
				if len(got) != len(want) {
					t.Fatalf("%s pool_models = %+v", name, got)
				}
				for i, m := range got {
					e := want[i]
					if m.PoolModelID != e.PoolModelID || m.ArtifactHashAlgorithm != e.ArtifactHashAlgorithm || m.ArtifactHash != e.ArtifactHash ||
						strings.Join(m.RuntimeSources, ",") != strings.Join(e.AllowedRuntimeSources, ",") || m.MaxContextTokens != e.MaxContextTokens ||
						m.Price.PromptRatePerMtok != e.Pricing.PromptRatePerMtok || m.Price.PromptCacheHitRatePerMtok != e.Pricing.PromptCacheHitRatePerMtok ||
						m.Price.CompletionRatePerMtok != e.Pricing.CompletionRatePerMtok || m.DisclosureClass != e.DisclosureClass ||
						m.DisclosureText != "Pool-attested, not network-verified" || m.PriceSource != "pool_creator_signed" {
						t.Fatalf("%s pool_models[%d] = %+v, entry %+v", name, i, m, e)
					}
				}
			}
		})
	}
}
