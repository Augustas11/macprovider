package sqlite

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

// ensureRelayBlindSettlementDispatchColumns adds the SPEC-022 R-14 dispatch
// record to quota_reservations. Existing rows default to "" (no response
// recorded), which the reconciler treats as undetermined. The columns and the
// v18 schema stamp commit in one transaction, so a gateway that predates them
// (max-known v17) refuses the migrated database instead of settling a
// relay-blind hold without coordinator finality.
func (s *Store) ensureRelayBlindSettlementDispatchColumns(ctx context.Context) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	rows, err := tx.QueryContext(ctx, `PRAGMA table_info(quota_reservations)`)
	if err != nil {
		return err
	}
	existing := map[string]bool{}
	for rows.Next() {
		var cid, notNull, pk int
		var name, typ string
		var defaultValue sql.NullString
		if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
			rows.Close()
			return err
		}
		existing[name] = true
	}
	if err := rows.Close(); err != nil {
		return err
	}
	for _, column := range []struct{ name, ddl string }{
		{"relay_blind_settlement_mode", "TEXT NOT NULL DEFAULT '' CHECK (relay_blind_settlement_mode IN ('', 'observe', 'enforce'))"},
		{"relay_blind_internal_request_id", "TEXT NOT NULL DEFAULT ''"},
	} {
		if existing[column.name] {
			continue
		}
		if _, err := tx.ExecContext(ctx, `ALTER TABLE quota_reservations ADD COLUMN `+column.name+` `+column.ddl); err != nil {
			return fmt.Errorf("add quota_reservations.%s: %w", column.name, err)
		}
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(18, ?)`,
		encodeTime(time.Now().UTC())); err != nil {
		return fmt.Errorf("stamp schema_migrations v18 inside relay-blind dispatch migration tx: %w", err)
	}
	return tx.Commit()
}

// RecordRelayBlindSettlementDispatch stores, once, the enforce coverage hint
// for an active relay-blind reservation: the coordinator's R-14 coverage
// marker and its internal request id. It is a hint for recovery, which still
// asks the coordinator; no other mode is recorded.
func (s *Store) RecordRelayBlindSettlementDispatch(ctx context.Context, accountID, requestID, mode, internalRequestID string) error {
	if mode != storage.RelayBlindSettlementModeEnforce {
		return fmt.Errorf("invalid relay-blind settlement mode %q", mode)
	}
	if internalRequestID == "" {
		return fmt.Errorf("enforce relay-blind dispatch requires the coordinator internal request id")
	}
	res, err := s.db.ExecContext(ctx, `
		UPDATE quota_reservations
		SET relay_blind_settlement_mode = ?, relay_blind_internal_request_id = ?
		WHERE account_id = ? AND request_id = ? AND status = 'active'
			AND relay_blind_envelope_digest != '' AND relay_blind_settlement_mode = ''`,
		mode, internalRequestID, accountID, requestID)
	if err != nil {
		return err
	}
	if n, err := res.RowsAffected(); err != nil {
		return err
	} else if n == 0 {
		var current string
		err := s.db.QueryRowContext(ctx, `SELECT relay_blind_settlement_mode FROM quota_reservations WHERE account_id = ? AND request_id = ?`, accountID, requestID).Scan(&current)
		if errors.Is(err, sql.ErrNoRows) {
			return storage.ErrReservationNotFound
		}
		return err
	}
	return nil
}
