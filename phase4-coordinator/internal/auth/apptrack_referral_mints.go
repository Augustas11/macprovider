package auth

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

// AppTrackRegistrationAttempt identifies the PostgreSQL half of a gated
// registration. AttemptTS is the signed request timestamp and therefore stable
// across transport retries; SourceIP is retained only as diagnostic metadata.
type AppTrackRegistrationAttempt struct {
	SourceIP  string
	Nonce     string
	AttemptTS time.Time
}

type PendingAppTrackReferralMint struct {
	ProviderID string
	TokenHash  string
	Attempt    AppTrackRegistrationAttempt
}

// MintProviderTokenAppTrackWithReferralAttempt validates and redeems the
// referral, commits the client's signed credential candidate, and records an
// exact pending saga in one SQLite transaction. It never rotates an existing
// credential; the client already has custody if the HTTP response is lost.
func (s *Store) MintProviderTokenAppTrackWithReferralAttempt(
	ctx context.Context,
	providerID, referralCode, tokenCandidate string,
	policy ReferralPolicy,
	attempt AppTrackRegistrationAttempt,
) (string, error) {
	if err := config.ValidateProviderID(providerID); err != nil {
		return "", err
	}
	tokenCandidate = strings.TrimSpace(tokenCandidate)
	if !policy.RequireForRegistration || strings.TrimSpace(attempt.SourceIP) == "" ||
		strings.TrimSpace(attempt.Nonce) == "" || attempt.AttemptTS.IsZero() {
		return "", ErrReferralConflict
	}
	if len(tokenCandidate) != 64 || !isLowerHexToken(tokenCandidate) {
		return "", ErrReferralConflict
	}

	var token string
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var active int
		if err := conn.QueryRowContext(ctx, `
SELECT COUNT(1) FROM provider_tokens
 WHERE provider_id = ? AND revoked_at IS NULL`, providerID).Scan(&active); err != nil {
			return err
		}
		if active != 0 {
			return ErrAppTrackExistingTokenNoProof
		}

		now := time.Now().UTC()
		createdRedemption, err := redeemReferralTx(ctx, conn, policy, referralCode, providerID, now)
		if err != nil {
			return err
		}
		hash := tokenHash(tokenCandidate)
		if _, err := conn.ExecContext(ctx, `
INSERT INTO provider_tokens
    (token_hash, token_prefix, provider_id, provider_name, created_at)
VALUES (?, ?, ?, 'malibu-app', ?)`,
			hash, tokenCandidate[:tokenDisplayPrefixLength], providerID, timeText(now),
		); err != nil {
			if isActiveProviderTokenConstraintFailure(err) {
				return ErrActiveTokenAlreadyExists
			}
			return err
		}
		if _, err := conn.ExecContext(ctx, `
INSERT INTO apptrack_pending_referral_mints (
    provider_id, token_hash, campaign, registration_source_ip,
    registration_nonce, registration_attempt_ts, created_redemption, created_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			providerID, hash, policy.Campaign, strings.TrimSpace(attempt.SourceIP),
			strings.TrimSpace(attempt.Nonce), attempt.AttemptTS.UTC().Format(time.RFC3339Nano),
			createdRedemption, timeText(now),
		); err != nil {
			return err
		}
		token = tokenCandidate
		return nil
	})
	if err != nil {
		return "", err
	}
	return token, nil
}

func isLowerHexToken(value string) bool {
	for _, r := range value {
		if (r < '0' || r > '9') && (r < 'a' || r > 'f') {
			return false
		}
	}
	return true
}

// AcknowledgeAppTrackReferralMint removes the saga only after PostgreSQL has
// durably recorded the exact attempt. The token and redemption remain.
func (s *Store) AcknowledgeAppTrackReferralMint(ctx context.Context, providerID, cleartextToken string) error {
	if err := config.ValidateProviderID(providerID); err != nil {
		return err
	}
	cleartextToken = strings.TrimSpace(cleartextToken)
	if cleartextToken == "" {
		return ErrReferralConflict
	}
	result, err := s.db.ExecContext(ctx, `
DELETE FROM apptrack_pending_referral_mints
 WHERE provider_id = ? AND token_hash = ?`, providerID, tokenHash(cleartextToken))
	if err != nil {
		return err
	}
	if changed, err := result.RowsAffected(); err != nil || changed != 1 {
		return ErrReferralConflict
	}
	return nil
}

func (s *Store) RollbackAppTrackReferralMint(ctx context.Context, providerID, cleartextToken string) error {
	if err := config.ValidateProviderID(providerID); err != nil {
		return err
	}
	cleartextToken = strings.TrimSpace(cleartextToken)
	if cleartextToken == "" {
		return ErrReferralConflict
	}
	return s.resolvePendingAppTrackReferralMint(ctx, providerID, tokenHash(cleartextToken), false)
}

func (s *Store) ListPendingAppTrackReferralMints(ctx context.Context, createdBefore time.Time) ([]PendingAppTrackReferralMint, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT provider_id, token_hash, registration_source_ip, registration_nonce, registration_attempt_ts
  FROM apptrack_pending_referral_mints
 WHERE created_at <= ?
 ORDER BY created_at, provider_id`, timeText(createdBefore.UTC()))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var pending []PendingAppTrackReferralMint
	for rows.Next() {
		var item PendingAppTrackReferralMint
		var attemptTS string
		if err := rows.Scan(
			&item.ProviderID, &item.TokenHash, &item.Attempt.SourceIP,
			&item.Attempt.Nonce, &attemptTS,
		); err != nil {
			return nil, err
		}
		item.Attempt.AttemptTS, err = time.Parse(time.RFC3339Nano, attemptTS)
		if err != nil {
			return nil, fmt.Errorf("parse pending App-track attempt timestamp: %w", err)
		}
		pending = append(pending, item)
	}
	return pending, rows.Err()
}

