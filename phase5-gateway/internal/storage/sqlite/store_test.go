package sqlite

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"math"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

func TestMigrateAndAuthCRUD(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)

	account := storage.Account{
		AccountID: "acct_1", Status: "active", QuotaClass: "default", ConcurrencyClass: "default", CreatedAt: fixedTime(),
	}
	if err := store.CreateAccount(ctx, account); err != nil {
		t.Fatalf("CreateAccount: %v", err)
	}
	if err := store.AddAccountIdentity(ctx, storage.AccountIdentity{
		AccountID: "acct_1", Provider: "github", ProviderUserID: "42", Email: "dev@example.test", CreatedAt: fixedTime(),
	}); err != nil {
		t.Fatalf("AddAccountIdentity: %v", err)
	}
	gotAccount, err := store.LookupAccountByIdentity(ctx, "github", "42")
	if err != nil {
		t.Fatalf("LookupAccountByIdentity: %v", err)
	}
	if gotAccount.AccountID != "acct_1" || gotAccount.Status != "active" {
		t.Fatalf("account = %+v", gotAccount)
	}

	hash := keyHash("secret-key")
	if err := store.CreateAPIKey(ctx, storage.APIKey{
		KeyID: "key_1", AccountID: "acct_1", KeyHash: hash[:], KeyHashPrefix: "mp_abcd", Status: "active", CreatedAt: fixedTime(),
	}); err != nil {
		t.Fatalf("CreateAPIKey: %v", err)
	}
	validation, err := store.ValidateAPIKeyHash(ctx, hash[:])
	if err != nil {
		t.Fatalf("ValidateAPIKeyHash: %v", err)
	}
	if !validation.Active || validation.AccountID != "acct_1" || validation.KeyHashPrefix != "mp_abcd" {
		t.Fatalf("validation = %+v", validation)
	}
	missing := keyHash("missing")
	if _, err := store.ValidateAPIKeyHash(ctx, missing[:]); !errors.Is(err, storage.ErrNotFound) {
		t.Fatalf("missing key err = %v, want ErrNotFound", err)
	}

	if err := store.RevokeAPIKey(ctx, "key_1", "operator", "req_revoke"); err != nil {
		t.Fatalf("RevokeAPIKey: %v", err)
	}
	validation, err = store.ValidateAPIKeyHash(ctx, hash[:])
	if err != nil {
		t.Fatalf("ValidateAPIKeyHash after revoke: %v", err)
	}
	if validation.Active || validation.KeyStatus != "revoked" {
		t.Fatalf("revoked validation = %+v", validation)
	}
}

func TestOpenAppliesSQLitePragmasViaDSN(t *testing.T) {
	store := newTestStore(t)
	defer store.Close()
	ctx := context.Background()
	for _, tc := range []struct {
		query string
		want  int
	}{
		{query: `PRAGMA busy_timeout`, want: 5000},
		{query: `PRAGMA foreign_keys`, want: 1},
	} {
		var got int
		if err := store.db.QueryRowContext(ctx, tc.query).Scan(&got); err != nil {
			t.Fatalf("%s: %v", tc.query, err)
		}
		if got != tc.want {
			t.Fatalf("%s=%d want %d", tc.query, got, tc.want)
		}
	}
}

func TestAccountScopedRevocationAndRotation(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_a")
	createAccount(t, store, "acct_b")
	hashA := keyHash("key-a")
	hashB := keyHash("key-b")
	if err := store.CreateAPIKey(ctx, storage.APIKey{KeyID: "key_a", AccountID: "acct_a", KeyHash: hashA[:], KeyHashPrefix: "mp_a", Status: "active", CreatedAt: fixedTime()}); err != nil {
		t.Fatalf("CreateAPIKey A: %v", err)
	}
	if err := store.CreateAPIKey(ctx, storage.APIKey{KeyID: "key_b", AccountID: "acct_b", KeyHash: hashB[:], KeyHashPrefix: "mp_b", Status: "active", CreatedAt: fixedTime()}); err != nil {
		t.Fatalf("CreateAPIKey B: %v", err)
	}
	if err := store.RevokeAPIKeyForAccount(ctx, "acct_a", "key_b", "account", "req_cross"); !errors.Is(err, storage.ErrNotFound) {
		t.Fatalf("cross-account revoke err=%v, want ErrNotFound", err)
	}
	validation, err := store.ValidateAPIKeyHash(ctx, hashB[:])
	if err != nil {
		t.Fatalf("Validate B: %v", err)
	}
	if validation.KeyStatus != "active" {
		t.Fatalf("cross-account revoke changed B: %+v", validation)
	}

	newHash := keyHash("key-a-new")
	if err := store.RotateAPIKey(ctx, "key_a", "acct_a", storage.APIKey{
		KeyID: "key_a_new", AccountID: "acct_a", KeyHash: newHash[:], KeyHashPrefix: "mp_new", Status: "active", CreatedAt: fixedTime(),
	}, "account", "req_rotate"); err != nil {
		t.Fatalf("RotateAPIKey: %v", err)
	}
	oldValidation, err := store.ValidateAPIKeyHash(ctx, hashA[:])
	if err != nil {
		t.Fatalf("Validate old: %v", err)
	}
	if oldValidation.KeyStatus != "revoked" {
		t.Fatalf("old key status=%s want revoked", oldValidation.KeyStatus)
	}
	newValidation, err := store.ValidateAPIKeyHash(ctx, newHash[:])
	if err != nil {
		t.Fatalf("Validate new: %v", err)
	}
	if !newValidation.Active || newValidation.AccountID != "acct_a" {
		t.Fatalf("new validation=%+v", newValidation)
	}
}

