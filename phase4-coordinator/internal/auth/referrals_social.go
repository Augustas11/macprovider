package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

var (
	ErrReferralLocked                = errors.New("provider referral locked until first verified serving")
	ErrReferralQualificationConflict = errors.New("provider serving qualification conflicts with durable state")
	ErrSocialDisabled                = errors.New("social invite bonus disabled")
	ErrSocialChallenge               = errors.New("social challenge invalid")
	ErrSocialRateLimited             = errors.New("social action rate limited")
	ErrSocialRecheckTransient        = errors.New("social recheck transient failure")
)

const (
	SocialStateLocked   = "locked_until_first_serving"
	SocialStateEligible = "eligible"
	SocialStatePending  = "pending"
	SocialStateMatured  = "matured"
	SocialStateFailed   = "failed"
	SocialStateRevoked  = "revoked"

	socialGrantKind          = "x_verified_post"
	socialRecheckLease       = 2 * time.Minute
	socialRecheckBaseBackoff = time.Minute
	socialRecheckMaxBackoff  = time.Hour
)

var socialPrincipalIDPattern = regexp.MustCompile(`^[0-9]{1,24}$`)
var socialShareURLHashPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)
var socialEvidenceIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:/-]{0,191}$`)
var socialActionPattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,31}$`)
var socialAuditTokenPattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,47}$`)

// ProviderReferral is the authoritative provider-invite snapshot. Capacity is
// redemption-only: no public hold or reservation state is represented here.
type ProviderReferral struct {
	Code                       string
	Campaign                   string
	IssuerID                   string
	BaseCapacity               int
	BonusCapacity              int
	Redemptions                int
	Remaining                  int
	SocialState                string
	SocialBonusGrantsRemaining int
	FirstServingSeen           bool
	Revoked                    bool
}

type SocialChallenge struct {
	Cleartext string
	ExpiresAt time.Time
	Code      string
}

func referralSocialSchemaStatements() []string {
	return []string{
		`CREATE TABLE IF NOT EXISTS referral_serving_qualifications (
			campaign TEXT NOT NULL,
			provider_id TEXT NOT NULL,
			evidence_id TEXT NOT NULL,
			evidence_at TEXT NOT NULL,
			qualified_at TEXT NOT NULL,
			issuer_id TEXT NOT NULL REFERENCES referral_issuers(issuer_id),
			PRIMARY KEY(campaign, provider_id),
			UNIQUE(campaign, evidence_id),
			UNIQUE(issuer_id)
		)`,
		`CREATE TABLE IF NOT EXISTS referral_social_challenges (
			challenge_hash TEXT PRIMARY KEY,
			provider_id TEXT NOT NULL,
			campaign TEXT NOT NULL,
			issuer_id TEXT NOT NULL REFERENCES referral_issuers(issuer_id),
			created_at TEXT NOT NULL,
			expires_at TEXT NOT NULL,
			consumed_at TEXT,
			UNIQUE(provider_id, campaign)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_referral_social_challenges_expiry
			ON referral_social_challenges(expires_at)`,
		`CREATE TABLE IF NOT EXISTS referral_social_failures (
			provider_id TEXT NOT NULL,
			campaign TEXT NOT NULL,
			issuer_id TEXT NOT NULL REFERENCES referral_issuers(issuer_id),
			challenge_hash TEXT NOT NULL UNIQUE,
			post_id TEXT NOT NULL,
			author_id TEXT NOT NULL,
			share_url_hash TEXT NOT NULL,
			reason TEXT NOT NULL,
			failed_at TEXT NOT NULL,
			PRIMARY KEY(provider_id, campaign)
		)`,
		`CREATE TABLE IF NOT EXISTS referral_social_verifications (
			provider_id TEXT NOT NULL,
			campaign TEXT NOT NULL,
			issuer_id TEXT NOT NULL REFERENCES referral_issuers(issuer_id),
			challenge_hash TEXT NOT NULL,
			post_id TEXT NOT NULL UNIQUE,
			author_id TEXT NOT NULL,
			share_url_hash TEXT NOT NULL,
			verification_method TEXT NOT NULL,
			submitted_at TEXT NOT NULL,
			pending_since TEXT NOT NULL,
			next_check_at TEXT NOT NULL,
			recheck_attempts INTEGER NOT NULL DEFAULT 0,
			lease_token TEXT,
			lease_until TEXT,
			granted_at TEXT,
			failed_at TEXT,
			PRIMARY KEY(provider_id, campaign),
			CHECK ((lease_token IS NULL) = (lease_until IS NULL))
		)`,
		`CREATE TABLE IF NOT EXISTS referral_social_verification_history (
			archive_id INTEGER PRIMARY KEY AUTOINCREMENT,
			provider_id TEXT NOT NULL,
			campaign TEXT NOT NULL,
			issuer_id TEXT NOT NULL,
			challenge_hash TEXT NOT NULL,
			post_id TEXT NOT NULL UNIQUE,
			author_id TEXT NOT NULL,
			share_url_hash TEXT NOT NULL,
			verification_method TEXT NOT NULL,
			submitted_at TEXT NOT NULL,
			pending_since TEXT NOT NULL,
			granted_at TEXT,
			failed_at TEXT,
			archived_at TEXT NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS referral_social_grants (
			campaign TEXT NOT NULL,
			provider_id TEXT NOT NULL,
			bonus_kind TEXT NOT NULL,
			issuer_id TEXT NOT NULL,
			verification_post_hash TEXT NOT NULL,
			amount INTEGER NOT NULL CHECK(amount > 0),
			granted_at TEXT NOT NULL,
			PRIMARY KEY(campaign, provider_id, bonus_kind)
		)`,
		`CREATE TRIGGER IF NOT EXISTS referral_social_grants_no_update
			BEFORE UPDATE ON referral_social_grants
			BEGIN SELECT RAISE(ABORT, 'referral_social_grants is append-only'); END`,
		`CREATE TRIGGER IF NOT EXISTS referral_social_grants_no_delete
			BEFORE DELETE ON referral_social_grants
			BEGIN SELECT RAISE(ABORT, 'referral_social_grants is append-only'); END`,
		`CREATE TABLE IF NOT EXISTS referral_social_rate_windows (
			campaign TEXT NOT NULL,
			provider_id TEXT NOT NULL,
			action TEXT NOT NULL,
			window_started_at TEXT NOT NULL,
			request_count INTEGER NOT NULL CHECK(request_count > 0),
			PRIMARY KEY(campaign, provider_id, action, window_started_at)
		)`,
		`CREATE TABLE IF NOT EXISTS referral_social_audit (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			campaign TEXT NOT NULL,
			provider_id TEXT NOT NULL,
			issuer_id TEXT,
			event_kind TEXT NOT NULL,
			outcome TEXT NOT NULL,
			subject_hash TEXT NOT NULL DEFAULT '',
			reason TEXT NOT NULL DEFAULT '',
			created_at TEXT NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_referral_social_audit_subject
			ON referral_social_audit(campaign, provider_id, created_at)`,
		`CREATE TRIGGER IF NOT EXISTS referral_social_audit_no_update
			BEFORE UPDATE ON referral_social_audit
			BEGIN SELECT RAISE(ABORT, 'referral_social_audit is append-only'); END`,
		`CREATE TRIGGER IF NOT EXISTS referral_social_audit_no_delete
			BEFORE DELETE ON referral_social_audit
			BEGIN SELECT RAISE(ABORT, 'referral_social_audit is append-only'); END`,
	}
}

// QualifyProviderReferral persists the coordinator-authoritative serving
// evidence and creates the provider issuer in one transaction. Retries are
// idempotent, while an out-of-order earlier authoritative verdict corrects the
// durable evidence tuple without issuing capacity a second time.
func (s *Store) QualifyProviderReferral(ctx context.Context, policy ReferralPolicy, providerID, evidenceID string, servedAt, qualifiedAt time.Time) (ProviderReferral, bool, error) {
	if err := policy.Validate(); err != nil {
		return ProviderReferral{}, false, err
	}
	evidenceID = strings.TrimSpace(evidenceID)
	if err := config.ValidateProviderID(providerID); err != nil || !socialEvidenceIDPattern.MatchString(evidenceID) || servedAt.IsZero() || qualifiedAt.IsZero() {
		return ProviderReferral{}, false, ErrReferralInvalid
	}
	servedAt = servedAt.UTC()
	qualifiedAt = qualifiedAt.UTC()
	if servedAt.After(qualifiedAt) {
		return ProviderReferral{}, false, ErrReferralInvalid
	}

	created := false
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var existingEvidence, existingAt, existingIssuer string
		err := conn.QueryRowContext(ctx, `
SELECT evidence_id, evidence_at, issuer_id
  FROM referral_serving_qualifications
 WHERE campaign = ? AND provider_id = ?`, policy.Campaign, providerID).Scan(&existingEvidence, &existingAt, &existingIssuer)
		if err == nil {
			if existingEvidence == evidenceID {
				return nil
			}
			durableAt, parseErr := time.Parse(time.RFC3339, existingAt)
			if parseErr != nil {
				return parseErr
			}
			if servedAt.After(durableAt) || (servedAt.Equal(durableAt) && evidenceID >= existingEvidence) {
				return nil
			}
			result, updateErr := conn.ExecContext(ctx, `
UPDATE referral_serving_qualifications
   SET evidence_id = ?, evidence_at = ?
 WHERE campaign = ? AND provider_id = ? AND evidence_id = ? AND evidence_at = ?`,
				evidenceID, timeText(servedAt), policy.Campaign, providerID, existingEvidence, existingAt)
			if isConstraintFailure(updateErr) {
				return ErrReferralQualificationConflict
			}
			if updateErr != nil {
				return updateErr
			}
			changed, updateErr := result.RowsAffected()
			if updateErr != nil || changed != 1 {
				return ErrReferralQualificationConflict
			}
			if _, updateErr = conn.ExecContext(ctx, `UPDATE referral_issuers SET first_serving_at = ? WHERE issuer_id = ?`, timeText(servedAt), existingIssuer); updateErr != nil {
				return updateErr
			}
			return recordSocialAuditTx(ctx, conn, policy.Campaign, providerID, existingIssuer, "serving_qualified", "corrected", hashSocialSubject(evidenceID), "earliest_authoritative_evidence", qualifiedAt)
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		var legacyIssuer string
		err = conn.QueryRowContext(ctx, `SELECT issuer_id FROM referral_issuers WHERE campaign = ? AND provider_id = ?`, policy.Campaign, providerID).Scan(&legacyIssuer)
		if err == nil {
			return ErrReferralQualificationConflict
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		issuerID, err := randomReferralID()
		if err != nil {
			return err
		}
		_, err = conn.ExecContext(ctx, `
INSERT INTO referral_issuers (
    issuer_id, code_type, key_id, campaign, provider_id,
    base_capacity, bonus_capacity, created_at, first_serving_at
) VALUES (?, 'P', ?, ?, ?, ?, 0, ?, ?)`,
			issuerID, policy.CurrentKeyID, policy.Campaign, providerID,
			policy.ProviderBaseUses, timeText(qualifiedAt), timeText(servedAt))
		if err != nil {
			return err
		}
		_, err = conn.ExecContext(ctx, `
INSERT INTO referral_serving_qualifications (
    campaign, provider_id, evidence_id, evidence_at, qualified_at, issuer_id
) VALUES (?, ?, ?, ?, ?, ?)`,
			policy.Campaign, providerID, evidenceID, timeText(servedAt), timeText(qualifiedAt), issuerID)
		if isConstraintFailure(err) {
			return ErrReferralQualificationConflict
		}
		if err != nil {
			return err
		}
		if err := recordSocialAuditTx(ctx, conn, policy.Campaign, providerID, issuerID, "serving_qualified", "accepted", hashSocialSubject(evidenceID), "authoritative_evidence", qualifiedAt); err != nil {
			return err
		}
		created = true
		return nil
	})
	if err != nil {
		return ProviderReferral{}, false, err
	}
	status, err := s.ProviderReferralStatus(ctx, policy, providerID)
	return status, created, err
}

func (s *Store) ProviderReferralStatus(ctx context.Context, policy ReferralPolicy, providerID string) (ProviderReferral, error) {
	if err := policy.Validate(); err != nil {
		return ProviderReferral{}, err
	}
	if err := config.ValidateProviderID(providerID); err != nil {
		return ProviderReferral{}, ErrReferralInvalid
	}

	out := ProviderReferral{Campaign: policy.Campaign, SocialState: SocialStateLocked}
	var keyID, evidenceAt string
	var revokedAt sql.NullString
	err := s.db.QueryRowContext(ctx, `
SELECT i.issuer_id, i.key_id, i.base_capacity, i.bonus_capacity, q.evidence_at, i.revoked_at
  FROM referral_serving_qualifications q
  JOIN referral_issuers i ON i.issuer_id = q.issuer_id
 WHERE q.provider_id = ? AND q.campaign = ?`, providerID, policy.Campaign).Scan(
		&out.IssuerID, &keyID, &out.BaseCapacity, &out.BonusCapacity, &evidenceAt, &revokedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return out, ErrReferralLocked
	}
	if err != nil {
		return ProviderReferral{}, err
	}
	out.FirstServingSeen = strings.TrimSpace(evidenceAt) != ""
	if revokedAt.Valid {
		out.SocialState = SocialStateRevoked
		out.Revoked = true
		return out, nil
	}
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(1) FROM referral_redemptions WHERE issuer_id = ?`, out.IssuerID).Scan(&out.Redemptions); err != nil {
		return ProviderReferral{}, err
	}
	out.Remaining = out.BaseCapacity + out.BonusCapacity - out.Redemptions
	if out.Remaining < 0 {
		out.Remaining = 0
	}
	grantCount, err := s.socialGrantCount(ctx, policy.Campaign, providerID)
	if err != nil {
		return ProviderReferral{}, err
	}
	if policy.EnableSocialBonus {
		out.SocialBonusGrantsRemaining = policy.SocialBonusMaxGrants - grantCount
		if out.SocialBonusGrantsRemaining < 0 {
			out.SocialBonusGrantsRemaining = 0
		}
	}
	out.Code, err = EncodeReferralCode(policy, ReferralTypeProvider, keyID, out.IssuerID)
	if err != nil {
		return ProviderReferral{}, err
	}

	var grantedAt, failedAt sql.NullString
	err = s.db.QueryRowContext(ctx, `
SELECT granted_at, failed_at FROM referral_social_verifications
 WHERE provider_id = ? AND campaign = ?`, providerID, policy.Campaign).Scan(&grantedAt, &failedAt)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		var terminalFailure bool
		if err := s.db.QueryRowContext(ctx, `
SELECT EXISTS(
    SELECT 1 FROM referral_social_failures
     WHERE provider_id = ? AND campaign = ?
)`, providerID, policy.Campaign).Scan(&terminalFailure); err != nil {
			return ProviderReferral{}, err
		}
		if terminalFailure {
			out.SocialState = SocialStateFailed
		} else {
			if grantCount > 0 {
				out.SocialState = SocialStateMatured
			} else {
				out.SocialState = SocialStateEligible
			}
		}
	case err != nil:
		return ProviderReferral{}, err
	case grantedAt.Valid:
		out.SocialState = SocialStateMatured
	case failedAt.Valid:
		out.SocialState = SocialStateFailed
	default:
		out.SocialState = SocialStatePending
	}
	return out, nil
}

