package auth

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func coreReferralPolicy() ReferralPolicy {
	return ReferralPolicy{
		RequireForRegistration: true,
		Campaign:               "prebeta_test",
		PolicyVersion:          "v1",
		CurrentKeyID:           "k1",
		HMACKeys:               map[string]string{"k1": strings.Repeat("s", 32)},
		ProviderBaseUses:       1,
	}
}

func seedCoreReferral(t *testing.T, store *Store, policy ReferralPolicy, issuerID string) string {
	t.Helper()
	_, err := store.db.Exec(`
INSERT INTO referral_issuers (
    issuer_id, code_type, key_id, campaign, provider_id,
    base_capacity, bonus_capacity, created_at, first_serving_at
) VALUES (?, 'S', ?, ?, NULL, 1, 0, ?, ?)`,
		issuerID, policy.CurrentKeyID, policy.Campaign, nowString(), nowString(),
	)
	if err != nil {
		t.Fatal(err)
	}
	code, err := EncodeReferralCode(policy, ReferralTypeSeed, policy.CurrentKeyID, issuerID)
	if err != nil {
		t.Fatal(err)
	}
	return code
}

func TestReferralRedemptionAndTokenInsertAreAtomic(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := coreReferralPolicy()
	code := seedCoreReferral(t, store, policy, "seed1")

	if _, _, err := store.IssueTokenWithReferral(context.Background(), "provider-a", "host-a", code, policy); err != nil {
		t.Fatalf("first mint: %v", err)
	}
	if _, _, err := store.IssueTokenWithReferral(context.Background(), "provider-b", "host-b", code, policy); !errors.Is(err, ErrReferralExhausted) {
		t.Fatalf("second mint error=%v, want exhausted", err)
	}
	var tokens, redemptions int
	if err := store.db.QueryRow(`SELECT COUNT(1) FROM provider_tokens WHERE revoked_at IS NULL`).Scan(&tokens); err != nil {
		t.Fatal(err)
	}
	if err := store.db.QueryRow(`SELECT COUNT(1) FROM referral_redemptions`).Scan(&redemptions); err != nil {
		t.Fatal(err)
	}
	if tokens != 1 || redemptions != 1 {
		t.Fatalf("tokens=%d redemptions=%d, want 1/1", tokens, redemptions)
	}
}

func TestReferralValidationRejectsInvalidExpiredRevokedAndExhausted(t *testing.T) {
	now := time.Date(2026, 7, 13, 12, 0, 0, 0, time.UTC)

	t.Run("invalid", func(t *testing.T) {
		store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
		if err != nil {
			t.Fatal(err)
		}
		defer store.Close()
		policy := coreReferralPolicy()
		code := seedCoreReferral(t, store, policy, "seedinvalid")
		tagStart := strings.LastIndex(code, "-") + 1
		replacement := "A"
		if code[tagStart] == replacement[0] {
			replacement = "B"
		}
		code = code[:tagStart] + replacement + code[tagStart+1:]

		validation, err := store.ValidateReferral(context.Background(), policy, code, now)
		if !errors.Is(err, ErrReferralInvalid) || validation.Reason != "invalid" {
			t.Fatalf("validation=%+v err=%v, want invalid", validation, err)
		}
	})

	t.Run("expired", func(t *testing.T) {
		store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
		if err != nil {
			t.Fatal(err)
		}
		defer store.Close()
		policy := coreReferralPolicy()
		code := seedCoreReferral(t, store, policy, "seedexpired")
		if _, err := store.db.Exec(`UPDATE referral_issuers SET expires_at = ? WHERE issuer_id = ?`, timeText(now.Add(-time.Second)), "seedexpired"); err != nil {
			t.Fatal(err)
		}

		validation, err := store.ValidateReferral(context.Background(), policy, code, now)
		if !errors.Is(err, ErrReferralExpired) || validation.Reason != "expired" {
			t.Fatalf("validation=%+v err=%v, want expired", validation, err)
		}
	})

	t.Run("revoked", func(t *testing.T) {
		store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
		if err != nil {
			t.Fatal(err)
		}
		defer store.Close()
		policy := coreReferralPolicy()
		code := seedCoreReferral(t, store, policy, "seedrevoked")
		if _, err := store.db.Exec(`UPDATE referral_issuers SET revoked_at = ? WHERE issuer_id = ?`, timeText(now.Add(-time.Second)), "seedrevoked"); err != nil {
			t.Fatal(err)
		}

		validation, err := store.ValidateReferral(context.Background(), policy, code, now)
		if !errors.Is(err, ErrReferralRevoked) || validation.Reason != "revoked" {
			t.Fatalf("validation=%+v err=%v, want revoked", validation, err)
		}
	})

	t.Run("exhausted", func(t *testing.T) {
		store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
		if err != nil {
			t.Fatal(err)
		}
		defer store.Close()
		policy := coreReferralPolicy()
		code := seedCoreReferral(t, store, policy, "seedexhausted")
		if _, _, err := store.IssueTokenWithReferral(context.Background(), "provider-a", "host-a", code, policy); err != nil {
			t.Fatal(err)
		}

		validation, err := store.ValidateReferral(context.Background(), policy, code, now)
		if !errors.Is(err, ErrReferralExhausted) || validation.Reason != "exhausted" {
			t.Fatalf("validation=%+v err=%v, want exhausted", validation, err)
		}
	})
}

