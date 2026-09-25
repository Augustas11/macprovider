package buyer

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/billing"
)

// settlementFinalityMACGolden pins the finality MAC encoding. The gateway
// test TestSettlementFinalityMACMatchesCoordinatorGolden pins the same value,
// so the two independent implementations cannot drift apart.
const settlementFinalityMACGolden = "6d50472d4203def3b4c03d6bc03732193faf42f871aa61ea1ce03c008b56da2d"

func TestSettlementFinalityMACGoldenVector(t *testing.T) {
	got := settlementFinalityMAC("service-token", "acct_1", "req-1",
		[]string{"quarantined", "invalid", "signature_verify_failed", "true", "enforce", "1", ""})
	if got != settlementFinalityMACGolden {
		t.Fatalf("finality MAC=%s, want %s", got, settlementFinalityMACGolden)
	}
	// Length prefixes keep field boundaries: moving a byte between the
	// account and the request id changes the MAC.
	if settlementFinalityMAC("service-token", "acct_1r", "eq-1",
		[]string{"quarantined", "invalid", "signature_verify_failed", "true", "enforce", "1", ""}) == got {
		t.Fatal("field boundaries are not bound")
	}
}

// Only a caller holding the gateway service token negotiates trailers.
func TestGatewayNegotiatedSettlementTrailersNeedsServiceToken(t *testing.T) {
	s := &Server{gatewayServiceToken: "service-token"}
	h := http.Header{}
	h.Set(settlementTrailersCapabilityHeader, "1")
	if s.gatewayNegotiatedSettlementTrailers(h) {
		t.Fatal("capability without the service token negotiated trailers")
	}
	h.Set("Authorization", "Bearer wrong")
	if s.gatewayNegotiatedSettlementTrailers(h) {
		t.Fatal("capability with a wrong bearer negotiated trailers")
	}
	h.Set("Authorization", "Bearer service-token")
	if !s.gatewayNegotiatedSettlementTrailers(h) {
		t.Fatal("the gateway's advertised capability was not honored")
	}
	h.Set(settlementTrailersCapabilityHeader, "0")
	if s.gatewayNegotiatedSettlementTrailers(h) {
		t.Fatal("a capability other than 1 negotiated trailers")
	}
	if (&Server{}).gatewayNegotiatedSettlementTrailers(http.Header{"Authorization": {"Bearer "}, settlementTrailersCapabilityHeader: {"1"}}) {
		t.Fatal("an unset service token negotiated trailers")
	}
	// The capability header is gateway-owned: a buyer-port request that
	// carries it without the bearer is refused like every internal header.
	if !hasInternalRoutingHeader(http.Header{settlementTrailersCapabilityHeader: {"1"}}) {
		t.Fatal("the capability header is outside the internal-header guard")
	}
}

// Review F5: a failed post-delivery record sends an explicit, MAC'd pending
// tuple, which a gateway reads as a hold.
func TestSettlementRecordFailedHoldIsSignedPending(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	req.Header.Set("X-MacProvider-Account", "acct_1")
	req.Header.Set("X-Request-ID", "req-1")
	rec := &billingRecorder{
		server:                       &Server{gatewayServiceToken: "service-token"},
		req:                          req,
		accountID:                    "acct_1",
		settlementTrailersNegotiated: true,
		hasSettlementAttemptN:        true,
		settlementPolicyMode:         billing.RouteSnapshotModeEnforce,
	}
	dst := http.Header{}
	setSettlementRecordFailedHold(dst, rec)
	if len(dst) != 0 {
		t.Fatalf("hold set before trailers were declared: %v", dst)
	}
	declareNonStreamingSettlementTrailers(dst, rec)
	setSettlementRecordFailedHold(dst, rec)
	if dst.Get(settlementOutcomeHeader) != "pending" || dst.Get(settlementReasonHeader) != settlementRecordFailedAfterDeliveryReason ||
		dst.Get(settlementModeHeader) != billing.RouteSnapshotModeEnforce || dst.Get(settlementClosedHeader) != "false" {
		t.Fatalf("hold tuple=%v, want an enforce-mode open pending tuple", dst)
	}
	values := make([]string, 0, len(settlementOutcomeHeaderNames))
	for _, name := range settlementOutcomeHeaderNames {
		values = append(values, dst.Get(name))
	}
	if got, want := dst.Get(settlementFinalityMACHeader), settlementFinalityMAC("service-token", "acct_1", "req-1", values); got != want {
		t.Fatalf("hold MAC=%q, want %q", got, want)
	}
}
