package sqlite

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

// MarkSettlementReconcileAttempt rotates a hold before its remote lookup, so
// unreachable old requests cannot monopolize bounded reconciliation batches.
func (s *Store) MarkSettlementReconcileAttempt(ctx context.Context, reservation storage.ActiveReservation) error {
	if reservation.CreatedAt.IsZero() {
		return storage.ErrReservationNotFound
	}
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var active int
	if err := tx.QueryRowContext(ctx, `SELECT 1 FROM quota_reservations
		WHERE account_id = ? AND request_id = ? AND created_at = ? AND status = 'active' AND settlement_hold = 1`,
		reservation.AccountID, reservation.RequestID, encodeTime(reservation.CreatedAt.UTC())).Scan(&active); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.ErrReservationNotFound
		}
		return err
	}
	// REPLACE intentionally allocates a new AUTOINCREMENT sequence, including
	// retries in the same clock tick or after a process restart. Backlog
	// metadata survives so the due/backoff scheduler keeps its memory.
	createdAt := encodeTime(reservation.CreatedAt.UTC())
	now := encodeTime(time.Now().UTC())
	if _, err := tx.ExecContext(ctx, `INSERT OR REPLACE INTO settlement_reconcile_attempts
		(account_id, request_id, reservation_created_at, attempt_count, first_attempt_at, last_attempt_at,
			first_not_found_at, last_result, next_attempt_after, operator_review, operator_review_reason)
		VALUES(?, ?, ?,
			COALESCE((SELECT attempt_count FROM settlement_reconcile_attempts
				WHERE account_id = ? AND request_id = ? AND reservation_created_at = ?), 0) + 1,
			COALESCE(NULLIF((SELECT first_attempt_at FROM settlement_reconcile_attempts
				WHERE account_id = ? AND request_id = ? AND reservation_created_at = ?), ''), ?),
			?,
			COALESCE((SELECT first_not_found_at FROM settlement_reconcile_attempts
				WHERE account_id = ? AND request_id = ? AND reservation_created_at = ?), ''),
			COALESCE((SELECT last_result FROM settlement_reconcile_attempts
				WHERE account_id = ? AND request_id = ? AND reservation_created_at = ?), ''),
			'',
			COALESCE((SELECT operator_review FROM settlement_reconcile_attempts
				WHERE account_id = ? AND request_id = ? AND reservation_created_at = ?), 0),
			COALESCE((SELECT operator_review_reason FROM settlement_reconcile_attempts
				WHERE account_id = ? AND request_id = ? AND reservation_created_at = ?), ''))`,
		reservation.AccountID, reservation.RequestID, createdAt,
		reservation.AccountID, reservation.RequestID, createdAt,
		reservation.AccountID, reservation.RequestID, createdAt, now,
		now,
		reservation.AccountID, reservation.RequestID, createdAt,
		reservation.AccountID, reservation.RequestID, createdAt,
		reservation.AccountID, reservation.RequestID, createdAt,
		reservation.AccountID, reservation.RequestID, createdAt); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) RecordSettlementReconcileResult(ctx context.Context, reservation storage.ActiveReservation, result string, now time.Time) error {
	if reservation.CreatedAt.IsZero() {
		return storage.ErrReservationNotFound
	}
	if result == "" || len(result) > 128 || strings.TrimSpace(result) != result {
		return fmt.Errorf("invalid settlement reconcile result")
	}
	delay := settlementReconcileBackoffDelay(result, settlementReconcileAttemptCount(ctx, s.db, reservation))
	next := ""
	if delay > 0 {
		next = encodeTime(now.UTC().Add(delay))
	}
	createdAt := encodeTime(reservation.CreatedAt.UTC())
	res, err := s.db.ExecContext(ctx, `UPDATE settlement_reconcile_attempts
		SET last_result = ?, next_attempt_after = ?
		WHERE account_id = ? AND request_id = ? AND reservation_created_at = ?`,
		result, next, reservation.AccountID, reservation.RequestID, createdAt)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return storage.ErrReservationNotFound
	}
	return nil
}

