package poolmanifest

// SPEC-042-R012 slice 3: the pool authority log. Slice 2 verifies a policy core
// against a SignerSet it is handed; this file is where that SignerSet comes from.
// The root issuer authorizes a versioned, append-only, hash-chained sequence of
// signer sets — the authority log — and this code verifies that chain and
// materializes signer_set_version -> SignerSet (with revocation state) for slice 2
// to consume.
//
// Scope boundary: pure verification of an in-memory entry list. Durable
// persistence, restart/failover reconstruction, the highest-accepted-version store,
// and the durable per-request acceptance-verdict record are slice 5. Emergency
// pool-lifecycle control messages (paused/draining/revoke_immediate, R011/R003) are
// a separate structure. This file has no I/O, no persistence, and no wall-clock.

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"sort"
)

// Domain tags (SPEC-042-R012). The entry content tag domain-separates an entry
// hash from the identity-core and policy-core digests; the sig tag separates an
// authority-log signature from a policy-core signature so neither can be replayed
// as the other.
const (
	authorityLogEntryTag    = "macprovider/spec042/authority-log-entry/v1"
	authorityLogEntrySigTag = "macprovider/spec042/authority-log-entry-sig/v1"
)

var (
	errAuthPrevHashLen   = errors.New("poolmanifest: authority-log prev hash must be 32 bytes")
	errAuthEntryHashLen  = errors.New("poolmanifest: authority-log entry hash must be 32 bytes")
	errAuthEmpty         = errors.New("poolmanifest: authority log has no entries")
	errAuthRollback      = errors.New("poolmanifest: authority-log signer_set_version is not strictly increasing")
	errAuthChainBroken   = errors.New("poolmanifest: authority-log prev_authority_log_entry_hash breaks the chain")
	errAuthGenesisPrev   = errors.New("poolmanifest: authority-log genesis entry prev hash must be the zero value")
	errAuthRevokesOrder  = errors.New("poolmanifest: authority-log revokes_versions must be ascending and distinct")
	errAuthRevokesTarget = errors.New("poolmanifest: authority-log revokes_versions must reference a prior existing version")
	errAuthSelfAuthorize = errors.New("poolmanifest: authorizing_signer_set_version must be a prior version")
	errAuthUnknownAuth   = errors.New("poolmanifest: authorizing_signer_set_version is not in the log")
	errAuthByRevokedSet  = errors.New("poolmanifest: authority-log entry authorized by a revoked signer set")
	errAuthSetInactive   = errors.New("poolmanifest: authorizing signer set window does not contain entry not_before")
	errAuthRootSig       = errors.New("poolmanifest: authority-log root-issuer signature invalid")
	errAuthRootKey       = errors.New("poolmanifest: root issuer public key malformed")
	errAuthRootMismatch  = errors.New("poolmanifest: root issuer key does not bind the pool identity core")
	errAuthPoolID        = errors.New("poolmanifest: authority-log entry pool_id does not match the pool")
)

// AuthorityLogEntry is one signed step of the pool authority log (SPEC-042-R012).
// The content fields (everything except Signatures) are canonically encoded,
// hashed into authority_log_entry_hash, and chained; Signatures authorize the
// entry and are NOT part of the hash.
type AuthorityLogEntry struct {
	PoolID                      string // binds the entry to one pool (SPEC-042-R012: log keyed under pool_id)
	SignerSetVersion            uint64
	PrevAuthorityLogEntryHash   []byte // 32 bytes; genesis = 32 zero bytes
	Keys                        []SignerKey
	Threshold                   uint32 // M of N = len(Keys)
	NotBeforeUnix               uint64 // validity window [NotBeforeUnix, ExpiresAtUnix)
	ExpiresAtUnix               uint64
	RevokesVersions             []uint64 // prior versions revoked by this entry; must be ascending, distinct
	AuthorizingSignerSetVersion uint64   // 0 = root issuer; else a prior still-authorized set
	Signatures                  []Signature
}

