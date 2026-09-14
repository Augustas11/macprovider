package billing

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"reflect"
	"strings"
	"testing"
	"time"
)

func artifactAdmissionFixture(t *testing.T, store *Store) RouteSnapshot {
	t.Helper()
	snapshot := testRouteSnapshot()
	rate := RateCardEntry{PromptCreditsPerMtok: 700000, CompletionCreditsPerMtok: 1700000}
	rate.SetPromptCacheHitCreditsPerMtok(130000)
	cfg := RewardsConfig{RateCard: map[string]RateCardEntry{"model-a": rate, "default": {PromptCreditsPerMtok: 9000000, CompletionCreditsPerMtok: 9000000}}, ProviderShare: 0.83, GlobalMultiplier: 1.2}
	id, err := store.InsertConfigSnapshot(context.Background(), cfg, time.UnixMilli(snapshot.RequestStartTSUnixMS))
	if err != nil {
		t.Fatal(err)
	}
	snapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
	snapshot.ModelAdmissionCandidateID = "byom_" + strings.Repeat("a", 52)
	snapshot.ModelAdmissionCoordinatorEventID = strings.Repeat("7", 64)
	snapshot.ModelAdmissionServedModelRef = snapshot.ModelID
	snapshot.ModelAdmissionCatalogModelKey = "model-a"
	snapshot.ModelAdmissionDiscoveryDigestSHA256 = strings.Repeat("8", 64)
	snapshot.ModelAdmissionEvaluationDigestSHA256 = strings.Repeat("9", 64)
	snapshot.ArtifactAdmissionEvidence = &ArtifactAdmissionEvidence{
		ArtifactFeedSHA256: strings.Repeat("a", 64), ArtifactID: "mlx-4bit", ArtifactHash: snapshot.ExpectedCatalogModelHash, ArtifactHashAlgorithm: snapshot.ExpectedCatalogModelHashAlgorithm,
		ArtifactFeedSignerKeyID: "fixture", CandidateCatalogSHA256: strings.Repeat("b", 64), ArtifactReleaseID: "fixture-release", CandidateReleaseID: "fixture-release", CandidateSignerKeyID: "fixture",
		RateCardSHA256: strings.Repeat("c", 64), RateCardVersion: strings.Repeat("d", 64), RateCardSignerKeyID: "fixture", CatalogModelKey: "model-a", ConfigSnapshotID: id,
		PromptRatePerMtok: 700000, PromptCacheHitRatePerMtok: 130000, CompletionRatePerMtok: 1700000, ProviderShareBPS: 8300, GlobalMultiplierPPM: 1200000,
		PriceUnit: "credits_per_million_tokens", ProviderSessionID: *snapshot.ProviderSessionID, ProviderReceiptKeyID: snapshot.ProviderReceiptKeyID,
		AuthorityExpiresAtUnixMS: snapshot.RouteDecisionTSUnixMS + 60000, ProbeExpiresAtUnixMS: snapshot.RouteDecisionTSUnixMS + 60000,
	}
	return snapshot
}
func TestArtifactAdmissionSnapshotProvenanceRoundTripAndLegacy(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	snapshot := artifactAdmissionFixture(t, store)
	digest, err := store.InsertRouteSnapshot(context.Background(), snapshot)
	if err != nil {
		t.Fatal(err)
	}
	conn, err := store.db.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	loaded, got, err := loadSettlementRouteSnapshotConn(context.Background(), conn, SettlementReceiptIdentity{snapshot.AccountScope, snapshot.RequestID, snapshot.AttemptN, snapshot.ProviderID})
	if err != nil || got != digest || !reflect.DeepEqual(loaded.ArtifactAdmissionEvidence, snapshot.ArtifactAdmissionEvidence) {
		t.Fatalf("roundtrip %s %+v %v", got, loaded.ArtifactAdmissionEvidence, err)
	}
	for _, field := range []string{"artifact_feed_sha256", "artifact_id", "artifact_hash", "artifact_hash_algorithm", "artifact_feed_signer_key_id", "candidate_catalog_sha256"} {
		t.Run(field, func(t *testing.T) {
			changed := cloneMap(snapshot.Value())
			changed[field] = "substituted"
			other, _, err := CanonicalSHA256Hex(changed)
			if err != nil || other == digest {
				t.Fatalf("not digest bound: %v", err)
			}
			delete(changed, field)
			raw, _ := json.Marshal(changed)
			var partial RouteSnapshot
			if err := json.Unmarshal(raw, &partial); err != nil {
				t.Fatal(err)
			}
			if partial.Validate() == nil {
				t.Fatal("partial evidence accepted")
			}
		})
	}
	legacy := snapshot
	legacy.ArtifactAdmissionEvidence = nil
	value := legacy.Value()
	for _, key := range []string{"artifact_feed_sha256", "artifact_id", "artifact_hash", "artifact_hash_algorithm", "artifact_feed_signer_key_id", "candidate_catalog_sha256"} {
		if _, ok := value[key]; ok {
			t.Fatalf("legacy gained %s", key)
		}
	}
	if legacy.Validate() != nil {
		t.Fatal("legacy no longer valid")
	}
}
func TestArtifactAdmissionRejectsSubstitutionAndCapturedRateDrift(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	original := artifactAdmissionFixture(t, store)
	for name, mutate := range map[string]func(*ArtifactAdmissionEvidence){
		"release":       func(e *ArtifactAdmissionEvidence) { e.ArtifactReleaseID = "other" },
		"signer":        func(e *ArtifactAdmissionEvidence) { e.ArtifactFeedSignerKeyID = "other-trusted" },
		"hash":          func(e *ArtifactAdmissionEvidence) { e.ArtifactHash = strings.Repeat("f", 64) },
		"session":       func(e *ArtifactAdmissionEvidence) { e.ProviderSessionID = "old" },
		"expired-probe": func(e *ArtifactAdmissionEvidence) { e.ProbeExpiresAtUnixMS = original.RouteDecisionTSUnixMS },
		"price-unit":    func(e *ArtifactAdmissionEvidence) { e.PriceUnit = "dollars" },
	} {
		t.Run(name, func(t *testing.T) {
			s := original
			e := *s.ArtifactAdmissionEvidence
			mutate(&e)
			s.ArtifactAdmissionEvidence = &e
			if s.Validate() == nil {
				t.Fatal("invalid authority accepted")
			}
		})
	}
	e := *original.ArtifactAdmissionEvidence
	if err := store.VerifyArtifactAdmissionConfig(context.Background(), e); err != nil {
		t.Fatal(err)
	}
	e.PromptCacheHitRatePerMtok++
	if store.VerifyArtifactAdmissionConfig(context.Background(), e) == nil {
		t.Fatal("captured cache rate drift accepted")
	}
	// A later config cannot alter or repair the immutable selected snapshot.
	cfg := RewardsConfig{RateCard: map[string]RateCardEntry{"model-a": e.RateEntry()}, ProviderShare: 0.83, GlobalMultiplier: 1.2}
	if _, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Now()); err != nil {
		t.Fatal(err)
	}
	if store.VerifyArtifactAdmissionConfig(context.Background(), e) == nil {
		t.Fatal("mutable config repaired captured mismatch")
	}
	if err := store.VerifyArtifactAdmissionConfig(context.Background(), *original.ArtifactAdmissionEvidence); err != nil {
		t.Fatal(err)
	}
}