func TestAppendOnlyEventTablesRejectMutation(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_append")

	if err := store.InsertUsageEvent(ctx, storage.UsageEvent{
		RequestID: "req_usage", AccountID: "acct_append", WindowDate: "2026-05-29",
		PromptTokens: 1, CompletionTokens: 2, TokenSource: "provider_reported", Outcome: "ok", CreatedAt: fixedTime(),
	}); err != nil {
		t.Fatalf("InsertUsageEvent: %v", err)
	}
	if err := store.InsertFeedbackEvent(ctx, storage.FeedbackEvent{
		EventID: "fb_1", RequestID: "req_usage", AccountID: "acct_append", Scope: "request", Rating: 4, Comment: "ok", CreatedAt: fixedTime(),
	}); err != nil {
		t.Fatalf("InsertFeedbackEvent: %v", err)
	}
	if err := store.InsertAuditEvent(ctx, storage.AuditEvent{
		EventID: "audit_1", RequestID: "req_usage", AccountID: "acct_append", Actor: "test", Type: "quota_change", Payload: "{}", CreatedAt: fixedTime(),
	}); err != nil {
		t.Fatalf("InsertAuditEvent: %v", err)
	}
	if err := store.InsertCapacitySignalEvent(ctx, storage.CapacitySignalEvent{
		EventID: "cap_1", Signal: "cpu", Value: 71, Threshold: 70, Firing: true, CreatedAt: fixedTime(),
	}); err != nil {
		t.Fatalf("InsertCapacitySignalEvent: %v", err)
	}

	assertSQLFails(t, store, `UPDATE usage_events SET total_tokens = 99 WHERE request_id = 'req_usage'`)
	assertSQLFails(t, store, `DELETE FROM feedback_events WHERE event_id = 'fb_1'`)
	assertSQLFails(t, store, `UPDATE audit_events SET payload_json = '{"bad":true}' WHERE event_id = 'audit_1'`)
	assertSQLFails(t, store, `DELETE FROM capacity_signal_events WHERE event_id = 'cap_1'`)
}

func TestDefaultValuesAndNotFoundErrors(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)

	if _, err := Open(ctx, ""); err == nil {
		t.Fatal("Open with empty path unexpectedly succeeded")
	}
	if err := store.CreateAccount(ctx, storage.Account{AccountID: "acct_defaults"}); err != nil {
		t.Fatalf("CreateAccount defaults: %v", err)
	}
	gotAccount, err := store.LookupAccount(ctx, "acct_defaults")
	if err != nil {
		t.Fatalf("LookupAccount: %v", err)
	}
	if gotAccount.AccountID != "acct_defaults" || gotAccount.Status != "active" {
		t.Fatalf("LookupAccount = %+v", gotAccount)
	}
	if _, err := store.LookupAccount(ctx, "missing"); !errors.Is(err, storage.ErrNotFound) {
		t.Fatalf("LookupAccount missing err=%v, want ErrNotFound", err)
	}
	account, err := store.LookupAccountByIdentity(ctx, "github", "missing")
	if !errors.Is(err, storage.ErrNotFound) {
		t.Fatalf("LookupAccountByIdentity missing account=%+v err=%v, want ErrNotFound", account, err)
	}

	hash := keyHash("default-status-key")
	if err := store.CreateAPIKey(ctx, storage.APIKey{
		KeyID: "key_defaults", AccountID: "acct_defaults", KeyHash: hash[:], KeyHashPrefix: "mp_default",
	}); err != nil {
		t.Fatalf("CreateAPIKey defaults: %v", err)
	}
	validation, err := store.ValidateAPIKeyHash(ctx, hash[:])
	if err != nil {
		t.Fatalf("ValidateAPIKeyHash defaults: %v", err)
	}
	if !validation.Active || validation.QuotaClass != "default" || validation.ConcurrencyClass != "default" {
		t.Fatalf("validation defaults = %+v", validation)
	}
	keys, err := store.ListAPIKeys(ctx, "acct_defaults")
	if err != nil {
		t.Fatalf("ListAPIKeys: %v", err)
	}
	if len(keys) != 1 || keys[0].KeyID != "key_defaults" || keys[0].Status != "active" {
		t.Fatalf("keys = %+v", keys)
	}
	if err := store.RevokeAPIKey(ctx, "missing_key", "operator", "req_missing"); !errors.Is(err, storage.ErrNotFound) {
		t.Fatalf("RevokeAPIKey missing err=%v, want ErrNotFound", err)
	}
}

func TestOAuthStateAndRateLimitStores(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	now := fixedTime()

	stateHash := keyHash("oauth-state")
	if err := store.StoreOAuthState(ctx, storage.OAuthState{
		StateHash: stateHash[:], SessionID: "session_1", RedirectURI: "https://api.streamvc.live/auth/github/callback",
		ClientIP: "1.2.3.4", Action: "mint", CreatedAt: now, ExpiresAt: now.Add(10 * time.Minute),
	}); err != nil {
		t.Fatalf("StoreOAuthState: %v", err)
	}
	redirectURI, action, err := store.ConsumeOAuthState(ctx, stateHash[:], "session_1", now.Add(time.Minute))
	if err != nil {
		t.Fatalf("ConsumeOAuthState: %v", err)
	}
	if redirectURI != "https://api.streamvc.live/auth/github/callback" {
		t.Fatalf("redirectURI=%q", redirectURI)
	}
	if action != "mint" {
		t.Fatalf("action=%q, want %q", action, "mint")
	}
	if _, _, err := store.ConsumeOAuthState(ctx, stateHash[:], "session_1", now.Add(2*time.Minute)); !errors.Is(err, storage.ErrNotFound) {
		t.Fatalf("ConsumeOAuthState replay err=%v, want ErrNotFound", err)
	}

	expiredHash := keyHash("expired-oauth-state")
	if err := store.StoreOAuthState(ctx, storage.OAuthState{
		StateHash: expiredHash[:], SessionID: "session_2", RedirectURI: "https://api.streamvc.live/auth/github/callback",
		ClientIP: "1.2.3.4", CreatedAt: now, ExpiresAt: now.Add(time.Minute),
	}); err != nil {
		t.Fatalf("StoreOAuthState expired: %v", err)
	}
	if _, _, err := store.ConsumeOAuthState(ctx, expiredHash[:], "session_2", now.Add(2*time.Minute)); !errors.Is(err, storage.ErrNotFound) {
		t.Fatalf("ConsumeOAuthState expired err=%v, want ErrNotFound", err)
	}

	// Default (unset) action persists as empty string and round-trips cleanly.
	plainHash := keyHash("plain-oauth-state")
	if err := store.StoreOAuthState(ctx, storage.OAuthState{
		StateHash: plainHash[:], SessionID: "session_3", RedirectURI: "https://api.streamvc.live/auth/github/callback",
		ClientIP: "1.2.3.4", CreatedAt: now, ExpiresAt: now.Add(10 * time.Minute),
	}); err != nil {
		t.Fatalf("StoreOAuthState plain: %v", err)
	}
	_, action, err = store.ConsumeOAuthState(ctx, plainHash[:], "session_3", now.Add(time.Minute))
	if err != nil {
		t.Fatalf("ConsumeOAuthState plain: %v", err)
	}
	if action != "" {
		t.Fatalf("default action=%q, want empty", action)
	}

	if err := store.RecordSignupEvent(ctx, storage.SignupEvent{
		EventID: "signup_1", AccountID: "acct_signup", ClientIP: "1.2.3.4", Provider: "github", CreatedAt: now,
	}); err != nil {
		t.Fatalf("RecordSignupEvent: %v", err)
	}
	signups, err := store.CountSignupEventsSince(ctx, "1.2.3.4", now.Add(-time.Hour))
	if err != nil {
		t.Fatalf("CountSignupEventsSince: %v", err)
	}
	if signups != 1 {
		t.Fatalf("signups=%d, want 1", signups)
	}
	if err := store.RecordDemoSessionEvent(ctx, storage.DemoSessionEvent{
		EventID: "demo_1", ClientIP: "1.2.3.4", CreatedAt: now,
	}); err != nil {
		t.Fatalf("RecordDemoSessionEvent: %v", err)
	}
	demos, err := store.CountDemoSessionEventsSince(ctx, "1.2.3.4", now.Add(-time.Hour))
	if err != nil {
		t.Fatalf("CountDemoSessionEventsSince: %v", err)
	}
	if demos != 1 {
		t.Fatalf("demos=%d, want 1", demos)
	}

	assertSQLFails(t, store, `UPDATE signup_events SET provider = 'email' WHERE event_id = 'signup_1'`)
	assertSQLFails(t, store, `DELETE FROM demo_session_events WHERE event_id = 'demo_1'`)
}