// ConsumeSocialRateLimit atomically consumes a provider/action slot in a
// durable fixed window. Denials are committed and audited, so process restarts
// and multiple coordinator instances cannot reset the provider limit.
func (s *Store) ConsumeSocialRateLimit(ctx context.Context, policy ReferralPolicy, providerID, action string, now time.Time, window time.Duration, limit int) (bool, error) {
	if err := policy.Validate(); err != nil {
		return false, err
	}
	action = strings.TrimSpace(action)
	if err := config.ValidateProviderID(providerID); err != nil || !socialActionPattern.MatchString(action) || now.IsZero() || window <= 0 || limit <= 0 {
		return false, ErrReferralInvalid
	}
	windowSeconds := int64(window / time.Second)
	if windowSeconds <= 0 {
		return false, ErrReferralInvalid
	}
	startedAt := time.Unix((now.UTC().Unix()/windowSeconds)*windowSeconds, 0).UTC()
	allowed := false
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		if _, err := conn.ExecContext(ctx, `
DELETE FROM referral_social_rate_windows
 WHERE campaign = ? AND provider_id = ? AND action = ? AND window_started_at < ?`,
			policy.Campaign, providerID, action, timeText(now.UTC().Add(-24*time.Hour))); err != nil {
			return err
		}
		var issuerID sql.NullString
		_ = conn.QueryRowContext(ctx, `SELECT issuer_id FROM referral_serving_qualifications WHERE campaign = ? AND provider_id = ?`, policy.Campaign, providerID).Scan(&issuerID)
		result, err := conn.ExecContext(ctx, `
INSERT INTO referral_social_rate_windows (campaign, provider_id, action, window_started_at, request_count)
VALUES (?, ?, ?, ?, 1)
ON CONFLICT(campaign, provider_id, action, window_started_at) DO UPDATE
   SET request_count = request_count + 1
 WHERE request_count < ?`, policy.Campaign, providerID, action, timeText(startedAt), limit)
		if err != nil {
			return err
		}
		changed, err := result.RowsAffected()
		if err != nil {
			return err
		}
		allowed = changed == 1
		if !allowed {
			return recordSocialAuditTx(ctx, conn, policy.Campaign, providerID, issuerID.String, "rate_limit", "denied", hashSocialSubject(action+"|"+timeText(startedAt)), action, now)
		}
		return nil
	})
	return allowed, err
}

