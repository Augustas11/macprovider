package payout

import (
	"encoding/hex"
	"fmt"
	"strings"

	"golang.org/x/crypto/sha3"
)

// addressByteLen is the on-chain Ethereum address length in bytes.
const addressByteLen = 20

// addressHexLen is the canonical 0x-prefixed string length.
const addressHexLen = 2 + 2*addressByteLen

// ParseAndCanonicalizeEIP55 implements SPEC-016 §3.2 step 2.
// Per the EIP-55 spec:
//   - A pure-lowercase address (40 hex chars, no upper) is
//     accepted with checksum SKIPPED (EIP-55 backward-compat).
//   - A pure-uppercase address (40 hex chars, no lower) is
//     accepted with checksum SKIPPED (EIP-55 backward-compat).
//   - A mixed-case address MUST match the canonical EIP-55
//     checksum exactly; otherwise the input is rejected.
//
// On success the function returns the canonical mixed-case
// checksummed form. SPEC-016 §3.2 step 2 forbids echoing this
// form to the caller in 4xx responses — call sites that surface
// errors to HTTP clients MUST return the bare "checksum_mismatch"
// error code without the canonical form.
//
// Errors returned: ErrBadFormat for the length/hex check;
// ErrChecksumMismatch for a mixed-case checksum failure.
func ParseAndCanonicalizeEIP55(input string) (canonical string, err error) {
	if len(input) != addressHexLen {
		return "", ErrBadFormat
	}
	if !strings.HasPrefix(input, "0x") && !strings.HasPrefix(input, "0X") {
		return "", ErrBadFormat
	}
	hexBody := input[2:]
	if !isHexAlphabet(hexBody) {
		return "", ErrBadFormat
	}
	lower := strings.ToLower(hexBody)
	canonical = "0x" + applyEIP55Checksum(lower)

	pureLower := hexBody == lower
	pureUpper := hexBody == strings.ToUpper(hexBody)
	if pureLower || pureUpper {
		// Backward-compat: checksum skipped.
		return canonical, nil
	}
	// Mixed-case: must match canonical.
	if "0x"+hexBody != canonical {
		return "", ErrChecksumMismatch
	}
	return canonical, nil
}

// CanonicalizeEIP55 is a convenience wrapper for callers that
// only want the canonical form and do not need to distinguish
// the bad-format vs checksum-mismatch error cases.
func CanonicalizeEIP55(input string) (string, error) {
	canonical, err := ParseAndCanonicalizeEIP55(input)
	if err != nil {
		return "", err
	}
	return canonical, nil
}

// NormalizeAddress returns the 0x-prefixed lowercase form. Used
// for byte-equality comparisons across canonicalisation paths
// (e.g. comparing a recovered EIP-712 signer to the configured
// hot wallet address without depending on case).
func NormalizeAddress(input string) (string, error) {
	canonical, err := ParseAndCanonicalizeEIP55(input)
	if err != nil {
		return "", err
	}
	return strings.ToLower(canonical), nil
}

// AddressBytes decodes a canonical or pure-case address into its
// 20-byte form. Returns an error if the address fails the §3.2
// step 2 validation (length, hex, checksum-where-applicable).
func AddressBytes(input string) ([20]byte, error) {
	canonical, err := ParseAndCanonicalizeEIP55(input)
	if err != nil {
		return [20]byte{}, err
	}
	raw, err := hex.DecodeString(canonical[2:])
	if err != nil {
		return [20]byte{}, fmt.Errorf("hex decode after canonicalize: %w", err)
	}
	var out [20]byte
	copy(out[:], raw)
	return out, nil
}

// applyEIP55Checksum takes a 40-char lowercase hex body and
// returns the mixed-case checksummed body (no 0x prefix).
func applyEIP55Checksum(lowerHex string) string {
	hash := sha3.NewLegacyKeccak256()
	_, _ = hash.Write([]byte(lowerHex))
	digest := hash.Sum(nil)

	out := []byte(lowerHex)
	for i := 0; i < len(out); i++ {
		hashNibble := digest[i/2]
		if i%2 == 0 {
			hashNibble >>= 4
		}
		hashNibble &= 0x0f
		if hashNibble >= 8 && out[i] >= 'a' && out[i] <= 'f' {
			out[i] = out[i] - 'a' + 'A'
		}
	}
	return string(out)
}

func isHexAlphabet(s string) bool {
	for _, r := range s {
		if (r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F') {
			continue
		}
		return false
	}
	return true
}
