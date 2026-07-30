package payout

import (
	"bytes"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"strings"

	"golang.org/x/crypto/sha3"
)

// SPEC-016 §4.3 step 6 / §6.3.1 — EVM utilities for building,
// signing, decoding, and re-verifying EIP-1559 transactions
// targeting USDC on Base mainnet (chain id 8453).
//
// This file is pure Go — no go-ethereum dep. RLP is implemented
// inline because the encoded payload is small + deterministic
// and the alternative (importing github.com/ethereum/go-ethereum)
// pulls a ~50 MB transitive graph that is mostly unused by the
// money-OUT path. Test vectors lock the encoding against
// reference outputs.

// USDCContractAddressBase is the canonical USDC contract on Base
// mainnet (chain id 8453). SPEC-016 §3.2 step 4 + §4.3 step 6 +
// §4.3 step 7 all pin to this exact address. The deny-list also
// uses this constant.
const USDCContractAddressBase = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

// BaseMainnetChainID is the canonical Base mainnet chain id.
// SPEC-016 §3.2 step 5 (EIP-712 domain) and §4.3 step 6 (tx
// build) both pin to this constant.
const BaseMainnetChainID uint64 = 8453

// USDCBaseDecimals is the on-chain decimal scaling for USDC on
// Base. SPEC-016 §4.3 step 2 ("unit identity") relies on this
// equaling SPEC-005 §5.1's 1-credit = 1 USD-micro-dollar unit
// scaling.
const USDCBaseDecimals = 6

// transferSelector is the keccak256 prefix of
// "transfer(address,uint256)" — the ERC-20 transfer function
// selector. Fixed across all ERC-20 tokens.
var transferSelector = []byte{0xa9, 0x05, 0x9c, 0xbb}

// transferEventTopic is the keccak256 of
// "Transfer(address,address,uint256)" — the ERC-20 Transfer
// event topic. SPEC-016 §4.3 step 7 (c) verifies this on the
// receipt log.
//
// keccak256("Transfer(address,address,uint256)") =
//
//	0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef
var transferEventTopic = mustHexBytes("ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef")

// USDCTransferCalldata builds the ERC-20 calldata for
// `transfer(to, amount)` against USDC on Base. The output is
// EXACTLY 68 bytes: 4-byte selector + 32-byte left-padded
// address + 32-byte big-endian uint256 amount. SPEC-016 §4.3
// step 6 (build) and step 7 (a) verify this exact shape.
func USDCTransferCalldata(toAddress string, amountBaseUnits int64) ([]byte, error) {
	if amountBaseUnits <= 0 {
		return nil, fmt.Errorf("USDCTransferCalldata: amount must be > 0, got %d", amountBaseUnits)
	}
	addrBytes, err := AddressBytes(toAddress)
	if err != nil {
		return nil, fmt.Errorf("USDCTransferCalldata: to address: %w", err)
	}
	out := make([]byte, 0, 68)
	out = append(out, transferSelector...)
	// uint160 address, left-padded to 32 bytes.
	var addrWord [32]byte
	copy(addrWord[12:], addrBytes[:])
	out = append(out, addrWord[:]...)
	// uint256 amount, big-endian.
	var amtWord [32]byte
	(&big.Int{}).SetInt64(amountBaseUnits).FillBytes(amtWord[:])
	out = append(out, amtWord[:]...)
	if len(out) != 68 {
		return nil, fmt.Errorf("USDCTransferCalldata: encoded length = %d, want 68", len(out))
	}
	return out, nil
}

// EIP1559Tx is the in-memory representation of an EIP-1559
// (typed-tx type 0x02) transaction. Field types match the
// EIP-1559 RLP encoding shape. AccessList is always empty for
// the SPEC-016 hot path (no gas savings on a plain USDC transfer).
//
// All address/hash fields are stored as raw bytes (no 0x
// prefix). All integer fields are stored as natively typed.
type EIP1559Tx struct {
	ChainID              uint64
	Nonce                uint64
	MaxPriorityFeePerGas *big.Int
	MaxFeePerGas         *big.Int
	GasLimit             uint64
	To                   [20]byte
	Value                *big.Int
	Data                 []byte
}