func (s *Store) CreateSocialChallenge(ctx context.Context, policy ReferralPolicy, providerID string, now time.Time) (SocialChallenge, error) {
	if err := policy.Validate(); err != nil {
		return SocialChallenge{}, err
	}
	if !policy.EnableSocialBonus {
		return SocialChallenge{}, ErrSocialDisabled
	}
	if err := config.ValidateProviderID(providerID); err != nil || now.IsZero() {
		return SocialChallenge{}, ErrSocialChallenge
	}
	cleartext, err := randomHex(32)
	if err != nil {
		return SocialChallenge{}, err
	}
	digest := sha256.Sum256([]byte(cleartext))
	digestText := fmt.Sprintf("%x", digest[:])
	expiresAt := now.UTC().Add(policy.ChallengeTTL)
	var code string
	err = sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var issuerID, keyID string
		if err := conn.QueryRowContext(ctx, `
SELECT i.issuer_id, i.key_id
  FROM referral_serving_qualifications q
  JOIN referral_issuers i ON i.issuer_id = q.issuer_id
 WHERE q.provider_id = ? AND q.campaign = ? AND i.code_type = 'P' AND i.revoked_at IS NULL`, providerID, policy.Campaign).Scan(&issuerID, &keyID); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return ErrReferralLocked
			}
			return err
		}
		var grantedAt, failedAt sql.NullString
		err := conn.QueryRowContext(ctx, `SELECT granted_at, failed_at FROM referral_social_verifications WHERE provider_id = ? AND campaign = ?`, providerID, policy.Campaign).Scan(&grantedAt, &failedAt)
		switch {
		case errors.Is(err, sql.ErrNoRows):
		case err != nil:
			return err
		case !grantedAt.Valid && !failedAt.Valid:
			return ErrSocialChallenge
		default:
			if err := archiveTerminalVerificationTx(ctx, conn, providerID, policy.Campaign, now); err != nil {
				return err
			}
		}
		grantCount, err := socialGrantCountTx(ctx, conn, policy.Campaign, providerID)
		if err != nil {
			return err
		}
		if grantCount >= policy.SocialBonusMaxGrants {
			return ErrSocialChallenge
		}
		if _, err := conn.ExecContext(ctx, `
DELETE FROM referral_social_failures
 WHERE provider_id = ? AND campaign = ?`, providerID, policy.Campaign); err != nil {
			return err
		}
		if _, err := conn.ExecContext(ctx, `DELETE FROM referral_social_challenges WHERE provider_id = ? AND campaign = ?`, providerID, policy.Campaign); err != nil {
			return err
		}
		if _, err := conn.ExecContext(ctx, `
INSERT INTO referral_social_challenges (challenge_hash, provider_id, campaign, issuer_id, created_at, expires_at)
VALUES (?, ?, ?, ?, ?, ?)`, digestText, providerID, policy.Campaign, issuerID, timeText(now.UTC()), timeText(expiresAt)); err != nil {
			return err
		}
		if err := recordSocialAuditTx(ctx, conn, policy.Campaign, providerID, issuerID, "challenge", "created", digestText, "", now); err != nil {
			return err
		}
		code, err = EncodeReferralCode(policy, ReferralTypeProvider, keyID, issuerID)
		return err
	})
	if err != nil {
		return SocialChallenge{}, err
	}
	return SocialChallenge{Cleartext: cleartext, ExpiresAt: expiresAt, Code: code}, nil
}

