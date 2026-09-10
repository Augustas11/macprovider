package ws_test

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// SPEC-047-R001 v0.1.5 / R008: operator decision store semantics: stale head,
// idempotent replay, catalog match + member recording round trip, the
// provider listing, the global state query, and dual-control pending records
// (single approval, replay, expiry, invalidation on any append).
func TestModelAdmissionDecisionStoreCASAndPending(t *testing.T) {
	for _, tc := range []struct {
		name string
		open func(t *testing.T) providerws.ModelAdmissionStore
	}{
		{name: "memory", open: func(t *testing.T) providerws.ModelAdmissionStore { return providerws.NewMemoryModelAdmissionStore() }},
		{name: "sqlite", open: func(t *testing.T) providerws.ModelAdmissionStore {
			db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = db.Close() })
			store, err := providerws.NewSQLiteModelAdmissionStore(db.DB())
			if err != nil {
				t.Fatal(err)
			}
			return store
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			store := tc.open(t)
			ctx := context.Background()
			offer := providerws.ModelAdmissionEvent{
				ProviderID:               "provider-byom-a",
				CandidateID:              stableModelAdmissionCandidateID("cas"),
				ServedModelRef:           "ollama:qwen3-8b",
				CatalogModelKey:          "qwen3-8b",
				DiscoveryDigestSHA256:    stringsOf("a", 64),
				EvaluationDigestSHA256:   stringsOf("b", 64),
				RequestedDisclosureClass: "catalog_binding_requested",
				ReasonCode:               "provider_offer_submitted",
				RequestID:                "request_offer_cas",
				Nonce:                    "nonce_offer_cas",
				PayloadDigestSHA256:      stringsOf("c", 64),
				SignatureDigestSHA256:    stringsOf("d", 64),
				CreatedAt:                time.Unix(1800000020, 0).UTC(),
				RuntimeSource:            "ollama",
				CatalogMatchState:        "catalog_matched",
				CatalogRowModelID:        "Qwen/Qwen3-8B",
				CatalogRowModelSHA256:    stringsOf("5", 64),
				CatalogReleaseID:         "autotune-2026-09-09-static",
				CatalogCandidateSHA256:   stringsOf("3", 64),
				CatalogSignerKeyID:       "test-key",
				CatalogMembers: []providerws.ModelAdmissionCatalogMember{
					{Source: "candidate_row", HashAlgorithm: "snapshot_manifest_v1", Hash: stringsOf("5", 64)},
					{Source: "artifact_feed", HashAlgorithm: "gguf_blob_sha256_v1", Hash: stringsOf("6", 64), ArtifactID: "qwen3-8b-q4", ArtifactFeedSHA256: stringsOf("7", 64), ArtifactFeedSignerKeyID: "test-key", ArtifactCandidateCatalogSHA256: stringsOf("3", 64)},
				},
			}
			submitted, _, err := store.AppendModelAdmissionOffer(ctx, offer)
			if err != nil {
				t.Fatal(err)
			}
			head, ok, err := store.LatestModelAdmissionStatus(ctx, offer.ProviderID, offer.CandidateID)
			if err != nil || !ok {
				t.Fatalf("head lookup ok=%v err=%v", ok, err)
			}
			if head.CatalogMatchState != "catalog_matched" || head.RuntimeSource != "ollama" || head.CatalogRowModelID != "Qwen/Qwen3-8B" || len(head.CatalogMembers) != 2 || head.CatalogMembers[1].ArtifactID != "qwen3-8b-q4" || head.CatalogMembers[1].ArtifactFeedSHA256 != stringsOf("7", 64) {
				t.Fatalf("catalog match did not round-trip: %+v", head)
			}
			if head.CatalogMembers[0].ArtifactID != "" || head.CatalogMembers[0].ArtifactFeedSHA256 != "" {
				t.Fatalf("candidate_row member must carry no artifact provenance: %+v", head.CatalogMembers[0])
			}

			decision := submitted
			decision.State = "catalog_priced"
			decision.Actor = "operator:alice"
			decision.ReasonCode = "operator_priced"
			decision.RequestID = "operator_decision_" + offer.CandidateID + "_key-1"
			decision.Nonce = "operator_decision_nonce_1"
			decision.PayloadDigestSHA256 = stringsOf("e", 64)
			decision.CreatedAt = time.Unix(1800000030, 0).UTC()
			decision.EvaluatedReleaseGeneration = 7
			decision = withTrustedCatalogDecisionFields(decision)

			if _, _, err := store.CASAppendModelAdmissionDecision(ctx, decision, stringsOf("0", 64)); !errors.Is(err, providerws.ErrModelAdmissionStaleHead) {
				t.Fatalf("stale head expected, got %v", err)
			}
			priced, replayed, err := store.CASAppendModelAdmissionDecision(ctx, decision, submitted.CoordinatorEventID)
			if err != nil || replayed {
				t.Fatalf("catalog_priced CAS replayed=%v err=%v", replayed, err)
			}
			if priced.Actor != "operator:alice" || priced.EvaluatedReleaseGeneration != 7 || priced.PreviousState != submitted.State {
				t.Fatalf("decision event fields lost: %+v", priced)
			}
			// Idempotent replay: same request id + payload digest answers the
			// committed event even though the head has moved on.
			again, replayed, err := store.CASAppendModelAdmissionDecision(ctx, decision, submitted.CoordinatorEventID)
			if err != nil || !replayed || again.CoordinatorEventID != priced.CoordinatorEventID {
				t.Fatalf("replay expected: replayed=%v err=%v", replayed, err)
			}
			// Same key, different body: conflict, before any head compare.
			conflict := decision
			conflict.PayloadDigestSHA256 = stringsOf("f", 64)
			if _, _, err := store.CASAppendModelAdmissionDecision(ctx, conflict, priced.CoordinatorEventID); err == nil || errors.Is(err, providerws.ErrModelAdmissionStaleHead) {
				t.Fatalf("idempotency conflict expected, got %v", err)
			}

			listed, err := store.LatestModelAdmissionStatusesForProvider(ctx, offer.ProviderID)
			if err != nil || len(listed) != 1 || listed[0].CoordinatorEventID != priced.CoordinatorEventID {
				t.Fatalf("provider listing = %d err=%v", len(listed), err)
			}
			inStates, err := store.LatestModelAdmissionStatusesInStates(ctx, []string{"catalog_priced", "settlement_capable"})
			if err != nil || len(inStates) != 1 || inStates[0].State != "catalog_priced" {
				t.Fatalf("state query = %+v err=%v", inStates, err)
			}
			if none, err := store.LatestModelAdmissionStatusesInStates(ctx, []string{"settlement_capable"}); err != nil || len(none) != 0 {
				t.Fatalf("state query must not return other states: %+v err=%v", none, err)
			}

			// Dual control: pending record, replay, single consumption, expiry.
			pending := providerws.PendingModelAdmissionDecision{
				ID:            "pend-1",
				ProviderID:    offer.ProviderID,
				CandidateID:   offer.CandidateID,
				NextState:     "settlement_capable",
				ReasonCode:    "operator_settlement",
				RequestDigest: stringsOf("1", 64),
				RequestID:     "operator_decision_" + offer.CandidateID + "_key-2",
				EvaluatedHead: priced.CoordinatorEventID,
				RequestedBy:   "operator:alice",
				CreatedAt:     time.Now().UTC(),
			}
			created, replayed, err := store.CreatePendingModelAdmissionDecision(ctx, pending)
			if err != nil || replayed || created.ExpiresAt.Before(created.CreatedAt.Add(23*time.Hour)) {
				t.Fatalf("pending create replayed=%v err=%v expires=%v", replayed, err, created.ExpiresAt)
			}
			if _, replayed, err := store.CreatePendingModelAdmissionDecision(ctx, pending); err != nil || !replayed {
				t.Fatalf("pending replay replayed=%v err=%v", replayed, err)
			}
			pendingConflict := pending
			pendingConflict.RequestDigest = stringsOf("2", 64)
			if _, _, err := store.CreatePendingModelAdmissionDecision(ctx, pendingConflict); err == nil {
				t.Fatal("pending same key different digest must conflict")
			}
			if got, ok, err := store.PendingModelAdmissionDecision(ctx, "pend-1"); err != nil || !ok || got.Invalidated || !got.ConsumedAt.IsZero() || got.RequestedBy != "operator:alice" || got.EvaluatedHead != priced.CoordinatorEventID {
				t.Fatalf("pending lookup: %+v ok=%v err=%v", got, ok, err)
			}
			if _, ok, err := store.PendingModelAdmissionDecision(ctx, "pend-missing"); err != nil || ok {
				t.Fatalf("unknown pending must not be found: ok=%v err=%v", ok, err)
			}
			// An approval append consumes its own record atomically while
			// invalidating every other open record for the candidate.
			approvalPending := pending
			approvalPending.ID = "pend-approve"
			approvalPending.RequestID = "operator_decision_" + offer.CandidateID + "_key-5"
			if _, _, err := store.CreatePendingModelAdmissionDecision(ctx, approvalPending); err != nil {
				t.Fatal(err)
			}
			sibling := pending
			sibling.ID = "pend-sibling"
			sibling.RequestID = "operator_decision_" + offer.CandidateID + "_key-6"
			if _, _, err := store.CreatePendingModelAdmissionDecision(ctx, sibling); err != nil {
				t.Fatal(err)
			}
			settle := priced
			settle.State = "settlement_capable"
			settle.Actor = "operator:bob"
			settle.ReasonCode = "operator_settlement"
			settle.RequestID = "operator_approval_pend-approve_a1"
			settle.Nonce = "operator_approval_nonce_1"
			settle.PayloadDigestSHA256 = stringsOf("c", 64)
			settle.CreatedAt = time.Unix(1800000045, 0).UTC()
			settled, replayed, err := store.AppendModelAdmissionApproval(ctx, settle, priced.CoordinatorEventID, providerws.PendingModelAdmissionApproval{PendingID: "pend-approve", RequestKey: settle.RequestID, Digest: stringsOf("c", 64), Actor: "operator:bob"})
			if err != nil || replayed || settled.State != "settlement_capable" {
				t.Fatalf("approval append replayed=%v err=%v state=%s", replayed, err, settled.State)
			}
			consumedRecord, ok, err := store.PendingModelAdmissionDecision(ctx, "pend-approve")
			if err != nil || !ok || consumedRecord.Invalidated || consumedRecord.ConsumedAt.IsZero() || consumedRecord.ConsumedBy != "operator:bob" || consumedRecord.ConsumedEventID != settled.CoordinatorEventID || consumedRecord.ApprovalRequestKey != settle.RequestID {
				t.Fatalf("approved record must be consumed, not invalidated: %+v err=%v", consumedRecord, err)
			}
			if _, ok, err := store.PendingModelAdmissionDecisionByRequest(ctx, offer.ProviderID, offer.CandidateID, approvalPending.RequestID); err != nil || !ok {
				t.Fatalf("consumed record must stay addressable by its request: ok=%v err=%v", ok, err)
			}
			if siblingRecord, _, _ := store.PendingModelAdmissionDecision(ctx, "pend-sibling"); !siblingRecord.Invalidated {
				t.Fatal("sibling record must be invalidated by the append")
			}
			priced = settled
			// Any append for the candidate invalidates open pending records.
			open := pending
			open.ID = "pend-open"
			open.RequestID = "operator_decision_" + offer.CandidateID + "_key-4"
			if _, _, err := store.CreatePendingModelAdmissionDecision(ctx, open); err != nil {
				t.Fatal(err)
			}
			revoke := priced
			revoke.State = "revoked"
			revoke.Actor = ""
			revoke.ReasonCode = "runtime_identity_drift"
			revoke.RequestID = "drift_1"
			revoke.Nonce = "drift_nonce_1"
			revoke.PayloadDigestSHA256 = stringsOf("b", 64)
			revoke.CreatedAt = time.Unix(1800000050, 0).UTC()
			if _, err := store.AppendModelAdmissionDecision(ctx, revoke); err != nil {
				t.Fatalf("revocation failed: %v", err)
			}
			got, ok, err := store.PendingModelAdmissionDecision(ctx, "pend-open")
			if err != nil || !ok || !got.Invalidated {
				t.Fatalf("pending lookup ok=%v invalidated=%v err=%v", ok, got.Invalidated, err)
			}
		})
	}
}
