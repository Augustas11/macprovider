package buyer

import (
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// TestEligibilityCtx_ProviderHasSettlementReceiptKey pins the
// SPEC-022 R-2.4/R-2.5 candidate-eligibility gate logic: observe mode
// (settlementEnforce == false) is a no-op that accepts every provider,
// while enforce mode drops providers whose active receipt public key is
// empty and keeps those that present one. This mirrors the pre-dispatch
// route-snapshot guard in route_snapshot.go so the eligibility filter
// and the fail-closed backstop cannot diverge.
func TestEligibilityCtx_ProviderHasSettlementReceiptKey(t *testing.T) {
	t.Parallel()
	withKey := pool.Provider{ProviderID: "with", ReceiptPubkey: []byte("k")}
	noKey := pool.Provider{ProviderID: "without"}

	observe := &eligibilityCtx{settlementEnforce: false}
	if !observe.ProviderHasSettlementReceiptKey(noKey) {
		t.Error("observe mode must accept a provider with no receipt key (no-op)")
	}
	if !observe.ProviderHasSettlementReceiptKey(withKey) {
		t.Error("observe mode must accept a provider with a receipt key")
	}

	enforce := &eligibilityCtx{settlementEnforce: true}
	if enforce.ProviderHasSettlementReceiptKey(noKey) {
		t.Error("enforce mode must reject a provider with an empty active receipt key")
	}
	if !enforce.ProviderHasSettlementReceiptKey(withKey) {
		t.Error("enforce mode must accept a provider with a non-empty active receipt key")
	}
}