func (s *Store) socialGrantCount(ctx context.Context, campaign, providerID string) (int, error) {
	var count int
	err := s.db.QueryRowContext(ctx, `
SELECT COUNT(1)
  FROM referral_social_grants
 WHERE campaign = ? AND provider_id = ?
   AND (bonus_kind = ? OR bonus_kind GLOB ?)`, campaign, providerID, socialGrantKind, socialGrantKind+":*").Scan(&count)
	return count, err
}

func socialGrantCountTx(ctx context.Context, conn *sql.Conn, campaign, providerID string) (int, error) {
	var count int
	err := conn.QueryRowContext(ctx, `
SELECT COUNT(1)
  FROM referral_social_grants
 WHERE campaign = ? AND provider_id = ?
   AND (bonus_kind = ? OR bonus_kind GLOB ?)`, campaign, providerID, socialGrantKind, socialGrantKind+":*").Scan(&count)
	return count, err
}

func archiveTerminalVerificationTx(ctx context.Context, conn *sql.Conn, providerID, campaign string, now time.Time) error {
	result, err := conn.ExecContext(ctx, `
INSERT INTO referral_social_verification_history (
    provider_id, campaign, issuer_id, challenge_hash, post_id, author_id, share_url_hash,
    verification_method, submitted_at, pending_since, granted_at, failed_at, archived_at
)
SELECT provider_id, campaign, issuer_id, challenge_hash, post_id, author_id, share_url_hash,
       verification_method, submitted_at, pending_since, granted_at,
       COALESCE(failed_at, granted_at, ?), ?
  FROM referral_social_verifications
 WHERE provider_id = ? AND campaign = ? AND (granted_at IS NOT NULL OR failed_at IS NOT NULL)`, timeText(now.UTC()), timeText(now.UTC()), providerID, campaign)
	if err != nil {
		return err
	}
	changed, err := result.RowsAffected()
	if err != nil || changed != 1 {
		return ErrSocialChallenge
	}
	result, err = conn.ExecContext(ctx, `DELETE FROM referral_social_verifications WHERE provider_id = ? AND campaign = ? AND (granted_at IS NOT NULL OR failed_at IS NOT NULL)`, providerID, campaign)
	if err != nil {
		return err
	}
	changed, err = result.RowsAffected()
	if err != nil || changed != 1 {
		return ErrSocialChallenge
	}
	return nil
}

func (s *Store) ValidateSocialChallenge(ctx context.Context, policy ReferralPolicy, providerID, challenge string, now time.Time) error {
	if err := policy.Validate(); err != nil {
		return err
	}
	if !policy.EnableSocialBonus {
		return ErrSocialDisabled
	}
	digest := sha256.Sum256([]byte(strings.TrimSpace(challenge)))
	var expiresAt string
	var consumedAt sql.NullString
	err := s.db.QueryRowContext(ctx, `
SELECT c.expires_at, c.consumed_at
  FROM referral_social_challenges c
  JOIN referral_serving_qualifications q ON q.issuer_id = c.issuer_id AND q.provider_id = c.provider_id AND q.campaign = c.campaign
  JOIN referral_issuers i ON i.issuer_id = q.issuer_id AND i.revoked_at IS NULL
 WHERE c.challenge_hash = ? AND c.provider_id = ? AND c.campaign = ?`, fmt.Sprintf("%x", digest[:]), providerID, policy.Campaign).Scan(&expiresAt, &consumedAt)
	if err != nil {
		return ErrSocialChallenge
	}
	expires, err := time.Parse(time.RFC3339, expiresAt)
	if err != nil || consumedAt.Valid || !expires.After(now.UTC()) {
		return ErrSocialChallenge
	}
	return nil
}

