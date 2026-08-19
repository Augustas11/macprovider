// Package poolmanifest implements the SPEC-042-R001 canonical byte grammar for
// the pool manifest's identity core and versioned policy core, and the two
// derivations that hang off them: pool_id and manifest_core_digest.
//
// This is the foundation of the R001 manifest epic (slice 1). It provides
// deterministic, domain-separated, length-prefixed encoding — mirroring the
// SPEC-041-R002 framing precedent (unsigned 32-bit big-endian length prefixes;
// sorted, individually length-prefixed list elements; unsigned 64-bit
// big-endian integers) — and NOTHING ELSE: no signatures, no authority log
// (R012), no active-policy selection, no persistence, no routing wiring. Those
// are later slices. The golden vectors in the test file freeze this wire format.
package poolmanifest

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"sort"
)

// Domain-separation tags (SPEC-042-R001). Each core's canonical preimage begins
// with its tag so an identity-core digest can never collide with a policy-core
// digest or any other signed structure.
const (
	identityCoreTag = "macprovider/spec042/identity-core/v1"
	policyCoreTag   = "macprovider/spec042/policy-core/v1"
)

// manifestCoreHashLen is the fixed length of prev_manifest_core_hash and of
// manifest_core_digest (SHA-256).
const manifestCoreHashLen = 32

// poolIDTruncBytes is the 128-bit truncation of the identity-core digest that
// forms pool_id (SPEC-042-R001).
const poolIDTruncBytes = 16

var (
	errFieldTooLong     = errors.New("poolmanifest: field exceeds 2^32-1 bytes")
	errPrevHashLen      = fmt.Errorf("poolmanifest: prev_manifest_core_hash must be %d bytes", manifestCoreHashLen)
	errDuplicateAllowed = errors.New("poolmanifest: duplicate model allowlist entry")
)

// IdentityCore fixes the stable pool identity (SPEC-042-R001). It contains ONLY
// identity-genesis fields; it MUST NOT carry pool_id, manifest_version, any
// version-chaining hash, the signer set, or any versioned policy field.
type IdentityCore struct {
	RootIssuerKeyID string
	GenesisNonce    []byte
}

// PolicyCore carries the trust contract for one manifest_version
// (SPEC-042-R001). pool_id is a reference (derived from the identity core), but
// it is bound into this preimage so a signed policy core is non-transferable to
// another pool.
type PolicyCore struct {
	PoolID               string
	ManifestVersion      uint64
	PrevManifestCoreHash []byte // 32 bytes; genesis is 32 zero bytes
	SignerSetVersion     uint64
	ModelAllowlist       []string
	MinBinaryVersion     string
	MinAttestationTier   string
	RequireEncryptedLeg  bool
	SettlementMode       string
	RevenueSplitBps      uint64
	SplitExecutionStatus string
	RetentionPolicyID    string
	MinEligibleMembers   uint64
	// Layer 3 compatibility fields (SPEC-042-R009), forward-declared so the
	// later Layer-3 amendment is additive rather than a breaking re-encode.
	// v0.1 is Layer 2: PrivacyMode MUST be "none" and the rest are inert
	// defaults; the coordinator fails closed on a non-default PrivacyMode.
	PrivacyMode          string // "none" in v0.1
	RelayBlindCapable    bool
	ReceiptContract      string
	MetadataVisible      string
	DowngradePolicy      string
	StickyRoutingAllowed bool // default false for trust-sensitive pools
	NotBeforeUnix        uint64
	ExpiresAtUnix        uint64
}

// GenesisPrevHash returns the defined genesis value for prev_manifest_core_hash:
// 32 zero bytes (SPEC-042-R001).
func GenesisPrevHash() []byte { return make([]byte, manifestCoreHashLen) }

// encoder accumulates the canonical length-prefixed byte grammar.
type encoder struct {
	buf []byte
	err error
}

func (e *encoder) tag(s string) { e.buf = append(e.buf, s...) } // raw, fixed leading discriminator
func (e *encoder) u64(n uint64) {
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], n)
	e.buf = append(e.buf, b[:]...)
}
func (e *encoder) boolean(x bool) {
	if x {
		e.buf = append(e.buf, 0x01)
	} else {
		e.buf = append(e.buf, 0x00)
	}
}

