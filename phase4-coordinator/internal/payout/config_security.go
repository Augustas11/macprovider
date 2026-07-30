package payout

import (
	"fmt"
)

// SecurityConfig holds the immutable-at-startup subset of the
// SPEC-016 §6.5 `payout.security.*` namespace required by Step 1.
// The §3.2 EIP-712 verifyingContract field, the §3.4 audit
// emission, and the §4.3 step 1 SELECT all read the hot-wallet
// address from one source of truth — this struct — so the
// "pinned to the current hot wallet" invariant is operationally
// load-bearing. The remaining `payout.security.*` keys (caps,
// RPC URLs, cancel tip multipliers, etc.) land in Step 4 with
// the dual-loader split.
//
// SecurityConfig MUST be constructed once at process start and
// passed by value to handlers. NO setter exists; reload via
// SIGHUP / fsnotify / runtime endpoint is FORBIDDEN per §6.5.
// The audit-prompt explicitly notes that a later step must
// extend this with bounds + same-shape immutability — Step 1's
// hot-wallet-only struct is the seed, not the finished surface.
type SecurityConfig struct {
	// HotWalletAddress is the canonical EIP-55 checksummed
	// address of the operator hot wallet. SPEC-016 §3.2 step 5
	// uses it as the EIP-712 verifyingContract; §3.3 stamps it
	// into provider_payout_addresses.registered_against_hot_wallet
	// on every successful INSERT/UPDATE; §4.3 step 1 SELECT
	// joins against it to silently route pre-rotation rows to
	// the "unpayable until re-registration" bucket.
	//
	// Stored in canonical EIP-55 mixed-case form so byte-equality
	// against typed-data verifyingContract holds without case-
	// folding (the EIP-712 typed-data encoder canonicalises the
	// address before hashing, so the *byte* form stored is
	// presentational; downstream comparisons should case-fold or
	// use the normalised lowercase form via NormalizeAddress).
	HotWalletAddress string
}

// LoadSecurityConfig validates the operator-supplied hot wallet
// address and returns the immutable config. The address MUST
// pass the §3.2 step 2 EIP-55 canonicalisation (pure-lowercase
// or pure-uppercase forms accepted as checksum-skipped per
// EIP-55 backward-compat; mixed-case must checksum). An empty
// address is rejected — a payout deployment with no operator
// hot wallet cannot serve §3.3 traffic.
func LoadSecurityConfig(rawHotWallet string) (SecurityConfig, error) {
	if rawHotWallet == "" {
		return SecurityConfig{}, fmt.Errorf("payout.LoadSecurityConfig: payout.security.hot_wallet_address is required")
	}
	canonical, err := CanonicalizeEIP55(rawHotWallet)
	if err != nil {
		return SecurityConfig{}, fmt.Errorf("payout.LoadSecurityConfig: hot_wallet_address: %w", err)
	}
	return SecurityConfig{HotWalletAddress: canonical}, nil
}
