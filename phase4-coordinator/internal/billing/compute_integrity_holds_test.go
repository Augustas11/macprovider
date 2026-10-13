package billing

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/computeintegrity"
)

// SPEC-022 R-16: a held hold withholds exactly the provider's credits for
// that model inside its window from the payable view and from weekly
// settlement; release restores them unchanged. Nothing is voided or burned.
func TestComputeIntegrityHoldWithholdsAndReleases(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	windowStart := time.Date(2026, 7, 1, 0, 0, 0, 0, time.UTC)
	insertCreditWithOperator(t, store.db, "before", "p-a", windowStart.Add(1*time.Hour), 100)
	insertCreditWithOperator(t, store.db, "inside-1", "p-a", windowStart.Add(3*time.Hour), 200)
	insertCreditWithOperator(t, store.db, "inside-2", "p-a", windowStart.Add(4*time.Hour), 300)
	insertCreditWithOperator(t, store.db, "after", "p-a", windowStart.Add(6*time.Hour), 400)
	insertCreditWithOperator(t, store.db, "other-provider", "p-b", windowStart.Add(3*time.Hour), 500)
	insertCreditWithOperator(t, store.db, "other-model", "p-a", windowStart.Add(3*time.Hour+time.Minute), 600)
	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET model = 'model-b' WHERE request_id = 'other-model'`); err != nil {
		t.Fatal(err)
	}
	payable := func() int64 {
		return scalar(t, store.db, `SELECT COALESCE(SUM(provider_credits), 0) FROM spec022_payable_request_credits`)
	}
	if got := payable(); got != 2100 {
		t.Fatalf("baseline payable=%d want 2100", got)
	}
	end := windowStart.Add(5 * time.Hour)
	id, err := store.OpenComputeIntegrityHold(ctx, "p-a", "model-a", computeintegrity.HoldKindFailure, windowStart.Add(2*time.Hour), &end, "confirmed_failure", windowStart.Add(5*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if got := payable(); got != 1600 {
		t.Fatalf("held payable=%d want 1600 (inside-1 and inside-2 withheld)", got)
	}
	holds, err := store.ComputeIntegrityHolds(ctx, "p-a")
	if err != nil || len(holds) != 1 || holds[0].HeldCredits != 500 || holds[0].Status != computeintegrity.HoldHeld {
		t.Fatalf("holds=%+v err=%v", holds, err)
	}
	if n, err := store.CountHeldComputeIntegrityHolds(ctx); err != nil || n != 1 {
		t.Fatalf("held count=%d err=%v", n, err)
	}

	// Weekly settlement leaves held credits unsettled and untouched.
	if err := store.RunSettlement(ctx, SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, windowStart, windowStart.AddDate(0, 0, 7)); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE settled = 0`); got != 2 {
		t.Fatalf("unsettled=%d want 2 held credits", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE quarantined = 1 OR provider_credits = 0`); got != 0 {
		t.Fatal("a hold must never quarantine or zero a credit")
	}

	if _, err := store.ReleaseComputeIntegrityHold(ctx, id, "", "reviewed", windowStart.Add(10*time.Hour)); err == nil {
		t.Fatal("release without operator_id must be refused")
	}
	released, err := store.ReleaseComputeIntegrityHold(ctx, id, "op-1", "false positive after review", windowStart.Add(10*time.Hour))
	if err != nil || released.Status != computeintegrity.HoldReleased || released.ReleasedBy != "op-1" || released.HeldCredits != 0 {
		t.Fatalf("release: %+v err=%v", released, err)
	}
	if _, err := store.ReleaseComputeIntegrityHold(ctx, id, "op-1", "again", windowStart.Add(11*time.Hour)); !errors.Is(err, ErrComputeIntegrityHoldReleased) {
		t.Fatalf("double release err=%v", err)
	}
	if _, err := store.ReleaseComputeIntegrityHold(ctx, 9999, "op-1", "x", windowStart.Add(11*time.Hour)); !errors.Is(err, ErrComputeIntegrityHoldNotFound) {
		t.Fatalf("missing hold err=%v", err)
	}
	if got := scalar(t, store.db, `SELECT COALESCE(SUM(provider_credits), 0) FROM spec022_payable_request_credits WHERE settled = 0`); got != 500 {
		t.Fatalf("released credits payable again=%d want 500", got)
	}
	next := windowStart.AddDate(0, 0, 7)
	if err := store.RunSettlement(ctx, SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, windowStart, next); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE settled = 0`); got != 0 {
		t.Fatalf("released credits must settle, unsettled=%d", got)
	}
}

