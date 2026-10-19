package billing

import (
	"context"
	"errors"
	"strings"
)

type RoutingStakeIdentityLookup func(context.Context, string) (int64, error)

// SetRoutingStakeIdentityLookup installs the configured rewards-ledger read.
// Configured source failures propagate; an unconfigured ledger has no link.
func (s *Store) SetRoutingStakeIdentityLookup(lookup RoutingStakeIdentityLookup) {
	if lookup != nil {
		s.routingStakeIdentity.Store(&lookup)
	}
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
		id, err := (*source)(ctx, accountID)
		if err != nil {
			return nil, err
		}
		if id > 0 {
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
	rows, err := s.db.QueryContext(ctx, `SELECT provider_id FROM provider_ownership WHERE github_user_id IN (`+strings.TrimSuffix(strings.Repeat("?,", len(args)), ",")+`)`, args...)
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
	rows, err := s.db.QueryContext(ctx, `SELECT DISTINCT github_user_id FROM allowance_grants WHERE account_id = ? AND github_user_id > 0 LIMIT 129`, accountID)
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