func TestQuotaReservationLedgerSemantics(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_quota")
	if err := store.InsertUsageEvent(ctx, storage.UsageEvent{
		RequestID: "req_existing", AccountID: "acct_quota", WindowDate: "2026-05-29",
		PromptTokens: 20, CompletionTokens: 40, TokenSource: "manual_fixture", Outcome: "ok", CreatedAt: fixedTime(),
	}); err != nil {
		t.Fatalf("InsertUsageEvent: %v", err)
	}

	decision, err := store.ReserveQuota(ctx, storage.ReservationRequest{
		AccountID: "acct_quota", RequestID: "req_1", WindowDate: "2026-05-29",
		RequestedTokens: 30, DailyQuota: 100, CreatedAt: fixedTime(), ExpiresAt: fixedTime().Add(time.Hour),
	})
	if err != nil {
		t.Fatalf("ReserveQuota req_1: %v", err)
	}
	if !decision.Admitted || decision.RemainingTokens != 10 {
		t.Fatalf("decision req_1 = %+v", decision)
	}

	_, err = store.ReserveQuota(ctx, storage.ReservationRequest{
		AccountID: "acct_quota", RequestID: "req_2", WindowDate: "2026-05-29",
		RequestedTokens: 20, DailyQuota: 100, CreatedAt: fixedTime(), ExpiresAt: fixedTime().Add(time.Hour),
	})
	if !errors.Is(err, storage.ErrQuotaExceeded) {
		t.Fatalf("ReserveQuota req_2 err = %v, want ErrQuotaExceeded", err)
	}

	if err := store.SettleReservation(ctx, storage.ReservationSettlement{
		AccountID: "acct_quota", RequestID: "req_1", PromptTokens: 5, CompletionTokens: 7,
		TokenSource: "provider_reported", Outcome: "ok", SettledAt: fixedTime().Add(time.Minute),
	}); err != nil {
		t.Fatalf("SettleReservation: %v", err)
	}
	used, reserved, err := store.DailyUsage(ctx, "acct_quota", "2026-05-29")
	if err != nil {
		t.Fatalf("DailyUsage: %v", err)
	}
	if used != 72 || reserved != 0 {
		t.Fatalf("usage after settle used=%d reserved=%d", used, reserved)
	}

	decision, err = store.ReserveQuota(ctx, storage.ReservationRequest{
		AccountID: "acct_quota", RequestID: "req_3", WindowDate: "2026-05-29",
		RequestedTokens: 20, DailyQuota: 100, CreatedAt: fixedTime(), ExpiresAt: fixedTime().Add(time.Hour),
	})
	if err != nil {
		t.Fatalf("ReserveQuota req_3: %v", err)
	}
	if decision.RemainingTokens != 8 {
		t.Fatalf("decision req_3 = %+v", decision)
	}
	if err := store.RefundReservation(ctx, "acct_quota", "req_3", fixedTime().Unix()); err != nil {
		t.Fatalf("RefundReservation: %v", err)
	}
	used, reserved, err = store.DailyUsage(ctx, "acct_quota", "2026-05-29")
	if err != nil {
		t.Fatalf("DailyUsage after refund: %v", err)
	}
	if used != 72 || reserved != 0 {
		t.Fatalf("usage after refund used=%d reserved=%d", used, reserved)
	}
}

func TestExpiredReservationsReclaimedAfter24h(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_expired_reap")
	created := fixedTime().Add(-25 * time.Hour)
	if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
		AccountID: "acct_expired_reap", RequestID: "req_expired", WindowDate: "2026-05-29",
		RequestedTokens: 90, DailyQuota: 100, CreatedAt: created, ExpiresAt: created.Add(24 * time.Hour),
	}); err != nil {
		t.Fatalf("ReserveQuota expired fixture: %v", err)
	}
	used, reserved, err := store.DailyUsage(ctx, "acct_expired_reap", "2026-05-29")
	if err != nil {
		t.Fatalf("DailyUsage before reap: %v", err)
	}
	if used != 0 || reserved != 90 {
		t.Fatalf("before reap used=%d reserved=%d", used, reserved)
	}
	reaped, err := store.ReapExpiredReservations(ctx, fixedTime())
	if err != nil {
		t.Fatalf("ReapExpiredReservations: %v", err)
	}
	if reaped != 1 {
		t.Fatalf("reaped=%d want 1", reaped)
	}
	used, reserved, err = store.DailyUsage(ctx, "acct_expired_reap", "2026-05-29")
	if err != nil {
		t.Fatalf("DailyUsage after reap: %v", err)
	}
	if used != 0 || reserved != 0 {
		t.Fatalf("after reap used=%d reserved=%d", used, reserved)
	}
	if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
		AccountID: "acct_expired_reap", RequestID: "req_new", WindowDate: "2026-05-29",
		RequestedTokens: 100, DailyQuota: 100, CreatedAt: fixedTime(),
	}); err != nil {
		t.Fatalf("ReserveQuota after reap: %v", err)
	}
}

