package ws

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
	_ "modernc.org/sqlite"
)

func TestAdmissionManagerTiersRateLimitAndQuota(t *testing.T) {
	now := time.Date(2026, 5, 28, 12, 0, 0, 0, time.UTC)
	adm := NewAdmissionManager(config.AdmissionConfig{
		ProvisionalAdmissionRatePerHour: 1,
		ProvisionalPoolMax:              10,
		ProvisionalQuotaPerHour:         2,
		ProvisionalTierWeight:           0.3,
	}, func() time.Time { return now })

	pinned, code, reason := adm.Admit(Hello{ProviderID: "m4-anon"}, true, 0)
	if pinned != pool.TierPinned || code != 0 || reason != "" {
		t.Fatalf("pinned admission = tier:%s code:%d reason:%q", pinned, code, reason)
	}

	hello := Hello{ProviderID: "new-1", Hostname: "host", ModelID: "model", BinaryVersion: "1.2.0"}
	tier, code, reason := adm.Admit(hello, false, 0)
	if tier != pool.TierProvisional || code != 0 || reason != "" {
		t.Fatalf("first provisional = tier:%s code:%d reason:%q", tier, code, reason)
	}

	_, code, _ = adm.Admit(Hello{ProviderID: "new-2"}, false, 0)
	if code != CloseProvisionalRateLimited {
		t.Fatalf("second provisional code = %d, want %d", code, CloseProvisionalRateLimited)
	}

	provider := pool.Provider{ProviderID: "new-1", Tier: pool.TierProvisional}
	if !adm.CheckQuota(provider) {
		t.Fatal("quota unexpectedly blocked first request")
	}
	if !adm.TryReserveRequest(provider) {
		t.Fatal("first reservation blocked")
	}
	if !adm.TryReserveRequest(provider) {
		t.Fatal("second reservation blocked")
	}
	if adm.TryReserveRequest(provider) {
		t.Fatal("quota allowed third reservation")
	}
	adm.RefundRequest(provider)
	if !adm.TryReserveRequest(provider) {
		t.Fatal("reservation after refund blocked")
	}

	if previous, ok := adm.Promote("new-1"); !ok || previous != "provisional" {
		t.Fatalf("promote previous=%q ok=%v", previous, ok)
	}
	adm.Reject("new-1", "test")
	if !adm.Rejected("new-1") {
		t.Fatal("provider not rejected")
	}
}

func TestAdmissionRefreshTelemetryAfterPromote(t *testing.T) {
	now := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	adm := NewAdmissionManager(config.AdmissionConfig{
		ProvisionalAdmissionRatePerHour: 1,
		ProvisionalPoolMax:              10,
	}, func() time.Time { return now })

	hello := Hello{ProviderID: "new-1", Hostname: "host", ModelID: "model", BinaryVersion: "1.8.115"}
	if tier, code, reason := adm.Admit(hello, false, 0); tier != pool.TierProvisional || code != 0 || reason != "" {
		t.Fatalf("admit = tier:%s code:%d reason:%q", tier, code, reason)
	}
	if _, ok := adm.Promote("new-1"); !ok {
		t.Fatal("promote failed")
	}

	now = now.Add(2 * time.Minute)
	adm.RefreshTelemetry("new-1", "host", "model", "1.8.117")
	adm.RefreshTelemetry("unknown", "other", "model", "9.9.9")

	recs := adm.Records(nil)
	if len(recs) != 1 {
		t.Fatalf("records=%d want 1 (unknown provider must not mint a row)", len(recs))
	}
	if recs[0].BinaryVersion != "1.8.117" {
		t.Fatalf("binary_version=%q want 1.8.117", recs[0].BinaryVersion)
	}
	if !recs[0].LastSeenAt.Equal(now) {
		t.Fatalf("last_seen=%s want %s", recs[0].LastSeenAt, now)
	}
	if recs[0].PromotedAt == nil {
		t.Fatal("promoted_at cleared by telemetry refresh")
	}

	if _, code, _ := adm.Admit(Hello{ProviderID: "new-2"}, false, 0); code != CloseProvisionalRateLimited {
		t.Fatalf("second provisional code = %d, want rate-limited %d (refresh must not consume a rate-limit slot)", code, CloseProvisionalRateLimited)
	}
}

func TestCommitReservedAdmissionAsPinnedRefreshesExistingRecord(t *testing.T) {
	now := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	adm := NewAdmissionManager(config.AdmissionConfig{
		ProvisionalAdmissionRatePerHour: 1,
		ProvisionalPoolMax:              10,
	}, func() time.Time { return now })

	hello := Hello{ProviderID: "new-1", Hostname: "host", ModelID: "model", BinaryVersion: "1.8.115"}
	if _, code, _ := adm.Admit(hello, false, 0); code != 0 {
		t.Fatalf("admit code=%d", code)
	}
	if _, ok := adm.Promote("new-1"); !ok {
		t.Fatal("promote failed")
	}

	now = now.Add(2 * time.Minute)
	rehello := Hello{ProviderID: "new-1", Hostname: "host-2", ModelID: "model-b", BinaryVersion: "1.8.117"}
	if got := adm.CommitReservedAdmissionAs(rehello, pool.TierPinned); got != pool.TierPinned {
		t.Fatalf("commit pinned = %s", got)
	}

	recs := adm.Records(nil)
	if len(recs) != 1 || recs[0].BinaryVersion != "1.8.117" || recs[0].Hostname != "host-2" || recs[0].ModelID != "model-b" {
		t.Fatalf("pinned reconnect did not refresh snapshot: %#v", recs)
	}
	if !recs[0].LastSeenAt.Equal(now) {
		t.Fatalf("last_seen=%s want %s", recs[0].LastSeenAt, now)
	}
	if _, code, _ := adm.Admit(Hello{ProviderID: "new-2"}, false, 0); code != CloseProvisionalRateLimited {
		t.Fatalf("pinned reconnect consumed a rate-limit slot, code=%d", code)
	}
}

