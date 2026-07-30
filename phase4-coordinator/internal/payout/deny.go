package payout

import "strings"

// SPEC-016 §3.2 step 4 — minimum deny-list for payout addresses.
//
// Stored as lowercase 0x-prefixed strings to make membership
// checks case-insensitive without re-running EIP-55 on every
// lookup. Callers pass the lowercase form (use NormalizeAddress).
//
// The hot-wallet self-payment denial is per-deployment and is
// added at construction time from the SecurityConfig — not
// hard-coded here.
var minimumDenyListLower = []string{
	// Zero address.
	"0x0000000000000000000000000000000000000000",
	// USDC contract on Base (the §3.2 denial of a registration
	// at the USDC contract address itself — preventing the
	// "register a contract as the payout target" attack class).
	"0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
	// Known burn addresses.
	"0x000000000000000000000000000000000000dead",
	"0xdead000000000000000000000000000000000000",
}

// DenyList is the immutable closed set of addresses that MUST
// NOT be accepted as payout targets. Constructed once per
// process from the SPEC-016 §3.2 minimum plus the configured
// hot wallet (self-payment denial) plus any operator-supplied
// additions. Compare via Contains, which lower-cases its input
// to match the canonical lowercase form stored here.
type DenyList struct {
	set map[string]struct{}
}

// NewDenyList constructs a deny-list from the SPEC-016 §3.2
// minimum (zero, USDC contract, common burn), the operator's
// hot wallet (self-payment denial), and any operator-supplied
// extras. Extras MUST be valid EIP-55-canonical or pure-case
// addresses; an invalid extra fails the constructor fast.
func NewDenyList(hotWalletAddress string, extras ...string) (*DenyList, error) {
	dl := &DenyList{set: map[string]struct{}{}}
	for _, addr := range minimumDenyListLower {
		dl.set[addr] = struct{}{}
	}
	if hotWalletAddress != "" {
		hwLower, err := NormalizeAddress(hotWalletAddress)
		if err != nil {
			return nil, err
		}
		dl.set[hwLower] = struct{}{}
	}
	for _, raw := range extras {
		lower, err := NormalizeAddress(raw)
		if err != nil {
			return nil, err
		}
		dl.set[lower] = struct{}{}
	}
	return dl, nil
}

// Contains reports whether addr appears on the deny-list. The
// address is lower-cased before lookup so callers can pass
// canonical mixed-case forms without first normalising.
func (d *DenyList) Contains(addr string) bool {
	if d == nil {
		return false
	}
	_, ok := d.set[strings.ToLower(addr)]
	return ok
}
