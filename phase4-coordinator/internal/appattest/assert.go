package appattest

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
)

// AssertionInput is one SPEC-049-R031 steps 1..4 check. PublicKey is the
// stored 65-byte uncompressed point of the enrolled key; ClientDataHash is
// SHA-256 of the recomputed v2 posture framing.
type AssertionInput struct {
	Assertion      []byte
	PublicKey      []byte
	ClientDataHash []byte
	AppID          string
}

func assertFail(format string, args ...any) error {
	return fmt.Errorf("%w: "+format, append([]any{ErrAssertionInvalid}, args...)...)
}

// VerifyAssertion checks the closed SPEC-049 §4.10 assertion shape, the
// rpIdHash, and the signature, and returns the signature counter. The
// caller enforces and durably persists the strictly increasing counter.
func VerifyAssertion(in AssertionInput) (uint32, error) {
	if len(in.Assertion) == 0 || len(in.Assertion) > MaxAssertionBytes {
		return 0, assertFail("size")
	}
	if len(in.ClientDataHash) != sha256.Size || in.AppID == "" {
		return 0, assertFail("input")
	}
	pub, err := ecdsa.ParseUncompressedPublicKey(elliptic.P256(), in.PublicKey)
	if err != nil {
		return 0, assertFail("stored public key")
	}
	obj, err := decodeCBOR(in.Assertion)
	if err != nil {
		return 0, assertFail("cbor: %v", err)
	}
	if !obj.onlyTextKeys("signature", "authenticatorData") {
		return 0, assertFail("assertion keys")
	}
	sig, _ := obj.textKey("signature")
	if sig.Kind != kindBytes || len(sig.Bytes) == 0 || len(sig.Bytes) > MaxAssertionSignatureBytes {
		return 0, assertFail("signature")
	}
	auth, _ := obj.textKey("authenticatorData")
	if auth.Kind != kindBytes || len(auth.Bytes) < authHeaderBytes || len(auth.Bytes) > MaxAssertionAuthDataBytes {
		return 0, assertFail("authenticatorData length")
	}
	// Real macOS 27 assertions set the AT flag but carry no attested
	// credential data, so flags are not interpreted. Any bytes after the
	// 37-byte header must be exactly one CBOR map.
	if len(auth.Bytes) > authHeaderBytes {
		ext, err := decodeCBOR(auth.Bytes[authHeaderBytes:])
		if err != nil || ext.Kind != kindMap {
			return 0, assertFail("authenticatorData trailing bytes")
		}
	}
	rp := sha256.Sum256([]byte(in.AppID))
	if !bytes.Equal(auth.Bytes[:32], rp[:]) {
		return 0, assertFail("rpIdHash does not match the App ID")
	}
	nonceInput := make([]byte, 0, len(auth.Bytes)+len(in.ClientDataHash))
	nonceInput = append(nonceInput, auth.Bytes...)
	nonceInput = append(nonceInput, in.ClientDataHash...)
	nonce := sha256.Sum256(nonceInput)
	// The signature is ECDSA-SHA256 over the message nonce, so the P-256
	// digest is SHA-256(nonce); the macOS 27 hardware run confirmed this.
	digest := sha256.Sum256(nonce[:])
	if !ecdsa.VerifyASN1(pub, digest[:], sig.Bytes) {
		return 0, assertFail("signature does not verify")
	}
	return binary.BigEndian.Uint32(auth.Bytes[33:37]), nil
}
