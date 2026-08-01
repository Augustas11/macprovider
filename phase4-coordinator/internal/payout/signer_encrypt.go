package payout

import (
	"crypto/aes"
	"crypto/cipher"
	crand "crypto/rand"
	"encoding/hex"
	"fmt"
	"io"

	"github.com/decred/dcrd/dcrec/secp256k1/v4"
)

// This file is the WRITE side of the v0.1.x wallet format whose READ
// side is LoadLocalFileSigner (signer.go). It exists so the SPEC-016
// §9.1 "encrypt the wallet with the KEK" step is performed by the
// exact same AES-256-GCM construction the coordinator decrypts with —
// eliminating the hand-rolled-openssl format-mismatch hazard called out
// in dist/payout-runbook.md §1.2. A mismatch here would produce an
// unloadable wallet, i.e. permanently locked payout funds.
//
// Round-trip parity with LoadLocalFileSigner is asserted in
// signer_encrypt_test.go.

// GenerateWalletKey returns a fresh secp256k1 private key using the
// crypto/rand-backed generator. The caller is responsible for keeping
// the returned bytes in memory only and encrypting them before any
// disk write (EncryptWalletKey does not persist plaintext).
func GenerateWalletKey() (*secp256k1.PrivateKey, error) {
	priv, err := secp256k1.GeneratePrivateKey()
	if err != nil {
		return nil, fmt.Errorf("GenerateWalletKey: %w", err)
	}
	return priv, nil
}

// WalletAddressForKey derives the EIP-55-checksummed address for a raw
// 32-byte secp256k1 private key, matching LoadLocalFileSigner's derivation.
func WalletAddressForKey(privKey []byte) (string, error) {
	if len(privKey) != 32 {
		return "", fmt.Errorf("WalletAddressForKey: privKey must be 32 bytes (got %d)", len(privKey))
	}
	priv := secp256k1.PrivKeyFromBytes(privKey)
	return deriveEthereumAddress(priv.PubKey())
}

// EncryptWalletKey seals a raw 32-byte secp256k1 private key under a
// 32-byte KEK using AES-256-GCM with a fresh 12-byte random nonce, and
// returns the hex encoding of nonce||ciphertext — exactly the on-disk
// layout LoadLocalFileSigner expects when OnDiskHex=true:
//
//	0:12   12-byte AES-GCM nonce
//	12:end ciphertext (includes the 16-byte GCM tag)
//
// The KEK MUST be 32 bytes (AES-256) — shorter keys are rejected
// fail-loud, mirroring LoadLocalFileSigner. Neither the private key nor
// the KEK is logged; callers MUST NOT log the returned value either (it
// is ciphertext, but treat the whole flow as secret-handling).
func EncryptWalletKey(privKey []byte, kek []byte) (string, error) {
	if len(privKey) != 32 {
		return "", fmt.Errorf("EncryptWalletKey: privKey must be 32 bytes (got %d)", len(privKey))
	}
	if len(kek) != 32 {
		return "", fmt.Errorf("EncryptWalletKey: KEK must be 32 bytes (got %d)", len(kek))
	}
	block, err := aes.NewCipher(kek)
	if err != nil {
		return "", fmt.Errorf("EncryptWalletKey: aes.NewCipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", fmt.Errorf("EncryptWalletKey: cipher.NewGCM: %w", err)
	}
	if gcm.NonceSize() != 12 {
		// LoadLocalFileSigner slices raw[:12] as the nonce; a non-12
		// nonce size would silently corrupt the format.
		return "", fmt.Errorf("EncryptWalletKey: unexpected GCM nonce size %d, want 12", gcm.NonceSize())
	}
	nonce := make([]byte, 12)
	if _, err := io.ReadFull(crand.Reader, nonce); err != nil {
		return "", fmt.Errorf("EncryptWalletKey: read nonce: %w", err)
	}
	ct := gcm.Seal(nil, nonce, privKey, nil)
	out := make([]byte, 0, len(nonce)+len(ct))
	out = append(out, nonce...)
	out = append(out, ct...)
	return hex.EncodeToString(out), nil
}
