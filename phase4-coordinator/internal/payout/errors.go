package payout

import "errors"

// Public sentinel errors mapped to SPEC-016 §3.3 4xx error
// codes. The HTTP handler converts these to JSON bodies of the
// form { "error": "<code>" } per the SPEC's response surface.
var (
	ErrBadFormat          = errors.New("bad_format")
	ErrChecksumMismatch   = errors.New("checksum_mismatch")
	ErrUnknownProvider    = errors.New("unknown_provider")
	ErrDenylist           = errors.New("denylist")
	ErrSignatureMismatch  = errors.New("signature_mismatch")
	ErrSignatureSkew      = errors.New("signature_skew")
	ErrNonceReplayed      = errors.New("nonce_replayed")
	ErrMissingField       = errors.New("missing_field")
	ErrBadProviderID      = errors.New("bad_provider_id")
	ErrProviderIDMismatch = errors.New("providerid_mismatch")
	ErrAddressMismatch    = errors.New("address_mismatch")
	ErrChainMismatch      = errors.New("chain_mismatch")
	ErrNonceMismatch      = errors.New("nonce_mismatch")
	ErrTsUtcMismatch      = errors.New("tsutc_mismatch")
)