func TestClampReservationExpiryBoundsActiveHold(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_clamp_expiry")
	created := fixedTime()
	originalExpiry := created.Add(24 * time.Hour)
	deadline := created.Add(5 * time.Minute)
	if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
		AccountID: "acct_clamp_expiry", RequestID: "req_clamp", WindowDate: "2026-05-29",
		RequestedTokens: 40, DailyQuota: 100, CreatedAt: created, ExpiresAt: originalExpiry,
	}); err != nil {
		t.Fatalf("ReserveQuota: %v", err)
	}
	if err := store.ClampReservationExpiry(ctx, "acct_clamp_expiry", "req_clamp", deadline); err != nil {
		t.Fatalf("ClampReservationExpiry: %v", err)
	}
	if err := store.ClampReservationExpiry(ctx, "acct_clamp_expiry", "req_clamp", originalExpiry); err != nil {
		t.Fatalf("ClampReservationExpiry later: %v", err)
	}
	var raw string
	if err := store.db.QueryRow(`SELECT expires_at FROM quota_reservations WHERE account_id = ? AND request_id = ?`, "acct_clamp_expiry", "req_clamp").Scan(&raw); err != nil {
		t.Fatalf("query expires_at: %v", err)
	}
	expiresAt := decodeTime(raw)
	if !expiresAt.Equal(deadline) {
		t.Fatalf("expires_at=%s want clamped deadline %s", expiresAt, deadline)
	}
	reaped, err := store.ReapExpiredReservations(ctx, deadline.Add(time.Second))
	if err != nil {
		t.Fatalf("ReapExpiredReservations: %v", err)
	}
	if reaped != 1 {
		t.Fatalf("reaped=%d want 1", reaped)
	}
	_, reserved, err := store.DailyUsage(ctx, "acct_clamp_expiry", "2026-05-29")
	if err != nil {
		t.Fatalf("DailyUsage: %v", err)
	}
	if reserved != 0 {
		t.Fatalf("reserved after clamped expiry reap=%d want 0", reserved)
	}
}

// TestDeleteTerminalQuotaReservationsKeepsActiveAndDropsOld pins the
// M2-4 / PERF-1 Part B contract: terminal-state rows past the retention
// window are deletable; active rows (and recent terminal rows) survive.
func TestDeleteTerminalQuotaReservationsKeepsActiveAndDropsOld(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_delete_terminal")

	// 100 reservations created 8 days ago and settled then — terminal,
	// past the 7-day retention window.
	oldAt := fixedTime().Add(-8 * 24 * time.Hour)
	for i := 0; i < 100; i++ {
		reqID := fmt.Sprintf("req_old_%03d", i)
		if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
			AccountID: "acct_delete_terminal", RequestID: reqID, WindowDate: "2026-05-21",
			RequestedTokens: 1, DailyQuota: 1000000, CreatedAt: oldAt, ExpiresAt: oldAt.Add(24 * time.Hour),
		}); err != nil {
			t.Fatalf("ReserveQuota old #%d: %v", i, err)
		}
		if err := store.SettleReservation(ctx, storage.ReservationSettlement{
			AccountID: "acct_delete_terminal", RequestID: reqID,
			PromptTokens: 1, CompletionTokens: 0, TotalTokens: 1, MaxTotalTokens: 1000,
			TokenSource: "provider_reported", Outcome: "ok", SettledAt: oldAt,
		}); err != nil {
			t.Fatalf("SettleReservation old #%d: %v", i, err)
		}
	}

	// 5 recently-settled reservations (3 days ago) — terminal but INSIDE
	// the retention window. Must survive. Added per codex code-audit
	// 2026-06-11 Low #49: the original fixture only had old-terminal +
	// active, so the test could not distinguish "deletes terminal rows
	// past cutoff" from "deletes all terminal rows".
	recentAt := fixedTime().Add(-3 * 24 * time.Hour)
	for i := 0; i < 5; i++ {
		reqID := fmt.Sprintf("req_recent_%03d", i)
		if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
			AccountID: "acct_delete_terminal", RequestID: reqID, WindowDate: "2026-05-26",
			RequestedTokens: 1, DailyQuota: 1000000, CreatedAt: recentAt, ExpiresAt: recentAt.Add(24 * time.Hour),
		}); err != nil {
			t.Fatalf("ReserveQuota recent #%d: %v", i, err)
		}
		if err := store.SettleReservation(ctx, storage.ReservationSettlement{
			AccountID: "acct_delete_terminal", RequestID: reqID,
			PromptTokens: 1, CompletionTokens: 0, TotalTokens: 1, MaxTotalTokens: 1000,
			TokenSource: "provider_reported", Outcome: "ok", SettledAt: recentAt,
		}); err != nil {
			t.Fatalf("SettleReservation recent #%d: %v", i, err)
		}
	}

	// 1 reservation settled EXACTLY at the cutoff (7 days ago). Must
	// survive because the predicate is strict less-than (settled_at <
	// before), not less-or-equal. Pins the boundary semantic.
	boundaryAt := fixedTime().Add(-7 * 24 * time.Hour)
	if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
		AccountID: "acct_delete_terminal", RequestID: "req_boundary", WindowDate: "2026-05-22",
		RequestedTokens: 1, DailyQuota: 1000000, CreatedAt: boundaryAt, ExpiresAt: boundaryAt.Add(24 * time.Hour),
	}); err != nil {
		t.Fatalf("ReserveQuota boundary: %v", err)
	}
	if err := store.SettleReservation(ctx, storage.ReservationSettlement{
		AccountID: "acct_delete_terminal", RequestID: "req_boundary",
		PromptTokens: 1, CompletionTokens: 0, TotalTokens: 1, MaxTotalTokens: 1000,
		TokenSource: "provider_reported", Outcome: "ok", SettledAt: boundaryAt,
	}); err != nil {
		t.Fatalf("SettleReservation boundary: %v", err)
	}

	// 10 active reservations created now — not yet terminal, must survive.
	for i := 0; i < 10; i++ {
		if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
			AccountID: "acct_delete_terminal", RequestID: fmt.Sprintf("req_active_%02d", i),
			WindowDate: "2026-05-29", RequestedTokens: 1, DailyQuota: 1000000,
			CreatedAt: fixedTime(), ExpiresAt: fixedTime().Add(24 * time.Hour),
		}); err != nil {
			t.Fatalf("ReserveQuota active #%d: %v", i, err)
		}
	}

	deleted, err := store.DeleteTerminalQuotaReservations(ctx, fixedTime().Add(-7*24*time.Hour))
	if err != nil {
		t.Fatalf("DeleteTerminalQuotaReservations: %v", err)
	}
	if deleted != 100 {
		t.Fatalf("deleted = %d, want 100 (old-terminal only; recent-terminal + boundary + active must survive)", deleted)
	}

	// Active rows untouched on today's window.
	used, reserved, err := store.DailyUsage(ctx, "acct_delete_terminal", "2026-05-29")
	if err != nil {
		t.Fatalf("DailyUsage post-prune (active window): %v", err)
	}
	if used != 0 || reserved != 10 {
		t.Fatalf("post-prune (active) used=%d reserved=%d, want 0/10", used, reserved)
	}

	// Recent-terminal rows are settled, not active — they have used=5 on
	// the 2026-05-26 window. Survives the prune; not in DailyUsage's
	// active-reservation count.
	used, reserved, err = store.DailyUsage(ctx, "acct_delete_terminal", "2026-05-26")
	if err != nil {
		t.Fatalf("DailyUsage post-prune (recent window): %v", err)
	}
	if used != 5 || reserved != 0 {
		t.Fatalf("post-prune (recent) used=%d reserved=%d, want 5/0 (recent-terminal rows must survive)", used, reserved)
	}

	// Boundary row is settled on the 2026-05-22 window. Survives.
	used, reserved, err = store.DailyUsage(ctx, "acct_delete_terminal", "2026-05-22")
	if err != nil {
		t.Fatalf("DailyUsage post-prune (boundary window): %v", err)
	}
	if used != 1 || reserved != 0 {
		t.Fatalf("post-prune (boundary) used=%d reserved=%d, want 1/0 (cutoff-boundary row must survive on strict-less-than)", used, reserved)
	}
}

