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
// message).
type FilterResult struct {
	Eligible       []pool.Provider
	Counts         map[RejectionReason]int
	HashMismatches []RejectedProvider
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
//  3. ProviderContextSufficient — ReasonContextTooSmall
//  4. Tier2Decision — ReasonTier2HashMismatch / ReasonTier2Hash
//     Required / ReasonTier2EncryptedLeg / ReasonTier2Attestation
//  5. QuotaPermits — ReasonQuotaBlocked (applied as a second pass
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
		if !checker.ProviderMatchesRequest(p) {
			res.Counts[ReasonModelMismatch]++
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
