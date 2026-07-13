package auth

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func socialReferralPolicy() ReferralPolicy {
	policy := coreReferralPolicy()
	policy.EnableSocialBonus = true
	policy.SocialBonusUses = 2
	policy.ChallengeTTL = 15 * time.Minute
	return policy
}

func openSocialStore(t *testing.T) *Store {
	t.Helper()
	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	return store
}

func createPendingSocialVerification(t *testing.T, store *Store, policy ReferralPolicy, providerID string, now time.Time) (ProviderReferral, SocialChallenge) {
	t.Helper()
	status, err := store.EnsureProviderReferral(context.Background(), policy, providerID, now.Add(-time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	challenge, err := store.CreateSocialChallenge(context.Background(), policy, providerID, now)
	if err != nil {
		t.Fatal(err)
	}
	status, err = store.CompleteSocialVerification(
		context.Background(), policy, providerID, challenge.Cleartext,
		"123456789", "456", "x_api", now,
	)
	if err != nil {
		t.Fatal(err)
	}
	return status, challenge
}

func TestProviderInviteAppearsOnlyAfterFirstVerifiedServing(t *testing.T) {
	store := openSocialStore(t)
	policy := socialReferralPolicy()
	ctx := context.Background()
	providerID := "provider-first-serving"
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)

	locked, err := store.ProviderReferralStatus(ctx, policy, providerID)
	if !errors.Is(err, ErrReferralLocked) || locked.SocialState != SocialStateLocked || locked.Code != "" {
		t.Fatalf("locked status=%+v err=%v", locked, err)
	}
	issued, err := store.EnsureProviderReferral(ctx, policy, providerID, now)
	if err != nil {
		t.Fatal(err)
	}
	if !issued.FirstServingSeen || issued.SocialState != SocialStateEligible ||
		issued.BaseCapacity != 1 || issued.BonusCapacity != 0 || issued.Redemptions != 0 || issued.Remaining != 1 ||
		!strings.HasPrefix(issued.Code, "MAL1-P-") {
		t.Fatalf("issued status=%+v", issued)
	}

	again, err := store.EnsureProviderReferral(ctx, policy, providerID, now.Add(time.Hour))
	if err != nil || again.IssuerID != issued.IssuerID || again.Code != issued.Code {
		t.Fatalf("idempotent ensure=%+v err=%v", again, err)
	}
}

func TestSocialVerificationIsAuthorBoundPendingThenGrantedOnce(t *testing.T) {
	store := openSocialStore(t)
	policy := socialReferralPolicy()
	ctx := context.Background()
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	providerID := "provider-social"

	if _, err := store.EnsureProviderReferral(ctx, policy, providerID, now.Add(-time.Minute)); err != nil {
		t.Fatal(err)
	}
	challenge, err := store.CreateSocialChallenge(ctx, policy, providerID, now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.CompleteSocialVerification(ctx, policy, providerID, challenge.Cleartext, "123", "", "x_api", now); !errors.Is(err, ErrSocialChallenge) {
		t.Fatalf("empty author error=%v, want social challenge", err)
	}
	if _, err := store.CompleteSocialVerification(ctx, policy, providerID, challenge.Cleartext, "not-numeric", "123", "x_api", now); !errors.Is(err, ErrSocialChallenge) {
		t.Fatalf("non-numeric post error=%v, want social challenge", err)
	}
	if _, err := store.CompleteSocialVerification(ctx, policy, providerID, challenge.Cleartext, "123", strings.Repeat("1", 25), "x_api", now); !errors.Is(err, ErrSocialChallenge) {
		t.Fatalf("oversized author error=%v, want social challenge", err)
	}
	pending, err := store.CompleteSocialVerification(ctx, policy, providerID, challenge.Cleartext, "123", "456", "x_api", now)
	if err != nil {
		t.Fatal(err)
	}
	if pending.SocialState != SocialStatePending || pending.BonusCapacity != 0 || pending.Remaining != 1 {
		t.Fatalf("pending status=%+v", pending)
	}

	var gotPost, gotAuthor string
	recheck := func(_ context.Context, postID, authorID string) error {
		gotPost, gotAuthor = postID, authorID
		return nil
	}
	if granted, err := store.PromoteMaturedSocialVerifications(ctx, policy, now.Add(time.Minute), recheck); err != nil || granted != 0 {
		t.Fatalf("premature promotion granted=%d err=%v", granted, err)
	}
	if granted, err := store.PromoteMaturedSocialVerifications(ctx, policy, now.Add(31*time.Minute), recheck); err != nil || granted != 1 {
		t.Fatalf("mature promotion granted=%d err=%v", granted, err)
	}
	if gotPost != "123" || gotAuthor != "456" {
		t.Fatalf("recheck post=%q author=%q", gotPost, gotAuthor)
	}
	matured, err := store.ProviderReferralStatus(ctx, policy, providerID)
	if err != nil || matured.SocialState != SocialStateMatured || matured.BonusCapacity != 2 || matured.Remaining != 3 {
		t.Fatalf("matured status=%+v err=%v", matured, err)
	}
	if granted, err := store.PromoteMaturedSocialVerifications(ctx, policy, now.Add(time.Hour), recheck); err != nil || granted != 0 {
		t.Fatalf("repeat promotion granted=%d err=%v", granted, err)
	}
}

func TestSocialPromotionDistinguishesTransientAndTerminalRechecks(t *testing.T) {
	store := openSocialStore(t)
	policy := socialReferralPolicy()
	ctx := context.Background()
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	providerID := "provider-recheck"
	createPendingSocialVerification(t, store, policy, providerID, now)

	transient := func(context.Context, string, string) error { return ErrSocialRecheckTransient }
	if granted, err := store.PromoteMaturedSocialVerifications(ctx, policy, now.Add(31*time.Minute), transient); err != nil || granted != 0 {
		t.Fatalf("transient promotion granted=%d err=%v", granted, err)
	}
	status, err := store.ProviderReferralStatus(ctx, policy, providerID)
	if err != nil || status.SocialState != SocialStatePending {
		t.Fatalf("transient status=%+v err=%v", status, err)
	}

	terminal := func(context.Context, string, string) error { return errors.New("post unavailable") }
	if granted, err := store.PromoteMaturedSocialVerifications(ctx, policy, now.Add(32*time.Minute), terminal); err != nil || granted != 0 {
		t.Fatalf("terminal promotion granted=%d err=%v", granted, err)
	}
	status, err = store.ProviderReferralStatus(ctx, policy, providerID)
	if err != nil || status.SocialState != SocialStateFailed || status.BonusCapacity != 0 {
		t.Fatalf("terminal status=%+v err=%v", status, err)
	}
}

func TestReplacementRebindsPendingReviewAndBlocksStalePromotion(t *testing.T) {
	store := openSocialStore(t)
	policy := socialReferralPolicy()
	ctx := context.Background()
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	providerID := "provider-replacement"
	pending, _ := createPendingSocialVerification(t, store, policy, providerID, now)
	oldIssuerID := pending.IssuerID

	replacedDuringRecheck := false
	recheck := func(context.Context, string, string) error {
		if replacedDuringRecheck {
			return nil
		}
		replacedDuringRecheck = true
		if _, err := store.RevokeReferralIssuerAudited(ctx, policy.Campaign, oldIssuerID, true, "ops", "rotate", &ReferralRevokeExpectation{Redeemed: 0}, now.Add(31*time.Minute)); err != nil {
			return err
		}
		preview, err := store.ReplaceReferralIssuer(ctx, policy, oldIssuerID, "", "", false, now.Add(31*time.Minute))
		if err != nil || !preview.PendingSocialReview || preview.Applied {
			return fmt.Errorf("replacement preview=%+v err=%v", preview, err)
		}
		_, err = store.ReplaceReferralIssuer(ctx, policy, oldIssuerID, "ops", "rotate compromised link", true, now.Add(31*time.Minute))
		return err
	}
	if granted, err := store.PromoteMaturedSocialVerifications(ctx, policy, now.Add(31*time.Minute), recheck); err != nil || granted != 0 {
		t.Fatalf("stale promotion granted=%d err=%v", granted, err)
	}
	status, err := store.ProviderReferralStatus(ctx, policy, providerID)
	if err != nil || status.IssuerID == oldIssuerID || status.SocialState != SocialStatePending || status.BonusCapacity != 0 {
		t.Fatalf("rebound status=%+v err=%v", status, err)
	}
	newIssuerID := status.IssuerID
	if granted, err := store.PromoteMaturedSocialVerifications(ctx, policy, now.Add(32*time.Minute), func(context.Context, string, string) error { return nil }); err != nil || granted != 1 {
		t.Fatalf("successor promotion granted=%d err=%v", granted, err)
	}
	status, err = store.ProviderReferralStatus(ctx, policy, providerID)
	if err != nil || status.IssuerID != newIssuerID || status.SocialState != SocialStateMatured || status.BonusCapacity != 2 {
		t.Fatalf("successor status=%+v err=%v", status, err)
	}
	var oldBonus, auditRows int
	if err := store.db.QueryRow(`SELECT bonus_capacity FROM referral_issuers WHERE issuer_id = ?`, oldIssuerID).Scan(&oldBonus); err != nil {
		t.Fatal(err)
	}
	if err := store.db.QueryRow(`SELECT COUNT(1) FROM referral_admin_audit WHERE action = 'replace_issuer' AND target = ?`, policy.Campaign+"/"+oldIssuerID).Scan(&auditRows); err != nil {
		t.Fatal(err)
	}
	if oldBonus != 0 || auditRows != 1 {
		t.Fatalf("old bonus=%d audit rows=%d", oldBonus, auditRows)
	}
}
