package sqlite

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

func TestWalletSessionMigrationIdempotent(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	if err := store.Migrate(ctx); err != nil {
		t.Fatalf("second Migrate: %v", err)
	}
	for _, table := range []string{
		"wallet_session_challenges",
		"wallet_identities",
		"wallet_sessions",
		"wallet_session_replays",
		"wallet_session_reservations",
		"wallet_session_request_map",
		"relay_blind_replays",
	} {
		var name string
		if err := store.db.QueryRowContext(ctx, `SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?`, table).Scan(&name); err != nil {
			t.Fatalf("missing table %s: %v", table, err)
		}
	}
	for _, version := range []int{10, 11} {
		var applied int
		if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM schema_migrations WHERE version = ?`, version).Scan(&applied); err != nil {
			t.Fatalf("schema version query v%d: %v", version, err)
		}
		if applied != 1 {
			t.Fatalf("schema v%d rows=%d want 1", version, applied)
		}
	}
}

func TestRelayBlindReplayDuplicateWinsOverCapacity(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_relay_blind_replay_precedence")
	now := fixedTime()
	replay := storage.RelayBlindReplayMaterial{
		AccountID:                     "acct_relay_blind_replay_precedence",
		RequestID:                     "req-relay-blind-precedence",
		RequestReplayNonceDigest:      []byte("nonce-digest"),
		BuyerEphemeralPublicKeyDigest: []byte("buyer-key-digest"),
		ProviderBindingDigest:         []byte("provider-binding-digest"),
		KIDDigest:                     []byte("kid-digest"),
		EnvelopeDigest:                []byte("envelope-digest"),
		EnvelopeBytes:                 128,
		RetentionExpiresAt:            now.Add(time.Minute),
		MaxReplayRows:                 1,
		MaxReplayBytes:                1024,
		CreatedAt:                     now,
	}
	if err := store.RecordRelayBlindReplay(ctx, replay); err != nil {
		t.Fatalf("RecordRelayBlindReplay first: %v", err)
	}
	if err := store.RecordRelayBlindReplay(ctx, replay); !errors.Is(err, storage.ErrRelayBlindReplay) {
		t.Fatalf("RecordRelayBlindReplay duplicate err=%v want ErrRelayBlindReplay", err)
	}
	unique := replay
	unique.RequestID = "req-relay-blind-precedence-2"
	unique.RequestReplayNonceDigest = []byte("nonce-digest-2")
	unique.BuyerEphemeralPublicKeyDigest = []byte("buyer-key-digest-2")
	unique.EnvelopeDigest = []byte("envelope-digest-2")
	if err := store.RecordRelayBlindReplay(ctx, unique); !errors.Is(err, storage.ErrRateLimit) {
		t.Fatalf("RecordRelayBlindReplay unique over cap err=%v want ErrRateLimit", err)
	}
}

func TestWalletChallengeConsumptionRaceCreatesOneSession(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_wallet_race")
	nonce := []byte("nonce-race")
	storeWalletChallenge(t, store, "acct_wallet_race", nonce, "wallet-race", 100, 50)

	var created int64
	var consumed int64
	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, err := store.RegisterWalletSession(ctx, storage.WalletSessionRegistrationRequest{
				ChallengeNonceHash:    nonce,
				SessionID:             fmt.Sprintf("ws_race_%d", i),
				AccountID:             "acct_wallet_race",
				WalletNamespace:       "ed25519",
				WalletFingerprint:     "wallet-race",
				Audience:              "macprovider.test",
				RequestedExpiresAt:    fixedTime().Add(time.Hour),
				PerRequestTokenCap:    50,
				TotalTokenCap:         100,
				ModelAllowlistJSON:    `["model-a"]`,
				SessionPublicKey:      []byte("session-public-key"),
				BearerHash:            []byte(fmt.Sprintf("bearer-race-%d", i)),
				BearerKeyID:           "k1",
				VerificationPublicKey: []byte("verify"),
				CreatedAt:             fixedTime(),
				MaxActivePerAccount:   10,
				MaxActivePerWallet:    10,
			})
			if err == nil {
				atomic.AddInt64(&created, 1)
				return
			}
			if errors.Is(err, storage.ErrWalletChallengeConsumed) {
				atomic.AddInt64(&consumed, 1)
				return
			}
			t.Errorf("RegisterWalletSession %d err=%v", i, err)
		}(i)
	}
	wg.Wait()
	if created != 1 || consumed != 1 {
		t.Fatalf("created/consumed=%d/%d want 1/1", created, consumed)
	}
}

func TestWalletActiveSessionCapConcurrentRegistrations(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_wallet_cap")

	var created int64
	var capped int64
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		i := i
		nonce := []byte(fmt.Sprintf("nonce-cap-%d", i))
		storeWalletChallenge(t, store, "acct_wallet_cap", nonce, fmt.Sprintf("wallet-cap-%d", i), 100, 50)
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := store.RegisterWalletSession(ctx, storage.WalletSessionRegistrationRequest{
				ChallengeNonceHash:    nonce,
				SessionID:             fmt.Sprintf("ws_cap_%d", i),
				AccountID:             "acct_wallet_cap",
				WalletNamespace:       "ed25519",
				WalletFingerprint:     fmt.Sprintf("wallet-cap-%d", i),
				Audience:              "macprovider.test",
				RequestedExpiresAt:    fixedTime().Add(time.Hour),
				PerRequestTokenCap:    50,
				TotalTokenCap:         100,
				ModelAllowlistJSON:    `["model-a"]`,
				SessionPublicKey:      []byte("session-public-key"),
				BearerHash:            []byte(fmt.Sprintf("bearer-cap-%d", i)),
				BearerKeyID:           "k1",
				VerificationPublicKey: []byte("verify"),
				CreatedAt:             fixedTime(),
				MaxActivePerAccount:   3,
				MaxActivePerWallet:    3,
			})
			if err == nil {
				atomic.AddInt64(&created, 1)
				return
			}
			if errors.Is(err, storage.ErrWalletSessionActiveCap) {
				atomic.AddInt64(&capped, 1)
				return
			}
			t.Errorf("RegisterWalletSession %d err=%v", i, err)
		}()
	}
	wg.Wait()
	if created != 3 || capped != 5 {
		t.Fatalf("created/capped=%d/%d want 3/5", created, capped)
	}
}

func TestWalletRegistrationRejectsChallengeProofDrift(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_wallet_drift")
	nonce := []byte("nonce-drift")
	storeWalletChallenge(t, store, "acct_wallet_drift", nonce, "wallet-drift", 100, 50)
	_, err := store.RegisterWalletSession(ctx, storage.WalletSessionRegistrationRequest{
		ChallengeNonceHash:    nonce,
		SessionID:             "ws_drift",
		AccountID:             "acct_wallet_drift",
		WalletNamespace:       "ed25519",
		WalletFingerprint:     "wallet-drift",
		Audience:              "macprovider.test",
		RequestedExpiresAt:    fixedTime().Add(time.Hour),
		PerRequestTokenCap:    51,
		TotalTokenCap:         100,
		ModelAllowlistJSON:    `["model-a"]`,
		SessionPublicKey:      []byte("session-public-key"),
		BearerHash:            []byte("bearer-drift"),
		BearerKeyID:           "k1",
		VerificationPublicKey: []byte("verify"),
		CreatedAt:             fixedTime(),
		MaxActivePerAccount:   10,
		MaxActivePerWallet:    10,
	})
	if !errors.Is(err, storage.ErrWalletChallengeMismatch) {
		t.Fatalf("RegisterWalletSession err=%v want ErrWalletChallengeMismatch", err)
	}
}

func TestWalletRegistrationRejectsAlreadyExpiredSessionProof(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_wallet_expired_proof")
	nonce := []byte("nonce-expired-proof")
	if err := store.StoreWalletSessionChallenge(ctx, storage.WalletSessionChallenge{
		NonceHash:          nonce,
		AccountID:          "acct_wallet_expired_proof",
		WalletNamespace:    "ed25519",
		WalletFingerprint:  "wallet-expired-proof",
		Purpose:            "wallet-session-registration-v1",
		Audience:           "macprovider.test",
		RequestedExpiresAt: fixedTime().Add(time.Minute),
		PerRequestTokenCap: 50,
		TotalTokenCap:      100,
		ModelAllowlistJSON: `["model-a"]`,
		SessionPublicKey:   []byte("session-public-key"),
		CreatedAt:          fixedTime(),
		ExpiresAt:          fixedTime().Add(5 * time.Minute),
	}); err != nil {
		t.Fatalf("StoreWalletSessionChallenge: %v", err)
	}
	_, err := store.RegisterWalletSession(ctx, storage.WalletSessionRegistrationRequest{
		ChallengeNonceHash:    nonce,
		SessionID:             "ws_expired_proof",
		AccountID:             "acct_wallet_expired_proof",
		WalletNamespace:       "ed25519",
		WalletFingerprint:     "wallet-expired-proof",
		Audience:              "macprovider.test",
		RequestedExpiresAt:    fixedTime().Add(time.Minute),
		PerRequestTokenCap:    50,
		TotalTokenCap:         100,
		ModelAllowlistJSON:    `["model-a"]`,
		SessionPublicKey:      []byte("session-public-key"),
		BearerHash:            []byte("bearer-expired-proof"),
		BearerKeyID:           "k1",
		VerificationPublicKey: []byte("verify"),
		CreatedAt:             fixedTime().Add(2 * time.Minute),
		MaxActivePerAccount:   10,
		MaxActivePerWallet:    10,
	})
	if !errors.Is(err, storage.ErrWalletChallengeExpired) {
		t.Fatalf("RegisterWalletSession err=%v want ErrWalletChallengeExpired", err)
	}
	if _, err := store.GetWalletSession(ctx, "acct_wallet_expired_proof", "ws_expired_proof"); !errors.Is(err, storage.ErrNotFound) {
		t.Fatalf("GetWalletSession err=%v want ErrNotFound", err)
	}
}

func TestWalletReplayDuplicateAndMismatchDoNotReserveAgain(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createWalletSession(t, store, "acct_wallet_replay", "ws_replay", 100, 50)

	req := walletAdmission("acct_wallet_replay", "ws_replay", "req_replay", 20)
	if _, err := store.AdmitWalletSessionInference(ctx, req); err != nil {
		t.Fatalf("AdmitWalletSessionInference: %v", err)
	}
	if _, err := store.AdmitWalletSessionInference(ctx, req); !errors.Is(err, storage.ErrWalletSessionReplayDuplicate) {
		t.Fatalf("duplicate err=%v want ErrWalletSessionReplayDuplicate", err)
	}
	req.Replay.RawBodyHash = []byte("different-body")
	if _, err := store.AdmitWalletSessionInference(ctx, req); !errors.Is(err, storage.ErrWalletSessionReplayMismatch) {
		t.Fatalf("mismatch err=%v want ErrWalletSessionReplayMismatch", err)
	}
	_, reserved, err := store.DailyUsage(ctx, "acct_wallet_replay", "2026-05-29")
	if err != nil {
		t.Fatalf("DailyUsage: %v", err)
	}
	if reserved != 20 {
		t.Fatalf("reserved=%d want one 20-token reservation", reserved)
	}
}

func TestWalletMetadataRateLimitAndReplayCeiling(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createWalletSession(t, store, "acct_wallet_meta", "ws_meta", 1000, 100)

	for i := 0; i < 2; i++ {
		err := store.AdmitWalletSessionMetadata(ctx, storage.WalletSessionMetadataAdmissionRequest{
			SessionID:      "ws_meta",
			AccountID:      "acct_wallet_meta",
			Replay:         walletReplay("ws_meta", fmt.Sprintf("req_meta_%d", i), "GET", "/v1/models", []byte("empty"), 10, "1.2.3.4"),
			WindowStart:    fixedTime().Add(-time.Minute),
			RateLimit:      2,
			MaxReplayRows:  10,
			MaxReplayBytes: 1000,
			CreatedAt:      fixedTime().Add(time.Duration(i) * time.Second),
		})
		if err != nil {
			t.Fatalf("metadata admit %d: %v", i, err)
		}
	}
	err := store.AdmitWalletSessionMetadata(ctx, storage.WalletSessionMetadataAdmissionRequest{
		SessionID:      "ws_meta",
		AccountID:      "acct_wallet_meta",
		Replay:         walletReplay("ws_meta", "req_meta_rate", "GET", "/v1/models", []byte("empty"), 10, "1.2.3.4"),
		WindowStart:    fixedTime().Add(-time.Minute),
		RateLimit:      2,
		MaxReplayRows:  10,
		MaxReplayBytes: 1000,
		CreatedAt:      fixedTime().Add(3 * time.Second),
	})
	if !errors.Is(err, storage.ErrRateLimit) {
		t.Fatalf("rate limit err=%v want ErrRateLimit", err)
	}
	err = store.AdmitWalletSessionMetadata(ctx, storage.WalletSessionMetadataAdmissionRequest{
		SessionID:      "ws_meta",
		AccountID:      "acct_wallet_meta",
		Replay:         walletReplay("ws_meta", "req_meta_capacity", "GET", "/v1/models", []byte("empty"), 10, "5.6.7.8"),
		WindowStart:    fixedTime().Add(-time.Minute),
		RateLimit:      10,
		MaxReplayRows:  2,
		MaxReplayBytes: 1000,
		CreatedAt:      fixedTime().Add(4 * time.Second),
	})
	if !errors.Is(err, storage.ErrWalletSessionReplayCapacity) {
		t.Fatalf("capacity err=%v want ErrWalletSessionReplayCapacity", err)
	}
	err = store.AdmitWalletSessionMetadata(ctx, storage.WalletSessionMetadataAdmissionRequest{
		SessionID:      "ws_meta",
		AccountID:      "acct_wallet_meta",
		Replay:         walletReplay("ws_meta", "req_meta_0", "GET", "/v1/models", []byte("empty"), 10, "1.2.3.4"),
		WindowStart:    fixedTime().Add(-time.Minute),
		RateLimit:      1,
		MaxReplayRows:  2,
		MaxReplayBytes: 1000,
		CreatedAt:      fixedTime().Add(5 * time.Second),
	})
	if !errors.Is(err, storage.ErrWalletSessionReplayDuplicate) {
		t.Fatalf("duplicate after capacity/rate err=%v want ErrWalletSessionReplayDuplicate", err)
	}
	err = store.AdmitWalletSessionMetadata(ctx, storage.WalletSessionMetadataAdmissionRequest{
		SessionID:      "ws_meta",
		AccountID:      "acct_wallet_meta",
		Replay:         walletReplay("ws_meta", "req_meta_0", "GET", "/v1/models", []byte("different"), 10, "1.2.3.4"),
		WindowStart:    fixedTime().Add(-time.Minute),
		RateLimit:      1,
		MaxReplayRows:  2,
		MaxReplayBytes: 1000,
		CreatedAt:      fixedTime().Add(6 * time.Second),
	})
	if !errors.Is(err, storage.ErrWalletSessionReplayMismatch) {
		t.Fatalf("mismatch after capacity/rate err=%v want ErrWalletSessionReplayMismatch", err)
	}
}

func TestWalletDispatchFenceRejectsClaimedAfterRevocation(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createWalletSession(t, store, "acct_wallet_revoke", "ws_revoke", 100, 50)
	if _, err := store.AdmitWalletSessionInference(ctx, walletAdmission("acct_wallet_revoke", "ws_revoke", "req_revoke", 20)); err != nil {
		t.Fatalf("AdmitWalletSessionInference: %v", err)
	}
	if err := store.RevokeWalletSession(ctx, "acct_wallet_revoke", "ws_revoke", "account", "test", fixedTime().Add(time.Second)); err != nil {
		t.Fatalf("RevokeWalletSession: %v", err)
	}
	err := store.ArmWalletSessionDispatch(ctx, storage.WalletSessionDispatchArm{
		AccountID: "acct_wallet_revoke", SessionID: "ws_revoke", RequestID: "req_revoke",
		CanonicalRoute: "/v1/chat/completions", ArmedAt: fixedTime().Add(2 * time.Second),
	})
	if !errors.Is(err, storage.ErrWalletSessionInactive) {
		t.Fatalf("arm after revoke err=%v want ErrWalletSessionInactive", err)
	}
	_, reserved, err := store.DailyUsage(ctx, "acct_wallet_revoke", "2026-05-29")
	if err != nil {
		t.Fatalf("DailyUsage: %v", err)
	}
	if reserved != 0 {
		t.Fatalf("reserved after revoke refund=%d want 0", reserved)
	}
}

func TestWalletStaleDispatchArmsMoveToHeld(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createWalletSession(t, store, "acct_wallet_stale_dispatch", "ws_stale_dispatch", 100, 50)
	if _, err := store.AdmitWalletSessionInference(ctx, walletAdmission("acct_wallet_stale_dispatch", "ws_stale_dispatch", "req_stale_dispatch", 20)); err != nil {
		t.Fatalf("AdmitWalletSessionInference: %v", err)
	}
	if err := store.ArmWalletSessionDispatch(ctx, storage.WalletSessionDispatchArm{
		AccountID: "acct_wallet_stale_dispatch", SessionID: "ws_stale_dispatch", RequestID: "req_stale_dispatch",
		CanonicalRoute: "/v1/chat/completions", ArmedAt: fixedTime(),
	}); err != nil {
		t.Fatalf("ArmWalletSessionDispatch: %v", err)
	}
	if err := store.MarkWalletSessionDispatched(ctx, "ws_stale_dispatch", "req_stale_dispatch", fixedTime().Add(time.Second)); err != nil {
		t.Fatalf("MarkWalletSessionDispatched: %v", err)
	}
	var armedAt, dispatchedAt, recoveryPolicy, intendedEffect string
	var replayReserved int64
	if err := store.db.QueryRowContext(ctx, `
		SELECT dispatch_armed_at, dispatched_at, recovery_policy, intended_effect, reserved_tokens
		FROM wallet_session_replays
		WHERE session_id = ? AND request_id = ?`,
		"ws_stale_dispatch", "req_stale_dispatch").Scan(&armedAt, &dispatchedAt, &recoveryPolicy, &intendedEffect, &replayReserved); err != nil {
		t.Fatalf("dispatch metadata query: %v", err)
	}
	if armedAt == "" || dispatchedAt == "" || recoveryPolicy != "hold_until_settlement_finality" ||
		intendedEffect != "wallet_session_inference" || replayReserved != 20 {
		t.Fatalf("dispatch metadata armed=%q dispatched=%q policy=%q effect=%q reserved=%d",
			armedAt, dispatchedAt, recoveryPolicy, intendedEffect, replayReserved)
	}
	held, err := store.HoldStaleWalletSessionDispatchArms(ctx, fixedTime().Add(2*time.Second), fixedTime().Add(3*time.Second))
	if err != nil {
		t.Fatalf("HoldStaleWalletSessionDispatchArms: %v", err)
	}
	if held != 1 {
		t.Fatalf("held=%d want 1", held)
	}
	usage, err := store.WalletSessionUsage(ctx, "acct_wallet_stale_dispatch", "ws_stale_dispatch")
	if err != nil {
		t.Fatalf("WalletSessionUsage: %v", err)
	}
	if usage.HeldTokens != 20 || usage.ReservedTokens != 0 || usage.RemainingTokens != 80 {
		t.Fatalf("usage=%+v want held=20 remaining=80", usage)
	}
}

func TestWalletReaperDoesNotSplitExpiredDispatchedReservations(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createWalletSession(t, store, "acct_wallet_expired_dispatch", "ws_expired_dispatch", 100, 50)
	req := walletAdmission("acct_wallet_expired_dispatch", "ws_expired_dispatch", "req_expired_dispatch", 20)
	req.ExpiresAt = fixedTime().Add(time.Second)
	if _, err := store.AdmitWalletSessionInference(ctx, req); err != nil {
		t.Fatalf("AdmitWalletSessionInference: %v", err)
	}
	if err := store.ArmWalletSessionDispatch(ctx, storage.WalletSessionDispatchArm{
		AccountID:      "acct_wallet_expired_dispatch",
		SessionID:      "ws_expired_dispatch",
		RequestID:      "req_expired_dispatch",
		CanonicalRoute: "/v1/chat/completions",
		ArmedAt:        fixedTime().Add(500 * time.Millisecond),
	}); err != nil {
		t.Fatalf("ArmWalletSessionDispatch: %v", err)
	}
	if err := store.MarkWalletSessionDispatched(ctx, "ws_expired_dispatch", "req_expired_dispatch", fixedTime().Add(time.Second)); err != nil {
		t.Fatalf("MarkWalletSessionDispatched: %v", err)
	}
	reaped, err := store.ReapExpiredReservations(ctx, fixedTime().Add(2*time.Second))
	if err != nil {
		t.Fatalf("ReapExpiredReservations: %v", err)
	}
	if reaped != 0 {
		t.Fatalf("generic reaped=%d want 0 for dispatched wallet reservation", reaped)
	}
	held, err := store.HoldStaleWalletSessionDispatchArms(ctx, fixedTime().Add(3*time.Second), fixedTime().Add(4*time.Second))
	if err != nil {
		t.Fatalf("HoldStaleWalletSessionDispatchArms: %v", err)
	}
	if held != 1 {
		t.Fatalf("held=%d want 1", held)
	}
	var quotaStatus, replayState, walletStatus string
	var settlementHold int
	if err := store.db.QueryRowContext(ctx, `
		SELECT qr.status, qr.settlement_hold, r.state, sr.status
		FROM quota_reservations qr
		JOIN wallet_session_replays r ON r.request_id = qr.request_id
		JOIN wallet_session_reservations sr ON sr.account_id = qr.account_id AND sr.request_id = qr.request_id
		WHERE qr.account_id = ? AND qr.request_id = ?`,
		"acct_wallet_expired_dispatch", "req_expired_dispatch").Scan(&quotaStatus, &settlementHold, &replayState, &walletStatus); err != nil {
		t.Fatalf("reservation status query: %v", err)
	}
	if quotaStatus != "active" || settlementHold != 1 || replayState != "held" || walletStatus != "held" {
		t.Fatalf("quota/hold/replay/wallet=%s/%d/%s/%s want active/1/held/held", quotaStatus, settlementHold, replayState, walletStatus)
	}
}

func TestWalletStaleClaimsRefundPreDispatchReservations(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createWalletSession(t, store, "acct_wallet_stale_claim", "ws_stale_claim", 100, 50)
	if _, err := store.AdmitWalletSessionInference(ctx, walletAdmission("acct_wallet_stale_claim", "ws_stale_claim", "req_stale_claim", 20)); err != nil {
		t.Fatalf("AdmitWalletSessionInference: %v", err)
	}
	refunded, err := store.RefundStaleWalletSessionClaims(ctx, fixedTime().Add(time.Second), fixedTime().Add(2*time.Second))
	if err != nil {
		t.Fatalf("RefundStaleWalletSessionClaims: %v", err)
	}
	if refunded != 1 {
		t.Fatalf("refunded=%d want 1", refunded)
	}
	usage, err := store.WalletSessionUsage(ctx, "acct_wallet_stale_claim", "ws_stale_claim")
	if err != nil {
		t.Fatalf("WalletSessionUsage: %v", err)
	}
	if usage.SettledTokens != 0 || usage.ReservedTokens != 0 || usage.RemainingTokens != 100 {
		t.Fatalf("usage=%+v want no exposure", usage)
	}
	_, reserved, err := store.DailyUsage(ctx, "acct_wallet_stale_claim", "2026-05-29")
	if err != nil {
		t.Fatalf("DailyUsage: %v", err)
	}
	if reserved != 0 {
		t.Fatalf("reserved=%d want 0", reserved)
	}
	var replayState string
	if err := store.db.QueryRowContext(ctx, `SELECT state FROM wallet_session_replays WHERE session_id = ? AND request_id = ?`,
		"ws_stale_claim", "req_stale_claim").Scan(&replayState); err != nil {
		t.Fatalf("replay state query: %v", err)
	}
	if replayState != "refunded" {
		t.Fatalf("replay state=%q want refunded", replayState)
	}
}

func TestWalletReaperRefundsExpiredPreDispatchClaims(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createWalletSession(t, store, "acct_wallet_expired_claim", "ws_expired_claim", 100, 50)
	req := walletAdmission("acct_wallet_expired_claim", "ws_expired_claim", "req_expired_claim", 20)
	req.ExpiresAt = fixedTime().Add(time.Second)
	if _, err := store.AdmitWalletSessionInference(ctx, req); err != nil {
		t.Fatalf("AdmitWalletSessionInference: %v", err)
	}
	reaped, err := store.ReapExpiredReservations(ctx, fixedTime().Add(2*time.Second))
	if err != nil {
		t.Fatalf("ReapExpiredReservations: %v", err)
	}
	if reaped != 0 {
		t.Fatalf("generic reaped=%d want 0 after wallet claim refund", reaped)
	}
	usage, err := store.WalletSessionUsage(ctx, "acct_wallet_expired_claim", "ws_expired_claim")
	if err != nil {
		t.Fatalf("WalletSessionUsage: %v", err)
	}
	if usage.ReservedTokens != 0 || usage.RemainingTokens != 100 {
		t.Fatalf("usage=%+v want no exposure", usage)
	}
	var quotaStatus, replayState string
	if err := store.db.QueryRowContext(ctx, `
		SELECT qr.status, r.state
		FROM quota_reservations qr
		JOIN wallet_session_replays r ON r.request_id = qr.request_id
		WHERE qr.account_id = ? AND qr.request_id = ?`,
		"acct_wallet_expired_claim", "req_expired_claim").Scan(&quotaStatus, &replayState); err != nil {
		t.Fatalf("reservation status query: %v", err)
	}
	if quotaStatus != "refunded" || replayState != "refunded" {
		t.Fatalf("quota/replay status=%s/%s want refunded/refunded", quotaStatus, replayState)
	}
}

func TestWalletSettlementHeldReservationsCarrySessionID(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createWalletSession(t, store, "acct_wallet_held_list", "ws_held_list", 1000, 200)
	if _, err := store.AdmitWalletSessionInference(ctx, walletAdmission("acct_wallet_held_list", "ws_held_list", "req_held_list", 40)); err != nil {
		t.Fatalf("AdmitWalletSessionInference: %v", err)
	}
	if err := store.HoldWalletSessionReservation(ctx, "acct_wallet_held_list", "ws_held_list", "req_held_list", fixedTime().Add(time.Minute)); err != nil {
		t.Fatalf("HoldWalletSessionReservation: %v", err)
	}
	held, err := store.ListSettlementHeldReservations(ctx, 10)
	if err != nil {
		t.Fatalf("ListSettlementHeldReservations: %v", err)
	}
	if len(held) != 1 || held[0].WalletSessionID != "ws_held_list" || held[0].RequestID != "req_held_list" {
		t.Fatalf("held=%+v want wallet session id carried", held)
	}
}

func TestWalletSessionCapConcurrencyAndRefundPrimitive(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createWalletSession(t, store, "acct_wallet_concurrent", "ws_concurrent", 100, 50)

	var admitted int64
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, err := store.AdmitWalletSessionInference(ctx, walletAdmission("acct_wallet_concurrent", "ws_concurrent", fmt.Sprintf("req_cap_%d", i), 20))
			if err == nil {
				atomic.AddInt64(&admitted, 1)
				return
			}
			if !errors.Is(err, storage.ErrWalletSessionCapExceeded) {
				t.Errorf("admit %d err=%v", i, err)
			}
		}(i)
	}
	wg.Wait()
	if admitted != 5 {
		t.Fatalf("admitted=%d want 5", admitted)
	}
	var refundRequestID string
	if err := store.db.QueryRowContext(ctx, `
		SELECT request_id FROM wallet_session_reservations
		WHERE session_id = 'ws_concurrent' AND status = 'active'
		ORDER BY request_id
		LIMIT 1`).Scan(&refundRequestID); err != nil {
		t.Fatalf("select active wallet reservation: %v", err)
	}
	if err := store.RefundWalletSessionReservation(ctx, "acct_wallet_concurrent", "ws_concurrent", refundRequestID, fixedTime().Add(time.Minute)); err != nil {
		t.Fatalf("RefundWalletSessionReservation: %v", err)
	}
	decision, err := store.AdmitWalletSessionInference(ctx, walletAdmission("acct_wallet_concurrent", "ws_concurrent", "req_after_refund", 20))
	if err != nil {
		t.Fatalf("admit after refund: %v", err)
	}
	if !decision.Admitted {
		t.Fatalf("decision after refund=%+v", decision)
	}
	_, reserved, err := store.DailyUsage(ctx, "acct_wallet_concurrent", "2026-05-29")
	if err != nil {
		t.Fatalf("DailyUsage: %v", err)
	}
	if reserved != 100 {
		t.Fatalf("reserved after refund/re-admit=%d want 100", reserved)
	}
}

func TestWalletReservationFinalizeHoldQuarantineAndStaleHeldTransitions(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createWalletSession(t, store, "acct_wallet_transitions", "ws_transitions", 1000, 100)
	for _, requestID := range []string{"req_finalize", "req_hold", "req_quarantine", "req_stale"} {
		if _, err := store.AdmitWalletSessionInference(ctx, walletAdmission("acct_wallet_transitions", "ws_transitions", requestID, 20)); err != nil {
			t.Fatalf("admit %s: %v", requestID, err)
		}
	}
	if err := store.FinalizeWalletSessionReservation(ctx, storage.WalletSessionReservationSettlement{
		AccountID: "acct_wallet_transitions", SessionID: "ws_transitions", RequestID: "req_finalize",
		PromptTokens: 7, CompletionTokens: 8, TokenSource: "provider_reported", Outcome: "ok",
		SettledAt: fixedTime().Add(time.Minute),
	}); err != nil {
		t.Fatalf("FinalizeWalletSessionReservation: %v", err)
	}
	if err := store.HoldWalletSessionReservation(ctx, "acct_wallet_transitions", "ws_transitions", "req_hold", fixedTime().Add(2*time.Minute)); err != nil {
		t.Fatalf("HoldWalletSessionReservation: %v", err)
	}
	if err := store.QuarantineWalletSessionReservation(ctx, "acct_wallet_transitions", "ws_transitions", "req_quarantine", fixedTime().Add(3*time.Minute)); err != nil {
		t.Fatalf("QuarantineWalletSessionReservation: %v", err)
	}
	if err := store.MarkWalletSessionReservationStaleHeld(ctx, "acct_wallet_transitions", "ws_transitions", "req_stale", fixedTime().Add(4*time.Minute)); err != nil {
		t.Fatalf("MarkWalletSessionReservationStaleHeld: %v", err)
	}
	want := map[string]string{
		"req_finalize":   "settled",
		"req_hold":       "held",
		"req_quarantine": "quarantined",
		"req_stale":      "stale_held",
	}
	rows, err := store.db.QueryContext(ctx, `
		SELECT request_id, status FROM wallet_session_reservations
		WHERE session_id = 'ws_transitions'`)
	if err != nil {
		t.Fatalf("query wallet reservations: %v", err)
	}
	defer rows.Close()
	for rows.Next() {
		var requestID, status string
		if err := rows.Scan(&requestID, &status); err != nil {
			t.Fatalf("scan wallet reservation: %v", err)
		}
		if want[requestID] != status {
			t.Fatalf("%s status=%s want %s", requestID, status, want[requestID])
		}
		delete(want, requestID)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("wallet reservation rows: %v", err)
	}
	if len(want) != 0 {
		t.Fatalf("missing reservation statuses: %+v", want)
	}
	used, reserved, err := store.DailyUsage(ctx, "acct_wallet_transitions", "2026-05-29")
	if err != nil {
		t.Fatalf("DailyUsage: %v", err)
	}
	if used != 15 || reserved != 40 {
		t.Fatalf("usage after transitions used/reserved=%d/%d want 15/40", used, reserved)
	}
}

func TestSealWalletSessionUsageEventConsumesSessionAndReleasesAccountHold(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createWalletSession(t, store, "acct_wallet_fallback", "ws_fallback", 1000, 100)
	if _, err := store.AdmitWalletSessionInference(ctx, walletAdmission("acct_wallet_fallback", "ws_fallback", "req_fallback", 20)); err != nil {
		t.Fatalf("AdmitWalletSessionInference: %v", err)
	}
	if err := store.EnsureUsageEvent(ctx, storage.UsageEvent{
		AccountID:        "acct_wallet_fallback",
		RequestID:        "req_fallback",
		WindowDate:       "2026-05-29",
		PromptTokens:     8,
		CompletionTokens: 9,
		TokenSource:      "gateway_estimated",
		Outcome:          "ok",
		CreatedAt:        fixedTime().Add(time.Minute),
	}); err != nil {
		t.Fatalf("EnsureUsageEvent: %v", err)
	}
	if err := store.SealWalletSessionUsageEvent(ctx, "acct_wallet_fallback", "ws_fallback", "req_fallback", 17, fixedTime().Add(2*time.Minute)); err != nil {
		t.Fatalf("SealWalletSessionUsageEvent: %v", err)
	}
	used, reserved, err := store.DailyUsage(ctx, "acct_wallet_fallback", "2026-05-29")
	if err != nil {
		t.Fatalf("DailyUsage: %v", err)
	}
	if used != 17 || reserved != 0 {
		t.Fatalf("account usage used/reserved=%d/%d want 17/0", used, reserved)
	}
	usage, err := store.WalletSessionUsage(ctx, "acct_wallet_fallback", "ws_fallback")
	if err != nil {
		t.Fatalf("WalletSessionUsage: %v", err)
	}
	if usage.SettledTokens != 17 || usage.ReservedTokens != 0 || usage.RemainingTokens != 983 {
		t.Fatalf("wallet usage=%+v want settled=17 reserved=0 remaining=983", usage)
	}
	var quotaStatus string
	var quotaSettled int64
	if err := store.db.QueryRowContext(ctx, `
		SELECT status, settled_tokens
		FROM quota_reservations
		WHERE account_id = ? AND request_id = ?`,
		"acct_wallet_fallback", "req_fallback").Scan(&quotaStatus, &quotaSettled); err != nil {
		t.Fatalf("quota reservation query: %v", err)
	}
	if quotaStatus != "settled" || quotaSettled != 17 {
		t.Fatalf("quota reservation status/tokens=%s/%d want settled/17", quotaStatus, quotaSettled)
	}
}

func TestWalletSessionUsageDetailsIncludeRequestRows(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createWalletSession(t, store, "acct_wallet_detail", "ws_detail", 1000, 200)
	if _, err := store.AdmitWalletSessionInference(ctx, walletAdmission("acct_wallet_detail", "ws_detail", "req_detail", 40)); err != nil {
		t.Fatalf("AdmitWalletSessionInference: %v", err)
	}
	if err := store.FinalizeWalletSessionReservation(ctx, storage.WalletSessionReservationSettlement{
		AccountID:        "acct_wallet_detail",
		SessionID:        "ws_detail",
		RequestID:        "req_detail",
		PromptTokens:     11,
		CompletionTokens: 13,
		TotalTokens:      24,
		MaxTotalTokens:   40,
		TokenSource:      "provider_reported",
		Outcome:          "ok",
		SettledAt:        fixedTime().Add(time.Minute),
	}); err != nil {
		t.Fatalf("FinalizeWalletSessionReservation: %v", err)
	}
	details, next, err := store.ListWalletSessionUsageDetails(ctx, "acct_wallet_detail", "ws_detail", 100, "", fixedTime().Add(-time.Hour), fixedTime().Add(time.Hour))
	if err != nil {
		t.Fatalf("ListWalletSessionUsageDetails: %v", err)
	}
	if next != "" || len(details) != 1 {
		t.Fatalf("details=%+v next=%q want one row no cursor", details, next)
	}
	row := details[0]
	if row.RequestID != "req_detail" || row.ModelID != "model-a" || row.UsageEventID == "" ||
		row.QuotaReservationID == "" || row.SessionReservationID == "" ||
		row.PromptTokens != 11 || row.CompletionTokens != 13 || row.TotalTokens != 24 ||
		row.TerminalStatus != "settled" || row.ReconciliationStatus != "matched" {
		t.Fatalf("detail row=%+v", row)
	}
}

func storeWalletChallenge(t *testing.T, store *Store, accountID string, nonce []byte, walletFingerprint string, totalCap, perRequestCap int64) {
	t.Helper()
	if err := store.StoreWalletSessionChallenge(context.Background(), storage.WalletSessionChallenge{
		NonceHash:          nonce,
		AccountID:          accountID,
		WalletNamespace:    "ed25519",
		WalletFingerprint:  walletFingerprint,
		Purpose:            "wallet-session-registration-v1",
		Audience:           "macprovider.test",
		RequestedExpiresAt: fixedTime().Add(time.Hour),
		PerRequestTokenCap: perRequestCap,
		TotalTokenCap:      totalCap,
		ModelAllowlistJSON: `["model-a"]`,
		SessionPublicKey:   []byte("session-public-key"),
		CreatedAt:          fixedTime(),
		ExpiresAt:          fixedTime().Add(5 * time.Minute),
	}); err != nil {
		t.Fatalf("StoreWalletSessionChallenge: %v", err)
	}
}

func createWalletSession(t *testing.T, store *Store, accountID, sessionID string, totalCap, perRequestCap int64) {
	t.Helper()
	createAccount(t, store, accountID)
	nonce := []byte("nonce-" + sessionID)
	storeWalletChallenge(t, store, accountID, nonce, "wallet-"+sessionID, totalCap, perRequestCap)
	if _, err := store.RegisterWalletSession(context.Background(), storage.WalletSessionRegistrationRequest{
		ChallengeNonceHash:    nonce,
		SessionID:             sessionID,
		AccountID:             accountID,
		WalletNamespace:       "ed25519",
		WalletFingerprint:     "wallet-" + sessionID,
		Audience:              "macprovider.test",
		RequestedExpiresAt:    fixedTime().Add(time.Hour),
		PerRequestTokenCap:    perRequestCap,
		TotalTokenCap:         totalCap,
		ModelAllowlistJSON:    `["model-a"]`,
		SessionPublicKey:      []byte("session-public-key"),
		BearerHash:            []byte("bearer-" + sessionID),
		BearerKeyID:           "k1",
		VerificationPublicKey: []byte("verify-" + sessionID),
		CreatedAt:             fixedTime(),
		MaxActivePerAccount:   10,
		MaxActivePerWallet:    10,
	}); err != nil {
		t.Fatalf("RegisterWalletSession: %v", err)
	}
}

func walletAdmission(accountID, sessionID, requestID string, tokens int64) storage.WalletSessionAdmissionRequest {
	return storage.WalletSessionAdmissionRequest{
		SessionID:       sessionID,
		AccountID:       accountID,
		RequestID:       requestID,
		Method:          "POST",
		CanonicalRoute:  "/v1/chat/completions",
		ModelID:         "model-a",
		WindowDate:      "2026-05-29",
		RequestedTokens: tokens,
		DailyQuota:      1000000,
		Replay:          walletReplay(sessionID, requestID, "POST", "/v1/chat/completions", []byte("body"), 128, ""),
		CreatedAt:       fixedTime(),
		ExpiresAt:       fixedTime().Add(time.Hour),
	}
}

func walletReplay(sessionID, requestID, method, route string, bodyHash []byte, bodyBytes int64, clientIP string) storage.WalletSessionReplayMaterial {
	return storage.WalletSessionReplayMaterial{
		SessionID:           sessionID,
		RequestID:           requestID,
		Method:              method,
		CanonicalRoute:      route,
		SemanticHeadersHash: []byte("headers"),
		RawBodyHash:         bodyHash,
		BodyBytes:           bodyBytes,
		MetadataClientIP:    clientIP,
	}
}
