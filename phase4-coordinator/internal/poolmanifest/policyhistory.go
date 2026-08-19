package poolmanifest

// SPEC-042-R001 slice 4: active-policy selection over a pool's versioned
// policy-core history. Slice 3 versioned the signer sets; this file versions the
// policy cores signed by them. It accepts a pool's policy-core history under the
// R001 rollback / prev-hash-chain / non-overlapping-window rules (verifying each
// core's signature against the slice-3 authority log via slice 2) and selects the
// single policy that is active at a given instant, or fails closed with
// pool_policy_stale.
//
// Scope boundary: pure. Acceptance is a total function of (identity core, authority
// log, cores); selection is a total function of `now` (an explicit parameter, not
// an ambient clock). Durable persistence, restart reconstruction, the
// highest-accepted-version store, and the durable per-request acceptance-verdict
// record (which grandfathers a policy accepted before its signer set was later
// revoked) are slice 5.

import (
	"bytes"
	"errors"
)

var (
	errPolicyPoolID           = errors.New("poolmanifest: policy core pool_id does not match the pool")
	errPolicyWindow           = errors.New("poolmanifest: policy core validity window must satisfy not_before < expires")
	errPolicyVersionZero      = errors.New("poolmanifest: policy core manifest_version must be >= 1")
	errPolicyRollback         = errors.New("poolmanifest: policy core manifest_version is not strictly increasing")
	errPolicyGenesisPrev      = errors.New("poolmanifest: genesis policy core prev_manifest_core_hash must be the zero value")
	errPolicyChainBroken      = errors.New("poolmanifest: policy core prev_manifest_core_hash breaks the chain")
	errPolicyWindowOverlap    = errors.New("poolmanifest: policy core validity window overlaps an already-accepted version")
	errPolicyUnknownSignerSet = errors.New("poolmanifest: policy core signer_set_version not in the authority log")
	errPoolPolicyStale        = errors.New("poolmanifest: no policy core is active (pool_policy_stale)")
)

// SignedPolicyCore is one versioned policy core plus the detached signatures that
// authorize it (M-of-N of its named signer set).
type SignedPolicyCore struct {
	Core       PolicyCore
	Signatures []Signature
}

// acceptedPolicy is one entry of the materialized history.
type acceptedPolicy struct {
	core   PolicyCore // deep copy
	window window
}

// window is a half-open validity interval [NotBefore, Expires).
type window struct {
	notBefore uint64
	expires   uint64
}

// overlaps reports whether two half-open intervals intersect. Adjacent windows
// (a.expires == b.notBefore) do not overlap.
func (a window) overlaps(b window) bool {
	return a.notBefore < b.expires && b.notBefore < a.expires
}

// contains reports whether now is within [notBefore, expires).
func (w window) contains(now uint64) bool {
	return w.notBefore <= now && now < w.expires
}

// deepCopyPolicyCore returns a PolicyCore whose PrevManifestCoreHash and
// ModelAllowlist slices are freshly allocated, so the copy shares no mutable
// backing storage with the original (slice-3 immutability rule).
func deepCopyPolicyCore(pc PolicyCore) PolicyCore {
	out := pc
	if pc.PrevManifestCoreHash != nil {
		out.PrevManifestCoreHash = append([]byte(nil), pc.PrevManifestCoreHash...)
	}
	if pc.ModelAllowlist != nil {
		out.ModelAllowlist = append([]string(nil), pc.ModelAllowlist...)
	}
	return out
}

// PolicyHistory is the materialized, verified policy-core history for one pool:
// the accepted versions in ascending order plus the highest version. Its windows
// are non-overlapping, so at most one version is active at any instant.
type PolicyHistory struct {
	accepted   []acceptedPolicy // ascending by manifest_version
	highestVer uint64
}

