package sqlite

import (
	"context"
	"errors"
	"path/filepath"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

func relayBlindTestMetadata() *storage.RelayBlindMetadata {
	return &storage.RelayBlindMetadata{
		RequestedPrivacyMode:    "relay_blind_required",
		EffectivePrivacyOutcome: "relay_blind_unavailable",
		EnvelopeDigest:          "envelope-digest",
		KeyRecordDigest:         "key-record-digest",
		KID:                     "kid-v1",
		ProviderBindingDigest:   "provider-binding-digest",
		InputTokenUpperBound:    4,
		MaxOutputTokens:         3,
	}
}

func TestRelayBlindSettlementPropagatesMetadataAndClampsIndependentCaps(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_relay_accounting")
	now := fixedTime()
	reserved := relayBlindTestMetadata()
	if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
		AccountID: "acct_relay_accounting", RequestID: "req_relay_accounting", WindowDate: now.Format("2006-01-02"),
		RequestedTokens: 20, DailyQuota: 100, CreatedAt: now, ExpiresAt: now.Add(time.Minute), RelayBlind: reserved,
	}); err != nil {
		t.Fatal(err)
	}
	settled := *reserved
	settled.EffectivePrivacyOutcome = "relay_blind_satisfied"
	if err := store.SettleReservation(ctx, storage.ReservationSettlement{
		AccountID: "acct_relay_accounting", RequestID: "req_relay_accounting",
		PromptTokens: 9, CompletionTokens: 8, TotalTokens: 17, MaxTotalTokens: 20,
		TokenSource: "provider_reported", Outcome: "ok", SettledAt: now.Add(time.Second), RelayBlind: &settled,
	}); err != nil {
		t.Fatal(err)
	}

	var prompt, completion, total int64
	var requested, effective, envelope, keyRecord, kid, providerBinding string
	var inputCap, outputCap int64
	if err := store.db.QueryRowContext(ctx, `SELECT prompt_tokens, completion_tokens, total_tokens, `+relayBlindSelectColumns+`
		FROM usage_events WHERE account_id = ? AND request_id = ?`, "acct_relay_accounting", "req_relay_accounting").Scan(
		&prompt, &completion, &total, &requested, &effective, &envelope, &keyRecord, &kid, &providerBinding, &inputCap, &outputCap); err != nil {
		t.Fatal(err)
	}
	if prompt != 4 || completion != 3 || total != 7 {
		t.Fatalf("settled tokens=%d/%d/%d want 4/3/7", prompt, completion, total)
	}
	got := relayBlindFromValues(requested, effective, envelope, keyRecord, kid, providerBinding, inputCap, outputCap)
	if !reflect.DeepEqual(got, &settled) {
		t.Fatalf("usage relay metadata=%+v want %+v", got, &settled)
	}
	var reservationEffective string
	if err := store.db.QueryRowContext(ctx, `SELECT effective_privacy_outcome FROM quota_reservations
		WHERE account_id = ? AND request_id = ?`, "acct_relay_accounting", "req_relay_accounting").Scan(&reservationEffective); err != nil {
		t.Fatal(err)
	}
	if reservationEffective != "relay_blind_satisfied" {
		t.Fatalf("reservation effective outcome=%q", reservationEffective)
	}
}

func TestRelayBlindSettlementRejectsImmutableMetadataConflict(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_relay_conflict")
	now := fixedTime()
	metadata := relayBlindTestMetadata()
	if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
		AccountID: "acct_relay_conflict", RequestID: "req_relay_conflict", WindowDate: now.Format("2006-01-02"),
		RequestedTokens: 20, DailyQuota: 100, CreatedAt: now, RelayBlind: metadata,
	}); err != nil {
		t.Fatal(err)
	}
	conflict := *metadata
	conflict.EnvelopeDigest = "different"
	err := store.SettleReservation(ctx, storage.ReservationSettlement{
		AccountID: "acct_relay_conflict", RequestID: "req_relay_conflict", PromptTokens: 1, CompletionTokens: 1,
		TokenSource: "provider_reported", Outcome: "ok", RelayBlind: &conflict,
	})
	if err == nil {
		t.Fatal("immutable relay metadata conflict was accepted")
	}
}

