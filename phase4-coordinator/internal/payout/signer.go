package payout

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"os"
	"time"

	"github.com/decred/dcrd/dcrec/secp256k1/v4"
	ecdsa "github.com/decred/dcrd/dcrec/secp256k1/v4/ecdsa"
	"golang.org/x/crypto/sha3"
)

// SPEC-016 §6.3 + §6.3.1 — package-internal Signer interface.
//
// The Signer interface is intentionally minimal: ONE method that
// signs an unsigned EIP-1559 envelope and returns the signed
// envelope + tx hash. No SignMessage primitive (footgun per
// v0.1.3 carve-out — would let a future code path sign anything
// with the hot-wallet key).
//
// The v0.1.x local-file implementation lives below; the v0.2 KMS
// substitution will implement this exact interface without
// changing the §4.3 step 6 sequence.

// Signer is the §6.3.1 interface contract.
type Signer interface {
	// FromAddress returns the EIP-55-checksummed Ethereum
	// address of the signing key. MUST return the same value
	// for the signer's lifetime.
	FromAddress() string

	// SignTx signs an unsigned EIP-1559 transaction envelope
	// and returns (rawSignedTx, txHash). MUST NOT broadcast.
	//
	// unsignedTxBytes format: EIP-2718 type-prefixed RLP-
	// encoded unsigned EIP-1559 transaction (txType 0x02) with
	// empty signature fields (V, R, S = 0). The exact bytes
	// produced by EIP1559Tx.UnsignedRLP() — caller does NOT
	// pre-hash; the Signer keccak256s the input internally.
	//
	// For the same input bytes called twice, the implementation
	// SHOULD return identical output bytes (deterministic ECDSA
	// via RFC 6979) but SPEC-016 does NOT depend on determinism
	// for idempotency — the chain-level nonce + raw_signed_tx
	// persistence in §4.3 step 6 is the actual guarantee.
	//
	// ctx supports cancellation; KMS implementations MAY block
	// on a network call; local-file implementations MUST NOT
	// block longer than 100ms.
	SignTx(ctx context.Context, unsignedTxBytes []byte) (rawSignedTx []byte, txHash string, err error)
}

// ErrSignerUnavailable is the typed-error sentinel for "wrong
// chain id", "key unavailable", "policy refused (KMS)" — fatal
// from the runner's perspective; emits
// `payout_signer_unavailable` per §7.1.
var ErrSignerUnavailable = errors.New("payout: signer unavailable")

// LocalFileSigner is the v0.1.x reference implementation:
// AES-256-GCM-encrypted secp256k1 private key on disk, decrypted
// in process memory at construction using the operator-supplied
// KEK.
//
// SPEC §6.3 hardening expected at process startup (mlockall,
// setrlimit, prctl) runs in the Linux-only setup path; the
// signer itself does not enforce those. See topology.go for the
// Linux-required hook.
type LocalFileSigner struct {
	privKey *secp256k1.PrivateKey
	address string // EIP-55 canonical
}

// EncryptedWalletFile is the v0.1.x on-disk wallet format. The
// nonce + ciphertext bind together so a partial-file write
// produces a decrypt failure rather than a silent corrupt-key
// fail-open.
//
// File layout (hex on disk, decoded to bytes):
//
//	0:12   12-byte AES-GCM nonce
//	12:end ciphertext (includes 16-byte GCM tag at end)
//
// Plaintext after decrypt: 32-byte secp256k1 private key.
type EncryptedWalletFile struct {
	Path      string
	OnDiskHex bool // true if file content is hex-encoded; false if raw bytes
}