func TestAdmissionRefreshTelemetryDoesNotCreateRecord(t *testing.T) {
	now := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	adm := NewAdmissionManager(config.AdmissionConfig{
		ProvisionalAdmissionRatePerHour: 1,
		ProvisionalPoolMax:              10,
	}, func() time.Time { return now })

	adm.RefreshTelemetry("never-admitted", "host", "model", "1.8.117")
	if recs := adm.Records(nil); len(recs) != 0 {
		t.Fatalf("records=%d want 0", len(recs))
	}
	if tier, code, _ := adm.Admit(Hello{ProviderID: "new-1", Hostname: "host", ModelID: "model", BinaryVersion: "1.8.115"}, false, 0); tier != pool.TierProvisional || code != 0 {
		t.Fatalf("first real admit blocked after no-op refresh: tier=%s code=%d", tier, code)
	}
}

func TestAdmissionRefreshTelemetryPersistsVersionImmediatelyAndThrottlesLastSeen(t *testing.T) {
	now := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	store := &countingAdmissionStore{}
	adm := NewAdmissionManager(config.AdmissionConfig{
		ProvisionalAdmissionRatePerHour: 1,
		ProvisionalPoolMax:              10,
	}, func() time.Time { return now })
	adm.SetPersistence(store, nil)

	hello := Hello{ProviderID: "new-1", Hostname: "host", ModelID: "model", BinaryVersion: "1.8.115"}
	if _, code, _ := adm.Admit(hello, false, 0); code != 0 {
		t.Fatalf("admit code=%d", code)
	}
	if _, ok := adm.Promote("new-1"); !ok {
		t.Fatal("promote failed")
	}
	afterPromote := store.saves

	now = now.Add(10 * time.Second)
	adm.RefreshTelemetry("new-1", "host", "model", "1.8.115")
	if store.saves != afterPromote {
		t.Fatalf("last-seen-only refresh inside interval persisted, saves=%d want %d", store.saves, afterPromote)
	}

	adm.RefreshTelemetry("new-1", "host", "model", "1.8.117")
	if store.saves != afterPromote+1 {
		t.Fatalf("version change did not persist immediately, saves=%d want %d", store.saves, afterPromote+1)
	}

	now = now.Add(10 * time.Second)
	adm.RefreshTelemetry("new-1", "host", "model", "1.8.117")
	if store.saves != afterPromote+1 {
		t.Fatalf("last-seen-only refresh after version persist wrote again, saves=%d", store.saves)
	}

	now = now.Add(admissionTelemetryPersistInterval + time.Second)
	adm.RefreshTelemetry("new-1", "host", "model", "1.8.117")
	if store.saves != afterPromote+2 {
		t.Fatalf("last-seen refresh after interval did not persist, saves=%d want %d", store.saves, afterPromote+2)
	}
}

func TestOverlayLiveAdmissionRecordsPrefersLivePool(t *testing.T) {
	frozen := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	liveAt := frozen.Add(2 * time.Hour)
	records := []ProvisionalRecord{{
		ProviderID:    "provider-a",
		BinaryVersion: "1.8.115",
		LastSeenAt:    frozen,
		Hostname:      "old-host",
		ModelID:       "old-model",
	}}
	live := map[string]pool.Provider{
		"provider-a": {
			ProviderID:      "provider-a",
			BinaryVersion:   "1.8.117",
			Hostname:        "new-host",
			ModelID:         "new-model",
			LastHeartbeatAt: liveAt,
			Tier:            pool.TierPinned,
		},
	}
	connected := append([]ProvisionalRecord(nil), records...)
	out := overlayLiveAdmissionRecords(connected, live, map[string]bool{"provider-a": true})
	if out[0].BinaryVersion != "1.8.117" || out[0].Hostname != "new-host" || out[0].ModelID != "new-model" {
		t.Fatalf("overlay identity: %+v", out[0])
	}
	if !out[0].LastSeenAt.Equal(liveAt) {
		t.Fatalf("last_seen=%s want %s", out[0].LastSeenAt, liveAt)
	}

	offline := overlayLiveAdmissionRecords(append([]ProvisionalRecord(nil), records...), live, map[string]bool{})
	if offline[0].BinaryVersion != "1.8.115" {
		t.Fatalf("offline overlay mutated frozen snapshot: %q", offline[0].BinaryVersion)
	}
}

func TestPromotedAdmissionTelemetryDoesNotBypassRetentionAfterDisconnect(t *testing.T) {
	now := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	adm := NewAdmissionManager(config.AdmissionConfig{
		ProvisionalAdmissionRatePerHour: 1,
		ProvisionalPoolMax:              10,
		ProvisionalRetentionDays:        30,
	}, func() time.Time { return now })

	hello := Hello{ProviderID: "new-1", Hostname: "host", ModelID: "model", BinaryVersion: "1.8.115"}
	if _, code, _ := adm.Admit(hello, false, 0); code != 0 {
		t.Fatalf("admit code=%d", code)
	}
	if _, ok := adm.Promote("new-1"); !ok {
		t.Fatal("promote failed")
	}
	now = now.Add(2 * time.Minute)
	adm.RefreshTelemetry("new-1", "host", "model", "1.8.117")

	if deleted, _, _ := adm.Prune(now.Add(-time.Second)); deleted != 0 {
		t.Fatalf("fresh last_seen pruned immediately, deleted=%d", deleted)
	}

	now = now.Add(31 * 24 * time.Hour)
	cutoff := now.Add(-30 * 24 * time.Hour)
	deleted, _, _ := adm.Prune(cutoff)
	if deleted != 1 {
		t.Fatalf("disconnected promoted record survived retention, deleted=%d", deleted)
	}
	if recs := adm.Records(nil); len(recs) != 0 {
		t.Fatalf("records after retention prune = %+v", recs)
	}
}

