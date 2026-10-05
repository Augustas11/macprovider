package billing

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

// SPEC-022-R012 / SPEC-042-R006 (v0.2.0, #1690 M4): the pool-scoped usage
// source pool_operator_attested. It is derived only from a route snapshot's
// digested values plus the durable, append-only pool records they name,
// never from the live registry, the provider hello, or the receipt.

// PoolOperatorAttestationClaim is the digested R012 subset of a route
// snapshot that the durable pool records must support.
type PoolOperatorAttestationClaim struct {
	PoolID                string
	ManifestVersion       uint64
	ManifestCoreDigest    string
	RuntimeSource         string
	PoolGeneration        uint64
	PoolOperatorAccountID string
	ProviderID            string
	// SPEC-022-R013 (#1816): for a pool_manifest route the claim also names
	// the SPEC-042-R015 entry and its exact pair, which the authority must
	// find in the accepted core the snapshot names. PoolMemberAccountID is
	// the serving provider's recorded owner account when it serves under a
	// SPEC-042-R016 attestation instead of as the creator.
	ExpectedModelHashSource    string
	PoolModelID                string
	ExpectedModelHashAlgorithm string
	ExpectedModelHash          string
	PoolMemberAccountID        string
}

// PoolManifestRouteAuthority re-evaluates a pool_manifest route that is not
// pool_operator_attested (a native mlx_cache session serving an R015 entry):
// the accepted core the snapshot names carries the exact entry for the
// runtime, and the provider is an admitted, unrevoked member at the fenced
// generation. The trust-pool store implements it.
type PoolManifestRouteAuthority interface {
	VerifyPoolManifestRoute(ctx context.Context, claim PoolOperatorAttestationClaim) error
}

// PoolOperatorAttestationAuthority re-evaluates SPEC-042-R006 conditions 2-4
// from the coordinator's durable pool records: membership at the fenced
// generation, the durable v2 policy core that allowlists the runtime under
// enforce, and creator-account equality for a creator-owned member. The
// trust-pool store implements it.
type PoolOperatorAttestationAuthority interface {
	VerifyPoolOperatorAttestation(ctx context.Context, claim PoolOperatorAttestationClaim) error
}

var (
	// ErrPoolOperatorAttestationUnavailable means no durable pool authority is
	// wired (trusted pools disabled); pool_operator_attested is then never
	// derived.
	ErrPoolOperatorAttestationUnavailable = errors.New("billing: pool operator attestation authority unavailable")
	errPoolOperatorAttestationSnapshot    = errors.New("billing: route snapshot does not carry the SPEC-022-R012 members")
	// ErrPoolOperatorAttestationRejected is a PERMANENT eligibility rejection
	// by the durable pool authority. Authority implementations wrap it.
	ErrPoolOperatorAttestationRejected = errors.New("billing: pool operator attestation rejected")
	// ErrPoolOperatorAttestationTransient means eligibility could not be
	// evaluated (a store or authority read failed). The receipt is retried;
	// it never becomes an un-cross-checked terminal verdict.
	ErrPoolOperatorAttestationTransient = errors.New("billing: pool operator attestation temporarily unavailable")
)

// poolOperatorAttestationPermanent reports whether an eligibility error is a
// decided rejection rather than an operational failure.
func poolOperatorAttestationPermanent(err error) bool {
	return errors.Is(err, ErrPoolOperatorAttestationRejected) ||
		errors.Is(err, ErrPoolOperatorAttestationUnavailable) ||
		errors.Is(err, errPoolOperatorAttestationSnapshot) ||
		errors.Is(err, errPoolOperatorAttestationNotEnforce)
}

var errPoolOperatorAttestationNotEnforce = errors.New("billing: pool_operator_attested requires an enforce-mode route snapshot")

// PoolFenceQueryer is the read handle a pool attestation fence is read
// through: the ledger write transaction itself, so the fence and the credit
// commit are one atomic decision.
type PoolFenceQueryer interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
}

// PoolRouteFenceSource is the durable half of a pool settlement fence
// (SPEC-042-R015, SPEC-047-R011, SPEC-022-R013). Read through q, it reports
// whether an attempt routed under claim may still settle from its immutable
// route snapshot: the claim's manifest label is an accepted core of the pool,
// and since routing no event revoked the provider's membership or the
// provider, retired or froze the pool, or (for a SPEC-042-R016 member)
// removed that member's attestation from a later accepted core. Ordinary
// manifest rotation, and removing or changing the route's entry in a later
// core, never fail it. A nil error holds; ErrPoolOperatorAttestationRejected
// is a decided failure; anything else could not be read. The durable pool
// authority implements it.
type PoolRouteFenceSource interface {
	PoolRouteFenceHolds(ctx context.Context, q PoolFenceQueryer, claim PoolOperatorAttestationClaim) error
}

// PoolAttestationFence pins the route-time pool claim a pool settlement
// decision used. The ledger transaction re-evaluates it against the durable
// revocation and membership records, never against the current manifest
// version, so an in-flight attempt settles across manifest rotation.
type PoolAttestationFence struct {
	Claim PoolOperatorAttestationClaim
}