// Validate enforces the SPEC §4.3 step 6 pre-broadcast invariants
// on the runner-built tx (BEFORE Signer is called). The set
// matches what the §4.3 step 6 NORMATIVE block then re-verifies
// after Signer returns.
func (t EIP1559Tx) Validate() error {
	if t.ChainID != BaseMainnetChainID {
		return fmt.Errorf("EIP1559Tx: chain_id must be %d, got %d", BaseMainnetChainID, t.ChainID)
	}
	if t.MaxPriorityFeePerGas == nil || t.MaxPriorityFeePerGas.Sign() < 0 {
		return errors.New("EIP1559Tx: max_priority_fee_per_gas must be set and non-negative")
	}
	if t.MaxFeePerGas == nil || t.MaxFeePerGas.Sign() < 0 {
		return errors.New("EIP1559Tx: max_fee_per_gas must be set and non-negative")
	}
	if t.MaxFeePerGas.Cmp(t.MaxPriorityFeePerGas) < 0 {
		return errors.New("EIP1559Tx: max_fee_per_gas must be >= max_priority_fee_per_gas")
	}
	if t.GasLimit == 0 {
		return errors.New("EIP1559Tx: gas_limit must be > 0")
	}
	if t.Value == nil {
		return errors.New("EIP1559Tx: value must be set (use big.NewInt(0) for zero)")
	}
	return nil
}

// UnsignedRLP returns the EIP-2718 type-prefixed RLP encoding of
// the unsigned EIP-1559 transaction with empty signature fields
// (v, r, s = 0). This is the exact byte sequence the Signer
// receives per §6.3.1 contract — caller does NOT pre-hash.
//
// Wire format (from EIP-1559 / EIP-2718):
//
//	0x02 || rlp([chain_id, nonce, max_priority_fee_per_gas,
//	             max_fee_per_gas, gas_limit, to, value, data,
//	             access_list, v, r, s])
//
// For UNSIGNED the trailing v/r/s are zero. For SIGNED they are
// the signature components (y_parity 0/1, r, s).
func (t EIP1559Tx) UnsignedRLP() ([]byte, error) {
	if err := t.Validate(); err != nil {
		return nil, err
	}
	list := [][]byte{
		rlpUint(t.ChainID),
		rlpUint(t.Nonce),
		rlpBigInt(t.MaxPriorityFeePerGas),
		rlpBigInt(t.MaxFeePerGas),
		rlpUint(t.GasLimit),
		rlpBytes(t.To[:]),
		rlpBigInt(t.Value),
		rlpBytes(t.Data),
		rlpList(nil), // empty access list
		// Trailing zero signature fields (unsigned).
		rlpUint(0), // y_parity
		rlpBytes(nil),
		rlpBytes(nil),
	}
	return prependEIP2718(0x02, rlpList(list)), nil
}

// SignedRLP returns the EIP-2718 type-prefixed RLP encoding of a
// SIGNED EIP-1559 transaction. yParity ∈ {0, 1}; r and s are
// 32-byte signature components (big-endian). The function
// validates basic well-formedness.
func (t EIP1559Tx) SignedRLP(yParity uint8, r, s []byte) ([]byte, error) {
	if err := t.Validate(); err != nil {
		return nil, err
	}
	if yParity > 1 {
		return nil, fmt.Errorf("EIP1559Tx.SignedRLP: yParity must be 0 or 1, got %d", yParity)
	}
	if len(r) == 0 || len(r) > 32 || len(s) == 0 || len(s) > 32 {
		return nil, errors.New("EIP1559Tx.SignedRLP: r and s must be 1-32 bytes each")
	}
	list := [][]byte{
		rlpUint(t.ChainID),
		rlpUint(t.Nonce),
		rlpBigInt(t.MaxPriorityFeePerGas),
		rlpBigInt(t.MaxFeePerGas),
		rlpUint(t.GasLimit),
		rlpBytes(t.To[:]),
		rlpBigInt(t.Value),
		rlpBytes(t.Data),
		rlpList(nil),
		rlpUint(uint64(yParity)),
		rlpBytes(trimLeadingZeros(r)),
		rlpBytes(trimLeadingZeros(s)),
	}
	return prependEIP2718(0x02, rlpList(list)), nil
}