// TestOpenReadOnlyServesReadsButNotWrites pins the M2-4 / PERF-4 design:
// the read handle uses mode=ro so writes through it fail loudly. This
// catches a regression where a future handler accidentally routes a
// write through readStore().
func TestOpenReadOnlyServesReadsButNotWrites(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "gateway.db")
	primary, err := Open(ctx, path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer primary.Close()
	if err := primary.CreateAccount(ctx, storage.Account{
		AccountID: "acct_ro_test", Status: "active", QuotaClass: "default", ConcurrencyClass: "default", CreatedAt: fixedTime(),
	}); err != nil {
		t.Fatalf("CreateAccount via primary: %v", err)
	}

	readStore, err := OpenReadOnly(ctx, path)
	if err != nil {
		t.Fatalf("OpenReadOnly: %v", err)
	}
	defer readStore.Close()

	// Reads work.
	used, reserved, err := readStore.DailyUsage(ctx, "acct_ro_test", "2026-05-29")
	if err != nil {
		t.Fatalf("DailyUsage via readStore: %v", err)
	}
	if used != 0 || reserved != 0 {
		t.Fatalf("readStore DailyUsage = (%d,%d), want (0,0)", used, reserved)
	}

	// Writes fail (mode=ro at the SQLite driver level).
	if err := readStore.CreateAccount(ctx, storage.Account{
		AccountID: "acct_should_fail", Status: "active", QuotaClass: "default", ConcurrencyClass: "default", CreatedAt: fixedTime(),
	}); err == nil {
		t.Fatal("CreateAccount via read-only store unexpectedly succeeded; mode=ro guard is missing")
	}
}

func TestConcurrentQuotaReservationsNoOverspend(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_concurrent")
	var admitted int64
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			decision, err := store.ReserveQuota(ctx, storage.ReservationRequest{
				AccountID: "acct_concurrent", RequestID: fmt.Sprintf("req_concurrent_%02d", i),
				WindowDate: "2026-05-29", RequestedTokens: 20, DailyQuota: 100,
				CreatedAt: fixedTime(), ExpiresAt: fixedTime().Add(time.Hour),
			})
			if err == nil && decision.Admitted {
				atomic.AddInt64(&admitted, 1)
				return
			}
			if !errors.Is(err, storage.ErrQuotaExceeded) {
				t.Errorf("ReserveQuota %d err=%v", i, err)
			}
		}(i)
	}
	wg.Wait()
	if admitted != 5 {
		t.Fatalf("admitted=%d, want exactly 5", admitted)
	}
	used, reserved, err := store.DailyUsage(ctx, "acct_concurrent", "2026-05-29")
	if err != nil {
		t.Fatalf("DailyUsage: %v", err)
	}
	if used != 0 || reserved != 100 {
		t.Fatalf("used=%d reserved=%d, want 0/100", used, reserved)
	}
}

func TestConcurrencyReservationCapAndRelease(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_concurrency")
	for i := 0; i < 2; i++ {
		decision, err := store.AcquireConcurrency(ctx, storage.ConcurrencyRequest{
			AccountID: "acct_concurrency", RequestID: fmt.Sprintf("req_%d", i), Limit: 2,
			CreatedAt: fixedTime(), ExpiresAt: fixedTime().Add(time.Hour),
		})
		if err != nil {
			t.Fatalf("AcquireConcurrency %d: %v", i, err)
		}
		if !decision.Admitted {
			t.Fatalf("decision %d = %+v", i, decision)
		}
	}
	if _, err := store.AcquireConcurrency(ctx, storage.ConcurrencyRequest{
		AccountID: "acct_concurrency", RequestID: "req_3", Limit: 2,
		CreatedAt: fixedTime(), ExpiresAt: fixedTime().Add(time.Hour),
	}); !errors.Is(err, storage.ErrQuotaExceeded) {
		t.Fatalf("AcquireConcurrency over cap err=%v, want ErrQuotaExceeded", err)
	}
	if err := store.ReleaseConcurrency(ctx, "acct_concurrency", "req_0", fixedTime().Add(time.Minute)); err != nil {
		t.Fatalf("ReleaseConcurrency: %v", err)
	}
	decision, err := store.AcquireConcurrency(ctx, storage.ConcurrencyRequest{
		AccountID: "acct_concurrency", RequestID: "req_4", Limit: 2,
		CreatedAt: fixedTime().Add(2 * time.Minute), ExpiresAt: fixedTime().Add(time.Hour),
	})
	if err != nil {
		t.Fatalf("AcquireConcurrency after release: %v", err)
	}
	if !decision.Admitted {
		t.Fatalf("decision after release = %+v", decision)
	}
}

