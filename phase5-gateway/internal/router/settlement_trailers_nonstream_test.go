package router

import (
	"net/http"
	"testing"
)

// Delivered-only billing (SPEC-022 R-5.6): the coordinator records a
// non-streaming success after its body write and sends the settlement
// finality as trailers; the gateway settles from them.
func TestWithSettlementFinalityTrailersFoldsCoordinatorTrailers(t *testing.T) {
	resp := &http.Response{Header: http.Header{"Content-Type": {"application/json"}}, Trailer: http.Header{}}
	if got := coordinatorSettlementFinalityFromHeaders(withSettlementFinalityTrailers(resp)); got.Action != settlementFinalityLegacy {
		t.Fatalf("no finality anywhere: action=%v, want legacy", got.Action)
	}
	resp.Header.Add("Trailer", settlementOutcomeHeader)
	resp.Trailer.Set(settlementOutcomeHeader, "verified")
	resp.Trailer.Set(settlementReceiptResultHeader, "valid")
	resp.Trailer.Set(settlementClosedHeader, "true")
	resp.Trailer.Set(settlementModeHeader, "enforce")
	resp.Trailer.Set(settlementPolicyVersionHeader, settlementPolicyVersion)
	folded := withSettlementFinalityTrailers(resp)
	if got := coordinatorSettlementFinalityFromHeaders(folded); got.Action != settlementFinalityDebit || got.Outcome != "verified" {
		t.Fatalf("trailer finality=%+v, want a verified debit", got)
	}
	if resp.Header.Get(settlementOutcomeHeader) != "" {
		t.Fatal("folding mutated the response headers")
	}
}
