package poolmanifest

// SPEC-042-R011/R012 slice 5: durable persistence + verdict-replay reconstruction.
// Slices 1-4 are pure crypto/logic over in-memory inputs; this file makes a pool's
// manifest state survivable across restart/failover. It provides a reversible
// canonical snapshot codec (a `decoder` mirroring the slice-1 `encoder`) and a
// reconstruction that rebuilds the authority log (slice 3) and policy-core history
// (slice 4) from durable records, REPLAYING the recorded acceptance verdicts rather
// than re-evaluating time-dependent validity against the current wall-clock.
//
// The load-bearing property (R012): a policy accepted under a signer set that is
// LATER revoked must stay accepted across a restart. The online build rejects a
// policy under a revoked signer set; reconstruction instead re-verifies only the
// timeless M-of-N signature and honors the recorded verdict.
//
// Scope boundary: pure. This defines WHAT is persisted and HOW it is replayed, not
// WHERE the bytes live — wiring into the coordinator's durable store (schema, the
// record-on-acceptance write path, the read-at-boot path) is the enable path.

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
)

const manifestSnapshotTag = "macprovider/spec042/manifest-snapshot/v1"

// maxSnapshotElements caps any single length-prefixed list in a snapshot. It is far
// above any realistic pool (authority-log entries, accepted policies, signers, or
// signatures) yet bounds a malformed durable blob from claiming a pathological count
// during restart/failover reconstruction.
const maxSnapshotElements = 1 << 20

var (
	errSnapshotTruncated = errors.New("poolmanifest: manifest snapshot is truncated")
	errSnapshotTrailing  = errors.New("poolmanifest: manifest snapshot has trailing bytes")
	errSnapshotTag       = errors.New("poolmanifest: manifest snapshot domain tag mismatch")
	errSnapshotTooLarge  = errors.New("poolmanifest: manifest snapshot list count exceeds bound")
)

// AcceptedPolicyRecord is a durably-recorded acceptance verdict (SPEC-042-R012): a
// signed policy core plus the epoch at which its acceptance was recorded as final.
type AcceptedPolicyRecord struct {
	SignedCore     SignedPolicyCore
	AcceptedAtUnix uint64
}

// ManifestSnapshot is the durable manifest state for one pool: the identity core,
// the root issuer key, the authority-log entries (chain order), and the accepted
// policy records (ascending manifest_version). It is coordinator-internal storage,
// not a signed wire object; its integrity comes from the trusted store plus the
// timeless re-verification performed by ReconstructPool.
type ManifestSnapshot struct {
	IdentityCore  IdentityCore
	RootIssuerKey SignerKey
	AuthorityLog  []AuthorityLogEntry
	Policies      []AcceptedPolicyRecord
}

// ReconstructedPool is the in-memory pool manifest state rebuilt from a snapshot.
type ReconstructedPool struct {
	AuthorityLog  *AuthorityLog
	PolicyHistory *PolicyHistory
}

// decoder is the strict, bounds-checked inverse of encoder. Every read checks
// bounds and sets err on overrun; once err is set all further reads are no-ops so a
// truncated input surfaces as a single error rather than a panic.
type decoder struct {
	buf []byte
	pos int
	err error
}

func (d *decoder) fail(err error) {
	if d.err == nil {
		d.err = err
	}
}

func (d *decoder) take(n int) []byte {
	if d.err != nil {
		return nil
	}
	if n < 0 || d.pos+n > len(d.buf) {
		d.fail(errSnapshotTruncated)
		return nil
	}
	b := d.buf[d.pos : d.pos+n]
	d.pos += n
	return b
}

func (d *decoder) u32() uint32 {
	b := d.take(4)
	if b == nil {
		return 0
	}
	return binary.BigEndian.Uint32(b)
}

func (d *decoder) u64() uint64 {
	b := d.take(8)
	if b == nil {
		return 0
	}
	return binary.BigEndian.Uint64(b)
}

func (d *decoder) boolean() bool {
	b := d.take(1)
	if b == nil {
		return false
	}
	if b[0] != 0x00 && b[0] != 0x01 {
		d.fail(errSnapshotTruncated)
		return false
	}
	return b[0] == 0x01
}

// lenPrefixed reads a u32 length then that many bytes, returning a fresh copy so the
// decoded value never aliases the input buffer.
func (d *decoder) lenPrefixed() []byte {
	n := d.u32()
	b := d.take(int(n))
	if b == nil {
		return nil
	}
	out := make([]byte, len(b))
	copy(out, b)
	return out
}

func (d *decoder) str() string { return string(d.lenPrefixed()) }

// expectTag consumes and verifies the fixed leading domain tag.
func (d *decoder) expectTag(tag string) {
	b := d.take(len(tag))
	if b == nil {
		return
	}
	if string(b) != tag {
		d.fail(errSnapshotTag)
	}
}