func TestAdmissionRefreshTelemetryCoalescesPersistsAcrossProviders(t *testing.T) {
	now := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	store := &countingAdmissionStore{}
	adm := NewAdmissionManager(config.AdmissionConfig{
		ProvisionalAdmissionRatePerHour: 10,
		ProvisionalPoolMax:              10,
	}, func() time.Time { return now })
	adm.SetPersistence(store, nil)

	if _, code, _ := adm.Admit(Hello{ProviderID: "a", Hostname: "h", ModelID: "m", BinaryVersion: "1.8.115"}, false, 0); code != 0 {
		t.Fatalf("admit a code=%d", code)
	}
	if _, code, _ := adm.Admit(Hello{ProviderID: "b", Hostname: "h", ModelID: "m", BinaryVersion: "1.8.115"}, false, 0); code != 0 {
		t.Fatalf("admit b code=%d", code)
	}
	afterAdmit := store.saves

	now = now.Add(10 * time.Second)
	adm.RefreshTelemetry("a", "h", "m", "1.8.115")
	adm.RefreshTelemetry("b", "h", "m", "1.8.115")
	if store.saves != afterAdmit {
		t.Fatalf("last-seen-only refreshes persisted per provider, saves=%d want %d", store.saves, afterAdmit)
	}

	recs := adm.Records(nil)
	if len(recs) != 2 || recs[0].LastSeenAt.IsZero() {
		t.Fatalf("in-memory last_seen not updated: %+v", recs)
	}
}

func TestAdmissionManagerTrustedTierBypassesProvisionalQuotaByDefault(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	adm := NewAdmissionManager(config.AdmissionConfig{
		ProvisionalAdmissionRatePerHour: 1,
		ProvisionalPoolMax:              1,
		ProvisionalQuotaPerHour:         1,
		TrustedQuotaPerHour:             0,
	}, func() time.Time { return now })

	if tier, code, reason := adm.AdmitAs(Hello{ProviderID: "trusted-1"}, pool.TierTrusted, 0); tier != pool.TierTrusted || code != 0 || reason != "" {
		t.Fatalf("trusted admit = tier:%s code:%d reason:%q", tier, code, reason)
	}
	trusted := pool.Provider{ProviderID: "trusted-1", Tier: pool.TierTrusted}
	for i := 0; i < 3; i++ {
		if !adm.TryReserveRequest(trusted) {
			t.Fatalf("trusted request %d blocked by provisional quota", i+1)
		}
	}

	provisional := pool.Provider{ProviderID: "trusted-1", Tier: pool.TierProvisional}
	if !adm.TryReserveRequest(provisional) {
		t.Fatal("first provisional request after demotion blocked")
	}
	if adm.TryReserveRequest(provisional) {
		t.Fatal("demoted provider bypassed provisional quota")
	}
}

func TestAdmissionManagerTrustedTierHonorsConfiguredQuota(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	adm := NewAdmissionManager(config.AdmissionConfig{
		ProvisionalQuotaPerHour: 1,
		TrustedQuotaPerHour:     1,
	}, func() time.Time { return now })
	trusted := pool.Provider{ProviderID: "trusted-1", Tier: pool.TierTrusted}

	if !adm.TryReserveRequest(trusted) {
		t.Fatal("first trusted request blocked")
	}
	if adm.TryReserveRequest(trusted) {
		t.Fatal("trusted provider bypassed configured trusted quota")
	}
	adm.RefundRequest(trusted)
	if !adm.TryReserveRequest(trusted) {
		t.Fatal("trusted request after refund blocked")
	}
}

func TestRoutingAdmissionTierRequiresAuthenticatedRewardsTrust(t *testing.T) {
	cfg := config.Default()
	s := NewServer(cfg, pool.NewRegistry(nil), zerolog.Nop(), WithProviderRewardsTrustTierStore(fakeRewardsTrustStore{
		tiers: map[string]string{"provider-a": string(pool.TierTrusted)},
	}))

	if tier := s.routingAdmissionTier(context.Background(), providerAuth{validated: true, providerID: "provider-a"}, "provider-a", false); tier != pool.TierProvisional {
		t.Fatalf("authenticated trusted tier without durable proof = %s, want provisional", tier)
	}
	if tier := s.routingAdmissionTierWithCustody(context.Background(), providerAuth{validated: true, providerID: "provider-a"}, "provider-a", false, true); tier != pool.TierTrusted {
		t.Fatalf("authenticated trusted tier with durable proof = %s, want %s", tier, pool.TierTrusted)
	}
	if tier := s.routingAdmissionTier(context.Background(), providerAuth{}, "provider-a", false); tier != pool.TierProvisional {
		t.Fatalf("tokenless trusted-id tier = %s, want provisional", tier)
	}
	if tier := s.routingAdmissionTier(context.Background(), providerAuth{validated: true, providerID: "other"}, "provider-a", false); tier != pool.TierProvisional {
		t.Fatalf("mismatched token tier = %s, want provisional", tier)
	}
}

func TestRoutingAdmissionTierRejectsTrustedQuotaAfterLegacyTokenRevocation(t *testing.T) {
	ctx := context.Background()
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	first, _, err := store.IssueToken(ctx, "provider-a", "host-a")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.RevokeToken(ctx, first.TokenPrefix); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.IssueToken(ctx, "provider-a", "host-a"); err != nil {
		t.Fatal(err)
	}

	s := NewServer(config.Default(), pool.NewRegistry(nil), zerolog.Nop(),
		WithTokenValidator(store),
		WithProviderRewardsTrustTierStore(fakeRewardsTrustStore{
			tiers: map[string]string{"provider-a": string(pool.TierTrusted)},
		}),
	)

	tier := s.routingAdmissionTier(ctx, providerAuth{validated: true, providerID: "provider-a"}, "provider-a", false)
	if tier != pool.TierProvisional {
		t.Fatalf("legacy revoked-history trusted tier = %s, want provisional", tier)
	}
	if tier := s.routingAdmissionTier(ctx, providerAuth{validated: true, providerID: "provider-a"}, "provider-a", true); tier != pool.TierPinned {
		t.Fatalf("operator-pinned tier = %s, want pinned", tier)
	}
}

