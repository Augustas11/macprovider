package buyer

import (
	"context"
	"net/http"
	"strconv"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

const routingGitHubIDsHeader = "X-MacProvider-Internal-Routing-GitHub-IDs"

type routingIdentityContextKey struct{}
type routingIdentity struct {
	ids         []int64
	unavailable bool
}
type BuyerOwnershipLookup func(context.Context, string, []int64) (map[string]bool, error)

// WithBuyerOwnershipLookup is required in the production server. Legacy,
// isolated servers without an ownership database cannot accept linked identity.
func WithBuyerOwnershipLookup(lookup BuyerOwnershipLookup) Option {
	return func(s *Server) { s.buyerOwnership = lookup }
}

func parseRoutingIdentity(h http.Header) routingIdentity {
	values := h.Values(routingGitHubIDsHeader)
	if len(values) == 0 {
		return routingIdentity{}
	} // legacy gateway
	if len(values) != 1 {
		return routingIdentity{unavailable: true}
	}
	if values[0] == "none" {
		return routingIdentity{}
	}
	parts := strings.Split(values[0], ",")
	if len(parts) > 64 {
		return routingIdentity{unavailable: true}
	}
	identity := routingIdentity{}
	for _, raw := range parts {
		id, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || id <= 0 || strconv.FormatInt(id, 10) != raw {
			return routingIdentity{unavailable: true}
		}
		identity.ids = append(identity.ids, id)
	}
	return identity
}

func ownershipUnavailable() *routeError {
	return &routeError{status: http.StatusServiceUnavailable, code: "no_provider_available", message: "No eligible provider available"}
}

func (s *Server) buyerOwnedProviders(ctx context.Context) (map[string]bool, *routeError) {
	account, authenticated := authenticatedAccountFromContext(ctx)
	if !authenticated {
		return nil, nil
	} // direct legacy calls have no asserted owner
	identity, _ := ctx.Value(routingIdentityContextKey{}).(routingIdentity)
	if identity.unavailable {
		return nil, ownershipUnavailable()
	}
	owned := map[string]bool{}
	if s.buyerOwnership != nil {
		var err error
		owned, err = s.buyerOwnership(ctx, account.ID(), identity.ids)
		if err != nil {
			return nil, ownershipUnavailable()
		}
	} else if len(identity.ids) != 0 {
		return nil, ownershipUnavailable()
	}
	if owned == nil {
		owned = map[string]bool{}
	}
	if s.trustPools != nil {
		for id := range s.trustPools.OwnedProvidersForAccount(account.ID()) {
			owned[id] = true
		}
	}
	return owned, nil
}

func (s *Server) checkBuyerProviderOwnership(ctx context.Context, providerID string) *routeError {
	owned, routeErr := s.buyerOwnedProviders(ctx)
	if routeErr != nil {
		return routeErr
	}
	if owned[providerID] {
		return ownershipUnavailable()
	}
	return nil
}

func filterBuyerOwnedProviders(providers []pool.Provider, owned map[string]bool) []pool.Provider {
	eligible := make([]pool.Provider, 0, len(providers))
	for _, provider := range providers {
		if !owned[provider.ProviderID] {
			eligible = append(eligible, provider)
		}
	}
	return eligible
}
