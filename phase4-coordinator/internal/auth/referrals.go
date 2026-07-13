package auth

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base32"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

var (
	ErrReferralRequired  = errors.New("referral code required")
	ErrReferralInvalid   = errors.New("referral code invalid")
	ErrReferralExpired   = errors.New("referral code expired")
	ErrReferralRevoked   = errors.New("referral code revoked")
	ErrReferralExhausted = errors.New("referral code exhausted")
	// ErrReferralReservationExpired is distinct from ErrReferralExhausted: the
	// caller's own preflight reservation reached its ABSOLUTE lifetime and was
	// released (FIX-570 H3). The invite itself may still have capacity, so the
	// installer/app should show actionable "your hold expired, re-acquire" copy
	// rather than the terminal "all spots taken" (exhausted) copy. A short
	// post-expiry cooldown keyed on (campaign, provider_id, code) prevents the
	// same identity from immediately re-holding the same slot forever.
	ErrReferralReservationExpired = errors.New("referral reservation expired")
	ErrReferralConflict           = errors.New("provider already attributed to another referral")
	ErrReferralSeedExists         = errors.New("seed referral already exists")
	ErrReferralCapacityBelowUsed  = errors.New("referral capacity cannot be set below redeemed plus reserved uses")
	ErrReferralLocked             = errors.New("provider referral locked until first verified serving")
	ErrSocialDisabled             = errors.New("social invite bonus disabled")
	ErrSocialChallenge            = errors.New("social challenge invalid")
	// ErrSocialRecheckTransient signals that a promotion-time social re-check
	// failed for a transient reason (timeout / 429 / 5xx / transport error)
	// rather than a confirmed terminal one (post deleted, protected, or author
	// mismatch). A recheck func returns it to keep the verification PENDING for a
	// later retry instead of permanently failing the bonus. FIX-570 M3.
	ErrSocialRecheckTransient = errors.New("social recheck transient failure")
)

// SocialVerificationDwell is how long a social verification stays PENDING before
// the promotion reconciler re-checks the post and grants the capacity bonus. It
// is exported so status responses can compute a stable review_due_at
// (pending_since + dwell) for the dashboard. FIX-570 H3 / cross-lane contract.
const SocialVerificationDwell = 30 * time.Minute

const (
	ReferralTypeSeed     = "S"
	ReferralTypeProvider = "P"
	referralTagBytes     = 16
)

var referralPartPattern = regexp.MustCompile(`^[A-Za-z0-9_]{1,32}$`)
var referralEncoder = base32.StdEncoding.WithPadding(base32.NoPadding)

// ReferralPolicy is a caller-owned immutable snapshot. Secrets stay in memory
// and are never stored in SQLite; key IDs stored with issuers make rotation
// explicit without exposing the HMAC material.
type ReferralPolicy struct {
	RequireForRegistration bool
	EnableSocialBonus      bool
	Campaign               string
	PolicyVersion          string
	GrandfatherBefore      *time.Time
	GrandfatherProof       bool
	CurrentKeyID           string
	HMACKeys               map[string]string
	ProviderBaseUses       int
	SocialBonusUses        int
	ChallengeTTL           time.Duration
}

func (p ReferralPolicy) Validate() error {
	if !p.RequireForRegistration && !p.EnableSocialBonus && strings.TrimSpace(p.Campaign) == "" {
		return nil
	}
	if !referralPartPattern.MatchString(p.Campaign) {
		return fmt.Errorf("referral campaign must match %s", referralPartPattern)
	}
	if !referralPartPattern.MatchString(p.PolicyVersion) {
		return fmt.Errorf("referral policy version must match %s", referralPartPattern)
	}
	if !referralPartPattern.MatchString(p.CurrentKeyID) {
		return fmt.Errorf("referral current key id must match %s", referralPartPattern)
	}
	secret := p.HMACKeys[p.CurrentKeyID]
	if len(secret) < 32 {
		return fmt.Errorf("referral current HMAC secret must be at least 32 bytes")
	}
	for keyID, value := range p.HMACKeys {
		if !referralPartPattern.MatchString(keyID) || len(value) < 32 {
			return fmt.Errorf("referral HMAC key %q is invalid or shorter than 32 bytes", keyID)
		}
	}
	if p.ProviderBaseUses <= 0 || p.SocialBonusUses <= 0 || p.ChallengeTTL <= 0 {
		return fmt.Errorf("referral capacities and challenge ttl must be positive")
	}
	return nil
}

type ReferralValidation struct {
	Valid         bool
	Reason        string
	Type          string
	IssuerID      string
	Campaign      string
	RemainingUses int
}

type ProviderReferral struct {
	Code             string
	Campaign         string
	BaseUses         int
	BonusUses        int
	Used             int
	Remaining        int
	SocialVerified   bool
	AdvocacyStatus   string
	IssuerID         string
	FirstServingSeen bool
	Revoked          bool
	// ReviewDueAt is set only while advocacy_status == "pending_social_review":
	// the RFC3339 instant (pending_since + dwell) at which the pending X
	// verification becomes eligible for promotion. Nil in every other state.
	// FIX-570 cross-lane contract.
	ReviewDueAt *time.Time
}

type SocialChallenge struct {
	Cleartext string
	ExpiresAt time.Time
	Code      string
}

type parsedReferralCode struct {
	Type     string
	KeyID    string
	IssuerID string
	Tag      []byte
}

func parseReferralCode(raw string) (parsedReferralCode, error) {
	parts := strings.Split(strings.TrimSpace(raw), "-")
	if len(parts) != 5 || parts[0] != "MAL1" || (parts[1] != ReferralTypeSeed && parts[1] != ReferralTypeProvider) ||
		!referralPartPattern.MatchString(parts[2]) || !referralPartPattern.MatchString(parts[3]) {
		return parsedReferralCode{}, ErrReferralInvalid
	}
	tag, err := referralEncoder.DecodeString(strings.ToUpper(parts[4]))
	if err != nil || len(tag) != referralTagBytes {
		return parsedReferralCode{}, ErrReferralInvalid
	}
	return parsedReferralCode{Type: parts[1], KeyID: parts[2], IssuerID: parts[3], Tag: tag}, nil
}

func referralMAC(policy ReferralPolicy, typ, keyID, issuerID string) ([]byte, error) {
	secret, ok := policy.HMACKeys[keyID]
	if !ok || len(secret) < 32 {
		return nil, ErrReferralInvalid
	}
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte("malibu-referral/v1\x00"))
	_, _ = mac.Write([]byte(typ))
	_, _ = mac.Write([]byte("\x00" + keyID + "\x00" + policy.Campaign + "\x00" + issuerID))
	return mac.Sum(nil)[:referralTagBytes], nil
}

func EncodeReferralCode(policy ReferralPolicy, typ, keyID, issuerID string) (string, error) {
	if err := policy.Validate(); err != nil {
		return "", err
	}
	if (typ != ReferralTypeSeed && typ != ReferralTypeProvider) || !referralPartPattern.MatchString(keyID) || !referralPartPattern.MatchString(issuerID) {
		return "", ErrReferralInvalid
	}
	tag, err := referralMAC(policy, typ, keyID, issuerID)
	if err != nil {
		return "", err
	}
	return strings.Join([]string{"MAL1", typ, keyID, issuerID, referralEncoder.EncodeToString(tag)}, "-"), nil
}