// A recovery hold is open-ended until recovery closes it; a passed recovery
// releases it, a failed one keeps it held.
func TestComputeIntegrityRecoveryHoldCloseAndRelease(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	t0 := time.Date(2026, 7, 1, 0, 0, 0, 0, time.UTC)
	insertCreditWithOperator(t, store.db, "r1", "p-a", t0.Add(time.Hour), 100)
	insertCreditWithOperator(t, store.db, "r2", "p-a", t0.Add(30*time.Hour), 200)
	if _, err := store.OpenComputeIntegrityHold(ctx, "p-a", "model-a", computeintegrity.HoldKindRecovery, t0, nil, "cooldown_elapsed", t0); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM spec022_payable_request_credits`); got != 0 {
		t.Fatalf("open recovery hold must withhold later credits too, payable rows=%d", got)
	}
	if err := store.CloseComputeIntegrityRecoveryHold(ctx, "p-a", "model-a", t0.Add(2*time.Hour), false, t0.Add(2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	holds, _ := store.ComputeIntegrityHolds(ctx, "p-a")
	if len(holds) != 1 || holds[0].WindowEnd == nil || holds[0].Status != computeintegrity.HoldHeld || holds[0].HeldCredits != 100 {
		t.Fatalf("closed recovery hold must stay held over its window: %+v", holds)
	}
	if got := scalar(t, store.db, `SELECT COALESCE(SUM(provider_credits), 0) FROM spec022_payable_request_credits`); got != 200 {
		t.Fatalf("credit after the closed window is payable, got %d", got)
	}

	if _, err := store.OpenComputeIntegrityHold(ctx, "p-a", "model-a", computeintegrity.HoldKindRecovery, t0.Add(24*time.Hour), nil, "cooldown_elapsed", t0.Add(24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if err := store.CloseComputeIntegrityRecoveryHold(ctx, "p-a", "model-a", t0.Add(40*time.Hour), true, t0.Add(40*time.Hour)); err != nil {
		t.Fatal(err)
	}
	holds, _ = store.ComputeIntegrityHolds(ctx, "p-a")
	if holds[0].Status != computeintegrity.HoldReleased || holds[0].ReleasedBy != "compute_integrity_recovery" {
		t.Fatalf("passed recovery must release its hold: %+v", holds[0])
	}
	if got := scalar(t, store.db, `SELECT COALESCE(SUM(provider_credits), 0) FROM spec022_payable_request_credits`); got != 200 {
		t.Fatalf("payable after recovery release=%d want 200", got)
	}
}

func TestComputeIntegrityHoldRejectsBadWindows(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	t0 := time.Date(2026, 7, 1, 0, 0, 0, 0, time.UTC)
	before := t0.Add(-time.Hour)
	if _, err := store.OpenComputeIntegrityHold(ctx, "p", "m", computeintegrity.HoldKindFailure, t0, &before, "x", t0); err == nil {
		t.Fatal("window end before start must be refused")
	}
	if _, err := store.OpenComputeIntegrityHold(ctx, "p", "m", "burn", t0, nil, "x", t0); err == nil {
		t.Fatal("unknown hold kind must be refused")
	}
	if _, err := store.OpenComputeIntegrityHold(ctx, "", "m", computeintegrity.HoldKindFailure, t0, nil, "x", t0); err == nil {
		t.Fatal("missing provider must be refused")
	}
}

// SPEC-022 R-16.3: a credit already settled into a payout is never withheld,
// so a hold cannot invalidate or strand a ready payout; the first hold raises
// the billing compatibility floor to contract 5 so an older coordinator that
// would pay held credits cannot open the database.
func TestComputeIntegrityHoldLeavesSettledCreditsAndRaisesCompatFloor(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	windowStart := time.Date(2026, 7, 1, 0, 0, 0, 0, time.UTC)
	insertCreditWithOperator(t, store.db, "settled", "p-a", windowStart.Add(time.Hour), 700)
	if err := store.RunSettlement(ctx, SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, windowStart, windowStart.AddDate(0, 0, 7)); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready WHERE status = 'ready'`); got != 1 {
		t.Fatalf("ready payouts=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT contract FROM billing_compat_floor WHERE id = 1`); got != billingCompatContractEvidenceRetention {
		t.Fatalf("floor before any hold=%d", got)
	}
	end := windowStart.Add(2 * time.Hour)
	if _, err := store.OpenComputeIntegrityHold(ctx, "p-a", "model-a", computeintegrity.HoldKindFailure, windowStart, &end, "confirmed_failure", end); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT contract FROM billing_compat_floor WHERE id = 1`); got != billingCompatContractComputeIntegrityHold {
		t.Fatalf("floor after first hold=%d want %d", got, billingCompatContractComputeIntegrityHold)
	}
	if got := scalar(t, store.db, `SELECT COALESCE(SUM(provider_credits), 0) FROM spec022_payable_request_credits`); got != 700 {
		t.Fatalf("settled credit must stay payable under a hold, got %d", got)
	}
	holds, _ := store.ComputeIntegrityHolds(ctx, "p-a")
	if len(holds) != 1 || holds[0].HeldCredits != 0 {
		t.Fatalf("a hold over settled credits withholds nothing: %+v", holds)
	}
}
