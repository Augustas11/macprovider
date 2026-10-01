package trustpool

import (
	"context"
	"fmt"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
)

// ErrPoolOperatorAttestation rejects a SPEC-022-R012 pool_operator_attested
// claim that the durable pool records do not support.
var ErrPoolOperatorAttestation = fmt.Errorf("trustpool: %w", billing.ErrPoolOperatorAttestationRejected)

var _ billing.PoolOperatorAttestationAuthority = (*Store)(nil)
var _ billing.PoolManifestRouteAuthority = (*Store)(nil)
var _ billing.PoolEventHighWaterSource = (*Store)(nil)

// PoolEventHighWater returns the id of the pool's latest durable event, read
// through q so a caller holding the ledger write transaction fences on it
// without a second connection. 0 means the pool has no durable events.
func (s *Store) PoolEventHighWater(ctx context.Context, q billing.PoolFenceQueryer, poolID string) (int64, error) {
	if s == nil || q == nil {
		return 0, ErrStoreClosed
	}
	var highWater int64
	err := q.QueryRowContext(ctx, `SELECT COALESCE(MAX(id), 0) FROM trustpool_events WHERE pool_id = ?`, poolID).Scan(&highWater)
	return highWater, err
}

// VerifyPoolOperatorAttestation re-evaluates SPEC-042-R006 conditions 2-4 for
// a route snapshot's digested values from the durable, append-only event log
// only (never the live registry):
//
//   - condition 4: the pool-creation record names the claimed operator
//     account as the creator;
//   - condition 3: the accepted manifest whose version and digest the snapshot
//     carries is a v2 policy core that declares enforce and allowlists the
//     snapshot's runtime_source;
//   - conditions 2 and 4: replaying the membership events up to the fenced
//     pool_generation, the provider is an admitted, unrevoked member that was
//     admitted without a ProviderPoolDelegationV1 grant, i.e. owned by the
//     creator account.
//
// The registry generation fence is never below the durable index of the last
// event it reflects, so a replay bounded by pool_generation includes every
// event the route saw; any later event it may also include can only revoke.
func (s *Store) VerifyPoolOperatorAttestation(ctx context.Context, claim billing.PoolOperatorAttestationClaim) error {
	if s == nil || s.db == nil {
		return ErrStoreClosed
	}
	if claim.PoolID == "" || claim.ProviderID == "" || claim.PoolGeneration == 0 ||
		claim.ManifestVersion == 0 || claim.ManifestCoreDigest == "" || claim.RuntimeSource == "" ||
		strings.TrimSpace(claim.PoolOperatorAccountID) == "" {
		return fmt.Errorf("%w: incomplete claim", ErrPoolOperatorAttestation)
	}
	replay, err := s.replayPoolRouteClaim(ctx, claim, claim.RuntimeSource)
	if err != nil {
		return err
	}
	// Condition 4 (SPEC-042-R006 0.0.37): the creator account owns the
	// provider, or the accepted core's R016 attestation names the serving
	// provider's recorded owner account for this runtime class and the
	// provider is a delegated member.
	attested := !replay.owned && claim.PoolMemberAccountID != "" && claim.PoolMemberAccountID != claim.PoolOperatorAccountID &&
		replay.attestsMember(claim.PoolMemberAccountID, claim.RuntimeSource)
	switch {
	case replay.creator == "" || replay.creator != claim.PoolOperatorAccountID:
		return fmt.Errorf("%w: operator account is not the pool creator", ErrPoolOperatorAttestation)
	case !replay.manifestFound:
		return fmt.Errorf("%w: no accepted policy core with the snapshot digest", ErrPoolOperatorAttestation)
	case !replay.admitted || replay.revoked:
		return fmt.Errorf("%w: provider is not a member at the fenced generation", ErrPoolOperatorAttestation)
	case !replay.owned && !attested:
		return fmt.Errorf("%w: provider is neither creator-owned nor named by a current member attestation", ErrPoolOperatorAttestation)
	case replay.owned && claim.PoolMemberAccountID != "":
		return fmt.Errorf("%w: a creator-owned provider carries a member attestation account", ErrPoolOperatorAttestation)
	}
	return nil
}

// VerifyPoolManifestRoute is SPEC-022-R013.3 for a natively served
// (mlx_cache) pool_manifest route: replayed from the durable event log only,
// the accepted core the snapshot names declares enforce and carries the
// exact entry for mlx_cache, and the provider is an admitted, unrevoked
// member at the fenced generation. Native usage is coordinator-observed, so
// no creator-ownership condition applies.
func (s *Store) VerifyPoolManifestRoute(ctx context.Context, claim billing.PoolOperatorAttestationClaim) error {
	if s == nil || s.db == nil {
		return ErrStoreClosed
	}
	if claim.PoolID == "" || claim.ProviderID == "" || claim.PoolGeneration == 0 ||
		claim.ManifestVersion == 0 || claim.ManifestCoreDigest == "" ||
		claim.ExpectedModelHashSource != billing.ExpectedModelHashSourcePoolManifest || claim.RuntimeSource != "" {
		return fmt.Errorf("%w: incomplete pool manifest claim", ErrPoolOperatorAttestation)
	}
	replay, err := s.replayPoolRouteClaim(ctx, claim, poolmanifest.RuntimeSourceNativeMLX)
	if err != nil {
		return err
	}
	switch {
	case !replay.manifestFound:
		return fmt.Errorf("%w: no accepted policy core with the snapshot digest", ErrPoolOperatorAttestation)
	case !replay.admitted || replay.revoked:
		return fmt.Errorf("%w: provider is not a member at the fenced generation", ErrPoolOperatorAttestation)
	}
	return nil
}