func (s *Store) CreateSeedReferral(ctx context.Context, policy ReferralPolicy, seedID string, maxUses int, expiresAt *time.Time) (string, error) {
	if err := policy.Validate(); err != nil {
		return "", err
	}
	if !referralPartPattern.MatchString(seedID) || maxUses <= 0 {
		return "", fmt.Errorf("seed id and max uses are invalid")
	}
	var expiry any
	if expiresAt != nil {
		expiry = timeText(expiresAt.UTC())
	}
	// FIX-570 H5: seed creation is INSERT-only. A silent upsert could strand a
	// live code (e.g. re-running with the default --max-uses 1 after the seed
	// already accrued redemptions). Capacity changes go through the audited
	// AdjustSeedReferral path instead.
	_, err := s.db.ExecContext(ctx, `
INSERT INTO referral_issuers (
    issuer_id, code_type, key_id, campaign, provider_id,
    base_capacity, bonus_capacity, expires_at, created_at, first_serving_at
) VALUES (?, 'S', ?, ?, NULL, ?, 0, ?, ?, ?)`,
		seedID, policy.CurrentKeyID, policy.Campaign, maxUses, expiry, nowString(), nowString())
	if isConstraintFailure(err) {
		return "", ErrReferralSeedExists
	}
	if err != nil {
		return "", err
	}
	return EncodeReferralCode(policy, ReferralTypeSeed, policy.CurrentKeyID, seedID)
}

func (s *Store) RevokeReferralIssuer(ctx context.Context, campaign, issuerID string, now time.Time) error {
	if !referralPartPattern.MatchString(strings.TrimSpace(campaign)) || !referralPartPattern.MatchString(strings.TrimSpace(issuerID)) {
		return ErrReferralInvalid
	}
	result, err := s.db.ExecContext(ctx, `
UPDATE referral_issuers
   SET revoked_at = ?
 WHERE campaign = ? AND issuer_id = ? AND revoked_at IS NULL`,
		timeText(now.UTC()), strings.TrimSpace(campaign), strings.TrimSpace(issuerID))
	if err != nil {
		return err
	}
	changed, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if changed != 1 {
		return ErrReferralInvalid
	}
	return nil
}

// ReferralRevocation is the preview/result of RevokeReferralIssuerAudited.
type ReferralRevocation struct {
	Campaign   string
	IssuerID   string
	CodeType   string
	ProviderID string
	Applied    bool
}

// RevokeReferralIssuerAudited previews (apply=false) or applies (apply=true) a
// revocation of a seed or provider issuer within a campaign. Applying requires a
// non-empty actor and reason and writes an append-only referral_admin_audit row
// in the SAME transaction as the revoke. FIX-570 M6: the operator revoke path
// must be attributable. The preview reports the target issuer's type and bound
// provider so an operator can confirm before mutating.
func (s *Store) RevokeReferralIssuerAudited(ctx context.Context, campaign, issuerID string, apply bool, actor, reason string, now time.Time) (ReferralRevocation, error) {
	campaign = strings.TrimSpace(campaign)
	issuerID = strings.TrimSpace(issuerID)
	if !referralPartPattern.MatchString(campaign) || !referralPartPattern.MatchString(issuerID) {
		return ReferralRevocation{}, ErrReferralInvalid
	}
	if apply && (strings.TrimSpace(actor) == "" || strings.TrimSpace(reason) == "") {
		return ReferralRevocation{}, fmt.Errorf("actor and reason are required to apply a revocation")
	}
	out := ReferralRevocation{Campaign: campaign, IssuerID: issuerID}
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var providerID sql.NullString
		var revokedAt sql.NullString
		if err := conn.QueryRowContext(ctx, `
SELECT code_type, provider_id, revoked_at
  FROM referral_issuers
 WHERE campaign = ? AND issuer_id = ?`, campaign, issuerID).Scan(&out.CodeType, &providerID, &revokedAt); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return ErrReferralInvalid
			}
			return err
		}
		out.ProviderID = strings.TrimSpace(providerID.String)
		if revokedAt.Valid {
			return fmt.Errorf("issuer %s is already revoked", issuerID)
		}
		if !apply {
			return nil
		}
		result, err := conn.ExecContext(ctx, `
UPDATE referral_issuers SET revoked_at = ? WHERE campaign = ? AND issuer_id = ? AND revoked_at IS NULL`,
			timeText(now.UTC()), campaign, issuerID)
		if err != nil {
			return err
		}
		if changed, err := result.RowsAffected(); err != nil || changed != 1 {
			return ErrReferralInvalid
		}
		detail := fmt.Sprintf("code_type=%s provider=%s", out.CodeType, out.ProviderID)
		if err := recordReferralAdminAuditTx(ctx, conn, actor, reason, "revoke_issuer", campaign+"/"+issuerID, detail, now); err != nil {
			return err
		}
		out.Applied = true
		return nil
	})
	if err != nil {
		return ReferralRevocation{}, err
	}
	return out, nil
}

// SeedReferralAdjustment is the preview/result of an AdjustSeedReferral call.
// It is returned for both dry-run and applied adjustments so operators can see
// the exact effect before and after mutation.
type SeedReferralAdjustment struct {
	SeedID             string
	CurrentCapacity    int
	NewCapacity        int
	Redeemed           int
	Reserved           int
	ResultingRemaining int
	Applied            bool
}