// PreflightSocialVerification authorizes a challenge before any external X
// request. An exact response-loss retry is recovered from durable state and
// audited without spending external verifier quota.
func (s *Store) PreflightSocialVerification(ctx context.Context, policy ReferralPolicy, providerID, challenge, postID string, now time.Time) (ProviderReferral, bool, error) {
	if err := policy.Validate(); err != nil {
		return ProviderReferral{}, false, err
	}
	if !policy.EnableSocialBonus {
		return ProviderReferral{}, false, ErrSocialDisabled
	}
	challenge = strings.TrimSpace(challenge)
	postID = strings.TrimSpace(postID)
	if err := config.ValidateProviderID(providerID); err != nil || len(challenge) != 64 || !socialPrincipalIDPattern.MatchString(postID) || now.IsZero() {
		return ProviderReferral{}, false, ErrSocialChallenge
	}
	digest := sha256.Sum256([]byte(challenge))
	digestText := fmt.Sprintf("%x", digest[:])
	replayed := false
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var issuerID, expiresAt string
		var consumedAt sql.NullString
		if err := conn.QueryRowContext(ctx, `
SELECT c.issuer_id, c.expires_at, c.consumed_at
  FROM referral_social_challenges c
  JOIN referral_serving_qualifications q ON q.issuer_id = c.issuer_id AND q.provider_id = c.provider_id AND q.campaign = c.campaign
  JOIN referral_issuers i ON i.issuer_id = q.issuer_id AND i.revoked_at IS NULL
 WHERE c.challenge_hash = ? AND c.provider_id = ? AND c.campaign = ?`, digestText, providerID, policy.Campaign).Scan(&issuerID, &expiresAt, &consumedAt); err != nil {
			return ErrSocialChallenge
		}
		if consumedAt.Valid {
			var storedIssuer, storedChallenge, storedPost string
			err := conn.QueryRowContext(ctx, `
SELECT issuer_id, challenge_hash, post_id
  FROM referral_social_verifications
 WHERE provider_id = ? AND campaign = ?`, providerID, policy.Campaign).Scan(&storedIssuer, &storedChallenge, &storedPost)
			if errors.Is(err, sql.ErrNoRows) {
				err = conn.QueryRowContext(ctx, `
SELECT issuer_id, challenge_hash, post_id
  FROM referral_social_failures
 WHERE provider_id = ? AND campaign = ?`, providerID, policy.Campaign).Scan(&storedIssuer, &storedChallenge, &storedPost)
			}
			if err != nil || storedIssuer != issuerID || storedChallenge != digestText || storedPost != postID {
				return ErrSocialChallenge
			}
			replayed = true
			return recordSocialAuditTx(ctx, conn, policy.Campaign, providerID, issuerID, "submission", "replayed", hashSocialSubject(postID), "response_loss_recovery", now)
		}
		expires, err := time.Parse(time.RFC3339, expiresAt)
		if err != nil || !expires.After(now.UTC()) {
			return ErrSocialChallenge
		}
		return nil
	})
	if err != nil {
		return ProviderReferral{}, false, err
	}
	if !replayed {
		return ProviderReferral{}, false, nil
	}
	status, err := s.ProviderReferralStatus(ctx, policy, providerID)
	return status, true, err
}

func (s *Store) CompleteSocialVerification(ctx context.Context, policy ReferralPolicy, providerID, challenge, postID, authorID, shareURLHash, method string, now time.Time) (ProviderReferral, error) {
	if err := policy.Validate(); err != nil {
		return ProviderReferral{}, err
	}
	if !policy.EnableSocialBonus {
		return ProviderReferral{}, ErrSocialDisabled
	}
	postID = strings.TrimSpace(postID)
	authorID = strings.TrimSpace(authorID)
	shareURLHash = strings.TrimSpace(shareURLHash)
	method = strings.TrimSpace(method)
	if !socialPrincipalIDPattern.MatchString(postID) || !socialPrincipalIDPattern.MatchString(authorID) || !socialShareURLHashPattern.MatchString(shareURLHash) || method != "x_api" || now.IsZero() {
		return ProviderReferral{}, ErrSocialChallenge
	}
	digest := sha256.Sum256([]byte(strings.TrimSpace(challenge)))
	digestText := fmt.Sprintf("%x", digest[:])
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var issuerID, expiresAt string
		var consumedAt sql.NullString
		if err := conn.QueryRowContext(ctx, `
SELECT c.issuer_id, c.expires_at, c.consumed_at
  FROM referral_social_challenges c
  JOIN referral_serving_qualifications q ON q.issuer_id = c.issuer_id AND q.provider_id = c.provider_id AND q.campaign = c.campaign
  JOIN referral_issuers i ON i.issuer_id = q.issuer_id AND i.revoked_at IS NULL
 WHERE c.challenge_hash = ? AND c.provider_id = ? AND c.campaign = ?`, digestText, providerID, policy.Campaign).Scan(&issuerID, &expiresAt, &consumedAt); err != nil {
			return ErrSocialChallenge
		}
		if consumedAt.Valid {
			var storedIssuer, storedChallenge, storedPost, storedAuthor, storedShare, storedMethod string
			err := conn.QueryRowContext(ctx, `
SELECT issuer_id, challenge_hash, post_id, author_id, share_url_hash, verification_method
  FROM referral_social_verifications WHERE provider_id = ? AND campaign = ?`, providerID, policy.Campaign).Scan(&storedIssuer, &storedChallenge, &storedPost, &storedAuthor, &storedShare, &storedMethod)
			if err == nil && storedIssuer == issuerID && storedChallenge == digestText && storedPost == postID && storedAuthor == authorID && storedShare == shareURLHash && storedMethod == method {
				return recordSocialAuditTx(ctx, conn, policy.Campaign, providerID, issuerID, "submission", "replayed", hashSocialSubject(postID), "response_loss_recovery", now)
			}
			return ErrSocialChallenge
		}
		expires, err := time.Parse(time.RFC3339, expiresAt)
		if err != nil || !expires.After(now.UTC()) {
			return ErrSocialChallenge
		}
		var archivedPost bool
		if err := conn.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM referral_social_verification_history WHERE post_id = ?)`, postID).Scan(&archivedPost); err != nil {
			return err
		}
		if archivedPost {
			return ErrSocialChallenge
		}
		if _, err := conn.ExecContext(ctx, `