func TestRelayBlindUnknownInputRemainsZero(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_relay_unknown_input")
	now := fixedTime()
	metadata := relayBlindTestMetadata()
	if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
		AccountID: "acct_relay_unknown_input", RequestID: "req_relay_unknown_input", WindowDate: now.Format("2006-01-02"),
		RequestedTokens: 20, DailyQuota: 100, CreatedAt: now, RelayBlind: metadata,
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.SettleReservation(ctx, storage.ReservationSettlement{
		AccountID: "acct_relay_unknown_input", RequestID: "req_relay_unknown_input",
		PromptTokens: 0, CompletionTokens: 8, TotalTokens: 8, MaxTotalTokens: 20,
		TokenSource: "provider_reported", Outcome: "ok",
	}); err != nil {
		t.Fatal(err)
	}
	var prompt, completion int64
	if err := store.db.QueryRowContext(ctx, `SELECT prompt_tokens, completion_tokens FROM usage_events
		WHERE account_id = ? AND request_id = ?`, "acct_relay_unknown_input", "req_relay_unknown_input").Scan(&prompt, &completion); err != nil {
		t.Fatal(err)
	}
	if prompt != 0 || completion != 3 {
		t.Fatalf("unknown input/output=%d/%d want 0/3", prompt, completion)
	}
}

func TestRelayBlindEnsureUsageEventClampsAndChecksMetadata(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	metadata := relayBlindTestMetadata()
	metadata.EffectivePrivacyOutcome = "relay_blind_satisfied"
	event := storage.UsageEvent{
		AccountID: "acct_fallback_relay", RequestID: "req_fallback_relay", WindowDate: "2026-09-10",
		PromptTokens: 11, CompletionTokens: 12, TotalTokens: 23, TokenSource: "provider_reported", Outcome: "ok", RelayBlind: metadata,
	}
	if err := store.EnsureUsageEvent(ctx, event); err != nil {
		t.Fatal(err)
	}
	if err := store.EnsureUsageEvent(ctx, event); err != nil {
		t.Fatalf("idempotent retry: %v", err)
	}
	changed := event
	changedMetadata := *metadata
	changedMetadata.KID = "different"
	changed.RelayBlind = &changedMetadata
	if err := store.EnsureUsageEvent(ctx, changed); !errors.Is(err, storage.ErrUsageEventConflict) {
		t.Fatalf("metadata drift error=%v want ErrUsageEventConflict", err)
	}
}

func TestPlaintextSettlementKeepsRelayColumnsAtDefaults(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_plaintext_compat")
	now := fixedTime()
	if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
		AccountID: "acct_plaintext_compat", RequestID: "req_plaintext_compat", WindowDate: now.Format("2006-01-02"),
		RequestedTokens: 10, DailyQuota: 100, CreatedAt: now,
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.SettleReservation(ctx, storage.ReservationSettlement{
		AccountID: "acct_plaintext_compat", RequestID: "req_plaintext_compat", PromptTokens: 2, CompletionTokens: 3,
		TokenSource: "gateway_estimated", Outcome: "ok",
	}); err != nil {
		t.Fatal(err)
	}
	var requested string
	var inputCap int64
	if err := store.db.QueryRowContext(ctx, `SELECT requested_privacy_mode, input_token_upper_bound FROM usage_events
		WHERE account_id = ? AND request_id = ?`, "acct_plaintext_compat", "req_plaintext_compat").Scan(&requested, &inputCap); err != nil {
		t.Fatal(err)
	}
	if requested != "" || inputCap != 0 {
		t.Fatalf("plaintext relay defaults=%q/%d", requested, inputCap)
	}
}

