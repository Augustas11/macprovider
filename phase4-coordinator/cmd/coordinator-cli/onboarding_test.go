package main

import (
	"bytes"
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/providerevents"
)

func TestListOnboardingMarksExpiredUnconfirmedAsFailed(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	now := time.Now().UTC().Add(-2 * time.Minute)
	policy := auth.ReferralPolicy{
		RequireForRegistration: true,
		Campaign:               "prebeta_test",
		PolicyVersion:          "v1",
		CurrentKeyID:           "k1",
		HMACKeys:               map[string]string{"k1": strings.Repeat("s", 32)},
		ProviderBaseUses:       1,
	}
	if _, err := store.DB().Exec(`
INSERT INTO referral_issuers (
    issuer_id, code_type, key_id, campaign, provider_id,
    base_capacity, bonus_capacity, created_at, first_serving_at
) VALUES ('seedcli', 'S', ?, ?, NULL, 1, 0, ?, ?)`,
		policy.CurrentKeyID, policy.Campaign, now.Format(time.RFC3339), now.Format(time.RFC3339),
	); err != nil {
		t.Fatal(err)
	}
	code, err := auth.EncodeReferralCode(policy, auth.ReferralTypeSeed, policy.CurrentKeyID, "seedcli")
	if err != nil {
		t.Fatal(err)
	}
	providerID := "mp-00000000000000000000000000000093"
	mint, err := store.MintBootstrapToken(ctx, auth.BootstrapMintRequest{
		ProviderID: providerID, ProviderName: "expired funnel", SourceIP: "192.0.2.93",
		ReceiptPubkey: bytes.Repeat([]byte{0x93}, 32), Now: now, TTL: time.Minute,
		PerIPLimitPerHour: 8, PerProviderPerHour: 3, GlobalLimitPerHour: 128,
		UnconfirmedIDMax: 64, OutstandingTokenMax: 64, IdentityRetention: 7 * 24 * time.Hour,
		ReferralCode: code, ReferralPolicy: policy,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}

	eventsPath := providerevents.DefaultDBPath(dbPath)
	events, err := providerevents.Open(eventsPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := events.Record(ctx, providerevents.Event{
		ProviderID:    providerID,
		Kind:          providerevents.KindAuthRejected,
		Outcome:       providerevents.OutcomeFailure,
		FailureReason: providerevents.ReasonInvalidToken,
		OccurredAt:    now.Add(30 * time.Second),
	}); err != nil {
		t.Fatal(err)
	}
	if err := events.Close(); err != nil {
		t.Fatal(err)
	}

	listed := captureStdout(t, func() {
		if err := listOnboarding([]string{"--db", dbPath, "--state", "failed_expired"}); err != nil {
			t.Fatal(err)
		}
	})
	if !strings.Contains(listed, "provider_id="+providerID+" state=failed_expired") {
		t.Fatalf("output=%q", listed)
	}
	if !strings.Contains(listed, "last_failure_reason=invalid_token") || !strings.Contains(listed, "redeemed_at=") {
		t.Fatalf("missing join fields: %q", listed)
	}
	if !strings.Contains(listed, "failed_expired=1") {
		t.Fatalf("summary missing: %q", listed)
	}
	if strings.Contains(listed, code) || strings.Contains(listed, mint.ProviderToken) || strings.Contains(listed, "code_digest") {
		t.Fatalf("leaked secret material: %q", listed)
	}
}