// AdjustSeedReferral previews (apply=false) or applies (apply=true) a change to a
// seed issuer's base_capacity. Applying requires a non-empty actor and reason and
// refuses to set capacity below the floor of already-redeemed plus live-reserved
// uses (which would strand committed installs). Every applied change writes an
// append-only referral_admin_audit row. FIX-570 H5.
func (s *Store) AdjustSeedReferral(ctx context.Context, policy ReferralPolicy, seedID string, newCapacity int, apply bool, actor, reason string, now time.Time) (SeedReferralAdjustment, error) {
	if err := policy.Validate(); err != nil {
		return SeedReferralAdjustment{}, err
	}
	seedID = strings.TrimSpace(seedID)
	if !referralPartPattern.MatchString(seedID) || newCapacity < 0 {
		return SeedReferralAdjustment{}, ErrReferralInvalid
	}
	if apply && (strings.TrimSpace(actor) == "" || strings.TrimSpace(reason) == "") {
		return SeedReferralAdjustment{}, fmt.Errorf("actor and reason are required to apply a seed adjustment")
	}
	out := SeedReferralAdjustment{SeedID: seedID, NewCapacity: newCapacity}
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var codeType string
		if err := conn.QueryRowContext(ctx, `
SELECT code_type, base_capacity
  FROM referral_issuers
 WHERE issuer_id = ? AND campaign = ?`, seedID, policy.Campaign).Scan(&codeType, &out.CurrentCapacity); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return ErrReferralInvalid
			}
			return err
		}
		if codeType != ReferralTypeSeed {
			return ErrReferralInvalid
		}
		if err := conn.QueryRowContext(ctx, `SELECT COUNT(1) FROM referral_redemptions WHERE issuer_id = ?`, seedID).Scan(&out.Redeemed); err != nil {
			return err
		}
		if err := conn.QueryRowContext(ctx, `
SELECT COUNT(1)
  FROM referral_reservations r
 WHERE r.issuer_id = ? AND r.expires_at > ?
   AND NOT EXISTS (
       SELECT 1 FROM referral_redemptions d
        WHERE d.campaign = r.campaign
          AND d.provider_id = r.provider_id
          AND d.issuer_id = r.issuer_id
   )`, seedID, timeText(now.UTC())).Scan(&out.Reserved); err != nil {
			return err
		}
		floor := out.Redeemed + out.Reserved
		out.ResultingRemaining = newCapacity - floor
		if out.ResultingRemaining < 0 {
			out.ResultingRemaining = 0
		}
		if !apply {
			return nil
		}
		if newCapacity < floor {
			return ErrReferralCapacityBelowUsed
		}
		result, err := conn.ExecContext(ctx, `
UPDATE referral_issuers SET base_capacity = ? WHERE issuer_id = ? AND campaign = ? AND code_type = 'S'`,
			newCapacity, seedID, policy.Campaign)
		if err != nil {
			return err
		}
		if changed, err := result.RowsAffected(); err != nil || changed != 1 {
			return ErrReferralInvalid
		}
		detail := fmt.Sprintf("base_capacity %d->%d redeemed=%d reserved=%d", out.CurrentCapacity, newCapacity, out.Redeemed, out.Reserved)
		if err := recordReferralAdminAuditTx(ctx, conn, actor, reason, "adjust_seed", policy.Campaign+"/"+seedID, detail, now); err != nil {
			return err
		}
		out.Applied = true
		return nil
	})
	if err != nil {
		return SeedReferralAdjustment{}, err
	}
	return out, nil
}

// ReferralReplacement is the result of ReplaceReferralIssuer.
type ReferralReplacement struct {
	ProviderID   string
	OldIssuerID  string
	NewIssuerID  string
	NewCode      string
	BaseCapacity int
}

// ReplaceReferralIssuer mints a fresh usable provider issuer to succeed a revoked
// one within a campaign. The revoked issuer is detached from the provider slot
// (its code stays revoked) and linked to the new issuer via replaced_by plus an
// audit row. Requires a non-empty actor and reason. FIX-570 H4.
func (s *Store) ReplaceReferralIssuer(ctx context.Context, policy ReferralPolicy, issuerID, actor, reason string, now time.Time) (ReferralReplacement, error) {
	if err := policy.Validate(); err != nil {
		return ReferralReplacement{}, err
	}
	issuerID = strings.TrimSpace(issuerID)
	if !referralPartPattern.MatchString(issuerID) {
		return ReferralReplacement{}, ErrReferralInvalid
	}
	if strings.TrimSpace(actor) == "" || strings.TrimSpace(reason) == "" {
		return ReferralReplacement{}, fmt.Errorf("actor and reason are required to replace an issuer")
	}
	var out ReferralReplacement
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var codeType string
		var providerID sql.NullString
		var firstServingAt sql.NullString
		var revokedAt sql.NullString
		if err := conn.QueryRowContext(ctx, `
SELECT code_type, provider_id, first_serving_at, revoked_at
  FROM referral_issuers
 WHERE issuer_id = ? AND campaign = ?`, issuerID, policy.Campaign).Scan(&codeType, &providerID, &firstServingAt, &revokedAt); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return ErrReferralInvalid
			}
			return err
		}
		if codeType != ReferralTypeProvider || !providerID.Valid || strings.TrimSpace(providerID.String) == "" {
			return ErrReferralInvalid
		}
		if !revokedAt.Valid {
			return fmt.Errorf("issuer %s is not revoked; only a revoked issuer can be replaced", issuerID)
		}
		newID, err := randomReferralID()
		if err != nil {
			return err
		}
		firstServing := firstServingAt.String
		if !firstServingAt.Valid || strings.TrimSpace(firstServing) == "" {
			firstServing = timeText(now.UTC())
		}
		// Detach the revoked issuer from the provider slot so the fresh issuer can
		// occupy UNIQUE(provider_id, campaign); the old code stays revoked.
		if _, err := conn.ExecContext(ctx, `
UPDATE referral_issuers SET provider_id = NULL, replaced_by = ? WHERE issuer_id = ? AND campaign = ?`,
			newID, issuerID, policy.Campaign); err != nil {
			return err
		}
		if _, err := conn.ExecContext(ctx, `
INSERT INTO referral_issuers (
    issuer_id, code_type, key_id, campaign, provider_id,
    base_capacity, bonus_capacity, created_at, first_serving_at
) VALUES (?, 'P', ?, ?, ?, ?, 0, ?, ?)`,
			newID, policy.CurrentKeyID, policy.Campaign, providerID.String, policy.ProviderBaseUses, timeText(now.UTC()), firstServing); err != nil {
			return err
		}
		code, err := EncodeReferralCode(policy, ReferralTypeProvider, policy.CurrentKeyID, newID)
		if err != nil {
			return err
		}
		detail := fmt.Sprintf("provider=%s replaced_by=%s base_capacity=%d", providerID.String, newID, policy.ProviderBaseUses)
		if err := recordReferralAdminAuditTx(ctx, conn, actor, reason, "replace_issuer", policy.Campaign+"/"+issuerID, detail, now); err != nil {
			return err
		}
		out = ReferralReplacement{ProviderID: providerID.String, OldIssuerID: issuerID, NewIssuerID: newID, NewCode: code, BaseCapacity: policy.ProviderBaseUses}
		return nil
	})
	if err != nil {
		return ReferralReplacement{}, err
	}
	return out, nil
}

func recordReferralAdminAuditTx(ctx context.Context, conn *sql.Conn, actor, reason, action, target, detail string, now time.Time) error {
	_, err := conn.ExecContext(ctx, `
INSERT INTO referral_admin_audit (actor, reason, action, target, detail, ts)
VALUES (?, ?, ?, ?, ?, ?)`,
		strings.TrimSpace(actor), strings.TrimSpace(reason), action, target, detail, timeText(now.UTC()))
	return err
}

func (s *Store) ValidateReferral(ctx context.Context, policy ReferralPolicy, code string, now time.Time) (ReferralValidation, error) {
	if err := policy.Validate(); err != nil {
		return ReferralValidation{}, err
	}
	return validateReferralTx(ctx, s.db, policy, code, now)
}

type referralQueryRower interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

func validateReferralTx(ctx context.Context, conn referralQueryRower, policy ReferralPolicy, code string, now time.Time) (ReferralValidation, error) {
	return validateReferralTxWithCapacity(ctx, conn, policy, code, now, true)
}

