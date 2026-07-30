package payout

import (
	"encoding/hex"
	"errors"
	"fmt"
	"strings"

	ecdsa "github.com/decred/dcrd/dcrec/secp256k1/v4/ecdsa"
	"golang.org/x/crypto/sha3"
)

// SPEC-016 §3.2 step 5 — EIP-712 typed-data verification.
//
// The domain typehash and struct typehash are deterministic
// (only the canonical text differs). Computing them eagerly here
// catches typos at process start instead of at first request.

// domainTypeHash = keccak256(
//
//	"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
//
// )
var domainTypeHash = keccak256OfString(
	"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
)

// payoutAddressRegistrationTypeHash = keccak256(
//
//	"PayoutAddressRegistration(string providerId,address address,string chain,bytes32 nonce,uint64 tsUtc)"
//
// )
//
// The struct name "PayoutAddressRegistration" and field names
// "providerId, address, chain, nonce, tsUtc" are part of the
// signing contract and MUST match what providers' EIP-712
// signers serialise. SPEC-016 §3.2 step 5 pins all of these.
var payoutAddressRegistrationTypeHash = keccak256OfString(
	"PayoutAddressRegistration(string providerId,address address,string chain,bytes32 nonce,uint64 tsUtc)",
)

// domainNameHash and domainVersionHash are constant per the
// SPEC's pinned `name`/`version` values; precompute once.
var (
	domainNameHash    = keccak256OfString("macprovider-payout")
	domainVersionHash = keccak256OfString("1")
)

// PayoutChainID is the EIP-712 chainId field — pinned to Base
// mainnet (8453) per SPEC-016 §3.2 step 5. There is no
// configuration knob; multi-rail support is a v0.2 candidate.
const PayoutChainID uint64 = 8453

// EIP712Inputs is the verifier-side payload assembled from the
// §3.3 request body. Every field is byte-equal-compared against
// the typed-data the recovered signer signed (SPEC §3.2 step 5
// field-by-field equality discipline).
type EIP712Inputs struct {
	ProviderID        string // expected to equal URL-path provider_id
	CanonicalAddr     string // canonical EIP-55, post-§3.2 step 2
	Chain             string // exactly "base-mainnet"
	Nonce32           [32]byte
	TsUtc             uint64 // unix seconds
	VerifyingContract string // canonical EIP-55, the operator's hot wallet
}

// VerifyEIP712 implements SPEC-016 §3.2 step 5. On success it
// returns the digest used for ecrecover (useful for logging
// the EIP-712 digest hash without re-deriving it). It validates:
//   - signature length (65 bytes when hex-decoded);
//   - v ∈ {27, 28};
//   - ecrecover yields a signer whose address byte-equals
//     inputs.CanonicalAddr (NormalizeAddress comparison);
//   - the typed-data byte-encoding is built from inputs and
//     produces the digest that ecrecover ran against.
//
// The caller is responsible for verifying that the request
// body's `providerId`, `address`, `chain`, `nonce`, `ts_utc`
// each byte-equal the corresponding inputs field BEFORE calling
// VerifyEIP712 — VerifyEIP712 itself only enforces signature
// correctness against the inputs it is given. SPEC §3.2 step 5
// closes the "decorative typed-data field" replay class by
// requiring the handler to perform field-by-field equality
// in addition to ecrecover; addresses.go performs those checks
// at the request boundary.
func VerifyEIP712(inputs EIP712Inputs, signatureHex string) (digest [32]byte, err error) {
	sig, err := decodeSignatureHex(signatureHex)
	if err != nil {
		return [32]byte{}, err
	}
	digest, err = buildDigest(inputs)
	if err != nil {
		return [32]byte{}, err
	}

	recovered, err := ecrecover(digest[:], sig)
	if err != nil {
		return [32]byte{}, ErrSignatureMismatch
	}
	expectedLower, err := NormalizeAddress(inputs.CanonicalAddr)
	if err != nil {
		return [32]byte{}, err
	}
	if !strings.EqualFold(recovered, expectedLower) {
		return [32]byte{}, ErrSignatureMismatch
	}
	return digest, nil
}

// buildDigest computes the EIP-712 digest:
//
//	digest = keccak256(0x19 || 0x01 || domainSeparator || structHash)
//
// Per SPEC §3.2 step 5 the typed-data definition is:
//
//	PayoutAddressRegistration(string providerId, address address,
//	                          string chain, bytes32 nonce,
//	                          uint64 tsUtc)
//
// EIP-712 atomic-type encoding:
//   - string  → keccak256(utf8 bytes)
//   - address → 32-byte left-padded big-endian
//   - bytes32 → raw 32 bytes
//   - uint64  → 32-byte big-endian
func buildDigest(inputs EIP712Inputs) (digest [32]byte, err error) {
	// Domain separator.
	verifyingBytes, err := AddressBytes(inputs.VerifyingContract)
	if err != nil {
		return [32]byte{}, fmt.Errorf("verifyingContract: %w", err)
	}
	chainIDBuf := uint256BE(PayoutChainID)
	verifyingBuf := leftPadAddress(verifyingBytes)
	domainSeparator := keccak256(
		domainTypeHash[:],
		domainNameHash[:],
		domainVersionHash[:],
		chainIDBuf[:],
		verifyingBuf[:],
	)

	// Struct hash.
	providerIDHash := keccak256OfString(inputs.ProviderID)
	chainHash := keccak256OfString(inputs.Chain)
	addrBytes, err := AddressBytes(inputs.CanonicalAddr)
	if err != nil {
		return [32]byte{}, fmt.Errorf("address: %w", err)
	}
	addrBuf := leftPadAddress(addrBytes)
	tsBuf := uint256BE(inputs.TsUtc)
	structHash := keccak256(
		payoutAddressRegistrationTypeHash[:],
		providerIDHash[:],
		addrBuf[:],
		chainHash[:],
		inputs.Nonce32[:],
		tsBuf[:],
	)

	// Final digest.
	prefix := []byte{0x19, 0x01}
	digest = keccak256(prefix, domainSeparator[:], structHash[:])
	return digest, nil
}

