package payout

import (
	"bytes"
	"encoding/hex"
	"math/big"
	"strings"
	"testing"

	ecdsa "github.com/decred/dcrd/dcrec/secp256k1/v4/ecdsa"
	"golang.org/x/crypto/sha3"
)

// TestUSDCTransferCalldata_KnownVector locks the §4.3 step 7 (a)
// expected calldata shape. The vector here is hand-derived:
//
//	selector  = 0xa9059cbb
//	to        = 0x000...DEAD (canonical EIP-55 form below)
//	amount    = 1_000_000 (1 USDC = 1e6 base units)
//
// Expected output is 68 bytes total.
func TestUSDCTransferCalldata_KnownVector(t *testing.T) {
	to := "0x000000000000000000000000000000000000dEaD"
	amount := int64(1_000_000)
	got, err := USDCTransferCalldata(to, amount)
	if err != nil {
		t.Fatalf("USDCTransferCalldata: %v", err)
	}
	if len(got) != 68 {
		t.Fatalf("calldata length = %d, want 68", len(got))
	}
	// Selector.
	if !bytes.Equal(got[:4], transferSelector) {
		t.Errorf("selector = %x, want %x", got[:4], transferSelector)
	}
	// 32-byte left-padded address.
	wantAddr := mustHexBytes("000000000000000000000000000000000000000000000000000000000000dead")
	if !bytes.Equal(got[4:36], wantAddr) {
		t.Errorf("address word = %x, want %x", got[4:36], wantAddr)
	}
	// 32-byte big-endian amount (1_000_000 = 0xf4240).
	wantAmt := mustHexBytes("00000000000000000000000000000000000000000000000000000000000f4240")
	if !bytes.Equal(got[36:68], wantAmt) {
		t.Errorf("amount word = %x, want %x", got[36:68], wantAmt)
	}
}

func TestUSDCTransferCalldata_RejectsNonPositiveAmount(t *testing.T) {
	if _, err := USDCTransferCalldata("0x000000000000000000000000000000000000dEaD", 0); err == nil {
		t.Fatal("expected error for amount=0")
	}
	if _, err := USDCTransferCalldata("0x000000000000000000000000000000000000dEaD", -1); err == nil {
		t.Fatal("expected error for negative amount")
	}
}

// TestEIP1559_RoundTripSignAndRecover signs a known unsigned tx
// with the test private key, then runs DecodeSignedEIP1559 +
// RecoverTxSender and asserts the recovered sender matches the
// signer address.
func TestEIP1559_RoundTripSignAndRecover(t *testing.T) {
	priv, signerAddr := loadKnownKey(t)
	calldata, err := USDCTransferCalldata("0x000000000000000000000000000000000000dEaD", 500_000)
	if err != nil {
		t.Fatalf("calldata: %v", err)
	}
	usdcBytes, err := AddressBytes(USDCContractAddressBase)
	if err != nil {
		t.Fatalf("usdc bytes: %v", err)
	}
	var to [20]byte
	copy(to[:], usdcBytes[:])
	tx := EIP1559Tx{
		ChainID:              BaseMainnetChainID,
		Nonce:                42,
		MaxPriorityFeePerGas: big.NewInt(1_500_000_000),  // 1.5 gwei
		MaxFeePerGas:         big.NewInt(20_000_000_000), // 20 gwei
		GasLimit:             100_000,
		To:                   to,
		Value:                big.NewInt(0),
		Data:                 calldata,
	}
	digest, err := tx.SigningHash()
	if err != nil {
		t.Fatalf("signing hash: %v", err)
	}
	// SignCompact returns 65 bytes <recoveryCode><R><S>; for
	// non-compressed pubkeys, recoveryCode = 27 + y_parity.
	compact := ecdsa.SignCompact(priv, digest[:], false)
	yParity := compact[0] - 27
	signedBytes, err := tx.SignedRLP(yParity, compact[1:33], compact[33:65])
	if err != nil {
		t.Fatalf("SignedRLP: %v", err)
	}
	if signedBytes[0] != 0x02 {
		t.Errorf("envelope must start with 0x02 (got %x)", signedBytes[0])
	}
	// Decode round-trip.
	decoded, decYParity, r, s, err := DecodeSignedEIP1559(signedBytes)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if decoded.Nonce != 42 {
		t.Errorf("decoded nonce = %d, want 42", decoded.Nonce)
	}
	if decoded.ChainID != BaseMainnetChainID {
		t.Errorf("decoded chain_id = %d, want %d", decoded.ChainID, BaseMainnetChainID)
	}
	if decYParity != yParity {
		t.Errorf("decoded yParity = %d, want %d", decYParity, yParity)
	}
	// R/S round-trip equal (within left-padding).
	expR := make([]byte, 32)
	copy(expR[32-len(compact[1:33]):], compact[1:33])
	if !bytes.Equal(r[:], expR) {
		t.Errorf("decoded R mismatch")
	}
	expS := make([]byte, 32)
	copy(expS[32-len(compact[33:65]):], compact[33:65])
	if !bytes.Equal(s[:], expS) {
		t.Errorf("decoded S mismatch")
	}
	// ecrecover.
	recovered, err := RecoverTxSender(signedBytes)
	if err != nil {
		t.Fatalf("RecoverTxSender: %v", err)
	}
	expectedLower, _ := NormalizeAddress(signerAddr)
	if !strings.EqualFold(recovered, expectedLower) {
		t.Errorf("recovered sender = %s, want %s", recovered, expectedLower)
	}
}

