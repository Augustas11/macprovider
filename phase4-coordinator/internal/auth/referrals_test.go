package auth_test

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

func referralPolicy() auth.ReferralPolicy {
	return auth.ReferralPolicy{
		RequireForRegistration: true,
		Campaign:               "prebeta_test",
		PolicyVersion:          "v1",
		CurrentKeyID:           "k1",
		HMACKeys:               map[string]string{"k1": "0123456789abcdef0123456789abcdef"},
		ProviderBaseUses:       1,
		SocialBonusUses:        2,
		ChallengeTTL:           15 * time.Minute,
	}
}

func TestReferralCodeAuthenticatesWithoutExposingProviderID(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := referralPolicy()
	code, err := store.CreateSeedReferral(context.Background(), policy, "seed01", 3, nil)
	if err != nil {
		t.Fatal(err)
	}
	if code == "" || code == "seed01" {
		t.Fatalf("unexpected code %q", code)
	}
	validation, err := store.ValidateReferral(context.Background(), policy, code, time.Now().UTC())
	if err != nil || !validation.Valid || validation.RemainingUses != 3 {
		t.Fatalf("validation=%+v err=%v", validation, err)
	}
	forged := code[:len(code)-1] + "A"
	if _, err := store.ValidateReferral(context.Background(), policy, forged, time.Now().UTC()); !errors.Is(err, auth.ErrReferralInvalid) {
		t.Fatalf("forged err=%v, want ErrReferralInvalid", err)
	}
}

func TestReferralCapAndTokenMintAreAtomicUnderConcurrency(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := referralPolicy()
	code, err := store.CreateSeedReferral(context.Background(), policy, "onlyone", 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	var successes atomic.Int32
	var wg sync.WaitGroup
	errs := make(chan error, 16)
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, _, err := store.IssueTokenWithReferral(context.Background(), fmt.Sprintf("ref-%02d", i), "concurrent", code, policy)
			if err == nil {
				successes.Add(1)
				return
			}
			errs <- err
		}(i)
	}
	wg.Wait()
	close(errs)
	if got := successes.Load(); got != 1 {
		t.Fatalf("successful mints=%d, want 1", got)
	}
	for err := range errs {
		if !errors.Is(err, auth.ErrReferralExhausted) {
			t.Fatalf("loser err=%v, want ErrReferralExhausted", err)
		}
	}
	if _, err := store.ValidateReferral(context.Background(), policy, code, time.Now().UTC()); !errors.Is(err, auth.ErrReferralExhausted) {
		t.Fatalf("post-cap err=%v, want ErrReferralExhausted", err)
	}
}

