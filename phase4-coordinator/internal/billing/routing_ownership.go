package billing

import (
	"context"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type RoutingStakeIdentityLookup func(context.Context, string) (int64, error)

// RoutingStakeIdentityTimeout bounds one rewards-ledger stake identity read
// on the dispatch path. A var so tests can shorten it.
var RoutingStakeIdentityTimeout = 250 * time.Millisecond

// routingStakeIdentitySource is the dispatch-path view of the rewards-ledger
// stake identity (SPEC-050-R002, SPEC-002-R008). A positive identity never
// changes once written, so it is cached for the process lifetime; only
// accounts with no stake are re-read, each read under a short deadline.
type routingStakeIdentitySource struct {
	lookup     RoutingStakeIdentityLookup
	onFallback func(accountID string, err error)
	positive   sync.Map // account id -> int64 (> 0)
	fallbacks  atomic.Int64
}

// SetRoutingStakeIdentityLookup installs the configured rewards-ledger read.
// Install it only when the stake ledger initialised; without it the stake
// source contributes no identity. A failed or timed-out read is not
// propagated: the dispatch falls back to the other ownership sources
// (gateway identities, allowance grants, trust-pool owners) and onFallback
// is told, so a rewards-database fault never refuses buyers.
func (s *Store) SetRoutingStakeIdentityLookup(lookup RoutingStakeIdentityLookup, onFallback func(accountID string, err error)) {
	if lookup != nil {
		s.routingStakeIdentity.Store(&routingStakeIdentitySource{lookup: lookup, onFallback: onFallback})
	}
}

// RoutingStakeIdentityFallbacks counts stake identity reads that failed or
// timed out and fell back to the other ownership sources.
func (s *Store) RoutingStakeIdentityFallbacks() int64 {
	if source := s.routingStakeIdentity.Load(); source != nil {
		return source.fallbacks.Load()
	}
	return 0
}

func (src *routingStakeIdentitySource) identity(ctx context.Context, accountID string) int64 {
	if cached, ok := src.positive.Load(accountID); ok {
		return cached.(int64)
	}
	readCtx, cancel := context.WithTimeout(ctx, RoutingStakeIdentityTimeout)
	defer cancel()
	id, err := src.lookup(readCtx, accountID)
	if err != nil {
		src.fallbacks.Add(1)
		if src.onFallback != nil {
			src.onFallback(accountID, err)
		}
		return 0
	}
	if id > 0 {
		src.positive.Store(accountID, id)
	}
	return id
}

// BuyerOwnedProviders reads authoritative owner links without the reward
// exclusion cache: a new claim must fence the next dispatch immediately.
func (s *Store) BuyerOwnedProviders(ctx context.Context, accountID string, githubIDs []int64) (map[string]bool, error) {
	if s == nil || s.db == nil {
		return nil, errors.New("routing ownership store unavailable")
	}
	ids := make(map[int64]bool)
	for _, id := range githubIDs {
		if id <= 0 {
			return nil, errors.New("invalid routing identity")
		}
		ids[id] = true
	}
	if source := s.routingStakeIdentity.Load(); source != nil {
		if id := source.identity(ctx, accountID); id > 0 {
			ids[id] = true
		}
	}
	// Close the identity cursor before querying ownership: production SQLite
	// handles may have one connection. Successful no-link needs no owner query.
	if err := s.readAllowanceRoutingIdentities(ctx, accountID, ids); err != nil {
		return nil, err
	}
	if len(ids) == 0 {
		return map[string]bool{}, nil
	}
	if len(ids) > 128 {
		return nil, errors.New("too many routing identities")
	}
	args := make([]any, 0, len(ids))
	for id := range ids {
		args = append(args, id)
	}
	rows, err := s.reader().QueryContext(ctx, `SELECT provider_id FROM provider_ownership WHERE github_user_id IN (`+strings.TrimSuffix(strings.Repeat("?,", len(args)), ",")+`)`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	owned := make(map[string]bool)
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		owned[id] = true
	}
	return owned, rows.Err()
}

func (s *Store) readAllowanceRoutingIdentities(ctx context.Context, accountID string, ids map[int64]bool) error {
	rows, err := s.reader().QueryContext(ctx, `SELECT DISTINCT github_user_id FROM allowance_grants WHERE account_id = ? AND github_user_id > 0 LIMIT 129`, accountID)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return err
		}
		ids[id] = true
	}
	return rows.Err()
}
