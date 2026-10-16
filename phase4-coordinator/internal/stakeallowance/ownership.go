package stakeallowance

import (
	"context"
	"database/sql"
	"errors"
	"strings"
)

// ProviderOwnerLookup reads the GitHub owner of a provider from the
// coordinator's provider_ownership table (read-only).
func ProviderOwnerLookup(db *sql.DB) func(ctx context.Context, providerID string) (int64, bool, error) {
	return func(ctx context.Context, providerID string) (int64, bool, error) {
		var githubUserID int64
		err := db.QueryRowContext(ctx, `SELECT github_user_id FROM provider_ownership WHERE provider_id = ?`, providerID).Scan(&githubUserID)
		if errors.Is(err, sql.ErrNoRows) {
			return 0, false, nil
		}
		if err != nil {
			return 0, false, err
		}
		return githubUserID, true, nil
	}
}

// OwnedProviderLookup lists the providers a GitHub identity owns (read-only).
func OwnedProviderLookup(db *sql.DB) func(ctx context.Context, githubUserID int64) ([]string, error) {
	return func(ctx context.Context, githubUserID int64) ([]string, error) {
		rows, err := db.QueryContext(ctx, `SELECT provider_id FROM provider_ownership WHERE github_user_id = ? ORDER BY provider_id`, githubUserID)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		var out []string
		for rows.Next() {
			var id string
			if err := rows.Scan(&id); err != nil {
				return nil, err
			}
			out = append(out, id)
		}
		return out, rows.Err()
	}
}

// PayoutAddressLookup lists the distinct SPEC-016 payout addresses of the
// given providers (read-only).
func PayoutAddressLookup(db *sql.DB) func(ctx context.Context, providerIDs []string) ([]string, error) {
	return func(ctx context.Context, providerIDs []string) ([]string, error) {
		if len(providerIDs) == 0 {
			return nil, nil
		}
		placeholders := strings.TrimSuffix(strings.Repeat("?,", len(providerIDs)), ",")
		args := make([]any, 0, len(providerIDs))
		for _, id := range providerIDs {
			args = append(args, id)
		}
		rows, err := db.QueryContext(ctx, `SELECT DISTINCT lower(address) FROM provider_payout_addresses WHERE provider_id IN (`+placeholders+`) ORDER BY 1`, args...)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		var out []string
		for rows.Next() {
			var addr string
			if err := rows.Scan(&addr); err != nil {
				return nil, err
			}
			out = append(out, addr)
		}
		return out, rows.Err()
	}
}
