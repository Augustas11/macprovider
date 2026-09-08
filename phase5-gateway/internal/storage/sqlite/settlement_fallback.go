package sqlite

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

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
	// retries in the same clock tick or after a process restart.
	if _, err := tx.ExecContext(ctx, `INSERT OR REPLACE INTO settlement_reconcile_attempts
		(account_id, request_id, reservation_created_at) VALUES(?, ?, ?)`,
		reservation.AccountID, reservation.RequestID, encodeTime(reservation.CreatedAt.UTC())); err != nil {
		return err
	}
	return tx.Commit()
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
	var reservedTokens int64
	if err := tx.QueryRowContext(ctx, `
		SELECT qr.window_date, qr.created_at, qr.status, qr.reserved_tokens, COALESCE(wrm.session_id, '')
		FROM quota_reservations qr LEFT JOIN wallet_session_request_map wrm
		ON wrm.account_id = qr.account_id AND wrm.request_id = qr.request_id
		WHERE qr.account_id = ? AND qr.request_id = ?`, candidate.AccountID, candidate.RequestID).
		Scan(&window, &createdAt, &status, &reservedTokens, &sessionID); err != nil {
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
	if candidate.MaxTotalTokens > reservedTokens {
		return fmt.Errorf("settlement fallback exceeds reservation")
	}
	existing, err := lookupSettlementFallbackCandidate(ctx, tx, storage.ActiveReservation{
		AccountID: candidate.AccountID, RequestID: candidate.RequestID, CreatedAt: candidate.ReservationCreatedAt,
	})
	if err == nil {
		existing.ReservationCreatedAt = candidate.ReservationCreatedAt
		if existing != candidate {
			return fmt.Errorf("settlement fallback candidate mismatch")
		}
	} else if errors.Is(err, storage.ErrNotFound) {
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO settlement_fallback_candidates(account_id, request_id, required_internal_request_id, reservation_created_at,
				wallet_session_id, demo_identity, demo_token_hash, window_date, prompt_tokens, completion_tokens,
				max_total_tokens, token_source, outcome)
			VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			candidate.AccountID, candidate.RequestID, candidate.RequiredInternalRequestID, createdAt, candidate.WalletSessionID, candidate.DemoIdentity,
			candidate.DemoTokenHash, candidate.WindowDate, candidate.PromptTokens, candidate.CompletionTokens,
			candidate.MaxTotalTokens, candidate.TokenSource, candidate.Outcome); err != nil {
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
	err := q.QueryRowContext(ctx, `
		SELECT c.account_id, c.request_id, c.required_internal_request_id, c.reservation_created_at, c.wallet_session_id,
			c.demo_identity, c.demo_token_hash, c.window_date, c.prompt_tokens, c.completion_tokens,
			c.max_total_tokens, c.token_source, c.outcome
		FROM settlement_fallback_candidates c JOIN quota_reservations qr
		ON qr.account_id = c.account_id AND qr.request_id = c.request_id AND qr.created_at = c.reservation_created_at
		WHERE c.account_id = ? AND c.request_id = ? AND c.reservation_created_at = ? AND qr.status = 'active'`,
		reservation.AccountID, reservation.RequestID, encodeTime(reservation.CreatedAt.UTC())).Scan(
		&candidate.AccountID, &candidate.RequestID, &candidate.RequiredInternalRequestID, &createdAt, &candidate.WalletSessionID,
		&candidate.DemoIdentity, &candidate.DemoTokenHash, &candidate.WindowDate, &candidate.PromptTokens,
		&candidate.CompletionTokens, &candidate.MaxTotalTokens, &candidate.TokenSource, &candidate.Outcome)
	if errors.Is(err, sql.ErrNoRows) {
		return storage.SettlementFallbackCandidate{}, storage.ErrNotFound
	}
	if err != nil {
		return storage.SettlementFallbackCandidate{}, err
	}
	candidate.ReservationCreatedAt = decodeTime(createdAt)
	return candidate, nil
}
