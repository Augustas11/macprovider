package auth

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

var (
	ErrReferralSeedExists        = errors.New("seed referral already exists")
	ErrReferralCapacityBelowUsed = errors.New("referral capacity cannot be set below redeemed uses")
)

// referralAdminSchemaStatements is kept with the privileged referral
// operations so the admin surface can be reviewed independently from referral
// admission. The audit log is append-only by API contract: this package never
// exposes update or delete operations for it.
func referralAdminSchemaStatements() []string {
	return []string{
		`CREATE TABLE IF NOT EXISTS referral_admin_audit (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			actor TEXT NOT NULL,
			reason TEXT NOT NULL,
			action TEXT NOT NULL,
			target TEXT NOT NULL,
			detail TEXT NOT NULL DEFAULT '',
			ts TEXT NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_referral_admin_audit_ts ON referral_admin_audit(ts)`,
		`CREATE TRIGGER IF NOT EXISTS referral_admin_audit_no_update
			BEFORE UPDATE ON referral_admin_audit
			BEGIN SELECT RAISE(ABORT, 'referral_admin_audit is append-only'); END`,
		`CREATE TRIGGER IF NOT EXISTS referral_admin_audit_no_delete
			BEFORE DELETE ON referral_admin_audit
			BEGIN SELECT RAISE(ABORT, 'referral_admin_audit is append-only'); END`,
	}
}

// SeedReferralCreation is returned for both dry-run and applied creation. The
// signed code is disclosed only after the issuer and audit event commit.
type SeedReferralCreation struct {
	SeedID    string
	Code      string
	MaxUses   int
	ExpiresAt *time.Time
	Applied   bool
	Recovered bool
}

// CreateSeedReferralAudited previews or atomically creates a seed issuer and
// its append-only operator audit record. Seed identifiers are immutable;
// operators use AdjustSeedReferral for later capacity changes.
func (s *Store) CreateSeedReferralAudited(ctx context.Context, policy ReferralPolicy, seedID string, maxUses int, expiresAt *time.Time, apply bool, actor, reason string, now time.Time) (SeedReferralCreation, error) {
	if err := policy.Validate(); err != nil {
		return SeedReferralCreation{}, err
	}
	seedID = strings.TrimSpace(seedID)
	actor = strings.TrimSpace(actor)
	reason = strings.TrimSpace(reason)
	if !referralPartPattern.MatchString(seedID) || maxUses <= 0 {
		return SeedReferralCreation{}, fmt.Errorf("seed id and max uses are invalid")
	}
	if apply && (actor == "" || reason == "") {
		return SeedReferralCreation{}, fmt.Errorf("actor and reason are required to create a seed")
	}
	out := SeedReferralCreation{SeedID: seedID, MaxUses: maxUses, ExpiresAt: expiresAt}
	code, err := EncodeReferralCode(policy, ReferralTypeSeed, policy.CurrentKeyID, seedID)
	if err != nil {
		return SeedReferralCreation{}, err
	}
	var expiry any
	if expiresAt != nil {
		expiry = timeText(expiresAt.UTC())
	}
	err = sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var codeType, keyID string
		var existingCapacity, existingBonus int
		var existingExpiry, providerID, revokedAt sql.NullString
		err := conn.QueryRowContext(ctx, `
SELECT code_type, key_id, base_capacity, bonus_capacity, expires_at, provider_id, revoked_at
  FROM referral_issuers
 WHERE issuer_id = ? AND campaign = ?`,
			seedID, policy.Campaign,
		).Scan(&codeType, &keyID, &existingCapacity, &existingBonus, &existingExpiry, &providerID, &revokedAt)
		switch {
		case err == nil:
			expectedExpiry, hasExpiry := expiry.(string)
			expiryMatches := (!hasExpiry && !existingExpiry.Valid) || (hasExpiry && existingExpiry.Valid && existingExpiry.String == expectedExpiry)
			if apply && codeType == ReferralTypeSeed && keyID == policy.CurrentKeyID && existingCapacity == maxUses && existingBonus == 0 && expiryMatches && !providerID.Valid && !revokedAt.Valid {
				out.Recovered = true
				return nil
			}
			return ErrReferralSeedExists
		case !errors.Is(err, sql.ErrNoRows):
			return err
		}
		if !apply {
			return nil
		}
		timestamp := timeText(now.UTC())
		_, err = conn.ExecContext(ctx, `
INSERT INTO referral_issuers (
    issuer_id, code_type, key_id, campaign, provider_id,
    base_capacity, bonus_capacity, expires_at, created_at, first_serving_at
) VALUES (?, 'S', ?, ?, NULL, ?, 0, ?, ?, ?)`,
			seedID, policy.CurrentKeyID, policy.Campaign, maxUses, expiry, timestamp, timestamp)
		if isConstraintFailure(err) {
			return ErrReferralSeedExists
		}
		if err != nil {
			return err
		}
		detail := fmt.Sprintf("code_type=S base_capacity=%d expires_at=%v", maxUses, expiry)
		if err := recordReferralAdminAuditTx(ctx, conn, actor, reason, "create_seed", policy.Campaign+"/"+seedID, detail, now); err != nil {
			return err
		}
		out.Applied = true
		return nil
	})
	if err != nil {
		return SeedReferralCreation{}, err
	}
	if out.Applied || out.Recovered {
		out.Code = code
	}
	return out, nil
}