// signerSet builds the SignerSet this entry establishes (without Revoked, which is
// stamped later during replay).
func (e AuthorityLogEntry) signerSet() SignerSet {
	return SignerSet{
		Version:       e.SignerSetVersion,
		Keys:          e.Keys,
		Threshold:     e.Threshold,
		NotBeforeUnix: e.NotBeforeUnix,
		ExpiresAtUnix: e.ExpiresAtUnix,
	}
}

// CanonicalContentBytes returns the SPEC-042-R012 authority-log-entry content
// preimage (everything except the authorizing Signatures). Keys are set-ordered by
// key id and revokes_versions ascending; both reject duplicates, so the encoding is
// deterministic and injective.
func (e AuthorityLogEntry) CanonicalContentBytes() ([]byte, error) {
	if len(e.PrevAuthorityLogEntryHash) != manifestCoreHashLen {
		return nil, errAuthPrevHashLen
	}
	// Order keys by key id, rejecting duplicate ids and duplicate public keys.
	keys := append([]SignerKey(nil), e.Keys...)
	sort.Slice(keys, func(i, j int) bool { return keys[i].KeyID < keys[j].KeyID })
	seenID := make(map[string]struct{}, len(keys))
	seenKey := make(map[string]struct{}, len(keys))
	for _, k := range keys {
		if k.KeyID == "" {
			return nil, errSignerKeyID
		}
		if _, dup := seenID[k.KeyID]; dup {
			return nil, errSignerKeyID
		}
		seenID[k.KeyID] = struct{}{}
		if len(k.PublicKey) != ed25519.PublicKeySize {
			return nil, errSignerKeyLen
		}
		if _, dup := seenKey[string(k.PublicKey)]; dup {
			return nil, errSignerKeyDup
		}
		seenKey[string(k.PublicKey)] = struct{}{}
	}
	revokes, err := ascendingDistinct(e.RevokesVersions)
	if err != nil {
		return nil, err
	}

	enc := &encoder{}
	enc.tag(authorityLogEntryTag)
	enc.str(e.PoolID) // bind the entry to its pool so it cannot be replayed into another pool's log
	enc.u64(e.SignerSetVersion)
	enc.bytesf(e.PrevAuthorityLogEntryHash)
	// list(keys): u32 count then each key_id (str) and public_key (bytes).
	if uint64(len(keys)) > uint64(^uint32(0)) {
		return nil, errFieldTooLong
	}
	var count [4]byte
	binary.BigEndian.PutUint32(count[:], uint32(len(keys)))
	enc.buf = append(enc.buf, count[:]...)
	for _, k := range keys {
		enc.str(k.KeyID)
		enc.bytesf(k.PublicKey)
	}
	enc.u64(uint64(e.Threshold))
	enc.u64(e.NotBeforeUnix)
	enc.u64(e.ExpiresAtUnix)
	// list(revokes_versions): u32 count then each u64.
	if uint64(len(revokes)) > uint64(^uint32(0)) {
		return nil, errFieldTooLong
	}
	var rcount [4]byte
	binary.BigEndian.PutUint32(rcount[:], uint32(len(revokes)))
	enc.buf = append(enc.buf, rcount[:]...)
	for _, v := range revokes {
		enc.u64(v)
	}
	enc.u64(e.AuthorizingSignerSetVersion)
	if enc.err != nil {
		return nil, enc.err
	}
	return enc.buf, nil
}

// EntryHash returns authority_log_entry_hash = SHA256(canonical content), 32 bytes.
func (e AuthorityLogEntry) EntryHash() ([]byte, error) {
	b, err := e.CanonicalContentBytes()
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(b)
	return sum[:], nil
}

// AuthorityLogEntrySigningMessage returns the domain-separated message an
// authorizer signs for an entry: authorityLogEntrySigTag ‖ authority_log_entry_hash.
func AuthorityLogEntrySigningMessage(entryHash []byte) ([]byte, error) {
	if len(entryHash) != manifestCoreHashLen {
		return nil, errAuthEntryHashLen
	}
	msg := make([]byte, 0, len(authorityLogEntrySigTag)+manifestCoreHashLen)
	msg = append(msg, authorityLogEntrySigTag...)
	msg = append(msg, entryHash...)
	return msg, nil
}

