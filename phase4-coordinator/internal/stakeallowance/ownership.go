package stakeallowance

import (
	"context"
	"database/sql"
	"errors"
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