// LoadLocalFileSigner decrypts the wallet file at path using the
// supplied KEK and returns a LocalFileSigner whose private key
// is held only in process memory. The KEK MUST be 32 bytes (256
// bits) — shorter keys are rejected fail-loud per §6.3.
//
// SPEC §6.3 path:
//   - systemd LoadCredential= (preferred): KEK is in
//     CREDENTIALS_DIRECTORY/<name> — caller resolves and passes
//     the 32 bytes here.
//   - env var MACPROVIDER_PAYOUT_WALLET_KEK: only when systemd
//     LoadCredential= is not available; caller passes the hex-
//     decoded value.
//
// The KEK plaintext is NEVER written to disk by this function
// nor logged. The decrypted private key is held in
// LocalFileSigner.privKey until process exit; release happens
// implicitly via GC (Go does not expose secure memory zeroization
// at v0.1.x — Step 4 / v0.2 may add a SecretBox-style wrapper).
func LoadLocalFileSigner(wallet EncryptedWalletFile, kek []byte) (*LocalFileSigner, error) {
	if len(kek) != 32 {
		return nil, fmt.Errorf("LoadLocalFileSigner: KEK must be 32 bytes (got %d)", len(kek))
	}
	raw, err := os.ReadFile(wallet.Path)
	if err != nil {
		return nil, fmt.Errorf("LoadLocalFileSigner: read wallet file: %w", err)
	}
	if wallet.OnDiskHex {
		raw, err = hex.DecodeString(string(raw))
		if err != nil {
			return nil, fmt.Errorf("LoadLocalFileSigner: hex-decode wallet file: %w", err)
		}
	}
	if len(raw) < 12+16+1 {
		return nil, errors.New("LoadLocalFileSigner: wallet file too short to contain nonce + GCM tag + key")
	}
	nonce := raw[:12]
	ct := raw[12:]
	block, err := aes.NewCipher(kek)
	if err != nil {
		return nil, fmt.Errorf("LoadLocalFileSigner: aes.NewCipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("LoadLocalFileSigner: cipher.NewGCM: %w", err)
	}
	pt, err := gcm.Open(nil, nonce, ct, nil)
	if err != nil {
		// Note: do NOT echo decrypt-failure details — could
		// leak whether the KEK is close-to-correct.
		return nil, errors.New("LoadLocalFileSigner: wallet decrypt failed")
	}
	// FULL-r1 [full-sec:r1-2] LOW closure: zeroize via defer so
	// the malformed-length error path also wipes decrypted bytes.
	// Defensive: the secp256k1 PrivateKey allocates its own copy
	// of the key material, so wiping pt after construction is safe.
	defer func() {
		for i := range pt {
			pt[i] = 0
		}
	}()
	if len(pt) != 32 {
		return nil, fmt.Errorf("LoadLocalFileSigner: decrypted key length = %d, want 32", len(pt))
	}
	if err := validatePrivateKeyScalar(pt); err != nil {
		return nil, fmt.Errorf("LoadLocalFileSigner: %w", err)
	}
	priv := secp256k1.PrivKeyFromBytes(pt)
	address, err := deriveEthereumAddress(priv.PubKey())
	if err != nil {
		return nil, fmt.Errorf("LoadLocalFileSigner: derive address: %w", err)
	}
	return &LocalFileSigner{privKey: priv, address: address}, nil
}

// NewLocalFileSignerFromKey is a test-only constructor that
// accepts a raw 32-byte private key directly. Production paths
// MUST go through LoadLocalFileSigner. Marked as such by the
// caller-required argument shape; the runner refuses to wire a
// signer that bypassed the file path (audit hook in main.go).
func NewLocalFileSignerFromKey(privKeyBytes []byte) (*LocalFileSigner, error) {
	if len(privKeyBytes) != 32 {
		return nil, fmt.Errorf("NewLocalFileSignerFromKey: privKey must be 32 bytes (got %d)", len(privKeyBytes))
	}
	priv := secp256k1.PrivKeyFromBytes(privKeyBytes)
	address, err := deriveEthereumAddress(priv.PubKey())
	if err != nil {
		return nil, err
	}
	return &LocalFileSigner{privKey: priv, address: address}, nil
}

// FromAddress satisfies the §6.3.1 contract.
func (s *LocalFileSigner) FromAddress() string {
	return s.address
}

// SignTx satisfies the §6.3.1 contract. The 100ms latency bound
// is enforced via a context-deadline wrapper — the signer is
// purely-CPU so a real-world local-file sign is microseconds; the
// bound exists so a future regression that introduces I/O (e.g.
// HSM proxy) fails-loud rather than silently slowing the runner.
//
// Error semantics per §6.3.1:
//   - nil err REQUIRES non-nil rawSignedTx AND non-empty txHash
//   - ctx.Err() returns as transient error
//   - Wrong chain id / key unavailable wrap ErrSignerUnavailable
//
// The signer does NOT log, print, or return the key bytes in any
// error path — call sites that wrap errors MUST NOT include
// `s.privKey` in the wrapped value (regression-test target).
func (s *LocalFileSigner) SignTx(ctx context.Context, unsignedTxBytes []byte) ([]byte, string, error) {
	if ctx.Err() != nil {
		return nil, "", ctx.Err()
	}
	// 100ms self-imposed deadline (§6.3.1).
	deadline := time.Now().Add(100 * time.Millisecond)

	// Decode the unsigned envelope to re-extract the fields we
	// need to re-emit the signed form. SPEC §6.3.1 says the
	// caller's input is the EIP-2718 type-prefixed RLP unsigned
	// tx — we keccak256 it ourselves (KMS implementations would
	// do the same).
	if len(unsignedTxBytes) < 2 || unsignedTxBytes[0] != 0x02 {
		return nil, "", fmt.Errorf("%w: unsigned bytes not type 0x02", ErrSignerUnavailable)
	}
	// Strict chain-id check: parse the chainId out of the
	// unsigned envelope and reject anything other than Base
	// mainnet 8453. The chain-id slot is the first RLP item
	// inside the list body. A KMS implementation would have a
	// policy that allowlists chainIds; the local-file signer
	// pins to Base.
	body := unsignedTxBytes[1:]
	items, _, err := rlpDecodeList(body)
	if err != nil {
		return nil, "", fmt.Errorf("%w: rlp decode: %v", ErrSignerUnavailable, err)
	}
	if len(items) < 1 {
		return nil, "", fmt.Errorf("%w: empty rlp list", ErrSignerUnavailable)
	}
	chainID, err := rlpItemUint(items[0])
	if err != nil {
		return nil, "", fmt.Errorf("%w: chain_id: %v", ErrSignerUnavailable, err)
	}
	if chainID != BaseMainnetChainID {
		return nil, "", fmt.Errorf("%w: chain_id %d, want %d", ErrSignerUnavailable, chainID, BaseMainnetChainID)
	}

	// Hash the EIP-2718 envelope for signing.
	h := sha3.NewLegacyKeccak256()
	_, _ = h.Write(unsignedTxBytes)
	digest := h.Sum(nil)

	// Sign.
	compact := ecdsa.SignCompact(s.privKey, digest, false)
	// compact[0] = 27 + y_parity for uncompressed-pubkey case.
	yParity := compact[0] - 27
	rBytes := compact[1:33]
	sBytes := compact[33:65]

	// Re-decode the unsigned tx into struct form so we can emit
	// the signed RLP. This intentionally bypasses constructor
	// validation because the unsigned bytes already represent a
	// validated tx (constructor validated before UnsignedRLP).
	tx, err := decodeUnsignedForSigning(items)
	if err != nil {
		return nil, "", fmt.Errorf("%w: rebuild tx: %v", ErrSignerUnavailable, err)
	}
	signedBytes, err := tx.SignedRLP(yParity, rBytes, sBytes)
	if err != nil {
		return nil, "", fmt.Errorf("%w: re-encode signed: %v", ErrSignerUnavailable, err)
	}
	txHash := TxHash(signedBytes)

	// Deadline check post-work — fail-loud if we crossed 100ms
	// (the signer is CPU-bound; crossing the bound is a sign of
	// pathological GC or instrumentation overhead).
	if time.Now().After(deadline) {
		return nil, "", fmt.Errorf("%w: sign exceeded 100ms local-file deadline", ErrSignerUnavailable)
	}
	return signedBytes, txHash, nil
}

// deriveEthereumAddress computes the EIP-55 checksummed address
// of a secp256k1 public key per the standard derivation:
// keccak256(uncompressed_pubkey_X||Y)[12:].
func deriveEthereumAddress(pub *secp256k1.PublicKey) (string, error) {
	uncompressed := pub.SerializeUncompressed()
	if len(uncompressed) != 65 || uncompressed[0] != 0x04 {
		return "", errors.New("deriveEthereumAddress: pubkey not in uncompressed form")
	}
	h := sha3.NewLegacyKeccak256()
	_, _ = h.Write(uncompressed[1:])
	d := h.Sum(nil)
	lower := "0x" + hex.EncodeToString(d[len(d)-20:])
	return CanonicalizeEIP55(lower)
}

// decodeUnsignedForSigning extracts the EIP1559Tx fields from the
// already-RLP-decoded items[]. Used only by SignTx after the
// caller-supplied unsigned envelope has been validated as having
// the right shape.
func decodeUnsignedForSigning(items [][]byte) (EIP1559Tx, error) {
	if len(items) != 12 {
		return EIP1559Tx{}, fmt.Errorf("decodeUnsignedForSigning: expected 12 fields, got %d", len(items))
	}
	chainID, err := rlpItemUint(items[0])
	if err != nil {
		return EIP1559Tx{}, fmt.Errorf("chain_id: %w", err)
	}
	nonce, err := rlpItemUint(items[1])
	if err != nil {
		return EIP1559Tx{}, fmt.Errorf("nonce: %w", err)
	}
	gasLimit, err := rlpItemUint(items[4])
	if err != nil {
		return EIP1559Tx{}, fmt.Errorf("gas_limit: %w", err)
	}
	if len(items[5]) != 20 {
		return EIP1559Tx{}, fmt.Errorf("to: must be 20 bytes")
	}
	var to [20]byte
	copy(to[:], items[5])
	return EIP1559Tx{
		ChainID:              chainID,
		Nonce:                nonce,
		MaxPriorityFeePerGas: newBigIntFromBytes(items[2]),
		MaxFeePerGas:         newBigIntFromBytes(items[3]),
		GasLimit:             gasLimit,
		To:                   to,
		Value:                newBigIntFromBytes(items[6]),
		Data:                 cloneBytes(items[7]),
	}, nil
}

func newBigIntFromBytes(b []byte) *big.Int {
	return new(big.Int).SetBytes(b)
}

func cloneBytes(b []byte) []byte {
	out := make([]byte, len(b))
	copy(out, b)
	return out
}
