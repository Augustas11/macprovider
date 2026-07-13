package auth

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
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