INSERT INTO referral_social_verifications (
    provider_id, campaign, issuer_id, challenge_hash, post_id, author_id, share_url_hash,
    verification_method, submitted_at, pending_since, next_check_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, providerID, policy.Campaign, issuerID, digestText, postID, authorID, shareURLHash, method, timeText(now.UTC()), timeText(now.UTC()), timeText(now.UTC().Add(policy.SocialVerificationDwell))); err != nil {
			if isConstraintFailure(err) {
				return ErrSocialChallenge
			}
			return err
		}
		result, err := conn.ExecContext(ctx, `UPDATE referral_social_challenges SET consumed_at = ? WHERE challenge_hash = ? AND consumed_at IS NULL`, timeText(now.UTC()), digestText)
		if err != nil {
			return err
		}
		changed, err := result.RowsAffected()
		if err != nil || changed != 1 {
			return ErrSocialChallenge
		}
		if err := recordSocialAuditTx(ctx, conn, policy.Campaign, providerID, issuerID, "external_verify", "verified", hashSocialSubject(postID), "x_api", now); err != nil {
			return err
		}
		return recordSocialAuditTx(ctx, conn, policy.Campaign, providerID, issuerID, "submission", "accepted", hashSocialSubject(postID), "x_api", now)
	})
	if err != nil {
		return ProviderReferral{}, err
	}
	return s.ProviderReferralStatus(ctx, policy, providerID)
}

