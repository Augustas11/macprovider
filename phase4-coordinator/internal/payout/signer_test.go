package payout

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLocalFileSigner_FromAddressDerivation(t *testing.T) {
	_, addr := loadKnownKey(t)
	rawHex := "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
	raw, _ := hex.DecodeString(rawHex)
	signer, err := NewLocalFileSignerFromKey(raw)
	if err != nil {
		t.Fatalf("NewLocalFileSignerFromKey: %v", err)
	}
	if signer.FromAddress() != addr {
		t.Errorf("FromAddress = %s, want %s", signer.FromAddress(), addr)
	}
}

func TestLocalFileSigner_SignTx_RoundTrip(t *testing.T) {
	rawHex := "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
	raw, _ := hex.DecodeString(rawHex)
	signer, err := NewLocalFileSignerFromKey(raw)
	if err != nil {
		t.Fatalf("NewLocalFileSignerFromKey: %v", err)
	}
	calldata, _ := USDCTransferCalldata("0x000000000000000000000000000000000000dEaD", 1_000_000)
	usdcBytes, _ := AddressBytes(USDCContractAddressBase)
	var to [20]byte
	copy(to[:], usdcBytes[:])
	tx := EIP1559Tx{
		ChainID:              BaseMainnetChainID,
		Nonce:                7,
		MaxPriorityFeePerGas: big.NewInt(1_500_000_000),
		MaxFeePerGas:         big.NewInt(20_000_000_000),
		GasLimit:             100_000,
		To:                   to,
		Value:                big.NewInt(0),
		Data:                 calldata,
	}
	unsigned, err := tx.UnsignedRLP()
	if err != nil {
		t.Fatalf("UnsignedRLP: %v", err)
	}
	signed, txHash, err := signer.SignTx(context.Background(), unsigned)
	if err != nil {
		t.Fatalf("SignTx: %v", err)
	}
	if len(signed) == 0 || txHash == "" {
		t.Fatal("partial return from SignTx — protocol violation per §6.3.1")
	}
	// Verify recovered sender matches signer's FromAddress.
	recovered, err := RecoverTxSender(signed)
	if err != nil {
		t.Fatalf("RecoverTxSender: %v", err)
	}
	wantLower, _ := NormalizeAddress(signer.FromAddress())
	if !strings.EqualFold(recovered, wantLower) {
		t.Errorf("recovered sender = %s, want %s", recovered, wantLower)
	}
	// Verify TxHash matches Signer's returned hash.
	if TxHash(signed) != txHash {
		t.Errorf("local TxHash = %s, signer returned = %s", TxHash(signed), txHash)
	}
}

func TestLocalFileSigner_SignTx_RejectsWrongChainID(t *testing.T) {
	rawHex := "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
	raw, _ := hex.DecodeString(rawHex)
	signer, _ := NewLocalFileSignerFromKey(raw)
	tx := EIP1559Tx{
		ChainID:              1, // mainnet, not Base
		Nonce:                0,
		MaxPriorityFeePerGas: big.NewInt(1),
		MaxFeePerGas:         big.NewInt(1),
		GasLimit:             21000,
		To:                   [20]byte{1},
		Value:                big.NewInt(0),
		Data:                 nil,
	}
	unsigned, _ := tx.UnsignedRLP()
	_, _, err := signer.SignTx(context.Background(), unsigned)
	if err == nil {
		t.Fatal("expected ErrSignerUnavailable for wrong chain id")
	}
	if !errors.Is(err, ErrSignerUnavailable) {
		t.Errorf("err = %v, want wrapping ErrSignerUnavailable", err)
	}
}

func TestLocalFileSigner_SignTx_CtxCancel(t *testing.T) {
	rawHex := "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
	raw, _ := hex.DecodeString(rawHex)
	signer, _ := NewLocalFileSignerFromKey(raw)
	tx := EIP1559Tx{
		ChainID:              BaseMainnetChainID,
		Nonce:                0,
		MaxPriorityFeePerGas: big.NewInt(1),
		MaxFeePerGas:         big.NewInt(1),
		GasLimit:             21000,
		To:                   [20]byte{1},
		Value:                big.NewInt(0),
	}
	unsigned, _ := tx.UnsignedRLP()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, _, err := signer.SignTx(ctx, unsigned)
	if err == nil || !errors.Is(err, context.Canceled) {
		t.Errorf("expected context.Canceled, got %v", err)
	}
}

func TestLoadLocalFileSigner_DecryptHappyPath(t *testing.T) {
	rawHex := "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
	plain, _ := hex.DecodeString(rawHex)

	kek := make([]byte, 32)
	if _, err := rand.Read(kek); err != nil {
		t.Fatalf("rand: %v", err)
	}
	block, _ := aes.NewCipher(kek)
	gcm, _ := cipher.NewGCM(block)
	nonce := make([]byte, 12)
	if _, err := rand.Read(nonce); err != nil {
		t.Fatalf("rand: %v", err)
	}
	ct := gcm.Seal(nil, nonce, plain, nil)
	file := append(append([]byte(nil), nonce...), ct...)

	path := filepath.Join(t.TempDir(), "wallet.bin")
	if err := os.WriteFile(path, file, 0o600); err != nil {
		t.Fatalf("write wallet: %v", err)
	}
	signer, err := LoadLocalFileSigner(EncryptedWalletFile{Path: path, OnDiskHex: false}, kek)
	if err != nil {
		t.Fatalf("LoadLocalFileSigner: %v", err)
	}
	_, expectedAddr := loadKnownKey(t)
	if signer.FromAddress() != expectedAddr {
		t.Errorf("FromAddress = %s, want %s", signer.FromAddress(), expectedAddr)
	}
}

func TestLoadLocalFileSigner_WrongKEKRejected(t *testing.T) {
	plain := make([]byte, 32)
	for i := range plain {
		plain[i] = byte(i + 1)
	}
	rightKEK := make([]byte, 32)
	if _, err := rand.Read(rightKEK); err != nil {
		t.Fatalf("rand: %v", err)
	}
	block, _ := aes.NewCipher(rightKEK)
	gcm, _ := cipher.NewGCM(block)
	nonce := make([]byte, 12)
	if _, err := rand.Read(nonce); err != nil {
		t.Fatalf("rand: %v", err)
	}
	ct := gcm.Seal(nil, nonce, plain, nil)
	file := append(append([]byte(nil), nonce...), ct...)
	path := filepath.Join(t.TempDir(), "wallet.bin")
	_ = os.WriteFile(path, file, 0o600)

	wrongKEK := make([]byte, 32)
	if _, err := rand.Read(wrongKEK); err != nil {
		t.Fatalf("rand: %v", err)
	}
	_, err := LoadLocalFileSigner(EncryptedWalletFile{Path: path, OnDiskHex: false}, wrongKEK)
	if err == nil {
		t.Fatal("wrong KEK MUST fail decrypt")
	}
	// Confirm the error string does NOT echo KEK / key material.
	if strings.Contains(err.Error(), hex.EncodeToString(plain)) ||
		strings.Contains(err.Error(), hex.EncodeToString(wrongKEK)) ||
		strings.Contains(err.Error(), hex.EncodeToString(rightKEK)) {
		t.Errorf("decrypt error leaks key material: %v", err)
	}
}

func TestLoadLocalFileSigner_ShortKEKRejected(t *testing.T) {
	_, err := LoadLocalFileSigner(EncryptedWalletFile{Path: "/dev/null"}, []byte{1, 2, 3})
	if err == nil {
		t.Fatal("expected error for short KEK")
	}
}