// TestEIP1559_TxHashMatchesKeccakOfSignedBytes asserts the tx-hash
// surface used by §4.3 step 6 to compare against Signer's
// returned hash.
func TestEIP1559_TxHashMatchesKeccakOfSignedBytes(t *testing.T) {
	signedBytes := []byte{0x02, 0xc0} // tiny placeholder envelope
	h := sha3.NewLegacyKeccak256()
	_, _ = h.Write(signedBytes)
	want := "0x" + hex.EncodeToString(h.Sum(nil))
	got := TxHash(signedBytes)
	if got != want {
		t.Errorf("TxHash = %s, want %s", got, want)
	}
}

// TestEIP1559_RLPEmptyAccessList asserts the access-list slot is
// encoded as 0xc0 (empty list) — a non-empty access list would
// inflate the envelope and break §4.3 step 6 invariants.
func TestEIP1559_RLPEmptyAccessList(t *testing.T) {
	calldata, _ := USDCTransferCalldata("0x000000000000000000000000000000000000dEaD", 1)
	usdcBytes, _ := AddressBytes(USDCContractAddressBase)
	var to [20]byte
	copy(to[:], usdcBytes[:])
	tx := EIP1559Tx{
		ChainID:              BaseMainnetChainID,
		Nonce:                0,
		MaxPriorityFeePerGas: big.NewInt(1),
		MaxFeePerGas:         big.NewInt(1),
		GasLimit:             21000,
		To:                   to,
		Value:                big.NewInt(0),
		Data:                 calldata,
	}
	unsigned, err := tx.UnsignedRLP()
	if err != nil {
		t.Fatalf("UnsignedRLP: %v", err)
	}
	if !bytes.Contains(unsigned, []byte{0xc0}) {
		t.Errorf("unsigned envelope should contain 0xc0 access-list marker; got %x", unsigned)
	}
}

func TestEIP1559_DecodeRejectsNonType02(t *testing.T) {
	if _, _, _, _, err := DecodeSignedEIP1559([]byte{0x01, 0xc0}); err == nil {
		t.Fatal("expected error for tx-type 0x01")
	}
	if _, _, _, _, err := DecodeSignedEIP1559([]byte{}); err == nil {
		t.Fatal("expected error for empty input")
	}
}

// TestEIP1559_DecodeRejectsTrailingBytes locks codex round-1
// [code:1.4]: bytes after the top-level list MUST be rejected.
func TestEIP1559_DecodeRejectsTrailingBytes(t *testing.T) {
	priv, _ := loadKnownKey(t)
	calldata, _ := USDCTransferCalldata("0x000000000000000000000000000000000000dEaD", 1)
	usdcBytes, _ := AddressBytes(USDCContractAddressBase)
	var to [20]byte
	copy(to[:], usdcBytes[:])
	tx := EIP1559Tx{
		ChainID:              BaseMainnetChainID,
		Nonce:                1,
		MaxPriorityFeePerGas: big.NewInt(1),
		MaxFeePerGas:         big.NewInt(1),
		GasLimit:             21000,
		To:                   to,
		Value:                big.NewInt(0),
		Data:                 calldata,
	}
	digest, _ := tx.SigningHash()
	compact := ecdsa.SignCompact(priv, digest[:], false)
	signed, _ := tx.SignedRLP(compact[0]-27, compact[1:33], compact[33:65])
	// Append a garbage byte.
	tampered := append([]byte(nil), signed...)
	tampered = append(tampered, 0xff)
	if _, _, _, _, err := DecodeSignedEIP1559(tampered); err == nil {
		t.Fatal("expected error for trailing byte")
	}
}

// loadKnownKey is also defined in eip712_test.go; this duplicate
// is in evm_test.go via blank-import (no — we keep one definition
// in eip712_test.go and reuse it here since tests in the same
// package share helpers).

// PadAddressTopic round-trip.
func TestPadAddressTopic(t *testing.T) {
	got, err := PadAddressTopic(USDCContractAddressBase)
	if err != nil {
		t.Fatalf("PadAddressTopic: %v", err)
	}
	if len(got) != 32 {
		t.Fatalf("len = %d, want 32", len(got))
	}
	for i := 0; i < 12; i++ {
		if got[i] != 0 {
			t.Errorf("byte %d = %x, want 0 (left-padding)", i, got[i])
		}
	}
}
