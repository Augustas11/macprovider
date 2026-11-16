package ws

import (
	"context"
	"database/sql"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/computeintegrity"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

// sanctionHoldHarness is a scoring harness whose states and holds live in
// one real billing database, with catalog row "public-ci" whose model_id is
// scoringModel.
func sanctionHoldHarness(t *testing.T) (*scoringHarness, *billing.Store, *computeintegrity.ScoringStore, *sql.DB) {
	t.Helper()
	h := newScoringHarness(t, map[string]string{"a": "github:1"}, nil)
	installAliasCatalog(h.server, aliasCatalog(t, map[string]string{"public-ci": scoringModel}), nil)
	reqStore, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "ledger.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reqStore.Close() })
	holds, err := billing.NewStore(reqStore.DB())
	if err != nil {
		t.Fatal(err)
	}
	scoring, err := computeintegrity.NewScoringStore(context.Background(), reqStore.DB())
	if err != nil {
		t.Fatal(err)
	}
	h.engine.deps.Store = scoring
	h.engine.deps.Holds = holds
	return h, holds, scoring, reqStore.DB()
}

const sanctionHoldTimeLayout = "2006-01-02T15:04:05.000000000Z"

// insertServedCredit records a provider credit of provider "a" at ts whose
// attempt's route snapshot names model with the given served_model_dispatch.
func insertServedCredit(t *testing.T, store *billing.Store, db *sql.DB, requestID, model string, flagged bool, ts time.Time, credits int64) {
	t.Helper()
	ctx := context.Background()
	at := ts.UTC().Format(sanctionHoldTimeLayout)
	if _, err := db.ExecContext(ctx, `
INSERT INTO ledger_request_credits (
    request_id, attempt_n, provider_id, provider_assigned_id, ts_utc, model,
    status, stream, usage_source, prompt_rate_per_mtok, completion_rate_per_mtok,
    global_multiplier_ppm, gross_credits, provider_share_bps, provider_credits,
    fault_flag, recovery_source, created_at_utc
) VALUES (?, 0, 'a', 'as-a', ?, ?, 200, 0, 'provider_reported', 1, 1, 1000000, ?, 9000, ?, 'none', 'hot_path', ?)`,
		requestID, at, model, credits, credits, at); err != nil {
		t.Fatal(err)
	}
	sessionID, generationID := "session-a", "generation-a"
	if _, err := store.InsertRouteSnapshot(ctx, billing.RouteSnapshot{
		AccountScope:                       "acct_sha256:" + strings.Repeat("1", 64),
		RequestID:                          requestID,
		ProviderID:                         "a",
		ProviderSessionID:                  &sessionID,
		ProviderGenerationID:               &generationID,
		PaidEntrypoint:                     "coordinator_buyer_v1_chat_completions",
		ProviderReceiptKeyID:               "ed25519-sha256:" + strings.Repeat("2", 64),
		ProviderReceiptKeySource:           "auth_session",
		ModelID:                            model,
		ProviderReportedModelHash:          strings.Repeat("3", 64),
		ProviderReportedModelHashAlgorithm: modelidentity.SnapshotManifestV1,
		ExpectedCatalogModelHash:           strings.Repeat("3", 64),
		ExpectedCatalogModelHashAlgorithm:  modelidentity.SnapshotManifestV1,
		CatalogID:                          "catalog-a",
		CatalogBodyDigest:                  strings.Repeat("4", 64),
		CatalogSignatureKeyID:              "catalog-key-a",
		CatalogSignaturePubkeyFingerprint:  "ed25519-sha256:" + strings.Repeat("5", 64),
		CatalogExpiresAtUnixMS:             1800000000000,
		Spec008HashStatus:                  "hash_verified",
		RouteSnapshotPolicyVersion:         billing.RouteSnapshotPolicyVersion,
		RouteSnapshotMode:                  billing.RouteSnapshotModeObserve,
		RouteDecisionTSUnixMS:              1716768000100,
		RequestStartTSUnixMS:               1716768000000,
		PendingDeadlineSeconds:             30,
		PromptHashBasis:                    "coordinator_prompt_canonical_v1",
		PromptHash:                         strings.Repeat("6", 64),
		ServedModelDispatch:                flagged,
	}); err != nil {
		t.Fatal(err)
	}
}

// SPEC-022 R-16.2a: a state stored under the row key before holds named the
// sanction identity opens its failure hold on the identity, so a flag-1
// credit served under the row's model_id is withheld.
func TestComputeScoringRestoredRowKeyStateHoldsSanctionIdentity(t *testing.T) {
	h, holds, scoring, db := sanctionHoldHarness(t)
	ctx := context.Background()
	now := h.now()
	start := now.Add(-time.Hour)
	st := computeintegrity.NewKeyState("a", "public-ci", start)
	st.State = computeintegrity.VerificationSuspect
	st.WindowStart = start
	st.ReviewPending = true
	if err := scoring.UpsertKeyState(ctx, st, now); err != nil {
		t.Fatal(err)
	}
	e := h.restartScoring()
	if found, err := e.operatorConfirmFailure(ctx, "a", "public-ci"); !found || err != nil {
		t.Fatalf("confirm failure: found=%v err=%v", found, err)
	}
	insertServedCredit(t, holds, db, "served-model-id", scoringModel, true, start.Add(10*time.Minute), 100)
	insertServedCredit(t, holds, db, "served-other", "model-other", true, start.Add(20*time.Minute), 1000)
	got, err := holds.ComputeIntegrityHolds(ctx, "a")
	if err != nil || len(got) != 1 {
		t.Fatalf("holds=%+v err=%v", got, err)
	}
	if got[0].ModelID != scoringModel || got[0].Kind != computeintegrity.HoldKindFailure || got[0].HeldCredits != 100 {
		t.Fatalf("hold = %+v, want a failure hold on %q holding 100", got[0], scoringModel)
	}
	var payable int64
	if err := db.QueryRowContext(ctx, `SELECT COALESCE(SUM(provider_credits), 0) FROM spec022_payable_request_credits`).Scan(&payable); err != nil {
		t.Fatal(err)
	}
	if payable != 1000 {
		t.Fatalf("payable = %d, want 1000 (the model_id credit withheld)", payable)
	}
}

// A recovery hold opened before this rule under the row-key spelling is still
// released by the ordinary recovering -> passing transition, whether the
// restored state carries that spelling or was stored under the identity (the
// row-key state folded away at restore).
func TestComputeScoringEarlierRowKeyRecoveryHoldStillReleased(t *testing.T) {
	for _, stored := range []string{"public-ci", scoringModel} {
		h, holds, scoring, _ := sanctionHoldHarness(t)
		ctx := context.Background()
		now := h.now()
		start := now.Add(-time.Hour)
		st := computeintegrity.NewKeyState("a", stored, start)
		st.State = computeintegrity.VerificationRecovering
		st.InStreak = 4
		st.StreakScorerOps = []string{"github:2"}
		if err := scoring.UpsertKeyState(ctx, st, now); err != nil {
			t.Fatal(err)
		}
		id, err := holds.OpenComputeIntegrityHold(ctx, "a", "public-ci", computeintegrity.HoldKindRecovery, start, nil, "cooldown_elapsed", start)
		if err != nil {
			t.Fatal(err)
		}
		e := h.restartScoring()
		e.mu.Lock()
		restored := e.states[computeScoringKey{"a", scoringModel}]
		if restored == nil || restored.ModelID != stored {
			e.mu.Unlock()
			t.Fatalf("%s: restored state = %+v", stored, restored)
		}
		tr := restored.Apply(computeintegrity.Outcome{InBand: true, ScorerOperators: []string{"github:3"}, At: now})
		if tr == nil || tr.To != computeintegrity.VerificationPassing || tr.Hold.Kind != computeintegrity.HoldActionReleaseRecovery {
			e.mu.Unlock()
			t.Fatalf("%s: setup: transition = %+v", stored, tr)
		}
		applied := e.applyTransitionLocked(ctx, restored, tr, now)
		e.mu.Unlock()
		if !applied {
			t.Fatalf("%s: recovery release not applied", stored)
		}
		got, err := holds.ComputeIntegrityHolds(ctx, "a")
		if err != nil || len(got) != 1 {
			t.Fatalf("%s: holds=%+v err=%v", stored, got, err)
		}
		if got[0].ID != id || got[0].Status != computeintegrity.HoldReleased || got[0].WindowEnd == nil || got[0].ReleaseReason != "recovery_passed" {
			t.Fatalf("%s: earlier row-key recovery hold = %+v, want released by recovery", stored, got[0])
		}
	}
}
