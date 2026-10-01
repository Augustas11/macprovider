package billing

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

const testPoolID = "QpsclmzwdJaWJTk3zowcXQ"

// poolManifestSnapshot is a SPEC-022-R013 pool_manifest route snapshot for a
// native (mlx_cache) session serving a signed pool entry.
func poolManifestSnapshot(route RouteSnapshot) RouteSnapshot {
	route.RouteSnapshotMode = RouteSnapshotModeEnforce
	route.PoolID = testPoolID
	route.ManifestVersion = 2
	route.ManifestCoreDigest = strings.Repeat("d", 64)
	route.PoolGeneration = 7
	route.ExpectedModelHashSource = ExpectedModelHashSourcePoolManifest
	route.PoolModelID = "pool/" + testPoolID + "/creator-mlx"
	route.PoolModelPromptRatePerMtok = 300000
	route.PoolModelPromptCacheHitRatePerMtok = 30000
	route.PoolModelCompletionRatePerMtok = 700000
	route.PoolModelPricingBoundsSHA256 = strings.Repeat("b", 64)
	return route
}

// SPEC-022-R013.1: catalog route snapshots keep their exact preimage; the
// pool-manifest members are digested only for a pool_manifest source.
func TestRouteSnapshotPoolManifestSourcePreimage(t *testing.T) {
	catalog := testRouteSnapshot()
	for _, key := range []string{"expected_model_hash_source", "pool_model_id", "pool_model_prompt_rate_per_mtok",
		"pool_model_prompt_cache_hit_rate_per_mtok", "pool_model_completion_rate_per_mtok", "pool_model_pricing_bounds_sha256", "pool_member_account_id"} {
		if _, ok := catalog.Value()[key]; ok {
			t.Fatalf("catalog route snapshot preimage gained %s", key)
		}
	}
	pool := poolManifestSnapshot(testRouteSnapshot())
	digest, _, err := pool.Digest()
	if err != nil {
		t.Fatalf("pool_manifest snapshot rejected: %v", err)
	}
	value := pool.Value()
	if value["expected_model_hash_source"] != ExpectedModelHashSourcePoolManifest || value["pool_model_id"] != pool.PoolModelID || value["pool_generation"] != int64(7) {
		t.Fatalf("pool_manifest preimage = %+v", value)
	}
	for name, mutate := range map[string]func(*RouteSnapshot){
		"price":      func(r *RouteSnapshot) { r.PoolModelCompletionRatePerMtok++ },
		"pool model": func(r *RouteSnapshot) { r.PoolModelID = "pool/" + testPoolID + "/other" },
		"bounds":     func(r *RouteSnapshot) { r.PoolModelPricingBoundsSHA256 = strings.Repeat("c", 64) },
		"generation": func(r *RouteSnapshot) { r.PoolGeneration = 8 },
	} {
		moved := pool
		mutate(&moved)
		if got, _, err := moved.Digest(); err != nil || got == digest {
			t.Errorf("%s: digest=%s err=%v, want a different valid digest", name, got, err)
		}
	}
	// A GGUF pool entry needs no artifact-feed evidence (SPEC-010-R007(j)).
	gguf := pool
	gguf.ProviderReportedModelHashAlgorithm = modelidentity.GGUFFileV1
	gguf.ExpectedCatalogModelHashAlgorithm = modelidentity.GGUFFileV1
	if err := gguf.Validate(); err != nil {
		t.Fatalf("GGUF pool_manifest snapshot: %v", err)
	}
	for name, mutate := range map[string]func(*RouteSnapshot){
		"explicit catalog source": func(r *RouteSnapshot) {
			*r = testRouteSnapshot()
			r.ExpectedModelHashSource = ExpectedModelHashSourceCatalog
		},
		"pool member without source": func(r *RouteSnapshot) {
			*r = testRouteSnapshot()
			r.PoolModelID = "pool/" + testPoolID + "/x"
		},
		"other pool's model":  func(r *RouteSnapshot) { r.PoolModelID = "pool/AAAAAAAAAAAAAAAAAAAAAA/creator-mlx" },
		"no pool id":          func(r *RouteSnapshot) { r.PoolID = "" },
		"no manifest labels":  func(r *RouteSnapshot) { r.ManifestVersion = 0 },
		"no generation":       func(r *RouteSnapshot) { r.PoolGeneration = 0 },
		"cache above prompt":  func(r *RouteSnapshot) { r.PoolModelPromptCacheHitRatePerMtok = r.PoolModelPromptRatePerMtok + 1 },
		"negative rate":       func(r *RouteSnapshot) { r.PoolModelCompletionRatePerMtok = -1 },
		"bounds digest":       func(r *RouteSnapshot) { r.PoolModelPricingBoundsSHA256 = "" },
		"catalog key":         func(r *RouteSnapshot) { r.ModelAdmissionCatalogModelKey = "model-a" },
		"feed evidence":       func(r *RouteSnapshot) { r.ArtifactID = "artifact-a" },
		"member account only": func(r *RouteSnapshot) { r.PoolMemberAccountID = "acct-member" },
	} {
		bad := pool
		mutate(&bad)
		if err := bad.Validate(); err == nil {
			t.Errorf("%s: invalid snapshot validated", name)
		}
	}
	entry, ok := pool.PoolModelRateEntry()
	if !ok || entry.PromptCreditsPerMtok != 300000 || entry.EffectivePromptCacheHitCreditsPerMtok() != 30000 || entry.CompletionCreditsPerMtok != 700000 {
		t.Fatalf("PoolModelRateEntry = %+v ok=%v", entry, ok)
	}
	if _, ok := catalog.PoolModelRateEntry(); ok {
		t.Fatal("catalog snapshot has a pool model rate")
	}
}

