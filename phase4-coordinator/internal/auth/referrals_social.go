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
	ErrReferralLocked         = errors.New("provider referral locked until first verified serving")
	ErrSocialDisabled         = errors.New("social invite bonus disabled")
	ErrSocialChallenge        = errors.New("social challenge invalid")
	ErrSocialRecheckTransient = errors.New("social recheck transient failure")
)

// SocialVerificationDwell prevents a post that is immediately deleted or made
// private from permanently increasing invite capacity.
const SocialVerificationDwell = 30 * time.Minute

const (
	SocialStateLocked   = "locked_until_first_serving"
	SocialStateEligible = "eligible"
	SocialStatePending  = "pending"
	SocialStateMatured  = "matured"
	SocialStateFailed   = "failed"
	SocialStateRevoked  = "revoked"
)

var socialPrincipalIDPattern = regexp.MustCompile(`^[0-9]{1,24}$`)

// ProviderReferral is the authoritative provider-invite snapshot. Capacity is
// redemption-only: no public hold or reservation state is represented here.
type ProviderReferral struct {
	Code             string
	Campaign         string
	IssuerID         string
	BaseCapacity     int
	BonusCapacity    int
	Redemptions      int
	Remaining        int
	SocialState      string
	FirstServingSeen bool
	Revoked          bool
}

type SocialChallenge struct {
	Cleartext string
	ExpiresAt time.Time
	Code      string
}

func referralSocialSchemaStatements() []string {
	return []string{
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
		`CREATE TABLE IF NOT EXISTS referral_social_verifications (
			provider_id TEXT NOT NULL,
			campaign TEXT NOT NULL,
			issuer_id TEXT NOT NULL REFERENCES referral_issuers(issuer_id),
			post_id TEXT NOT NULL UNIQUE,
			author_id TEXT NOT NULL,
			verification_method TEXT NOT NULL,
			submitted_at TEXT NOT NULL,
			pending_since TEXT NOT NULL,
			granted_at TEXT,
			failed_at TEXT,
			PRIMARY KEY(provider_id, campaign)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_referral_social_pending
			ON referral_social_verifications(campaign, pending_since)
			WHERE granted_at IS NULL AND failed_at IS NULL`,
	}
}

func (s *Store) EnsureProviderReferral(ctx context.Context, policy ReferralPolicy, providerID string, firstServingAt time.Time) (ProviderReferral, error) {
	if err := policy.Validate(); err != nil {
		return ProviderReferral{}, err
	}
	if err := config.ValidateProviderID(providerID); err != nil || firstServingAt.IsZero() {
		return ProviderReferral{}, ErrReferralInvalid
	}

	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var issuerID string
		err := conn.QueryRowContext(ctx, `
SELECT issuer_id
  FROM referral_issuers
 WHERE provider_id = ? AND campaign = ?`, providerID, policy.Campaign).Scan(&issuerID)
		if err == nil {
			return nil
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		issuerID, err = randomReferralID()
		if err != nil {
			return err
		}
		_, err = conn.ExecContext(ctx, `
INSERT INTO referral_issuers (
    issuer_id, code_type, key_id, campaign, provider_id,
    base_capacity, bonus_capacity, created_at, first_serving_at
) VALUES (?, 'P', ?, ?, ?, ?, 0, ?, ?)`,
			issuerID, policy.CurrentKeyID, policy.Campaign, providerID,
			policy.ProviderBaseUses, timeText(firstServingAt.UTC()), timeText(firstServingAt.UTC()))
		return err
	})
	if err != nil {
		return ProviderReferral{}, err
	}
	return s.ProviderReferralStatus(ctx, policy, providerID)
}

