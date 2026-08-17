package rewards

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	_ "modernc.org/sqlite"
)

// PayoutAddress row mirrored from SPEC-016 SQLite.
type PayoutAddress struct {
	ProviderID      string
	Chain           string
	Address         string
	PayoutAllowed   int
	RegisteredAtUTC time.Time
}

func (r *Runner) runWalletMirror(ctx context.Context) error {
	source, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(r.cfg.SQLitePayoutDBPath))
	if err != nil {
		return fmt.Errorf("open payout sqlite: %w", err)
	}
	defer source.Close()
	source.SetMaxOpenConns(1)

	if !tableExists(ctx, source, "provider_payout_addresses") {
		// SPEC-016 payout table not deployed yet — mirror is a no-op.
		return nil
	}

	rows, err := source.QueryContext(ctx, `
        SELECT provider_id, chain, address, payout_allowed, registered_at_utc
          FROM provider_payout_addresses
    `)
	if err != nil {
		return fmt.Errorf("read payout addresses: %w", err)
	}
	defer rows.Close()

	now := time.Now().UTC()
	for rows.Next() {
		var addr PayoutAddress
		var registeredRaw string
		if err := rows.Scan(&addr.ProviderID, &addr.Chain, &addr.Address, &addr.PayoutAllowed, &registeredRaw); err != nil {
			return err
		}
		addr.Address = normalizeAddress(addr.Address)
		reg, err := time.Parse(time.RFC3339, registeredRaw)
		if err != nil {
			reg = now
		}
		addr.RegisteredAtUTC = reg
		if err := r.upsertProjection(ctx, addr, now); err != nil {
			return err
		}
	}
	return rows.Err()
}

func (r *Runner) upsertProjection(ctx context.Context, addr PayoutAddress, now time.Time) error {
	return r.withSerializableRetry(ctx, func(tx *sql.Tx) error {
		var prevAddr sql.NullString
		err := tx.QueryRowContext(ctx, `
            SELECT address FROM provider_payout_addresses_proj
             WHERE provider_id = $1 AND chain = $2
        `, addr.ProviderID, addr.Chain).Scan(&prevAddr)
		firstBind := err == sql.ErrNoRows

		_, err = tx.ExecContext(ctx, `
            INSERT INTO provider_payout_addresses_proj
                (provider_id, chain, address, payout_allowed, registered_at_utc, source_updated_at)
            VALUES ($1, $2, $3, $4, $5, $6)
            ON CONFLICT (provider_id, chain) DO UPDATE SET
                address = EXCLUDED.address,
                payout_allowed = EXCLUDED.payout_allowed,
                registered_at_utc = EXCLUDED.registered_at_utc,
                source_updated_at = EXCLUDED.source_updated_at
        `, addr.ProviderID, addr.Chain, addr.Address, addr.PayoutAllowed, addr.RegisteredAtUTC, now)
		if err != nil {
			return err
		}

		replay := firstBind || (prevAddr.Valid && !strings.EqualFold(prevAddr.String, addr.Address))
		_, err = tx.ExecContext(ctx, `
            INSERT INTO provider_emission_state (provider_id, trust_tier, bound_wallet, cap_replay_pending)
            VALUES ($1, $2, $3, $4)
            ON CONFLICT (provider_id) DO UPDATE SET
                bound_wallet = EXCLUDED.bound_wallet,
                cap_replay_pending = CASE
                    WHEN $4 THEN TRUE
                    ELSE provider_emission_state.cap_replay_pending
                END,
                updated_at = $5
        `, addr.ProviderID, TierProvisional, addr.Address, replay, now)
		if err != nil {
			return err
		}
		if !replay {
			return nil
		}
		_, err = insertRewardAuditEvent(ctx, tx, RewardAuditInsert{
			ProviderID:          addr.ProviderID,
			OccurredAt:          now,
			EventType:           AuditEventWalletBindProjected,
			SafeSummary:         "Payout wallet projection updated; wallet-cap replay is pending.",
			OperatorCorrelation: map[string]string{"chain": addr.Chain},
		})
		return err
	})
}

func normalizeAddress(addr string) string {
	return strings.ToLower(strings.TrimSpace(addr))
}

func tableExists(ctx context.Context, db *sql.DB, name string) bool {
	var n string
	err := db.QueryRowContext(ctx, `
        SELECT name FROM sqlite_master WHERE type='table' AND name = ?
    `, name).Scan(&n)
	return err == nil && n == name
}
