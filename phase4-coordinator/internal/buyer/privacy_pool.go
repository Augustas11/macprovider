package buyer

import (
	"context"
	"net/http"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/relayblind"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// SPEC-049-R032: a privacy-class request scoped to a Trusted Pool. The pool
// is the gateway-authorized X-MacProvider-Pool; the provider must be both a
// current eligible member and eligible for the privacy class.

// privacyForwardedPool returns the single gateway-forwarded pool of a
// request. ok is false for any other pool header, a repeated header, or a
// malformed value: those are pool intent the privacy class cannot bind.
func privacyForwardedPool(r *http.Request) (string, bool) {
	poolID := ""
	for key, values := range r.Header {
		lower := strings.ToLower(key)
		if lower != "x-macprovider-pool" && !strings.HasPrefix(lower, "x-macprovider-pool-") {
			continue
		}
		nonempty := 0
		for _, value := range values {
			if strings.TrimSpace(value) != "" {
				nonempty++
			}
		}
		if nonempty == 0 {
			continue
		}
		if lower != "x-macprovider-pool" || nonempty != 1 || len(values) != 1 {
			return "", false
		}
		raw := strings.TrimSpace(values[0])
		poolID = sanitizeAccountID(raw)
		if poolID == "" || poolID != raw {
			return "", false
		}
	}
	return poolID, true
}

// relayBlindPoolScope applies SPEC-049-R022 and R032 item 1 to a relay-blind
// hop. It returns the forwarded pool ("" for global) or writes the refusal.
// Pool intent is honored only on a valid privacy-class request from an API
// key: plain relay-blind and wallet sessions stay global-pool only.
func (s *Server) relayBlindPoolScope(w http.ResponseWriter, r *http.Request, phase string, present, valid bool, walletSession, plainMessage string) (string, bool) {
	if !relayBlindPoolIntent(r) {
		return "", true
	}
	if !present {
		writeRelayBlindError(w, "relay_blind_downgrade_rejected", plainMessage)
		return "", false
	}
	poolID, ok := privacyForwardedPool(r)
	if !ok || !valid || walletSession != "" {
		s.writePrivacyRouteErrorMessage(w, r, phase, privacyClassDowngrade, relayblind.PrivacyRejectPoolScopedRequest, "Privacy class does not accept this pool selection")
		return "", false
	}
	return poolID, true
}

// privacyPoolGate is SPEC-049-R032 item 2: re-authorize the pool for the
// account against durable state and capture one consistent snapshot before
// any privacy candidate is evaluated. It returns the SPEC-042-R010 code of a
// refusal.
func (s *Server) privacyPoolGate(ctx context.Context, poolID, accountID, model string) (trustpool.Snapshot, string) {
	if s.trustPools == nil || poolID == "" || accountID == "" {
		return trustpool.Snapshot{}, "pool_unavailable"
	}
	snap, authorized, err := s.authorizeTrustPoolFromDurableState(ctx, poolID, accountID)
	if err != nil {
		return trustpool.Snapshot{}, "pool_unavailable"
	}
	return s.privacyPoolUsable(snap, authorized, model)
}

// privacyPoolUsable applies the SPEC-049-R032 item 2 checks to one
// consistent pool snapshot and returns the SPEC-042-R010 code of a refusal.
func (s *Server) privacyPoolUsable(snap trustpool.Snapshot, authorized bool, model string) (trustpool.Snapshot, string) {
	if !authorized || !snap.Exists {
		return trustpool.Snapshot{}, "pool_unavailable"
	}
	if snap.Routeable && poolRouteableSnapshotExpiredAt(snap, time.Now().UTC()) {
		snap.Routeable = false
		snap.RouteableExpired = true
	}
	if !snap.Routeable {
		if snap.RouteableExpired {
			return trustpool.Snapshot{}, "pool_policy_stale"
		}
		return trustpool.Snapshot{}, "pool_unavailable"
	}
	// A seed-only pool has no manifest labels, so its settlement label could
	// never be verified (SPEC-042-R006).
	if snap.ManifestVersion == 0 || snap.ManifestCoreDigest == "" {
		return trustpool.Snapshot{}, "pool_unavailable"
	}
	if poolSettlementRequiresEnforce(snap.SettlementMode) && !s.settlementEnforceMode() {
		return trustpool.Snapshot{}, "pool_settlement_mode_unsatisfied"
	}
	if !poolModelAllowed(model, nil, snap.ModelAllowlist) {
		return trustpool.Snapshot{}, "pool_model_not_allowed"
	}
	return snap, ""
}

// privacyPoolMemberEligible is the SPEC-049-R032 item 3 member half of the
// intersection: a current non-revoked member that advertises
// trusted_pool_v1, meets the binary floor, and is a native session not bound
// to a pool model entry.
func privacyPoolMemberEligible(snap trustpool.Snapshot, p pool.Provider) bool {
	return snap.Members[p.ProviderID] &&
		poolProviderSupportsTrustedPools(p) &&
		poolBinaryFloorMet(p.BinaryVersion, snap.MinBinaryVersion) &&
		!providerws.IsBYOMLoopbackRuntimeSource(p.RuntimeSource) &&
		p.ModelAdmissionPoolModelID == ""
}

// privacyPoolFence is SPEC-049-R032 item 5: the reserved pool is still
// authorized and routeable at the reserved generation and manifest, and the
// reserved provider still passes the member predicates. Like the plaintext
// dispatch fence it reads the live registry, whose generation advances on
// every membership, buyer, or lifecycle change. It returns the live snapshot,
// or false when the reservation must be burned.
func (s *Server) privacyPoolFence(reservation relayblind.Reservation) (trustpool.Snapshot, bool) {
	if reservation.PoolID == "" {
		return trustpool.Snapshot{}, true
	}
	if s.trustPools == nil {
		return trustpool.Snapshot{}, false
	}
	current, authorized := s.trustPools.AuthorizeAndSnapshot(reservation.PoolID, reservation.AccountID)
	snap, code := s.privacyPoolUsable(current, authorized, reservation.Model)
	if code != "" || snap.Generation != reservation.PoolGeneration || snap.ManifestVersion != reservation.PoolManifestVersion || snap.ManifestCoreDigest != reservation.PoolManifestCoreDigest {
		return trustpool.Snapshot{}, false
	}
	provider, live := s.pool.Resolve(reservation.ProviderID, reservation.AssignedSession)
	if !live || provider.AssignedID != reservation.AssignedSession || !privacyPoolMemberEligible(snap, provider) {
		return trustpool.Snapshot{}, false
	}
	return snap, true
}

// writePrivacyPoolRefusal records reason pool_scoped_request and writes the
// SPEC-042-R010 code of a pool refused before selection. pool_unavailable
// keeps the timing floor so latency does not reveal the cause.
func (s *Server) writePrivacyPoolRefusal(w http.ResponseWriter, r *http.Request, phase, code string, startedAt time.Time) {
	s.notePrivacyRouteRejection(w, r, phase, code, relayblind.PrivacyRejectPoolScopedRequest)
	switch code {
	case "pool_policy_stale":
		writeError(w, http.StatusServiceUnavailable, code, "Pool policy/status freshness is stale")
	case "pool_model_not_allowed":
		writeError(w, http.StatusBadRequest, code, "Requested model is not allowed by the selected pool")
	case "pool_settlement_mode_unsatisfied":
		writeError(w, http.StatusServiceUnavailable, code, "Pool requires enforce-mode settlement")
	default:
		s.writePoolUnavailable(w, startedAt)
	}
}

// bindPrivacyPoolRoute labels the request's routing state with the reserved
// pool, so the R-14 route snapshot, the settlement verdict, and the request
// log carry the SPEC-042-R006 labels (SPEC-049-R032 item 6).
func bindPrivacyPoolRoute(state *forwardState, reservation relayblind.Reservation, snap trustpool.Snapshot) {
	if state == nil || reservation.PoolID == "" {
		return
	}
	state.poolID = reservation.PoolID
	state.poolMembers = snap.Members
	state.poolGeneration = reservation.PoolGeneration
	state.poolGenSet = true
	state.poolManifestVersion = reservation.PoolManifestVersion
	state.poolManifestCoreDigest = reservation.PoolManifestCoreDigest
	state.poolMinBinaryVersion = snap.MinBinaryVersion
	state.poolModelAllowlist = append([]string(nil), snap.ModelAllowlist...)
	state.poolRequiresSettlementEnforce = poolSettlementRequiresEnforce(snap.SettlementMode)
	state.poolCreatorAccountID = snap.CreatorAccountID
	state.poolCreatorOwnedMembers = snap.CreatorOwnedMembers
}
