package trustpool_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// #1816 F4: a manifest refused for its R015/R016 extensions answers its
// closed rejection code on the admin surface, never the opaque invalid_event.
func TestAdminHandler_PoolModelManifestRejectionCodes(t *testing.T) {
	t.Parallel()
	bounds := &poolmanifest.PoolModelPricingBounds{MaxPromptRatePerMtok: 1000, MaxPromptCacheHitRatePerMtok: 1000, MaxCompletionRatePerMtok: 1000}
	accept := func(isCatalogID func(string) bool, inCatalog func(string, string, []string) bool) func() poolmanifest.PoolModelAcceptanceContext {
		return func() poolmanifest.PoolModelAcceptanceContext {
			return poolmanifest.PoolModelAcceptanceContext{PricingBounds: bounds, IsCatalogModelID: isCatalogID, ArtifactInCatalog: inCatalog}
		}
	}
	none := func(string) bool { return false }
	notCatalogued := func(string, string, []string) bool { return false }
	entries := func(mutate func([]poolmanifest.PoolModelEntry) []poolmanifest.PoolModelEntry) func(string) []poolmanifest.PoolModelEntry {
		return func(poolID string) []poolmanifest.PoolModelEntry { return mutate(poolEntriesFor(poolID)) }
	}
	same := func(e []poolmanifest.PoolModelEntry) []poolmanifest.PoolModelEntry { return e }
	for name, tc := range map[string]struct {
		acceptance func() poolmanifest.PoolModelAcceptanceContext
		entries    func(string) []poolmanifest.PoolModelEntry
		members    []poolmanifest.AttestedMember
		wantCode   string
	}{
		"bounds unset": {nil, entries(same), nil, poolmanifest.RejectCodePricingBoundsUnset},
		"out of bounds": {accept(none, notCatalogued), entries(func(e []poolmanifest.PoolModelEntry) []poolmanifest.PoolModelEntry {
			e[0].Pricing.CompletionRatePerMtok = 5000
			return e
		}), nil, poolmanifest.RejectCodePricingOutOfBounds},
		"catalog shadow": {accept(func(id string) bool { return id == "creator-gguf" }, notCatalogued), entries(same), nil, poolmanifest.RejectCodeShadowsCatalog},
		"catalog overlap": {accept(none, func(_, hash string, _ []string) bool { return hash == poolEntryGGUFHash }), entries(same), nil,
			poolmanifest.RejectCodeCatalogOverlap},
		"licence": {accept(none, notCatalogued), entries(func(e []poolmanifest.PoolModelEntry) []poolmanifest.PoolModelEntry {
			e[0].License = "Not-A-Licence"
			return e
		}), nil, poolmanifest.RejectCodeLicense},
		"paid serving": {accept(none, notCatalogued), entries(func(e []poolmanifest.PoolModelEntry) []poolmanifest.PoolModelEntry {
			e[0].PaidServingAttested = false
			return e
		}), nil, poolmanifest.RejectCodePaidServing},
		"runtime pairing": {accept(none, notCatalogued), entries(func(e []poolmanifest.PoolModelEntry) []poolmanifest.PoolModelEntry {
			e[0].AllowedRuntimeSources = []string{poolmanifest.RuntimeSourceNativeMLX}
			return e
		}), nil, poolmanifest.RejectCodeRuntimePairing},
		"duplicate hash": {accept(none, notCatalogued), entries(func(e []poolmanifest.PoolModelEntry) []poolmanifest.PoolModelEntry {
			e[1].ArtifactHashAlgorithm, e[1].ArtifactHash = e[0].ArtifactHashAlgorithm, e[0].ArtifactHash
			e[1].AllowedRuntimeSources = e[0].AllowedRuntimeSources
			return e
		}), nil, poolmanifest.RejectCodeDuplicate},
		"creator attested": {accept(none, notCatalogued), entries(same),
			[]poolmanifest.AttestedMember{{ProviderAccountID: "creator-a", RuntimeClasses: []string{poolmanifest.RuntimeSourceLlamacppLoopback}}}, trustpool.PoolModelRejectCreatorMember},
	} {
		t.Run(name, func(t *testing.T) {
			var opts []trustpool.StoreOption
			if tc.acceptance != nil {
				opts = append(opts, trustpool.WithPoolModelAcceptance(tc.acceptance))
			}
			store, err := trustpool.NewStore(openTrustPoolDB(t), opts...)
			if err != nil {
				t.Fatalf("NewStore: %v", err)
			}
			handler := trustpool.NewAdminHandler(trustpool.AdminDeps{Store: store, Registry: trustpool.NewRegistry(), OperatorKey: "operator-secret"})
			root := newRootFixture(t)
			approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
			postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
				EventType: trustpool.EventPoolCreated, PoolID: root.poolID, CreatorAccountID: "creator-a", ApprovalRecordID: "approval-v1",
			}, "op-create", http.StatusAccepted)
			postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root), "op-root", http.StatusAccepted)
			manifest := signedManifestWithPolicyCoreMutation(t, "op-manifest", testAdminTS(2), root.poolID, 1, root, func(core *poolmanifest.PolicyCore) {
				core.SettlementMode = "enforce"
				core.Encoding = poolmanifest.PolicyCoreEncodingV2
				allowLlamacpp(core)
				core.Extensions = nil
				if err := core.SetPoolExtensions(tc.entries(root.poolID), tc.members); err != nil {
					t.Fatalf("SetPoolExtensions: %v", err)
				}
			})
			body, err := json.Marshal(manifest)
			if err != nil {
				t.Fatal(err)
			}
			req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/events", bytes.NewReader(body))
			req.Header.Set("Authorization", "Bearer operator-secret")
			req.Header.Set("Idempotency-Key", "op-manifest")
			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, req)
			var got struct {
				Error struct {
					Code string `json:"code"`
				} `json:"error"`
			}
			_ = json.Unmarshal(rec.Body.Bytes(), &got)
			if rec.Code != http.StatusBadRequest || got.Error.Code != tc.wantCode {
				t.Fatalf("status=%d code=%q body=%s, want 400 %s", rec.Code, got.Error.Code, rec.Body.String(), tc.wantCode)
			}
		})
	}
}