func TestRelayBlindFallbackCandidateRoundTripsReservationMetadata(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_relay_candidate")
	now := fixedTime()
	metadata := relayBlindTestMetadata()
	if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
		AccountID: "acct_relay_candidate", RequestID: "req_relay_candidate", WindowDate: now.Format("2006-01-02"),
		RequestedTokens: 20, DailyQuota: 100, CreatedAt: now, ExpiresAt: now.Add(time.Minute), RelayBlind: metadata,
	}); err != nil {
		t.Fatal(err)
	}
	candidate := storage.SettlementFallbackCandidate{
		AccountID: "acct_relay_candidate", RequestID: "req_relay_candidate", RequiredInternalRequestID: "internal_relay_candidate",
		ReservationCreatedAt: now, WindowDate: now.Format("2006-01-02"), PromptTokens: 10, CompletionTokens: 9,
		MaxTotalTokens: 20, TokenSource: "provider_reported", Outcome: "ok",
	}
	if err := store.SaveSettlementFallbackCandidate(ctx, candidate); err != nil {
		t.Fatal(err)
	}
	got, err := store.LookupSettlementFallbackCandidate(ctx, storage.ActiveReservation{
		AccountID: candidate.AccountID, RequestID: candidate.RequestID, CreatedAt: now,
	})
	if err != nil {
		t.Fatal(err)
	}
	if got.PromptTokens != 4 || got.CompletionTokens != 3 || !reflect.DeepEqual(got.RelayBlind, metadata) {
		t.Fatalf("fallback candidate=%+v relay=%+v", got, got.RelayBlind)
	}
}

