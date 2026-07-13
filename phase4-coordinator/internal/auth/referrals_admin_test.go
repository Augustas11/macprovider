package auth

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"
)

func TestReferralAdminSeedLifecycleIsAuditedAndRedemptionOnly(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	ctx := context.Background()
	policy := coreReferralPolicy()
	now := time.Date(2026, 7, 13, 12, 0, 0, 0, time.UTC)

	code, err := store.CreateSeedReferral(ctx, policy, "launch", 3, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.CreateSeedReferral(ctx, policy, "launch", 9, nil); !errors.Is(err, ErrReferralSeedExists) {
		t.Fatalf("duplicate seed error=%v, want ErrReferralSeedExists", err)
	}
	if _, _, err := store.IssueTokenWithReferral(ctx, "provider-a", "host-a", code, policy); err != nil {
		t.Fatal(err)
	}

	preview, err := store.AdjustSeedReferral(ctx, policy, "launch", 0, false, "", "", now)
	if err != nil {
		t.Fatal(err)
	}
	if preview.Redeemed != 1 || preview.CurrentCapacity != 3 || preview.ResultingRemaining != 0 || preview.Applied {
		t.Fatalf("unexpected preview: %+v", preview)
	}
	if _, err := store.AdjustSeedReferral(ctx, policy, "launch", 0, true, "ops", "shrink", now); !errors.Is(err, ErrReferralCapacityBelowUsed) {
		t.Fatalf("below-used adjustment error=%v", err)
	}
	if _, err := store.AdjustSeedReferral(ctx, policy, "launch", 5, true, "ops", "expand cohort", now); err != nil {
		t.Fatal(err)
	}

	var capacity, auditRows int
	if err := store.db.QueryRow(`SELECT base_capacity FROM referral_issuers WHERE issuer_id = 'launch'`).Scan(&capacity); err != nil {
		t.Fatal(err)
	}
	if err := store.db.QueryRow(`SELECT COUNT(1) FROM referral_admin_audit WHERE action = 'adjust_seed' AND actor = 'ops' AND reason = 'expand cohort'`).Scan(&auditRows); err != nil {
		t.Fatal(err)
	}
	if capacity != 5 || auditRows != 1 {
		t.Fatalf("capacity=%d audit_rows=%d, want 5/1", capacity, auditRows)
	}
	if _, err := store.db.Exec(`UPDATE referral_admin_audit SET reason = 'rewritten'`); err == nil {
		t.Fatal("append-only referral audit accepted an update")
	}
	if _, err := store.db.Exec(`DELETE FROM referral_admin_audit`); err == nil {
		t.Fatal("append-only referral audit accepted a delete")
	}

	revokePreview, err := store.RevokeReferralIssuerAudited(ctx, policy.Campaign, "launch", false, "", "", nil, now)
	if err != nil {
		t.Fatal(err)
	}
	if revokePreview.Redeemed != 1 || revokePreview.RemainingCapacity != 4 {
		t.Fatalf("unexpected revoke preview: %+v", revokePreview)
	}
	if _, err := store.RevokeReferralIssuerAudited(ctx, policy.Campaign, "launch", true, "ops", "abuse", &ReferralRevokeExpectation{Redeemed: 0}, now); err == nil {
		t.Fatal("stale revoke expectation unexpectedly applied")
	}
	result, err := store.RevokeReferralIssuerAudited(ctx, policy.Campaign, "launch", true, "ops", "abuse", &ReferralRevokeExpectation{Redeemed: 1}, now)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Applied {
		t.Fatalf("revoke result=%+v", result)
	}
	if err := store.db.QueryRow(`SELECT COUNT(1) FROM referral_admin_audit WHERE action = 'revoke_issuer' AND actor = 'ops' AND reason = 'abuse'`).Scan(&auditRows); err != nil {
		t.Fatal(err)
	}
	if auditRows != 1 {
		t.Fatalf("revoke audit rows=%d, want 1", auditRows)
	}
	if _, err := store.ValidateReferral(ctx, policy, code, now); !errors.Is(err, ErrReferralRevoked) {
		t.Fatalf("validation after revoke error=%v, want revoked", err)
	}
}

func TestReferralAdminApplyRequiresAttributionAndPreviewConfirmation(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := coreReferralPolicy()
	if _, err := store.CreateSeedReferral(context.Background(), policy, "launch", 1, nil); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	if _, err := store.AdjustSeedReferral(context.Background(), policy, "launch", 2, true, "", "", now); err == nil {
		t.Fatal("unattributed adjustment unexpectedly applied")
	}
	if _, err := store.RevokeReferralIssuerAudited(context.Background(), policy.Campaign, "launch", true, "ops", "reason", nil, now); err == nil {
		t.Fatal("revoke without confirmed preview unexpectedly applied")
	}
}
