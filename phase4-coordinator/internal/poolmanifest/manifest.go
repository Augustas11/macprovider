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
	"regexp"
	"sort"
)

// Domain-separation tags (SPEC-042-R001). Each core's canonical preimage begins
// with its tag so an identity-core digest can never collide with a policy-core
// digest or any other signed structure.
const (
	identityCoreTag = "macprovider/spec042/identity-core/v1"
	policyCoreTag   = "macprovider/spec042/policy-core/v1"
	// policyCoreTagV2 prefixes the SPEC-042-R001 v2 preimage (0.0.32, #1690):
	// the v1 field list, then runtime_allowlist, then extensions.
	policyCoreTagV2 = "macprovider/spec042/policy-core/v2"
)

// Policy-core encodings (SPEC-042-R001). The zero value is v1, so every core
// built before v2 existed keeps its bytes, digest, and signing tag.
const (
	PolicyCoreEncodingV1 uint8 = 1
	PolicyCoreEncodingV2 uint8 = 2
)

// The closed SPEC-042-R001 0.0.34 runtime_allowlist vocabulary: the SPEC-046
// loopback adapters with a serving selector and a SPEC-010 identity leg (GGUF
// for llama.cpp and Ollama, the MLX snapshot for mlx_lm.server). Native MLX
// (mlx_cache) is always allowed and is never listed.
const (
	RuntimeSourceLlamacppLoopback = "llamacpp_loopback"
	RuntimeSourceMLXLMLoopback    = "mlxlm_loopback"
	RuntimeSourceOllamaLoopback   = "ollama_loopback"
)

// extensionIDPattern is the SPEC-042-R001 extension_id grammar.
var extensionIDPattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,47}/v[1-9][0-9]{0,3}$`)

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

	errPolicyEncoding          = errors.New("poolmanifest: unknown policy core encoding")
	errV1CarriesV2Fields       = errors.New("poolmanifest: a v1 policy core cannot carry runtime_allowlist or extensions")
	errRuntimeAllowlistOrder   = errors.New("poolmanifest: runtime_allowlist must be byte-lexicographically ascending with no duplicates")
	errRuntimeAllowlistValue   = errors.New("poolmanifest: runtime_allowlist carries a runtime_source outside the closed vocabulary")
	errRuntimeAllowlistObserve = errors.New("poolmanifest: a non-empty runtime_allowlist requires settlement mode enforce")
	errExtensionGrammar        = errors.New("poolmanifest: extension_id does not match the SPEC-042-R001 grammar")
	errExtensionOrder          = errors.New("poolmanifest: extensions must be strictly ascending by extension_id with no duplicates")
	errExtensionUnknown        = errors.New("poolmanifest: extension_id is not implemented by this coordinator")
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
	// Encoding selects the canonical preimage: 0 or PolicyCoreEncodingV1 is
	// the frozen v1 grammar; PolicyCoreEncodingV2 appends RuntimeAllowlist and
	// Extensions (SPEC-042-R001 0.0.32). A v1 core means native MLX only.
	Encoding uint8
	// RuntimeAllowlist is the signed set of external runtime_source values a
	// v2 core authorizes to serve the pool. Empty means native MLX only.
	RuntimeAllowlist []string
	// Extensions is the reserved, versioned v2 extension field. No
	// extension_id is implemented yet, so an accepted core carries none.
	Extensions []PolicyExtension
}

// PolicyExtension is one entry of the v2 reserved extensions field.
type PolicyExtension struct {
	ID   string
	Body []byte
}

// IsV2 reports whether the core uses the v2 preimage.
func (pc PolicyCore) IsV2() bool { return pc.Encoding == PolicyCoreEncodingV2 }

// AllowsRuntimeSource reports whether the core authorizes an external runtime
// to serve the pool: only a v2 core whose runtime_allowlist names it. A v1
// core, an empty list, or an unlisted value is native MLX only.
func (pc PolicyCore) AllowsRuntimeSource(runtimeSource string) bool {
	if !pc.IsV2() || runtimeSource == "" {
		return false
	}
	for _, allowed := range pc.RuntimeAllowlist {
		if allowed == runtimeSource {
			return true
		}
	}
	return false
}

// ValidRuntimeAllowlistSource reports whether a runtime_source belongs to the
// closed SPEC-042-R001 0.0.34 runtime_allowlist vocabulary.
func ValidRuntimeAllowlistSource(runtimeSource string) bool {
	switch runtimeSource {
	case RuntimeSourceLlamacppLoopback, RuntimeSourceMLXLMLoopback, RuntimeSourceOllamaLoopback:
		return true
	default:
		return false
	}
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

// validateV2Grammar applies the SPEC-042-R001 v2 byte grammar: a strictly
// ascending runtime_allowlist and grammatical, strictly ascending extensions.
// A core that fails it has no canonical preimage.
func (pc PolicyCore) validateV2Grammar() error {
	for i, source := range pc.RuntimeAllowlist {
		if i > 0 && source <= pc.RuntimeAllowlist[i-1] {
			return errRuntimeAllowlistOrder
		}
	}
	for _, ext := range pc.Extensions {
		if !extensionIDPattern.MatchString(ext.ID) {
			return errExtensionGrammar
		}
	}
	for i := 1; i < len(pc.Extensions); i++ {
		if pc.Extensions[i].ID <= pc.Extensions[i-1].ID {
			return errExtensionOrder
		}
	}
	return nil
}

// ValidateAcceptance applies the SPEC-042-R001 0.0.32 acceptance rules on top
// of the grammar: the runtime_allowlist vocabulary is closed, a non-empty
// allowlist requires settlement mode enforce, and a coordinator rejects every
// extension_id it does not implement (0.0.32 implements none). Signature
// verification runs it, so no core that fails it is ever accepted or replayed.
func (pc PolicyCore) ValidateAcceptance() error {
	if _, err := pc.CanonicalBytes(); err != nil {
		return err
	}
	if !pc.IsV2() {
		return nil
	}
	for _, source := range pc.RuntimeAllowlist {
		if !ValidRuntimeAllowlistSource(source) {
			return errRuntimeAllowlistValue
		}
	}
	if len(pc.RuntimeAllowlist) > 0 && pc.SettlementMode != "enforce" {
		return errRuntimeAllowlistObserve
	}
	if len(pc.Extensions) > 0 {
		return errExtensionUnknown
	}
	return nil
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
	tag := policyCoreTag
	switch pc.Encoding {
	case 0, PolicyCoreEncodingV1:
		if len(pc.RuntimeAllowlist) > 0 || len(pc.Extensions) > 0 {
			return nil, errV1CarriesV2Fields
		}
	case PolicyCoreEncodingV2:
		if err := pc.validateV2Grammar(); err != nil {
			return nil, err
		}
		tag = policyCoreTagV2
	default:
		return nil, errPolicyEncoding
	}
	e := &encoder{}
	e.tag(tag)
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
	if pc.IsV2() {
		// runtime_allowlist then extensions, in this order (SPEC-042-R001).
		e.u32count(len(pc.RuntimeAllowlist))
		for _, source := range pc.RuntimeAllowlist {
			e.str(source)
		}
		e.u32count(len(pc.Extensions))
		for _, ext := range pc.Extensions {
			e.str(ext.ID)
			e.bytesf(ext.Body)
		}
	}
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
