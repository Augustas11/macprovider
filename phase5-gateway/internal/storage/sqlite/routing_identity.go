package sqlite

import (
	"context"
	"errors"
	"strconv"
)

// RoutingGitHubIdentities returns every established account link. A bounded
// overflow or malformed stored identity is an error, never an empty success.
func (s *Store) RoutingGitHubIdentities(ctx context.Context, accountID string) ([]int64, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT DISTINCT provider_user_id FROM account_identities WHERE account_id = ? AND provider = 'github' ORDER BY provider_user_id LIMIT 65`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var raw string
		if err := rows.Scan(&raw); err != nil {
			return nil, err
		}
		id, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || id <= 0 || strconv.FormatInt(id, 10) != raw || len(ids) >= 64 {
			return nil, errors.New("invalid routing identity")
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}
