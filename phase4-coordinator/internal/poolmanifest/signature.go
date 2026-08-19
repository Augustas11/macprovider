package poolmanifest

// SPEC-042-R001/R012 slice 2: signature verification over the canonical policy
// core. Slice 1 froze the encoding and the manifest_core_digest; this file makes
// that encoding trust-bearing by deciding whether a signed policy core is
// authentic (valid Ed25519 signatures), authorized (keys in the named signer
// set), and threshold-met (M distinct authorized signers).
//
// Scope boundary: verification takes a SignerSet as an INPUT. The append-only,
// hash-chained authority log that establishes and versions signer sets — and
// sets SignerSet.Revoked — is SPEC-042-R012 (slice 3). Stateful manifest rejects
// (manifest_version monotonicity, prev-hash chaining, rollback, active-policy
// selection, durable verdict records) need durable history and are slices 4-5.
// This file has no I/O, no persistence, and no wall-clock: every function is a
// total function of its inputs.

import (
	"crypto/ed25519"
	"crypto/subtle"
	"errors"
)

// policyCoreSigTag domain-separates a policy-core signature from the identity-core,
// authority-log-entry, and mutable-field signatures added by later slices, so a
// signature harvested from one structure can never be replayed as another. It is
// DISTINCT from the policyCoreTag (slice 1) that prefixes the digest preimage.
const policyCoreSigTag = "macprovider/spec042/policy-core-sig/v1"

var (
	errSignerSetEmpty    = errors.New("poolmanifest: signer set has no keys")
	errThresholdRange    = errors.New("poolmanifest: signer set threshold must satisfy 1 <= M <= N")
	errSignerKeyID       = errors.New("poolmanifest: signer set key id must be non-empty and distinct")
	errSignerKeyLen      = errors.New("poolmanifest: signer set public key must be ed25519.PublicKeySize bytes")
	errSignerKeyDup      = errors.New("poolmanifest: signer set public keys must be distinct")
	errSignerSetWindow   = errors.New("poolmanifest: signer set validity window must satisfy not_before < expires")
	errSignerSetVersion  = errors.New("poolmanifest: policy core signer_set_version does not match signer set")
	errSignerSetRevoked  = errors.New("poolmanifest: signer set is revoked")
	errSignerSetInactive = errors.New("poolmanifest: signer set window does not contain policy not_before")
	errDuplicateSigner   = errors.New("poolmanifest: duplicate signer key id in signature list")
	errUnknownSigner     = errors.New("poolmanifest: signature key id not in signer set")
	errBadSignature      = errors.New("poolmanifest: invalid signature")
	errThresholdNotMet   = errors.New("poolmanifest: fewer authorized signatures than threshold")
	errPoolIDMismatch    = errors.New("poolmanifest: pool_id does not match recomputed identity-core digest")
	errDigestLen         = errors.New("poolmanifest: manifest_core_digest must be 32 bytes")
)

// Signature is a detached Ed25519 signature by one signer key over a
// domain-separated policy-core signing message (SPEC-042-R012). Alg is fixed
// Ed25519 (the network signature algorithm; see internal/tier2 catalog
// signatures). On the wire KeyID and Sig are base64url per the catalog precedent;
// this in-memory form carries the decoded signature bytes.
type Signature struct {
	KeyID string
	Sig   []byte
}

// SignerKey is one authorized operational signer: an opaque key id and its
// Ed25519 public key.
type SignerKey struct {
	KeyID     string
	PublicKey ed25519.PublicKey
}

// SignerSet is the M-of-N operational signer set a policy core is verified
// against (SPEC-042-R012), the INPUT to verification. Slice 3's authority log
// constructs it (and is the only writer of Revoked); slice 2 only consumes it.
type SignerSet struct {
	Version       uint64
	Keys          []SignerKey
	Threshold     uint32 // M
	NotBeforeUnix uint64 // validity window [NotBeforeUnix, ExpiresAtUnix)
	ExpiresAtUnix uint64
	Revoked       bool
}

// Validate checks the signer set is structurally well-formed: N = len(Keys) >= 1,
// 1 <= Threshold <= N, distinct non-empty key ids, each public key exactly
// ed25519.PublicKeySize bytes, DISTINCT public-key bytes, and a non-empty
// half-open validity window. It does NOT consult the clock or any policy; window
// applicability is evaluated per policy in VerifyPolicyCore.
//
// Distinct public-key bytes are load-bearing for true M-of-N independence: because
// verifyThreshold dedupes signatures by key id, a signer set carrying the same
// public key under two key ids would let the holder of a single private key submit
// the same valid signature under both ids and satisfy a 2-of-N threshold with one
// key. Rejecting duplicate public keys here (the trust-primitive boundary) closes
// that collapse regardless of how the slice-3 authority log constructs the set.
func (ss SignerSet) Validate() error {
	n := len(ss.Keys)
	if n == 0 {
		return errSignerSetEmpty
	}
	if ss.Threshold < 1 || int(ss.Threshold) > n {
		return errThresholdRange
	}
	seenIDs := make(map[string]struct{}, n)
	seenKeys := make(map[string]struct{}, n)
	for _, k := range ss.Keys {
		if k.KeyID == "" {
			return errSignerKeyID
		}
		if _, dup := seenIDs[k.KeyID]; dup {
			return errSignerKeyID
		}
		seenIDs[k.KeyID] = struct{}{}
		if len(k.PublicKey) != ed25519.PublicKeySize {
			return errSignerKeyLen
		}
		if _, dup := seenKeys[string(k.PublicKey)]; dup {
			return errSignerKeyDup
		}
		seenKeys[string(k.PublicKey)] = struct{}{}
	}
	if ss.NotBeforeUnix >= ss.ExpiresAtUnix {
		return errSignerSetWindow
	}
	return nil
}