func TestDemoReservationSettlesUsageAndDemoEvent(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
		AccountID: "demo:1.2.3.4", RequestID: "req_demo", WindowDate: "2026-05-29",
		RequestedTokens: 10, DailyQuota: 20, CreatedAt: fixedTime(), ExpiresAt: fixedTime().Add(time.Hour),
	}); err != nil {
		t.Fatalf("ReserveQuota demo: %v", err)
	}
	if err := store.SettleDemoReservation(ctx, storage.ReservationSettlement{
		AccountID: "demo:1.2.3.4", RequestID: "req_demo", PromptTokens: 3, CompletionTokens: 4,
		TokenSource: "provider_reported", Outcome: "ok", SettledAt: fixedTime().Add(time.Minute),
	}, storage.DemoUsageEvent{
		RequestID: "req_demo", ClientIP: "1.2.3.4", DemoTokenHash: "hash", CreatedAt: fixedTime().Add(time.Minute),
	}); err != nil {
		t.Fatalf("SettleDemoReservation: %v", err)
	}
	used, reserved, err := store.DailyUsage(ctx, "demo:1.2.3.4", "2026-05-29")
	if err != nil {
		t.Fatalf("DailyUsage demo: %v", err)
	}
	if used != 7 || reserved != 0 {
		t.Fatalf("demo usage used=%d reserved=%d", used, reserved)
	}
	var demoCount int
	if err := store.db.QueryRow(`SELECT COUNT(*) FROM demo_usage_events WHERE request_id = 'req_demo' AND total_tokens = 7`).Scan(&demoCount); err != nil {
		t.Fatalf("count demo usage: %v", err)
	}
	if demoCount != 1 {
		t.Fatalf("demo usage events=%d want 1", demoCount)
	}
}

func TestReservationErrorBranches(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_reservation_errors")

	err := store.SettleReservation(ctx, storage.ReservationSettlement{
		AccountID: "acct_reservation_errors", RequestID: "missing", PromptTokens: 1,
		TokenSource: "provider_reported", Outcome: "ok",
	})
	if !errors.Is(err, storage.ErrReservationNotFound) {
		t.Fatalf("SettleReservation missing err=%v, want ErrReservationNotFound", err)
	}
	if err := store.RefundReservation(ctx, "acct_reservation_errors", "missing", fixedTime().Unix()); !errors.Is(err, storage.ErrReservationNotFound) {
		t.Fatalf("RefundReservation missing err=%v, want ErrReservationNotFound", err)
	}

	if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
		AccountID: "acct_reservation_errors", RequestID: "req_refund_then_settle", WindowDate: "bad-date",
		RequestedTokens: 5, DailyQuota: 100,
	}); err != nil {
		t.Fatalf("ReserveQuota: %v", err)
	}
	if err := store.RefundReservation(ctx, "acct_reservation_errors", "req_refund_then_settle", fixedTime().Unix()); err != nil {
		t.Fatalf("RefundReservation: %v", err)
	}
	err = store.SettleReservation(ctx, storage.ReservationSettlement{
		AccountID: "acct_reservation_errors", RequestID: "req_refund_then_settle", PromptTokens: 1,
		TokenSource: "provider_reported", Outcome: "ok",
	})
	if err == nil {
		t.Fatal("SettleReservation on refunded reservation unexpectedly succeeded")
	}
}

func TestReservationSettlementRejectsInvalidTokenTotals(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_invalid_settlement")
	for _, tc := range []struct {
		name       string
		settlement storage.ReservationSettlement
	}{
		{
			name: "negative",
			settlement: storage.ReservationSettlement{
				AccountID: "acct_invalid_settlement", RequestID: "req_negative", PromptTokens: -1, CompletionTokens: 1,
				TokenSource: "provider_reported", Outcome: "ok", SettledAt: fixedTime(),
			},
		},
		{
			name: "overflow",
			settlement: storage.ReservationSettlement{
				AccountID: "acct_invalid_settlement", RequestID: "req_overflow", PromptTokens: math.MaxInt64, CompletionTokens: 1,
				TokenSource: "provider_reported", Outcome: "ok", SettledAt: fixedTime(),
			},
		},
		{
			name: "inconsistent_total",
			settlement: storage.ReservationSettlement{
				AccountID: "acct_invalid_settlement", RequestID: "req_inconsistent", PromptTokens: 1, CompletionTokens: 2, TotalTokens: 4,
				TokenSource: "provider_reported", Outcome: "ok", SettledAt: fixedTime(),
			},
		},
		{
			name: "exceeds_request_max",
			settlement: storage.ReservationSettlement{
				AccountID: "acct_invalid_settlement", RequestID: "req_exceeds_max", PromptTokens: 7, CompletionTokens: 5, MaxTotalTokens: 10,
				TokenSource: "provider_reported", Outcome: "ok", SettledAt: fixedTime(),
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
				AccountID: "acct_invalid_settlement", RequestID: tc.settlement.RequestID, WindowDate: "2026-05-29",
				RequestedTokens: 10, DailyQuota: 1000, ExpiresAt: fixedTime().Add(time.Minute), CreatedAt: fixedTime(),
			}); err != nil {
				t.Fatalf("ReserveQuota: %v", err)
			}
			if err := store.SettleReservation(ctx, tc.settlement); err == nil {
				t.Fatal("SettleReservation unexpectedly accepted invalid token totals")
			}
		})
	}
}