func recordSettlementDrainResultTx(ctx context.Context, tx *immediateTx, accountID, requestID, reservationCreatedAt, result string) error {
	if result == "" {
		return nil
	}
	if len(result) > 128 || strings.TrimSpace(result) != result || reservationCreatedAt == "" {
		return fmt.Errorf("invalid settlement drain reconcile result")
	}
	res, err := tx.ExecContext(ctx, `UPDATE settlement_reconcile_attempts
		SET last_result = ?, next_attempt_after = '', operator_review = 0, operator_review_reason = ''
		WHERE account_id = ? AND request_id = ? AND reservation_created_at = ?`,
		result, accountID, requestID, reservationCreatedAt)
	if err != nil {
		return err
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if rows != 1 {
		return storage.ErrReservationNotFound
	}
	return nil
}

func settlementReconcileAttemptCount(ctx context.Context, q interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}, reservation storage.ActiveReservation) int64 {
	var attempts int64
	_ = q.QueryRowContext(ctx, `SELECT attempt_count FROM settlement_reconcile_attempts
		WHERE account_id = ? AND request_id = ? AND reservation_created_at = ?`,
		reservation.AccountID, reservation.RequestID, encodeTime(reservation.CreatedAt.UTC())).Scan(&attempts)
	return attempts
}

func settlementReconcileBackoffDelay(result string, attempts int64) time.Duration {
	if attempts < 1 {
		attempts = 1
	}
	switch result {
	case "coordinator_404_held":
		return boundedSettlementReconcileBackoff(attempts, 15*time.Minute, 24*time.Hour)
	case "held":
		return boundedSettlementReconcileBackoff(attempts, 5*time.Minute, 6*time.Hour)
	default:
		return 0
	}
}

func boundedSettlementReconcileBackoff(attempts int64, base, max time.Duration) time.Duration {
	shift := attempts - 1
	if shift > 8 {
		shift = 8
	}
	delay := base
	for i := int64(0); i < shift; i++ {
		delay *= 2
		if delay >= max {
			return max
		}
	}
	if delay > max {
		return max
	}
	return delay
}

// RecordSettlementFinalityNotFound sets first_not_found_at the first time
// only and returns the stored value. The attempt row exists because
// MarkSettlementReconcileAttempt runs before every coordinator lookup.
func (s *Store) RecordSettlementFinalityNotFound(ctx context.Context, reservation storage.ActiveReservation, at time.Time) (time.Time, error) {
	if reservation.CreatedAt.IsZero() {
		return time.Time{}, storage.ErrReservationNotFound
	}
	createdAt := encodeTime(reservation.CreatedAt.UTC())
	if _, err := s.db.ExecContext(ctx, `UPDATE settlement_reconcile_attempts SET first_not_found_at = ?
		WHERE account_id = ? AND request_id = ? AND reservation_created_at = ? AND first_not_found_at = ''`,
		encodeTime(at.UTC()), reservation.AccountID, reservation.RequestID, createdAt); err != nil {
		return time.Time{}, err
	}
	var raw string
	if err := s.db.QueryRowContext(ctx, `SELECT first_not_found_at FROM settlement_reconcile_attempts
		WHERE account_id = ? AND request_id = ? AND reservation_created_at = ?`,
		reservation.AccountID, reservation.RequestID, createdAt).Scan(&raw); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return time.Time{}, storage.ErrReservationNotFound
		}
		return time.Time{}, err
	}
	first := decodeTime(raw)
	if first.IsZero() {
		return time.Time{}, fmt.Errorf("settlement reconcile attempt has an unreadable first_not_found_at")
	}
	return first, nil
}

func (s *Store) ClearSettlementFinalityNotFound(ctx context.Context, reservation storage.ActiveReservation) error {
	_, err := s.db.ExecContext(ctx, `UPDATE settlement_reconcile_attempts SET first_not_found_at = ''
		WHERE account_id = ? AND request_id = ? AND reservation_created_at = ? AND first_not_found_at != ''`,
		reservation.AccountID, reservation.RequestID, encodeTime(reservation.CreatedAt.UTC()))
	return err
}