// count reads a u32 element count and rejects any count that exceeds
// maxSnapshotElements or that cannot fit even one byte per element in the remaining
// buffer. It is only a cheap upfront sanity bound: the decode loops append elements
// as they are actually decoded (breaking on the first read error), so total
// allocation tracks real decoded content, never the claimed count times the in-memory
// element size — a malformed blob cannot force an oversized allocation.
func (d *decoder) count() int {
	n := d.u32()
	if d.err != nil {
		return 0
	}
	if n > maxSnapshotElements {
		d.fail(errSnapshotTooLarge)
		return 0
	}
	if int64(n) > int64(len(d.buf)-d.pos) {
		d.fail(errSnapshotTruncated)
		return 0
	}
	return int(n)
}

func (d *decoder) done() error {
	if d.err != nil {
		return d.err
	}
	if d.pos != len(d.buf) {
		return errSnapshotTrailing
	}
	return nil
}

// --- encoders (reversible; preserve field order, do NOT sort/dedup) ---

func encodeSigner(e *encoder, k SignerKey) {
	e.str(k.KeyID)
	e.bytesf(k.PublicKey)
}

func encodeSignatures(e *encoder, sigs []Signature) {
	e.u32count(len(sigs))
	for _, s := range sigs {
		e.str(s.KeyID)
		e.bytesf(s.Sig)
	}
}

func encodeAuthEntry(e *encoder, a AuthorityLogEntry) {
	e.str(a.PoolID)
	e.u64(a.SignerSetVersion)
	e.bytesf(a.PrevAuthorityLogEntryHash)
	e.u32count(len(a.Keys))
	for _, k := range a.Keys {
		encodeSigner(e, k)
	}
	e.u64(uint64(a.Threshold))
	e.u64(a.NotBeforeUnix)
	e.u64(a.ExpiresAtUnix)
	e.u32count(len(a.RevokesVersions))
	for _, v := range a.RevokesVersions {
		e.u64(v)
	}
	e.u64(a.AuthorizingSignerSetVersion)
	encodeSignatures(e, a.Signatures)
}

