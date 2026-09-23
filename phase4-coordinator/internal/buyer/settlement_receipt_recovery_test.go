package buyer

import (
	"context"
	"errors"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
)

func TestSettlementReceiptPressureDefersWithoutFailingServedBuyer(t *testing.T) {
	s := settlementLegServer(t)
	rec := settlementLegRecorder(s, "req-receipt-recovery")
	rec.settlementPolicyMode = billing.RouteSnapshotModeEnforce
	rec.settlementPolicyVersion = billing.RouteSnapshotPolicyVersion
	provider := settlementLegProvider()

	var calls atomic.Int32
	recovered := make(chan struct{})
	s.settlementReceiptPersist = func(_ context.Context, _ *billing.Store, input settlementReceiptRecoveryInput) (billing.SettlementReceiptState, error) {
		if input.header != "signed-receipt" {
			t.Errorf("receipt header = %q, want signed-receipt", input.header)
		}
		if calls.Add(1) == 1 {
			return billing.SettlementReceiptState{}, context.DeadlineExceeded
		}
		close(recovered)
		return billing.SettlementReceiptState{SettlementOutcome: billing.SettlementOutcomeVerified}, nil
	}

	state, has, err := rec.ingestSettlementReceipt(provider, "signed-receipt")
	if err != nil {
		t.Fatalf("ingestSettlementReceipt returned transient error: %v", err)
	}
	if !has || state.SettlementOutcome != billing.SettlementOutcomePending || state.ReceiptResult != billing.SettlementReceiptResultInconclusive ||
		state.Reason != "receipt_verdict_pending" || state.Closed || state.RouteSnapshotMode != billing.RouteSnapshotModeEnforce ||
		state.RouteSnapshotPolicyVersion != billing.RouteSnapshotPolicyVersion {
		t.Fatalf("deferred receipt state = %+v, has=%v; want enforce pending hold authority", state, has)
	}

	select {
	case <-recovered:
	case <-time.After(3 * time.Second):
		t.Fatal("deferred receipt was not retried")
	}
	if got := calls.Load(); got != 2 {
		t.Fatalf("receipt persistence calls = %d, want 2", got)
	}
	deadline := time.Now().Add(time.Second)
	for {
		s.settlementReceiptRecoveryMu.Lock()
		pending := len(s.settlementReceiptRecoveryKeys)
		s.settlementReceiptRecoveryMu.Unlock()
		if pending == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("receipt recovery key still pending after success: %d", pending)
		}
		time.Sleep(time.Millisecond)
	}
}

func TestSettlementReceiptPermanentFailureStaysLoud(t *testing.T) {
	s := settlementLegServer(t)
	rec := settlementLegRecorder(s, "req-receipt-permanent")
	provider := settlementLegProvider()
	wantErr := errors.New("settlement attempt output missing")
	s.settlementReceiptPersist = func(context.Context, *billing.Store, settlementReceiptRecoveryInput) (billing.SettlementReceiptState, error) {
		return billing.SettlementReceiptState{}, wantErr
	}

	if _, _, err := rec.ingestSettlementReceipt(provider, "signed-receipt"); !errors.Is(err, wantErr) {
		t.Fatalf("ingestSettlementReceipt error = %v, want %v", err, wantErr)
	}
	s.settlementReceiptRecoveryMu.Lock()
	pending := len(s.settlementReceiptRecoveryKeys)
	s.settlementReceiptRecoveryMu.Unlock()
	if pending != 0 {
		t.Fatalf("permanent receipt failure queued for retry: %d", pending)
	}
}

func TestSettlementReceiptRecoveryKeyDoesNotContainRawReceipt(t *testing.T) {
	input := settlementReceiptRecoveryInput{
		identity: billing.SettlementReceiptIdentity{
			AccountScope: "acct-scope",
			RequestID:    "req-id",
			AttemptN:     1,
			ProviderID:   "provider-id",
		},
		header: "raw-signed-receipt-material",
	}
	key := settlementReceiptRecoveryKey(input)
	if strings.Contains(key, input.header) {
		t.Fatal("receipt recovery key retained raw receipt material")
	}
}