func (s *Store) SaveSettlementFallbackCandidate(ctx context.Context, candidate storage.SettlementFallbackCandidate) error {
	if candidate.ReservationCreatedAt.IsZero() || candidate.MaxTotalTokens <= 0 ||
		len(candidate.RequiredInternalRequestID) > 128 || strings.TrimSpace(candidate.RequiredInternalRequestID) != candidate.RequiredInternalRequestID ||
		(candidate.TokenSource != "provider_reported" && candidate.TokenSource != "gateway_estimated") ||
		candidate.Outcome == "" || len(candidate.Outcome) > 128 ||
		len(candidate.DemoIdentity) > 128 || len(candidate.DemoTokenHash) > 128 ||
		(candidate.DemoIdentity == "") != (candidate.DemoTokenHash == "") ||
		(candidate.WalletSessionID != "" && candidate.DemoTokenHash != "") {
		return fmt.Errorf("invalid settlement fallback candidate")
	}
	usage := storage.ReservationSettlement{
		PromptTokens: candidate.PromptTokens, CompletionTokens: candidate.CompletionTokens, MaxTotalTokens: candidate.MaxTotalTokens,
		RelayBlind: candidate.RelayBlind,
	}
	if err := normalizeSettlementTokens(&usage); err != nil {
		return err
	}
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var window, createdAt, status, sessionID string
	var requested, effective, envelope, keyRecord, kid, providerBinding string
	var inputCap, outputCap int64
	var reservedTokens int64
	if err := tx.QueryRowContext(ctx, `
		SELECT qr.window_date, qr.created_at, qr.status, qr.reserved_tokens, COALESCE(wrm.session_id, ''), `+relayBlindSelectColumns+`
		FROM quota_reservations qr LEFT JOIN wallet_session_request_map wrm
		ON wrm.account_id = qr.account_id AND wrm.request_id = qr.request_id
		WHERE qr.account_id = ? AND qr.request_id = ?`, candidate.AccountID, candidate.RequestID).
		Scan(&window, &createdAt, &status, &reservedTokens, &sessionID, &requested, &effective, &envelope, &keyRecord, &kid, &providerBinding, &inputCap, &outputCap); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.ErrReservationNotFound
		}
		return err
	}
	if createdAt != encodeTime(candidate.ReservationCreatedAt.UTC()) || window != candidate.WindowDate || sessionID != candidate.WalletSessionID {
		return fmt.Errorf("settlement fallback reservation identity mismatch")
	}
	if status != "active" {
		return storage.ErrReservationTerminal
	}
	resolved, err := resolveRelayBlind(relayBlindFromValues(requested, effective, envelope, keyRecord, kid, providerBinding, inputCap, outputCap), candidate.RelayBlind)
	if err != nil {
		return err
	}
	candidate.RelayBlind = resolved
	usage.RelayBlind = resolved
	if err := normalizeSettlementTokens(&usage); err != nil {
		return err
	}
	candidate.PromptTokens, candidate.CompletionTokens = usage.PromptTokens, usage.CompletionTokens
	if candidate.MaxTotalTokens > reservedTokens {
		return fmt.Errorf("settlement fallback exceeds reservation")
	}
	existing, err := lookupSettlementFallbackCandidate(ctx, tx, storage.ActiveReservation{
		AccountID: candidate.AccountID, RequestID: candidate.RequestID, CreatedAt: candidate.ReservationCreatedAt,
	})
	if err == nil {
		existing.ReservationCreatedAt = candidate.ReservationCreatedAt
		if !reflect.DeepEqual(existing, candidate) {
			return fmt.Errorf("settlement fallback candidate mismatch")
		}
	} else if errors.Is(err, storage.ErrNotFound) {
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO settlement_fallback_candidates(account_id, request_id, required_internal_request_id, reservation_created_at,
				wallet_session_id, demo_identity, demo_token_hash, window_date, prompt_tokens, completion_tokens,
				max_total_tokens, token_source, outcome, requested_privacy_mode, effective_privacy_outcome,
				relay_blind_envelope_digest, relay_blind_key_record_digest, relay_blind_kid,
				relay_blind_provider_binding_digest, input_token_upper_bound, max_output_tokens)
			VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			candidate.AccountID, candidate.RequestID, candidate.RequiredInternalRequestID, createdAt, candidate.WalletSessionID, candidate.DemoIdentity,
			candidate.DemoTokenHash, candidate.WindowDate, candidate.PromptTokens, candidate.CompletionTokens,
			candidate.MaxTotalTokens, candidate.TokenSource, candidate.Outcome,
			relayBlindArgs(candidate.RelayBlind)[0], relayBlindArgs(candidate.RelayBlind)[1], relayBlindArgs(candidate.RelayBlind)[2], relayBlindArgs(candidate.RelayBlind)[3],
			relayBlindArgs(candidate.RelayBlind)[4], relayBlindArgs(candidate.RelayBlind)[5], relayBlindArgs(candidate.RelayBlind)[6], relayBlindArgs(candidate.RelayBlind)[7]); err != nil {
			return err
		}
	} else {
		return err
	}
	// Saving usage and making it discoverable for recovery are one write.
	if _, err := tx.ExecContext(ctx, `UPDATE quota_reservations SET settlement_hold = 1
		WHERE account_id = ? AND request_id = ?`, candidate.AccountID, candidate.RequestID); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) LookupSettlementFallbackCandidate(ctx context.Context, reservation storage.ActiveReservation) (storage.SettlementFallbackCandidate, error) {
	return lookupSettlementFallbackCandidate(ctx, s.db, reservation)
}