func TestReferralReplayForSameProviderDoesNotConsumeCapacityTwice(t *testing.T) {
	ctx := context.Background()
	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := coreReferralPolicy()
	code := seedCoreReferral(t, store, policy, "seedreplay")

	first, firstToken, err := store.IssueTokenWithReferral(ctx, "provider-a", "host-a", code, policy)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.RevokeToken(ctx, first.TokenPrefix); err != nil {
		t.Fatal(err)
	}
	_, secondToken, err := store.IssueTokenWithReferral(ctx, "provider-a", "host-a", code, policy)
	if err != nil {
		t.Fatalf("idempotent replay mint: %v", err)
	}
	if secondToken == firstToken {
		t.Fatal("replay returned the revoked credential")
	}

	var redemptions, activeTokens int
	if err := store.db.QueryRow(`SELECT COUNT(1) FROM referral_redemptions WHERE provider_id = ?`, "provider-a").Scan(&redemptions); err != nil {
		t.Fatal(err)
	}
	if err := store.db.QueryRow(`SELECT COUNT(1) FROM provider_tokens WHERE provider_id = ? AND revoked_at IS NULL`, "provider-a").Scan(&activeTokens); err != nil {
		t.Fatal(err)
	}
	if redemptions != 1 || activeTokens != 1 {
		t.Fatalf("redemptions=%d active_tokens=%d, want 1/1", redemptions, activeTokens)
	}
}

func TestConcurrentReferralRedemptionHasOneTokenAndRedemptionWinner(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := coreReferralPolicy()
	code := seedCoreReferral(t, store, policy, "seedconcurrent")

	type result struct {
		providerID string
		err        error
	}
	start := make(chan struct{})
	results := make(chan result, 2)
	var wg sync.WaitGroup
	for _, providerID := range []string{"provider-a", "provider-b"} {
		providerID := providerID
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			_, _, err := store.IssueTokenWithReferral(context.Background(), providerID, "host-"+providerID, code, policy)
			results <- result{providerID: providerID, err: err}
		}()
	}
	close(start)
	wg.Wait()
	close(results)

	winner := ""
	for result := range results {
		switch {
		case result.err == nil:
			if winner != "" {
				t.Fatalf("multiple winners: %q and %q", winner, result.providerID)
			}
			winner = result.providerID
		case errors.Is(result.err, ErrReferralExhausted):
		default:
			t.Fatalf("provider %q error=%v, want exhausted", result.providerID, result.err)
		}
	}
	if winner == "" {
		t.Fatal("no redemption winner")
	}

	var tokens, redemptions int
	if err := store.db.QueryRow(`SELECT COUNT(1) FROM provider_tokens WHERE revoked_at IS NULL`).Scan(&tokens); err != nil {
		t.Fatal(err)
	}
	if err := store.db.QueryRow(`SELECT COUNT(1) FROM referral_redemptions`).Scan(&redemptions); err != nil {
		t.Fatal(err)
	}
	if tokens != 1 || redemptions != 1 {
		t.Fatalf("tokens=%d redemptions=%d, want 1/1", tokens, redemptions)
	}

	var tokenProvider, redemptionProvider string
	if err := store.db.QueryRow(`SELECT provider_id FROM provider_tokens WHERE revoked_at IS NULL`).Scan(&tokenProvider); err != nil {
		t.Fatal(err)
	}
	if err := store.db.QueryRow(`SELECT provider_id FROM referral_redemptions`).Scan(&redemptionProvider); err != nil {
		t.Fatal(err)
	}
	if tokenProvider != winner || redemptionProvider != winner {
		t.Fatalf("winner=%q token_provider=%q redemption_provider=%q", winner, tokenProvider, redemptionProvider)
	}
}