func TestReferralReservationOwnsCapacityBeforeAppTrackIdentityPrepare(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := referralPolicy()
	code, err := store.CreateSeedReferral(context.Background(), policy, "reserve_cap", 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	reservation, err := store.ReserveReferralCapacity(context.Background(), policy, code, "app-winner", now, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if duplicate, err := store.ReserveReferralCapacity(context.Background(), policy, code, "app-winner", now, time.Minute); err != nil || duplicate != reservation {
		t.Fatalf("exact reservation retry = %q err=%v, want %q", duplicate, err, reservation)
	}
	if duplicate, err := store.ReserveReferralCapacity(context.Background(), policy, code, "app-winner", now.Add(59*time.Second), time.Minute); err != nil || duplicate != reservation {
		t.Fatalf("near-expiry retry = %q err=%v, want refreshed %q", duplicate, err, reservation)
	}
	if _, err := store.ReserveReferralCapacity(context.Background(), policy, code, "app-loser", now.Add(61*time.Second), time.Minute); !errors.Is(err, auth.ErrReferralExhausted) {
		t.Fatalf("capacity loser err=%v, want ErrReferralExhausted", err)
	}
	token, err := store.MintProviderTokenAppTrackWithReferralReservation(context.Background(), "app-winner", nil, code, policy, reservation, appTrackAttempt(now))
	if err != nil || token == "" {
		t.Fatalf("reservation finalize token=%q err=%v", token, err)
	}
	if _, err := store.ReserveReferralCapacity(context.Background(), policy, code, "app-loser", now, time.Minute); !errors.Is(err, auth.ErrReferralExhausted) {
		t.Fatalf("post-redemption loser err=%v, want ErrReferralExhausted", err)
	}
}

func TestExpiredReferralReservationReleasesCapacity(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := referralPolicy()
	code, err := store.CreateSeedReferral(context.Background(), policy, "reserve_expiry", 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	if _, err := store.ReserveReferralCapacity(context.Background(), policy, code, "abandoned-app", now, time.Minute); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ReserveReferralCapacity(context.Background(), policy, code, "recovered-app", now.Add(2*time.Minute), time.Minute); err != nil {
		t.Fatalf("reserve after expiry: %v", err)
	}
}

func TestAppTrackPrepareFailureRollbackRestoresReferralCapacity(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := referralPolicy()
	code, err := store.CreateSeedReferral(context.Background(), policy, "prepare_rollback", 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	reservation, err := store.ReserveReferralCapacity(context.Background(), policy, code, "rollback-app", now, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	token, err := store.MintProviderTokenAppTrackWithReferralReservation(context.Background(), "rollback-app", nil, code, policy, reservation, appTrackAttempt(now))
	if err != nil {
		t.Fatal(err)
	}
	if err := store.RollbackAppTrackReferralMint(context.Background(), "rollback-app", token); err != nil {
		t.Fatal(err)
	}
	if active, err := store.HasActiveTokenForProvider(context.Background(), "rollback-app"); err != nil || active {
		t.Fatalf("active after rollback=%v err=%v", active, err)
	}
	validation, err := store.ValidateReferral(context.Background(), policy, code, time.Now().UTC())
	if err != nil || validation.RemainingUses != 1 {
		t.Fatalf("validation after rollback=%+v err=%v", validation, err)
	}
}

func TestAppTrackRollbackPreservesHistoricalReferralRedemption(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := referralPolicy()
	code, err := store.CreateSeedReferral(context.Background(), policy, "historical_rollback", 2, nil)
	if err != nil {
		t.Fatal(err)
	}
	record, _, err := store.IssueTokenWithReferral(context.Background(), "historical-app", "malibu-app", code, policy)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.RevokeToken(context.Background(), record.TokenPrefix); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	reservation, err := store.ReserveReferralCapacity(context.Background(), policy, code, "historical-app", now, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	token, err := store.MintProviderTokenAppTrackWithReferralReservation(
		context.Background(), "historical-app", nil, code, policy, reservation, appTrackAttempt(now),
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.RollbackAppTrackReferralMint(context.Background(), "historical-app", token); err != nil {
		t.Fatal(err)
	}
	validation, err := store.ValidateReferral(context.Background(), policy, code, time.Now().UTC())
	if err != nil || validation.RemainingUses != 1 {
		t.Fatalf("historical redemption changed by rollback: validation=%+v err=%v", validation, err)
	}
}

func TestAppTrackHistoricalBindingCanReserveAtExhaustedCapacity(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := referralPolicy()
	code, err := store.CreateSeedReferral(context.Background(), policy, "historical_exhausted", 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	record, _, err := store.IssueTokenWithReferral(context.Background(), "historical-cap-one", "malibu-app", code, policy)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.RevokeToken(context.Background(), record.TokenPrefix); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	reservation, err := store.ReserveReferralCapacity(context.Background(), policy, code, "historical-cap-one", now, time.Minute)
	if err != nil {
		t.Fatalf("same binding should not need another capacity unit: %v", err)
	}
	token, err := store.MintProviderTokenAppTrackWithReferralReservation(
		context.Background(), "historical-cap-one", nil, code, policy, reservation, appTrackAttempt(now),
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.AcknowledgeAppTrackReferralMint(context.Background(), "historical-cap-one", token); err != nil {
		t.Fatal(err)
	}
}

func TestPendingAppTrackMintRecoveryKeepsCommittedCredential(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := referralPolicy()
	code, err := store.CreateSeedReferral(context.Background(), policy, "pending_keep", 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	reservation, err := store.ReserveReferralCapacity(context.Background(), policy, code, "committed-app", now, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.MintProviderTokenAppTrackWithReferralReservation(
		context.Background(), "committed-app", nil, code, policy, reservation, appTrackAttempt(now),
	); err != nil {
		t.Fatal(err)
	}
	pending, err := store.ListPendingAppTrackReferralMints(context.Background(), now.Add(time.Hour))
	if err != nil || len(pending) != 1 {
		t.Fatalf("pending=%+v err=%v", pending, err)
	}
	if err := store.ResolvePendingAppTrackReferralMint(context.Background(), pending[0], true); err != nil {
		t.Fatal(err)
	}
	if active, err := store.HasActiveTokenForProvider(context.Background(), "committed-app"); err != nil || !active {
		t.Fatalf("committed token active=%v err=%v", active, err)
	}
	pending, err = store.ListPendingAppTrackReferralMints(context.Background(), now.Add(time.Hour))
	if err != nil || len(pending) != 0 {
		t.Fatalf("resolved pending=%+v err=%v", pending, err)
	}
}

func appTrackAttempt(now time.Time) auth.AppTrackRegistrationAttempt {
	return auth.AppTrackRegistrationAttempt{
		SourceIP:   "198.51.100.10",
		Nonce:      "test-register-nonce",
		ObservedAt: now,
	}
}

func TestReferralFailureMintsNoCredentialAndRetryDoesNotConsumeTwice(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := referralPolicy()
	if _, _, err := store.IssueTokenWithReferral(context.Background(), "missing-ref", "missing", "", policy); !errors.Is(err, auth.ErrReferralRequired) {
		t.Fatalf("missing err=%v", err)
	}
	if active, err := store.HasActiveTokenForProvider(context.Background(), "missing-ref"); err != nil || active {
		t.Fatalf("missing-ref active=%v err=%v", active, err)
	}

	code, err := store.CreateSeedReferral(context.Background(), policy, "retry", 2, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.IssueTokenWithReferral(context.Background(), "retry-provider", "retry", code, policy); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.IssueTokenWithReferral(context.Background(), "retry-provider", "retry", code, policy); !errors.Is(err, auth.ErrActiveTokenAlreadyExists) {
		t.Fatalf("retry err=%v, want active-token conflict", err)
	}
	validation, err := store.ValidateReferral(context.Background(), policy, code, time.Now().UTC())
	if err != nil || validation.RemainingUses != 1 {
		t.Fatalf("retry validation=%+v err=%v, want one remaining", validation, err)
	}
}

func TestBogusBearerCannotBypassAppTrackReferralGate(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	bogus := "junk"
	if _, err := store.MintProviderTokenAppTrackWithReferral(context.Background(), "new-provider", &bogus, "", referralPolicy()); !errors.Is(err, auth.ErrReferralRequired) {
		t.Fatalf("err=%v, want referral required", err)
	}
	if active, err := store.HasActiveTokenForProvider(context.Background(), "new-provider"); err != nil || active {
		t.Fatalf("active=%v err=%v", active, err)
	}
}

func TestFlagOffIgnoresPersistedInvalidReferral(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := referralPolicy()
	policy.RequireForRegistration = false
	if _, _, err := store.IssueTokenWithReferral(context.Background(), "open-provider", "open", "not-a-code", policy); err != nil {
		t.Fatalf("flag-off mint rejected stale code: %v", err)
	}
}

func TestGrandfatherCutoffAllowsHistoricalProviderRecovery(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	record, _, err := store.IssueToken(context.Background(), "historical-provider", "historical")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.RevokeToken(context.Background(), record.TokenPrefix); err != nil {
		t.Fatal(err)
	}
	cutoff := time.Now().UTC().Add(time.Hour)
	policy := referralPolicy()
	policy.GrandfatherBefore = &cutoff
	if _, _, err := store.IssueTokenWithReferral(context.Background(), "historical-provider", "historical", "", policy); !errors.Is(err, auth.ErrReferralRequired) {
		t.Fatalf("unproven provider-id grandfather err=%v, want required", err)
	}
	policy.GrandfatherProof = true
	recovered, _, err := store.IssueTokenWithReferral(context.Background(), "historical-provider", "historical", "", policy)
	if err != nil {
		t.Fatalf("grandfathered recovery failed: %v", err)
	}
	if _, err := store.RevokeToken(context.Background(), recovered.TokenPrefix); err != nil {
		t.Fatal(err)
	}
	policy.GrandfatherBefore = nil
	if _, _, err := store.IssueTokenWithReferral(context.Background(), "historical-provider", "historical", "", policy); err != nil {
		t.Fatalf("persisted grandfather decision not honored: %v", err)
	}
}

func TestExistingBindingRejectsForgedDigest(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := referralPolicy()
	code, err := store.CreateSeedReferral(context.Background(), policy, "digestseed", 2, nil)
	if err != nil {
		t.Fatal(err)
	}
	record, _, err := store.IssueTokenWithReferral(context.Background(), "digest-provider", "digest", code, policy)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.RevokeToken(context.Background(), record.TokenPrefix); err != nil {
		t.Fatal(err)
	}
	replacement := "A"
	if code[len(code)-1] == 'A' {
		replacement = "B"
	}
	forged := code[:len(code)-1] + replacement
	if _, _, err := store.IssueTokenWithReferral(context.Background(), "digest-provider", "digest", forged, policy); !errors.Is(err, auth.ErrReferralInvalid) {
		t.Fatalf("forged retry err=%v, want invalid", err)
	}
}

func TestAppTrackBearerReissueDoesNotRequireOrRebindReferral(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := referralPolicy()
	code, err := store.CreateSeedReferral(context.Background(), policy, "appseed", 2, nil)
	if err != nil {
		t.Fatal(err)
	}
	first, err := store.MintProviderTokenAppTrackWithReferral(context.Background(), "app-provider", nil, code, policy)
	if err != nil {
		t.Fatal(err)
	}
	second, err := store.MintProviderTokenAppTrackWithReferral(context.Background(), "app-provider", &first, "", policy)
	if err != nil {
		t.Fatal(err)
	}
	if first == second {
		t.Fatal("reissue returned the same token")
	}
	validation, err := store.ValidateReferral(context.Background(), policy, code, time.Now().UTC())
	if err != nil || validation.RemainingUses != 1 {
		t.Fatalf("reissue validation=%+v err=%v", validation, err)
	}
}

func TestSocialChallengeIsProviderBoundSingleUseAndAwardsBonusOnce(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := referralPolicy()
	policy.EnableSocialBonus = true
	now := time.Date(2026, 7, 12, 10, 0, 0, 0, time.UTC)
	if _, err := store.EnsureProviderReferral(context.Background(), policy, "provider-a", now.Add(-time.Minute)); err != nil {
		t.Fatal(err)
	}
	if _, err := store.EnsureProviderReferral(context.Background(), policy, "provider-b", now.Add(-time.Minute)); err != nil {
		t.Fatal(err)
	}
	challenge, err := store.CreateSocialChallenge(context.Background(), policy, "provider-a", now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.CompleteSocialVerification(context.Background(), policy, "provider-b", challenge.Cleartext, "100", "author-a", "x_api", now); !errors.Is(err, auth.ErrSocialChallenge) {
		t.Fatalf("cross-provider err=%v", err)
	}
	// FIX-570 H3: verification is recorded pending — no bonus is granted until the
	// dwell reconciler promotes it.
	status, err := store.CompleteSocialVerification(context.Background(), policy, "provider-a", challenge.Cleartext, "100", "author-a", "x_api", now)
	if err != nil {
		t.Fatal(err)
	}
	if status.SocialVerified || status.BonusUses != 0 {
		t.Fatalf("expected pending status=%+v", status)
	}
	if _, err := store.CompleteSocialVerification(context.Background(), policy, "provider-a", challenge.Cleartext, "101", "author-a", "x_api", now); !errors.Is(err, auth.ErrSocialChallenge) {
		t.Fatalf("replay err=%v", err)
	}
	recheck := func(_ context.Context, _, boundAuthor string) error {
		if boundAuthor != "author-a" {
			return errors.New("unexpected author")
		}
		return nil
	}
	if granted, err := store.PromoteMaturedSocialVerifications(context.Background(), policy, now.Add(31*time.Minute), recheck); err != nil || granted != 1 {
		t.Fatalf("promotion granted=%d err=%v", granted, err)
	}
	after, err := store.ProviderReferralStatus(context.Background(), policy, "provider-a")
	if err != nil || !after.SocialVerified || after.BonusUses != policy.SocialBonusUses {
		t.Fatalf("after=%+v err=%v", after, err)
	}
	// A second promotion pass must not double-grant.
	if granted, err := store.PromoteMaturedSocialVerifications(context.Background(), policy, now.Add(62*time.Minute), recheck); err != nil || granted != 0 {
		t.Fatalf("double grant=%d err=%v", granted, err)
	}
	providerBChallenge, err := store.CreateSocialChallenge(context.Background(), policy, "provider-b", now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.CompleteSocialVerification(context.Background(), policy, "provider-b", providerBChallenge.Cleartext, "100", "author-b", "x_api", now); !errors.Is(err, auth.ErrSocialChallenge) {
		t.Fatalf("duplicate post err=%v", err)
	}
}

// TestTransientSocialRecheckLeavesPendingThenGrantsOnce is the FIX-570 M3
// regression: a transient re-check failure (timeout / 429 / 5xx) must NOT set
// failed_at; the verification stays pending and a subsequent successful pass
// grants the bonus exactly once. The status endpoint reports pending_social_review
// with a review_due_at throughout, then verified after the grant.
func TestTransientSocialRecheckLeavesPendingThenGrantsOnce(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := referralPolicy()
	policy.EnableSocialBonus = true
	now := time.Date(2026, 7, 12, 10, 0, 0, 0, time.UTC)
	if _, err := store.EnsureProviderReferral(context.Background(), policy, "provider-a", now.Add(-time.Minute)); err != nil {
		t.Fatal(err)
	}
	challenge, err := store.CreateSocialChallenge(context.Background(), policy, "provider-a", now)
	if err != nil {
		t.Fatal(err)
	}
	pending, err := store.CompleteSocialVerification(context.Background(), policy, "provider-a", challenge.Cleartext, "100", "author-a", "x_api", now)
	if err != nil {
		t.Fatal(err)
	}
	if pending.AdvocacyStatus != "pending_social_review" || pending.ReviewDueAt == nil {
		t.Fatalf("expected pending with review_due_at, got %+v", pending)
	}
	if want := now.Add(auth.SocialVerificationDwell); !pending.ReviewDueAt.Equal(want) {
		t.Fatalf("review_due_at=%v want=%v", pending.ReviewDueAt, want)
	}

	// A transient recheck failure must leave the row pending (no failed_at) and
	// grant nothing.
	transient := func(_ context.Context, _, _ string) error {
		return fmt.Errorf("x lookup 503: %w", auth.ErrSocialRecheckTransient)
	}
	if granted, err := store.PromoteMaturedSocialVerifications(context.Background(), policy, now.Add(31*time.Minute), transient); err != nil || granted != 0 {
		t.Fatalf("transient granted=%d err=%v", granted, err)
	}
	mid, err := store.ProviderReferralStatus(context.Background(), policy, "provider-a")
	if err != nil {
		t.Fatal(err)
	}
	if mid.AdvocacyStatus != "pending_social_review" || mid.SocialVerified {
		t.Fatalf("transient failure must stay pending, got %+v", mid)
	}

	// A subsequent successful pass grants exactly once.
	ok := func(_ context.Context, _, _ string) error { return nil }
	if granted, err := store.PromoteMaturedSocialVerifications(context.Background(), policy, now.Add(40*time.Minute), ok); err != nil || granted != 1 {
		t.Fatalf("success granted=%d err=%v", granted, err)
	}
	after, err := store.ProviderReferralStatus(context.Background(), policy, "provider-a")
	if err != nil {
		t.Fatal(err)
	}
	if !after.SocialVerified || after.AdvocacyStatus != "verified" || after.ReviewDueAt != nil {
		t.Fatalf("expected verified, got %+v", after)
	}
	if after.BonusUses != policy.SocialBonusUses {
		t.Fatalf("bonus=%d want=%d", after.BonusUses, policy.SocialBonusUses)
	}
}

// TestTerminalSocialRecheckFailsAndSurfacesFailedStatus is the FIX-570 M3
// terminal path plus the cross-lane social_review_failed status: a confirmed
// terminal recheck (post deleted / author mismatch) sets failed_at, grants no
// bonus, and the status endpoint reports social_review_failed.
func TestTerminalSocialRecheckFailsAndSurfacesFailedStatus(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := referralPolicy()
	policy.EnableSocialBonus = true
	now := time.Date(2026, 7, 12, 10, 0, 0, 0, time.UTC)
	if _, err := store.EnsureProviderReferral(context.Background(), policy, "provider-a", now.Add(-time.Minute)); err != nil {
		t.Fatal(err)
	}
	challenge, err := store.CreateSocialChallenge(context.Background(), policy, "provider-a", now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.CompleteSocialVerification(context.Background(), policy, "provider-a", challenge.Cleartext, "100", "author-a", "x_api", now); err != nil {
		t.Fatal(err)
	}
	terminal := func(_ context.Context, _, _ string) error {
		return errors.New("post author changed")
	}
	if granted, err := store.PromoteMaturedSocialVerifications(context.Background(), policy, now.Add(31*time.Minute), terminal); err != nil || granted != 0 {
		t.Fatalf("terminal granted=%d err=%v", granted, err)
	}
	after, err := store.ProviderReferralStatus(context.Background(), policy, "provider-a")
	if err != nil {
		t.Fatal(err)
	}
	if after.AdvocacyStatus != "social_review_failed" || after.SocialVerified || after.ReviewDueAt != nil {
		t.Fatalf("expected social_review_failed, got %+v", after)
	}
	// A later successful tick must NOT resurrect a terminally-failed verification.
	ok := func(_ context.Context, _, _ string) error { return nil }
	if granted, err := store.PromoteMaturedSocialVerifications(context.Background(), policy, now.Add(90*time.Minute), ok); err != nil || granted != 0 {
		t.Fatalf("failed row must not be granted later granted=%d err=%v", granted, err)
	}
}

// TestReservationCannotBeExtendedPastAbsoluteLifetime is the FIX-570 H3
// regression: refreshing a preflight reservation must never push expires_at past
// its original created_at + maxReservationLifetime, so a single unauthenticated
// request cannot pin a cap-one invite forever. After the absolute lifetime the
// slot frees for another provider.
func TestReservationCannotBeExtendedPastAbsoluteLifetime(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := referralPolicy()
	code, err := store.CreateSeedReferral(context.Background(), policy, "reslife", 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	t0 := time.Date(2026, 7, 12, 10, 0, 0, 0, time.UTC)
	// ttl is long enough that each refresh lands before natural expiry, so the only
	// thing that can free the slot is the absolute-lifetime cap.
	ttl := 20 * time.Minute

	res1, err := store.ReserveReferralCapacity(context.Background(), policy, code, "provider-a", t0, ttl)
	if err != nil {
		t.Fatal(err)
	}
	// Refreshes within the absolute lifetime keep the SAME reservation but clamp
	// expires_at to created_at+30m (would otherwise be t0+35, then t0+48).
	res1b, err := store.ReserveReferralCapacity(context.Background(), policy, code, "provider-a", t0.Add(15*time.Minute), ttl)
	if err != nil {
		t.Fatal(err)
	}
	if res1b != res1 {
		t.Fatalf("refresh within lifetime changed reservation id %q -> %q", res1, res1b)
	}
	if _, err := store.ReserveReferralCapacity(context.Background(), policy, code, "provider-a", t0.Add(28*time.Minute), ttl); err != nil {
		t.Fatal(err)
	}
	// Absent the absolute cap, the t0+28 refresh would set expires_at=t0+48 and keep
	// the cap-one slot pinned at t0+31. With the cap, expires_at is clamped to
	// t0+30, so the slot has freed and another provider can reserve at t0+31.
	res2, err := store.ReserveReferralCapacity(context.Background(), policy, code, "provider-b", t0.Add(31*time.Minute), ttl)
	if err != nil {
		t.Fatalf("slot did not free after absolute lifetime: %v", err)
	}
	if res2 == "" || res2 == res1 {
		t.Fatalf("expected a distinct fresh reservation for provider-b, got %q", res2)
	}
	// provider-a re-reserving now would collide with provider-b's live claim on the
	// cap-one invite, proving the slot is genuinely held by b (not still pinned by a).
	if _, err := store.ReserveReferralCapacity(context.Background(), policy, code, "provider-a", t0.Add(32*time.Minute), ttl); !errors.Is(err, auth.ErrReferralExhausted) {
		t.Fatalf("provider-a re-reserve after slot taken err=%v want exhausted", err)
	}
}

// TestCustodyProvenRecoveryIgnoresIssuerRevocation is the FIX-570 A3 regression:
// once a provider is bound to a redemption, presenting the same code must succeed
// even after the issuer is revoked. Pre-fix redeemReferralTx re-validated the
// issuer lifecycle and returned ErrReferralRevoked, stranding the provider.
func TestCustodyProvenRecoveryIgnoresIssuerRevocation(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := referralPolicy()
	code, err := store.CreateSeedReferral(context.Background(), policy, "revoke_recover", 2, nil)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	record, _, err := store.IssueTokenWithReferral(context.Background(), "bound-provider", "bound", code, policy)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.RevokeToken(context.Background(), record.TokenPrefix); err != nil {
		t.Fatal(err)
	}
	if err := store.RevokeReferralIssuer(context.Background(), policy.Campaign, "revoke_recover", now); err != nil {
		t.Fatal(err)
	}
	// A fresh, unbound provider is correctly rejected once the issuer is revoked.
	if _, _, err := store.IssueTokenWithReferral(context.Background(), "fresh-provider", "fresh", code, policy); !errors.Is(err, auth.ErrReferralRevoked) {
		t.Fatalf("fresh redeem after revoke err=%v, want ErrReferralRevoked", err)
	}
	// The already-bound provider recovers regardless of the later revocation.
	if _, _, err := store.IssueTokenWithReferral(context.Background(), "bound-provider", "bound", code, policy); err != nil {
		t.Fatalf("custody-proven recovery after issuer revoke failed: %v", err)
	}
}

// TestCommittedUndeliveredAppTrackMintIsRecoverable is the FIX-570 A2 regression:
// a gated mint that committed (referral redeemed, unused token minted) but whose
// cleartext response was lost must remain recoverable without re-consuming
// capacity. Pre-fix the only retry path (MintProviderTokenAppTrackWithReferralReservation
// with no bearer) dead-ended with ErrAppTrackExistingTokenNoProof.
func TestCommittedUndeliveredAppTrackMintIsRecoverable(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := referralPolicy()
	code, err := store.CreateSeedReferral(context.Background(), policy, "recover_undelivered", 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	reservation, err := store.ReserveReferralCapacity(context.Background(), policy, code, "lost-app", now, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	firstToken, err := store.MintProviderTokenAppTrackWithReferralReservation(
		context.Background(), "lost-app", nil, code, policy, reservation, appTrackAttempt(now),
	)
	if err != nil || firstToken == "" {
		t.Fatalf("first mint token=%q err=%v", firstToken, err)
	}
	// Response lost; reconciliation with prepared=true keeps the credential.
	pending, err := store.ListPendingAppTrackReferralMints(context.Background(), now.Add(time.Hour))
	if err != nil || len(pending) != 1 {
		t.Fatalf("pending=%+v err=%v", pending, err)
	}
	if err := store.ResolvePendingAppTrackReferralMint(context.Background(), pending[0], true); err != nil {
		t.Fatal(err)
	}

	// The pre-fix dead-end: a bearer-less retry through the normal mint path is
	// rejected because an active (undeliverable) token exists.
	retryReservation, err := store.ReserveReferralCapacity(context.Background(), policy, code, "lost-app", now.Add(time.Minute), time.Minute)
	if err != nil {
		t.Fatalf("idempotent re-reserve err=%v", err)
	}
	if _, err := store.MintProviderTokenAppTrackWithReferralReservation(
		context.Background(), "lost-app", nil, code, policy, retryReservation, appTrackAttempt(now.Add(time.Minute)),
	); !errors.Is(err, auth.ErrAppTrackExistingTokenNoProof) {
		t.Fatalf("bearer-less retry err=%v, want the pre-recovery dead-end", err)
	}

	// A2 recovery resolves the dead-end by rotating the unused token.
	recovered, ok, err := store.RecoverAppTrackReferralMint(
		context.Background(), "lost-app", nil, code, policy, appTrackAttempt(now.Add(2*time.Minute)),
	)
	if err != nil || !ok || recovered == "" {
		t.Fatalf("recover token=%q ok=%v err=%v", recovered, ok, err)
	}
	if recovered == firstToken {
		t.Fatalf("recovery must rotate to a fresh token, got the old one")
	}
	providerID, valid, err := store.ValidateToken(context.Background(), recovered)
	if err != nil || !valid || providerID != "lost-app" {
		t.Fatalf("recovered token provider=%q valid=%v err=%v", providerID, valid, err)
	}
	if _, valid, err := store.ValidateToken(context.Background(), firstToken); err != nil || valid {
		t.Fatalf("old undelivered token must be revoked (valid=%v err=%v)", valid, err)
	}
	// Capacity (1) was not re-consumed: still exhausted, one redemption only.
	if _, err := store.ReserveReferralCapacity(context.Background(), policy, code, "other-app", now.Add(3*time.Minute), time.Minute); !errors.Is(err, auth.ErrReferralExhausted) {
		t.Fatalf("post-recovery capacity err=%v, want ErrReferralExhausted", err)
	}
}

// TestUsedAppTrackTokenIsNotRecoverable guards A2: once the active token has been
// used, recovery must not rotate it (the caller must prove custody instead).
func TestUsedAppTrackTokenIsNotRecoverable(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := referralPolicy()
	code, err := store.CreateSeedReferral(context.Background(), policy, "used_norecover", 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	reservation, err := store.ReserveReferralCapacity(context.Background(), policy, code, "used-app", now, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	token, err := store.MintProviderTokenAppTrackWithReferralReservation(
		context.Background(), "used-app", nil, code, policy, reservation, appTrackAttempt(now),
	)
	if err != nil {
		t.Fatal(err)
	}
	if _, valid, err := store.ValidateAndMarkTokenUsed(context.Background(), token); err != nil || !valid {
		t.Fatalf("mark used valid=%v err=%v", valid, err)
	}
	recovered, ok, err := store.RecoverAppTrackReferralMint(
		context.Background(), "used-app", nil, code, policy, appTrackAttempt(now.Add(time.Minute)),
	)
	if err != nil || ok || recovered != "" {
		t.Fatalf("used token recovery ok=%v token=%q err=%v, want no recovery", ok, recovered, err)
	}
}

// TestRecoveryNeverClobbersConcurrentDifferentAttempt guards FIX-570 C1a bug 3
// (ADV-H4 residual): recovery for one signed attempt must NEVER revoke the token
// or clobber the durable saga of a DIFFERENT concurrent signed attempt. Here a
// gated mint commits and leaves an unacknowledged saga bound to attempt-1; a
// recovery invoked with a DIFFERENT attempt (different nonce) must refuse with a
// conflict and leave attempt-1's token active and its saga intact.
func TestRecoveryNeverClobbersConcurrentDifferentAttempt(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := referralPolicy()
	code, err := store.CreateSeedReferral(context.Background(), policy, "concurrent_guard", 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	reservation, err := store.ReserveReferralCapacity(context.Background(), policy, code, "concurrent-app", now, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	// attempt-1 commits: mints an unused token and leaves a durable saga bound to
	// its own (nonce, observed_at). The saga is intentionally NOT acknowledged, to
	// model a concurrent in-flight attempt whose recovery marker still exists.
	attempt1 := appTrackAttempt(now)
	firstToken, err := store.MintProviderTokenAppTrackWithReferralReservation(
		context.Background(), "concurrent-app", nil, code, policy, reservation, attempt1,
	)
	if err != nil || firstToken == "" {
		t.Fatalf("attempt-1 mint token=%q err=%v", firstToken, err)
	}
	if pending, err := store.ListPendingAppTrackReferralMints(context.Background(), now.Add(time.Hour)); err != nil || len(pending) != 1 {
		t.Fatalf("attempt-1 saga pending=%+v err=%v want exactly one", pending, err)
	}

	// A recovery for a DIFFERENT signed attempt (different nonce) must refuse to
	// touch attempt-1's saga/token.
	attempt2 := auth.AppTrackRegistrationAttempt{
		SourceIP:   "203.0.113.9",
		Nonce:      "a-different-register-nonce",
		ObservedAt: now.Add(time.Second),
	}
	recovered, ok, err := store.RecoverAppTrackReferralMint(
		context.Background(), "concurrent-app", nil, code, policy, attempt2,
	)
	if !errors.Is(err, auth.ErrReferralConflict) || ok || recovered != "" {
		t.Fatalf("cross-attempt recovery ok=%v token=%q err=%v, want ErrReferralConflict and no rotation", ok, recovered, err)
	}

	// attempt-1's token is still active (never revoked) and its saga is intact.
	if providerID, valid, err := store.ValidateToken(context.Background(), firstToken); err != nil || !valid || providerID != "concurrent-app" {
		t.Fatalf("attempt-1 token must remain active: provider=%q valid=%v err=%v", providerID, valid, err)
	}
	pending, err := store.ListPendingAppTrackReferralMints(context.Background(), now.Add(time.Hour))
	if err != nil || len(pending) != 1 || pending[0].Attempt.Nonce != attempt1.Nonce {
		t.Fatalf("attempt-1 saga must be intact: pending=%+v err=%v", pending, err)
	}
}