// TxHash returns the keccak256 of a SIGNED EIP-1559 tx envelope.
// This is the canonical Ethereum tx hash — the value users see
// in basescan.org and the value §4.3 step 6 compares against
// Signer's returned `txHash`.
func TxHash(signedTxBytes []byte) string {
	hash := sha3.NewLegacyKeccak256()
	_, _ = hash.Write(signedTxBytes)
	return "0x" + hex.EncodeToString(hash.Sum(nil))
}

// DecodeSignedEIP1559 parses a signed EIP-1559 envelope back into
// its components for the §4.3 step 6 pre-broadcast verification.
// Returns the tx fields + the signature (yParity, r, s) for
// downstream ecrecover. Rejects any envelope that isn't tx-type
// 0x02. Tolerates short integer fields (RLP minimal encoding) by
// left-padding into [32]byte buffers for r/s.
func DecodeSignedEIP1559(signedTxBytes []byte) (tx EIP1559Tx, yParity uint8, r, s [32]byte, err error) {
	if len(signedTxBytes) < 2 {
		return tx, 0, r, s, errors.New("DecodeSignedEIP1559: envelope too short")
	}
	if signedTxBytes[0] != 0x02 {
		return tx, 0, r, s, fmt.Errorf("DecodeSignedEIP1559: envelope is not type 0x02 (got 0x%02x)", signedTxBytes[0])
	}
	body := signedTxBytes[1:]
	items, consumed, kinds, derr := rlpDecodeListWithKinds(body)
	if derr != nil {
		return tx, 0, r, s, fmt.Errorf("DecodeSignedEIP1559: RLP decode body: %w", derr)
	}
	// Closes codex round-1 [code:1.4] MEDIUM: trailing bytes after
	// the top-level list MUST be rejected. A signer that emits an
	// envelope plus garbage tail bytes is misbehaving — accepting
	// the prefix would weaken the §4.3 step 6 pre-broadcast guard.
	if consumed != len(body) {
		return tx, 0, r, s, fmt.Errorf("DecodeSignedEIP1559: trailing %d bytes after top-level list", len(body)-consumed)
	}
	if len(items) != 12 {
		return tx, 0, r, s, fmt.Errorf("DecodeSignedEIP1559: expected 12 fields, got %d", len(items))
	}
	chainID, err := rlpItemUint(items[0])
	if err != nil {
		return tx, 0, r, s, fmt.Errorf("chain_id: %w", err)
	}
	nonce, err := rlpItemUint(items[1])
	if err != nil {
		return tx, 0, r, s, fmt.Errorf("nonce: %w", err)
	}
	maxPrio := new(big.Int).SetBytes(items[2])
	maxFee := new(big.Int).SetBytes(items[3])
	gasLimit, err := rlpItemUint(items[4])
	if err != nil {
		return tx, 0, r, s, fmt.Errorf("gas_limit: %w", err)
	}
	if len(items[5]) != 20 {
		return tx, 0, r, s, fmt.Errorf("to: must be 20 bytes, got %d", len(items[5]))
	}
	var to [20]byte
	copy(to[:], items[5])
	value := new(big.Int).SetBytes(items[6])
	data := items[7]
	// items[8] = access list — MUST be the empty list 0xc0, NOT
	// the empty string 0x80. Closes codex round-1 [code:1.4]:
	// before, a 0x80-encoded empty string passed because both
	// values surfaced as a zero-length byte slice. The kinds[]
	// array now distinguishes string-vs-list at the RLP level.
	if kinds[8] != rlpKindList {
		return tx, 0, r, s, fmt.Errorf("access_list must be RLP list (got kind=%d)", kinds[8])
	}
	if len(items[8]) != 0 {
		return tx, 0, r, s, errors.New("access_list must be empty for §4.3 hot path")
	}
	parityU, err := rlpItemUint(items[9])
	if err != nil {
		return tx, 0, r, s, fmt.Errorf("y_parity: %w", err)
	}
	if parityU > 1 {
		return tx, 0, r, s, fmt.Errorf("y_parity must be 0 or 1, got %d", parityU)
	}
	yParity = uint8(parityU)
	rBytes := items[10]
	sBytes := items[11]
	if len(rBytes) == 0 || len(rBytes) > 32 || len(sBytes) == 0 || len(sBytes) > 32 {
		return tx, 0, r, s, errors.New("r/s must be 1-32 bytes each")
	}
	copy(r[32-len(rBytes):], rBytes)
	copy(s[32-len(sBytes):], sBytes)
	tx = EIP1559Tx{
		ChainID:              chainID,
		Nonce:                nonce,
		MaxPriorityFeePerGas: maxPrio,
		MaxFeePerGas:         maxFee,
		GasLimit:             gasLimit,
		To:                   to,
		Value:                value,
		Data:                 data,
	}
	return tx, yParity, r, s, nil
}

