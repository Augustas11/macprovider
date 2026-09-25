package sqlite

import (
	"context"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

// #1690 review L-1: the first authoritative "finality not found" time is
// recorded once, survives the per-lookup REPLACE of the reconcile attempt
// row, and is cleared when the coordinator answers with finality.
func TestSettlementFinalityNotFoundFirstTimeSurvivesReconcileAttempts(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	candidate := fallbackTestCandidate(t, store)
	if err := store.SaveSettlementFallbackCandidate(ctx, candidate); err != nil {
		t.Fatal(err)
	}
	reservation := storage.ActiveReservation{
		AccountID: candidate.AccountID, RequestID: candidate.RequestID, CreatedAt: candidate.ReservationCreatedAt,
	}
	if err := store.MarkSettlementReconcileAttempt(ctx, reservation); err != nil {
		t.Fatal(err)
	}
	t0 := time.Date(2026, 9, 25, 10, 0, 0, 0, time.UTC)
	first, err := store.RecordSettlementFinalityNotFound(ctx, reservation, t0)
	if err != nil || !first.Equal(t0) {
		t.Fatalf("first record=%v err=%v, want %v", first, err, t0)
	}
	if err := store.MarkSettlementReconcileAttempt(ctx, reservation); err != nil {
		t.Fatal(err)
	}
	again, err := store.RecordSettlementFinalityNotFound(ctx, reservation, t0.Add(30*time.Minute))
	if err != nil || !again.Equal(t0) {
		t.Fatalf("after another attempt: first=%v err=%v, want the original %v", again, err, t0)
	}
	if err := store.ClearSettlementFinalityNotFound(ctx, reservation); err != nil {
		t.Fatal(err)
	}
	later := t0.Add(2 * time.Hour)
	if reset, err := store.RecordSettlementFinalityNotFound(ctx, reservation, later); err != nil || !reset.Equal(later) {
		t.Fatalf("after clear: first=%v err=%v, want %v", reset, err, later)
	}
}