func TestArtifactAdmissionRecoveryUsesCapturedCandidateRates(t *testing.T) {
	ctx := context.Background()
	reqStore, store := newRequestAndBillingStores(t)
	route := artifactAdmissionFixture(t, store)
	route.ModelID = "mlx-community/Runtime-4bit"
	route.ModelAdmissionServedModelRef = route.ModelID
	route.AccountScope = AccountScopeForSettlement("recovery-buyer")
	if _, err := store.InsertRouteSnapshot(ctx, route); err != nil {
		t.Fatal(err)
	}
	e := route.ArtifactAdmissionEvidence
	prompt, cached, completion := int64(10), int64(4), int64(2)
	ts := time.UnixMilli(route.RequestStartTSUnixMS)
	row := requestlog.Row{TSUtc: ts, RequestID: route.RequestID, AccountID: "recovery-buyer", Model: route.ModelID, ProviderAssignedID: *route.ProviderSessionID, PromptTokens: &prompt, CachedPromptTokens: &cached, CompletionTokens: &completion, Status: 200, BuyerIP: "127.0.0.1"}
	input := HotPathInput{RequestID: row.RequestID, ProviderID: route.ProviderID, ProviderAssignedID: row.ProviderAssignedID, Model: row.Model, TSUtc: ts, Status: 200, PromptTokens: &prompt, CachedPromptTokens: &cached, CompletionTokens: &completion, ConfigSnapshotID: e.ConfigSnapshotID, RateEntry: e.RateEntry(), MultiplierPPM: e.GlobalMultiplierPPM, ProviderShareBps: e.ProviderShareBPS}
	if err := store.WriteRequestLogWithIdentity(ctx, reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	// A later configuration and runtime-model fallback cannot reprice this attempt.
	if _, err := store.InsertConfigSnapshot(ctx, testRewards(), ts.Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	recovery := RecoverInput{ScanFrom: ts.Add(-time.Minute), ScanTo: ts.Add(time.Minute), Source: "startup_scan"}
	want := ComputeCreditsWithCache(&prompt, &cached, &completion, nil, UsageProviderReported, FaultNone, e.RateEntry(), e.GlobalMultiplierPPM, e.ProviderShareBPS)
	for i := 0; i < 2; i++ {
		if err := store.RecoverLedger(ctx, recovery); err != nil {
			t.Fatal(err)
		}
		var gross, provider, rate int64
		if err := store.db.QueryRow(`SELECT gross_credits,provider_credits,prompt_rate_per_mtok FROM ledger_request_credits WHERE request_id=? AND quarantined=0`, route.RequestID).Scan(&gross, &provider, &rate); err != nil {
			t.Fatal(err)
		}
		if gross != want.GrossCredits || provider != want.ProviderCredits || rate != e.PromptRatePerMtok {
			t.Fatalf("recovered wrong rates: %d/%d/%d want %d/%d/%d", gross, provider, rate, want.GrossCredits, want.ProviderCredits, e.PromptRatePerMtok)
		}
	}
}

func TestArtifactAdmissionSignedReceiptKeepsCapturedCacheRate(t *testing.T) {
	ctx := context.Background()
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	input := settlementVerifierInputFromFixture(t, fixtures, firstSettlementTupleWithTerminal(t, fixtures, "normal_done"), pubkey)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	template := artifactAdmissionFixture(t, store)
	route := &input.RouteSnapshot
	route.RouteSnapshotMode = RouteSnapshotModeEnforce
	route.RouteSnapshotPolicyVersion = RouteSnapshotPolicyVersion
	route.ProviderReportedModelHashAlgorithm = template.ProviderReportedModelHashAlgorithm
	route.ExpectedCatalogModelHashAlgorithm = template.ExpectedCatalogModelHashAlgorithm
	route.ModelAdmissionCandidateID = template.ModelAdmissionCandidateID
	route.ModelAdmissionCoordinatorEventID = template.ModelAdmissionCoordinatorEventID
	route.ModelAdmissionServedModelRef = route.ModelID
	route.ModelAdmissionCatalogModelKey = "artifact-candidate"
	route.ModelAdmissionDiscoveryDigestSHA256 = template.ModelAdmissionDiscoveryDigestSHA256
	route.ModelAdmissionEvaluationDigestSHA256 = template.ModelAdmissionEvaluationDigestSHA256
	rate := RateCardEntry{PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 1000000}
	rate.SetPromptCacheHitCreditsPerMtok(250000)
	cfg := RewardsConfig{ProviderShare: 1, GlobalMultiplier: 1, RateCard: map[string]RateCardEntry{"artifact-candidate": rate, "default": {PromptCreditsPerMtok: 9000000, CompletionCreditsPerMtok: 9000000}}}
	id, err := store.InsertConfigSnapshot(ctx, cfg, time.UnixMilli(route.RequestStartTSUnixMS))
	if err != nil {
		t.Fatal(err)
	}
	e := *template.ArtifactAdmissionEvidence
	e.ArtifactHash = route.ExpectedCatalogModelHash
	e.CatalogModelKey = route.ModelAdmissionCatalogModelKey
	e.ConfigSnapshotID = id
	e.PromptRatePerMtok = 1000000
	e.PromptCacheHitRatePerMtok = 250000
	e.CompletionRatePerMtok = 1000000
	e.ProviderShareBPS = 10000
	e.GlobalMultiplierPPM = 1000000
	e.ProviderSessionID = *route.ProviderSessionID
	e.ProviderReceiptKeyID = route.ProviderReceiptKeyID
	e.AuthorityExpiresAtUnixMS = route.RouteDecisionTSUnixMS + 60000
	e.ProbeExpiresAtUnixMS = route.RouteDecisionTSUnixMS + 60000
	route.ArtifactAdmissionEvidence = &e
	digest, _, err := route.Digest()
	if err != nil {
		t.Fatal(err)
	}
	input.Header = settlementHeaderWithCanonicalMutationAndTestSignature(t, input.Header, func(tuple map[string]any) {
		tuple["route_snapshot_mode"] = RouteSnapshotModeEnforce
		tuple["route_snapshot_policy_version"] = RouteSnapshotPolicyVersion
		tuple["route_snapshot_digest"] = digest
	})
	seedSettlementReceiptEvidence(t, store, input)
	cached := input.ExpectedUsage.BillableInputTokens / 2
	want := insertSPEC022CachedReceiptLedgerCredit(t, store.db, input, cached, id)
	setSettlementReceiptNow(store, input.ReceiptReceivedUnixMS)
	state, err := store.IngestSettlementReceipt(ctx, SettlementReceiptIngestionInput{SettlementReceiptIdentity: settlementIdentityFromInput(input), Header: input.Header, ProviderReceiptPubkey: pubkey, receiptReceivedUnixMS: input.ReceiptReceivedUnixMS})
	if err != nil {
		t.Fatal(err)
	}
	if state.SettlementOutcome != SettlementOutcomeVerified || state.ReceiptResult != SettlementReceiptResultValid {
		t.Fatalf("signed artifact cache receipt: %+v", state)
	}
	if got := scalar(t, store.db, `SELECT provider_credits FROM spec022_payable_request_credits WHERE request_id=?`, input.RequestID); got != want.ProviderCredits {
		t.Fatalf("cache repriced %d want %d", got, want.ProviderCredits)
	}
	// A persisted valid verdict cannot bless a later loss of the complete
	// artifact extension, including when there are no cached prompt tokens.
	stripArtifactAdmissionExtension(t, store, input.RouteSnapshot)
	for _, cachedTokens := range []int64{cached, 0} {
		if _, err := store.db.Exec(`UPDATE ledger_request_credits SET cached_prompt_tokens=? WHERE request_id=?`, cachedTokens, input.RequestID); err != nil {
			t.Fatal(err)
		}
		before := scalar(t, store.db, `SELECT provider_credits FROM ledger_request_credits WHERE request_id=?`, input.RequestID)
		if _, err := loadArtifactAdmissionForAttempt(ctx, store.db, settlementIdentityFromInput(input)); err == nil {
			t.Errorf("removed extension accepted as legacy (cached=%d)", cachedTokens)
		}
		if _, err := syncVerifiedReceiptLedgerCreditForAttemptTx(ctx, store.db, input.RequestID, input.AttemptN, input.ProviderID); err == nil {
			t.Errorf("verified receipt sync accepted removed extension (cached=%d)", cachedTokens)
		}
		if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_request_credits WHERE request_id=?`, input.RequestID); got != before {
			t.Errorf("corrupt route changed credit from %d to %d", before, got)
		}
	}
}

func stripArtifactAdmissionExtension(t *testing.T, store *Store, route RouteSnapshot) {
	t.Helper()
	// Simulate corrupt retained storage; ordinary SQL updates are prohibited.
	// The production immutable trigger is unchanged by this fixture.
	if _, err := store.db.Exec(`DROP TRIGGER trg_srs_immutable`); err != nil {
		t.Fatal(err)
	}
	value := route.Value()
	encoded, err := json.Marshal(route.ArtifactAdmissionEvidence)
	if err != nil {
		t.Fatal(err)
	}
	var extension map[string]any
	if err := json.Unmarshal(encoded, &extension); err != nil {
		t.Fatal(err)
	}
	for key := range extension {
		delete(value, key)
	}
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`UPDATE settlement_route_snapshots SET route_snapshot_json=? WHERE account_scope=? AND request_id=? AND attempt_n=? AND provider_id=?`, string(raw), route.AccountScope, route.RequestID, route.AttemptN, route.ProviderID); err != nil {
		t.Fatal(err)
	}
}

func TestArtifactAdmissionRecoveryRejectsWholeExtensionLoss(t *testing.T) {
	for _, scenario := range []struct {
		cached       int64
		missingRoute bool
	}{{0, false}, {4, false}, {0, true}, {4, true}} {
		t.Run(fmt.Sprintf("cached_%d_missing_route_%t", scenario.cached, scenario.missingRoute), func(t *testing.T) {
			cached := scenario.cached
			ctx := context.Background()
			reqStore, store := newRequestAndBillingStores(t)
			route := artifactAdmissionFixture(t, store)
			route.ModelID = "mlx-community/Runtime-4bit"
			route.ModelAdmissionServedModelRef = route.ModelID
			route.AccountScope = AccountScopeForSettlement("recovery-buyer")
			if _, err := store.InsertRouteSnapshot(ctx, route); err != nil {
				t.Fatal(err)
			}
			e := route.ArtifactAdmissionEvidence
			prompt, completion := int64(10), int64(2)
			ts := time.UnixMilli(route.RequestStartTSUnixMS)
			row := requestlog.Row{TSUtc: ts, RequestID: route.RequestID, AccountID: "recovery-buyer", Model: route.ModelID, ProviderAssignedID: *route.ProviderSessionID, PromptTokens: &prompt, CachedPromptTokens: &cached, CompletionTokens: &completion, Status: 200, BuyerIP: "127.0.0.1"}
			input := HotPathInput{RequestID: row.RequestID, ProviderID: route.ProviderID, ProviderAssignedID: row.ProviderAssignedID, Model: row.Model, TSUtc: ts, Status: 200, PromptTokens: &prompt, CachedPromptTokens: &cached, CompletionTokens: &completion, ConfigSnapshotID: e.ConfigSnapshotID, RateEntry: e.RateEntry(), MultiplierPPM: e.GlobalMultiplierPPM, ProviderShareBps: e.ProviderShareBPS}
			if err := store.WriteRequestLogWithIdentity(ctx, reqStore, row, input); err != nil {
				t.Fatal(err)
			}
			markSPEC022ReceiptVerified(t, store.db, SettlementVerifyInput{RouteSnapshot: route, AccountScope: route.AccountScope, RequestID: route.RequestID, AttemptN: route.AttemptN, ProviderID: route.ProviderID, TerminalState: TerminalStateNormalDone, TerminalStateTSUnixMS: ts.UnixMilli(), ReceiptReceivedUnixMS: ts.UnixMilli(), OutputHash: strings.Repeat("e", 64), ExpectedUsage: SettlementUsage{BillableInputTokens: prompt, BillableOutputTokens: completion, ObservedInputTokens: prompt, ObservedOutputTokens: completion}})
			stripArtifactAdmissionExtension(t, store, route)
			if scenario.missingRoute {
				// Retained enforce verdict with the entire route missing is also
				// corruption, not evidence of a genuinely legacy request.
				if _, err := store.db.Exec(`DELETE FROM settlement_route_snapshots WHERE request_id=?`, route.RequestID); err != nil {
					t.Fatal(err)
				}
			}
			if err := store.RecoverLedger(ctx, RecoverInput{ScanFrom: ts.Add(-time.Minute), ScanTo: ts.Add(time.Minute), Source: "startup_scan"}); err == nil {
				t.Fatal("corrupt artifact route recovered using legacy rates")
			}
			if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id=?`, route.RequestID); got != 0 {
				t.Fatalf("corrupt route created %d ledger rows", got)
			}
		})
	}
}

