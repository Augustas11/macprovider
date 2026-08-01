package payout

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
)

// TestValidatePrivateKeyScalar_RejectsInvalid proves the write-side paths
// reject a zero key and an out-of-range (>= N) scalar — secp256k1.PrivKeyFromBytes
// would otherwise accept zero and silently reduce overflow, deriving an address
// the operator does not control (locked-funds hazard on -key-file import).
func TestValidatePrivateKeyScalar_RejectsInvalid(t *testing.T) {
	zeroKey := make([]byte, 32)
	overflow := make([]byte, 32)
	for i := range overflow {
		overflow[i] = 0xff // 0xffff...ff > curve order N
	}
	kek := make([]byte, 32)
	for _, tc := range []struct {
		name string
		key  []byte
	}{{"zero", zeroKey}, {"overflow_all_ff", overflow}} {
		if _, err := WalletAddressForKey(tc.key); err == nil {
			t.Fatalf("%s: WalletAddressForKey accepted invalid scalar", tc.name)
		}
		if _, err := EncryptWalletKey(tc.key, kek); err == nil {
			t.Fatalf("%s: EncryptWalletKey accepted invalid scalar", tc.name)
		}
	}
}

// TestLoadLocalFileSigner_RejectsInvalidDecryptedScalar proves the READ path
// also validates: a wallet file that decrypts to a zero key (hand-sealed here,
// since EncryptWalletKey now refuses to produce one) must be rejected at load.
func TestLoadLocalFileSigner_RejectsInvalidDecryptedScalar(t *testing.T) {
	kek := make([]byte, 32)
	block, err := aes.NewCipher(kek)
	if err != nil {
		t.Fatalf("aes: %v", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatalf("gcm: %v", err)
	}
	nonce := make([]byte, 12)
	ct := gcm.Seal(nil, nonce, make([]byte, 32), nil) // seal an all-zero "key"
	raw := append(append([]byte{}, nonce...), ct...)
	dir := t.TempDir()
	path := filepath.Join(dir, "w.hex")
	if err := os.WriteFile(path, []byte(hex.EncodeToString(raw)), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	if _, err := LoadLocalFileSigner(EncryptedWalletFile{Path: path, OnDiskHex: true}, kek); err == nil {
		t.Fatal("LoadLocalFileSigner accepted a zero-scalar decrypted key")
	}
}

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
