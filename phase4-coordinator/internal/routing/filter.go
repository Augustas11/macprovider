package routing

import "github.com/augstar/macprovider-coordinator/internal/pool"

// RejectionReason enumerates every reason
// EligibleCandidates can drop a provider from the candidate set.
// Order matters: server.go uses the count vector to emit a SPEC-002
// + SPEC-004-aligned error envelope when the eligible list is
// empty (e.g., 503 tier2_hash_verified_required overrides the
// generic no_provider_available).
type RejectionReason int

const (
	// ReasonExcluded — provider key was in the supplied Excluded
	// set (F-4 failover or SPEC-004 retry already touched it).
	ReasonExcluded RejectionReason = iota + 1
	// ReasonModelMismatch — provider does not advertise the
	// requested model AND does not match the resolved class, OR
	// is in a routing-ineligible state per SPEC-002 FR-P5.
	ReasonModelMismatch
	// ReasonContextTooSmall — provider's MaxContextTokens cannot
	// fit the estimated request tokens.
	ReasonContextTooSmall
	// ReasonTier2HashMismatch — provider's heartbeat-reported
	// model hash failed verification (mismatch or invalid).
	ReasonTier2HashMismatch
	// ReasonTier2HashRequired — tier2.require_hash_verified=true
	// and provider's hash is uncatalogued or catalog-unavailable.
	ReasonTier2HashRequired
	// ReasonTier2EncryptedLeg — tier2.require_encrypted_leg=true
	// and provider lacks an encrypted leg.
	ReasonTier2EncryptedLeg
	// ReasonTier2Attestation — tier2.require_attestation=true and
	// provider's attestation status is not Attested.
	ReasonTier2Attestation
	// ReasonQuotaBlocked — provider failed the admission-quota
	// check (typically provisional-tier rate cap).
	ReasonQuotaBlocked
	// ReasonModelVersionFloor — provider's reported binary_version is
	// below the per-model minimum configured in
	// coordinator_advertised_version.per_model_required_binary_version,
	// or is unparseable while such a floor is in force (#768).
	ReasonModelVersionFloor
	// ReasonReceiptKeyMissing — verified_model_settlement_mode=enforce
	// and the provider has no active settlement receipt public key, so a
	// route snapshot can never be recorded for it (SPEC-022 R-2.4/R-2.5:
	// providers with missing/empty settlement preconditions MUST be
	// excluded from covered paid routing). Under observe mode — or when
	// the settlement store/config is unavailable — the checker returns
	// true for every provider and this reason never fires, so default /
	// observe selection stays byte-identical to pre-fix behaviour.
	ReasonReceiptKeyMissing
	// ReasonPoolNotMember — the request carries a pool_id (SPEC-042) and
	// the provider is not a current, non-revoked member of that pool. A
	// false ProviderInPool return is reported here. With no pool selected
	// (global traffic) the checker returns true for every provider and
	// this reason never fires, so poolless selection stays byte-identical
	// to pre-SPEC-042 behaviour. Fail-closed: when every candidate is
	// dropped for this reason the eligible list is empty and the request
	// surfaces the no-eligible-member 503 with no spill to global.
	ReasonPoolNotMember
	// ReasonPoolBinaryTooOld — the request carries a pool_id (SPEC-042) and
	// the provider IS a current member, but its reported binary_version is
	// below the pool's configured minimum (SPEC-042 R004 predicate), so it
	// cannot safely serve the pool's traffic under a mixed-binary rollout
	// (SPEC-042 R010, the provider half of the positive capability handshake).
	// A false ProviderMeetsPoolBinaryFloor return is reported here. Membership
	// dominates: a non-member is reported ReasonPoolNotMember and never also
	// evaluated for the floor. With no pool selected, or no floor configured
	// for the pool, the checker returns true for every provider and this
	// reason never fires — poolless and floorless selection stay byte-identical.
	// Fail-closed: when members exist but all are dropped for this reason the
	// request surfaces pool_binary_too_old (503) with no spill to an
	// under-version or global provider.
	ReasonPoolBinaryTooOld
)

