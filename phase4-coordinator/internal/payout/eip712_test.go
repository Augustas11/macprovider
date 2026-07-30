package payout

import (
	"encoding/hex"
	"errors"
	"strings"
	"testing"

	"github.com/decred/dcrd/dcrec/secp256k1/v4"
	ecdsa "github.com/decred/dcrd/dcrec/secp256k1/v4/ecdsa"
	"golang.org/x/crypto/sha3"
)

// knownPrivKeyHex is a deterministic test-only secp256k1 private
// key. The corresponding Ethereum address is computed in the
// test and used both as the signer's expected address and as
// the canonical address in the EIP-712 typed-data.
const knownPrivKeyHex = "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

func loadKnownKey(t *testing.T) (*secp256k1.PrivateKey, string) {
	t.Helper()
	raw, err := hex.DecodeString(knownPrivKeyHex)
	if err != nil {
		t.Fatalf("decode priv key: %v", err)
	}
	priv := secp256k1.PrivKeyFromBytes(raw)
	pub := priv.PubKey()
	uncompressed := pub.SerializeUncompressed()
	hash := sha3.NewLegacyKeccak256()
	_, _ = hash.Write(uncompressed[1:])
	digest := hash.Sum(nil)
	addrLower := "0x" + hex.EncodeToString(digest[len(digest)-20:])
	canonical, err := CanonicalizeEIP55(addrLower)
	if err != nil {
		t.Fatalf("canonicalize signer addr: %v", err)
	}
	return priv, canonical
}

// signEIP712 takes the inputs that VerifyEIP712 expects and the
// known private key, computes the digest, signs it, and returns
// the 0x-prefixed r||s||v hex string with v in {27, 28}.
func signEIP712(t *testing.T, priv *secp256k1.PrivateKey, inputs EIP712Inputs) string {
	t.Helper()
	digest, err := buildDigest(inputs)
	if err != nil {
		t.Fatalf("buildDigest: %v", err)
	}
	// SignCompact returns 65 bytes: <v(27+recovery code)><32 R><32 S>.
	// The "compressed" bit MUST NOT be set in the recovery byte
	// for plain EIP-712 signatures.
	compact := ecdsa.SignCompact(priv, digest[:], false)
	if len(compact) != 65 {
		t.Fatalf("SignCompact returned %d bytes, want 65", len(compact))
	}
	v := compact[0]
	if v != 27 && v != 28 {
		t.Fatalf("SignCompact returned v=%d outside {27,28}", v)
	}
	// EIP-712 wire form is r||s||v.
	wire := make([]byte, 65)
	copy(wire[0:32], compact[1:33])
	copy(wire[32:64], compact[33:65])
	wire[64] = v
	return "0x" + hex.EncodeToString(wire)
}

func TestVerifyEIP712_HappyPath(t *testing.T) {
	priv, signerAddr := loadKnownKey(t)
	hotWallet := "0x52908400098527886E0F7030069857D2E4169EE7"
	var nonce32 [32]byte
	for i := range nonce32 {
		nonce32[i] = byte(i + 1)
	}
	inputs := EIP712Inputs{
		ProviderID:        "test-provider-id",
		CanonicalAddr:     signerAddr,
		Chain:             "base-mainnet",
		Nonce32:           nonce32,
		TsUtc:             1719234896,
		VerifyingContract: hotWallet,
	}
	sigHex := signEIP712(t, priv, inputs)
	if _, err := VerifyEIP712(inputs, sigHex); err != nil {
		t.Fatalf("verify happy path: %v", err)
	}
}

func TestVerifyEIP712_WrongVerifyingContractRejected(t *testing.T) {
	priv, signerAddr := loadKnownKey(t)
	original := EIP712Inputs{
		ProviderID:        "test-provider-id",
		CanonicalAddr:     signerAddr,
		Chain:             "base-mainnet",
		Nonce32:           [32]byte{1, 2, 3, 4, 5},
		TsUtc:             1719234896,
		VerifyingContract: "0x52908400098527886E0F7030069857D2E4169EE7",
	}
	sigHex := signEIP712(t, priv, original)
	tampered := original
	tampered.VerifyingContract = "0x8617E340B3D01FA5F11F306F4090FD50E238070D"
	if _, err := VerifyEIP712(tampered, sigHex); !errors.Is(err, ErrSignatureMismatch) {
		t.Fatalf("expected ErrSignatureMismatch on verifyingContract swap, got %v", err)
	}
}

func TestVerifyEIP712_WrongNonceRejected(t *testing.T) {
	// Decorative-field replay defense: a body whose typed-data
	// `nonce` does not match the request body's nonce MUST be
	// rejected even if ecrecover succeeds against some signer.
	priv, signerAddr := loadKnownKey(t)
	original := EIP712Inputs{
		ProviderID:        "test-provider-id",
		CanonicalAddr:     signerAddr,
		Chain:             "base-mainnet",
		Nonce32:           [32]byte{1, 1, 1, 1},
		TsUtc:             1719234896,
		VerifyingContract: "0x52908400098527886E0F7030069857D2E4169EE7",
	}
	sigHex := signEIP712(t, priv, original)
	tampered := original
	tampered.Nonce32 = [32]byte{2, 2, 2, 2}
	if _, err := VerifyEIP712(tampered, sigHex); !errors.Is(err, ErrSignatureMismatch) {
		t.Fatalf("expected ErrSignatureMismatch on nonce swap, got %v", err)
	}
}

func TestVerifyEIP712_BadSignatureLengthRejected(t *testing.T) {
	inputs := EIP712Inputs{
		ProviderID:        "p",
		CanonicalAddr:     "0x52908400098527886E0F7030069857D2E4169EE7",
		Chain:             "base-mainnet",
		Nonce32:           [32]byte{},
		TsUtc:             1,
		VerifyingContract: "0x52908400098527886E0F7030069857D2E4169EE7",
	}
	bad := "0x" + strings.Repeat("00", 64) // 128 hex chars, not 130
	if _, err := VerifyEIP712(inputs, bad); !errors.Is(err, ErrSignatureMismatch) {
		t.Fatalf("expected ErrSignatureMismatch on bad sig length, got %v", err)
	}
}

func TestVerifyEIP712_BadVRejected(t *testing.T) {
	inputs := EIP712Inputs{
		ProviderID:        "p",
		CanonicalAddr:     "0x52908400098527886E0F7030069857D2E4169EE7",
		Chain:             "base-mainnet",
		Nonce32:           [32]byte{},
		TsUtc:             1,
		VerifyingContract: "0x52908400098527886E0F7030069857D2E4169EE7",
	}
	// 65 bytes, but v = 0 (rejected — Ethereum convention is {27,28}).
	bad := "0x" + strings.Repeat("00", 64) + "00"
	if _, err := VerifyEIP712(inputs, bad); !errors.Is(err, ErrSignatureMismatch) {
		t.Fatalf("expected ErrSignatureMismatch on v=0, got %v", err)
	}
}