// PoolAttestationFenceFor evaluates the fence for a route snapshot before a
// pool settlement decision. False when trusted pools are off, the snapshot
// carries no pool label, or the fence does not hold.
func (s *Store) PoolAttestationFenceFor(ctx context.Context, route RouteSnapshot) (*PoolAttestationFence, bool) {
	if s == nil || route.PoolID == "" || route.ManifestVersion == 0 || route.ManifestCoreDigest == "" {
		return nil, false
	}
	fence := &PoolAttestationFence{Claim: poolAttestationClaimForRoute(route)}
	if !s.poolAttestationFenceHolds(ctx, s.db, fence) {
		return nil, false
	}
	return fence, true
}

// poolAttestationFenceHolds re-evaluates the fence through the ledger write
// transaction q: the durable records still support the route-time claim and
// the live label view does not dispute it. Trusted pools off, an unreadable
// state, a revocation, or a disputed label is false.
func (s *Store) poolAttestationFenceHolds(ctx context.Context, q PoolFenceQueryer, fence *PoolAttestationFence) bool {
	if s == nil || q == nil || fence == nil || fence.Claim.PoolID == "" {
		return false
	}
	source, ok := s.poolOperatorAttestationAuthority().(PoolRouteFenceSource)
	if !ok || source == nil {
		return false
	}
	if err := source.PoolRouteFenceHolds(ctx, q, fence.Claim); err != nil {
		return false
	}
	labels := s.settlementPoolLabels(fence.Claim.PoolID, "")
	return labels != nil && poolLabelRotationUndisputed(fence.Claim.ManifestVersion, fence.Claim.ManifestCoreDigest, labels)
}

// PoolAttestationFenceMatchesRoute reports whether a fence pins exactly the
// route snapshot's route-time pool claim.
func PoolAttestationFenceMatchesRoute(fence *PoolAttestationFence, route RouteSnapshot) bool {
	return fence != nil && fence.Claim == poolAttestationClaimForRoute(route)
}

// PoolAttestedCreditRecorded reports whether an attempt's ledger row carries
// unquarantined credit, i.e. the ledger commit kept its pool attestation.
func (s *Store) PoolAttestedCreditRecorded(ctx context.Context, requestID string, attemptN int, providerID string) bool {
	if s == nil {
		return false
	}
	var quarantined int
	err := s.db.QueryRowContext(ctx, `
SELECT quarantined FROM ledger_request_credits
 WHERE request_id = ? AND attempt_n = ? AND provider_id = ?
 LIMIT 1`, requestID, attemptN, providerID).Scan(&quarantined)
	return err == nil && quarantined == 0
}

// SettlementPoolLabelSource returns the settlement-time SPEC-042 R006 labels of
// a pool (its current manifest version and core digest), or false when the
// pool is unknown.
type SettlementPoolLabelSource func(poolID string) (manifestVersion uint64, manifestCoreDigest string, ok bool)

// SetSettlementPoolLabelSource wires the settlement-time pool label view that
// ledger recovery compares with a route snapshot's routing-time labels.
func (s *Store) SetSettlementPoolLabelSource(source SettlementPoolLabelSource) {
	if s == nil {
		return
	}
	s.poolAttestationMu.Lock()
	defer s.poolAttestationMu.Unlock()
	s.poolLabelSource = source
}

func (s *Store) settlementPoolLabels(poolID, routeHash string) *SettlementPoolLabels {
	if s == nil || poolID == "" {
		return nil
	}
	s.poolAttestationMu.RLock()
	source := s.poolLabelSource
	s.poolAttestationMu.RUnlock()
	if source == nil {
		return nil
	}
	version, digest, ok := source(poolID)
	if !ok {
		return nil
	}
	return &SettlementPoolLabels{PoolID: poolID, ManifestVersion: version, ManifestCoreDigest: digest, RouteSnapshotHash: routeHash}
}

// SetPoolOperatorAttestationAuthority wires the durable pool authority.
func (s *Store) SetPoolOperatorAttestationAuthority(authority PoolOperatorAttestationAuthority) {
	if s == nil {
		return
	}
	s.poolAttestationMu.Lock()
	defer s.poolAttestationMu.Unlock()
	s.poolAttestation = authority
}

func (s *Store) poolOperatorAttestationAuthority() PoolOperatorAttestationAuthority {
	if s == nil {
		return nil
	}
	s.poolAttestationMu.RLock()
	defer s.poolAttestationMu.RUnlock()
	return s.poolAttestation
}

// PoolOperatorAttestationEligible re-evaluates SPEC-022-R012.3 conditions 1-4
// for a recorded route snapshot. Condition 5 (the label is not disputed) is
// the caller's, because it compares the snapshot with a settlement-time view.
func (s *Store) PoolOperatorAttestationEligible(ctx context.Context, route RouteSnapshot) error {
	if !poolOperatorAttestationSnapshotComplete(route) {
		return errPoolOperatorAttestationSnapshot
	}
	if route.RouteSnapshotMode != RouteSnapshotModeEnforce {
		return errPoolOperatorAttestationNotEnforce
	}
	authority := s.poolOperatorAttestationAuthority()
	if authority == nil {
		return ErrPoolOperatorAttestationUnavailable
	}
	return authority.VerifyPoolOperatorAttestation(ctx, poolAttestationClaimForRoute(route))
}