// ascendingDistinct verifies vs is already in strictly-ascending order (no
// normalization, no duplicates) and returns it. revokes_versions is part of a
// signed, hash-chained structure, so the in-memory list must equal what was signed
// byte-for-byte: a non-ascending or duplicate list is rejected rather than silently
// sorted, so two different orderings can never map to the same signed content.
func ascendingDistinct(vs []uint64) ([]uint64, error) {
	for i := 1; i < len(vs); i++ {
		if vs[i] <= vs[i-1] {
			return nil, errAuthRevokesOrder
		}
	}
	return vs, nil
}

// AuthorityLog is the materialized result of replaying a verified authority log:
// version -> SignerSet (with Revoked stamped), the head chain hash, and the
// current (highest) version.
type AuthorityLog struct {
	sets       map[uint64]SignerSet
	headHash   []byte
	currentVer uint64
}

// SignerSet returns the materialized signer set for a version, ok=false if the
// version is not in the log. It returns a deep copy so a caller cannot mutate the
// log's internal signer material through the returned value.
func (l *AuthorityLog) SignerSet(version uint64) (SignerSet, bool) {
	ss, ok := l.sets[version]
	if !ok {
		return SignerSet{}, false
	}
	return ss.deepCopy(), true
}

// CurrentVersion returns the highest accepted signer_set_version.
func (l *AuthorityLog) CurrentVersion() uint64 { return l.currentVer }

// HeadHash returns the authority_log_entry_hash of the last accepted entry.
func (l *AuthorityLog) HeadHash() []byte {
	out := make([]byte, len(l.headHash))
	copy(out, l.headHash)
	return out
}

// BindsRootIssuer reports whether rootIssuer is the identity core's declared root
// issuer key (key id match) and is a well-formed Ed25519 key. The caller uses this
// to bind BuildAuthorityLog's trust anchor to the pool identity (SPEC-042-R012:
// the identity core carries only root_issuer_key_id, so the public key is supplied
// out of band and its id MUST match).
func (ic IdentityCore) BindsRootIssuer(rootIssuer SignerKey) bool {
	return rootIssuer.KeyID != "" &&
		rootIssuer.KeyID == ic.RootIssuerKeyID &&
		len(rootIssuer.PublicKey) == ed25519.PublicKeySize
}

