package auth

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	"github.com/google/uuid"
)

var (
	ErrReferralSeedExists         = errors.New("seed referral already exists")
	ErrReferralCapacityBelowUsed  = errors.New("referral capacity cannot be set below redeemed uses")
	ErrReferralAdminStateChanged  = errors.New("referral admin expected state changed")
	ErrReferralOperationIDReused  = errors.New("referral admin operation id was reused for a different request")
	ErrReferralReplacementInvalid = errors.New("referral seed replacement is invalid")
)

// ReferralAdminOperation is supplied only for an applied mutation. OperationID
// is a caller-generated UUID and is the durable idempotency key. Actor is the
// operator's claimed identity; UnixUID is the effective OS identity observed by
// the local CLI. ExpectedState is the opaque full-state digest printed by the
// corresponding dry-run.
type ReferralAdminOperation struct {
	OperationID   string
	Actor         string
	UnixUID       int
	Reason        string
	ExpectedState string
}

// referralAdminSchemaStatements is kept with the privileged referral
// operations so the admin surface can be reviewed independently from referral
// admission. The audit log is append-only by API contract: this package never
// exposes update or delete operations for it.
func referralAdminSchemaStatements() []string {
	return []string{
		`CREATE TABLE IF NOT EXISTS referral_admin_audit (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			operation_id TEXT NOT NULL UNIQUE,
			actor TEXT NOT NULL,
			unix_uid INTEGER NOT NULL CHECK(unix_uid >= 0),
			reason TEXT NOT NULL,
			action TEXT NOT NULL,
			target TEXT NOT NULL,
			expected_state TEXT NOT NULL,
			request_fingerprint TEXT NOT NULL,
			result TEXT NOT NULL,
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
	SeedID        string
	Code          string
	MaxUses       int
	ExpiresAt     *time.Time
	ExpectedState string
	Applied       bool
	Recovered     bool
}

// CreateSeedReferralAudited previews or atomically creates a seed issuer and
// its append-only operator audit record. A retry with the exact same operation
// UUID recovers the original response without a second issuer or audit row.
func (s *Store) CreateSeedReferralAudited(
	ctx context.Context,
	policy ReferralPolicy,
	seedID string,
	maxUses int,
	expiresAt *time.Time,
	apply bool,
	operation ReferralAdminOperation,
	now time.Time,
) (SeedReferralCreation, error) {
	if err := policy.Validate(); err != nil {
		return SeedReferralCreation{}, err
	}
	seedID = strings.TrimSpace(seedID)
	if !referralPartPattern.MatchString(seedID) || maxUses <= 0 {
		return SeedReferralCreation{}, fmt.Errorf("seed id and max uses are invalid")
	}
	if apply {
		var err error
		operation, err = normalizeReferralAdminOperation(operation, false)
		if err != nil {
			return SeedReferralCreation{}, err
		}
	}

	expiryText, expiryValue := referralAdminExpiry(expiresAt)
	target := policy.Campaign + "/" + seedID
	expectedState := referralAdminAbsentExpectation(policy.Campaign, seedID)
	requestFingerprint := referralAdminRequestFingerprint(struct {
		Policy        string `json:"policy"`
		SeedID        string `json:"seed_id"`
		MaxUses       int    `json:"max_uses"`
		ExpiresAt     string `json:"expires_at"`
		ExpectedState string `json:"expected_state"`
	}{
		Policy: referralAdminPolicyFingerprint(policy), SeedID: seedID,
		MaxUses: maxUses, ExpiresAt: expiryText, ExpectedState: expectedState,
	})
	out := SeedReferralCreation{
		SeedID: seedID, MaxUses: maxUses, ExpiresAt: cloneReferralAdminTime(expiresAt),
		ExpectedState: expectedState,
	}
	code, err := EncodeReferralCode(policy, ReferralTypeSeed, policy.CurrentKeyID, seedID)
	if err != nil {
		return SeedReferralCreation{}, err
	}

	err = sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		if apply {
			recovered, err := recoverReferralAdminResultTx(
				ctx, conn, operation, "create_seed", target, expectedState, requestFingerprint, &out,
			)
			if err != nil {
				return err
			}
			if recovered {
				out.Applied = false
				out.Recovered = true
				return nil
			}
		}

		_, found, err := loadReferralIssuerAdminStateTx(ctx, conn, policy.Campaign, seedID)
		if err != nil {
			return err
		}
		if found {
			return ErrReferralSeedExists
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
			seedID, policy.CurrentKeyID, policy.Campaign, maxUses, expiryValue, timestamp, timestamp)
		if isConstraintFailure(err) {
			return ErrReferralSeedExists
		}
		if err != nil {
			return err
		}
		out.Applied = true
		persisted := out
		persisted.Code = ""
		detail := fmt.Sprintf("code_type=S base_capacity=%d expires_at=%s", maxUses, expiryText)
		return recordReferralAdminAuditTx(
			ctx, conn, operation, "create_seed", target, expectedState,
			requestFingerprint, detail, persisted, now,
		)
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
// ExpectedState binds every issuer field plus the durable redemption count.
type SeedReferralAdjustment struct {
	SeedID               string
	CurrentCapacity      int
	CurrentBonusCapacity int
	NewCapacity          int
	Redeemed             int
	ResultingRemaining   int
	ExpectedState        string
	Applied              bool
	Recovered            bool
}

// AdjustSeedReferral previews or applies a seed capacity change. Applied
// requests require the exact state digest returned by a dry-run.
func (s *Store) AdjustSeedReferral(
	ctx context.Context,
	policy ReferralPolicy,
	seedID string,
	newCapacity int,
	apply bool,
	operation ReferralAdminOperation,
	now time.Time,
) (SeedReferralAdjustment, error) {
	if err := policy.Validate(); err != nil {
		return SeedReferralAdjustment{}, err
	}
	seedID = strings.TrimSpace(seedID)
	if !referralPartPattern.MatchString(seedID) || newCapacity < 0 {
		return SeedReferralAdjustment{}, ErrReferralInvalid
	}
	if apply {
		var err error
		operation, err = normalizeReferralAdminOperation(operation, true)
		if err != nil {
			return SeedReferralAdjustment{}, err
		}
	}

	target := policy.Campaign + "/" + seedID
	requestFingerprint := referralAdminRequestFingerprint(struct {
		Policy        string `json:"policy"`
		SeedID        string `json:"seed_id"`
		NewCapacity   int    `json:"new_capacity"`
		ExpectedState string `json:"expected_state"`
	}{
		Policy: referralAdminPolicyFingerprint(policy), SeedID: seedID,
		NewCapacity: newCapacity, ExpectedState: operation.ExpectedState,
	})
	out := SeedReferralAdjustment{SeedID: seedID, NewCapacity: newCapacity}
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		if apply {
			recovered, err := recoverReferralAdminResultTx(
				ctx, conn, operation, "adjust_seed", target, operation.ExpectedState, requestFingerprint, &out,
			)
			if err != nil {
				return err
			}
			if recovered {
				out.Applied = false
				out.Recovered = true
				return nil
			}
		}

		state, found, err := loadReferralIssuerAdminStateTx(ctx, conn, policy.Campaign, seedID)
		if err != nil {
			return err
		}
		if !found || state.CodeType != ReferralTypeSeed || state.RevokedAt != "" {
			return ErrReferralInvalid
		}
		out.CurrentCapacity = state.BaseCapacity
		out.CurrentBonusCapacity = state.BonusCapacity
		out.Redeemed = state.Redeemed
		out.ResultingRemaining = newCapacity + state.BonusCapacity - state.Redeemed
		if out.ResultingRemaining < 0 {
			out.ResultingRemaining = 0
		}
		out.ExpectedState = referralAdminStateExpectation(state)
		if !apply {
			return nil
		}
		if operation.ExpectedState != out.ExpectedState {
			return fmt.Errorf("%w: re-run the dry-run", ErrReferralAdminStateChanged)
		}
		if newCapacity+state.BonusCapacity < state.Redeemed {
			return ErrReferralCapacityBelowUsed
		}
		result, err := conn.ExecContext(ctx, `
UPDATE referral_issuers
   SET base_capacity = ?
 WHERE issuer_id = ?
   AND campaign = ?
   AND code_type = 'S'
   AND base_capacity = ?
   AND bonus_capacity = ?
   AND revoked_at IS NULL`,
			newCapacity, seedID, policy.Campaign, state.BaseCapacity, state.BonusCapacity)
		if err != nil {
			return err
		}
		if changed, err := result.RowsAffected(); err != nil || changed != 1 {
			return ErrReferralAdminStateChanged
		}
		out.Applied = true
		detail := fmt.Sprintf(
			"base_capacity %d->%d bonus_capacity=%d redeemed=%d",
			state.BaseCapacity, newCapacity, state.BonusCapacity, state.Redeemed,
		)
		return recordReferralAdminAuditTx(
			ctx, conn, operation, "adjust_seed", target, operation.ExpectedState,
			requestFingerprint, detail, out, now,
		)
	})
	if err != nil {
		return SeedReferralAdjustment{}, err
	}
	return out, nil
}

// ReferralRevocation is the blast-radius preview or result of an issuer revoke.
type ReferralRevocation struct {
	Campaign          string
	IssuerID          string
	CodeType          string
	ProviderID        string
	BaseCapacity      int
	BonusCapacity     int
	Redeemed          int
	RemainingCapacity int
	ExpectedState     string
	Applied           bool
	Recovered         bool
}

// RevokeReferralIssuerAudited previews or transactionally revokes an issuer and
// records the operator's claimed actor, effective UID, reason, expected full
// state, and exact result. An exact operation retry recovers that result.
func (s *Store) RevokeReferralIssuerAudited(
	ctx context.Context,
	campaign string,
	issuerID string,
	apply bool,
	operation ReferralAdminOperation,
	now time.Time,
) (ReferralRevocation, error) {
	campaign = strings.TrimSpace(campaign)
	issuerID = strings.TrimSpace(issuerID)
	if !referralPartPattern.MatchString(campaign) || !referralPartPattern.MatchString(issuerID) {
		return ReferralRevocation{}, ErrReferralInvalid
	}
	if apply {
		var err error
		operation, err = normalizeReferralAdminOperation(operation, true)
		if err != nil {
			return ReferralRevocation{}, err
		}
	}

	target := campaign + "/" + issuerID
	requestFingerprint := referralAdminRequestFingerprint(struct {
		Campaign      string `json:"campaign"`
		IssuerID      string `json:"issuer_id"`
		ExpectedState string `json:"expected_state"`
	}{Campaign: campaign, IssuerID: issuerID, ExpectedState: operation.ExpectedState})
	out := ReferralRevocation{Campaign: campaign, IssuerID: issuerID}
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		if apply {
			recovered, err := recoverReferralAdminResultTx(
				ctx, conn, operation, "revoke_issuer", target, operation.ExpectedState, requestFingerprint, &out,
			)
			if err != nil {
				return err
			}
			if recovered {
				out.Applied = false
				out.Recovered = true
				return nil
			}
		}

		state, found, err := loadReferralIssuerAdminStateTx(ctx, conn, campaign, issuerID)
		if err != nil {
			return err
		}
		if !found || state.RevokedAt != "" {
			return ErrReferralInvalid
		}
		out.CodeType = state.CodeType
		out.ProviderID = state.ProviderID
		out.BaseCapacity = state.BaseCapacity
		out.BonusCapacity = state.BonusCapacity
		out.Redeemed = state.Redeemed
		out.RemainingCapacity = state.BaseCapacity + state.BonusCapacity - state.Redeemed
		if out.RemainingCapacity < 0 {
			out.RemainingCapacity = 0
		}
		out.ExpectedState = referralAdminStateExpectation(state)
		if !apply {
			return nil
		}
		if operation.ExpectedState != out.ExpectedState {
			return fmt.Errorf("%w: re-run the dry-run", ErrReferralAdminStateChanged)
		}
		result, err := conn.ExecContext(ctx, `
UPDATE referral_issuers
   SET revoked_at = ?
 WHERE campaign = ?
   AND issuer_id = ?
   AND base_capacity = ?
   AND bonus_capacity = ?
   AND revoked_at IS NULL`,
			timeText(now.UTC()), campaign, issuerID, state.BaseCapacity, state.BonusCapacity)
		if err != nil {
			return err
		}
		if changed, err := result.RowsAffected(); err != nil || changed != 1 {
			return ErrReferralAdminStateChanged
		}
		out.Applied = true
		detail := fmt.Sprintf(
			"code_type=%s provider=%s base_capacity=%d bonus_capacity=%d redeemed=%d remaining_capacity=%d",
			out.CodeType, out.ProviderID, out.BaseCapacity, out.BonusCapacity,
			out.Redeemed, out.RemainingCapacity,
		)
		return recordReferralAdminAuditTx(
			ctx, conn, operation, "revoke_issuer", target, operation.ExpectedState,
			requestFingerprint, detail, out, now,
		)
	})
	if err != nil {
		return ReferralRevocation{}, err
	}
	return out, nil
}

// SeedReferralReplacement is the preview or result of atomically retiring one
// seed issuer and creating its successor.
type SeedReferralReplacement struct {
	Campaign             string
	OldSeedID            string
	NewSeedID            string
	OldBaseCapacity      int
	OldBonusCapacity     int
	OldRedeemed          int
	OldRemainingCapacity int
	NewMaxUses           int
	NewExpiresAt         *time.Time
	Code                 string
	ExpectedState        string
	Applied              bool
	Recovered            bool
}

// ReplaceSeedReferralAudited atomically revokes an active seed and creates its
// successor with one append-only audit event. The dry-run digest binds the full
// old issuer state and the absence of the requested successor.
func (s *Store) ReplaceSeedReferralAudited(
	ctx context.Context,
	policy ReferralPolicy,
	oldSeedID string,
	newSeedID string,
	newMaxUses int,
	newExpiresAt *time.Time,
	apply bool,
	operation ReferralAdminOperation,
	now time.Time,
) (SeedReferralReplacement, error) {
	if err := policy.Validate(); err != nil {
		return SeedReferralReplacement{}, err
	}
	oldSeedID = strings.TrimSpace(oldSeedID)
	newSeedID = strings.TrimSpace(newSeedID)
	if !referralPartPattern.MatchString(oldSeedID) ||
		!referralPartPattern.MatchString(newSeedID) ||
		oldSeedID == newSeedID || newMaxUses <= 0 {
		return SeedReferralReplacement{}, ErrReferralReplacementInvalid
	}
	if apply {
		var err error
		operation, err = normalizeReferralAdminOperation(operation, true)
		if err != nil {
			return SeedReferralReplacement{}, err
		}
	}

	expiryText, expiryValue := referralAdminExpiry(newExpiresAt)
	target := policy.Campaign + "/" + oldSeedID + "->" + newSeedID
	requestFingerprint := referralAdminRequestFingerprint(struct {
		Policy        string `json:"policy"`
		OldSeedID     string `json:"old_seed_id"`
		NewSeedID     string `json:"new_seed_id"`
		NewMaxUses    int    `json:"new_max_uses"`
		NewExpiresAt  string `json:"new_expires_at"`
		ExpectedState string `json:"expected_state"`
	}{
		Policy: referralAdminPolicyFingerprint(policy), OldSeedID: oldSeedID,
		NewSeedID: newSeedID, NewMaxUses: newMaxUses, NewExpiresAt: expiryText,
		ExpectedState: operation.ExpectedState,
	})
	out := SeedReferralReplacement{
		Campaign: policy.Campaign, OldSeedID: oldSeedID, NewSeedID: newSeedID,
		NewMaxUses: newMaxUses, NewExpiresAt: cloneReferralAdminTime(newExpiresAt),
	}
	code, err := EncodeReferralCode(policy, ReferralTypeSeed, policy.CurrentKeyID, newSeedID)
	if err != nil {
		return SeedReferralReplacement{}, err
	}

	err = sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		if apply {
			recovered, err := recoverReferralAdminResultTx(
				ctx, conn, operation, "replace_seed", target, operation.ExpectedState, requestFingerprint, &out,
			)
			if err != nil {
				return err
			}
			if recovered {
				out.Applied = false
				out.Recovered = true
				return nil
			}
		}

		oldState, found, err := loadReferralIssuerAdminStateTx(ctx, conn, policy.Campaign, oldSeedID)
		if err != nil {
			return err
		}
		if !found || oldState.CodeType != ReferralTypeSeed || oldState.RevokedAt != "" {
			return ErrReferralReplacementInvalid
		}
		if _, successorFound, err := loadReferralIssuerAdminStateTx(ctx, conn, policy.Campaign, newSeedID); err != nil {
			return err
		} else if successorFound {
			return ErrReferralSeedExists
		}

		out.OldBaseCapacity = oldState.BaseCapacity
		out.OldBonusCapacity = oldState.BonusCapacity
		out.OldRedeemed = oldState.Redeemed
		out.OldRemainingCapacity = oldState.BaseCapacity + oldState.BonusCapacity - oldState.Redeemed
		if out.OldRemainingCapacity < 0 {
			out.OldRemainingCapacity = 0
		}
		out.ExpectedState = referralAdminReplacementExpectation(oldState, newSeedID)
		if !apply {
			return nil
		}
		if operation.ExpectedState != out.ExpectedState {
			return fmt.Errorf("%w: re-run the dry-run", ErrReferralAdminStateChanged)
		}

		timestamp := timeText(now.UTC())
		result, err := conn.ExecContext(ctx, `
UPDATE referral_issuers
   SET revoked_at = ?
 WHERE campaign = ?
   AND issuer_id = ?
   AND base_capacity = ?
   AND bonus_capacity = ?
   AND revoked_at IS NULL`,
			timestamp, policy.Campaign, oldSeedID, oldState.BaseCapacity, oldState.BonusCapacity)
		if err != nil {
			return err
		}
		if changed, err := result.RowsAffected(); err != nil || changed != 1 {
			return ErrReferralAdminStateChanged
		}
		_, err = conn.ExecContext(ctx, `
INSERT INTO referral_issuers (
    issuer_id, code_type, key_id, campaign, provider_id,
    base_capacity, bonus_capacity, expires_at, created_at, first_serving_at
) VALUES (?, 'S', ?, ?, NULL, ?, 0, ?, ?, ?)`,
			newSeedID, policy.CurrentKeyID, policy.Campaign, newMaxUses,
			expiryValue, timestamp, timestamp)
		if isConstraintFailure(err) {
			return ErrReferralSeedExists
		}
		if err != nil {
			return err
		}
		out.Applied = true
		persisted := out
		persisted.Code = ""
		detail := fmt.Sprintf(
			"old_seed=%s old_base_capacity=%d old_bonus_capacity=%d old_redeemed=%d new_seed=%s new_base_capacity=%d new_expires_at=%s",
			oldSeedID, oldState.BaseCapacity, oldState.BonusCapacity, oldState.Redeemed,
			newSeedID, newMaxUses, expiryText,
		)
		return recordReferralAdminAuditTx(
			ctx, conn, operation, "replace_seed", target, operation.ExpectedState,
			requestFingerprint, detail, persisted, now,
		)
	})
	if err != nil {
		return SeedReferralReplacement{}, err
	}
	if out.Applied || out.Recovered {
		out.Code = code
	}
	return out, nil
}

type referralIssuerAdminState struct {
	Campaign      string `json:"campaign"`
	IssuerID      string `json:"issuer_id"`
	CodeType      string `json:"code_type"`
	KeyID         string `json:"key_id"`
	ProviderID    string `json:"provider_id"`
	BaseCapacity  int    `json:"base_capacity"`
	BonusCapacity int    `json:"bonus_capacity"`
	ExpiresAt     string `json:"expires_at"`
	RevokedAt     string `json:"revoked_at"`
	Redeemed      int    `json:"redeemed"`
}

func loadReferralIssuerAdminStateTx(
	ctx context.Context,
	conn *sql.Conn,
	campaign string,
	issuerID string,
) (referralIssuerAdminState, bool, error) {
	state := referralIssuerAdminState{Campaign: campaign, IssuerID: issuerID}
	var providerID, expiresAt, revokedAt sql.NullString
	err := conn.QueryRowContext(ctx, `
SELECT code_type, key_id, provider_id, base_capacity, bonus_capacity, expires_at, revoked_at
  FROM referral_issuers
 WHERE campaign = ? AND issuer_id = ?`,
		campaign, issuerID,
	).Scan(
		&state.CodeType, &state.KeyID, &providerID, &state.BaseCapacity,
		&state.BonusCapacity, &expiresAt, &revokedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return referralIssuerAdminState{}, false, nil
	}
	if err != nil {
		return referralIssuerAdminState{}, false, err
	}
	state.ProviderID = providerID.String
	state.ExpiresAt = expiresAt.String
	state.RevokedAt = revokedAt.String
	if err := conn.QueryRowContext(ctx,
		`SELECT COUNT(1) FROM referral_redemptions WHERE issuer_id = ?`,
		issuerID,
	).Scan(&state.Redeemed); err != nil {
		return referralIssuerAdminState{}, false, err
	}
	return state, true, nil
}

func normalizeReferralAdminOperation(operation ReferralAdminOperation, requireExpectedState bool) (ReferralAdminOperation, error) {
	parsed, err := uuid.Parse(strings.TrimSpace(operation.OperationID))
	if err != nil || parsed == uuid.Nil {
		return ReferralAdminOperation{}, fmt.Errorf("operation id must be a non-nil UUID")
	}
	operation.OperationID = parsed.String()
	operation.Actor = strings.TrimSpace(operation.Actor)
	operation.Reason = strings.TrimSpace(operation.Reason)
	operation.ExpectedState = strings.TrimSpace(operation.ExpectedState)
	if operation.Actor == "" || operation.Reason == "" {
		return ReferralAdminOperation{}, fmt.Errorf("actor and reason are required to apply a referral admin operation")
	}
	if operation.UnixUID < 0 {
		return ReferralAdminOperation{}, fmt.Errorf("effective unix uid must be non-negative")
	}
	if requireExpectedState && !isReferralAdminStateDigest(operation.ExpectedState) {
		return ReferralAdminOperation{}, fmt.Errorf("expected state must be the 64-character digest from the dry-run")
	}
	return operation, nil
}

func isReferralAdminStateDigest(value string) bool {
	if len(value) != sha256.Size*2 || value != strings.ToLower(value) {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}

func referralAdminStateExpectation(state referralIssuerAdminState) string {
	return referralAdminRequestFingerprint(state)
}

func referralAdminReplacementExpectation(state referralIssuerAdminState, newSeedID string) string {
	return referralAdminRequestFingerprint(struct {
		OldState  referralIssuerAdminState `json:"old_state"`
		NewSeedID string                   `json:"new_seed_id"`
		NewAbsent bool                     `json:"new_absent"`
	}{OldState: state, NewSeedID: newSeedID, NewAbsent: true})
}

func referralAdminAbsentExpectation(campaign, issuerID string) string {
	return referralAdminRequestFingerprint(struct {
		Campaign string `json:"campaign"`
		IssuerID string `json:"issuer_id"`
		Absent   bool   `json:"absent"`
	}{Campaign: campaign, IssuerID: issuerID, Absent: true})
}

func referralAdminPolicyFingerprint(policy ReferralPolicy) string {
	return referralAdminRequestFingerprint(struct {
		Campaign      string `json:"campaign"`
		PolicyVersion string `json:"policy_version"`
		CurrentKeyID  string `json:"current_key_id"`
		CurrentSecret string `json:"current_secret"`
	}{
		Campaign: policy.Campaign, PolicyVersion: policy.PolicyVersion,
		CurrentKeyID: policy.CurrentKeyID, CurrentSecret: policy.HMACKeys[policy.CurrentKeyID],
	})
}

func referralAdminRequestFingerprint(value any) string {
	encoded, err := json.Marshal(value)
	if err != nil {
		panic(fmt.Sprintf("marshal referral admin fingerprint: %v", err))
	}
	sum := sha256.Sum256(encoded)
	return hex.EncodeToString(sum[:])
}

func referralAdminExpiry(value *time.Time) (string, any) {
	if value == nil {
		return "", nil
	}
	text := timeText(value.UTC())
	return text, text
}

func cloneReferralAdminTime(value *time.Time) *time.Time {
	if value == nil {
		return nil
	}
	cloned := value.UTC()
	return &cloned
}

func recoverReferralAdminResultTx(
	ctx context.Context,
	conn *sql.Conn,
	operation ReferralAdminOperation,
	action string,
	target string,
	expectedState string,
	requestFingerprint string,
	out any,
) (bool, error) {
	var actor, reason, storedAction, storedTarget, storedExpected, storedFingerprint, result string
	var unixUID int
	err := conn.QueryRowContext(ctx, `
SELECT actor, unix_uid, reason, action, target, expected_state, request_fingerprint, result
  FROM referral_admin_audit
 WHERE operation_id = ?`,
		operation.OperationID,
	).Scan(
		&actor, &unixUID, &reason, &storedAction, &storedTarget,
		&storedExpected, &storedFingerprint, &result,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if actor != operation.Actor ||
		unixUID != operation.UnixUID ||
		reason != operation.Reason ||
		storedAction != action ||
		storedTarget != target ||
		storedExpected != expectedState ||
		storedFingerprint != requestFingerprint {
		return false, ErrReferralOperationIDReused
	}
	if err := json.Unmarshal([]byte(result), out); err != nil {
		return false, fmt.Errorf("decode referral admin replay result: %w", err)
	}
	return true, nil
}

func recordReferralAdminAuditTx(
	ctx context.Context,
	conn *sql.Conn,
	operation ReferralAdminOperation,
	action string,
	target string,
	expectedState string,
	requestFingerprint string,
	detail string,
	result any,
	now time.Time,
) error {
	encodedResult, err := json.Marshal(result)
	if err != nil {
		return fmt.Errorf("encode referral admin result: %w", err)
	}
	_, err = conn.ExecContext(ctx, `
INSERT INTO referral_admin_audit (
    operation_id, actor, unix_uid, reason, action, target,
    expected_state, request_fingerprint, result, detail, ts
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		operation.OperationID, operation.Actor, operation.UnixUID, operation.Reason,
		action, target, expectedState, requestFingerprint, string(encodedResult),
		detail, timeText(now.UTC()),
	)
	if isConstraintFailure(err) {
		return ErrReferralOperationIDReused
	}
	return err
}