func TestEventInsertDefaults(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_event_defaults")

	if err := store.InsertUsageEvent(ctx, storage.UsageEvent{
		RequestID: "req_usage_defaults", AccountID: "acct_event_defaults", WindowDate: "2026-05-29",
		PromptTokens: 3, CompletionTokens: 4, TokenSource: "gateway_estimated", Outcome: "ok",
	}); err != nil {
		t.Fatalf("InsertUsageEvent defaults: %v", err)
	}
	used, reserved, err := store.DailyUsage(ctx, "acct_event_defaults", "2026-05-29")
	if err != nil {
		t.Fatalf("DailyUsage defaults: %v", err)
	}
	if used != 7 || reserved != 0 {
		t.Fatalf("DailyUsage defaults used=%d reserved=%d", used, reserved)
	}
	if err := store.InsertFeedbackEvent(ctx, storage.FeedbackEvent{
		EventID: "fb_defaults", RequestID: "req_usage_defaults", AccountID: "acct_event_defaults", Scope: "request", Rating: 3,
	}); err != nil {
		t.Fatalf("InsertFeedbackEvent defaults: %v", err)
	}
	if err := store.InsertAuditEvent(ctx, storage.AuditEvent{
		EventID: "audit_defaults", RequestID: "req_usage_defaults", Actor: "test", Type: "key_revoked", Payload: "{}",
	}); err != nil {
		t.Fatalf("InsertAuditEvent defaults: %v", err)
	}
	if err := store.InsertCapacitySignalEvent(ctx, storage.CapacitySignalEvent{
		EventID: "cap_defaults", Signal: "bandwidth", Value: 10, Threshold: 70,
	}); err != nil {
		t.Fatalf("InsertCapacitySignalEvent defaults: %v", err)
	}
}

func TestFeedbackSummaryAndCapacityStores(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_summary")
	old := fixedTime().Add(-48 * time.Hour)
	now := fixedTime()
	if err := store.InsertFeedbackEvent(ctx, storage.FeedbackEvent{
		EventID: "fb_old", RequestID: "req_old", AccountID: "acct_summary", Scope: "request", Rating: 1, Comment: "old", CreatedAt: old,
	}); err != nil {
		t.Fatalf("InsertFeedbackEvent old: %v", err)
	}
	if err := store.InsertFeedbackEvent(ctx, storage.FeedbackEvent{
		EventID: "fb_new", RequestID: "req_new", AccountID: "acct_summary", Scope: "account", Rating: 4, Comment: "new", CreatedAt: now,
	}); err != nil {
		t.Fatalf("InsertFeedbackEvent new: %v", err)
	}
	events, err := store.ListFeedbackEventsSince(ctx, now.Add(-time.Hour))
	if err != nil {
		t.Fatalf("ListFeedbackEventsSince: %v", err)
	}
	if len(events) != 1 || events[0].EventID != "fb_new" {
		t.Fatalf("events = %+v", events)
	}

	if err := store.InsertCapacitySignalEvent(ctx, storage.CapacitySignalEvent{
		EventID: "cap_cpu_1", Signal: "cpu", Value: 80, Threshold: 70, Firing: true, CreatedAt: now,
	}); err != nil {
		t.Fatalf("InsertCapacitySignalEvent cpu firing: %v", err)
	}
	if err := store.InsertCapacitySignalEvent(ctx, storage.CapacitySignalEvent{
		EventID: "cap_cpu_2", Signal: "cpu", Value: 50, Threshold: 70, Firing: false, CreatedAt: now.Add(time.Minute),
	}); err != nil {
		t.Fatalf("InsertCapacitySignalEvent cpu clear: %v", err)
	}
	if err := store.InsertCapacitySignalEvent(ctx, storage.CapacitySignalEvent{
		EventID: "cap_mem_1", Signal: "memory", Value: 90, Threshold: 80, Firing: true, CreatedAt: now,
	}); err != nil {
		t.Fatalf("InsertCapacitySignalEvent memory: %v", err)
	}
	signals, err := store.LatestCapacitySignals(ctx)
	if err != nil {
		t.Fatalf("LatestCapacitySignals: %v", err)
	}
	if len(signals) != 2 {
		t.Fatalf("signals len=%d want 2: %+v", len(signals), signals)
	}
	bySignal := map[string]storage.CapacitySignalEvent{}
	for _, signal := range signals {
		bySignal[signal.Signal] = signal
	}
	if bySignal["cpu"].Firing || !bySignal["memory"].Firing {
		t.Fatalf("signals = %+v", signals)
	}

	tier, err := store.GetCapacityTier(ctx)
	if err != nil {
		t.Fatalf("GetCapacityTier default: %v", err)
	}
	if tier.Tier != 0 {
		t.Fatalf("default tier=%d want 0", tier.Tier)
	}
	if err := store.SetCapacityTier(ctx, storage.CapacityTier{Tier: 2, Signals: "cpu", UpdatedAt: now}); err != nil {
		t.Fatalf("SetCapacityTier: %v", err)
	}
	tier, err = store.GetCapacityTier(ctx)
	if err != nil {
		t.Fatalf("GetCapacityTier: %v", err)
	}
	if tier.Tier != 2 || tier.Signals != "cpu" || !tier.UpdatedAt.Equal(now) {
		t.Fatalf("tier = %+v", tier)
	}
	kill, err := store.GetKillSwitch(ctx)
	if err != nil {
		t.Fatalf("GetKillSwitch default: %v", err)
	}
	if !kill.UpdatedAt.IsZero() || kill.DemoOnly || kill.AllPublicAPI {
		t.Fatalf("default kill switch = %+v", kill)
	}
	if err := store.SetKillSwitch(ctx, storage.KillSwitchState{DemoOnly: true, AllPublicAPI: true, UpdatedAt: now}); err != nil {
		t.Fatalf("SetKillSwitch: %v", err)
	}
	kill, err = store.GetKillSwitch(ctx)
	if err != nil {
		t.Fatalf("GetKillSwitch: %v", err)
	}
	if !kill.DemoOnly || !kill.AllPublicAPI || !kill.UpdatedAt.Equal(now) {
		t.Fatalf("kill switch = %+v", kill)
	}
}

// TestCapacityTierRoundTripSpecialChars verifies that SetCapacityTier/GetCapacityTier
// round-trips Signals values that contain JSON-special characters.
// Added because the old Sscanf %q format would have failed on these inputs.
func TestCapacityTierRoundTripSpecialChars(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)

	// Signals containing backslashes, double quotes, control characters, and Unicode.
	specialSignals := "cpu\\high \"memory\" \n\t load™"

	now := time.Now().UTC().Truncate(time.Second)
	if err := store.SetCapacityTier(ctx, storage.CapacityTier{Tier: 3, Signals: specialSignals, UpdatedAt: now}); err != nil {
		t.Fatalf("SetCapacityTier with special chars: %v", err)
	}
	got, err := store.GetCapacityTier(ctx)
	if err != nil {
		t.Fatalf("GetCapacityTier with special chars: %v", err)
	}
	if got.Signals != specialSignals {
		t.Fatalf("Signals round-trip mismatch:\n got:  %q\n want: %q", got.Signals, specialSignals)
	}
	if got.Tier != 3 {
		t.Fatalf("Tier round-trip mismatch: got %d want 3", got.Tier)
	}
	if !got.UpdatedAt.Equal(now) {
		t.Fatalf("UpdatedAt round-trip mismatch: got %v want %v", got.UpdatedAt, now)
	}
}

