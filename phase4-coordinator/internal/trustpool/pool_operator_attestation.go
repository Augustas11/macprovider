package trustpool

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/billing"
)

// ErrPoolOperatorAttestation rejects a SPEC-022-R012 pool_operator_attested
// claim that the durable pool records do not support.
var ErrPoolOperatorAttestation = errors.New("trustpool: pool operator attestation rejected")

var _ billing.PoolOperatorAttestationAuthority = (*Store)(nil)

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
	events, err := s.Events(ctx)
	if err != nil {
		return err
	}
	var creator string
	var manifestFound, admitted, owned, revoked bool
	for i, e := range events {
		if uint64(i+1) > claim.PoolGeneration {
			break
		}
		if e.PoolID != claim.PoolID {
			continue
		}
		switch e.EventType {
		case EventPoolCreated:
			creator = e.CreatorAccountID
		case EventManifestAccepted:
			if e.ManifestVersion != claim.ManifestVersion || e.ManifestCoreDigest != claim.ManifestCoreDigest {
				continue
			}
			core, err := acceptedPolicyCoreFromManifestSnapshot(e)
			if err != nil {
				return fmt.Errorf("%w: manifest %d: %v", ErrPoolOperatorAttestation, e.ManifestVersion, err)
			}
			if !core.IsV2() || core.SettlementMode != billing.RouteSnapshotModeEnforce || !core.AllowsRuntimeSource(claim.RuntimeSource) {
				return fmt.Errorf("%w: accepted policy core does not allowlist %s under enforce", ErrPoolOperatorAttestation, claim.RuntimeSource)
			}
			manifestFound = true
		case EventMemberAdmitted:
			if e.ProviderID != claim.ProviderID || revoked {
				continue
			}
			admitted = true
			owned = strings.TrimSpace(e.DelegationID) == ""
		case EventDelegationRevoked:
			if e.ProviderID == claim.ProviderID && admitted && !owned {
				admitted = false
			}
		case EventMemberRevoked:
			if e.ProviderID == claim.ProviderID {
				revoked = true
				admitted = false
			}
		}
	}
	switch {
	case creator == "" || creator != claim.PoolOperatorAccountID:
		return fmt.Errorf("%w: operator account is not the pool creator", ErrPoolOperatorAttestation)
	case !manifestFound:
		return fmt.Errorf("%w: no accepted policy core with the snapshot digest", ErrPoolOperatorAttestation)
	case !admitted || revoked:
		return fmt.Errorf("%w: provider is not a member at the fenced generation", ErrPoolOperatorAttestation)
	case !owned:
		return fmt.Errorf("%w: provider is admitted through a delegation, not owned by the creator", ErrPoolOperatorAttestation)
	}
	return nil
}
