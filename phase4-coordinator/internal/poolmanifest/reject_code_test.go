package poolmanifest

import (
	"errors"
	"fmt"
	"testing"
)

// #1816 F4: every R015/R016 refusal maps to its closed rejection code, also
// when wrapped, and nothing else does.
func TestPoolModelRejectCode(t *testing.T) {
	for err, want := range map[error]string{
		ErrPoolModelPricingBoundsUnset: RejectCodePricingBoundsUnset,
		ErrPoolModelPricingBounds:      RejectCodePricingOutOfBounds,
		ErrPoolModelShadowsCatalog:     RejectCodeShadowsCatalog,
		ErrPoolModelCatalogOverlap:     RejectCodeCatalogOverlap,
		errModelEntryPairing:           RejectCodeRuntimePairing,
		errModelEntryRuntimes:          RejectCodeRuntimeNotAllowed,
		errAttestedMemberRuntimes:      RejectCodeRuntimeNotAllowed,
		errModelEntryLicense:           RejectCodeLicense,
		errModelEntryPaidServing:       RejectCodePaidServing,
		errModelEntryDupHash:           RejectCodeDuplicate,
		errModelEntriesOrder:           RejectCodeDuplicate,
		errAttestedMembersOrder:        RejectCodeDuplicate,
		errModelEntriesBound:           RejectCodeLimitExceeded,
		errAttestedMembersBound:        RejectCodeLimitExceeded,
		errModelEntryContext:           RejectCodeInvalid,
		errExtensionBody:               RejectCodeInvalid,
		errAttestedMemberAccount:       RejectCodeInvalid,
		errors.New("unrelated"):        "",
	} {
		if got := PoolModelRejectCode(fmt.Errorf("wrapped: %w", err)); got != want {
			t.Errorf("%v: code=%q, want %q", err, got, want)
		}
	}
	if PoolModelRejectCode(nil) != "" {
		t.Fatal("nil error has a code")
	}
}