func (s *Store) ResolvePendingAppTrackReferralMint(ctx context.Context, pending PendingAppTrackReferralMint, registrationPrepared bool) error {
	if err := config.ValidateProviderID(pending.ProviderID); err != nil {
		return err
	}
	if strings.TrimSpace(pending.TokenHash) == "" {
		return ErrReferralConflict
	}
	return s.resolvePendingAppTrackReferralMint(ctx, pending.ProviderID, pending.TokenHash, registrationPrepared)
}

func (s *Store) resolvePendingAppTrackReferralMint(ctx context.Context, providerID, expectedTokenHash string, registrationPrepared bool) error {
	return sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var campaign string
		var createdRedemption bool
		if err := conn.QueryRowContext(ctx, `
SELECT campaign, created_redemption
  FROM apptrack_pending_referral_mints
 WHERE provider_id = ? AND token_hash = ?`, providerID, expectedTokenHash,
		).Scan(&campaign, &createdRedemption); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return ErrReferralConflict
			}
			return err
		}
		if registrationPrepared {
			_, err := conn.ExecContext(ctx, `
DELETE FROM apptrack_pending_referral_mints
 WHERE provider_id = ? AND token_hash = ?`, providerID, expectedTokenHash)
			return err
		}

		result, err := conn.ExecContext(ctx, `
DELETE FROM provider_tokens
 WHERE provider_id = ? AND token_hash = ?
   AND provider_name = 'malibu-app'
   AND revoked_at IS NULL AND last_used_at IS NULL`, providerID, expectedTokenHash)
		if err != nil {
			return err
		}
		if changed, err := result.RowsAffected(); err != nil || changed != 1 {
			return ErrReferralConflict
		}
		if createdRedemption {
			result, err = conn.ExecContext(ctx, `
DELETE FROM referral_redemptions
 WHERE campaign = ? AND provider_id = ?`, campaign, providerID)
			if err != nil {
				return err
			}
			if changed, err := result.RowsAffected(); err != nil || changed != 1 {
				return ErrReferralConflict
			}
			if _, err := conn.ExecContext(ctx, `
DELETE FROM provider_referral_admissions
 WHERE campaign = ? AND provider_id = ? AND decision = 'referred'`, campaign, providerID); err != nil {
				return err
			}
		}
		_, err = conn.ExecContext(ctx, `
DELETE FROM apptrack_pending_referral_mints
 WHERE provider_id = ? AND token_hash = ?`, providerID, expectedTokenHash)
		return err
	})
}