func lookupSettlementFallbackCandidate(ctx context.Context, q interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}, reservation storage.ActiveReservation) (storage.SettlementFallbackCandidate, error) {
	var candidate storage.SettlementFallbackCandidate
	var createdAt string
	var requested, effective, envelope, keyRecord, kid, providerBinding string
	var inputCap, outputCap int64
	err := q.QueryRowContext(ctx, `
		SELECT c.account_id, c.request_id, c.required_internal_request_id, c.reservation_created_at, c.wallet_session_id,
			c.demo_identity, c.demo_token_hash, c.window_date, c.prompt_tokens, c.completion_tokens,
			c.max_total_tokens, c.token_source, c.outcome,
			c.requested_privacy_mode, c.effective_privacy_outcome, c.relay_blind_envelope_digest,
			c.relay_blind_key_record_digest, c.relay_blind_kid, c.relay_blind_provider_binding_digest,
			c.input_token_upper_bound, c.max_output_tokens
		FROM settlement_fallback_candidates c JOIN quota_reservations qr
		ON qr.account_id = c.account_id AND qr.request_id = c.request_id AND qr.created_at = c.reservation_created_at
		WHERE c.account_id = ? AND c.request_id = ? AND c.reservation_created_at = ? AND qr.status = 'active'`,
		reservation.AccountID, reservation.RequestID, encodeTime(reservation.CreatedAt.UTC())).Scan(
		&candidate.AccountID, &candidate.RequestID, &candidate.RequiredInternalRequestID, &createdAt, &candidate.WalletSessionID,
		&candidate.DemoIdentity, &candidate.DemoTokenHash, &candidate.WindowDate, &candidate.PromptTokens,
		&candidate.CompletionTokens, &candidate.MaxTotalTokens, &candidate.TokenSource, &candidate.Outcome,
		&requested, &effective, &envelope, &keyRecord, &kid, &providerBinding, &inputCap, &outputCap)
	if errors.Is(err, sql.ErrNoRows) {
		return storage.SettlementFallbackCandidate{}, storage.ErrNotFound
	}
	if err != nil {
		return storage.SettlementFallbackCandidate{}, err
	}
	candidate.ReservationCreatedAt = decodeTime(createdAt)
	candidate.RelayBlind = relayBlindFromValues(requested, effective, envelope, keyRecord, kid, providerBinding, inputCap, outputCap)
	return candidate, nil
}
