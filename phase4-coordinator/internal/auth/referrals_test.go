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
	if _, err := store.CompleteSocialVerification(context.Background(), policy, "provider-b", challenge.Cleartext, "100", "x_api", now); !errors.Is(err, auth.ErrSocialChallenge) {
		t.Fatalf("cross-provider err=%v", err)
	}
	status, err := store.CompleteSocialVerification(context.Background(), policy, "provider-a", challenge.Cleartext, "100", "x_api", now)
	if err != nil {
		t.Fatal(err)
	}
	if !status.SocialVerified || status.BonusUses != policy.SocialBonusUses {
		t.Fatalf("status=%+v", status)
	}
	if _, err := store.CompleteSocialVerification(context.Background(), policy, "provider-a", challenge.Cleartext, "101", "x_api", now); !errors.Is(err, auth.ErrSocialChallenge) {
		t.Fatalf("replay err=%v", err)
	}
	after, err := store.ProviderReferralStatus(context.Background(), policy, "provider-a")
	if err != nil || after.BonusUses != policy.SocialBonusUses {
		t.Fatalf("after=%+v err=%v", after, err)
	}
	providerBChallenge, err := store.CreateSocialChallenge(context.Background(), policy, "provider-b", now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.CompleteSocialVerification(context.Background(), policy, "provider-b", providerBChallenge.Cleartext, "100", "x_api", now); !errors.Is(err, auth.ErrSocialChallenge) {
		t.Fatalf("duplicate post err=%v", err)
	}
}