func TestArtifactAdmissionAbsentExtensionRequiresIntactLegacySnapshot(t *testing.T) {
	ctx := context.Background()
	_, store := newRequestAndBillingStores(t)
	route := testRouteSnapshot()
	id := SettlementReceiptIdentity{route.AccountScope, route.RequestID, route.AttemptN, route.ProviderID}
	if evidence, err := loadArtifactAdmissionForAttempt(ctx, store.db, id); err != nil || evidence != nil {
		t.Fatalf("absent route compatibility: %v %v", evidence, err)
	}
	if _, err := store.InsertRouteSnapshot(ctx, route); err != nil {
		t.Fatal(err)
	}
	if evidence, err := loadArtifactAdmissionForAttempt(ctx, store.db, id); err != nil || evidence != nil {
		t.Fatalf("intact legacy compatibility: %v %v", evidence, err)
	}
	if _, err := store.db.Exec(`DROP TRIGGER trg_srs_immutable`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`UPDATE settlement_route_snapshots SET route_snapshot_json='{}' WHERE request_id=?`, route.RequestID); err != nil {
		t.Fatal(err)
	}
	if _, err := loadArtifactAdmissionForAttempt(ctx, store.db, id); err == nil {
		t.Fatal("corrupt legacy snapshot accepted")
	}
}