func (s *Store) ProviderReferralStatus(ctx context.Context, policy ReferralPolicy, providerID string) (ProviderReferral, error) {
	if err := policy.Validate(); err != nil {
		return ProviderReferral{}, err
	}
	if err := config.ValidateProviderID(providerID); err != nil {
		return ProviderReferral{}, ErrReferralInvalid
	}

	out := ProviderReferral{Campaign: policy.Campaign, SocialState: SocialStateLocked}
	var keyID, firstServingAt string
	var revokedAt sql.NullString
	err := s.db.QueryRowContext(ctx, `
SELECT issuer_id, key_id, base_capacity, bonus_capacity, first_serving_at, revoked_at
  FROM referral_issuers
 WHERE provider_id = ? AND campaign = ?`, providerID, policy.Campaign).Scan(
		&out.IssuerID, &keyID, &out.BaseCapacity, &out.BonusCapacity, &firstServingAt, &revokedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return out, ErrReferralLocked
	}
	if err != nil {
		return ProviderReferral{}, err
	}
	out.FirstServingSeen = strings.TrimSpace(firstServingAt) != ""
	if revokedAt.Valid {
		out.SocialState = SocialStateRevoked
		out.Revoked = true
		return out, nil
	}
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(1) FROM referral_redemptions WHERE issuer_id = ?`, out.IssuerID,
	).Scan(&out.Redemptions); err != nil {
		return ProviderReferral{}, err
	}
	out.Remaining = out.BaseCapacity + out.BonusCapacity - out.Redemptions
	if out.Remaining < 0 {
		out.Remaining = 0
	}
	out.Code, err = EncodeReferralCode(policy, ReferralTypeProvider, keyID, out.IssuerID)
	if err != nil {
		return ProviderReferral{}, err
	}

	var grantedAt, failedAt sql.NullString
	err = s.db.QueryRowContext(ctx, `
SELECT granted_at, failed_at
  FROM referral_social_verifications
 WHERE provider_id = ? AND campaign = ?`, providerID, policy.Campaign).Scan(
		&grantedAt, &failedAt)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		out.SocialState = SocialStateEligible
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

func (s *Store) CreateSocialChallenge(ctx context.Context, policy ReferralPolicy, providerID string, now time.Time) (SocialChallenge, error) {
	if err := policy.Validate(); err != nil {
		return SocialChallenge{}, err
	}
	if !policy.EnableSocialBonus {
		return SocialChallenge{}, ErrSocialDisabled
	}
	if err := config.ValidateProviderID(providerID); err != nil {
		return SocialChallenge{}, ErrSocialChallenge
	}
	cleartext, err := randomHex(32)
	if err != nil {
		return SocialChallenge{}, err
	}
	digest := sha256.Sum256([]byte(cleartext))
	expiresAt := now.UTC().Add(policy.ChallengeTTL)
	var code string
	err = sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var issuerID, keyID, firstServingAt string
		if err := conn.QueryRowContext(ctx, `
SELECT issuer_id, key_id, first_serving_at
  FROM referral_issuers
 WHERE provider_id = ? AND campaign = ? AND code_type = 'P' AND revoked_at IS NULL`,
			providerID, policy.Campaign).Scan(&issuerID, &keyID, &firstServingAt); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return ErrReferralLocked
			}
			return err
		}
		if strings.TrimSpace(firstServingAt) == "" {
			return ErrReferralLocked
		}
		var exists bool
		if err := conn.QueryRowContext(ctx, `
SELECT EXISTS(SELECT 1 FROM referral_social_verifications WHERE provider_id = ? AND campaign = ?)`,
			providerID, policy.Campaign).Scan(&exists); err != nil {
			return err
		}
		if exists {
			return ErrSocialChallenge
		}
		if _, err := conn.ExecContext(ctx,
			`DELETE FROM referral_social_challenges WHERE provider_id = ? AND campaign = ?`,
			providerID, policy.Campaign); err != nil {
			return err
		}
		if _, err := conn.ExecContext(ctx, `
INSERT INTO referral_social_challenges (
    challenge_hash, provider_id, campaign, issuer_id, created_at, expires_at
) VALUES (?, ?, ?, ?, ?, ?)`,
			fmt.Sprintf("%x", digest[:]), providerID, policy.Campaign, issuerID,
			timeText(now.UTC()), timeText(expiresAt)); err != nil {
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
  JOIN referral_issuers i
    ON i.issuer_id = c.issuer_id
   AND i.provider_id = c.provider_id
   AND i.campaign = c.campaign
   AND i.revoked_at IS NULL
 WHERE c.challenge_hash = ? AND c.provider_id = ? AND c.campaign = ?`,
		fmt.Sprintf("%x", digest[:]), providerID, policy.Campaign).Scan(&expiresAt, &consumedAt)
	if err != nil {
		return ErrSocialChallenge
	}
	expires, err := time.Parse(time.RFC3339, expiresAt)
	if err != nil || consumedAt.Valid || !expires.After(now.UTC()) {
		return ErrSocialChallenge
	}
	return nil
}