func validateReferralTxWithCapacity(ctx context.Context, conn referralQueryRower, policy ReferralPolicy, code string, now time.Time, enforceCapacity bool) (ReferralValidation, error) {
	parsed, err := parseReferralCode(code)
	if err != nil {
		return ReferralValidation{Reason: "invalid"}, ErrReferralInvalid
	}
	want, err := referralMAC(policy, parsed.Type, parsed.KeyID, parsed.IssuerID)
	if err != nil || !hmac.Equal(want, parsed.Tag) {
		return ReferralValidation{Reason: "invalid"}, ErrReferralInvalid
	}
	var issuer struct {
		Type      string
		KeyID     string
		Campaign  string
		Base      int
		Bonus     int
		ExpiresAt sql.NullString
		RevokedAt sql.NullString
	}
	err = conn.QueryRowContext(ctx, `
SELECT code_type, key_id, campaign, base_capacity, bonus_capacity, expires_at, revoked_at
  FROM referral_issuers
 WHERE issuer_id = ?`, parsed.IssuerID).Scan(
		&issuer.Type, &issuer.KeyID, &issuer.Campaign, &issuer.Base, &issuer.Bonus, &issuer.ExpiresAt, &issuer.RevokedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return ReferralValidation{Reason: "invalid"}, ErrReferralInvalid
	}
	if err != nil {
		return ReferralValidation{}, err
	}
	if issuer.Type != parsed.Type || issuer.KeyID != parsed.KeyID || issuer.Campaign != policy.Campaign {
		return ReferralValidation{Reason: "invalid"}, ErrReferralInvalid
	}
	if issuer.RevokedAt.Valid {
		return ReferralValidation{Reason: "revoked"}, ErrReferralRevoked
	}
	if issuer.ExpiresAt.Valid {
		expires, parseErr := time.Parse(time.RFC3339, issuer.ExpiresAt.String)
		if parseErr != nil || !expires.After(now.UTC()) {
			return ReferralValidation{Reason: "expired"}, ErrReferralExpired
		}
	}
	var used int
	if err := conn.QueryRowContext(ctx, `
SELECT (SELECT COUNT(1) FROM referral_redemptions WHERE issuer_id = ?)
     + (SELECT COUNT(1)
	          FROM referral_reservations r
	         WHERE r.issuer_id = ? AND r.expires_at > ?
	           AND NOT EXISTS (
	               SELECT 1 FROM referral_redemptions d
	                WHERE d.campaign = r.campaign
	                  AND d.provider_id = r.provider_id
	                  AND d.issuer_id = r.issuer_id
	           ))`,
		parsed.IssuerID, parsed.IssuerID, timeText(now.UTC())).Scan(&used); err != nil {
		return ReferralValidation{}, err
	}
	remaining := issuer.Base + issuer.Bonus - used
	if remaining <= 0 && enforceCapacity {
		return ReferralValidation{Reason: "exhausted", Type: parsed.Type, IssuerID: parsed.IssuerID, Campaign: issuer.Campaign}, ErrReferralExhausted
	}
	return ReferralValidation{Valid: true, Reason: "valid", Type: parsed.Type, IssuerID: parsed.IssuerID, Campaign: issuer.Campaign, RemainingUses: remaining}, nil
}

// maxReservationLifetime bounds the TOTAL wall-clock lifetime of a single
// preflight reservation, measured from its original created_at. Refreshing a
// reservation may extend expires_at only up to created_at + this cap, after
// which the reservation expires and the slot frees. Without this bound a single
// unauthenticated /v1/referrals/reserve request could pin a cap-one invite
// indefinitely by periodically refreshing under the per-IP limit. FIX-570 H3.
//
// The value is deliberately >= the longest realistic App-track install:
// onboarding states benchmarking ALONE can take 10-30 minutes, on top of the
// DMG download, model download, and autotune. 60 minutes covers that worst case
// with headroom while still bounding an abusive hold; the reservation may be
// refreshed within this window but never past created_at + this cap.
const maxReservationLifetime = 60 * time.Minute

// reservationExpiryCooldown is the short window after a reservation reaches its
// ABSOLUTE lifetime during which the SAME identity may not re-hold the SAME
// code. During the cooldown the released slot is available to OTHER installers,
// so — combined with the per-IP limiter — an unauthenticated caller can no
// longer pin a cap-one invite forever. It does not block acquiring a different
// still-valid invite. FIX-570 H3.
const reservationExpiryCooldown = 2 * time.Minute

// ReserveReferralCapacity creates a short-lived authoritative claim on one
// invite use. It lets App-track commit its PostgreSQL identity transaction
// without holding SQLite's writer lock and without losing a capacity race
// before the referral/token transaction runs. The returned expires_at is the
// STORED absolute-capped deadline, not now+ttl (FIX-570 H3).
func (s *Store) ReserveReferralCapacity(ctx context.Context, policy ReferralPolicy, code, providerID string, now time.Time, ttl time.Duration) (string, error) {
	id, _, err := s.reserveReferralCapacity(ctx, policy, code, providerID, now, ttl)
	return id, err
}

// ReserveReferralCapacityWithExpiry is ReserveReferralCapacity that additionally
// returns the STORED (absolute-capped) expires_at so the caller can present the
// true remaining hold instead of a fresh now+ttl window (FIX-570 H3).
func (s *Store) ReserveReferralCapacityWithExpiry(ctx context.Context, policy ReferralPolicy, code, providerID string, now time.Time, ttl time.Duration) (string, time.Time, error) {
	return s.reserveReferralCapacity(ctx, policy, code, providerID, now, ttl)
}