func (e *encoder) lenPrefixed(b []byte) {
	if e.err != nil {
		return
	}
	if uint64(len(b)) > uint64(^uint32(0)) {
		e.err = errFieldTooLong
		return
	}
	var p [4]byte
	binary.BigEndian.PutUint32(p[:], uint32(len(b)))
	e.buf = append(e.buf, p[:]...)
	e.buf = append(e.buf, b...)
}

func (e *encoder) str(s string)    { e.lenPrefixed([]byte(s)) }
func (e *encoder) bytesf(b []byte) { e.lenPrefixed(b) }

// CanonicalBytes returns the SPEC-042-R001 identity-core preimage.
func (ic IdentityCore) CanonicalBytes() ([]byte, error) {
	e := &encoder{}
	e.tag(identityCoreTag)
	e.str(ic.RootIssuerKeyID)
	e.bytesf(ic.GenesisNonce)
	if e.err != nil {
		return nil, e.err
	}
	return e.buf, nil
}

// PoolID derives base64url(SHA256(canonical identity core)[0:16]) — the stable,
// non-capability pool identifier (SPEC-042-R001). Unpadded base64url.
func (ic IdentityCore) PoolID() (string, error) {
	b, err := ic.CanonicalBytes()
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(b)
	return base64.RawURLEncoding.EncodeToString(sum[:poolIDTruncBytes]), nil
}

// setOrdered returns a byte-lexicographically ascending copy of xs and errors on
// a duplicate (set-like list normalization, SPEC-042-R001).
func setOrdered(xs []string) ([]string, error) {
	out := append([]string(nil), xs...)
	sort.Strings(out)
	for i := 1; i < len(out); i++ {
		if out[i] == out[i-1] {
			return nil, errDuplicateAllowed
		}
	}
	return out, nil
}

// CanonicalBytes returns the SPEC-042-R001 versioned policy-core preimage.
func (pc PolicyCore) CanonicalBytes() ([]byte, error) {
	if len(pc.PrevManifestCoreHash) != manifestCoreHashLen {
		return nil, errPrevHashLen
	}
	allow, err := setOrdered(pc.ModelAllowlist)
	if err != nil {
		return nil, err
	}
	e := &encoder{}
	e.tag(policyCoreTag)
	e.str(pc.PoolID)
	e.u64(pc.ManifestVersion)
	e.bytesf(pc.PrevManifestCoreHash)
	e.u64(pc.SignerSetVersion)
	// list(model_allowlist): count then each element length-prefixed, set-ordered.
	if uint64(len(allow)) > uint64(^uint32(0)) {
		return nil, errFieldTooLong
	}
	var count [4]byte
	binary.BigEndian.PutUint32(count[:], uint32(len(allow)))
	e.buf = append(e.buf, count[:]...)
	for _, m := range allow {
		e.str(m)
	}
	e.str(pc.MinBinaryVersion)
	e.str(pc.MinAttestationTier)
	e.boolean(pc.RequireEncryptedLeg)
	e.str(pc.SettlementMode)
	e.u64(pc.RevenueSplitBps)
	e.str(pc.SplitExecutionStatus)
	e.str(pc.RetentionPolicyID)
	e.u64(pc.MinEligibleMembers)
	// SPEC-042-R009 Layer 3 compatibility field group, in R009's declared order.
	e.str(pc.PrivacyMode)
	e.boolean(pc.RelayBlindCapable)
	e.str(pc.ReceiptContract)
	e.str(pc.MetadataVisible)
	e.str(pc.DowngradePolicy)
	e.boolean(pc.StickyRoutingAllowed)
	e.u64(pc.NotBeforeUnix)
	e.u64(pc.ExpiresAtUnix)
	if e.err != nil {
		return nil, e.err
	}
	return e.buf, nil
}

// ManifestCoreDigest returns SHA256(canonical policy core) — the pool policy
// hash (SPEC-042-R001), 32 bytes.
func (pc PolicyCore) ManifestCoreDigest() ([]byte, error) {
	b, err := pc.CanonicalBytes()
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(b)
	return sum[:], nil
}
