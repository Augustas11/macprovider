package payout

import (
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
)

// TestEncryptWalletKey_RoundTripsThroughLoadLocalFileSigner is the
// load-bearing parity test: a key encrypted by EncryptWalletKey MUST be
// decryptable by LoadLocalFileSigner and derive the same address. A
// format drift here would mean an operator's real hot wallet is
// permanently unloadable (locked funds), so this guards the money path.
func TestEncryptWalletKey_RoundTripsThroughLoadLocalFileSigner(t *testing.T) {
	priv, err := GenerateWalletKey()
	if err != nil {
		t.Fatalf("GenerateWalletKey: %v", err)
	}
	keyBytes := priv.Serialize()
	if len(keyBytes) != 32 {
		t.Fatalf("serialized key = %d bytes, want 32", len(keyBytes))
	}
	wantAddr, err := WalletAddressForKey(keyBytes)
	if err != nil {
		t.Fatalf("WalletAddressForKey: %v", err)
	}

	kek := make([]byte, 32)
	for i := range kek {
		kek[i] = byte(i * 7)
	}

	encHex, err := EncryptWalletKey(keyBytes, kek)
	if err != nil {
		t.Fatalf("EncryptWalletKey: %v", err)
	}

	dir := t.TempDir()
	path := filepath.Join(dir, "wallet.hex")
	if err := os.WriteFile(path, []byte(encHex), 0o600); err != nil {
		t.Fatalf("write wallet: %v", err)
	}

	signer, err := LoadLocalFileSigner(EncryptedWalletFile{Path: path, OnDiskHex: true}, kek)
	if err != nil {
		t.Fatalf("LoadLocalFileSigner could not decrypt EncryptWalletKey output: %v", err)
	}
	if signer.FromAddress() != wantAddr {
		t.Fatalf("round-trip address mismatch: signer=%s want=%s", signer.FromAddress(), wantAddr)
	}
}

// TestEncryptWalletKey_WrongKEKFailsClosed proves a wrong KEK cannot
// silently decrypt to a different key — the GCM tag check must fail.
func TestEncryptWalletKey_WrongKEKFailsClosed(t *testing.T) {
	priv, err := GenerateWalletKey()
	if err != nil {
		t.Fatalf("GenerateWalletKey: %v", err)
	}
	kek := make([]byte, 32)
	encHex, err := EncryptWalletKey(priv.Serialize(), kek)
	if err != nil {
		t.Fatalf("EncryptWalletKey: %v", err)
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "wallet.hex")
	if err := os.WriteFile(path, []byte(encHex), 0o600); err != nil {
		t.Fatalf("write wallet: %v", err)
	}
	wrong := make([]byte, 32)
	wrong[0] = 1
	if _, err := LoadLocalFileSigner(EncryptedWalletFile{Path: path, OnDiskHex: true}, wrong); err == nil {
		t.Fatal("expected decrypt failure with wrong KEK, got nil")
	}
}

// TestEncryptWalletKey_RejectsBadLengths guards the fail-loud length checks.
func TestEncryptWalletKey_RejectsBadLengths(t *testing.T) {
	good := make([]byte, 32)
	if _, err := EncryptWalletKey(make([]byte, 31), good); err == nil {
		t.Fatal("expected error for 31-byte key")
	}
	if _, err := EncryptWalletKey(good, make([]byte, 16)); err == nil {
		t.Fatal("expected error for 16-byte KEK")
	}
}

// TestEncryptWalletKey_FreshNoncePerCall proves each encryption uses a
// distinct nonce (no static-nonce reuse under the same KEK).
func TestEncryptWalletKey_FreshNoncePerCall(t *testing.T) {
	key := make([]byte, 32)
	key[0] = 9
	kek := make([]byte, 32)
	a, err := EncryptWalletKey(key, kek)
	if err != nil {
		t.Fatalf("EncryptWalletKey a: %v", err)
	}
	b, err := EncryptWalletKey(key, kek)
	if err != nil {
		t.Fatalf("EncryptWalletKey b: %v", err)
	}
	if a[:24] == b[:24] { // first 12 bytes = 24 hex chars = the nonce
		t.Fatal("nonce reused across encryptions of the same key")
	}
	// Sanity: both must still be valid hex.
	if _, err := hex.DecodeString(a); err != nil {
		t.Fatalf("output a not hex: %v", err)
	}
}