func TestRoutingAdmissionTierRejectsTrustedQuotaWithoutDurableIdentityProofEvenWithoutRevocation(t *testing.T) {
	ctx := context.Background()
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if _, _, err := store.IssueToken(ctx, "provider-a", "host-a"); err != nil {
		t.Fatal(err)
	}

	s := NewServer(config.Default(), pool.NewRegistry(nil), zerolog.Nop(),
		WithTokenValidator(store),
		WithProviderRewardsTrustTierStore(fakeRewardsTrustStore{
			tiers: map[string]string{"provider-a": string(pool.TierTrusted)},
		}),
	)

	tier := s.routingAdmissionTierWithCustody(ctx, providerAuth{validated: true, providerID: "provider-a"}, "provider-a", false, false)
	if tier != pool.TierProvisional {
		t.Fatalf("new-bearer trusted tier without durable proof = %s, want provisional", tier)
	}

	tier = s.routingAdmissionTierWithCustody(ctx, providerAuth{validated: true, providerID: "provider-a"}, "provider-a", false, true)
	if tier != pool.TierTrusted {
		t.Fatalf("verified durable-identity trusted tier without revocation history = %s, want trusted", tier)
	}
}

func TestRoutingAdmissionTierRequiresVerifiedDurableIdentityAfterRevocation(t *testing.T) {
	ctx := context.Background()
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	first, _, err := store.IssueToken(ctx, "provider-a", "host-a")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.RevokeToken(ctx, first.TokenPrefix); err != nil {
		t.Fatal(err)
	}
	_, secondToken, err := store.IssueToken(ctx, "provider-a", "host-a")
	if err != nil {
		t.Fatal(err)
	}
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.BindAdmissionIdentity(ctx, "provider-a", secondToken, pub, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}

	s := NewServer(config.Default(), pool.NewRegistry(nil), zerolog.Nop(),
		WithTokenValidator(store),
		WithBootstrapTokenStore(store),
		WithProviderRewardsTrustTierStore(fakeRewardsTrustStore{
			tiers: map[string]string{"provider-a": string(pool.TierTrusted)},
		}),
	)

	tier := s.routingAdmissionTierWithCustody(ctx, providerAuth{validated: true, providerID: "provider-a"}, "provider-a", false, false)
	if tier != pool.TierProvisional {
		t.Fatalf("durable-row-only trusted tier = %s, want provisional", tier)
	}

	tier = s.routingAdmissionTierWithCustody(ctx, providerAuth{validated: true, providerID: "provider-a"}, "provider-a", false, true)
	if tier != pool.TierTrusted {
		t.Fatalf("verified durable-identity trusted tier = %s, want trusted", tier)
	}
}

func TestIdentityProofMarksOnlyExistingDurableKeyAsQuotaCustody(t *testing.T) {
	const providerID = "provider-a"
	ctx := context.Background()
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	_, bearer, err := store.IssueToken(ctx, providerID, "host-a")
	if err != nil {
		t.Fatal(err)
	}
	currentPubkey, currentPrivateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.BindAdmissionIdentity(ctx, providerID, bearer, currentPubkey, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}

	s := NewServer(config.Default(), pool.NewRegistry(nil), zerolog.Nop(),
		WithBootstrapTokenStore(store),
	)
	initial := AuthRequest{
		ProviderID:                 providerID,
		BinaryVersion:              "1.2.3",
		ProviderECDHPublicKey:      "ecdh-key",
		ProviderAdmissionPubkey:    append([]byte(nil), currentPubkey...),
		ProviderAdmissionPublicKey: base64.StdEncoding.EncodeToString(currentPubkey),
	}
	retained := retainedAuthAttemptForIdentityProof(t, initial)
	proof := signedIdentityProof(t, initial, retained, currentPrivateKey)

	result := s.verifyIdentitySignature(ctx, initial, proof, retained, providerAuth{
		validated:  true,
		providerID: providerID,
		token:      bearer,
	})
	if !result.Accepted || !result.DurableAdmissionIdentityVerified {
		t.Fatalf("existing durable proof accepted=%v durable_verified=%v", result.Accepted, result.DurableAdmissionIdentityVerified)
	}

	_, enrollmentBearer, err := store.IssueToken(ctx, "provider-b", "host-b")
	if err != nil {
		t.Fatal(err)
	}
	enrollmentPubkey, enrollmentPrivateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	enrollmentInitial := initial
	enrollmentInitial.ProviderID = "provider-b"
	enrollmentInitial.ProviderAdmissionPubkey = append([]byte(nil), enrollmentPubkey...)
	enrollmentInitial.ProviderAdmissionPublicKey = base64.StdEncoding.EncodeToString(enrollmentPubkey)
	enrollmentRetained := retainedAuthAttemptForIdentityProof(t, enrollmentInitial)
	enrollmentProof := signedIdentityProof(t, enrollmentInitial, enrollmentRetained, enrollmentPrivateKey)
	result = s.verifyIdentitySignature(ctx, enrollmentInitial, enrollmentProof, enrollmentRetained, providerAuth{
		validated:  true,
		providerID: "provider-b",
		token:      enrollmentBearer,
	})
	if !result.Accepted || result.DurableAdmissionIdentityVerified {
		t.Fatalf("first enrollment accepted=%v durable_verified=%v", result.Accepted, result.DurableAdmissionIdentityVerified)
	}
}