func poolAttestationClaimForRoute(route RouteSnapshot) PoolOperatorAttestationClaim {
	claim := PoolOperatorAttestationClaim{
		PoolID:                route.PoolID,
		ManifestVersion:       route.ManifestVersion,
		ManifestCoreDigest:    route.ManifestCoreDigest,
		RuntimeSource:         route.RuntimeSource,
		PoolGeneration:        route.PoolGeneration,
		PoolOperatorAccountID: route.PoolOperatorAccountID,
		ProviderID:            route.ProviderID,
		PoolMemberAccountID:   route.PoolMemberAccountID,
	}
	if route.PoolManifestSourced() {
		claim.ExpectedModelHashSource = route.ExpectedModelHashSource
		claim.PoolModelID = route.PoolModelID
		claim.ExpectedModelHashAlgorithm = route.ExpectedCatalogModelHashAlgorithm
		claim.ExpectedModelHash = route.ExpectedCatalogModelHash
	}
	return claim
}

// PoolManifestRouteEligible is SPEC-022-R013.3 for a pool_manifest route
// served natively (mlx_cache): the immutable accepted core the snapshot
// names must carry the exact entry, replayed from the durable pool records,
// never repaired from a current manifest. A loopback pool_manifest route is
// covered by PoolOperatorAttestationEligible, whose authority checks the
// same entry. Any other snapshot is not a pool_manifest route.
func (s *Store) PoolManifestRouteEligible(ctx context.Context, route RouteSnapshot) error {
	if !route.PoolManifestSourced() {
		return errPoolOperatorAttestationSnapshot
	}
	if route.RouteSnapshotMode != RouteSnapshotModeEnforce {
		return errPoolOperatorAttestationNotEnforce
	}
	if route.Validate() != nil {
		return errPoolOperatorAttestationSnapshot
	}
	if route.RuntimeSource != "" {
		return s.PoolOperatorAttestationEligible(ctx, route)
	}
	authority, ok := s.poolOperatorAttestationAuthority().(PoolManifestRouteAuthority)
	if !ok || authority == nil {
		return ErrPoolOperatorAttestationUnavailable
	}
	return authority.VerifyPoolManifestRoute(ctx, poolAttestationClaimForRoute(route))
}

// poolOperatorAttestationSnapshotComplete reports whether a route snapshot
// carries every SPEC-022-R012.1 member of a loopback pool route.
func poolOperatorAttestationSnapshotComplete(route RouteSnapshot) bool {
	return route.RuntimeSource != "" && IsLoopbackRuntimeSource(route.RuntimeSource) &&
		route.PoolID != "" && route.ManifestVersion != 0 && hex64Pattern.MatchString(route.ManifestCoreDigest) &&
		route.PoolGeneration != 0 && strings.TrimSpace(route.PoolOperatorAccountID) != ""
}

// PoolOperatorAttestedLabelVerified is SPEC-042-R006 condition 5: the
// attempt's pool label compared with a settlement-time view is verified, not
// disputed or unverified.
func PoolOperatorAttestedLabelVerified(route RouteSnapshot, routeHash string, labels *SettlementPoolLabels) bool {
	return settlementPoolLabelStatus(route, routeHash, labels) == PoolLabelStatusVerified
}

// poolOperatorAttestedIngest pre-evaluates, outside the settlement
// transaction, whether the persisted route snapshot of an attempt satisfies
// SPEC-022-R012 at settlement (R-12.4): the durable conditions and an
// undisputed label. It returns the route digest it evaluated so the verdict
// can require the same snapshot. An operational failure (a store read or an
// authority lookup that could not decide) returns
// ErrPoolOperatorAttestationTransient so the receipt is retried instead of
// being settled as un-cross-checked.
func (s *Store) poolOperatorAttestedIngest(ctx context.Context, id SettlementReceiptIdentity, labels *SettlementPoolLabels) (string, bool, error) {
	var route RouteSnapshot
	var routeHash string
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var err error
		route, routeHash, err = loadSettlementRouteSnapshotConn(ctx, conn, id)
		return err
	})
	if err != nil {
		return "", false, fmt.Errorf("%w: load route snapshot: %v", ErrPoolOperatorAttestationTransient, err)
	}
	if route.RuntimeSource == "" {
		return "", false, nil
	}
	if err := s.PoolOperatorAttestationEligible(ctx, route); err != nil {
		if poolOperatorAttestationPermanent(err) {
			return "", false, nil
		}
		return "", false, fmt.Errorf("%w: %v", ErrPoolOperatorAttestationTransient, err)
	}
	if labels == nil || labels.RouteSnapshotHash != routeHash || !PoolOperatorAttestedLabelVerified(route, routeHash, labels) {
		return "", false, nil
	}
	return routeHash, true, nil
}
