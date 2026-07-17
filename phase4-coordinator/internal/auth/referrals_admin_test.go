package auth

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const (
	adminCreateOperation  = "11111111-1111-4111-8111-111111111111"
	adminAdjustOperation  = "22222222-2222-4222-8222-222222222222"
	adminRevokeOperation  = "33333333-3333-4333-8333-333333333333"
	adminReplaceOperation = "44444444-4444-4444-8444-444444444444"
)

func referralAdminTestOperation(id, actor, reason, expectedState string) ReferralAdminOperation {
	return ReferralAdminOperation{
		OperationID: id, Actor: actor, UnixUID: 501,
		Reason: reason, ExpectedState: expectedState,
	}
}

func openReferralAdminTestStore(t *testing.T) *Store {
	t.Helper()
	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	return store
}

func createReferralAdminSeed(t *testing.T, store *Store, policy ReferralPolicy, seedID string, capacity int, operationID string, now time.Time) SeedReferralCreation {
	t.Helper()
	result, err := store.CreateSeedReferralAudited(
		context.Background(), policy, seedID, capacity, nil, true,
		referralAdminTestOperation(operationID, "ops", "create "+seedID, ""), now,
	)
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func TestReferralAdminMutationsAreAuditedAndExactlyRecoverable(t *testing.T) {
	store := openReferralAdminTestStore(t)
	ctx := context.Background()
	policy := coreReferralPolicy()
	now := time.Date(2026, 7, 13, 12, 0, 0, 0, time.UTC)

	creationPreview, err := store.CreateSeedReferralAudited(
		ctx, policy, "launch", 3, nil, false, ReferralAdminOperation{}, now,
	)
	if err != nil {
		t.Fatal(err)
	}
	if creationPreview.Applied || creationPreview.Code != "" || creationPreview.ExpectedState == "" {
		t.Fatalf("creation preview=%+v", creationPreview)
	}
	createOp := referralAdminTestOperation(adminCreateOperation, "release", "open cohort", "")
	created, err := store.CreateSeedReferralAudited(ctx, policy, "launch", 3, nil, true, createOp, now)
	if err != nil {
		t.Fatal(err)
	}
	if !created.Applied || created.Recovered || created.Code == "" {
		t.Fatalf("creation result=%+v", created)
	}
	recovered, err := store.CreateSeedReferralAudited(ctx, policy, "launch", 3, nil, true, createOp, now.Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if recovered.Applied || !recovered.Recovered || recovered.Code != created.Code {
		t.Fatalf("creation recovery=%+v want code %q", recovered, created.Code)
	}

	var auditRows, unixUID int
	if err := store.db.QueryRow(`
SELECT COUNT(1), MIN(unix_uid)
  FROM referral_admin_audit
 WHERE operation_id = ?`, adminCreateOperation).Scan(&auditRows, &unixUID); err != nil {
		t.Fatal(err)
	}
	if auditRows != 1 || unixUID != 501 {
		t.Fatalf("create audit rows=%d uid=%d", auditRows, unixUID)
	}
	reusedOp := createOp
	reusedOp.Reason = "different request"
	if _, err := store.CreateSeedReferralAudited(ctx, policy, "launch", 3, nil, true, reusedOp, now); !errors.Is(err, ErrReferralOperationIDReused) {
		t.Fatalf("operation-id reuse error=%v", err)
	}

	if _, _, err := store.IssueTokenWithReferral(ctx, "provider-a", "host-a", created.Code, policy); err != nil {
		t.Fatal(err)
	}
	adjustPreview, err := store.AdjustSeedReferral(ctx, policy, "launch", 5, false, ReferralAdminOperation{}, now)
	if err != nil {
		t.Fatal(err)
	}
	if adjustPreview.Redeemed != 1 || adjustPreview.CurrentCapacity != 3 || adjustPreview.ExpectedState == "" {
		t.Fatalf("adjust preview=%+v", adjustPreview)
	}
	adjustOp := referralAdminTestOperation(adminAdjustOperation, "ops", "expand cohort", adjustPreview.ExpectedState)
	adjusted, err := store.AdjustSeedReferral(ctx, policy, "launch", 5, true, adjustOp, now)
	if err != nil {
		t.Fatal(err)
	}
	if !adjusted.Applied || adjusted.Recovered {
		t.Fatalf("adjust result=%+v", adjusted)
	}
	adjustRecovered, err := store.AdjustSeedReferral(ctx, policy, "launch", 5, true, adjustOp, now.Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if adjustRecovered.Applied || !adjustRecovered.Recovered ||
		adjustRecovered.CurrentCapacity != adjusted.CurrentCapacity ||
		adjustRecovered.ResultingRemaining != adjusted.ResultingRemaining {
		t.Fatalf("adjust recovery=%+v original=%+v", adjustRecovered, adjusted)
	}

	revokePreview, err := store.RevokeReferralIssuerAudited(
		ctx, policy.Campaign, "launch", false, ReferralAdminOperation{}, now,
	)
	if err != nil {
		t.Fatal(err)
	}
	revokeOp := referralAdminTestOperation(adminRevokeOperation, "ops", "abuse", revokePreview.ExpectedState)
	revoked, err := store.RevokeReferralIssuerAudited(ctx, policy.Campaign, "launch", true, revokeOp, now)
	if err != nil {
		t.Fatal(err)
	}
	if !revoked.Applied || revoked.Recovered {
		t.Fatalf("revoke result=%+v", revoked)
	}
	revokeRecovered, err := store.RevokeReferralIssuerAudited(
		ctx, policy.Campaign, "launch", true, revokeOp, now.Add(time.Second),
	)
	if err != nil {
		t.Fatal(err)
	}
	if revokeRecovered.Applied || !revokeRecovered.Recovered ||
		revokeRecovered.RemainingCapacity != revoked.RemainingCapacity {
		t.Fatalf("revoke recovery=%+v original=%+v", revokeRecovered, revoked)
	}

	for _, operationID := range []string{adminCreateOperation, adminAdjustOperation, adminRevokeOperation} {
		if err := store.db.QueryRow(
			`SELECT COUNT(1) FROM referral_admin_audit WHERE operation_id = ?`,
			operationID,
		).Scan(&auditRows); err != nil {
			t.Fatal(err)
		}
		if auditRows != 1 {
			t.Fatalf("operation %s audit rows=%d", operationID, auditRows)
		}
	}
	if _, err := store.db.Exec(`UPDATE referral_admin_audit SET reason = 'rewritten'`); err == nil {
		t.Fatal("append-only referral audit accepted an update")
	}
	if _, err := store.db.Exec(`DELETE FROM referral_admin_audit`); err == nil {
		t.Fatal("append-only referral audit accepted a delete")
	}
	if _, err := store.ValidateReferral(ctx, policy, created.Code, now); !errors.Is(err, ErrReferralRevoked) {
		t.Fatalf("validation after revoke error=%v", err)
	}
}

func TestReferralAdminFullStateCASRejectsRacedAdjustAndRevoke(t *testing.T) {
	store := openReferralAdminTestStore(t)
	ctx := context.Background()
	policy := coreReferralPolicy()
	now := time.Date(2026, 7, 13, 12, 0, 0, 0, time.UTC)
	createReferralAdminSeed(t, store, policy, "launch", 3, adminCreateOperation, now)

	adjustPreview, err := store.AdjustSeedReferral(ctx, policy, "launch", 6, false, ReferralAdminOperation{}, now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`UPDATE referral_issuers SET bonus_capacity = 1 WHERE issuer_id = 'launch'`); err != nil {
		t.Fatal(err)
	}
	adjustOp := referralAdminTestOperation(adminAdjustOperation, "ops", "expand", adjustPreview.ExpectedState)
	if _, err := store.AdjustSeedReferral(ctx, policy, "launch", 6, true, adjustOp, now); !errors.Is(err, ErrReferralAdminStateChanged) {
		t.Fatalf("raced adjustment error=%v", err)
	}
	var baseCapacity int
	if err := store.db.QueryRow(`SELECT base_capacity FROM referral_issuers WHERE issuer_id = 'launch'`).Scan(&baseCapacity); err != nil {
		t.Fatal(err)
	}
	if baseCapacity != 3 {
		t.Fatalf("stale adjustment overwrote capacity: %d", baseCapacity)
	}

	revokePreview, err := store.RevokeReferralIssuerAudited(
		ctx, policy.Campaign, "launch", false, ReferralAdminOperation{}, now,
	)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`UPDATE referral_issuers SET base_capacity = 4 WHERE issuer_id = 'launch'`); err != nil {
		t.Fatal(err)
	}
	revokeOp := referralAdminTestOperation(adminRevokeOperation, "ops", "retire", revokePreview.ExpectedState)
	if _, err := store.RevokeReferralIssuerAudited(ctx, policy.Campaign, "launch", true, revokeOp, now); !errors.Is(err, ErrReferralAdminStateChanged) {
		t.Fatalf("raced revoke error=%v", err)
	}
	var revokedAt *string
	if err := store.db.QueryRow(`SELECT revoked_at FROM referral_issuers WHERE issuer_id = 'launch'`).Scan(&revokedAt); err != nil {
		t.Fatal(err)
	}
	if revokedAt != nil {
		t.Fatalf("stale revoke applied: revoked_at=%v", revokedAt)
	}
}

func TestReferralAdminReplacementIsAtomicCASAndRecoverable(t *testing.T) {
	store := openReferralAdminTestStore(t)
	ctx := context.Background()
	policy := coreReferralPolicy()
	now := time.Date(2026, 7, 13, 12, 0, 0, 0, time.UTC)
	createReferralAdminSeed(t, store, policy, "launch", 3, adminCreateOperation, now)

	preview, err := store.ReplaceSeedReferralAudited(
		ctx, policy, "launch", "launch2", 5, nil, false, ReferralAdminOperation{}, now,
	)
	if err != nil {
		t.Fatal(err)
	}
	if preview.ExpectedState == "" || preview.Code != "" || preview.Applied {
		t.Fatalf("replacement preview=%+v", preview)
	}

	if _, err := store.db.Exec(`
INSERT INTO referral_issuers (
    issuer_id, code_type, key_id, campaign, provider_id,
    base_capacity, bonus_capacity, created_at, first_serving_at
) VALUES ('launch2', 'S', 'k1', ?, NULL, 1, 0, ?, ?)`,
		policy.Campaign, timeText(now), timeText(now),
	); err != nil {
		t.Fatal(err)
	}
	racedOp := referralAdminTestOperation(adminReplaceOperation, "ops", "rotate", preview.ExpectedState)
	if _, err := store.ReplaceSeedReferralAudited(
		ctx, policy, "launch", "launch2", 5, nil, true, racedOp, now,
	); !errors.Is(err, ErrReferralSeedExists) {
		t.Fatalf("successor race error=%v", err)
	}
	var oldRevokedAt *string
	if err := store.db.QueryRow(`SELECT revoked_at FROM referral_issuers WHERE issuer_id = 'launch'`).Scan(&oldRevokedAt); err != nil {
		t.Fatal(err)
	}
	if oldRevokedAt != nil {
		t.Fatalf("failed replacement revoked old seed: %v", oldRevokedAt)
	}
	if _, err := store.db.Exec(`DELETE FROM referral_issuers WHERE issuer_id = 'launch2'`); err != nil {
		t.Fatal(err)
	}

	preview, err = store.ReplaceSeedReferralAudited(
		ctx, policy, "launch", "launch2", 5, nil, false, ReferralAdminOperation{}, now,
	)
	if err != nil {
		t.Fatal(err)
	}
	replaceOp := referralAdminTestOperation(adminReplaceOperation, "ops", "rotate", preview.ExpectedState)
	replaced, err := store.ReplaceSeedReferralAudited(
		ctx, policy, "launch", "launch2", 5, nil, true, replaceOp, now,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !replaced.Applied || replaced.Recovered || replaced.Code == "" {
		t.Fatalf("replacement=%+v", replaced)
	}
	recovered, err := store.ReplaceSeedReferralAudited(
		ctx, policy, "launch", "launch2", 5, nil, true, replaceOp, now.Add(time.Second),
	)
	if err != nil {
		t.Fatal(err)
	}
	if recovered.Applied || !recovered.Recovered || recovered.Code != replaced.Code {
		t.Fatalf("replacement recovery=%+v original=%+v", recovered, replaced)
	}

	var activeNew, revokedOld, auditRows int
	if err := store.db.QueryRow(`
SELECT
    COUNT(1) FILTER (WHERE issuer_id = 'launch2' AND revoked_at IS NULL),
    COUNT(1) FILTER (WHERE issuer_id = 'launch' AND revoked_at IS NOT NULL)
  FROM referral_issuers`).Scan(&activeNew, &revokedOld); err != nil {
		t.Fatal(err)
	}
	if err := store.db.QueryRow(
		`SELECT COUNT(1) FROM referral_admin_audit WHERE operation_id = ?`,
		adminReplaceOperation,
	).Scan(&auditRows); err != nil {
		t.Fatal(err)
	}
	if activeNew != 1 || revokedOld != 1 || auditRows != 1 {
		t.Fatalf("active_new=%d revoked_old=%d audit_rows=%d", activeNew, revokedOld, auditRows)
	}
	var auditResult, auditDetail string
	if err := store.db.QueryRow(`
SELECT result, detail FROM referral_admin_audit WHERE operation_id = ?`,
		adminReplaceOperation,
	).Scan(&auditResult, &auditDetail); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(auditResult, replaced.Code) || strings.Contains(auditDetail, replaced.Code) ||
		strings.Contains(auditResult, policy.HMACKeys[policy.CurrentKeyID]) ||
		strings.Contains(auditDetail, policy.HMACKeys[policy.CurrentKeyID]) {
		t.Fatal("replacement audit persisted a raw code or HMAC secret")
	}
}

func TestReferralAdminApplyRequiresUUIDAttributionUIDAndExpectedState(t *testing.T) {
	store := openReferralAdminTestStore(t)
	policy := coreReferralPolicy()
	now := time.Now().UTC()

	for name, operation := range map[string]ReferralAdminOperation{
		"missing uuid": {Actor: "ops", UnixUID: 501, Reason: "test"},
		"bad uuid": {OperationID: "not-a-uuid", Actor: "ops", UnixUID: 501, Reason: "test"},
		"missing actor": {OperationID: adminCreateOperation, UnixUID: 501, Reason: "test"},
		"missing reason": {OperationID: adminCreateOperation, Actor: "ops", UnixUID: 501},
		"invalid uid": {OperationID: adminCreateOperation, Actor: "ops", UnixUID: -1, Reason: "test"},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := store.CreateSeedReferralAudited(
				context.Background(), policy, "launch", 1, nil, true, operation, now,
			); err == nil {
				t.Fatal("invalid attributed create unexpectedly applied")
			}
		})
	}

	createReferralAdminSeed(t, store, policy, "launch", 1, adminCreateOperation, now)
	if _, err := store.AdjustSeedReferral(
		context.Background(), policy, "launch", 2, true,
		referralAdminTestOperation(adminAdjustOperation, "ops", "expand", ""), now,
	); err == nil {
		t.Fatal("adjustment without expected state unexpectedly applied")
	}
	if _, err := store.RevokeReferralIssuerAudited(
		context.Background(), policy.Campaign, "launch", true,
		referralAdminTestOperation(adminRevokeOperation, "ops", "retire", ""), now,
	); err == nil {
		t.Fatal("revocation without expected state unexpectedly applied")
	}
}