func TestV2DeferredAdmissionAllowsVerifiedTrustedQuotaWhenProvisionalPoolFull(t *testing.T) {
	ctx := context.Background()
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	first, _, err := store.IssueToken(ctx, "provider-a", "host-a")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.RevokeToken(ctx, first.TokenPrefix); err != nil {
		t.Fatal(err)
	}
	_, bearer, err := store.IssueToken(ctx, "provider-a", "host-a")
	if err != nil {
		t.Fatal(err)
	}
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.BindAdmissionIdentity(ctx, "provider-a", bearer, pub, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}

	cfg := config.Default()
	cfg.Admission.ProvisionalPoolMax = 0
	s := NewServer(cfg, pool.NewRegistry(nil), zerolog.Nop(),
		WithTokenValidator(store),
		WithBootstrapTokenStore(store),
		WithProviderRewardsTrustTierStore(fakeRewardsTrustStore{
			tiers: map[string]string{"provider-a": string(pool.TierTrusted)},
		}),
	)
	hello := capacityTestHello(2)

	entry, ok := s.prepareProviderAdmissionDeferredQuota(nil, providerAuth{validated: true, providerID: "provider-a"}, hello)
	if !ok {
		t.Fatal("deferred v2 admission rejected before durable identity proof")
	}
	if entry.Tier != pool.TierProvisional {
		t.Fatalf("pre-proof tier = %s, want provisional", entry.Tier)
	}

	finalTier := s.routingAdmissionTierWithCustody(ctx, providerAuth{validated: true, providerID: "provider-a"}, "provider-a", false, true)
	if finalTier != pool.TierTrusted {
		t.Fatalf("post-proof tier = %s, want trusted", finalTier)
	}
	if tier, code, reason := s.admission.ReserveAdmissionAs(hello, finalTier, s.connectedProvisional()); tier != pool.TierTrusted || code != 0 || reason != "" {
		t.Fatalf("trusted reserve after proof = tier:%s code:%d reason:%q, want trusted success", tier, code, reason)
	}

	unverifiedTier := s.routingAdmissionTierWithCustody(ctx, providerAuth{validated: true, providerID: "provider-a"}, "provider-a", false, false)
	if unverifiedTier != pool.TierProvisional {
		t.Fatalf("unverified tier = %s, want provisional", unverifiedTier)
	}
	if _, code, _ := s.admission.ReserveAdmissionAs(hello, unverifiedTier, s.connectedProvisional()); code != CloseProvisionalPoolFull {
		t.Fatalf("unverified reserve code = %d, want provisional pool full", code)
	}
}

func TestRewardsTrustReconciliationDemotesLiveTrustedProvider(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registry.Register(&pool.Provider{
		ProviderID: "provider-a",
		AssignedID: "session-a",
		Tier:       pool.TierTrusted,
		State:      pool.StateReady,
		AuthState:  pool.AuthBearerValidated,
	}, nil)
	s := NewServer(config.Default(), registry, zerolog.Nop(), WithProviderRewardsTrustTierStore(fakeRewardsTrustStore{
		tiers: map[string]string{"provider-a": string(pool.TierProvisional)},
	}))
	s.sessions.Store(sessionKey("provider-a", "session-a"), &providerSession{})

	s.runRewardsTrustTierReconciliationSweep()

	got, ok := registry.Resolve("provider-a", "session-a")
	if !ok {
		t.Fatal("provider disappeared")
	}
	if got.Tier != pool.TierProvisional {
		t.Fatalf("reconciled tier = %s, want provisional", got.Tier)
	}
}

func TestRewardsTrustReconciliationDemotesTrustedProviderWithRevokedLegacyTokenHistory(t *testing.T) {
	ctx := context.Background()
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	first, _, err := store.IssueToken(ctx, "provider-a", "host-a")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.RevokeToken(ctx, first.TokenPrefix); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.IssueToken(ctx, "provider-a", "host-a"); err != nil {
		t.Fatal(err)
	}

	registry := pool.NewRegistry(nil)
	registry.Register(&pool.Provider{
		ProviderID: "provider-a",
		AssignedID: "session-a",
		Tier:       pool.TierTrusted,
		State:      pool.StateReady,
		AuthState:  pool.AuthBearerValidated,
	}, nil)
	s := NewServer(config.Default(), registry, zerolog.Nop(),
		WithTokenValidator(store),
		WithProviderRewardsTrustTierStore(fakeRewardsTrustStore{
			tiers: map[string]string{"provider-a": string(pool.TierTrusted)},
		}),
	)
	s.sessions.Store(sessionKey("provider-a", "session-a"), &providerSession{})

	s.runRewardsTrustTierReconciliationSweep()

	got, ok := registry.Resolve("provider-a", "session-a")
	if !ok {
		t.Fatal("provider disappeared")
	}
	if got.Tier != pool.TierProvisional {
		t.Fatalf("tier after revoked legacy token history = %s, want provisional", got.Tier)
	}
}

func TestRewardsTrustReconciliationDemotesTrustedProviderWithoutDurableIdentityProof(t *testing.T) {
	ctx := context.Background()
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if _, _, err := store.IssueToken(ctx, "provider-a", "host-a"); err != nil {
		t.Fatal(err)
	}

	registry := pool.NewRegistry(nil)
	registry.Register(&pool.Provider{
		ProviderID: "provider-a",
		AssignedID: "session-a",
		Tier:       pool.TierTrusted,
		State:      pool.StateReady,
		AuthState:  pool.AuthBearerValidated,
	}, nil)
	s := NewServer(config.Default(), registry, zerolog.Nop(),
		WithTokenValidator(store),
		WithProviderRewardsTrustTierStore(fakeRewardsTrustStore{
			tiers: map[string]string{"provider-a": string(pool.TierTrusted)},
		}),
	)
	s.sessions.Store(sessionKey("provider-a", "session-a"), &providerSession{})

	s.runRewardsTrustTierReconciliationSweep()

	got, ok := registry.Resolve("provider-a", "session-a")
	if !ok {
		t.Fatal("provider disappeared")
	}
	if got.Tier != pool.TierProvisional {
		t.Fatalf("tier without durable identity proof = %s, want provisional", got.Tier)
	}
}