func (s *Store) reserveReferralCapacity(ctx context.Context, policy ReferralPolicy, code, providerID string, now time.Time, ttl time.Duration) (string, time.Time, error) {
	if err := policy.Validate(); err != nil {
		return "", time.Time{}, err
	}
	if !policy.RequireForRegistration || ttl <= 0 {
		return "", time.Time{}, ErrReferralRequired
	}
	code = strings.TrimSpace(code)
	if code == "" {
		return "", time.Time{}, ErrReferralRequired
	}
	if err := config.ValidateProviderID(providerID); err != nil {
		return "", time.Time{}, err
	}
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", time.Time{}, err
	}
	reservationID := fmt.Sprintf("%x", raw[:])
	digest := sha256.Sum256([]byte(code))
	digestText := fmt.Sprintf("%x", digest[:])
	now = now.UTC()
	var storedExpiry time.Time
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		if _, err := conn.ExecContext(ctx, `DELETE FROM referral_reservations WHERE expires_at <= ?`, timeText(now)); err != nil {
			return err
		}
		// FIX-570 H3: prune lineage rows whose absolute lifetime AND cooldown have
		// both fully elapsed, so a genuinely new install much later starts clean.
		if _, err := conn.ExecContext(ctx, `DELETE FROM referral_reservation_cooldowns WHERE lineage_started_at <= ?`,
			timeText(now.Add(-(maxReservationLifetime + reservationExpiryCooldown)))); err != nil {
			return err
		}

		// FIX-570 H3: the absolute lifetime is anchored to the LINEAGE start, which
		// survives natural expiry of the reservation row. This is what stops an
		// identity from resetting the clock by re-reserving the same code after each
		// deadline. Resolve (or start) the lineage first.
		var lineageStartedText string
		lineageErr := conn.QueryRowContext(ctx, `
SELECT lineage_started_at FROM referral_reservation_cooldowns
 WHERE campaign = ? AND provider_id = ? AND code_digest = ?`,
			policy.Campaign, providerID, digestText).Scan(&lineageStartedText)
		if lineageErr != nil && !errors.Is(lineageErr, sql.ErrNoRows) {
			return lineageErr
		}
		var absoluteDeadline time.Time
		haveLineage := false
		if lineageErr == nil {
			started, parseErr := time.Parse(time.RFC3339, lineageStartedText)
			if parseErr != nil {
				return parseErr
			}
			absoluteDeadline = started.Add(maxReservationLifetime)
			switch {
			case now.Before(absoluteDeadline):
				haveLineage = true // within the current lineage's absolute lifetime
			case now.Before(absoluteDeadline.Add(reservationExpiryCooldown)):
				// Past the absolute lifetime, still inside the post-expiry cooldown:
				// the same identity may not immediately re-hold the same code.
				return ErrReferralReservationExpired
			default:
				// Fully elapsed (defensive; the prune above normally removed it).
				if _, err := conn.ExecContext(ctx, `
DELETE FROM referral_reservation_cooldowns
 WHERE campaign = ? AND provider_id = ? AND code_digest = ?`,
					policy.Campaign, providerID, digestText); err != nil {
					return err
				}
			}
		}

		var existingID, existingDigest string
		err := conn.QueryRowContext(ctx, `
SELECT reservation_id, code_digest
  FROM referral_reservations
 WHERE campaign = ? AND provider_id = ?`, policy.Campaign, providerID).Scan(&existingID, &existingDigest)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		if err == nil {
			// A live reservation row implies an in-lifetime lineage.
			if !hmac.Equal([]byte(existingDigest), []byte(digestText)) {
				return ErrReferralConflict
			}
			if _, validationErr := validateReferralTxWithCapacity(ctx, conn, policy, code, now, false); validationErr != nil {
				return validationErr
			}
			cappedExpiry := now.Add(ttl)
			if haveLineage && cappedExpiry.After(absoluteDeadline) {
				cappedExpiry = absoluteDeadline
			}
			result, updateErr := conn.ExecContext(ctx, `
UPDATE referral_reservations
   SET expires_at = ?
 WHERE reservation_id = ? AND campaign = ? AND provider_id = ?`,
				timeText(cappedExpiry), existingID, policy.Campaign, providerID)
			if updateErr != nil {
				return updateErr
			}
			if changed, updateErr := result.RowsAffected(); updateErr != nil || changed != 1 {
				return ErrReferralExhausted
			}
			reservationID = existingID
			storedExpiry = cappedExpiry
			return nil
		}

		// Fresh reservation. Start a new lineage if none is active; otherwise reuse
		// the current lineage's absolute deadline (re-holding after the row expired
		// must NOT reset the clock).
		if !haveLineage {
			absoluteDeadline = now.Add(maxReservationLifetime)
			if _, err := conn.ExecContext(ctx, `
INSERT INTO referral_reservation_cooldowns (campaign, provider_id, code_digest, lineage_started_at)
VALUES (?, ?, ?, ?)
ON CONFLICT(campaign, provider_id, code_digest) DO UPDATE SET lineage_started_at = excluded.lineage_started_at`,
				policy.Campaign, providerID, digestText, timeText(now)); err != nil {
				return err
			}
		}
		validated, err := validateReferralTxWithCapacity(ctx, conn, policy, code, now, false)
		if err != nil {
			return err
		}
		var redeemedIssuer, redeemedDigest string
		redeemedErr := conn.QueryRowContext(ctx, `
SELECT issuer_id, code_digest
  FROM referral_redemptions
 WHERE campaign = ? AND provider_id = ?`, policy.Campaign, providerID).Scan(&redeemedIssuer, &redeemedDigest)
		if redeemedErr != nil && !errors.Is(redeemedErr, sql.ErrNoRows) {
			return redeemedErr
		}
		if redeemedErr == nil {
			if redeemedIssuer != validated.IssuerID || !hmac.Equal([]byte(redeemedDigest), []byte(digestText)) {
				return ErrReferralConflict
			}
		} else if _, err := validateReferralTx(ctx, conn, policy, code, now); err != nil {
			return err
		}
		expiresAt := now.Add(ttl)
		if expiresAt.After(absoluteDeadline) {
			expiresAt = absoluteDeadline
		}
		if _, err = conn.ExecContext(ctx, `
INSERT INTO referral_reservations (
    reservation_id, campaign, provider_id, issuer_id, code_digest, created_at, expires_at
) VALUES (?, ?, ?, ?, ?, ?, ?)`,
			reservationID, policy.Campaign, providerID, validated.IssuerID, digestText, timeText(now), timeText(expiresAt)); err != nil {
			return err
		}
		storedExpiry = expiresAt
		return nil
	})
	if err != nil {
		return "", time.Time{}, err
	}
	return reservationID, storedExpiry, nil
}

func consumeReferralReservationTx(ctx context.Context, conn *sql.Conn, policy ReferralPolicy, reservationID, code, providerID string, now time.Time) error {
	code = strings.TrimSpace(code)
	digest := sha256.Sum256([]byte(code))
	digestText := fmt.Sprintf("%x", digest[:])
	var storedDigest, issuerID, expiresAt string
	err := conn.QueryRowContext(ctx, `
SELECT code_digest, issuer_id, expires_at
  FROM referral_reservations
 WHERE reservation_id = ? AND campaign = ? AND provider_id = ?`,
		strings.TrimSpace(reservationID), policy.Campaign, providerID).Scan(&storedDigest, &issuerID, &expiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrReferralExhausted
	}
	if err != nil {
		return err
	}
	expires, parseErr := time.Parse(time.RFC3339, expiresAt)
	if parseErr != nil || !expires.After(now.UTC()) || !hmac.Equal([]byte(storedDigest), []byte(digestText)) {
		return ErrReferralExhausted
	}
	validated, err := validateReferralTxWithCapacity(ctx, conn, policy, code, now, false)
	if err != nil {
		return err
	}
	if validated.IssuerID != issuerID {
		return ErrReferralConflict
	}
	result, err := conn.ExecContext(ctx, `
DELETE FROM referral_reservations
 WHERE reservation_id = ? AND campaign = ? AND provider_id = ?`, reservationID, policy.Campaign, providerID)
	if err != nil {
		return err
	}
	if changed, err := result.RowsAffected(); err != nil || changed != 1 {
		return ErrReferralExhausted
	}
	return nil
}

