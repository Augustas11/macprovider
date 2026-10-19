package router

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"
)

var errRoutingIdentityUnavailable = errors.New("routing identity unavailable")

const routingGitHubIDsHeader = "X-MacProvider-Internal-Routing-GitHub-IDs"

type routingIdentityLookup interface {
	RoutingGitHubIdentities(context.Context, string) ([]int64, error)
}

// The header is an assertion from the authenticated gateway database, never
// an inbound header. The explicit unavailable state makes even an encrypted
// reservation fail closed at the coordinator before any provider dispatch.
// The lookup runs on the read-only pool: it is on every chat attempt, so it
// must not queue behind settlement on the single writer connection. WAL makes
// every committed identity link visible to the reader.
func (s *Server) setRoutingIdentity(h http.Header, r *http.Request, accountID string) {
	h.Set(routingGitHubIDsHeader, "unavailable")
	lookup := s.readStore()
	if lookup == nil {
		return
	}
	ids, err := lookup.RoutingGitHubIdentities(r.Context(), accountID)
	if err != nil || len(ids) > 64 {
		return
	}
	if len(ids) == 0 {
		h.Set(routingGitHubIDsHeader, "none")
		return
	}
	values := make([]string, 0, len(ids))
	for _, id := range ids {
		if id <= 0 {
			return
		}
		values = append(values, strconv.FormatInt(id, 10))
	}
	h.Set(routingGitHubIDsHeader, strings.Join(values, ","))
}