func TestRewardsTrustReconciliationKeepsVerifiedDurableIdentityAfterRevokedHistory(t *testing.T) {
	ctx := context.Background()
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	first, _, err := store.IssueToken(ctx, "provider-a", "host-a")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.RevokeToken(ctx, first.TokenPrefix); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.IssueToken(ctx, "provider-a", "host-a"); err != nil {
		t.Fatal(err)
	}

	registry := pool.NewRegistry(nil)
	registry.Register(&pool.Provider{
		ProviderID:                       "provider-a",
		AssignedID:                       "session-a",
		Tier:                             pool.TierTrusted,
		State:                            pool.StateReady,
		AuthState:                        pool.AuthBearerValidated,
		DurableAdmissionIdentityVerified: true,
	}, nil)
	s := NewServer(config.Default(), registry, zerolog.Nop(),
		WithTokenValidator(store),
		WithProviderRewardsTrustTierStore(fakeRewardsTrustStore{
			tiers: map[string]string{"provider-a": string(pool.TierTrusted)},
		}),
	)
	s.sessions.Store(sessionKey("provider-a", "session-a"), &providerSession{})

	s.runRewardsTrustTierReconciliationSweep()

	got, ok := registry.Resolve("provider-a", "session-a")
	if !ok {
		t.Fatal("provider disappeared")
	}
	if got.Tier != pool.TierTrusted {
		t.Fatalf("verified durable identity tier after revoked history = %s, want trusted", got.Tier)
	}
}

func TestRewardsTrustReconciliationDoesNotPromoteNonBearerSession(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registry.Register(&pool.Provider{
		ProviderID: "provider-a",
		AssignedID: "session-a",
		Tier:       pool.TierProvisional,
		State:      pool.StateReady,
		AuthState:  pool.AuthSelfMinted,
	}, nil)
	s := NewServer(config.Default(), registry, zerolog.Nop(), WithProviderRewardsTrustTierStore(fakeRewardsTrustStore{
		tiers: map[string]string{"provider-a": string(pool.TierTrusted)},
	}))
	s.sessions.Store(sessionKey("provider-a", "session-a"), &providerSession{})

	s.runRewardsTrustTierReconciliationSweep()

	got, ok := registry.Resolve("provider-a", "session-a")
	if !ok {
		t.Fatal("provider disappeared")
	}
	if got.Tier != pool.TierProvisional {
		t.Fatalf("non-bearer reconciled tier = %s, want provisional", got.Tier)
	}
}

func TestRewardsTrustReconciliationDemotesProviderAfterRepeatedLookupFailuresWithMixedSuccess(t *testing.T) {
	registry := pool.NewRegistry(nil)
	for _, id := range []string{"provider-a", "provider-b"} {
		registry.Register(&pool.Provider{
			ProviderID:                       id,
			AssignedID:                       "session-" + id,
			Tier:                             pool.TierTrusted,
			State:                            pool.StateReady,
			AuthState:                        pool.AuthBearerValidated,
			DurableAdmissionIdentityVerified: true,
		}, nil)
	}
	s := NewServer(config.Default(), registry, zerolog.Nop(), WithProviderRewardsTrustTierStore(fakeRewardsTrustStore{
		tiers:  map[string]string{"provider-b": string(pool.TierTrusted)},
		errors: map[string]error{"provider-a": errors.New("lookup failed")},
	}))
	for _, id := range []string{"provider-a", "provider-b"} {
		s.sessions.Store(sessionKey(id, "session-"+id), &providerSession{})
	}

	for i := 0; i < rewardsTrustSweepDegradedThreshold; i++ {
		s.runRewardsTrustTierReconciliationSweep()
	}

	failing, ok := registry.Resolve("provider-a", "session-provider-a")
	if !ok {
		t.Fatal("failing provider disappeared")
	}
	if failing.Tier != pool.TierProvisional {
		t.Fatalf("failing provider tier = %s, want provisional", failing.Tier)
	}
	succeeding, ok := registry.Resolve("provider-b", "session-provider-b")
	if !ok {
		t.Fatal("succeeding provider disappeared")
	}
	if succeeding.Tier != pool.TierTrusted {
		t.Fatalf("succeeding provider tier = %s, want trusted", succeeding.Tier)
	}
}

func TestRewardsTrustReconciliationSweepDeadlineDemotesUnresolvedTrustedProviders(t *testing.T) {
	oldLookupTimeout := rewardsTrustLookupTimeout
	oldSweepDeadline := rewardsTrustSweepDeadline
	rewardsTrustLookupTimeout = 25 * time.Millisecond
	rewardsTrustSweepDeadline = 60 * time.Millisecond
	t.Cleanup(func() {
		rewardsTrustLookupTimeout = oldLookupTimeout
		rewardsTrustSweepDeadline = oldSweepDeadline
	})

	registry := pool.NewRegistry(nil)
	for i := 0; i < 8; i++ {
		id := "provider-" + string(rune('a'+i))
		registry.Register(&pool.Provider{
			ProviderID:                       id,
			AssignedID:                       "session-" + id,
			Tier:                             pool.TierTrusted,
			State:                            pool.StateReady,
			AuthState:                        pool.AuthBearerValidated,
			DurableAdmissionIdentityVerified: true,
		}, nil)
	}
	s := NewServer(config.Default(), registry, zerolog.Nop(), WithProviderRewardsTrustTierStore(blockingRewardsTrustStore{}))
	for i := 0; i < 8; i++ {
		id := "provider-" + string(rune('a'+i))
		s.sessions.Store(sessionKey(id, "session-"+id), &providerSession{})
	}

	start := time.Now()
	s.runRewardsTrustTierReconciliationSweep()
	elapsed := time.Since(start)

	if elapsed > 250*time.Millisecond {
		t.Fatalf("sweep elapsed = %s, want bounded by sweep deadline", elapsed)
	}
	demoted := 0
	for _, provider := range registry.Snapshot() {
		if provider.Tier == pool.TierProvisional {
			demoted++
		}
	}
	if demoted == 0 {
		t.Fatal("stalled sweep deadline did not demote any unresolved trusted providers")
	}
}