// EligibilityChecker is the cross-package boundary between the
// routing helpers (cold, dependency-free) and the buyer Server's
// per-provider check methods (which need tier2 config, hash
// verifier, quota tracker, etc.). Phase C wires this from
// internal/buyer/server.go; the same methods that currently inline
// the checks satisfy the interface.
//
// Implementations MUST be deterministic for the duration of a
// single EligibleCandidates call — tier2 config snapshots, quota
// state, and hash verifier results MUST NOT change mid-loop.
type EligibilityChecker interface {
	// ProviderMatchesRequest reports whether the provider
	// advertises the requested model (or is a member of the
	// resolved class) AND is in a routing-eligible state per
	// SPEC-002 FR-P5. Implementation MUST combine the model /
	// class check with RoutingEligible(); a false return is
	// reported as ReasonModelMismatch.
	ProviderMatchesRequest(p pool.Provider) bool

	// ProviderMeetsModelVersionFloor reports whether the provider's
	// reported binary_version satisfies the per-model minimum
	// version floor (#768). A false return is reported as
	// ReasonModelVersionFloor. Implementations MUST delegate to the
	// SAME versionfloor.Check used by the self-route preflight and
	// warm-pool gates — "we never warm a box we won't route to"
	// only holds while all three share one verdict. With no floors
	// configured the implementation MUST return true for every
	// provider so selection stays byte-identical to pre-#768.
	ProviderMeetsModelVersionFloor(p pool.Provider) bool

	// ProviderHasSettlementReceiptKey reports whether the provider can
	// have a route snapshot recorded under the active settlement mode.
	// A false return is reported as ReasonReceiptKeyMissing (SPEC-022
	// R-2.4/R-2.5). Implementations MUST return true UNLESS
	// verified_model_settlement_mode is `enforce` AND the provider's
	// active receipt public key is empty — the SAME (store, mode) source
	// the pre-dispatch route-snapshot guard in route_snapshot.go reads,
	// so the eligibility filter and the fail-closed backstop cannot
	// diverge. In observe mode, or when the settlement store/config is
	// unavailable, it MUST return true for every provider so observe /
	// default selection stays byte-identical.
	ProviderHasSettlementReceiptKey(p pool.Provider) bool

	// ProviderContextSufficient reports whether the provider's
	// MaxContextTokens fits the request's estimated token budget.
	// Implementation MUST use the same token-estimation function
	// the buyer Server uses elsewhere to keep selection
	// byte-identical with pre-Phase-C behavior.
	ProviderContextSufficient(p pool.Provider) bool

	// Tier2Decision reports the tier2 verification outcome.
	// Returns (ReasonNone == 0, observed-or-effective HashStatus)
	// on accept, or a non-zero ReasonTier2* on reject.
	// HashStatus is the value the implementation observed for
	// the provider; the caller uses it (only) when the reason
	// is ReasonTier2HashMismatch to stamp p.HashStatus for the
	// error envelope.
	Tier2Decision(p pool.Provider) (RejectionReason, pool.HashStatus)

	// QuotaPermits reports whether the provider passes the
	// admission-quota check (typically provisional-tier rate cap).
	// A false return is reported as ReasonQuotaBlocked. Quota is
	// a SOFT filter: per SPEC-002, the loop reports
	// 429 provisional_quota_exceeded ONLY when EVERY otherwise-
	// eligible provider is quota-blocked. server.go applies the
	// 429-vs-503 decision against FilterResult counts.
	QuotaPermits(p pool.Provider) bool

	// ProviderInPool reports whether the provider is a current,
	// non-revoked member of the request's selected pool (SPEC-042
	// R005 tenant isolation). A false return is reported as
	// ReasonPoolNotMember. Implementations MUST return true for every
	// provider when the request carries no pool selection, so global
	// (poolless) selection stays byte-identical to pre-SPEC-042. The
	// member set and pool generation MUST be read as a single
	// consistent snapshot (SPEC-042 R003) so a revocation cannot leave
	// a stale member passing this gate.
	ProviderInPool(p pool.Provider) bool

	// ProviderMeetsPoolBinaryFloor reports whether a pool MEMBER's reported
	// binary_version satisfies the selected pool's minimum version floor
	// (SPEC-042 R004 / R010 provider half). A false return is reported as
	// ReasonPoolBinaryTooOld. This is evaluated only after ProviderInPool
	// (membership dominates). Implementations MUST return true for every
	// provider when the request carries no pool selection OR the pool has no
	// floor configured, so poolless and floorless selection stay
	// byte-identical. The floor MUST come from the SAME consistent snapshot as
	// membership/generation (SPEC-042 R003), and an empty/unparseable
	// binary_version while a floor is in force MUST be treated as below the
	// floor (fail-safe, mirroring the #768 malformed-version posture).
	ProviderMeetsPoolBinaryFloor(p pool.Provider) bool
}

// RejectedProvider records a single provider drop with enough
// context for the error-envelope mapping in server.go.
type RejectedProvider struct {
	Provider   pool.Provider
	Reason     RejectionReason
	HashStatus pool.HashStatus // non-zero only when Reason == ReasonTier2HashMismatch
}

// FilterResult is the structured output of EligibleCandidates.
// Eligible is the candidate list AFTER every composition gate;
// Counts is the per-reason rejection vector; HashMismatches lists
// the providers dropped specifically for hash mismatch / invalid
// (server.go uses the first one's provider_id in the error
// message). PreQuotaCount is the number of providers that survived
// every gate except quota — needed to distinguish "first loop dropped
// everything" from "every first-loop survivor was quota-blocked"
// when the caller picks 503-vs-429 envelopes.
type FilterResult struct {
	Eligible       []pool.Provider
	Counts         map[RejectionReason]int
	HashMismatches []RejectedProvider
	PreQuotaCount  int
}