func TestReferralFeatureOffAllowsFreshProviderWithoutRedemption(t *testing.T) {
	ctx := context.Background()
	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	_, token, err := store.IssueTokenWithReferral(ctx, "provider-fresh", "host-fresh", "", ReferralPolicy{})
	if err != nil {
		t.Fatal(err)
	}
	providerID, ok, err := store.ValidateToken(ctx, token)
	if err != nil || !ok || providerID != "provider-fresh" {
		t.Fatalf("provider_id=%q ok=%v err=%v", providerID, ok, err)
	}
	var redemptions int
	if err := store.db.QueryRow(`SELECT COUNT(1) FROM referral_redemptions`).Scan(&redemptions); err != nil {
		t.Fatal(err)
	}
	if redemptions != 0 {
		t.Fatalf("redemptions=%d, want 0", redemptions)
	}
}

func TestAppTrackReferralSagaPreservesCommittedAndCompensatesAbsent(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := coreReferralPolicy()
	code := seedCoreReferral(t, store, policy, "seed1")
	attempt := AppTrackRegistrationAttempt{
		SourceIP:  "203.0.113.10",
		Nonce:     strings.Repeat("a", 64),
		AttemptTS: time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC),
	}

	tokenCandidate := strings.Repeat("c", 64)
	token, err := store.MintProviderTokenAppTrackWithReferralAttempt(context.Background(), "provider-a", code, tokenCandidate, policy, attempt)
	if err != nil {
		t.Fatal(err)
	}
	pending, err := store.ListPendingAppTrackReferralMints(context.Background(), time.Now().UTC().Add(time.Hour))
	if err != nil || len(pending) != 1 {
		t.Fatalf("pending=%+v err=%v", pending, err)
	}
	if err := store.ResolvePendingAppTrackReferralMint(context.Background(), pending[0], false); err != nil {
		t.Fatal(err)
	}
	if _, ok, err := store.ValidateToken(context.Background(), token); err != nil || ok {
		t.Fatalf("rolled-back token ok=%v err=%v", ok, err)
	}

	committedToken, err := store.MintProviderTokenAppTrackWithReferralAttempt(context.Background(), "provider-b", code, strings.Repeat("d", 64), policy, AppTrackRegistrationAttempt{
		SourceIP: "203.0.113.11", Nonce: strings.Repeat("b", 64), AttemptTS: attempt.AttemptTS.Add(time.Second),
	})
	if err != nil {
		t.Fatal(err)
	}
	pending, err = store.ListPendingAppTrackReferralMints(context.Background(), time.Now().UTC().Add(time.Hour))
	if err != nil || len(pending) != 1 {
		t.Fatalf("pending=%+v err=%v", pending, err)
	}
	if err := store.ResolvePendingAppTrackReferralMint(context.Background(), pending[0], true); err != nil {
		t.Fatal(err)
	}
	if providerID, ok, err := store.ValidateToken(context.Background(), committedToken); err != nil || !ok || providerID != "provider-b" {
		t.Fatalf("committed token provider=%q ok=%v err=%v", providerID, ok, err)
	}
}

func TestCoreSchemaHasNoPublicReferralReservationTables(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	var count int
	if err := store.db.QueryRow(`
SELECT COUNT(1) FROM sqlite_master
 WHERE type = 'table' AND name LIKE 'referral_reservation%'`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatalf("reservation table count=%d, want 0", count)
	}
}
