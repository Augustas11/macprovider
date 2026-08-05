package auth

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"database/sql"
	"encoding/base32"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
)

var (
	ErrReferralRequired  = errors.New("referral code required")
	ErrReferralInvalid   = errors.New("referral code invalid")
	ErrReferralExpired   = errors.New("referral code expired")
	ErrReferralRevoked   = errors.New("referral code revoked")
	ErrReferralExhausted = errors.New("referral code exhausted")
	ErrReferralConflict  = errors.New("provider already attributed to another referral")
)

const (
	ReferralTypeSeed     = "S"
	ReferralTypeProvider = "P"
	referralTagBytes     = 16
)

var referralPartPattern = regexp.MustCompile(`^[A-Za-z0-9_]{1,32}$`)
var referralEncoder = base32.StdEncoding.WithPadding(base32.NoPadding)

// ReferralPolicy is a caller-owned immutable snapshot. Secrets remain in
// memory; issuer rows persist only the key id needed for explicit rotation.
type ReferralPolicy struct {
	RequireForRegistration  bool
	EnableSocialBonus       bool
	Campaign                string
	PolicyVersion           string
	GrandfatherBefore       *time.Time
	GrandfatherProof        bool
	CurrentKeyID            string
	HMACKeys                map[string]string
	ProviderBaseUses        int
	SocialBonusUses         int
	SocialBonusMaxGrants    int
	ChallengeTTL            time.Duration
	SocialVerificationDwell time.Duration
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
	if p.ProviderBaseUses <= 0 {
		return fmt.Errorf("referral provider capacity must be positive")
	}
	if p.EnableSocialBonus && (p.SocialBonusUses <= 0 || p.SocialBonusMaxGrants <= 0 || p.ChallengeTTL <= 0 || p.SocialVerificationDwell <= 0) {
		return fmt.Errorf("referral social capacity, max grants, challenge ttl, and verification dwell must be positive")
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

type parsedReferralCode struct {
	Type     string
	KeyID    string
	IssuerID string
	Tag      []byte
}

func parseReferralCode(raw string) (parsedReferralCode, error) {
	parts := strings.Split(strings.TrimSpace(raw), "-")
	if len(parts) != 5 || parts[0] != "MAL1" ||
		(parts[1] != ReferralTypeSeed && parts[1] != ReferralTypeProvider) ||
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
	if (typ != ReferralTypeSeed && typ != ReferralTypeProvider) ||
		!referralPartPattern.MatchString(keyID) || !referralPartPattern.MatchString(issuerID) {
		return "", ErrReferralInvalid
	}
	tag, err := referralMAC(policy, typ, keyID, issuerID)
	if err != nil {
		return "", err
	}
	return strings.Join([]string{"MAL1", typ, keyID, issuerID, referralEncoder.EncodeToString(tag)}, "-"), nil
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
		&issuer.Type, &issuer.KeyID, &issuer.Campaign, &issuer.Base, &issuer.Bonus,
		&issuer.ExpiresAt, &issuer.RevokedAt,
	)
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
	if err := conn.QueryRowContext(ctx,
		`SELECT COUNT(1) FROM referral_redemptions WHERE issuer_id = ?`,
		parsed.IssuerID,
	).Scan(&used); err != nil {
		return ReferralValidation{}, err
	}
	remaining := issuer.Base + issuer.Bonus - used
	if remaining <= 0 {
		return ReferralValidation{
			Reason: "exhausted", Type: parsed.Type, IssuerID: parsed.IssuerID, Campaign: issuer.Campaign,
		}, ErrReferralExhausted
	}
	return ReferralValidation{
		Valid: true, Reason: "valid", Type: parsed.Type, IssuerID: parsed.IssuerID,
		Campaign: issuer.Campaign, RemainingUses: remaining,
	}, nil
}

// redeemReferralTx is called from the same SQLite transaction that creates a
// credential. Capacity therefore cannot be consumed without a corresponding
// token, and two concurrent consumers cannot overdraw an issuer.
func redeemReferralTx(ctx context.Context, conn *sql.Conn, policy ReferralPolicy, code, providerID string, now time.Time) (bool, error) {
	if !policy.RequireForRegistration {
		return false, nil
	}
	code = strings.TrimSpace(code)
	if code == "" {
		if policy.GrandfatherProof {
			var decision string
			err := conn.QueryRowContext(ctx,
				`SELECT decision FROM provider_referral_admissions WHERE provider_id = ? AND campaign = ?`,
				providerID, policy.Campaign,
			).Scan(&decision)
			// Exact bootstrap-key custody may recover a response lost after a
			// referral was already committed. The campaign-scoped admission row
			// proves policy was satisfied; accepting no code here avoids storing
			// the plaintext invite in the CLI restart journal. GrandfatherProof is
			// set only after MintBootstrapToken byte-matches the retained key and
			// rejects confirmed, ordinary, or operator-revoked ownership.
			if err == nil && (decision == "grandfathered" || decision == "referred") {
				return false, nil
			}
			if err != nil && !errors.Is(err, sql.ErrNoRows) {
				return false, err
			}
		}
		if policy.GrandfatherProof && policy.GrandfatherBefore != nil {
			var firstCreated sql.NullString
			if err := conn.QueryRowContext(ctx,
				`SELECT MIN(created_at) FROM provider_tokens WHERE provider_id = ?`, providerID,
			).Scan(&firstCreated); err != nil {
				return false, err
			}
			if firstCreated.Valid {
				first, err := time.Parse(time.RFC3339, firstCreated.String)
				if err == nil && first.Before(policy.GrandfatherBefore.UTC()) {
					_, err = conn.ExecContext(ctx, `
INSERT INTO provider_referral_admissions (provider_id, campaign, policy_version, decision, applied_at)
VALUES (?, ?, ?, 'grandfathered', ?)
ON CONFLICT(provider_id, campaign) DO NOTHING`,
						providerID, policy.Campaign, policy.PolicyVersion, timeText(now.UTC()),
					)
					return false, err
				}
			}
		}
		return false, ErrReferralRequired
	}

	var existingIssuer, existingDigest string
	err := conn.QueryRowContext(ctx, `
SELECT issuer_id, code_digest FROM referral_redemptions
 WHERE campaign = ? AND provider_id = ?`, policy.Campaign, providerID,
	).Scan(&existingIssuer, &existingDigest)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return false, err
	}
	parsed, parseErr := parseReferralCode(code)
	if parseErr != nil {
		return false, ErrReferralInvalid
	}
	digest := sha256.Sum256([]byte(code))
	presentedDigest := fmt.Sprintf("%x", digest[:])
	if err == nil {
		if existingIssuer == parsed.IssuerID && hmac.Equal([]byte(existingDigest), []byte(presentedDigest)) {
			wantMAC, macErr := referralMAC(policy, parsed.Type, parsed.KeyID, parsed.IssuerID)
			if macErr != nil || !hmac.Equal(wantMAC, parsed.Tag) {
				return false, ErrReferralInvalid
			}
			return false, nil
		}
		return false, ErrReferralConflict
	}

	validated, err := validateReferralTx(ctx, conn, policy, code, now)
	if err != nil {
		return false, err
	}
	_, err = conn.ExecContext(ctx, `
INSERT INTO referral_redemptions
    (campaign, provider_id, issuer_id, code_digest, policy_version, redeemed_at)
VALUES (?, ?, ?, ?, ?, ?)`,
		policy.Campaign, providerID, validated.IssuerID, presentedDigest,
		policy.PolicyVersion, timeText(now.UTC()),
	)
	if isConstraintFailure(err) {
		return false, ErrReferralExhausted
	}
	if err != nil {
		return false, err
	}
	_, err = conn.ExecContext(ctx, `
INSERT INTO provider_referral_admissions
    (provider_id, campaign, policy_version, decision, applied_at)
VALUES (?, ?, ?, 'referred', ?)
ON CONFLICT(provider_id, campaign) DO NOTHING`,
		providerID, policy.Campaign, policy.PolicyVersion, timeText(now.UTC()),
	)
	return true, err
}