func redeemReferralTx(ctx context.Context, conn *sql.Conn, policy ReferralPolicy, code, providerID string, now time.Time) error {
	if !policy.RequireForRegistration {
		return nil
	}
	code = strings.TrimSpace(code)
	if code == "" {
		if policy.GrandfatherProof {
			var existingDecision string
			err := conn.QueryRowContext(ctx, `
SELECT decision FROM provider_referral_admissions WHERE provider_id = ? AND campaign = ?`,
				providerID, policy.Campaign).Scan(&existingDecision)
			if err == nil && existingDecision == "grandfathered" {
				return nil
			}
			if err != nil && !errors.Is(err, sql.ErrNoRows) {
				return err
			}
		}
		if policy.GrandfatherProof && policy.GrandfatherBefore != nil {
			var firstCreated sql.NullString
			if err := conn.QueryRowContext(ctx, `SELECT MIN(created_at) FROM provider_tokens WHERE provider_id = ?`, providerID).Scan(&firstCreated); err != nil {
				return err
			}
			if firstCreated.Valid {
				first, err := time.Parse(time.RFC3339, firstCreated.String)
				if err == nil && first.Before(policy.GrandfatherBefore.UTC()) {
					_, err = conn.ExecContext(ctx, `
INSERT INTO provider_referral_admissions (provider_id, campaign, policy_version, decision, applied_at)
VALUES (?, ?, ?, 'grandfathered', ?)
ON CONFLICT(provider_id, campaign) DO NOTHING`, providerID, policy.Campaign, policy.PolicyVersion, timeText(now.UTC()))
					return err
				}
			}
		}
		return ErrReferralRequired
	}
	var existingIssuer, existingDigest string
	err := conn.QueryRowContext(ctx, `
SELECT issuer_id, code_digest FROM referral_redemptions WHERE campaign = ? AND provider_id = ?`,
		policy.Campaign, providerID).Scan(&existingIssuer, &existingDigest)
	if err != nil && err != sql.ErrNoRows {
		return err
	}
	parsed, parseErr := parseReferralCode(code)
	if parseErr != nil {
		return ErrReferralInvalid
	}
	if err == nil {
		digest := sha256.Sum256([]byte(code))
		presentedDigest := fmt.Sprintf("%x", digest[:])
		// FIX-570 A3 (PROD-H7): once (provider_id, campaign, issuer_id, code_digest)
		// are bound in referral_redemptions the binding is immutable. Custody-proven
		// recovery / re-disclosure for THAT binding must succeed regardless of the
		// issuer's later lifecycle (expiry/revocation) — those apply only to NEW
		// redemptions. Authenticate the presented code's MAC and match it to the
		// stored binding, then accept without re-validating issuer expiry/revocation.
		if existingIssuer == parsed.IssuerID && hmac.Equal([]byte(existingDigest), []byte(presentedDigest)) {
			wantMAC, macErr := referralMAC(policy, parsed.Type, parsed.KeyID, parsed.IssuerID)
			if macErr != nil || !hmac.Equal(wantMAC, parsed.Tag) {
				return ErrReferralInvalid
			}
			return nil
		}
		// A different code presented for an already-attributed provider: run full
		// validation to surface the precise reason, else report the conflict.
		if _, validationErr := validateReferralTxWithCapacity(ctx, conn, policy, code, now, false); validationErr != nil {
			return validationErr
		}
		return ErrReferralConflict
	}
	validated, err := validateReferralTx(ctx, conn, policy, code, now)
	if err != nil {
		return err
	}
	digest := sha256.Sum256([]byte(strings.TrimSpace(code)))
	_, err = conn.ExecContext(ctx, `
INSERT INTO referral_redemptions (campaign, provider_id, issuer_id, code_digest, policy_version, redeemed_at)
VALUES (?, ?, ?, ?, ?, ?)`, policy.Campaign, providerID, validated.IssuerID, fmt.Sprintf("%x", digest[:]), policy.PolicyVersion, timeText(now.UTC()))
	if isConstraintFailure(err) {
		return ErrReferralExhausted
	}
	if err != nil {
		return err
	}
	_, err = conn.ExecContext(ctx, `
INSERT INTO provider_referral_admissions (provider_id, campaign, policy_version, decision, applied_at)
VALUES (?, ?, ?, 'referred', ?)
ON CONFLICT(provider_id, campaign) DO NOTHING`, providerID, policy.Campaign, policy.PolicyVersion, timeText(now.UTC()))
	return err
}

func (s *Store) ValidateSocialChallenge(ctx context.Context, policy ReferralPolicy, providerID, challenge string, now time.Time) error {
	if err := policy.Validate(); err != nil {
		return err
	}
	if !policy.EnableSocialBonus {
		return ErrSocialDisabled
	}
	hash := sha256.Sum256([]byte(strings.TrimSpace(challenge)))
	var expiresAt string
	var consumedAt sql.NullString
	err := s.db.QueryRowContext(ctx, `
SELECT c.expires_at, c.consumed_at
  FROM referral_social_challenges c
  JOIN referral_issuers i ON i.issuer_id = c.issuer_id AND i.revoked_at IS NULL
 WHERE c.challenge_hash = ? AND c.provider_id = ? AND c.campaign = ?`,
		fmt.Sprintf("%x", hash[:]), providerID, policy.Campaign).Scan(&expiresAt, &consumedAt)
	if err != nil {
		return ErrSocialChallenge
	}
	expires, err := time.Parse(time.RFC3339, expiresAt)
	if err != nil || consumedAt.Valid || !expires.After(now.UTC()) {
		return ErrSocialChallenge
	}
	return nil
}

func (s *Store) EnsureProviderReferral(ctx context.Context, policy ReferralPolicy, providerID string, firstServingAt time.Time) (ProviderReferral, error) {
	if err := policy.Validate(); err != nil {
		return ProviderReferral{}, err
	}
	var out ProviderReferral
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var issuerID, keyID string
		var base, bonus int
		var socialVerified int
		var revokedAt sql.NullString
		err := conn.QueryRowContext(ctx, `
SELECT issuer_id, key_id, base_capacity, bonus_capacity, revoked_at,
       EXISTS(SELECT 1 FROM referral_social_verifications v WHERE v.provider_id = referral_issuers.provider_id AND v.campaign = referral_issuers.campaign AND v.granted_at IS NOT NULL)
  FROM referral_issuers
 WHERE provider_id = ? AND campaign = ?`, providerID, policy.Campaign).Scan(&issuerID, &keyID, &base, &bonus, &revokedAt, &socialVerified)
		if errors.Is(err, sql.ErrNoRows) {
			randomID, err := randomReferralID()
			if err != nil {
				return err
			}
			issuerID, keyID, base = randomID, policy.CurrentKeyID, policy.ProviderBaseUses
			_, err = conn.ExecContext(ctx, `
INSERT INTO referral_issuers (
    issuer_id, code_type, key_id, campaign, provider_id,
    base_capacity, bonus_capacity, created_at, first_serving_at
) VALUES (?, 'P', ?, ?, ?, ?, 0, ?, ?)`,
				issuerID, keyID, policy.Campaign, providerID, base, timeText(firstServingAt.UTC()), timeText(firstServingAt.UTC()))
			if err != nil {
				return err
			}
		} else if err != nil {
			return err
		}
		if revokedAt.Valid {
			out = ProviderReferral{Campaign: policy.Campaign, AdvocacyStatus: "revoked", IssuerID: issuerID, Revoked: true, FirstServingSeen: true}
			return nil
		}
		var used int
		if err := conn.QueryRowContext(ctx, `SELECT COUNT(1) FROM referral_redemptions WHERE issuer_id = ?`, issuerID).Scan(&used); err != nil {
			return err
		}
		code, err := EncodeReferralCode(policy, ReferralTypeProvider, keyID, issuerID)
		if err != nil {
			return err
		}
		status := "eligible"
		if socialVerified == 1 {
			status = "verified"
		}
		out = ProviderReferral{Code: code, Campaign: policy.Campaign, BaseUses: base, BonusUses: bonus, Used: used,
			Remaining: base + bonus - used, SocialVerified: socialVerified == 1, AdvocacyStatus: status, IssuerID: issuerID, FirstServingSeen: true}
		return nil
	})
	return out, err
}

