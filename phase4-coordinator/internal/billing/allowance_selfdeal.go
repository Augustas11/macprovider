package billing

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"sync"
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
// account's allowance request externalRequestID: owned by the GitHub identity
// recorded on the grant of the request's admission day, sharing a payout
// address with a provider that identity owns, or in the same provider-issued
// referral cluster as one. Any lookup failure, a request without an
// allowance hold, a grant without an identity, or a walk that reaches its
// bound counts as self-dealt, so uncertainty never earns MALIBU. Answers are
// memoized per (identity, provider) for a few minutes, so a request's
// attempts and an account's repeated traffic do not repeat the walk.
func (s *Store) AllowanceSelfDealing(ctx context.Context, accountID, externalRequestID, providerID string) bool {
	if accountID == "" || externalRequestID == "" || providerID == "" {
		return true
	}
	var githubUserID int64
	if err := s.db.QueryRowContext(ctx, `
SELECT g.github_user_id
  FROM allowance_reservations r
  JOIN allowance_grants g ON g.account_id = r.account_id AND g.day = r.day
 WHERE r.account_id = ? AND r.request_id = ?`, accountID, externalRequestID).Scan(&githubUserID); err != nil || githubUserID <= 0 {
		return true
	}
	now := time.Now()
	if dealt, ok := s.selfDealMemo.get(githubUserID, providerID, now); ok {
		return dealt
	}
	dealt, err := s.allowanceSelfDealing(ctx, githubUserID, providerID)
	if err != nil {
		return true
	}
	s.selfDealMemo.put(githubUserID, providerID, dealt, now)
	return dealt
}

func (s *Store) allowanceSelfDealing(ctx context.Context, githubUserID int64, providerID string) (bool, error) {
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

const (
	selfDealMemoTTL        = 5 * time.Minute
	selfDealMemoMaxEntries = 10_000
)

type selfDealKey struct {
	githubUserID int64
	providerID   string
}

type selfDealEntry struct {
	dealt bool
	at    time.Time
}

// selfDealMemo caches self-dealing answers briefly. Only answers computed
// without error are stored; failures are never cached.
type selfDealMemo struct {
	mu      sync.Mutex
	entries map[selfDealKey]selfDealEntry
}

func (m *selfDealMemo) get(github int64, provider string, now time.Time) (bool, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	e, ok := m.entries[selfDealKey{github, provider}]
	if !ok || now.Sub(e.at) > selfDealMemoTTL {
		return false, false
	}
	return e.dealt, true
}

func (m *selfDealMemo) put(github int64, provider string, dealt bool, now time.Time) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.entries == nil || len(m.entries) >= selfDealMemoMaxEntries {
		m.entries = map[selfDealKey]selfDealEntry{}
	}
	m.entries[selfDealKey{github, provider}] = selfDealEntry{dealt: dealt, at: now}
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