// SigningHash returns the keccak256 of the unsigned EIP-2718
// envelope — the digest the Signer signs over. Useful for tests
// that need to drive ecrecover against an in-process signer.
func (t EIP1559Tx) SigningHash() ([32]byte, error) {
	unsigned, err := t.UnsignedRLP()
	if err != nil {
		return [32]byte{}, err
	}
	hash := sha3.NewLegacyKeccak256()
	_, _ = hash.Write(unsigned)
	var out [32]byte
	copy(out[:], hash.Sum(nil))
	return out, nil
}

// RecoverTxSender recovers the lowercase 0x-prefixed Ethereum
// address that signed a SIGNED EIP-1559 envelope. SPEC §4.3 step
// 6 pre-broadcast verification uses this — IMPL MUST NOT trust
// Signer.FromAddress() blindly; a compromised Signer could return
// a tx signed by a different key.
func RecoverTxSender(signedTxBytes []byte) (string, error) {
	tx, yParity, r, s, err := DecodeSignedEIP1559(signedTxBytes)
	if err != nil {
		return "", fmt.Errorf("RecoverTxSender: decode: %w", err)
	}
	digest, err := tx.SigningHash()
	if err != nil {
		return "", fmt.Errorf("RecoverTxSender: signing hash: %w", err)
	}
	// EIP-1559 uses y_parity (0/1); the decred RecoverCompact API
	// wants Ethereum-style {27, 28}.
	sig := make([]byte, 65)
	sig[0] = 27 + yParity
	copy(sig[1:33], r[:])
	copy(sig[33:65], s[:])
	return ecrecover(digest[:], sig)
}

// USDCTransferLogTopic returns the constant keccak256 topic for
// ERC-20 Transfer events. Test surface only — internal callers
// use transferEventTopic directly.
func USDCTransferLogTopic() []byte {
	cpy := make([]byte, len(transferEventTopic))
	copy(cpy, transferEventTopic)
	return cpy
}

// PadAddressTopic returns the 32-byte left-padded address form
// used in ERC-20 Transfer log topics[1] / topics[2]. The input
// MUST be a canonical EIP-55 or pure-case address.
func PadAddressTopic(addr string) ([]byte, error) {
	bytes, err := AddressBytes(addr)
	if err != nil {
		return nil, err
	}
	out := make([]byte, 32)
	copy(out[12:], bytes[:])
	return out, nil
}

// ---- RLP minimal encoder ------------------------------------------------