func (s *Store) ProviderReferralStatus(ctx context.Context, policy ReferralPolicy, providerID string) (ProviderReferral, error) {
	if err := policy.Validate(); err != nil {
		return ProviderReferral{}, err
	}
	var out ProviderReferral
	var keyID, firstServingAt string
	var revokedAt sql.NullString
	err := s.db.QueryRowContext(ctx, `
SELECT issuer_id, key_id, base_capacity, bonus_capacity, first_serving_at, revoked_at
  FROM referral_issuers
 WHERE provider_id = ? AND campaign = ?`, providerID, policy.Campaign).Scan(
		&out.IssuerID, &keyID, &out.BaseUses, &out.BonusUses, &firstServingAt, &revokedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return ProviderReferral{Campaign: policy.Campaign, AdvocacyStatus: "locked_until_first_serving"}, ErrReferralLocked
	}
	if err != nil {
		return ProviderReferral{}, err
	}
	if revokedAt.Valid {
		return ProviderReferral{Campaign: policy.Campaign, AdvocacyStatus: "revoked", IssuerID: out.IssuerID, Revoked: true, FirstServingSeen: firstServingAt != ""}, nil
	}
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(1) FROM referral_redemptions WHERE issuer_id = ?`, out.IssuerID).Scan(&out.Used); err != nil {
		return ProviderReferral{}, err
	}
	var reserved int
	if err := s.db.QueryRowContext(ctx, `
SELECT COUNT(1)
  FROM referral_reservations r
 WHERE r.issuer_id = ? AND r.expires_at > ?
   AND NOT EXISTS (
       SELECT 1 FROM referral_redemptions d
        WHERE d.campaign = r.campaign
          AND d.provider_id = r.provider_id
          AND d.issuer_id = r.issuer_id
   )`, out.IssuerID, nowString()).Scan(&reserved); err != nil {
		return ProviderReferral{}, err
	}
	out.Code, err = EncodeReferralCode(policy, ReferralTypeProvider, keyID, out.IssuerID)
	if err != nil {
		return ProviderReferral{}, err
	}
	out.Campaign = policy.Campaign
	out.Remaining = max(0, out.BaseUses+out.BonusUses-out.Used-reserved)
	out.FirstServingSeen = firstServingAt != ""
	// Surface the social-advocacy lifecycle so the dashboard can render granted,
	// pending (with a review_due_at), and terminally-failed states distinctly.
	// FIX-570 H3 / cross-lane contract.
	var grantedAt, failedAt, pendingSince sql.NullString
	verifyErr := s.db.QueryRowContext(ctx, `
SELECT granted_at, failed_at, pending_since
  FROM referral_social_verifications
 WHERE provider_id = ? AND campaign = ?`, providerID, policy.Campaign).Scan(&grantedAt, &failedAt, &pendingSince)
	switch {
	case errors.Is(verifyErr, sql.ErrNoRows):
		out.AdvocacyStatus = "eligible"
	case verifyErr != nil:
		return ProviderReferral{}, verifyErr
	case grantedAt.Valid:
		out.SocialVerified = true
		out.AdvocacyStatus = "verified"
	case failedAt.Valid:
		out.AdvocacyStatus = "social_review_failed"
	case pendingSince.Valid:
		out.AdvocacyStatus = "pending_social_review"
		if since, parseErr := time.Parse(time.RFC3339, pendingSince.String); parseErr == nil {
			due := since.Add(SocialVerificationDwell)
			out.ReviewDueAt = &due
		}
	default:
		out.AdvocacyStatus = "eligible"
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

func (s *Store) CreateSocialChallenge(ctx context.Context, policy ReferralPolicy, providerID string, now time.Time) (SocialChallenge, error) {
	if err := policy.Validate(); err != nil {
		return SocialChallenge{}, err
	}
	if !policy.EnableSocialBonus {
		return SocialChallenge{}, ErrSocialDisabled
	}
	cleartext, err := randomHex(32)
	if err != nil {
		return SocialChallenge{}, err
	}
	hash := sha256.Sum256([]byte(cleartext))
	expiresAt := now.UTC().Add(policy.ChallengeTTL)
	var code string
	err = sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var issuerID, keyID string
		var firstServingAt sql.NullString
		if err := conn.QueryRowContext(ctx, `
SELECT issuer_id, key_id, first_serving_at
  FROM referral_issuers
 WHERE provider_id = ? AND campaign = ? AND code_type = 'P' AND revoked_at IS NULL`, providerID, policy.Campaign).Scan(&issuerID, &keyID, &firstServingAt); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return ErrReferralLocked
			}
			return err
		}
		if !firstServingAt.Valid {
			return ErrReferralLocked
		}
		var verified int
		if err := conn.QueryRowContext(ctx, `
SELECT EXISTS(SELECT 1 FROM referral_social_verifications WHERE provider_id = ? AND campaign = ?)`,
			providerID, policy.Campaign).Scan(&verified); err != nil {
			return err
		}
		if verified == 1 {
			return ErrSocialChallenge
		}
		if _, err := conn.ExecContext(ctx, `DELETE FROM referral_social_challenges WHERE provider_id = ? AND campaign = ?`, providerID, policy.Campaign); err != nil {
			return err
		}
		if _, err := conn.ExecContext(ctx, `
INSERT INTO referral_social_challenges (
    challenge_hash, provider_id, campaign, issuer_id, created_at, expires_at
) VALUES (?, ?, ?, ?, ?, ?)`, fmt.Sprintf("%x", hash[:]), providerID, policy.Campaign, issuerID, timeText(now.UTC()), timeText(expiresAt)); err != nil {
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

// socialVerificationDwell is how long a social verification stays PENDING before
// the reconciler re-checks the post and grants the capacity bonus. It bounds the
// window in which a transient (deleted/protected) post could otherwise have
// permanently inflated capacity. FIX-570 H3.
const socialVerificationDwell = SocialVerificationDwell

// CompleteSocialVerification records a social verification as PENDING. It does NOT
// grant the capacity bonus here; the bonus is granted later by
// PromoteMaturedSocialVerifications after a dwell window and a re-check. The bound
// X author id (may be empty when the API omits it) is persisted so promotion can
// confirm the post is still authored by the same account. FIX-570 H3.
func (s *Store) CompleteSocialVerification(ctx context.Context, policy ReferralPolicy, providerID, challenge, postID, authorID, method string, now time.Time) (ProviderReferral, error) {
	if err := policy.Validate(); err != nil {
		return ProviderReferral{}, err
	}
	if !policy.EnableSocialBonus {
		return ProviderReferral{}, ErrSocialDisabled
	}
	postID = strings.TrimSpace(postID)
	if postID == "" || strings.Trim(postID, "0123456789") != "" {
		return ProviderReferral{}, ErrSocialChallenge
	}
	authorID = strings.TrimSpace(authorID)
	hash := sha256.Sum256([]byte(strings.TrimSpace(challenge)))
	var out ProviderReferral
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var issuerID, expiresAt string
		var consumedAt sql.NullString
		if err := conn.QueryRowContext(ctx, `
SELECT c.issuer_id, c.expires_at, c.consumed_at
  FROM referral_social_challenges c
  JOIN referral_issuers i ON i.issuer_id = c.issuer_id AND i.revoked_at IS NULL
 WHERE c.challenge_hash = ? AND c.provider_id = ? AND c.campaign = ?`,
			fmt.Sprintf("%x", hash[:]), providerID, policy.Campaign).Scan(&issuerID, &expiresAt, &consumedAt); err != nil {
			return ErrSocialChallenge
		}
		expires, err := time.Parse(time.RFC3339, expiresAt)
		if err != nil || consumedAt.Valid || !expires.After(now.UTC()) {
			return ErrSocialChallenge
		}
		var authorValue any
		if authorID != "" {
			authorValue = authorID
		}
		// Record PENDING (granted_at NULL). The UNIQUE(post_id) constraint already
		// binds one X post to one provider, and PK(provider_id, campaign) binds one
		// verification per provider — so a post or provider cannot be double-bound.
		if _, err := conn.ExecContext(ctx, `
INSERT INTO referral_social_verifications (
    provider_id, campaign, issuer_id, post_id, verification_method, verified_at, author_id, pending_since
) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			providerID, policy.Campaign, issuerID, postID, method, timeText(now.UTC()), authorValue, timeText(now.UTC())); err != nil {
			if isConstraintFailure(err) {
				return ErrSocialChallenge
			}
			return err
		}
		if _, err := conn.ExecContext(ctx, `
UPDATE referral_social_challenges SET consumed_at = ? WHERE challenge_hash = ? AND consumed_at IS NULL`,
			timeText(now.UTC()), fmt.Sprintf("%x", hash[:])); err != nil {
			return err
		}
		var keyID string
		if err := conn.QueryRowContext(ctx, `
SELECT key_id, base_capacity, bonus_capacity FROM referral_issuers WHERE issuer_id = ?`, issuerID).Scan(&keyID, &out.BaseUses, &out.BonusUses); err != nil {
			return err
		}
		if err := conn.QueryRowContext(ctx, `SELECT COUNT(1) FROM referral_redemptions WHERE issuer_id = ?`, issuerID).Scan(&out.Used); err != nil {
			return err
		}
		var reserved int
		if err := conn.QueryRowContext(ctx, `
SELECT COUNT(1)
  FROM referral_reservations r
 WHERE r.issuer_id = ? AND r.expires_at > ?
   AND NOT EXISTS (
       SELECT 1 FROM referral_redemptions d
        WHERE d.campaign = r.campaign
          AND d.provider_id = r.provider_id
          AND d.issuer_id = r.issuer_id
   )`, issuerID, timeText(now.UTC())).Scan(&reserved); err != nil {
			return err
		}
		out.Code, err = EncodeReferralCode(policy, ReferralTypeProvider, keyID, issuerID)
		if err != nil {
			return err
		}
		out.Campaign = policy.Campaign
		out.IssuerID = issuerID
		// Bonus is not yet granted, so remaining reflects the current (un-bonused)
		// capacity. advocacy_status stays "pending_social_review" until promotion.
		out.Remaining = out.BaseUses + out.BonusUses - out.Used - reserved
		if out.Remaining < 0 {
			out.Remaining = 0
		}
		out.SocialVerified = false
		out.AdvocacyStatus = "pending_social_review"
		out.FirstServingSeen = true
		reviewDue := now.UTC().Add(SocialVerificationDwell)
		out.ReviewDueAt = &reviewDue
		return nil
	})
	return out, err
}

