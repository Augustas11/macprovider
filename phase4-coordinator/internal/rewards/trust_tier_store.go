package rewards

import (
	"context"
	"database/sql"
)

type TrustTierStore struct {
	db *sql.DB
}

func NewTrustTierStore(db *sql.DB) *TrustTierStore {
	if db == nil {
		return nil
	}
	return &TrustTierStore{db: db}
}

func (s *TrustTierStore) ProviderTrustTier(ctx context.Context, providerID string) (string, error) {
	return QueryProviderTrustTier(ctx, s.db, providerID)
}

func QueryProviderTrustTier(ctx context.Context, db *sql.DB, providerID string) (string, error) {
	if db == nil {
		return TierProvisional, nil
	}
	var tier string
	err := db.QueryRowContext(ctx, `
        SELECT COALESCE(trust_tier, $2)
          FROM provider_emission_state
         WHERE provider_id = $1
    `, providerID, TierProvisional).Scan(&tier)
	if err == sql.ErrNoRows {
		return TierProvisional, nil
	}
	if err != nil {
		return "", err
	}
	if tier == "" {
		return TierProvisional, nil
	}
	return tier, nil
}