func encodePolicyCore(e *encoder, pc PolicyCore) {
	e.str(pc.PoolID)
	e.u64(pc.ManifestVersion)
	e.bytesf(pc.PrevManifestCoreHash)
	e.u64(pc.SignerSetVersion)
	e.u32count(len(pc.ModelAllowlist))
	for _, m := range pc.ModelAllowlist {
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
	e.str(pc.PrivacyMode)
	e.boolean(pc.RelayBlindCapable)
	e.str(pc.ReceiptContract)
	e.str(pc.MetadataVisible)
	e.str(pc.DowngradePolicy)
	e.boolean(pc.StickyRoutingAllowed)
	e.u64(pc.NotBeforeUnix)
	e.u64(pc.ExpiresAtUnix)
}

// u32count writes a 32-bit element count (errors if it exceeds 2^32-1).
func (e *encoder) u32count(n int) {
	if e.err != nil {
		return
	}
	if uint64(n) > uint64(^uint32(0)) {
		e.err = errFieldTooLong
		return
	}
	var b [4]byte
	binary.BigEndian.PutUint32(b[:], uint32(n))
	e.buf = append(e.buf, b[:]...)
}

// CanonicalBytes returns the reversible, deterministic durable encoding of the
// snapshot. Unlike the signed-preimage encodings it preserves field order exactly
// (so Parse(CanonicalBytes(x)) == x) and carries signatures + the acceptance epoch.
func (s ManifestSnapshot) CanonicalBytes() ([]byte, error) {
	e := &encoder{}
	e.tag(manifestSnapshotTag)
	e.str(s.IdentityCore.RootIssuerKeyID)
	e.bytesf(s.IdentityCore.GenesisNonce)
	encodeSigner(e, s.RootIssuerKey)
	e.u32count(len(s.AuthorityLog))
	for _, a := range s.AuthorityLog {
		encodeAuthEntry(e, a)
	}
	e.u32count(len(s.Policies))
	for _, p := range s.Policies {
		encodePolicyCore(e, p.SignedCore.Core)
		encodeSignatures(e, p.SignedCore.Signatures)
		e.u64(p.AcceptedAtUnix)
	}
	if e.err != nil {
		return nil, e.err
	}
	return e.buf, nil
}

// --- decoders ---

func decodeSigner(d *decoder) SignerKey {
	id := d.str()
	pk := d.lenPrefixed()
	return SignerKey{KeyID: id, PublicKey: ed25519.PublicKey(pk)}
}

func decodeSignatures(d *decoder) []Signature {
	n := d.count()
	var sigs []Signature
	for i := 0; i < n && d.err == nil; i++ {
		sigs = append(sigs, Signature{KeyID: d.str(), Sig: d.lenPrefixed()})
	}
	return sigs
}

func decodeAuthEntry(d *decoder) AuthorityLogEntry {
	var a AuthorityLogEntry
	a.PoolID = d.str()
	a.SignerSetVersion = d.u64()
	a.PrevAuthorityLogEntryHash = d.lenPrefixed()
	for n, i := d.count(), 0; i < n && d.err == nil; i++ {
		a.Keys = append(a.Keys, decodeSigner(d))
	}
	a.Threshold = uint32(d.u64())
	a.NotBeforeUnix = d.u64()
	a.ExpiresAtUnix = d.u64()
	for n, i := d.count(), 0; i < n && d.err == nil; i++ {
		a.RevokesVersions = append(a.RevokesVersions, d.u64())
	}
	a.AuthorizingSignerSetVersion = d.u64()
	a.Signatures = decodeSignatures(d)
	return a
}

func decodePolicyCore(d *decoder) PolicyCore {
	var pc PolicyCore
	pc.PoolID = d.str()
	pc.ManifestVersion = d.u64()
	pc.PrevManifestCoreHash = d.lenPrefixed()
	pc.SignerSetVersion = d.u64()
	for n, i := d.count(), 0; i < n && d.err == nil; i++ {
		pc.ModelAllowlist = append(pc.ModelAllowlist, d.str())
	}
	pc.MinBinaryVersion = d.str()
	pc.MinAttestationTier = d.str()
	pc.RequireEncryptedLeg = d.boolean()
	pc.SettlementMode = d.str()
	pc.RevenueSplitBps = d.u64()
	pc.SplitExecutionStatus = d.str()
	pc.RetentionPolicyID = d.str()
	pc.MinEligibleMembers = d.u64()
	pc.PrivacyMode = d.str()
	pc.RelayBlindCapable = d.boolean()
	pc.ReceiptContract = d.str()
	pc.MetadataVisible = d.str()
	pc.DowngradePolicy = d.str()
	pc.StickyRoutingAllowed = d.boolean()
	pc.NotBeforeUnix = d.u64()
	pc.ExpiresAtUnix = d.u64()
	return pc
}

// ParseManifestSnapshot is the strict inverse of CanonicalBytes.
func ParseManifestSnapshot(b []byte) (ManifestSnapshot, error) {
	d := &decoder{buf: b}
	d.expectTag(manifestSnapshotTag)
	var s ManifestSnapshot
	s.IdentityCore = IdentityCore{RootIssuerKeyID: d.str(), GenesisNonce: d.lenPrefixed()}
	s.RootIssuerKey = decodeSigner(d)
	for n, i := d.count(), 0; i < n && d.err == nil; i++ {
		s.AuthorityLog = append(s.AuthorityLog, decodeAuthEntry(d))
	}
	for n, i := d.count(), 0; i < n && d.err == nil; i++ {
		core := decodePolicyCore(d)
		sigs := decodeSignatures(d)
		s.Policies = append(s.Policies, AcceptedPolicyRecord{
			SignedCore:     SignedPolicyCore{Core: core, Signatures: sigs},
			AcceptedAtUnix: d.u64(),
		})
	}
	if err := d.done(); err != nil {
		return ManifestSnapshot{}, err
	}
	return s, nil
}

// SnapshotDigest returns SHA-256 over the canonical snapshot bytes (a stable
// content id for the durable record).
func (s ManifestSnapshot) SnapshotDigest() ([]byte, error) {
	b, err := s.CanonicalBytes()
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(b)
	return sum[:], nil
}

// ReconstructPool rebuilds a pool's authority log and policy-core history from a
// durable snapshot (SPEC-042-R011/R012). The authority log is fully re-verified
// (slice 3, timeless). The policy history is rebuilt with the SAME structural rules
// as the online build but the TIMELESS per-core verifier — a recorded acceptance
// verdict's M-of-N signature is re-verified (catching store corruption), while the
// time-dependent revoked/window gate is REPLAYED, not re-evaluated. So a policy
// accepted before its signer set was later revoked/expired survives reconstruction.
func ReconstructPool(snapshot ManifestSnapshot) (*ReconstructedPool, error) {
	authLog, err := BuildAuthorityLog(snapshot.IdentityCore, snapshot.RootIssuerKey, snapshot.AuthorityLog)
	if err != nil {
		return nil, fmt.Errorf("poolmanifest: authority-log reconstruction failed: %w", err)
	}
	cores := make([]SignedPolicyCore, len(snapshot.Policies))
	for i, p := range snapshot.Policies {
		cores[i] = p.SignedCore
	}
	history, err := buildPolicyHistory(snapshot.IdentityCore, authLog, cores, verifyPolicyCoreSignature)
	if err != nil {
		return nil, fmt.Errorf("poolmanifest: policy-history reconstruction failed: %w", err)
	}
	return &ReconstructedPool{AuthorityLog: authLog, PolicyHistory: history}, nil
}