func TestRelayBlindSettlementAtMostOnceAcrossConcurrencyAndRestart(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "gateway.db")
	store, err := Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	createAccount(t, store, "acct_relay_once")
	now := fixedTime()
	metadata := relayBlindTestMetadata()
	if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
		AccountID: "acct_relay_once", RequestID: "req_relay_once", WindowDate: now.Format("2006-01-02"),
		RequestedTokens: 20, DailyQuota: 100, CreatedAt: now, RelayBlind: metadata,
	}); err != nil {
		t.Fatal(err)
	}
	settled := *metadata
	settled.EffectivePrivacyOutcome = "relay_blind_satisfied"
	settlement := storage.ReservationSettlement{
		AccountID: "acct_relay_once", RequestID: "req_relay_once", PromptTokens: 8, CompletionTokens: 8, TotalTokens: 16,
		MaxTotalTokens: 20, TokenSource: "provider_reported", Outcome: "ok", RelayBlind: &settled,
	}
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results <- store.SettleReservation(ctx, settlement)
		}()
	}
	wg.Wait()
	close(results)
	var succeeded, terminal int
	for err := range results {
		switch {
		case err == nil:
			succeeded++
		case errors.Is(err, storage.ErrReservationTerminal):
			terminal++
		default:
			t.Fatalf("concurrent settlement error=%v", err)
		}
	}
	if succeeded != 1 || terminal != 1 {
		t.Fatalf("settlement results success/terminal=%d/%d", succeeded, terminal)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.SettleReservation(ctx, settlement); !errors.Is(err, storage.ErrReservationTerminal) {
		t.Fatalf("post-restart settlement error=%v", err)
	}
	var rows int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM usage_events WHERE account_id = ? AND request_id = ?`,
		"acct_relay_once", "req_relay_once").Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 1 {
		t.Fatalf("usage rows=%d want 1", rows)
	}
}

func TestWalletRelayBlindSettlementUsesReservationCaps(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createWalletSession(t, store, "acct_wallet_relay", "ws_wallet_relay", 100, 20)
	metadata := relayBlindTestMetadata()
	admission := walletAdmission("acct_wallet_relay", "ws_wallet_relay", "req_wallet_relay", 20)
	admission.RelayBlind = metadata
	if _, err := store.AdmitWalletSessionInference(ctx, admission); err != nil {
		t.Fatal(err)
	}
	if err := store.ArmWalletSessionDispatch(ctx, storage.WalletSessionDispatchArm{
		SessionID: admission.SessionID, AccountID: admission.AccountID, RequestID: admission.RequestID,
		CanonicalRoute: admission.CanonicalRoute, ArmedAt: fixedTime().Add(time.Second),
	}); err != nil {
		t.Fatal(err)
	}
	var quotaStatus, replayState, walletStatus string
	var settlementHold int
	if err := store.db.QueryRowContext(ctx, `SELECT qr.status, qr.settlement_hold, r.state, sr.status
		FROM quota_reservations qr
		JOIN wallet_session_replays r ON r.session_id = ? AND r.request_id = qr.request_id
		JOIN wallet_session_reservations sr ON sr.session_id = r.session_id AND sr.request_id = r.request_id
		WHERE qr.account_id = ? AND qr.request_id = ?`, admission.SessionID, admission.AccountID, admission.RequestID).
		Scan(&quotaStatus, &settlementHold, &replayState, &walletStatus); err != nil {
		t.Fatal(err)
	}
	if quotaStatus != "active" || settlementHold != 1 || replayState != "dispatch_armed" || walletStatus != "active" {
		t.Fatalf("armed quota/hold/replay/wallet=%s/%d/%s/%s want active/1/dispatch_armed/active",
			quotaStatus, settlementHold, replayState, walletStatus)
	}
	if err := store.MarkWalletSessionDispatched(ctx, admission.SessionID, admission.RequestID, fixedTime().Add(2*time.Second)); err != nil {
		t.Fatal(err)
	}
	settled := *metadata
	settled.EffectivePrivacyOutcome = "relay_blind_satisfied"
	if err := store.FinalizeWalletSessionReservation(ctx, storage.WalletSessionReservationSettlement{
		SessionID: admission.SessionID, AccountID: admission.AccountID, RequestID: admission.RequestID,
		PromptTokens: 10, CompletionTokens: 10, TotalTokens: 20, MaxTotalTokens: 20,
		TokenSource: "provider_reported", Outcome: "ok", RelayBlind: &settled,
	}); err != nil {
		t.Fatal(err)
	}
	var prompt, completion, total int64
	if err := store.db.QueryRowContext(ctx, `SELECT prompt_tokens, completion_tokens, total_tokens FROM usage_events
		WHERE account_id = ? AND request_id = ?`, admission.AccountID, admission.RequestID).Scan(&prompt, &completion, &total); err != nil {
		t.Fatal(err)
	}
	if prompt != 4 || completion != 3 || total != 7 {
		t.Fatalf("wallet settled tokens=%d/%d/%d want 4/3/7", prompt, completion, total)
	}
	if err := store.db.QueryRowContext(ctx, `SELECT qr.status, qr.settlement_hold, r.state, sr.status
		FROM quota_reservations qr
		JOIN wallet_session_replays r ON r.session_id = ? AND r.request_id = qr.request_id
		JOIN wallet_session_reservations sr ON sr.session_id = r.session_id AND sr.request_id = r.request_id
		WHERE qr.account_id = ? AND qr.request_id = ?`, admission.SessionID, admission.AccountID, admission.RequestID).
		Scan(&quotaStatus, &settlementHold, &replayState, &walletStatus); err != nil {
		t.Fatal(err)
	}
	if quotaStatus != "settled" || settlementHold != 0 || replayState != "finalized" || walletStatus != "settled" {
		t.Fatalf("final quota/hold/replay/wallet=%s/%d/%s/%s want settled/0/finalized/settled",
			quotaStatus, settlementHold, replayState, walletStatus)
	}
}

func TestWalletRelayBlindDispatchArmDurablyHoldsQuotaAcrossRestart(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "gateway.db")
	store, err := Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	createWalletSession(t, store, "acct_wallet_relay_crash", "ws_wallet_relay_crash", 100, 20)
	admission := walletAdmission("acct_wallet_relay_crash", "ws_wallet_relay_crash", "req_wallet_relay_crash", 20)
	admission.RelayBlind = relayBlindTestMetadata()
	if _, err := store.AdmitWalletSessionInference(ctx, admission); err != nil {
		t.Fatal(err)
	}
	if err := store.ArmWalletSessionDispatch(ctx, storage.WalletSessionDispatchArm{
		SessionID: admission.SessionID, AccountID: admission.AccountID, RequestID: admission.RequestID,
		CanonicalRoute: admission.CanonicalRoute, ArmedAt: fixedTime().Add(time.Second),
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	held, err := store.ListSettlementHeldReservations(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(held) != 1 || held[0].RequestID != admission.RequestID || held[0].WalletSessionID != admission.SessionID ||
		held[0].RelayBlind == nil || held[0].RelayBlind.EnvelopeDigest != admission.RelayBlind.EnvelopeDigest {
		t.Fatalf("held reservations after restart=%+v", held)
	}
	var replayState, walletStatus string
	if err := store.db.QueryRowContext(ctx, `SELECT r.state, sr.status
		FROM wallet_session_replays r JOIN wallet_session_reservations sr
		ON sr.session_id = r.session_id AND sr.request_id = r.request_id
		WHERE r.session_id = ? AND r.request_id = ?`, admission.SessionID, admission.RequestID).Scan(&replayState, &walletStatus); err != nil {
		t.Fatal(err)
	}
	if replayState != "dispatch_armed" || walletStatus != "active" {
		t.Fatalf("restart replay/wallet=%s/%s want dispatch_armed/active", replayState, walletStatus)
	}
}

func TestRelayBlindAPIPredispatchHoldSurvivesRestart(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "gateway.db")
	store, err := Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	createAccount(t, store, "acct_relay_api_crash")
	now := fixedTime()
	metadata := relayBlindTestMetadata()
	if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
		AccountID: "acct_relay_api_crash", RequestID: "req_relay_api_crash", WindowDate: now.Format("2006-01-02"),
		RequestedTokens: 20, DailyQuota: 100, CreatedAt: now, ExpiresAt: now.Add(time.Minute), RelayBlind: metadata,
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.MarkReservationSettlementHold(ctx, "acct_relay_api_crash", "req_relay_api_crash"); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	held, err := store.ListSettlementHeldReservations(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(held) != 1 || held[0].AccountID != "acct_relay_api_crash" || held[0].RequestID != "req_relay_api_crash" ||
		held[0].WalletSessionID != "" || !reflect.DeepEqual(held[0].RelayBlind, metadata) {
		t.Fatalf("API held reservation after restart=%+v", held)
	}
	settled := *metadata
	settled.EffectivePrivacyOutcome = "relay_blind_satisfied"
	if err := store.SettleReservation(ctx, storage.ReservationSettlement{
		AccountID: "acct_relay_api_crash", RequestID: "req_relay_api_crash", PromptTokens: 8, CompletionTokens: 6,
		TotalTokens: 14, MaxTotalTokens: 20, TokenSource: "provider_reported", Outcome: "ok", RelayBlind: &settled,
	}); err != nil {
		t.Fatal(err)
	}
	var status string
	var settlementHold int
	if err := store.db.QueryRowContext(ctx, `SELECT status, settlement_hold FROM quota_reservations
		WHERE account_id = ? AND request_id = ?`, "acct_relay_api_crash", "req_relay_api_crash").Scan(&status, &settlementHold); err != nil {
		t.Fatal(err)
	}
	if status != "settled" || settlementHold != 0 {
		t.Fatalf("API final status/hold=%s/%d want settled/0", status, settlementHold)
	}
}

func TestPlaintextWalletDispatchArmKeepsExistingQuotaBehavior(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createWalletSession(t, store, "acct_wallet_plain_arm", "ws_wallet_plain_arm", 100, 20)
	admission := walletAdmission("acct_wallet_plain_arm", "ws_wallet_plain_arm", "req_wallet_plain_arm", 20)
	if _, err := store.AdmitWalletSessionInference(ctx, admission); err != nil {
		t.Fatal(err)
	}
	if err := store.ArmWalletSessionDispatch(ctx, storage.WalletSessionDispatchArm{
		SessionID: admission.SessionID, AccountID: admission.AccountID, RequestID: admission.RequestID,
		CanonicalRoute: admission.CanonicalRoute, ArmedAt: fixedTime().Add(time.Second),
	}); err != nil {
		t.Fatal(err)
	}
	var settlementHold int
	if err := store.db.QueryRowContext(ctx, `SELECT settlement_hold FROM quota_reservations
		WHERE account_id = ? AND request_id = ?`, admission.AccountID, admission.RequestID).Scan(&settlementHold); err != nil {
		t.Fatal(err)
	}
	if settlementHold != 0 {
		t.Fatalf("plaintext settlement_hold=%d want 0", settlementHold)
	}
}

func TestRelayBlindStoredPrivacyEnumsFailClosed(t *testing.T) {
	for _, mode := range []string{"required", "none", "plaintext", ""} {
		metadata := relayBlindTestMetadata()
		metadata.RequestedPrivacyMode = mode
		if validateRelayBlind(metadata) == nil {
			t.Errorf("accepted noncanonical requested mode %q", mode)
		}
	}
	metadata := relayBlindTestMetadata()
	metadata.EffectivePrivacyOutcome = "plaintext"
	if validateRelayBlind(metadata) == nil {
		t.Fatal("accepted plaintext outcome for required relay-blind reservation")
	}
}