func TestHandleDisconnectClearsRewardsTrustLookupFailure(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registry.Register(&pool.Provider{
		ProviderID: "provider-a",
		AssignedID: "session-a",
		Tier:       pool.TierTrusted,
		State:      pool.StateReady,
		AuthState:  pool.AuthBearerValidated,
	}, nil)
	s := NewServer(config.Default(), registry, zerolog.Nop())
	serverConn, clientConn := net.Pipe()
	defer clientConn.Close()
	s.sessions.Store(sessionKey("provider-a", "session-a"), newProviderSession("provider-a", "session-a", serverConn, 1))
	key := sessionKey("provider-a", "session-a")
	s.rewardsTrustSweepFailures.Store(key, 2)

	s.handleDisconnect("provider-a", "session-a")

	if _, ok := s.rewardsTrustSweepFailures.Load(key); ok {
		t.Fatal("rewards trust lookup failure counter survived disconnect")
	}
}

func TestAdmissionManagerPendingReservationsEnforcePoolCap(t *testing.T) {
	now := time.Date(2026, 5, 28, 12, 0, 0, 0, time.UTC)
	adm := NewAdmissionManager(config.AdmissionConfig{
		ProvisionalAdmissionRatePerHour: 100,
		ProvisionalPoolMax:              1,
		ProvisionalQuotaPerHour:         100,
		ProvisionalTierWeight:           0.3,
	}, func() time.Time { return now })

	tier, code, reason := adm.Admit(Hello{ProviderID: "new-1", Hostname: "host", ModelID: "model", BinaryVersion: "1.2.0"}, false, 0)
	if tier != pool.TierProvisional || code != 0 || reason != "" {
		t.Fatalf("first admit = tier:%s code:%d reason:%q", tier, code, reason)
	}
	_, code, reason = adm.Admit(Hello{ProviderID: "new-2", Hostname: "host", ModelID: "model", BinaryVersion: "1.2.0"}, false, 0)
	if code != CloseProvisionalPoolFull {
		t.Fatalf("second admit code=%d reason=%q, want pool full", code, reason)
	}

	adm.ReleasePendingProvisional()
	_, code, reason = adm.Admit(Hello{ProviderID: "new-2", Hostname: "host", ModelID: "model", BinaryVersion: "1.2.0"}, false, 0)
	if code != 0 || reason != "" {
		t.Fatalf("admit after release code=%d reason=%q, want success", code, reason)
	}
}

func TestAdmissionManagerPersistenceSurvivesRestart(t *testing.T) {
	now := time.Date(2026, 5, 28, 12, 0, 0, 0, time.UTC)
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	defer db.Close()
	store, err := NewSQLiteAdmissionStore(db)
	if err != nil {
		t.Fatalf("admission store: %v", err)
	}
	cfg := config.AdmissionConfig{
		ProvisionalAdmissionRatePerHour: 10,
		ProvisionalPoolMax:              10,
		ProvisionalQuotaPerHour:         1,
		ProvisionalTierWeight:           0.3,
	}
	adm := NewAdmissionManager(cfg, func() time.Time { return now })
	adm.SetPersistence(store, func(err error) { t.Fatalf("persist admission: %v", err) })

	hello := Hello{ProviderID: "new-1", Hostname: "host", ModelID: "model", BinaryVersion: "1.2.0"}
	if tier, code, reason := adm.Admit(hello, false, 0); tier != pool.TierProvisional || code != 0 || reason != "" {
		t.Fatalf("admit = tier:%s code:%d reason:%q", tier, code, reason)
	}
	provider := pool.Provider{ProviderID: "new-1", Tier: pool.TierProvisional}
	if !adm.TryReserveRequest(provider) {
		t.Fatal("reservation blocked")
	}
	adm.Reject("blocked-1", "operator")

	restarted := NewAdmissionManager(cfg, func() time.Time { return now })
	restarted.SetPersistence(store, func(err error) { t.Fatalf("load admission: %v", err) })
	if !restarted.Rejected("blocked-1") {
		t.Fatal("rejected provider was not restored")
	}
	if restarted.CheckQuota(provider) {
		t.Fatal("quota window was not restored")
	}
	records := restarted.Records(map[string]bool{"new-1": true})
	if len(records) != 1 || records[0].ProviderID != "new-1" || records[0].TotalRequestsServed != 1 || !records[0].CurrentlyConnected {
		t.Fatalf("records = %+v", records)
	}
	if _, err := store.LoadAdmissionState(context.Background()); err != nil {
		t.Fatalf("reload state: %v", err)
	}
}

func TestAdmissionManagerUnrejectPersistsAcrossRestart(t *testing.T) {
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	defer db.Close()
	store, err := NewSQLiteAdmissionStore(db)
	if err != nil {
		t.Fatalf("admission store: %v", err)
	}
	cfg := config.AdmissionConfig{}
	adm := NewAdmissionManager(cfg, nil)
	adm.SetPersistence(store, func(err error) { t.Fatalf("persist admission: %v", err) })
	adm.Reject("provider-a", "false-positive canary")

	if cleared, err := adm.Unreject("provider-a"); err != nil || !cleared {
		t.Fatal("unreject did not report the persisted rejection")
	}
	if adm.Rejected("provider-a") {
		t.Fatal("provider remained rejected after recovery")
	}
	if cleared, err := adm.Unreject("provider-a"); err != nil || cleared {
		t.Fatal("idempotent unreject reported a second removal")
	}

	restarted := NewAdmissionManager(cfg, nil)
	restarted.SetPersistence(store, func(err error) { t.Fatalf("reload admission: %v", err) })
	if restarted.Rejected("provider-a") {
		t.Fatal("cleared rejection returned after restart")
	}
}

func TestAdmissionManagerUnrejectPersistenceFailureKeepsRejection(t *testing.T) {
	adm := NewAdmissionManager(config.AdmissionConfig{}, nil)
	adm.Reject("provider-a", "operator")
	storeErr := errors.New("sqlite unavailable")
	var reported error
	adm.SetPersistence(failingAdmissionStateStore{err: storeErr}, func(err error) { reported = err })

	cleared, err := adm.Unreject("provider-a")
	if cleared || !errors.Is(err, storeErr) {
		t.Fatalf("unreject = cleared:%v err:%v, want durable failure", cleared, err)
	}
	if !errors.Is(reported, storeErr) {
		t.Fatalf("reported error = %v, want %v", reported, storeErr)
	}
	if !adm.Rejected("provider-a") {
		t.Fatal("failed durable recovery removed in-memory rejection")
	}
}

