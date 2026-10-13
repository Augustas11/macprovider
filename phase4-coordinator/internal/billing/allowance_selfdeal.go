package billing

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// SPEC-050-R010: allowance-funded traffic served by a provider that is
// self-dealing for the staking account earns that provider no MALIBU. The
// check reads provider_ownership, provider_payout_addresses and the SPEC-034
// referral tables, which live in this same coordinator database, read-only.
// It never touches provider credits (SPEC-050-R009).

const (
	selfDealReferralMaxDepth = 8
	selfDealReferralMaxNodes = 256
)

// errSelfDealWalkLimit means the referral walk hit its bound; the attempt is
// then treated as self-dealt.
var errSelfDealWalkLimit = errors.New("allowance: referral cluster walk limit reached")

// AllowanceSelfDealing reports whether providerID is self-dealing for the
// account's allowance on the UTC day of now: owned by the account's GitHub
// identity, sharing a payout address with a provider that identity owns, or
// in the same provider-issued referral cluster as one. Any lookup failure, an
// account without a recorded identity, or a walk that reaches its bound
// counts as self-dealt, so uncertainty never earns MALIBU.
func (s *Store) AllowanceSelfDealing(ctx context.Context, accountID, providerID string, now time.Time) bool {
	dealt, err := s.allowanceSelfDealing(ctx, accountID, providerID, now)
	if err != nil {
		return true
	}
	return dealt
}

func (s *Store) allowanceSelfDealing(ctx context.Context, accountID, providerID string, now time.Time) (bool, error) {
	if accountID == "" || providerID == "" {
		return true, errors.New("allowance: missing account or provider")
	}
	var githubUserID int64
	if err := s.db.QueryRowContext(ctx, `SELECT github_user_id FROM allowance_grants WHERE account_id = ? AND day = ?`,
		accountID, allowanceDay(now)).Scan(&githubUserID); err != nil {
		return true, fmt.Errorf("allowance: grant identity: %w", err)
	}
	if githubUserID <= 0 {
		return true, errors.New("allowance: grant has no identity")
	}
	owned, err := s.ownedProviderSet(ctx, githubUserID)
	if err != nil {
		return true, err
	}
	if owned[providerID] {
		return true, nil
	}
	if len(owned) == 0 {
		// No owned provider: no shared wallet and no cluster to share.
		return false, nil
	}
	sharedWallet, err := s.sharesPayoutAddress(ctx, providerID, githubUserID)
	if err != nil || sharedWallet {
		return true, err
	}
	return s.referralClusterTouches(ctx, providerID, owned)
}

func (s *Store) ownedProviderSet(ctx context.Context, githubUserID int64) (map[string]bool, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT provider_id FROM provider_ownership WHERE github_user_id = ?`, githubUserID)
	if err != nil {
		return nil, fmt.Errorf("allowance: owned providers: %w", err)
	}
	defer rows.Close()
	owned := map[string]bool{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		owned[id] = true
	}
	return owned, rows.Err()
}

func (s *Store) sharesPayoutAddress(ctx context.Context, providerID string, githubUserID int64) (bool, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `
SELECT COUNT(1)
  FROM provider_payout_addresses served
  JOIN provider_payout_addresses mine ON lower(mine.address) = lower(served.address) AND mine.chain = served.chain
  JOIN provider_ownership po ON po.provider_id = mine.provider_id
 WHERE served.provider_id = ? AND po.github_user_id = ?`, providerID, githubUserID).Scan(&n)
	if err != nil {
		return false, fmt.Errorf("allowance: payout address: %w", err)
	}
	return n > 0, nil
}

// referralNeighbors are the providers linked to id by a provider-issued
// referral code, in either direction. Operator seed codes ('S') link nobody.
func (s *Store) referralNeighbors(ctx context.Context, id string) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT ri.provider_id
  FROM referral_redemptions rr
  JOIN referral_issuers ri ON ri.issuer_id = rr.issuer_id
 WHERE rr.provider_id = ? AND ri.code_type = 'P' AND ri.provider_id IS NOT NULL AND ri.provider_id <> ''
UNION
SELECT rr.provider_id
  FROM referral_issuers ri
  JOIN referral_redemptions rr ON rr.issuer_id = ri.issuer_id
 WHERE ri.provider_id = ? AND ri.code_type = 'P'`, id, id)
	if err != nil {
		return nil, fmt.Errorf("allowance: referral edges: %w", err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var n sql.NullString
		if err := rows.Scan(&n); err != nil {
			return nil, err
		}
		if v := strings.TrimSpace(n.String); n.Valid && v != "" {
			out = append(out, v)
		}
	}
	return out, rows.Err()
}

// referralClusterTouches walks the referral cluster of providerID breadth
// first and reports whether it contains a provider in owned.
func (s *Store) referralClusterTouches(ctx context.Context, providerID string, owned map[string]bool) (bool, error) {
	seen := map[string]bool{providerID: true}
	frontier := []string{providerID}
	for depth := 0; depth < selfDealReferralMaxDepth && len(frontier) > 0; depth++ {
		var next []string
		for _, id := range frontier {
			neighbors, err := s.referralNeighbors(ctx, id)
			if err != nil {
				return true, err
			}
			for _, n := range neighbors {
				if owned[n] {
					return true, nil
				}
				if seen[n] {
					continue
				}
				seen[n] = true
				if len(seen) > selfDealReferralMaxNodes {
					return true, errSelfDealWalkLimit
				}
				next = append(next, n)
			}
		}
		frontier = next
	}
	if len(frontier) > 0 {
		// Unexplored providers remain past the depth bound.
		return true, errSelfDealWalkLimit
	}
	return false, nil
}
