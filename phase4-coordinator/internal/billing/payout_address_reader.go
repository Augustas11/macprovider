package billing

import "context"

// PayoutAddressReader is the read-only seam SPEC-016 §4.1
// uses to cross the billing/ → payout/ boundary without
// importing the payout package. The interface is DECLARED here
// in billing/ and SATISFIED by a thin adapter in payout/
// (internal/payout/addresses.go LookupPayoutAddress), wired in
// cmd/coordinator/main.go.
//
// SPEC §4.1 normative: `billing/` MUST NOT import `payout/`.
// payout/ MAY import billing/ for the §4.3 step 8
// ClaimPayoutReady call. The direction is strictly one-way.
// An IMPL audit-time import-graph test enforces this; see
// internal/payout/importgraph_test.go.
//
// Returns:
//
//   - address — canonical EIP-55 form of the registered payout
//     address for (providerID, chain). Empty string with
//     payoutAllowed=false when no row exists for the provider.
//   - payoutAllowed — provider_payout_addresses.payout_allowed
//     flag value (the SPEC §8 compliance gate).
//   - err — DB / driver error; never used to signal "no row".
type PayoutAddressReader interface {
	LookupPayoutAddress(ctx context.Context, providerID, chain string) (address string, payoutAllowed bool, err error)
}