// rlpUint encodes an unsigned integer per RLP rules: leading
// zero bytes stripped; 0 encodes as the single byte 0x80 (the
// empty-bytes encoding).
func rlpUint(v uint64) []byte {
	if v == 0 {
		return []byte{0x80}
	}
	var buf [8]byte
	binaryBigEndianPutUint64(buf[:], v)
	return rlpBytes(trimLeadingZeros(buf[:]))
}

// rlpBigInt encodes a non-negative big integer.
func rlpBigInt(v *big.Int) []byte {
	if v == nil || v.Sign() == 0 {
		return []byte{0x80}
	}
	return rlpBytes(trimLeadingZeros(v.Bytes()))
}

// rlpBytes encodes a byte string per RLP rules.
func rlpBytes(b []byte) []byte {
	// Empty string.
	if len(b) == 0 {
		return []byte{0x80}
	}
	// Single byte < 0x80 encodes as itself.
	if len(b) == 1 && b[0] < 0x80 {
		return []byte{b[0]}
	}
	if len(b) <= 55 {
		out := make([]byte, 0, 1+len(b))
		out = append(out, 0x80+byte(len(b)))
		out = append(out, b...)
		return out
	}
	lenBytes := bigEndianLen(uint64(len(b)))
	out := make([]byte, 0, 1+len(lenBytes)+len(b))
	out = append(out, 0xb7+byte(len(lenBytes)))
	out = append(out, lenBytes...)
	out = append(out, b...)
	return out
}

// rlpList encodes a list of already-RLP-encoded items.
func rlpList(items [][]byte) []byte {
	total := 0
	for _, it := range items {
		total += len(it)
	}
	if total == 0 {
		return []byte{0xc0}
	}
	if total <= 55 {
		out := make([]byte, 0, 1+total)
		out = append(out, 0xc0+byte(total))
		for _, it := range items {
			out = append(out, it...)
		}
		return out
	}
	lenBytes := bigEndianLen(uint64(total))
	out := make([]byte, 0, 1+len(lenBytes)+total)
	out = append(out, 0xf7+byte(len(lenBytes)))
	out = append(out, lenBytes...)
	for _, it := range items {
		out = append(out, it...)
	}
	return out
}

// rlpKind distinguishes the RLP item type at the wire level so
// the EIP-1559 decoder can reject a misencoded access-list slot
// (0x80 empty string vs 0xc0 empty list).
type rlpKind int

const (
	rlpKindString rlpKind = 1
	rlpKindList   rlpKind = 2
)

// rlpDecodeListWithKinds parses an RLP-encoded list and returns
// the inner item byte slices, the consumed byte count, the item
// kinds, and any error. The kinds slice is parallel with the
// items slice.
func rlpDecodeListWithKinds(b []byte) ([][]byte, int, []rlpKind, error) {
	if len(b) == 0 {
		return nil, 0, nil, errors.New("rlpDecodeListWithKinds: empty input")
	}
	prefix := b[0]
	var payloadLen int
	var headerLen int
	switch {
	case prefix >= 0xc0 && prefix <= 0xf7:
		payloadLen = int(prefix - 0xc0)
		headerLen = 1
	case prefix >= 0xf8 && prefix <= 0xff:
		ll := int(prefix - 0xf7)
		if len(b) < 1+ll {
			return nil, 0, nil, errors.New("rlpDecodeListWithKinds: truncated long-list header")
		}
		payloadLen = int(bigEndianRead(b[1 : 1+ll]))
		headerLen = 1 + ll
	default:
		return nil, 0, nil, fmt.Errorf("rlpDecodeListWithKinds: prefix 0x%02x is not a list", prefix)
	}
	if len(b) < headerLen+payloadLen {
		return nil, 0, nil, errors.New("rlpDecodeListWithKinds: truncated list payload")
	}
	payload := b[headerLen : headerLen+payloadLen]
	out := [][]byte{}
	kinds := []rlpKind{}
	for len(payload) > 0 {
		item, used, kind, err := rlpDecodeItemWithKind(payload)
		if err != nil {
			return nil, 0, nil, err
		}
		out = append(out, item)
		kinds = append(kinds, kind)
		payload = payload[used:]
	}
	return out, headerLen + payloadLen, kinds, nil
}