// TestCapacityTierLegacyFormatBackwardCompat documents that old fmt.Sprintf %q rows
// containing \xNN escapes round-trip through the new json-based decoder via the
// legacy fallback path. The old SetCapacityTier used fmt.Sprintf with %q which
// produces Go-quoted strings (e.g., \x00 for NUL) that json.Unmarshal rejects.
func TestCapacityTierLegacyFormatBackwardCompat(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)

	cases := []struct {
		name    string
		signals string
	}{
		{"normal_ascii", "cpu_high memory_low"},
		{"nul_byte", string([]byte{'h', 'e', 'l', 'l', 'o', 0x00, 'w', 'o', 'r', 'l', 'd'})},
		{"invalid_utf8", string([]byte{'b', 'a', 'd', 0xff, 0xfe, 's', 'e', 'q'})},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Write a row using the OLD fmt.Sprintf %q format directly into the DB,
			// simulating rows that were created before the json migration.
			legacyValue := fmt.Sprintf(`{"tier":%d,"signals":%q}`, 2, tc.signals)
			_, err := store.db.ExecContext(ctx,
				`INSERT OR REPLACE INTO runtime_config (key, value, updated_at) VALUES (?, ?, ?)`,
				"capacity_tier", legacyValue, encodeTime(time.Now().UTC()))
			if err != nil {
				t.Fatalf("insert legacy row: %v", err)
			}

			got, err := store.GetCapacityTier(ctx)
			if err != nil {
				t.Fatalf("GetCapacityTier legacy row (%s): %v", tc.name, err)
			}
			if got.Tier != 2 {
				t.Fatalf("Tier mismatch: got %d want 2", got.Tier)
			}
			if got.Signals != tc.signals {
				t.Fatalf("Signals mismatch:\n got:  %q\n want: %q", got.Signals, tc.signals)
			}
		})
	}
}

// BenchmarkAuthLookupWith10KKeys replaces the previous
// TestAuthLookupP95UnderOneMillisecondWith10KKeys: a hard 1ms ceiling in
// a unit test flakes under parallel load on CI (observed 13ms). The
// p95 is still worth tracking, just not as a Go test pass/fail signal —
// run `go test -bench=BenchmarkAuthLookup ./internal/storage/sqlite/`
// to see it. The structural guarantee (idx_api_keys_hash exists) lives
// in TestAPIKeyHashIndexExists below.
func BenchmarkAuthLookupWith10KKeys(b *testing.B) {
	ctx := context.Background()
	store := newTestStore(b)
	createAccount(b, store, "acct_bench")

	targetHash := keyHash("fixture-9999")
	for i := 0; i < 10000; i++ {
		hash := keyHash(fmt.Sprintf("fixture-%04d", i))
		if err := store.CreateAPIKey(ctx, storage.APIKey{
			KeyID: fmt.Sprintf("key_%04d", i), AccountID: "acct_bench", KeyHash: hash[:],
			KeyHashPrefix: fmt.Sprintf("mp_%04d", i), Status: "active", CreatedAt: fixedTime(),
		}); err != nil {
			b.Fatalf("CreateAPIKey %d: %v", i, err)
		}
	}

	durations := make([]time.Duration, 0, b.N)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		start := time.Now()
		validation, err := store.ValidateAPIKeyHash(ctx, targetHash[:])
		durations = append(durations, time.Since(start))
		if err != nil {
			b.Fatalf("ValidateAPIKeyHash: %v", err)
		}
		if validation.KeyID != "key_9999" {
			b.Fatalf("validation key = %s", validation.KeyID)
		}
	}
	b.StopTimer()
	if len(durations) > 0 {
		sort.Slice(durations, func(i, j int) bool { return durations[i] < durations[j] })
		p95 := durations[int(float64(len(durations))*0.95)]
		b.ReportMetric(float64(p95.Nanoseconds())/1e6, "p95_ms")
	}
}

func TestAPIKeyHashIndexExists(t *testing.T) {
	store := newTestStore(t)
	var sqlText string
	err := store.db.QueryRowContext(context.Background(), `SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'idx_api_keys_hash'`).Scan(&sqlText)
	if err != nil {
		t.Fatalf("idx_api_keys_hash lookup: %v", err)
	}
	if !strings.Contains(sqlText, "key_hash") {
		t.Fatalf("idx_api_keys_hash sql = %q, want key_hash index", sqlText)
	}
}

func newTestStore(tb testing.TB) *Store {
	tb.Helper()
	store, err := Open(context.Background(), filepath.Join(tb.TempDir(), "gateway.db"))
	if err != nil {
		tb.Fatalf("Open: %v", err)
	}
	tb.Cleanup(func() {
		if err := store.Close(); err != nil {
			tb.Fatalf("Close: %v", err)
		}
	})
	return store
}

func createAccount(tb testing.TB, store *Store, accountID string) {
	tb.Helper()
	if err := store.CreateAccount(context.Background(), storage.Account{
		AccountID: accountID, Status: "active", QuotaClass: "default", ConcurrencyClass: "default", CreatedAt: fixedTime(),
	}); err != nil {
		tb.Fatalf("CreateAccount: %v", err)
	}
}

func assertSQLFails(t *testing.T, store *Store, stmt string) {
	t.Helper()
	if _, err := store.db.Exec(stmt); err == nil {
		t.Fatalf("statement unexpectedly succeeded: %s", stmt)
	}
}

func fixedTime() time.Time {
	return time.Date(2026, 5, 29, 0, 0, 0, 0, time.UTC)
}

func keyHash(s string) [32]byte {
	sum := sha256.Sum256([]byte(s))
	if bytes.Equal(sum[:], make([]byte, 32)) {
		panic("unreachable")
	}
	return sum
}
