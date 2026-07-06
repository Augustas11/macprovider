package metrics

import (
	"testing"

	"github.com/augstar/macprovider-network-harness/internal/buyer"
)

func TestAggregateCountsInvalid2xx(t *testing.T) {
	summary := Aggregate([]buyer.Result{{Outcome: "invalid_response", ErrorCode: "invalid_response", HTTPStatus: 200}})
	if summary.SuccessCount != 0 {
		t.Fatalf("SuccessCount=%d want 0", summary.SuccessCount)
	}
	if summary.Invalid2xx != 1 {
		t.Fatalf("Invalid2xx=%d want 1", summary.Invalid2xx)
	}
	if summary.ErrorTaxonomy["invalid_response"] != 1 {
		t.Fatalf("invalid_response taxonomy=%d want 1", summary.ErrorTaxonomy["invalid_response"])
	}
}