func (s *Store) CompleteSocialVerification(ctx context.Context, policy ReferralPolicy, providerID, challenge, postID, authorID, method string, now time.Time) (ProviderReferral, error) {
	if err := policy.Validate(); err != nil {
		return ProviderReferral{}, err
	}
	if !policy.EnableSocialBonus {
		return ProviderReferral{}, ErrSocialDisabled
	}
	postID = strings.TrimSpace(postID)
	authorID = strings.TrimSpace(authorID)
	method = strings.TrimSpace(method)
	if !socialPrincipalIDPattern.MatchString(postID) || !socialPrincipalIDPattern.MatchString(authorID) || method != "x_api" {
		return ProviderReferral{}, ErrSocialChallenge
	}
	digest := sha256.Sum256([]byte(strings.TrimSpace(challenge)))
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var issuerID, expiresAt string
		var consumedAt sql.NullString
		if err := conn.QueryRowContext(ctx, `
SELECT c.issuer_id, c.expires_at, c.consumed_at
  FROM referral_social_challenges c
  JOIN referral_issuers i
    ON i.issuer_id = c.issuer_id
   AND i.provider_id = c.provider_id
   AND i.campaign = c.campaign
   AND i.revoked_at IS NULL
 WHERE c.challenge_hash = ? AND c.provider_id = ? AND c.campaign = ?`,
			fmt.Sprintf("%x", digest[:]), providerID, policy.Campaign).Scan(
			&issuerID, &expiresAt, &consumedAt); err != nil {
			return ErrSocialChallenge
		}
		expires, err := time.Parse(time.RFC3339, expiresAt)
		if err != nil || consumedAt.Valid || !expires.After(now.UTC()) {
			return ErrSocialChallenge
		}
		if _, err := conn.ExecContext(ctx, `
INSERT INTO referral_social_verifications (
    provider_id, campaign, issuer_id, post_id, author_id,
    verification_method, submitted_at, pending_since
) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			providerID, policy.Campaign, issuerID, postID, authorID, method,
			timeText(now.UTC()), timeText(now.UTC())); err != nil {
			if isConstraintFailure(err) {
				return ErrSocialChallenge
			}
			return err
		}
		result, err := conn.ExecContext(ctx, `
UPDATE referral_social_challenges
   SET consumed_at = ?
 WHERE challenge_hash = ? AND consumed_at IS NULL`,
			timeText(now.UTC()), fmt.Sprintf("%x", digest[:]))
		if err != nil {
			return err
		}
		changed, err := result.RowsAffected()
		if err != nil || changed != 1 {
			return ErrSocialChallenge
		}
		return nil
	})
	if err != nil {
		return ProviderReferral{}, err
	}
	return s.ProviderReferralStatus(ctx, policy, providerID)
}

// PromoteMaturedSocialVerifications grants only against the exact issuer that
// was active when the pending row was selected. If replacement occurs during
// recheck, the conditional issuer update is a no-op and a later pass processes
// the verification after it has been rebound to the successor.
func (s *Store) PromoteMaturedSocialVerifications(ctx context.Context, policy ReferralPolicy, now time.Time, recheck func(context.Context, string, string) error) (int, error) {
	if err := policy.Validate(); err != nil {
		return 0, err
	}
	if !policy.EnableSocialBonus || recheck == nil {
		return 0, nil
	}
	rows, err := s.db.QueryContext(ctx, `
SELECT provider_id, issuer_id, post_id, author_id
  FROM referral_social_verifications
 WHERE campaign = ?
   AND granted_at IS NULL
   AND failed_at IS NULL
   AND pending_since <= ?
 ORDER BY pending_since, provider_id
 LIMIT 64`, policy.Campaign, timeText(now.UTC().Add(-SocialVerificationDwell)))
	if err != nil {
		return 0, err
	}
	type pending struct{ providerID, issuerID, postID, authorID string }
	var items []pending
	for rows.Next() {
		var item pending
		if err := rows.Scan(&item.providerID, &item.issuerID, &item.postID, &item.authorID); err != nil {
			rows.Close()
			return 0, err
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return 0, err
	}
	rows.Close()

	granted := 0
	for _, item := range items {
		checkErr := recheck(ctx, item.postID, item.authorID)
		if errors.Is(checkErr, ErrSocialRecheckTransient) {
			continue
		}
		err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
			if checkErr != nil {
				_, err := conn.ExecContext(ctx, `
UPDATE referral_social_verifications
   SET failed_at = ?
 WHERE provider_id = ? AND campaign = ? AND issuer_id = ?
   AND granted_at IS NULL AND failed_at IS NULL`,
					timeText(now.UTC()), item.providerID, policy.Campaign, item.issuerID)
				return err
			}
			bonusResult, err := conn.ExecContext(ctx, `
UPDATE referral_issuers
   SET bonus_capacity = bonus_capacity + ?
 WHERE issuer_id = ? AND provider_id = ? AND campaign = ? AND revoked_at IS NULL
   AND EXISTS (
       SELECT 1 FROM referral_social_verifications v
        WHERE v.provider_id = ? AND v.campaign = ? AND v.issuer_id = referral_issuers.issuer_id
          AND v.granted_at IS NULL AND v.failed_at IS NULL
   )`, policy.SocialBonusUses, item.issuerID, item.providerID, policy.Campaign,
				item.providerID, policy.Campaign)
			if err != nil {
				return err
			}
			changed, err := bonusResult.RowsAffected()
			if err != nil {
				return err
			}
			if changed != 1 {
				// A concurrent issuer replacement intentionally makes the
				// conditional update a no-op. The replacement transaction rebinds
				// the pending verification, so a later reconciliation pass can
				// promote it against the successor without double-granting.
				return nil
			}
			verificationResult, err := conn.ExecContext(ctx, `
UPDATE referral_social_verifications
   SET granted_at = ?
 WHERE provider_id = ? AND campaign = ? AND issuer_id = ?
   AND granted_at IS NULL AND failed_at IS NULL`,
				timeText(now.UTC()), item.providerID, policy.Campaign, item.issuerID)
			if err != nil {
				return err
			}
			changed, err = verificationResult.RowsAffected()
			if err != nil {
				return err
			}
			if changed != 1 {
				return fmt.Errorf("social verification changed during promotion")
			}
			granted++
			return nil
		})
		if err != nil {
			return granted, err
		}
	}
	return granted, nil
}

type ReferralReplacement struct {
	ProviderID          string
	OldIssuerID         string
	OldBaseCapacity     int
	OldBonusCapacity    int
	NewIssuerID         string
	NewCode             string
	KeyID               string
	BaseCapacity        int
	BonusCapacity       int
	PendingSocialReview bool
	Applied             bool
}

// ReplaceReferralIssuer creates a fresh successor only for a revoked provider
// issuer. Earned bonus capacity and pending social state are preserved in the
// same transaction as the replacement audit record.
func (s *Store) ReplaceReferralIssuer(ctx context.Context, policy ReferralPolicy, issuerID, actor, reason string, apply bool, now time.Time) (ReferralReplacement, error) {
	if err := policy.Validate(); err != nil {
		return ReferralReplacement{}, err
	}
	issuerID = strings.TrimSpace(issuerID)
	actor = strings.TrimSpace(actor)
	reason = strings.TrimSpace(reason)
	if !referralPartPattern.MatchString(issuerID) {
		return ReferralReplacement{}, ErrReferralInvalid
	}
	if apply && (actor == "" || reason == "") {
		return ReferralReplacement{}, fmt.Errorf("actor and reason are required to replace an issuer")
	}

	var out ReferralReplacement
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var codeType string
		var providerID, firstServingAt, revokedAt sql.NullString
		if err := conn.QueryRowContext(ctx, `
SELECT code_type, provider_id, first_serving_at, revoked_at, base_capacity, bonus_capacity
  FROM referral_issuers
 WHERE issuer_id = ? AND campaign = ?`, issuerID, policy.Campaign).Scan(
			&codeType, &providerID, &firstServingAt, &revokedAt,
			&out.OldBaseCapacity, &out.OldBonusCapacity); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return ErrReferralInvalid
			}
			return err
		}
		if codeType != ReferralTypeProvider || !providerID.Valid || strings.TrimSpace(providerID.String) == "" {
			return ErrReferralInvalid
		}
		if !revokedAt.Valid {
			return fmt.Errorf("issuer %s is not revoked", issuerID)
		}
		var pending bool
		if err := conn.QueryRowContext(ctx, `
SELECT EXISTS(
    SELECT 1 FROM referral_social_verifications
     WHERE provider_id = ? AND campaign = ? AND granted_at IS NULL AND failed_at IS NULL
)`, providerID.String, policy.Campaign).Scan(&pending); err != nil {
			return err
		}
		out.ProviderID = providerID.String
		out.OldIssuerID = issuerID
		out.KeyID = policy.CurrentKeyID
		out.BaseCapacity = policy.ProviderBaseUses
		out.BonusCapacity = out.OldBonusCapacity
		out.PendingSocialReview = pending
		if !apply {
			return nil
		}

		newIssuerID, err := randomReferralID()
		if err != nil {
			return err
		}
		servingAt := firstServingAt.String
		if !firstServingAt.Valid || strings.TrimSpace(servingAt) == "" {
			servingAt = timeText(now.UTC())
		}
		result, err := conn.ExecContext(ctx, `
UPDATE referral_issuers
   SET provider_id = NULL, replaced_by = ?
 WHERE issuer_id = ? AND campaign = ? AND revoked_at IS NOT NULL AND provider_id = ?`,
			newIssuerID, issuerID, policy.Campaign, providerID.String)
		if err != nil {
			return err
		}
		if changed, err := result.RowsAffected(); err != nil || changed != 1 {
			return ErrReferralInvalid
		}
		if _, err := conn.ExecContext(ctx, `
INSERT INTO referral_issuers (
    issuer_id, code_type, key_id, campaign, provider_id,
    base_capacity, bonus_capacity, created_at, first_serving_at
) VALUES (?, 'P', ?, ?, ?, ?, ?, ?, ?)`,
			newIssuerID, policy.CurrentKeyID, policy.Campaign, providerID.String,
			policy.ProviderBaseUses, out.OldBonusCapacity, timeText(now.UTC()), servingAt); err != nil {
			return err
		}
		if _, err := conn.ExecContext(ctx, `
UPDATE referral_social_verifications
   SET issuer_id = ?
 WHERE provider_id = ? AND campaign = ? AND issuer_id = ?`,
			newIssuerID, providerID.String, policy.Campaign, issuerID); err != nil {
			return err
		}
		if _, err := conn.ExecContext(ctx, `
UPDATE referral_social_challenges
   SET issuer_id = ?
 WHERE provider_id = ? AND campaign = ? AND issuer_id = ?`,
			newIssuerID, providerID.String, policy.Campaign, issuerID); err != nil {
			return err
		}
		code, err := EncodeReferralCode(policy, ReferralTypeProvider, policy.CurrentKeyID, newIssuerID)
		if err != nil {
			return err
		}
		detail := fmt.Sprintf("provider=%s replaced_by=%s base_capacity=%d bonus_capacity=%d pending_social=%t",
			providerID.String, newIssuerID, policy.ProviderBaseUses, out.OldBonusCapacity, pending)
		if err := recordReferralAdminAuditTx(ctx, conn, actor, reason, "replace_issuer", policy.Campaign+"/"+issuerID, detail, now); err != nil {
			return err
		}
		out.NewIssuerID = newIssuerID
		out.NewCode = code
		out.Applied = true
		return nil
	})
	if err != nil {
		return ReferralReplacement{}, err
	}
	return out, nil
}

func randomReferralID() (string, error) {
	var raw [10]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	return strings.ToLower(referralEncoder.EncodeToString(raw[:])), nil
}