// BuildPolicyHistory verifies and orders a pool's signed policy cores under the
// SPEC-042-R001 rules and returns the active-policy history. cores must be in
// ascending manifest_version order (a non-ascending list is rejected as a
// rollback). Each core is verified against the signer set the slice-3 authority log
// materializes for its signer_set_version. Returns a distinct typed sentinel on any
// reject; the accepted cores are deep-copied so later mutation of the inputs cannot
// alter the history.
func BuildPolicyHistory(ic IdentityCore, authLog *AuthorityLog, cores []SignedPolicyCore) (*PolicyHistory, error) {
	if authLog == nil {
		return nil, errAuthEmpty
	}
	poolID, err := ic.PoolID()
	if err != nil {
		return nil, err
	}

	accepted := make([]acceptedPolicy, 0, len(cores))
	var prevDigest []byte // nil before the genesis core
	var prevVersion uint64
	var haveVersion bool

	for i := range cores {
		spc := cores[i]
		core := spc.Core

		// (1) Pool binding.
		if core.PoolID != poolID {
			return nil, errPolicyPoolID
		}
		// (2) Window well-formed.
		if core.NotBeforeUnix >= core.ExpiresAtUnix {
			return nil, errPolicyWindow
		}
		// (3) Version: >= 1 and strictly increasing.
		if core.ManifestVersion == 0 {
			return nil, errPolicyVersionZero
		}
		if haveVersion && core.ManifestVersion <= prevVersion {
			return nil, errPolicyRollback
		}
		// (4) prev-hash chain; genesis prev must be the zero value.
		if len(core.PrevManifestCoreHash) != manifestCoreHashLen {
			return nil, errPrevHashLen
		}
		if prevDigest == nil {
			if !isZeroHash(core.PrevManifestCoreHash) {
				return nil, errPolicyGenesisPrev
			}
		} else if !bytes.Equal(core.PrevManifestCoreHash, prevDigest) {
			return nil, errPolicyChainBroken
		}
		// (5) Non-overlapping window vs every accepted version.
		w := window{notBefore: core.NotBeforeUnix, expires: core.ExpiresAtUnix}
		for _, a := range accepted {
			if w.overlaps(a.window) {
				return nil, errPolicyWindowOverlap
			}
		}
		// (6) Signature: resolve the signer set and verify (slice 2). This also
		// recomputes the digest and runs structural validation of the core.
		ss, ok := authLog.SignerSet(core.SignerSetVersion)
		if !ok {
			return nil, errPolicyUnknownSignerSet
		}
		if err := VerifyPolicyCore(core, spc.Signatures, ss); err != nil {
			return nil, err
		}

		digest, err := core.ManifestCoreDigest()
		if err != nil {
			return nil, err
		}
		accepted = append(accepted, acceptedPolicy{core: deepCopyPolicyCore(core), window: w})
		prevDigest = digest
		prevVersion = core.ManifestVersion
		haveVersion = true
	}

	if !haveVersion {
		return nil, errPoolPolicyStale // an empty history is never active
	}
	return &PolicyHistory{accepted: accepted, highestVer: prevVersion}, nil
}

// ActivePolicy returns the single policy version whose half-open validity window
// contains nowUnix (SPEC-042-R001). Because acceptance rejects overlapping windows,
// at most one qualifies. If none is active — nowUnix before the earliest window, in
// a gap, or after the latest — it returns errPoolPolicyStale and the caller MUST
// NOT route. The returned core is a deep copy.
func (h *PolicyHistory) ActivePolicy(nowUnix uint64) (PolicyCore, error) {
	for _, a := range h.accepted {
		if a.window.contains(nowUnix) {
			return deepCopyPolicyCore(a.core), nil
		}
	}
	return PolicyCore{}, errPoolPolicyStale
}

// HighestVersion returns the highest accepted manifest_version (the rollback floor
// and an observability handle). It is NOT the "current policy" — the current policy
// is time-dependent (ActivePolicy) and may be a lower active version, or none.
func (h *PolicyHistory) HighestVersion() uint64 { return h.highestVer }