// PromoteMaturedSocialVerifications grants the capacity bonus for social
// verifications that have dwelled past socialVerificationDwell, but only after
// recheck confirms the post is still public and still authored by the bound
// author. The grant is idempotent (guarded by granted_at IS NULL) so no
// verification is ever granted twice. recheck receives the post id and the bound
// author id (empty when unknown) and must return nil to grant, or an error to
// mark the verification failed. FIX-570 H3.
func (s *Store) PromoteMaturedSocialVerifications(ctx context.Context, policy ReferralPolicy, now time.Time, recheck func(ctx context.Context, postID, boundAuthorID string) error) (int, error) {
	if err := policy.Validate(); err != nil {
		return 0, err
	}
	if !policy.EnableSocialBonus || recheck == nil {
		return 0, nil
	}
	cutoff := timeText(now.UTC().Add(-socialVerificationDwell))
	rows, err := s.db.QueryContext(ctx, `
SELECT provider_id, issuer_id, post_id, COALESCE(author_id, '')
  FROM referral_social_verifications
 WHERE campaign = ?
   AND granted_at IS NULL
   AND failed_at IS NULL
   AND pending_since IS NOT NULL
   AND pending_since <= ?`, policy.Campaign, cutoff)
	if err != nil {
		return 0, err
	}
	type pending struct{ providerID, issuerID, postID, authorID string }
	var matured []pending
	for rows.Next() {
		var p pending
		if err := rows.Scan(&p.providerID, &p.issuerID, &p.postID, &p.authorID); err != nil {
			rows.Close()
			return 0, err
		}
		matured = append(matured, p)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return 0, err
	}
	rows.Close()

	granted := 0
	for _, p := range matured {
		checkErr := recheck(ctx, p.postID, p.authorID)
		// FIX-570 M3: a TRANSIENT recheck failure (timeout / 429 / 5xx / transport
		// error) must NOT permanently deny the bonus. Leave the row PENDING so the
		// next reconciler tick retries it (bounded natural backoff at the tick
		// interval). Only confirmed-terminal failures (post deleted, protected, or
		// author mismatch) set failed_at.
		if checkErr != nil && errors.Is(checkErr, ErrSocialRecheckTransient) {
			continue
		}
		txErr := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
			if checkErr != nil {
				_, err := conn.ExecContext(ctx, `
UPDATE referral_social_verifications
   SET failed_at = ?
 WHERE provider_id = ? AND campaign = ? AND granted_at IS NULL AND failed_at IS NULL`,
					timeText(now.UTC()), p.providerID, policy.Campaign)
				return err
			}
			result, err := conn.ExecContext(ctx, `
UPDATE referral_social_verifications
   SET granted_at = ?
 WHERE provider_id = ? AND campaign = ? AND granted_at IS NULL AND failed_at IS NULL`,
				timeText(now.UTC()), p.providerID, policy.Campaign)
			if err != nil {
				return err
			}
			changed, err := result.RowsAffected()
			if err != nil {
				return err
			}
			if changed != 1 {
				// Already granted/failed by a concurrent tick; nothing to do.
				return nil
			}
			bonusResult, err := conn.ExecContext(ctx, `
UPDATE referral_issuers SET bonus_capacity = bonus_capacity + ? WHERE issuer_id = ? AND revoked_at IS NULL`,
				policy.SocialBonusUses, p.issuerID)
			if err != nil {
				return err
			}
			// If the issuer was revoked between verify and promotion the grant is a
			// no-op on capacity; granted_at is still set so it is not retried.
			if _, err := bonusResult.RowsAffected(); err != nil {
				return err
			}
			granted++
			return nil
		})
		if txErr != nil {
			return granted, txErr
		}
	}
	return granted, nil
}