// FailSocialVerification consumes a terminally classified submission and
// persists the failed state in the same transaction as its redacted decision
// audit. An exact response-loss retry then recovers the failed status without
// calling the external verifier again.
func (s *Store) FailSocialVerification(ctx context.Context, policy ReferralPolicy, providerID, challenge, postID, authorID, shareURLHash, reason string, now time.Time) (ProviderReferral, error) {
	if err := policy.Validate(); err != nil {
		return ProviderReferral{}, err
	}
	if !policy.EnableSocialBonus {
		return ProviderReferral{}, ErrSocialDisabled
	}
	postID = strings.TrimSpace(postID)
	authorID = strings.TrimSpace(authorID)
	shareURLHash = strings.TrimSpace(shareURLHash)
	reason = strings.TrimSpace(reason)
	if err := config.ValidateProviderID(providerID); err != nil ||
		!socialPrincipalIDPattern.MatchString(postID) ||
		(authorID != "" && !socialPrincipalIDPattern.MatchString(authorID)) ||
		!socialShareURLHashPattern.MatchString(shareURLHash) ||
		!socialAuditTokenPattern.MatchString(reason) ||
		now.IsZero() {
		return ProviderReferral{}, ErrSocialChallenge
	}
	digest := sha256.Sum256([]byte(strings.TrimSpace(challenge)))
	digestText := fmt.Sprintf("%x", digest[:])
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var issuerID, expiresAt string
		var consumedAt sql.NullString
		if err := conn.QueryRowContext(ctx, `
SELECT c.issuer_id, c.expires_at, c.consumed_at
  FROM referral_social_challenges c
  JOIN referral_serving_qualifications q ON q.issuer_id = c.issuer_id AND q.provider_id = c.provider_id AND q.campaign = c.campaign
  JOIN referral_issuers i ON i.issuer_id = q.issuer_id AND i.revoked_at IS NULL
 WHERE c.challenge_hash = ? AND c.provider_id = ? AND c.campaign = ?`, digestText, providerID, policy.Campaign).Scan(&issuerID, &expiresAt, &consumedAt); err != nil {
			return ErrSocialChallenge
		}
		if consumedAt.Valid {
			var storedIssuer, storedChallenge, storedPost, storedAuthor, storedShare string
			err := conn.QueryRowContext(ctx, `
SELECT issuer_id, challenge_hash, post_id, author_id, share_url_hash
  FROM referral_social_failures
 WHERE provider_id = ? AND campaign = ?`, providerID, policy.Campaign).Scan(
				&storedIssuer, &storedChallenge, &storedPost, &storedAuthor, &storedShare,
			)
			if err == nil && storedIssuer == issuerID && storedChallenge == digestText &&
				storedPost == postID && storedAuthor == authorID && storedShare == shareURLHash {
				return nil
			}
			return ErrSocialChallenge
		}
		expires, err := time.Parse(time.RFC3339, expiresAt)
		if err != nil || !expires.After(now.UTC()) {
			return ErrSocialChallenge
		}
		if _, err := conn.ExecContext(ctx, `
INSERT INTO referral_social_failures (
    provider_id, campaign, issuer_id, challenge_hash, post_id, author_id,
    share_url_hash, reason, failed_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			providerID, policy.Campaign, issuerID, digestText, postID, authorID,
			shareURLHash, reason, timeText(now.UTC())); err != nil {
			if isConstraintFailure(err) {
				return ErrSocialChallenge
			}
			return err
		}
		result, err := conn.ExecContext(ctx, `
UPDATE referral_social_challenges SET consumed_at = ?
 WHERE challenge_hash = ? AND consumed_at IS NULL`, timeText(now.UTC()), digestText)
		if err != nil {
			return err
		}
		changed, err := result.RowsAffected()
		if err != nil || changed != 1 {
			return ErrSocialChallenge
		}
		return recordSocialAuditTx(ctx, conn, policy.Campaign, providerID, issuerID, "external_verify", "terminal", hashSocialSubject(postID), reason, now)
	})
	if err != nil {
		return ProviderReferral{}, err
	}
	return s.ProviderReferralStatus(ctx, policy, providerID)
}

type socialRecheckClaim struct {
	providerID, issuerID, postID, authorID, shareURLHash, leaseToken string
	attempts                                                         int
}

func (s *Store) PromoteMaturedSocialVerifications(ctx context.Context, policy ReferralPolicy, now time.Time, recheck func(context.Context, string, string, string) error) (int, error) {
	if err := policy.Validate(); err != nil {
		return 0, err
	}
	if !policy.EnableSocialBonus || recheck == nil {
		return 0, nil
	}
	granted := 0
	for range 64 {
		claim, ok, err := s.claimSocialRecheck(ctx, policy, now)
		if err != nil {
			return granted, err
		}
		if !ok {
			break
		}
		checkErr := recheck(ctx, claim.postID, claim.authorID, claim.shareURLHash)
		wasGranted, err := s.finishSocialRecheck(ctx, policy, now, claim, checkErr)
		if err != nil {
			return granted, err
		}
		if wasGranted {
			granted++
		}
	}
	return granted, nil
}

func (s *Store) claimSocialRecheck(ctx context.Context, policy ReferralPolicy, now time.Time) (socialRecheckClaim, bool, error) {
	var claim socialRecheckClaim
	claimed := false
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		err := conn.QueryRowContext(ctx, `
SELECT v.provider_id, v.issuer_id, v.post_id, v.author_id, v.share_url_hash, v.recheck_attempts
  FROM referral_social_verifications v
  JOIN referral_serving_qualifications q ON q.provider_id = v.provider_id AND q.campaign = v.campaign AND q.issuer_id = v.issuer_id
  JOIN referral_issuers i ON i.issuer_id = v.issuer_id AND i.revoked_at IS NULL
 WHERE v.campaign = ? AND v.granted_at IS NULL AND v.failed_at IS NULL
   AND v.pending_since <= ? AND v.next_check_at <= ?
   AND (v.lease_until IS NULL OR v.lease_until <= ?)
 ORDER BY v.next_check_at, v.pending_since, v.provider_id LIMIT 1`, policy.Campaign, timeText(now.UTC().Add(-policy.SocialVerificationDwell)), timeText(now.UTC()), timeText(now.UTC())).Scan(&claim.providerID, &claim.issuerID, &claim.postID, &claim.authorID, &claim.shareURLHash, &claim.attempts)
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		claim.leaseToken, err = randomHex(16)
		if err != nil {
			return err
		}
		result, err := conn.ExecContext(ctx, `
UPDATE referral_social_verifications SET lease_token = ?, lease_until = ?
 WHERE provider_id = ? AND campaign = ? AND issuer_id = ?
   AND granted_at IS NULL AND failed_at IS NULL AND (lease_until IS NULL OR lease_until <= ?)`, claim.leaseToken, timeText(now.UTC().Add(socialRecheckLease)), claim.providerID, policy.Campaign, claim.issuerID, timeText(now.UTC()))
		if err != nil {
			return err
		}
		changed, err := result.RowsAffected()
		if err != nil {
			return err
		}
		if changed != 1 {
			return nil
		}
		claimed = true
		return recordSocialAuditTx(ctx, conn, policy.Campaign, claim.providerID, claim.issuerID, "recheck", "claimed", hashSocialSubject(claim.postID), "", now)
	})
	return claim, claimed, err
}

func (s *Store) finishSocialRecheck(ctx context.Context, policy ReferralPolicy, now time.Time, claim socialRecheckClaim, checkErr error) (bool, error) {
	granted := false
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		if errors.Is(checkErr, ErrSocialRecheckTransient) {
			backoff := socialRecheckBackoff(claim.attempts + 1)
			result, err := conn.ExecContext(ctx, `
UPDATE referral_social_verifications
   SET recheck_attempts = recheck_attempts + 1, next_check_at = ?, lease_token = NULL, lease_until = NULL
 WHERE provider_id = ? AND campaign = ? AND issuer_id = ? AND lease_token = ?
   AND granted_at IS NULL AND failed_at IS NULL`, timeText(now.UTC().Add(backoff)), claim.providerID, policy.Campaign, claim.issuerID, claim.leaseToken)
			if err != nil {
				return err
			}
			changed, err := result.RowsAffected()
			if err != nil || changed == 0 {
				return err
			}
			return recordSocialAuditTx(ctx, conn, policy.Campaign, claim.providerID, claim.issuerID, "recheck", "transient", hashSocialSubject(claim.postID), "backoff", now)
		}
		if checkErr != nil {
			result, err := conn.ExecContext(ctx, `
UPDATE referral_social_verifications SET failed_at = ?, lease_token = NULL, lease_until = NULL
 WHERE provider_id = ? AND campaign = ? AND issuer_id = ? AND lease_token = ?
   AND granted_at IS NULL AND failed_at IS NULL`, timeText(now.UTC()), claim.providerID, policy.Campaign, claim.issuerID, claim.leaseToken)
			if err != nil {
				return err
			}
			changed, err := result.RowsAffected()
			if err != nil || changed == 0 {
				return err
			}
			return recordSocialAuditTx(ctx, conn, policy.Campaign, claim.providerID, claim.issuerID, "recheck", "terminal", hashSocialSubject(claim.postID), "external_rejection", now)
		}

		grantCount, err := socialGrantCountTx(ctx, conn, policy.Campaign, claim.providerID)
		if err != nil {
			return err
		}
		if grantCount >= policy.SocialBonusMaxGrants {
			result, err := conn.ExecContext(ctx, `
UPDATE referral_social_verifications SET failed_at = ?, lease_token = NULL, lease_until = NULL
 WHERE provider_id = ? AND campaign = ? AND issuer_id = ? AND lease_token = ?
   AND granted_at IS NULL AND failed_at IS NULL`, timeText(now.UTC()), claim.providerID, policy.Campaign, claim.issuerID, claim.leaseToken)
			if err != nil {
				return err
			}
			changed, err := result.RowsAffected()
			if err != nil || changed == 0 {
				return err
			}
			return recordSocialAuditTx(ctx, conn, policy.Campaign, claim.providerID, claim.issuerID, "recheck", "terminal", hashSocialSubject(claim.postID), "cap_reached", now)
		}

		result, err := conn.ExecContext(ctx, `
INSERT INTO referral_social_grants (campaign, provider_id, bonus_kind, issuer_id, verification_post_hash, amount, granted_at)
SELECT ?, ?, ?, ?, ?, ?, ?
 WHERE EXISTS (
       SELECT 1 FROM referral_social_verifications
        WHERE provider_id = ? AND campaign = ? AND issuer_id = ? AND lease_token = ?
          AND granted_at IS NULL AND failed_at IS NULL
   )
   AND EXISTS (
       SELECT 1 FROM referral_serving_qualifications q
       JOIN referral_issuers i ON i.issuer_id = q.issuer_id
        WHERE q.provider_id = ? AND q.campaign = ? AND q.issuer_id = ? AND i.revoked_at IS NULL
   )
ON CONFLICT(campaign, provider_id, bonus_kind) DO NOTHING`, policy.Campaign, claim.providerID, socialGrantKindForPost(claim.postID), claim.issuerID, hashSocialSubject(claim.postID), policy.SocialBonusUses, timeText(now.UTC()), claim.providerID, policy.Campaign, claim.issuerID, claim.leaseToken, claim.providerID, policy.Campaign, claim.issuerID)
		if err != nil {
			return err
		}
		inserted, err := result.RowsAffected()
		if err != nil {
			return err
		}
		if inserted == 0 {
			return nil
		}
		result, err = conn.ExecContext(ctx, `UPDATE referral_issuers SET bonus_capacity = bonus_capacity + ? WHERE issuer_id = ? AND provider_id = ? AND campaign = ? AND revoked_at IS NULL`, policy.SocialBonusUses, claim.issuerID, claim.providerID, policy.Campaign)
		if err != nil {
			return err
		}
		changed, err := result.RowsAffected()
		if err != nil || changed != 1 {
			return fmt.Errorf("social issuer changed during grant")
		}
		result, err = conn.ExecContext(ctx, `
UPDATE referral_social_verifications SET granted_at = ?, lease_token = NULL, lease_until = NULL
 WHERE provider_id = ? AND campaign = ? AND issuer_id = ? AND lease_token = ?
   AND granted_at IS NULL AND failed_at IS NULL`, timeText(now.UTC()), claim.providerID, policy.Campaign, claim.issuerID, claim.leaseToken)
		if err != nil {
			return err
		}
		changed, err = result.RowsAffected()
		if err != nil || changed != 1 {
			return fmt.Errorf("social verification changed during grant")
		}
		if err := recordSocialAuditTx(ctx, conn, policy.Campaign, claim.providerID, claim.issuerID, "bonus", "granted", hashSocialSubject(claim.postID), socialGrantKind, now); err != nil {
			return err
		}
		if err := recordSocialAuditTx(ctx, conn, policy.Campaign, claim.providerID, claim.issuerID, "recheck", "verified", hashSocialSubject(claim.postID), "author_continuity", now); err != nil {
			return err
		}
		granted = true
		return nil
	})
	return granted, err
}

func socialRecheckBackoff(attempt int) time.Duration {
	if attempt < 1 {
		attempt = 1
	}
	d := socialRecheckBaseBackoff
	for i := 1; i < attempt && d < socialRecheckMaxBackoff; i++ {
		d *= 2
		if d > socialRecheckMaxBackoff {
			d = socialRecheckMaxBackoff
		}
	}
	return d
}

// RecordSocialAudit records a redacted externally classified decision. Raw
// challenge text, share URLs, bearers, and external response bodies are never
// persisted; identifiers are reduced to a one-way subject digest.
func (s *Store) RecordSocialAudit(ctx context.Context, policy ReferralPolicy, providerID, challenge, postID, authorID, eventKind, outcome, reason string, now time.Time) error {
	if err := policy.Validate(); err != nil {
		return err
	}
	eventKind = strings.TrimSpace(eventKind)
	outcome = strings.TrimSpace(outcome)
	reason = strings.TrimSpace(reason)
	if err := config.ValidateProviderID(providerID); err != nil || !socialAuditTokenPattern.MatchString(eventKind) || !socialAuditTokenPattern.MatchString(outcome) || (reason != "" && !socialAuditTokenPattern.MatchString(reason)) || now.IsZero() {
		return ErrSocialChallenge
	}
	subject := strings.Join([]string{strings.TrimSpace(challenge), strings.TrimSpace(postID), strings.TrimSpace(authorID)}, "|")
	return sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var issuerID sql.NullString
		if err := conn.QueryRowContext(ctx, `SELECT issuer_id FROM referral_serving_qualifications WHERE campaign = ? AND provider_id = ?`, policy.Campaign, providerID).Scan(&issuerID); err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		return recordSocialAuditTx(ctx, conn, policy.Campaign, providerID, issuerID.String, eventKind, outcome, hashSocialSubject(subject), reason, now)
	})
}

func recordSocialAuditTx(ctx context.Context, conn *sql.Conn, campaign, providerID, issuerID, eventKind, outcome, subjectHash, reason string, now time.Time) error {
	_, err := conn.ExecContext(ctx, `
INSERT INTO referral_social_audit (campaign, provider_id, issuer_id, event_kind, outcome, subject_hash, reason, created_at)
VALUES (?, ?, NULLIF(?, ''), ?, ?, ?, ?, ?)`, campaign, providerID, issuerID, eventKind, outcome, subjectHash, reason, timeText(now.UTC()))
	return err
}

func hashSocialSubject(value string) string {
	digest := sha256.Sum256([]byte(value))
	return fmt.Sprintf("%x", digest[:])
}

func socialGrantKindForPost(postID string) string {
	return socialGrantKind + ":" + hashSocialSubject(postID)
}

func randomReferralID() (string, error) {
	var raw [10]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	return strings.ToLower(referralEncoder.EncodeToString(raw[:])), nil
}
