package sqlite

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

// ensureRelayBlindSettlementDispatchColumns adds the SPEC-022 R-13 dispatch
// record to quota_reservations. Existing rows default to "" (no response
// recorded), which the reconciler treats as undetermined.
func (s *Store) ensureRelayBlindSettlementDispatchColumns(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(quota_reservations)`)
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
		if _, err := s.db.ExecContext(ctx, `ALTER TABLE quota_reservations ADD COLUMN `+column.name+` `+column.ddl); err != nil {
			return fmt.Errorf("add quota_reservations.%s: %w", column.name, err)
		}
	}
	return nil
}

// RecordRelayBlindSettlementDispatch stores the first coverage proof for an
// active relay-blind reservation. An enforce record needs the coordinator
// internal request id. A recorded mode is never overwritten.
func (s *Store) RecordRelayBlindSettlementDispatch(ctx context.Context, accountID, requestID, mode, internalRequestID string) error {
	switch mode {
	case storage.RelayBlindSettlementModeEnforce:
		if internalRequestID == "" {
			return fmt.Errorf("enforce relay-blind dispatch requires the coordinator internal request id")
		}
	case storage.RelayBlindSettlementModeObserve:
		internalRequestID = ""
	default:
		return fmt.Errorf("invalid relay-blind settlement mode %q", mode)
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