// EligibleCandidates applies SPEC-002 composition gates +
// SPEC-004 FR-SR-18 ordering: filter FIRST (state, model/class,
// context, tier2), THEN quota. Sort / tiebreak / preflight run
// AFTER this helper in the caller.
//
// Order of per-provider checks matches the pre-Phase-C inline
// loop in internal/buyer/server.go::selectProviderExcluding so
// byte-identical default-config selection (AC-SR-1) is preserved.
// The order is:
//
//  1. Excluded check (F-4 failover / SPEC-004 retry skip)
//  2. ProviderMatchesRequest (model/class + FR-P5 state) — combined
//     gate; either failure is ReasonModelMismatch (the inline loop
//     short-circuits to `continue` without separating the two)
//  3. ProviderMeetsModelVersionFloor — ReasonModelVersionFloor
//     (#768). Runs immediately after the model match because the
//     floor is keyed BY model; a no-op when no floors are
//     configured, so default-config selection stays byte-identical
//     (AC-SR-1).
//  3b. ProviderHasSettlementReceiptKey — ReasonReceiptKeyMissing
//     (SPEC-022 R-2.4/R-2.5). A no-op in observe mode / when the
//     settlement store is unavailable, so default / observe selection
//     stays byte-identical; under enforce it drops providers with no
//     active receipt key so routing never selects a box whose route
//     snapshot is guaranteed to fail pre-dispatch.
//  4. ProviderContextSufficient — ReasonContextTooSmall
//  5. Tier2Decision — ReasonTier2HashMismatch / ReasonTier2Hash
//     Required / ReasonTier2EncryptedLeg / ReasonTier2Attestation
//  6. QuotaPermits — ReasonQuotaBlocked (applied as a second pass
//     here to preserve the "quota is soft, drives 429 only when
//     every other check passed" semantics)
//
// keyer is the same routeKey function the caller uses elsewhere —
// passed in so routing/ does not duplicate buyer-internal key
// derivation.
func EligibleCandidates(
	providers []pool.Provider,
	excluded Excluded,
	keyer func(pool.Provider) string,
	checker EligibilityChecker,
) FilterResult {
	res := FilterResult{
		Eligible: make([]pool.Provider, 0, len(providers)),
		Counts:   make(map[RejectionReason]int),
	}
	// First pass: state / model / context / tier2 gates.
	preQuota := make([]pool.Provider, 0, len(providers))
	for _, p := range providers {
		if excluded.Has(keyer(p)) {
			res.Counts[ReasonExcluded]++
			continue
		}
		// SPEC-042 R005 tenant isolation: a non-member of the request's
		// selected pool is dropped before any model/version/tier2 gate —
		// pool membership is the trust boundary and dominates. For global
		// (poolless) requests ProviderInPool returns true for every
		// provider, so this gate is a no-op and selection stays
		// byte-identical to pre-SPEC-042.
		if !checker.ProviderInPool(p) {
			res.Counts[ReasonPoolNotMember]++
			continue
		}
		// SPEC-042 R004/R010 provider half: a pool MEMBER whose binary_version
		// is below the pool's configured floor cannot serve the pool's traffic
		// under a mixed-binary rollout. Evaluated after membership (which
		// dominates). No-op for global requests and for pools with no floor,
		// so poolless/floorless selection stays byte-identical.
		if !checker.ProviderMeetsPoolBinaryFloor(p) {
			res.Counts[ReasonPoolBinaryTooOld]++
			continue
		}
		if !checker.ProviderMatchesRequest(p) {
			res.Counts[ReasonModelMismatch]++
			continue
		}
		if !checker.ProviderMeetsModelVersionFloor(p) {
			res.Counts[ReasonModelVersionFloor]++
			continue
		}
		if !checker.ProviderHasSettlementReceiptKey(p) {
			res.Counts[ReasonReceiptKeyMissing]++
			continue
		}
		if !checker.ProviderContextSufficient(p) {
			res.Counts[ReasonContextTooSmall]++
			continue
		}
		reason, hashStatus := checker.Tier2Decision(p)
		if reason != 0 {
			res.Counts[reason]++
			if reason == ReasonTier2HashMismatch {
				rejected := p
				rejected.HashStatus = hashStatus
				res.HashMismatches = append(res.HashMismatches, RejectedProvider{
					Provider:   rejected,
					Reason:     reason,
					HashStatus: hashStatus,
				})
			}
			continue
		}
		preQuota = append(preQuota, p)
	}
	res.PreQuotaCount = len(preQuota)
	// Second pass: quota gate. SPEC-002 contract is that quota
	// rejection drives 429 provisional_quota_exceeded ONLY when
	// every otherwise-eligible candidate is quota-blocked; server.go
	// applies the 429-vs-503 decision against res.Counts.
	for _, p := range preQuota {
		if checker.QuotaPermits(p) {
			res.Eligible = append(res.Eligible, p)
			continue
		}
		res.Counts[ReasonQuotaBlocked]++
	}
	return res
}