// SeedReferralAdjustment is returned for both dry-run and applied changes.
// Used capacity is based only on durable redemptions; PR-B deliberately has no
// public reservation model.
type SeedReferralAdjustment struct {
	SeedID             string
	CurrentCapacity    int
	NewCapacity        int
	Redeemed           int
	ResultingRemaining int
	Applied            bool
}

// AdjustSeedReferral previews or applies a seed capacity change. Applying is
// attributable and transactional with its append-only audit record.
func (s *Store) AdjustSeedReferral(ctx context.Context, policy ReferralPolicy, seedID string, newCapacity int, apply bool, actor, reason string, now time.Time) (SeedReferralAdjustment, error) {
	if err := policy.Validate(); err != nil {
		return SeedReferralAdjustment{}, err
	}
	seedID = strings.TrimSpace(seedID)
	actor = strings.TrimSpace(actor)
	reason = strings.TrimSpace(reason)
	if !referralPartPattern.MatchString(seedID) || newCapacity < 0 {
		return SeedReferralAdjustment{}, ErrReferralInvalid
	}
	if apply && (actor == "" || reason == "") {
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
		if err := conn.QueryRowContext(ctx,
			`SELECT COUNT(1) FROM referral_redemptions WHERE issuer_id = ?`, seedID,
		).Scan(&out.Redeemed); err != nil {
			return err
		}
		out.ResultingRemaining = newCapacity - out.Redeemed
		if out.ResultingRemaining < 0 {
			out.ResultingRemaining = 0
		}
		if !apply {
			return nil
		}
		if newCapacity < out.Redeemed {
			return ErrReferralCapacityBelowUsed
		}
		result, err := conn.ExecContext(ctx, `
UPDATE referral_issuers
   SET base_capacity = ?
 WHERE issuer_id = ? AND campaign = ? AND code_type = 'S'`, newCapacity, seedID, policy.Campaign)
		if err != nil {
			return err
		}
		if changed, err := result.RowsAffected(); err != nil || changed != 1 {
			return ErrReferralInvalid
		}
		detail := fmt.Sprintf("base_capacity %d->%d redeemed=%d", out.CurrentCapacity, newCapacity, out.Redeemed)
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

// ReferralRevocation is the blast-radius preview or result of an issuer revoke.
// Capacity accounting is redemption-only in the reservation-neutral launch.
type ReferralRevocation struct {
	Campaign          string
	IssuerID          string
	CodeType          string
	ProviderID        string
	Redeemed          int
	RemainingCapacity int
	Applied           bool
}

// ReferralRevokeExpectation is required when applying a previewed revoke. It
// prevents an operator from acting on a stale redemption count.
type ReferralRevokeExpectation struct {
	Redeemed int
}

// RevokeReferralIssuerAudited previews or transactionally revokes an issuer and
// records the operator actor and reason. Replacement issuance is intentionally
// deferred to a later issuer-lifecycle change.
func (s *Store) RevokeReferralIssuerAudited(ctx context.Context, campaign, issuerID string, apply bool, actor, reason string, expect *ReferralRevokeExpectation, now time.Time) (ReferralRevocation, error) {
	campaign = strings.TrimSpace(campaign)
	issuerID = strings.TrimSpace(issuerID)
	actor = strings.TrimSpace(actor)
	reason = strings.TrimSpace(reason)
	if !referralPartPattern.MatchString(campaign) || !referralPartPattern.MatchString(issuerID) {
		return ReferralRevocation{}, ErrReferralInvalid
	}
	if apply && (actor == "" || reason == "") {
		return ReferralRevocation{}, fmt.Errorf("actor and reason are required to apply a revocation")
	}
	if apply && expect == nil {
		return ReferralRevocation{}, fmt.Errorf("an expected redemption count is required to apply a revocation")
	}

	out := ReferralRevocation{Campaign: campaign, IssuerID: issuerID}
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var providerID, revokedAt sql.NullString
		var baseCapacity, bonusCapacity, carriedRedemptions int
		if err := conn.QueryRowContext(ctx, `
SELECT code_type, provider_id, revoked_at, base_capacity, bonus_capacity, carried_redemptions
  FROM referral_issuers
 WHERE campaign = ? AND issuer_id = ?`, campaign, issuerID).Scan(
			&out.CodeType, &providerID, &revokedAt, &baseCapacity, &bonusCapacity, &carriedRedemptions,
		); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return ErrReferralInvalid
			}
			return err
		}
		out.ProviderID = strings.TrimSpace(providerID.String)
		if revokedAt.Valid {
			return fmt.Errorf("issuer %s is already revoked", issuerID)
		}
		if err := conn.QueryRowContext(ctx,
			`SELECT COUNT(1) FROM referral_redemptions WHERE issuer_id = ?`, issuerID,
		).Scan(&out.Redeemed); err != nil {
			return err
		}
		out.Redeemed += carriedRedemptions
		out.RemainingCapacity = baseCapacity + bonusCapacity - out.Redeemed
		if out.RemainingCapacity < 0 {
			out.RemainingCapacity = 0
		}
		if !apply {
			return nil
		}
		if expect.Redeemed != out.Redeemed {
			return fmt.Errorf("revocation snapshot drift: expected redeemed=%d but live redeemed=%d; re-run the dry-run", expect.Redeemed, out.Redeemed)
		}
		result, err := conn.ExecContext(ctx, `
UPDATE referral_issuers
   SET revoked_at = ?
 WHERE campaign = ? AND issuer_id = ? AND revoked_at IS NULL`,
			timeText(now.UTC()), campaign, issuerID)
		if err != nil {
			return err
		}
		if changed, err := result.RowsAffected(); err != nil || changed != 1 {
			return ErrReferralInvalid
		}
		detail := fmt.Sprintf("code_type=%s provider=%s redeemed=%d remaining_capacity=%d", out.CodeType, out.ProviderID, out.Redeemed, out.RemainingCapacity)
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

func recordReferralAdminAuditTx(ctx context.Context, conn *sql.Conn, actor, reason, action, target, detail string, now time.Time) error {
	_, err := conn.ExecContext(ctx, `
INSERT INTO referral_admin_audit (actor, reason, action, target, detail, ts)
VALUES (?, ?, ?, ?, ?, ?)`, actor, reason, action, target, detail, timeText(now.UTC()))
	return err
}
