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
}

// PoolEventHighWaterSource reads the id of a pool's latest durable event
// through q. The durable pool authority implements it; any durable change
// to a pool (membership, manifest, lifecycle) advances it.
type PoolEventHighWaterSource interface {
	PoolEventHighWater(ctx context.Context, q PoolFenceQueryer, poolID string) (int64, error)
}

// PoolAttestationFence pins the pool state a pool_operator_attested decision
// used: the pool's durable event high-water mark, read before the durable
// checks, and the settlement-time label it verified against.
type PoolAttestationFence struct {
	PoolID             string
	PoolEventHighWater int64
	ManifestVersion    uint64
	ManifestCoreDigest string
}

// PoolAttestationFenceFor reads the fence for poolID before a
// pool_operator_attested decision. False when trusted pools are off or the
// pool state cannot be read.
func (s *Store) PoolAttestationFenceFor(ctx context.Context, poolID string) (*PoolAttestationFence, bool) {
	if s == nil || poolID == "" {
		return nil, false
	}
	return s.readPoolAttestationFence(ctx, s.db, poolID)
}

func (s *Store) readPoolAttestationFence(ctx context.Context, q PoolFenceQueryer, poolID string) (*PoolAttestationFence, bool) {
	source, ok := s.poolOperatorAttestationAuthority().(PoolEventHighWaterSource)
	if !ok || source == nil {
		return nil, false
	}
	highWater, err := source.PoolEventHighWater(ctx, q, poolID)
	if err != nil || highWater <= 0 {
		return nil, false
	}
	labels := s.settlementPoolLabels(poolID, "")
	if labels == nil {
		return nil, false
	}
	return &PoolAttestationFence{
		PoolID:             poolID,
		PoolEventHighWater: highWater,
		ManifestVersion:    labels.ManifestVersion,
		ManifestCoreDigest: labels.ManifestCoreDigest,
	}, true
}

// poolAttestationFenceHolds re-reads the fence through the ledger write
// transaction q and reports whether the pool is unchanged since the
// decision. Trusted pools off, an unreadable state, or any change is false.
func (s *Store) poolAttestationFenceHolds(ctx context.Context, q PoolFenceQueryer, fence *PoolAttestationFence) bool {
	if fence == nil || fence.PoolID == "" {
		return false
	}
	current, ok := s.readPoolAttestationFence(ctx, q, fence.PoolID)
	return ok && *current == *fence
}

// PoolAttestationFenceMatchesRoute reports whether a fence's label is the
// route snapshot's routing-time label.
func PoolAttestationFenceMatchesRoute(fence *PoolAttestationFence, route RouteSnapshot) bool {
	return fence != nil && fence.PoolID == route.PoolID &&
		fence.ManifestVersion == route.ManifestVersion && fence.ManifestCoreDigest == route.ManifestCoreDigest
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
	return authority.VerifyPoolOperatorAttestation(ctx, PoolOperatorAttestationClaim{
		PoolID:                route.PoolID,
		ManifestVersion:       route.ManifestVersion,
		ManifestCoreDigest:    route.ManifestCoreDigest,
		RuntimeSource:         route.RuntimeSource,
		PoolGeneration:        route.PoolGeneration,
		PoolOperatorAccountID: route.PoolOperatorAccountID,
		ProviderID:            route.ProviderID,
	})
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