// keyByID returns the public key for id, or ok=false if id is not in the set.
func (ss SignerSet) keyByID(id string) (ed25519.PublicKey, bool) {
	for _, k := range ss.Keys {
		if k.KeyID == id {
			return k.PublicKey, true
		}
	}
	return nil, false
}

// PolicyCoreSigningMessage returns the domain-separated message a signer signs
// for a policy core: policyCoreSigTag ‖ manifest_core_digest. manifestCoreDigest
// must be the 32-byte SHA-256 policy-core digest from ManifestCoreDigest.
func PolicyCoreSigningMessage(manifestCoreDigest []byte) ([]byte, error) {
	if len(manifestCoreDigest) != manifestCoreHashLen {
		return nil, errDigestLen
	}
	msg := make([]byte, 0, len(policyCoreSigTag)+manifestCoreHashLen)
	msg = append(msg, policyCoreSigTag...)
	msg = append(msg, manifestCoreDigest...)
	return msg, nil
}

// VerifyPolicyCore accepts iff the policy core is authentic, authorized under the
// named signer set, and threshold-met (SPEC-042-R001/R012). It returns a distinct
// typed sentinel on every reject and nil only on full acceptance. There is no
// partial acceptance: every listed signature MUST be authorized, valid, and
// distinct, and the count MUST reach the threshold.
func VerifyPolicyCore(core PolicyCore, sigs []Signature, ss SignerSet) error {
	if err := ss.Validate(); err != nil {
		return err
	}
	// The policy core is verified against EXACTLY the signer set it names.
	if ss.Version != core.SignerSetVersion {
		return errSignerSetVersion
	}
	// Acceptance validity is anchored to the policy's not_before, never to
	// manifest_version (SPEC-042-R012): the signer set must be unrevoked and its
	// half-open window must contain core.NotBeforeUnix.
	if ss.Revoked {
		return errSignerSetRevoked
	}
	if !(ss.NotBeforeUnix <= core.NotBeforeUnix && core.NotBeforeUnix < ss.ExpiresAtUnix) {
		return errSignerSetInactive
	}
	// Recompute the digest (also runs slice-1 structural validation of the core).
	digest, err := core.ManifestCoreDigest()
	if err != nil {
		return err
	}
	return verifyThreshold(digest, sigs, ss)
}

// verifyThreshold enforces M-of-N over distinct authorized valid signatures. The
// signature list must be clean: each entry authorized (key id in the set),
// cryptographically valid over the policy-core signing message, and distinct by
// key id; then len(sigs) >= Threshold. This makes M-of-N mean "M distinct
// authorized keys signed the same digest", never M signatures from one key nor M
// good signatures padded with garbage. ss is assumed already Validate()d.
func verifyThreshold(manifestCoreDigest []byte, sigs []Signature, ss SignerSet) error {
	msg, err := PolicyCoreSigningMessage(manifestCoreDigest)
	if err != nil {
		return err
	}
	seen := make(map[string]struct{}, len(sigs))
	for _, s := range sigs {
		if _, dup := seen[s.KeyID]; dup {
			return errDuplicateSigner
		}
		seen[s.KeyID] = struct{}{}
		pub, ok := ss.keyByID(s.KeyID)
		if !ok {
			return errUnknownSigner
		}
		if len(s.Sig) != ed25519.SignatureSize {
			return errBadSignature
		}
		if !ed25519.Verify(pub, msg, s.Sig) {
			return errBadSignature
		}
	}
	if len(sigs) < int(ss.Threshold) {
		return errThresholdNotMet
	}
	return nil
}

// VerifyPoolIDBinding recomputes the identity-core-derived pool_id and rejects on
// mismatch against the pool_id carried alongside the manifest (SPEC-042-R001).
// pool_id is a self-certifying name (a hash of the identity core), not an
// authorization; authorization flows only from policy-core signatures verified
// against a signer set. The compare is constant-time for hygiene though pool_id
// is public.
func VerifyPoolIDBinding(ic IdentityCore, claimedPoolID string) error {
	got, err := ic.PoolID()
	if err != nil {
		return err
	}
	if subtle.ConstantTimeCompare([]byte(got), []byte(claimedPoolID)) != 1 {
		return errPoolIDMismatch
	}
	return nil
}