// #1816 F5: get-pool / pool-status read back the accepted core's pool model
// entries and member attestations on the admin surface.
func TestAdminHandler_GetPoolListsModelEntriesAndAttestedMembers(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t), trustpool.WithPoolModelAcceptance(acceptAllPoolModels))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{Store: store, Registry: trustpool.NewRegistry(), OperatorKey: "operator-secret"})
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType: trustpool.EventPoolCreated, PoolID: root.poolID, CreatorAccountID: "creator-a", ApprovalRecordID: "approval-v1",
	}, "op-create", http.StatusAccepted)
	get := func() map[string]any {
		t.Helper()
		req := httptest.NewRequest(http.MethodGet, "/admin/trust-pools/pools/"+root.poolID, nil)
		req.Header.Set("Authorization", "Bearer operator-secret")
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("GET pool status=%d body=%s", rec.Code, rec.Body.String())
		}
		var body struct {
			Pool map[string]any `json:"pool"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
		return body.Pool
	}
	if before := get(); before["model_entries"] != nil || before["attested_members"] != nil {
		t.Fatalf("pool before any accepted core lists extensions: %v %v", before["model_entries"], before["attested_members"])
	}
	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root), "op-root", http.StatusAccepted)
	members := []poolmanifest.AttestedMember{{ProviderAccountID: "acct-member-d", RuntimeClasses: []string{poolmanifest.RuntimeSourceLlamacppLoopback}}}
	postAdminEvent(t, handler, "operator-secret", signedManifestWithPolicyCoreMutation(t, "op-manifest", testAdminTS(2), root.poolID, 1, root, func(core *poolmanifest.PolicyCore) {
		core.SettlementMode = "enforce"
		core.Encoding = poolmanifest.PolicyCoreEncodingV2
		withPoolModels(root.poolID, members)(core)
	}), "op-manifest", http.StatusAccepted)
	pool := get()
	entries, _ := pool["model_entries"].([]any)
	attested, _ := pool["attested_members"].([]any)
	if len(entries) != 2 || len(attested) != 1 {
		t.Fatalf("model_entries=%v attested_members=%v", pool["model_entries"], pool["attested_members"])
	}
	first := entries[0].(map[string]any)
	if first["pool_model_id"] != "pool/"+root.poolID+"/creator-gguf" || first["artifact_hash"] != poolEntryGGUFHash ||
		first["completion_rate_per_mtok"] != float64(300) || first["max_context_tokens"] != float64(32768) || first["license"] != "Apache-2.0" {
		t.Fatalf("model entry = %v", first)
	}
	if member := attested[0].(map[string]any); member["provider_account_id"] != "acct-member-d" {
		t.Fatalf("attested member = %v", member)
	}
}