// poolRouteReplay is the durable state a pool route claim is checked against.
type poolRouteReplay struct {
	creator                                 string
	manifestFound, admitted, owned, revoked bool
	attestedMembers                         []poolmanifest.AttestedMember
}

func (r poolRouteReplay) attestsMember(accountID, runtimeSource string) bool {
	for _, a := range r.attestedMembers {
		if a.ProviderAccountID != accountID {
			continue
		}
		for _, source := range a.RuntimeClasses {
			if source == runtimeSource {
				return true
			}
		}
	}
	return false
}

// replayPoolRouteClaim replays the pool's durable events up to the claim's
// fenced generation. The manifest the claim names must be an accepted v2
// core under enforce that allows runtimeSource (a loopback class through
// runtime_allowlist; native mlx_cache always), and, for a pool_manifest
// claim, must carry the exact R015 entry for that runtime. It never consults
// a current manifest.
func (s *Store) replayPoolRouteClaim(ctx context.Context, claim billing.PoolOperatorAttestationClaim, runtimeSource string) (poolRouteReplay, error) {
	var r poolRouteReplay
	events, err := s.Events(ctx)
	if err != nil {
		return r, err
	}
	for i, e := range events {
		if uint64(i+1) > claim.PoolGeneration {
			break
		}
		if e.PoolID != claim.PoolID {
			continue
		}
		switch e.EventType {
		case EventPoolCreated:
			r.creator = e.CreatorAccountID
		case EventManifestAccepted:
			if e.ManifestVersion != claim.ManifestVersion || e.ManifestCoreDigest != claim.ManifestCoreDigest {
				continue
			}
			core, err := acceptedPolicyCoreFromManifestSnapshot(e)
			if err != nil {
				return r, fmt.Errorf("%w: manifest %d: %v", ErrPoolOperatorAttestation, e.ManifestVersion, err)
			}
			runtimeAllowed := runtimeSource == poolmanifest.RuntimeSourceNativeMLX || core.AllowsRuntimeSource(runtimeSource)
			if !core.IsV2() || core.SettlementMode != billing.RouteSnapshotModeEnforce || !runtimeAllowed {
				return r, fmt.Errorf("%w: accepted policy core does not allowlist %s under enforce", ErrPoolOperatorAttestation, runtimeSource)
			}
			if claim.ExpectedModelHashSource == billing.ExpectedModelHashSourcePoolManifest {
				if err := poolManifestEntryMatchesClaim(core, claim, runtimeSource); err != nil {
					return r, err
				}
			} else if claim.ExpectedModelHashSource != "" {
				return r, fmt.Errorf("%w: unknown expected_model_hash_source", ErrPoolOperatorAttestation)
			}
			members, err := core.PoolAttestedMembers()
			if err != nil {
				return r, fmt.Errorf("%w: manifest %d attested members: %v", ErrPoolOperatorAttestation, e.ManifestVersion, err)
			}
			r.attestedMembers = members
			r.manifestFound = true
		case EventMemberAdmitted:
			if e.ProviderID != claim.ProviderID || r.revoked {
				continue
			}
			r.admitted = true
			r.owned = strings.TrimSpace(e.DelegationID) == ""
		case EventDelegationRevoked:
			if e.ProviderID == claim.ProviderID && r.admitted && !r.owned {
				r.admitted = false
			}
		case EventMemberRevoked:
			if e.ProviderID == claim.ProviderID {
				r.revoked = true
				r.admitted = false
			}
		}
	}
	return r, nil
}

// poolManifestEntryMatchesClaim is SPEC-022-R013.3: the immutable accepted
// core carries an entry with the claim's pool_model_id and exact pair that
// allows the runtime.
func poolManifestEntryMatchesClaim(core poolmanifest.PolicyCore, claim billing.PoolOperatorAttestationClaim, runtimeSource string) error {
	entries, err := core.PoolModelEntries()
	if err != nil {
		return fmt.Errorf("%w: pool model entries: %v", ErrPoolOperatorAttestation, err)
	}
	for _, m := range entries {
		if m.PoolModelID != claim.PoolModelID {
			continue
		}
		if m.ArtifactHashAlgorithm != claim.ExpectedModelHashAlgorithm || m.ArtifactHash != claim.ExpectedModelHash || !m.AllowsRuntimeSource(runtimeSource) {
			return fmt.Errorf("%w: pool model entry does not carry the route's pair for %s", ErrPoolOperatorAttestation, runtimeSource)
		}
		return nil
	}
	return fmt.Errorf("%w: accepted policy core has no entry %s", ErrPoolOperatorAttestation, claim.PoolModelID)
}