func TestSettlementReceiptSynchronousBudgetLeavesBuyerResponseHeadroom(t *testing.T) {
	if settlementReceiptSynchronousTimeout >= requestLogWriteTimeout {
		t.Fatalf("settlement receipt synchronous timeout = %s, must stay below request log timeout %s", settlementReceiptSynchronousTimeout, requestLogWriteTimeout)
	}
}

func TestSettlementReceiptRecoveryStopsAfterBoundedAttempts(t *testing.T) {
	s := settlementLegServer(t)
	rec := settlementLegRecorder(s, "req-receipt-exhausted")
	provider := settlementLegProvider()
	var calls atomic.Int32
	s.settlementReceiptPersist = func(context.Context, *billing.Store, settlementReceiptRecoveryInput) (billing.SettlementReceiptState, error) {
		calls.Add(1)
		return billing.SettlementReceiptState{}, context.DeadlineExceeded
	}

	if state, has, err := rec.ingestSettlementReceipt(provider, "signed-receipt"); err != nil || !has || state.SettlementOutcome != billing.SettlementOutcomePending {
		t.Fatalf("initial receipt pressure: state=%+v has=%v err=%v, want deferred pending success", state, has, err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		s.settlementReceiptRecoveryMu.Lock()
		pending := len(s.settlementReceiptRecoveryKeys)
		s.settlementReceiptRecoveryMu.Unlock()
		if pending == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("receipt recovery did not exhaust within bound; calls=%d", calls.Load())
		}
		time.Sleep(10 * time.Millisecond)
	}
	if got := calls.Load(); got != settlementReceiptRecoveryMaxAttempts {
		t.Fatalf("receipt persistence calls = %d, want %d", got, settlementReceiptRecoveryMaxAttempts)
	}
}

func TestSettlementReceiptRecoveryQueueIsBounded(t *testing.T) {
	s := settlementLegServer(t)
	s.settlementReceiptRecoveryMu.Lock()
	for i := 0; i < settlementReceiptRecoveryMaxPending; i++ {
		s.settlementReceiptRecoveryKeys[string(rune(i))] = struct{}{}
	}
	s.settlementReceiptRecoveryMu.Unlock()
	input := settlementReceiptRecoveryInput{
		identity: billing.SettlementReceiptIdentity{
			AccountScope: "acct-scope",
			RequestID:    "req-overflow",
			ProviderID:   "provider-id",
		},
		header: "signed-receipt",
	}
	if s.deferSettlementReceiptRecovery(input) {
		t.Fatal("full receipt recovery queue accepted another item")
	}
	s.settlementReceiptRecoveryMu.Lock()
	pending := len(s.settlementReceiptRecoveryKeys)
	s.settlementReceiptRecoveryMu.Unlock()
	if pending != settlementReceiptRecoveryMaxPending {
		t.Fatalf("recovery key count = %d, want %d", pending, settlementReceiptRecoveryMaxPending)
	}
}

func TestSettlementReceiptRecoveryQueueOverflowStaysLoud(t *testing.T) {
	s := settlementLegServer(t)
	rec := settlementLegRecorder(s, "req-receipt-overflow")
	provider := settlementLegProvider()
	s.settlementReceiptPersist = func(context.Context, *billing.Store, settlementReceiptRecoveryInput) (billing.SettlementReceiptState, error) {
		return billing.SettlementReceiptState{}, context.DeadlineExceeded
	}
	s.settlementReceiptRecoveryMu.Lock()
	for i := 0; i < settlementReceiptRecoveryMaxPending; i++ {
		s.settlementReceiptRecoveryKeys[string(rune(i))] = struct{}{}
	}
	s.settlementReceiptRecoveryMu.Unlock()

	if _, has, err := rec.ingestSettlementReceipt(provider, "signed-receipt"); !errors.Is(err, context.DeadlineExceeded) || has {
		t.Fatalf("overflow receipt ingest: has=%v err=%v, want deadline error and no state", has, err)
	}
}
