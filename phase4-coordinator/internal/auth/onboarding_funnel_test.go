package auth

import (
	"bytes"
	"context"
	"database/sql"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestListOnboardingAttemptsJoinsRedemptionAndBootstrapIdentity(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	ctx := context.Background()
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	policy := coreReferralPolicy()
	code := seedCoreReferral(t, store, policy, "seedfunnel")
	providerID := "mp-00000000000000000000000000000081"
	if _, err := store.MintBootstrapToken(ctx, BootstrapMintRequest{
		ProviderID: providerID, ProviderName: "funnel pending", SourceIP: "192.0.2.81",
		ReceiptPubkey: bytes.Repeat([]byte{0x81}, 32), Now: now, TTL: time.Hour,
		PerIPLimitPerHour: 8, PerProviderPerHour: 3, GlobalLimitPerHour: 128,
		UnconfirmedIDMax: 64, OutstandingTokenMax: 64, IdentityRetention: 7 * 24 * time.Hour,
		ReferralCode: code, ReferralPolicy: policy,
	}); err != nil {
		t.Fatalf("mint: %v", err)
	}

	records, err := store.ListOnboardingAttempts(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 {
		t.Fatalf("attempts=%d want 1", len(records))
	}
	got := records[0]
	if got.ProviderID != providerID {
		t.Fatalf("provider_id=%q", got.ProviderID)
	}
	if got.Campaign != policy.Campaign || got.IssuerID != "seedfunnel" {
		t.Fatalf("campaign=%q issuer_id=%q", got.Campaign, got.IssuerID)
	}
	if !got.RedeemedAt.Valid || !got.BootstrapCreatedAt.Valid || !got.ExpiresAt.Valid {
		t.Fatalf("missing timestamps: %+v", got)
	}
	if got.ConfirmedAt.Valid {
		t.Fatal("pending attempt unexpectedly confirmed")
	}
	attempt := AssembleOnboardingAttempt(got, now.Add(time.Second))
	if attempt.State != OnboardingStatePending {
		t.Fatalf("state=%q want pending", attempt.State)
	}
	if strings.Contains(attempt.RedeemedAt, code) || strings.Contains(got.IssuerID, code) {
		t.Fatalf("invite code leaked: %+v", attempt)
	}
}

func TestOnboardingFunnelStatesCoverExpiredConfirmedLiveAndRevoked(t *testing.T) {
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)

	t.Run("failed_expired unconfirmed past ttl", func(t *testing.T) {
		record := OnboardingAttemptRecord{
			ProviderID: "mp-expired",
			RedeemedAt: sql.NullString{String: timeText(now.Add(-2 * time.Minute)), Valid: true},
			ExpiresAt:  sql.NullString{String: timeText(now.Add(-time.Minute)), Valid: true},
		}
		if got := DeriveOnboardingState(record, now, false); got != OnboardingStateFailedExpired {
			t.Fatalf("state=%q", got)
		}
	})

	t.Run("failed_expired after identity collection", func(t *testing.T) {
		record := OnboardingAttemptRecord{
			ProviderID: "mp-collected",
			Campaign:   "prebeta_test",
			IssuerID:   "seed-funnel",
			RedeemedAt: sql.NullString{String: timeText(now.Add(-8 * 24 * time.Hour)), Valid: true},
		}
		attempt := AssembleOnboardingAttempt(record, now)
		if attempt.State != OnboardingStateFailedExpired {
			t.Fatalf("state=%q want failed_expired", attempt.State)
		}
		if attempt.RedeemedAt == "" || attempt.BootstrapCreatedAt != "" {
			t.Fatalf("collected identity row=%+v", attempt)
		}
	})

	t.Run("confirmed offline is not live", func(t *testing.T) {
		record := OnboardingAttemptRecord{
			ProviderID:  "mp-confirmed",
			ConfirmedAt: sql.NullString{String: timeText(now), Valid: true},
		}
		attempt := OverlayPresence(AssembleOnboardingAttempt(record, now), OnboardingPresence{
			LastSeenAt:      timeText(now),
			LastHeartbeatAt: timeText(now),
		}, now, record)
		if attempt.State != OnboardingStateConfirmed || attempt.Presence != OnboardingPresenceOffline {
			t.Fatalf("state=%q presence=%q", attempt.State, attempt.Presence)
		}
	})

	t.Run("confirmed connected is live", func(t *testing.T) {
		record := OnboardingAttemptRecord{
			ProviderID:  "mp-live",
			ConfirmedAt: sql.NullString{String: timeText(now), Valid: true},
		}
		attempt := OverlayPresence(AssembleOnboardingAttempt(record, now), OnboardingPresence{
			Connected:       true,
			LastHeartbeatAt: timeText(now),
		}, now, record)
		if attempt.State != OnboardingStateLive || attempt.Presence != OnboardingPresenceConnected {
			t.Fatalf("state=%q presence=%q", attempt.State, attempt.Presence)
		}
	})

	t.Run("operator revoked beats live overlay", func(t *testing.T) {
		record := OnboardingAttemptRecord{
			ProviderID:        "mp-revoked",
			OperatorRevokedAt: sql.NullString{String: timeText(now), Valid: true},
			ConfirmedAt:       sql.NullString{String: timeText(now), Valid: true},
		}
		attempt := OverlayPresence(AssembleOnboardingAttempt(record, now), OnboardingPresence{Connected: true}, now, record)
		if attempt.State != OnboardingStateFailedRevoked {
			t.Fatalf("state=%q", attempt.State)
		}
	})
}

func TestListOnboardingAttemptsKeepsRedemptionAfterIdentityDelete(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	ctx := context.Background()
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	policy := coreReferralPolicy()
	code := seedCoreReferral(t, store, policy, "seedgc")
	providerID := "mp-00000000000000000000000000000082"
	if _, err := store.MintBootstrapToken(ctx, BootstrapMintRequest{
		ProviderID: providerID, ProviderName: "funnel gc", SourceIP: "192.0.2.82",
		ReceiptPubkey: bytes.Repeat([]byte{0x82}, 32), Now: now, TTL: time.Hour,
		PerIPLimitPerHour: 8, PerProviderPerHour: 3, GlobalLimitPerHour: 128,
		UnconfirmedIDMax: 64, OutstandingTokenMax: 64, IdentityRetention: 7 * 24 * time.Hour,
		ReferralCode: code, ReferralPolicy: policy,
	}); err != nil {
		t.Fatalf("mint: %v", err)
	}
	if _, err := store.db.ExecContext(ctx, `DELETE FROM provider_bootstrap_identities WHERE provider_id = ?`, providerID); err != nil {
		t.Fatal(err)
	}
	records, err := store.ListOnboardingAttempts(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 || records[0].ProviderID != providerID || !records[0].RedeemedAt.Valid || records[0].BootstrapCreatedAt.Valid {
		t.Fatalf("gc join=%+v", records)
	}
	if AssembleOnboardingAttempt(records[0], now).State != OnboardingStateFailedExpired {
		t.Fatalf("state=%q", AssembleOnboardingAttempt(records[0], now).State)
	}
	if AssembleOnboardingAttempt(records[0], now).ExpiresAt != "" {
		t.Fatalf("collected identity still has expires_at=%q", AssembleOnboardingAttempt(records[0], now).ExpiresAt)
	}
}

func TestSummarizeOnboardingAttempts(t *testing.T) {
	summary := SummarizeOnboardingAttempts([]OnboardingAttempt{
		{State: OnboardingStatePending},
		{State: OnboardingStatePending},
		{State: OnboardingStateConfirmed},
		{State: OnboardingStateLive},
		{State: OnboardingStateFailedExpired},
		{State: OnboardingStateFailedRevoked},
	})
	if summary.Pending != 2 || summary.Confirmed != 1 || summary.Live != 1 || summary.FailedExpired != 1 || summary.FailedRevoked != 1 {
		t.Fatalf("summary=%+v", summary)
	}
}

func TestPageOnboardingAttemptsEmitsCursorWhenTruncated(t *testing.T) {
	ts := "2026-08-31T12:00:00Z"
	attempts := []OnboardingAttempt{
		{ProviderID: "mp-a", State: OnboardingStatePending, RedeemedAt: ts},
		{ProviderID: "mp-b", State: OnboardingStateConfirmed, RedeemedAt: ts},
		{ProviderID: "mp-c", State: OnboardingStatePending, RedeemedAt: ts},
	}
	page, nextTS, nextID := PageOnboardingAttempts(attempts, "pending", 1, "", "")
	if len(page) != 1 || page[0].ProviderID != "mp-a" || nextID != "mp-a" || nextTS != ts {
		t.Fatalf("first page=%+v next=%s %s", page, nextTS, nextID)
	}
	page, nextTS, nextID = PageOnboardingAttempts(attempts, "pending", 1, nextTS, nextID)
	if len(page) != 1 || page[0].ProviderID != "mp-c" || nextID != "" {
		t.Fatalf("second page=%+v next=%s %s", page, nextTS, nextID)
	}
}