// TestAdmissionManagerPruneShrinksStateBeyondCutoff pins the M2-5 / XPERF-2
// guarantee: ProvisionalRetentionDays actually takes effect. Without the
// pruner the existing admission state grew without bound — the audit
// flagged the config knob was set to 30 days but referenced nowhere in
// the ws package.
func TestAdmissionManagerPruneShrinksStateBeyondCutoff(t *testing.T) {
	base := time.Date(2026, 5, 28, 12, 0, 0, 0, time.UTC)
	cur := base
	cfg := config.AdmissionConfig{
		ProvisionalAdmissionRatePerHour: 1000,
		ProvisionalPoolMax:              1000,
		ProvisionalQuotaPerHour:         1000,
		ProvisionalTierWeight:           0.3,
		ProvisionalRetentionDays:        30,
	}
	adm := NewAdmissionManager(cfg, func() time.Time { return cur })

	// Three old providers (>30d ago) and one fresh provider (today).
	for _, id := range []string{"old-1", "old-2", "old-3"} {
		if _, _, _ = adm.Admit(Hello{ProviderID: id, ModelID: "m"}, false, 0); false {
		}
	}
	cur = base.AddDate(0, 0, 31)
	if _, _, _ = adm.Admit(Hello{ProviderID: "fresh-1", ModelID: "m"}, false, 0); false {
	}
	adm.Reject("old-1", "operator dropped")
	adm.Reject("fresh-1", "operator")

	// Populate fresh-1's request window so the time-points counter is
	// observable on the survivor. Do NOT reserve on the old records —
	// TryReserveRequest bumps LastSeenAt to the current time, which would
	// keep them alive past the cutoff.
	adm.TryReserveRequest(pool.Provider{ProviderID: "fresh-1", Tier: pool.TierProvisional})

	cutoff := cur.AddDate(0, 0, -cfg.ProvisionalRetentionDays)
	deletedRecords, deletedRejected, _ := adm.Prune(cutoff)
	if deletedRecords != 3 {
		t.Fatalf("deleted records = %d, want 3 (old-1/old-2/old-3)", deletedRecords)
	}
	// old-1 rejection drops because its record dropped; fresh-1 rejection survives.
	if deletedRejected != 1 {
		t.Fatalf("deleted rejected = %d, want 1 (only old-1's; fresh-1 must stay)", deletedRejected)
	}
	records := adm.Records(map[string]bool{"fresh-1": true})
	if len(records) != 1 || records[0].ProviderID != "fresh-1" {
		t.Fatalf("records after prune = %+v, want only fresh-1", records)
	}
	if !adm.Rejected("fresh-1") {
		t.Fatal("fresh rejection lost across prune (operator action must survive while record survives)")
	}
	if adm.Rejected("old-1") {
		t.Fatal("old rejection survived prune (record was dropped, rejection should follow)")
	}
}

type failingAdmissionStateStore struct {
	err error
}

type countingAdmissionStore struct {
	saves int
}

func (c *countingAdmissionStore) LoadAdmissionState(context.Context) (AdmissionState, error) {
	return AdmissionState{}, nil
}

func (c *countingAdmissionStore) SaveAdmissionState(context.Context, AdmissionState) error {
	c.saves++
	return nil
}

type fakeRewardsTrustStore struct {
	tiers  map[string]string
	errors map[string]error
	err    error
}

type blockingRewardsTrustStore struct{}

func (blockingRewardsTrustStore) ProviderTrustTier(ctx context.Context, _ string) (string, error) {
	<-ctx.Done()
	return "", ctx.Err()
}

func (f fakeRewardsTrustStore) ProviderTrustTier(_ context.Context, providerID string) (string, error) {
	if f.err != nil {
		return "", f.err
	}
	if err := f.errors[providerID]; err != nil {
		return "", err
	}
	return f.tiers[providerID], nil
}

func (f failingAdmissionStateStore) LoadAdmissionState(context.Context) (AdmissionState, error) {
	return AdmissionState{}, nil
}

func (f failingAdmissionStateStore) SaveAdmissionState(context.Context, AdmissionState) error {
	return f.err
}

func retainedAuthAttemptForIdentityProof(t *testing.T, initial AuthRequest) AuthAttemptState {
	t.Helper()
	raw, err := json.Marshal(initial)
	if err != nil {
		t.Fatal(err)
	}
	hash, err := initialAuthTranscriptHash(raw)
	if err != nil {
		t.Fatal(err)
	}
	return AuthAttemptState{
		AuthAttemptID:           "attempt-" + initial.ProviderID,
		ProviderID:              initial.ProviderID,
		BinaryVersion:           initial.BinaryVersion,
		ProviderECDHPublicKey:   initial.ProviderECDHPublicKey,
		InitialTranscriptSHA256: hash,
	}
}

func signedIdentityProof(t *testing.T, initial AuthRequest, retained AuthAttemptState, privateKey ed25519.PrivateKey) AuthRequest {
	t.Helper()
	transcript := base64.StdEncoding.EncodeToString(retained.InitialTranscriptSHA256[:])
	tuple := map[string]any{
		"auth_attempt_id":          retained.AuthAttemptID,
		"provider_id":              initial.ProviderID,
		"binary_version":           retained.BinaryVersion,
		"provider_ecdh_public_key": retained.ProviderECDHPublicKey,
		"transcript_sha256":        transcript,
	}
	canonical, err := billing.CanonicalJSON(tuple)
	if err != nil {
		t.Fatal(err)
	}
	signature := ed25519.Sign(privateKey, canonical)
	proof := initial
	proof.AuthAttemptID = retained.AuthAttemptID
	proof.IdentityTranscriptSHA256 = transcript
	proof.IdentitySignature = base64.StdEncoding.EncodeToString(signature)
	return proof
}