// rlpDecodeItemWithKind extends rlpDecodeItem with the wire-kind
// distinction so the EIP-1559 decoder can enforce that the
// access-list slot is encoded as an empty LIST (0xc0), not as an
// empty STRING (0x80).
func rlpDecodeItemWithKind(b []byte) ([]byte, int, rlpKind, error) {
	if len(b) == 0 {
		return nil, 0, 0, errors.New("rlpDecodeItemWithKind: empty input")
	}
	prefix := b[0]
	switch {
	case prefix < 0x80:
		return []byte{prefix}, 1, rlpKindString, nil
	case prefix == 0x80:
		return []byte{}, 1, rlpKindString, nil
	case prefix >= 0x81 && prefix <= 0xb7:
		l := int(prefix - 0x80)
		if len(b) < 1+l {
			return nil, 0, 0, errors.New("rlpDecodeItemWithKind: truncated short-string")
		}
		return b[1 : 1+l], 1 + l, rlpKindString, nil
	case prefix >= 0xb8 && prefix <= 0xbf:
		ll := int(prefix - 0xb7)
		if len(b) < 1+ll {
			return nil, 0, 0, errors.New("rlpDecodeItemWithKind: truncated long-string header")
		}
		l := int(bigEndianRead(b[1 : 1+ll]))
		if len(b) < 1+ll+l {
			return nil, 0, 0, errors.New("rlpDecodeItemWithKind: truncated long-string payload")
		}
		return b[1+ll : 1+ll+l], 1 + ll + l, rlpKindString, nil
	case prefix == 0xc0:
		return []byte{}, 1, rlpKindList, nil
	case prefix >= 0xc1 && prefix <= 0xf7:
		return nil, 0, 0, errors.New("rlpDecodeItemWithKind: nested non-empty list payload not supported in this scope")
	case prefix >= 0xf8 && prefix <= 0xff:
		return nil, 0, 0, errors.New("rlpDecodeItemWithKind: nested long-list payload not supported in this scope")
	}
	return nil, 0, 0, fmt.Errorf("rlpDecodeItemWithKind: unexpected prefix 0x%02x", prefix)
}

// rlpDecodeList parses an RLP-encoded list and returns the inner
// item byte slices, the consumed byte count, and any error.
// Wrapper that drops the kinds — kept for callers that don't
// need the kind distinction (test code, simple paths).
func rlpDecodeList(b []byte) ([][]byte, int, error) {
	if len(b) == 0 {
		return nil, 0, errors.New("rlpDecodeList: empty input")
	}
	prefix := b[0]
	var payloadLen int
	var headerLen int
	switch {
	case prefix >= 0xc0 && prefix <= 0xf7:
		payloadLen = int(prefix - 0xc0)
		headerLen = 1
	case prefix >= 0xf8 && prefix <= 0xff:
		ll := int(prefix - 0xf7)
		if len(b) < 1+ll {
			return nil, 0, errors.New("rlpDecodeList: truncated long-list header")
		}
		payloadLen = int(bigEndianRead(b[1 : 1+ll]))
		headerLen = 1 + ll
	default:
		return nil, 0, fmt.Errorf("rlpDecodeList: prefix 0x%02x is not a list", prefix)
	}
	if len(b) < headerLen+payloadLen {
		return nil, 0, errors.New("rlpDecodeList: truncated list payload")
	}
	payload := b[headerLen : headerLen+payloadLen]
	out := [][]byte{}
	for len(payload) > 0 {
		item, used, err := rlpDecodeItem(payload)
		if err != nil {
			return nil, 0, err
		}
		out = append(out, item)
		payload = payload[used:]
	}
	return out, headerLen + payloadLen, nil
}