type fakePoolManifestAuthority struct {
	fencedPoolAuthority
	routeErr error
	last     PoolOperatorAttestationClaim
}

func (f *fakePoolManifestAuthority) VerifyPoolManifestRoute(_ context.Context, claim PoolOperatorAttestationClaim) error {
	f.last = claim
	return f.routeErr
}

func poolManifestLabels(poolID string) (uint64, string, bool) {
	return 2, strings.Repeat("d", 64), poolID == testPoolID
}

// SPEC-005-R015 at the ledger boundary: a pool-model attempt is priced from
// its signed entry only behind a verified, fenced pool_manifest decision; a
// pool/ model id without one is zero-billed, never priced by RateFor/default.
func TestHotPathPoolManifestPricing(t *testing.T) {
	cfg := testRewards()
	run := func(t *testing.T, mutate func(*HotPathInput, *Store)) (gross, provider, quarantined int64, reason string) {
		t.Helper()
		reqStore, store := newRequestAndBillingStores(t)
		authority := &fakePoolManifestAuthority{fencedPoolAuthority: fencedPoolAuthority{highWaters: []int64{7}}}
		store.SetPoolOperatorAttestationAuthority(authority)
		store.SetSettlementPoolLabelSource(poolManifestLabels)
		snapshotID, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Unix(100, 0).UTC())
		if err != nil {
			t.Fatal(err)
		}
		prompt, completion := int64(1000), int64(2000)
		model := "pool/" + testPoolID + "/creator-mlx"
		row := requestlog.Row{TSUtc: time.Unix(200, 0).UTC(), RequestID: "pool-hot", Model: model, ProviderAssignedID: "assigned-a",
			PromptTokens: &prompt, CompletionTokens: &completion, Status: 200, BuyerIP: "127.0.0.1"}
		entry, _ := poolManifestSnapshot(testRouteSnapshot()).PoolModelRateEntry()
		fence, ok := store.PoolAttestationFenceFor(context.Background(), testPoolID)
		if !ok {
			t.Fatal("no fence")
		}
		input := HotPathInput{
			RequestID: row.RequestID, ProviderAssignedID: row.ProviderAssignedID, ProviderID: "provider-a", Model: model,
			Status: 200, TSUtc: row.TSUtc, PromptTokens: &prompt, CompletionTokens: &completion,
			ConfigSnapshotID: snapshotID, RateEntry: entry, MultiplierPPM: ParseMultiplierPPM(cfg.GlobalMultiplier),
			ProviderShareBps: ParseShareBps(cfg.ProviderShare), ProviderRuntimeSource: "mlx_cache",
			PoolManifestRoute: true, PoolManifestVerified: true, PoolAttestationFence: fence,
		}
		mutate(&input, store)
		if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
			t.Fatal(err)
		}
		var reasonNull sql.NullString
		if err := store.db.QueryRow(`SELECT gross_credits, provider_credits, quarantined, quarantine_reason FROM ledger_request_credits WHERE request_id = ?`, row.RequestID).
			Scan(&gross, &provider, &quarantined, &reasonNull); err != nil {
			t.Fatal(err)
		}
		return gross, provider, quarantined, reasonNull.String
	}
	t.Run("verified route priced from entry", func(t *testing.T) {
		gross, provider, quarantined, _ := run(t, func(*HotPathInput, *Store) {})
		// 1000 * 300000 / 1e6 + 2000 * 700000 / 1e6 = 300 + 1400.
		if gross != 1700 || provider == 0 || quarantined != 0 {
			t.Fatalf("gross=%d provider=%d quarantined=%d, want 1700 priced from the entry", gross, provider, quarantined)
		}
	})
	for name, mutate := range map[string]func(*HotPathInput, *Store){
		"unverified route": func(in *HotPathInput, _ *Store) { in.PoolManifestVerified = false },
		"pool model on a non-pool route": func(in *HotPathInput, _ *Store) {
			in.PoolManifestRoute, in.PoolManifestVerified = false, false
			in.RateEntry = RateFor(cfg.RateCard, in.Model)
		},
		"fence moved": func(_ *HotPathInput, store *Store) {
			store.SetSettlementPoolLabelSource(func(string) (uint64, string, bool) { return 3, strings.Repeat("e", 64), true })
		},
		"no fence": func(in *HotPathInput, _ *Store) { in.PoolAttestationFence = nil },
	} {
		t.Run(name, func(t *testing.T) {
			gross, provider, quarantined, reason := run(t, mutate)
			if gross != 0 || provider != 0 || quarantined != 1 || reason != PoolManifestRouteNotSettlementEligible {
				t.Fatalf("gross=%d provider=%d quarantined=%d reason=%q, want zero %s", gross, provider, quarantined, reason, PoolManifestRouteNotSettlementEligible)
			}
		})
	}
}