// decodeSignatureHex accepts a 0x-prefixed 130-hex-char signature
// (r||s||v) and returns the 65-byte form ordered as v||r||s for
// the decred RecoverCompact API. v ∈ {27, 28} is enforced
// (Ethereum's EIP-712 convention).
func decodeSignatureHex(sigHex string) ([]byte, error) {
	if len(sigHex) != 2+130 {
		return nil, ErrSignatureMismatch
	}
	if !strings.HasPrefix(sigHex, "0x") && !strings.HasPrefix(sigHex, "0X") {
		return nil, ErrSignatureMismatch
	}
	raw, err := hex.DecodeString(sigHex[2:])
	if err != nil {
		return nil, ErrSignatureMismatch
	}
	if len(raw) != 65 {
		return nil, ErrSignatureMismatch
	}
	v := raw[64]
	if v != 27 && v != 28 {
		// Reject {0, 1} forms — Ethereum's plain EIP-712 surfaces
		// produce {27, 28} per yellow paper Appendix F. Permitting
		// the {0, 1} form would silently accept signatures the
		// SPEC didn't account for in its replay-table sizing.
		return nil, ErrSignatureMismatch
	}
	// Reorder to v||r||s for decred RecoverCompact.
	reordered := make([]byte, 65)
	reordered[0] = v
	copy(reordered[1:33], raw[0:32])
	copy(reordered[33:65], raw[32:64])
	return reordered, nil
}

// ecrecover runs decred's RecoverCompact against the EIP-712
// digest and returns the lowercase 0x-prefixed Ethereum address
// of the recovered public key.
func ecrecover(digest []byte, sig []byte) (lowerHexAddress string, err error) {
	pubKey, _, err := ecdsa.RecoverCompact(sig, digest)
	if err != nil {
		return "", err
	}
	uncompressed := pubKey.SerializeUncompressed()
	if len(uncompressed) != 65 || uncompressed[0] != 0x04 {
		return "", errors.New("recovered pubkey not in uncompressed form")
	}
	// keccak256 of X||Y (drop the 0x04 prefix); address is the
	// last 20 bytes.
	hash := sha3.NewLegacyKeccak256()
	_, _ = hash.Write(uncompressed[1:])
	digestPub := hash.Sum(nil)
	addr := digestPub[len(digestPub)-20:]
	return "0x" + hex.EncodeToString(addr), nil
}

// keccak256 hashes the concatenation of the provided byte slices.
func keccak256(parts ...[]byte) [32]byte {
	hash := sha3.NewLegacyKeccak256()
	for _, p := range parts {
		_, _ = hash.Write(p)
	}
	var out [32]byte
	copy(out[:], hash.Sum(nil))
	return out
}

// keccak256OfString is a convenience for typehash/domain-name
// constants — keccak over the UTF-8 bytes.
func keccak256OfString(s string) [32]byte {
	return keccak256([]byte(s))
}

// uint256BE returns the 32-byte big-endian encoding of v.
func uint256BE(v uint64) [32]byte {
	var out [32]byte
	for i := 0; i < 8; i++ {
		out[31-i] = byte(v >> (8 * i))
	}
	return out
}

// leftPadAddress takes a 20-byte address and returns the
// 32-byte left-padded form used in EIP-712 encoding for the
// `address` atomic type.
func leftPadAddress(addr [20]byte) [32]byte {
	var out [32]byte
	copy(out[12:], addr[:])
	return out
}

// DecodeNonce32 parses a 0x-prefixed 64-hex-char nonce into its
// raw 32-byte form. Returns an error if the input has the wrong
// length or hex.
func DecodeNonce32(s string) ([32]byte, error) {
	var out [32]byte
	if len(s) != 2+64 {
		return out, fmt.Errorf("nonce: expected 0x-prefixed 64 hex chars, got %d chars", len(s))
	}
	if !strings.HasPrefix(s, "0x") && !strings.HasPrefix(s, "0X") {
		return out, fmt.Errorf("nonce: expected 0x prefix")
	}
	raw, err := hex.DecodeString(s[2:])
	if err != nil {
		return out, fmt.Errorf("nonce: hex decode: %w", err)
	}
	copy(out[:], raw)
	return out, nil
}
