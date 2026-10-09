package sqlite

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

// refusalRecordsDDL is the SPEC-006 §5.4.3.3 gateway refusal record table.
// It is additive and independent: an older gateway neither reads nor writes
// it, so it carries no schema-version gate and does not block a rollback.
const refusalRecordsDDL = `
CREATE TABLE IF NOT EXISTS gateway_refusal_records (
	account_id TEXT NOT NULL,
	external_request_id TEXT NOT NULL,
	intent_commitment TEXT NOT NULL CHECK (length(intent_commitment) = 64),
	terminal_kind TEXT NOT NULL CHECK (terminal_kind IN ('pre_quota_refusal', 'post_reservation_refusal')),
	status INTEGER NOT NULL CHECK (status BETWEEN 400 AND 599),
	error_code TEXT NOT NULL,
	forwarded INTEGER NOT NULL CHECK (forwarded IN (0, 1)),
	recorded_at TEXT NOT NULL,
	PRIMARY KEY (account_id, external_request_id),
	CHECK ((terminal_kind = 'pre_quota_refusal' AND forwarded = 0) OR (terminal_kind = 'post_reservation_refusal' AND forwarded = 1))
);
CREATE INDEX IF NOT EXISTS idx_gateway_refusal_records_recorded_at ON gateway_refusal_records(recorded_at);
`

// InsertRefusalRecord stores one refusal record and deletes records older
// than retention. A second record for the same (account, request) keeps the
// first: the first refusal is the one the buyer saw for that request ID.
func (s *Store) InsertRefusalRecord(ctx context.Context, rec storage.RefusalRecord, retention time.Duration) error {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if retention > 0 {
		if _, err := tx.ExecContext(ctx, `DELETE FROM gateway_refusal_records WHERE recorded_at < ?`, encodeTime(rec.RecordedAt.Add(-retention))); err != nil {
			return err
		}
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO gateway_refusal_records
		(account_id, external_request_id, intent_commitment, terminal_kind, status, error_code, forwarded, recorded_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(account_id, external_request_id) DO NOTHING`,
		rec.AccountID, rec.ExternalRequestID, rec.IntentCommitment, rec.TerminalKind, rec.Status, rec.ErrorCode,
		boolInt(rec.Forwarded), encodeTime(rec.RecordedAt)); err != nil {
		return err
	}
	return tx.Commit()
}

// ResolveRefusalRecords reads every key's record with its quota reservation
// and usage rows in one read transaction, so the export signs one
// consistent view. A key without a record fails the whole call.
func (s *Store) ResolveRefusalRecords(ctx context.Context, keys []storage.RefusalRecordKey) ([]storage.ResolvedRefusalRecord, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer rollback(tx)
	out := make([]storage.ResolvedRefusalRecord, 0, len(keys))
	for _, key := range keys {
		var r storage.ResolvedRefusalRecord
		var forwarded int
		var recordedAt string
		err := tx.QueryRowContext(ctx, `SELECT account_id, external_request_id, intent_commitment, terminal_kind, status, error_code, forwarded, recorded_at
			FROM gateway_refusal_records WHERE account_id = ? AND external_request_id = ?`, key.AccountID, key.ExternalRequestID).
			Scan(&r.Record.AccountID, &r.Record.ExternalRequestID, &r.Record.IntentCommitment, &r.Record.TerminalKind,
				&r.Record.Status, &r.Record.ErrorCode, &forwarded, &recordedAt)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, storage.ErrNotFound
		}
		if err != nil {
			return nil, err
		}
		r.Record.Forwarded = forwarded == 1
		r.Record.RecordedAt = decodeTime(recordedAt)
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*), COALESCE(MAX(status), ''), COALESCE(MAX(settled_tokens), 0), COALESCE(MAX(settlement_hold), 0)
			FROM quota_reservations WHERE account_id = ? AND request_id = ?`, key.AccountID, key.ExternalRequestID).
			Scan(&r.ReservationCount, &r.ReservationStatus, &r.ReservationSettled, &r.ReservationHold); err != nil {
			return nil, err
		}
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*), COALESCE(SUM(prompt_tokens + completion_tokens), 0)
			FROM usage_events WHERE account_id = ? AND request_id = ?`, key.AccountID, key.ExternalRequestID).
			Scan(&r.UsageRows, &r.UsageTokens); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, nil
}