// rlpDecodeItem parses ONE RLP item (byte-string OR list); for a
// list it surfaces a zero-length byte slice (the SPEC-016 caller
// only sees the empty access-list).
func rlpDecodeItem(b []byte) ([]byte, int, error) {
	if len(b) == 0 {
		return nil, 0, errors.New("rlpDecodeItem: empty input")
	}
	prefix := b[0]
	switch {
	case prefix < 0x80:
		return []byte{prefix}, 1, nil
	case prefix == 0x80:
		return []byte{}, 1, nil
	case prefix >= 0x81 && prefix <= 0xb7:
		l := int(prefix - 0x80)
		if len(b) < 1+l {
			return nil, 0, errors.New("rlpDecodeItem: truncated short-string")
		}
		return b[1 : 1+l], 1 + l, nil
	case prefix >= 0xb8 && prefix <= 0xbf:
		ll := int(prefix - 0xb7)
		if len(b) < 1+ll {
			return nil, 0, errors.New("rlpDecodeItem: truncated long-string header")
		}
		l := int(bigEndianRead(b[1 : 1+ll]))
		if len(b) < 1+ll+l {
			return nil, 0, errors.New("rlpDecodeItem: truncated long-string payload")
		}
		return b[1+ll : 1+ll+l], 1 + ll + l, nil
	case prefix == 0xc0:
		return []byte{}, 1, nil
	case prefix >= 0xc1 && prefix <= 0xf7:
		// Non-empty list — for §4.3 we only expect the access-list
		// slot to be 0xc0 (empty). A non-empty list here is an
		// SPEC violation we surface as an error.
		return nil, 0, errors.New("rlpDecodeItem: nested list payload not supported in this scope")
	case prefix >= 0xf8 && prefix <= 0xff:
		return nil, 0, errors.New("rlpDecodeItem: nested long-list payload not supported in this scope")
	}
	return nil, 0, fmt.Errorf("rlpDecodeItem: unexpected prefix 0x%02x", prefix)
}

func rlpItemUint(b []byte) (uint64, error) {
	if len(b) > 8 {
		return 0, fmt.Errorf("rlpItemUint: value too large (%d bytes)", len(b))
	}
	var v uint64
	for _, by := range b {
		v = (v << 8) | uint64(by)
	}
	return v, nil
}

// ---- helpers ------------------------------------------------------------

func trimLeadingZeros(b []byte) []byte {
	i := 0
	for i < len(b) && b[i] == 0 {
		i++
	}
	return b[i:]
}

func bigEndianLen(v uint64) []byte {
	var buf [8]byte
	binaryBigEndianPutUint64(buf[:], v)
	return trimLeadingZeros(buf[:])
}

func bigEndianRead(b []byte) uint64 {
	var v uint64
	for _, by := range b {
		v = (v << 8) | uint64(by)
	}
	return v
}

func binaryBigEndianPutUint64(b []byte, v uint64) {
	b[0] = byte(v >> 56)
	b[1] = byte(v >> 48)
	b[2] = byte(v >> 40)
	b[3] = byte(v >> 32)
	b[4] = byte(v >> 24)
	b[5] = byte(v >> 16)
	b[6] = byte(v >> 8)
	b[7] = byte(v)
}

func prependEIP2718(typeByte byte, rlpEncoded []byte) []byte {
	out := make([]byte, 0, 1+len(rlpEncoded))
	out = append(out, typeByte)
	out = append(out, rlpEncoded...)
	return out
}

func mustHexBytes(s string) []byte {
	s = strings.TrimPrefix(s, "0x")
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(fmt.Sprintf("mustHexBytes: %v", err))
	}
	return b
}

// addressEqualFold compares two 0x-prefixed Ethereum addresses
// case-insensitively. Returns false on any decode error.
func addressEqualFold(a, b string) bool {
	an, errA := NormalizeAddress(a)
	bn, errB := NormalizeAddress(b)
	if errA != nil || errB != nil {
		return false
	}
	return an == bn
}

// bytesEqual is a thin wrapper used in tests + verification.
func bytesEqual(a, b []byte) bool {
	return bytes.Equal(a, b)
}