// BuildAuthorityLog verifies the append-only, hash-chained authority log for one
// pool and materializes signer_set_version -> SignerSet (SPEC-042-R012). The pool
// identity core is the single binding: rootIssuer MUST be the identity core's
// declared root issuer key (id match, well-formed), and every entry's PoolID MUST
// equal the identity core's derived pool_id — so a log (or entry) signed under a
// reused root key cannot be replayed into a different pool. entries must be in
// chain order. Returns a distinct typed sentinel on any reject and a
// fully-materialized log (deep-copied signer material, revocation state stamped) on
// success.
func BuildAuthorityLog(ic IdentityCore, rootIssuer SignerKey, entries []AuthorityLogEntry) (*AuthorityLog, error) {
	if len(entries) == 0 {
		return nil, errAuthEmpty
	}
	if len(rootIssuer.PublicKey) != ed25519.PublicKeySize {
		return nil, errAuthRootKey
	}
	if !ic.BindsRootIssuer(rootIssuer) {
		return nil, errAuthRootMismatch
	}
	poolID, err := ic.PoolID()
	if err != nil {
		return nil, err
	}

	sets := make(map[uint64]SignerSet, len(entries))
	revoked := make(map[uint64]struct{})
	var prevHash []byte // nil before the genesis entry
	var prevVersion uint64
	var haveVersion bool

	for i := range entries {
		e := entries[i]

		// (0) The entry must be bound to this pool.
		if e.PoolID != poolID {
			return nil, errAuthPoolID
		}
		// (1) The signer set this entry establishes must be structurally valid
		// (covers R012 M<1 || M>N, version-0 reservation, distinct keys, window).
		ss := e.signerSet()
		if err := ss.Validate(); err != nil {
			return nil, err
		}
		// (2) prev-hash length.
		if len(e.PrevAuthorityLogEntryHash) != manifestCoreHashLen {
			return nil, errAuthPrevHashLen
		}
		// (3) Monotonic version (strictly increasing); rollback rejected.
		if haveVersion && e.SignerSetVersion <= prevVersion {
			return nil, errAuthRollback
		}
		// (4) Chain intact; genesis prev must be the zero value.
		if prevHash == nil {
			if !isZeroHash(e.PrevAuthorityLogEntryHash) {
				return nil, errAuthGenesisPrev
			}
		} else if !bytes.Equal(e.PrevAuthorityLogEntryHash, prevHash) {
			return nil, errAuthChainBroken
		}
		// (5) revokes_versions well-formed: ascending/distinct and each a prior
		// existing version (cannot revoke self, a future, or a nonexistent version).
		revokes, err := ascendingDistinct(e.RevokesVersions)
		if err != nil {
			return nil, err
		}
		for _, rv := range revokes {
			if rv >= e.SignerSetVersion {
				return nil, errAuthRevokesTarget
			}
			if _, ok := sets[rv]; !ok {
				return nil, errAuthRevokesTarget
			}
		}
		// (6) Authorization.
		entryHash, err := e.EntryHash()
		if err != nil {
			return nil, err
		}
		msg, err := AuthorityLogEntrySigningMessage(entryHash)
		if err != nil {
			return nil, err
		}
		if e.AuthorizingSignerSetVersion == 0 {
			// Root issuer: exactly one signature from the root key, valid.
			if err := verifyRootIssuerSig(rootIssuer, msg, e.Signatures); err != nil {
				return nil, err
			}
		} else {
			av := e.AuthorizingSignerSetVersion
			if av >= e.SignerSetVersion {
				return nil, errAuthSelfAuthorize
			}
			authSet, ok := sets[av]
			if !ok {
				return nil, errAuthUnknownAuth
			}
			// The authorizing set must not be revoked as of the entries processed
			// so far, and its window must contain this entry's not_before. This is
			// checked BEFORE applying the current entry's own revokes, so a set may
			// authorize its own replacement then be revoked (rotate-and-revoke).
			if _, isRev := revoked[av]; isRev {
				return nil, errAuthByRevokedSet
			}
			if !(authSet.NotBeforeUnix <= e.NotBeforeUnix && e.NotBeforeUnix < authSet.ExpiresAtUnix) {
				return nil, errAuthSetInactive
			}
			if err := verifyThresholdMessage(msg, e.Signatures, authSet); err != nil {
				return nil, err
			}
		}

		// Accept: advance the chain, record a private deep copy of the set (so
		// mutating the caller's entries afterward cannot alter verified signer
		// material), then apply revocations.
		prevHash = entryHash
		prevVersion = e.SignerSetVersion
		haveVersion = true
		sets[e.SignerSetVersion] = ss.deepCopy()
		for _, rv := range revokes {
			revoked[rv] = struct{}{}
		}
	}

	// Stamp revocation state onto the materialized sets.
	for v := range revoked {
		ss := sets[v]
		ss.Revoked = true
		sets[v] = ss
	}

	return &AuthorityLog{sets: sets, headHash: prevHash, currentVer: prevVersion}, nil
}

// verifyRootIssuerSig accepts iff Signatures contains exactly one signature, from
// the root issuer key id, valid over msg. The root issuer is a single-key
// authorizer (threshold 1); extra or foreign signatures are rejected so a
// root-authorized entry cannot smuggle additional signer material.
func verifyRootIssuerSig(rootIssuer SignerKey, msg []byte, sigs []Signature) error {
	if len(sigs) != 1 {
		return errAuthRootSig
	}
	s := sigs[0]
	if s.KeyID != rootIssuer.KeyID {
		return errAuthRootSig
	}
	if len(s.Sig) != ed25519.SignatureSize {
		return errAuthRootSig
	}
	if !ed25519.Verify(rootIssuer.PublicKey, msg, s.Sig) {
		return errAuthRootSig
	}
	return nil
}

// isZeroHash reports whether b is all zero bytes (the genesis prev-hash value).
func isZeroHash(b []byte) bool {
	for _, x := range b {
		if x != 0 {
			return false
		}
	}
	return true
}
