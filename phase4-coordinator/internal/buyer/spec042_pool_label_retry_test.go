package buyer

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
)

// #1816 VM acceptance A-4: the synchronous receipt path shares one short
// deadline between the verdict and its SPEC-042 R006 label stamp. When the
// verdict write used it up, the label stayed NULL on a verified verdict. The
// stamp is retried in the background on its own deadline.
func TestSettlementPoolLabelRetriedAfterSynchronousDeadline(t *testing.T) {
	s := settlementLegServer(t)
	store, _, _ := s.billingState()
	if store == nil {
		t.Fatal("settlement leg server has no billing store")
	}
	ctx, cancel := context.WithCancel(context.Background())
	s.settlementReceiptPersist = func(context.Context, *billing.Store, settlementReceiptRecoveryInput) (billing.SettlementReceiptState, error) {
		cancel() // the verdict write used the whole synchronous deadline
		return billing.SettlementReceiptState{SettlementOutcome: billing.SettlementOutcomeVerified}, nil
	}
	var calls, recorded atomic.Int32
	s.settlementPoolLabelRecord = func(ctx context.Context, _ *billing.Store, _ billing.SettlementReceiptIdentity, _ *billing.SettlementPoolLabels) (billing.SettlementPoolLabelRecord, error) {
		calls.Add(1)
		if err := ctx.Err(); err != nil {
			return billing.SettlementPoolLabelRecord{}, err
		}
		recorded.Add(1)
		return billing.SettlementPoolLabelRecord{Status: billing.PoolLabelStatusVerified}, nil
	}
	input := settlementReceiptRecoveryInput{
		identity:   billing.SettlementReceiptIdentity{AccountScope: "acct", RequestID: "req-label-retry", AttemptN: 0, ProviderID: "p1"},
		header:     "signed-receipt",
		poolLabels: &billing.SettlementPoolLabels{PoolID: "pool-a", ManifestVersion: 2, ManifestCoreDigest: "d", RouteSnapshotHash: "h"},
	}
	if _, err := s.persistSettlementReceipt(ctx, store, input); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for recorded.Load() == 0 {
		if time.Now().After(deadline) {
			t.Fatalf("label never recorded after the synchronous deadline (%d attempts)", calls.Load())
		}
		time.Sleep(10 * time.Millisecond)
	}
	if n := s.settlementPoolLabelRetries.Load(); n > 1 {
		t.Fatalf("label retries in flight = %d", n)
	}
}