// Recovery re-creating a missing pool-model ledger row prices it from the
// route snapshot's signed entry only when the durable authority re-verifies
// the native pool_manifest route and the label still holds.
func TestRecoverLedger_PoolManifestRoutes(t *testing.T) {
	cfg := testRewards()
	run := func(t *testing.T, withSnapshot bool, authority *fakePoolManifestAuthority, labels SettlementPoolLabelSource) (gross, quarantined int64, reason string) {
		t.Helper()
		reqStore, store := newRequestAndBillingStores(t)
		if authority != nil {
			store.SetPoolOperatorAttestationAuthority(authority)
		}
		if labels != nil {
			store.SetSettlementPoolLabelSource(labels)
		}
		snapshotID, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Unix(100, 0).UTC())
		if err != nil {
			t.Fatal(err)
		}
		ts := time.Unix(200, 0).UTC()
		prompt, completion := int64(1000), int64(2000)
		model := "pool/" + testPoolID + "/creator-mlx"
		row := requestlog.Row{TSUtc: ts, RequestID: "pool-recover", Model: model, ProviderAssignedID: "assigned-a",
			PromptTokens: &prompt, CompletionTokens: &completion, Status: 200, BuyerIP: "127.0.0.1"}
		input := HotPathInput{RequestID: row.RequestID, ProviderAssignedID: row.ProviderAssignedID, ProviderID: "provider-a",
			Model: model, Status: 200, TSUtc: ts, PromptTokens: &prompt, CompletionTokens: &completion, ConfigSnapshotID: snapshotID,
			MultiplierPPM: ParseMultiplierPPM(cfg.GlobalMultiplier), ProviderShareBps: ParseShareBps(cfg.ProviderShare), ProviderRuntimeSource: "mlx_cache"}
		if err := store.WriteRequestLogWithIdentity(context.Background(), reqStore, row, input); err != nil {
			t.Fatal(err)
		}
		if withSnapshot {
			snap := poolManifestSnapshot(testRouteSnapshot())
			snap.AccountScope = AccountScopeForSettlement("")
			snap.RequestID = row.RequestID
			snap.ProviderID = input.ProviderID
			if _, err := store.InsertRouteSnapshot(context.Background(), snap); err != nil {
				t.Fatal(err)
			}
		}
		if err := store.RecoverLedger(context.Background(), RecoverInput{ScanFrom: ts.Add(-time.Minute), ScanTo: ts.Add(time.Minute), Source: "startup_scan"}); err != nil {
			t.Fatal(err)
		}
		var reasonNull sql.NullString
		if err := store.db.QueryRow(`SELECT gross_credits, quarantined, quarantine_reason FROM ledger_request_credits WHERE request_id = ?`, row.RequestID).
			Scan(&gross, &quarantined, &reasonNull); err != nil {
			t.Fatal(err)
		}
		return gross, quarantined, reasonNull.String
	}
	verifying := func() *fakePoolManifestAuthority {
		return &fakePoolManifestAuthority{fencedPoolAuthority: fencedPoolAuthority{highWaters: []int64{7}}}
	}
	authority := verifying()
	if gross, quarantined, _ := run(t, true, authority, poolManifestLabels); gross != 1700 || quarantined != 0 {
		t.Fatalf("verified native pool route: gross=%d quarantined=%d, want 1700 priced from the entry", gross, quarantined)
	}
	if authority.last.PoolModelID != "pool/"+testPoolID+"/creator-mlx" || authority.last.ExpectedModelHashSource != ExpectedModelHashSourcePoolManifest {
		t.Fatalf("authority claim = %+v", authority.last)
	}
	rejecting := verifying()
	rejecting.routeErr = fmt.Errorf("%w: entry removed", ErrPoolOperatorAttestationRejected)
	for name, tc := range map[string]struct {
		snapshot  bool
		authority *fakePoolManifestAuthority
		labels    SettlementPoolLabelSource
	}{
		"authority rejects":     {true, rejecting, poolManifestLabels},
		"no authority":          {true, nil, poolManifestLabels},
		"label moved":           {true, verifying(), movedPoolLabels},
		"pool model, no route":  {false, verifying(), poolManifestLabels},
		"pool event mid-commit": {true, &fakePoolManifestAuthority{fencedPoolAuthority: fencedPoolAuthority{highWaters: []int64{7, 8}}}, poolManifestLabels},
	} {
		t.Run(name, func(t *testing.T) {
			gross, quarantined, reason := run(t, tc.snapshot, tc.authority, tc.labels)
			if gross != 0 || quarantined != 1 || reason != PoolManifestRouteNotSettlementEligible {
				t.Fatalf("gross=%d quarantined=%d reason=%q, want zero %s", gross, quarantined, reason, PoolManifestRouteNotSettlementEligible)
			}
		})
	}
	if !errors.Is(rejecting.routeErr, ErrPoolOperatorAttestationRejected) {
		t.Fatal("fixture")
	}
}
