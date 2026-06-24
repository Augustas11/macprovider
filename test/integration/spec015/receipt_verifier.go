package spec015

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// maxReceiptHeaderBytes mirrors SPEC-015 AC-15. DecodeReceiptHeader rejects
// values above this limit so a misbehaving provider cannot push arbitrarily
// large bytes through the verifier (defense-in-depth atop the Swift-side and
// coordinator-side caps).
const maxReceiptHeaderBytes = 8192

type PoolzReceiptTrust struct {
	ReceiptPubkey     string
	ReceiptPubkeyPrev *PoolzReceiptPubkeyPrevious
}

type PoolzReceiptPubkeyPrevious struct {
	Pubkey    string
	RotatedAt int64
	ExpiresAt int64
}

type VerifiedReceipt struct {
	Tuple     map[string]any
	TupleData []byte
	Signature []byte
	KeySource string
}

func VerifyReceiptAgainstPoolzTrust(header string, trust PoolzReceiptTrust) (VerifiedReceipt, error) {
	tupleData, signature, err := DecodeReceiptHeader(header)
	if err != nil {
		return VerifiedReceipt{}, err
	}
	var tuple map[string]any
	if err := json.Unmarshal(tupleData, &tuple); err != nil {
		return VerifiedReceipt{}, fmt.Errorf("decode tuple: %w", err)
	}
	if err := requireReceiptTupleShape(tuple); err != nil {
		return VerifiedReceipt{}, err
	}
	if err := AssertTupleCanonicalizationMatches(tupleData); err != nil {
		return VerifiedReceipt{}, fmt.Errorf("tuple canonicalization drift: %w", err)
	}
	unixTS, err := receiptUnixTS(tuple)
	if err != nil {
		return VerifiedReceipt{}, err
	}
	providerPubkey, err := receiptProviderPubkey(tuple)
	if err != nil {
		return VerifiedReceipt{}, err
	}
	if verifyWithPubkey(tupleData, signature, trust.ReceiptPubkey) && pubkeyBytesEqual(providerPubkey, trust.ReceiptPubkey) {
		return VerifiedReceipt{Tuple: tuple, TupleData: tupleData, Signature: signature, KeySource: "current"}, nil
	}
	if prev := trust.ReceiptPubkeyPrev; prev != nil {
		stamp := time.Unix(unixTS, 0)
		rotatedAt := time.Unix(prev.RotatedAt, 0)
		expiresAt := time.Unix(prev.ExpiresAt, 0)
		if !stamp.Before(rotatedAt.Add(-60*time.Second)) && !stamp.After(expiresAt) && verifyWithPubkey(tupleData, signature, prev.Pubkey) && pubkeyBytesEqual(providerPubkey, prev.Pubkey) {
			return VerifiedReceipt{Tuple: tuple, TupleData: tupleData, Signature: signature, KeySource: "previous"}, nil
		}
	}
	return VerifiedReceipt{}, errors.New("receipt signature does not match active poolz receipt keys")
}

// pubkeyBytesEqual decodes both sides as base64 and compares the resulting
// raw 32-byte Ed25519 public keys. M15 audit: pure string equality was
// fragile under StdEncoding vs URL-safe (or padded vs unpadded) drift,
// even though both sides typically agree today.
func pubkeyBytesEqual(a, b string) bool {
	if a == b {
		return true
	}
	aBytes, err := base64.StdEncoding.DecodeString(a)
	if err != nil {
		return false
	}
	bBytes, err := base64.StdEncoding.DecodeString(b)
	if err != nil {
		return false
	}
	if len(aBytes) != ed25519.PublicKeySize || len(bBytes) != ed25519.PublicKeySize {
		return false
	}
	return bytes.Equal(aBytes, bBytes)
}

func DecodeReceiptHeader(header string) ([]byte, []byte, error) {
	if len(header) > maxReceiptHeaderBytes {
		return nil, nil, fmt.Errorf("receipt header length %d exceeds %d-byte cap", len(header), maxReceiptHeaderBytes)
	}
	parts := strings.Split(header, ".")
	if len(parts) != 2 {
		return nil, nil, fmt.Errorf("receipt header has %d parts, want 2", len(parts))
	}
	tupleData, err := base64.StdEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, nil, fmt.Errorf("decode tuple: %w", err)
	}
	signature, err := base64.StdEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, nil, fmt.Errorf("decode signature: %w", err)
	}
	if len(signature) != ed25519.SignatureSize {
		return nil, nil, fmt.Errorf("signature must be %d bytes, got %d", ed25519.SignatureSize, len(signature))
	}
	return tupleData, signature, nil
}

func requireReceiptTupleShape(tuple map[string]any) error {
	required := []string{"model_id", "output_hash", "prompt_hash", "provider_pubkey", "tokens_out", "ttft_ms", "unix_ts"}
	if len(tuple) != len(required) {
		return fmt.Errorf("tuple has %d keys, want %d", len(tuple), len(required))
	}
	for _, key := range required {
		if _, ok := tuple[key]; !ok {
			return fmt.Errorf("tuple missing %s", key)
		}
	}
	return nil
}

func receiptUnixTS(tuple map[string]any) (int64, error) {
	value, ok := tuple["unix_ts"]
	if !ok {
		return 0, errors.New("tuple missing unix_ts")
	}
	number, ok := value.(float64)
	if !ok {
		return 0, fmt.Errorf("unix_ts has type %T, want number", value)
	}
	return int64(number), nil
}

func receiptProviderPubkey(tuple map[string]any) (string, error) {
	value, ok := tuple["provider_pubkey"]
	if !ok {
		return "", errors.New("tuple missing provider_pubkey")
	}
	encoded, ok := value.(string)
	if !ok {
		return "", fmt.Errorf("provider_pubkey has type %T, want string", value)
	}
	pubkey, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil || len(pubkey) != ed25519.PublicKeySize {
		return "", fmt.Errorf("provider_pubkey must be base64-encoded %d-byte Ed25519 public key", ed25519.PublicKeySize)
	}
	return encoded, nil
}

func verifyWithPubkey(tupleData, signature []byte, encodedPubkey string) bool {
	if encodedPubkey == "" {
		return false
	}
	pubkey, err := base64.StdEncoding.DecodeString(encodedPubkey)
	if err != nil || len(pubkey) != ed25519.PublicKeySize {
		return false
	}
	return ed25519.Verify(ed25519.PublicKey(pubkey), tupleData, signature)
}
