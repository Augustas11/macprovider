package ws_test

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"path/filepath"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
)

// selfServeHarness centralizes the settling-window posture for FR-C9:
// token store wired (for mint) AND require_provider_tokens=false (so
// tokenless provisional connects survive validateProviderToken). The
// default harness ships RequireProviderTokens=true when a validator is
// provided, which is the post-flag-flip posture — wrong for these tests.
func selfServeHarness(t *testing.T, store *auth.Store) providerHarness {
	t.Helper()
	return newProviderHarnessWithTokenValidator(t, store, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = false
	})
}

// SPEC-003 v0.8 FR-C9.1 / FR-C9.2 — tokenless provisional admission
// MUST result in a freshly-minted row in provider_tokens AND the v1
// hello_ack frame MUST carry the cleartext under
// assigned_provider_token. Without the mint hook this test fails:
// pre-fix the field is "" (no mint), no DB row is created, and the
// binary has no way to acquire a token through open onboarding.
func TestSelfServeProvisionalTokenMintedOnHelloAck(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	h := selfServeHarness(t, store)
	defer h.HTTP.Close()

	// No Bearer header — provisional path.
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial tokenless: %v", err)
	}
	defer conn.Close()

	if err := wsutil.WriteClientText(conn, mustJSON(validHello("self-serve-provider"))); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read ack: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}

	var ack providerws.HelloAck
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("ack json: %v", err)
	}
	if ack.Type != "hello_ack" {
		t.Fatalf("ack type = %q, want hello_ack", ack.Type)
	}
	if ack.AssignedProviderToken == "" {
		t.Fatalf("assigned_provider_token empty in hello_ack: %#v", ack)
	}
	if len(ack.AssignedProviderToken) != 64 {
		t.Fatalf("assigned_provider_token len = %d, want 64 hex chars: %q", len(ack.AssignedProviderToken), ack.AssignedProviderToken)
	}

	// The cleartext returned to the binary MUST validate through the
	// same store and resolve back to the declared provider_id.
	providerID, ok, err := store.ValidateToken(context.Background(), ack.AssignedProviderToken)
	if err != nil {
		t.Fatalf("validate self-minted token: %v", err)
	}
	if !ok {
		t.Fatalf("self-minted token did not validate")
	}
	if providerID != "self-serve-provider" {
		t.Fatalf("validated provider_id = %q, want self-serve-provider", providerID)
	}

	// Exactly one row should exist after a single tokenless admission.
	records, err := store.ListTokens(context.Background())
	if err != nil {
		t.Fatalf("list tokens: %v", err)
	}
	if len(records) != 1 {
		t.Fatalf("token rows = %d, want 1: %#v", len(records), records)
	}
	if records[0].ProviderID != "self-serve-provider" {
		t.Fatalf("row provider_id = %q, want self-serve-provider", records[0].ProviderID)
	}
}

func TestProviderTokenBootstrapMintsWhenTokensRequired(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	h := newProviderHarnessWithTokenValidator(t, store, func(cfg *config.Config) {
		cfg.Providers = nil
		cfg.Auth.RequireProviderTokens = true
		cfg.Auth.AllowTokenlessProvisionalBootstrap = true
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial tokenless bootstrap: %v", err)
	}
	defer conn.Close()

	if err := wsutil.WriteClientText(conn, mustJSON(validHello("bootstrap-provider"))); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read bootstrap ack: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}

	var ack providerws.HelloAck
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("ack json: %v", err)
	}
	if ack.AssignedProviderToken == "" {
		t.Fatalf("assigned_provider_token empty in bootstrap hello_ack: %#v", ack)
	}
	providerID, ok, err := store.ValidateToken(context.Background(), ack.AssignedProviderToken)
	if err != nil || !ok || providerID != "bootstrap-provider" {
		t.Fatalf("bootstrap token validation: provider_id=%q ok=%v err=%v", providerID, ok, err)
	}
	provider, ok := h.Registry.Resolve("bootstrap-provider", ack.AssignedID)
	if !ok {
		t.Fatalf("registry has no entry for assigned_id %q after bootstrap", ack.AssignedID)
	}
	if provider.AuthState != pool.AuthSelfMinted {
		t.Fatalf("bootstrap auth_state = %q, want %q", provider.AuthState, pool.AuthSelfMinted)
	}
}

func TestProviderTokenBootstrapRejectsPinnedTokenlessProvider(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	h := newProviderHarnessWithTokenValidator(t, store, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = true
		cfg.Auth.AllowTokenlessProvisionalBootstrap = true
	})
	defer h.HTTP.Close()

	code, reason := sendHelloExpectClose(t, h.HTTP.URL, validHello("m4-anon"))
	if code != providerws.CloseInvalidToken || reason != "invalid_token" {
		t.Fatalf("close = %d %q, want %d invalid_token", code, reason, providerws.CloseInvalidToken)
	}
	records, err := store.ListTokens(context.Background())
	if err != nil {
		t.Fatalf("list tokens: %v", err)
	}
	if len(records) != 0 {
		t.Fatalf("token rows after pinned reject = %d, want 0: %#v", len(records), records)
	}
}

func TestProviderTokenBootstrapFallsBackWhenPairOTCompoundMintFails(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	if _, err := store.DB().ExecContext(context.Background(), `DROP TABLE pair_ots`); err != nil {
		t.Fatalf("drop pair_ots: %v", err)
	}

	var logBuffer lockedBuffer
	h := newProviderHarnessWithServerOptionsAndLogger(
		t,
		store,
		[]providerws.Option{providerws.WithGitHubAuthStore(store)},
		zerolog.New(&logBuffer),
		func(cfg *config.Config) {
			cfg.Providers = nil
			cfg.Auth.RequireProviderTokens = true
			cfg.Auth.AllowTokenlessProvisionalBootstrap = true
			cfg.Auth.GitHubOAuth.Enabled = true
		},
	)
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial tokenless bootstrap: %v", err)
	}
	defer conn.Close()

	if err := wsutil.WriteClientText(conn, mustJSON(validHello("pair-fallback-provider"))); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read fallback ack: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}

	var ack providerws.HelloAck
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("ack json: %v", err)
	}
	if ack.AssignedProviderToken == "" {
		t.Fatalf("assigned_provider_token empty after pair-OT fallback: %#v", ack)
	}
	if ack.PairOT != "" || ack.ClaimURL != "" {
		t.Fatalf("pairing fields should be omitted after pair-OT fallback: pair_ot=%q claim_url=%q", ack.PairOT, ack.ClaimURL)
	}
	providerID, ok, err := store.ValidateToken(context.Background(), ack.AssignedProviderToken)
	if err != nil || !ok || providerID != "pair-fallback-provider" {
		t.Fatalf("fallback token validation: provider_id=%q ok=%v err=%v", providerID, ok, err)
	}
	if logs := logBuffer.String(); !strings.Contains(logs, "FR-C10 pair_ot compound mint failed; falling back to plain FR-C9 provider token mint") {
		t.Fatalf("fallback warning not logged: %s", logs)
	}
}

// SPEC-003 v0.8 FR-C9.1 — when a valid Bearer is presented, the
// coordinator MUST NOT mint a duplicate. The ack MUST omit the field.
func TestSelfServeProvisionalTokenNotMintedWhenBearerValidated(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	_, token, err := store.IssueToken(context.Background(), "self-serve-provider", "test provider")
	if err != nil {
		t.Fatalf("seed token: %v", err)
	}
	h := selfServeHarness(t, store)
	defer h.HTTP.Close()

	conn, _, _, err := bearerDialer(token).Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial with bearer: %v", err)
	}
	defer conn.Close()

	if err := wsutil.WriteClientText(conn, mustJSON(validHello("self-serve-provider"))); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, _, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read ack: %v", err)
	}
	var ack providerws.HelloAck
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("ack json: %v", err)
	}
	if ack.AssignedProviderToken != "" {
		t.Fatalf("assigned_provider_token = %q, want empty when bearer validated", ack.AssignedProviderToken)
	}
	records, err := store.ListTokens(context.Background())
	if err != nil {
		t.Fatalf("list tokens: %v", err)
	}
	if len(records) != 1 {
		t.Fatalf("token rows = %d, want 1 (no new mint): %#v", len(records), records)
	}
}

// mintFailingStore wraps *auth.Store and forces IssueToken to fail so
// we can exercise the FR-C9.1 mint-failure tolerance branch without
// closing the DB out from under the rest of the harness.
type mintFailingStore struct {
	*auth.Store
}

func (m mintFailingStore) IssueToken(ctx context.Context, providerID, providerName string) (auth.TokenRecord, string, error) {
	return auth.TokenRecord{}, "", errors.New("synthetic mint failure")
}

type validatorOnlyStore struct {
	store *auth.Store
}

func (v validatorOnlyStore) ValidateToken(ctx context.Context, token string) (string, bool, error) {
	return v.store.ValidateToken(ctx, token)
}

func (v validatorOnlyStore) MarkTokenUsed(ctx context.Context, token string) error {
	return v.store.MarkTokenUsed(ctx, token)
}

func (v validatorOnlyStore) ValidateAndMarkTokenUsed(ctx context.Context, token string) (string, bool, error) {
	return v.store.ValidateAndMarkTokenUsed(ctx, token)
}

func TestProviderTokenBootstrapFailsClosedWithoutIssuer(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	h := newProviderHarnessWithTokenValidator(t, validatorOnlyStore{store: store}, func(cfg *config.Config) {
		cfg.Providers = nil
		cfg.Auth.RequireProviderTokens = true
		cfg.Auth.AllowTokenlessProvisionalBootstrap = true
	})
	defer h.HTTP.Close()

	code, reason := sendHelloExpectClose(t, h.HTTP.URL, validHello("miswired-bootstrap"))
	if code != providerws.CloseInvalidToken || reason != "invalid_token" {
		t.Fatalf("close = %d %q, want %d invalid_token", code, reason, providerws.CloseInvalidToken)
	}
	records, err := store.ListTokens(context.Background())
	if err != nil {
		t.Fatalf("list tokens: %v", err)
	}
	if len(records) != 0 {
		t.Fatalf("token rows after issuer-missing reject = %d, want 0: %#v", len(records), records)
	}
}

// SPEC-003 v0.8.4 FR-C9.1 (fix-pass-5 G) — mint failure on a transient
// DB error MUST fail-closed with CloseInvalidToken / "invalid_token".
//
// Pre-fix-pass-5 this case admitted-tokenless and the binary retried on
// next reconnect. The codex security audit on the v0.8.4 composition
// (MAJOR-1) flagged that the empty `AuthState` returned in the
// admit-tokenless path was treated as routable, amplifying a DB-error
// storm into a routing-admission DoS. fix-pass-5 G closes that by
// returning provisionalTokenRejectTOFU + AuthMintFailed so the v1/v2
// ack sites close the connection instead of registering an empty-state
// routable session.
//
// The binary still recovers cleanly: no row was written (the mint
// failed), so the next reconnect re-enters resolveProvisionalToken at
// step 1 with no row in the DB and proceeds to mint normally.
func TestSelfServeProvisionalTokenMintFailureFailsClosed(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	h := newProviderHarnessWithTokenValidator(t, mintFailingStore{Store: store}, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = false
	})
	defer h.HTTP.Close()

	conn, br, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial tokenless: %v", err)
	}
	defer conn.Close()

	if err := wsutil.WriteClientText(conn, mustJSON(validHello("flaky-mint-provider"))); err != nil {
		t.Fatalf("write hello: %v", err)
	}

	// MUST receive a close frame, not a hello_ack.
	var src io.Reader = conn
	if br != nil {
		src = br
	}
	frame, err := gobwas.ReadFrame(src)
	if err != nil {
		t.Fatalf("read mint-failure close: %v", err)
	}
	if frame.Header.OpCode != gobwas.OpClose {
		t.Fatalf("op = %v, want close (fix-pass-5 fail-closed on transient DB error)", frame.Header.OpCode)
	}
	code, reason := gobwas.ParseCloseFrameData(frame.Payload)
	if code != providerws.CloseInvalidToken || reason != "invalid_token" {
		t.Fatalf("close = %d %q, want %d invalid_token (FR-C9.1 fail-closed)", code, reason, providerws.CloseInvalidToken)
	}

	// DB invariant: no row written (mint failed).
	records, err := store.ListTokens(context.Background())
	if err != nil {
		t.Fatalf("list tokens: %v", err)
	}
	for _, r := range records {
		if r.ProviderID == "flaky-mint-provider" && !r.RevokedAt.Valid {
			t.Fatalf("unexpected active row for flaky-mint-provider after fail-closed mint: %#v", r)
		}
	}
}

// SPEC-003 v0.8.4 FR-C9.4 unused-token self-heal — when an active row
// exists for a provider_id but its last_used_at IS NULL (never
// authenticated), the coordinator MUST revoke that row and mint a
// fresh token for the incoming tokenless connect instead of
// rejecting. Closes the deploy-gap lockout class that hit `air5` on
// the 2026-06-12 production deploy: a provider minted a token under
// the new coordinator but reconnected before consuming the ack
// frame, and v0.8.2's blanket TOFU policy locked them out
// indefinitely. The codex MAJOR-1 credential-capture vector that
// v0.8.1 closed requires the attacker to have authenticated at
// least once (which sets last_used_at) — an unused row carries no
// live credential, so self-heal does not weaken the security model.
// Pre-v0.8.3 this test asserted strict rejection; the new contract
// is in DECISION_CRITERIA Entry 67.
func TestSelfServeProvisionalTokenSelfHealsWhenExistingTokenUnused(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	// Seed: a legitimate provider self-minted on a prior connect but
	// never used the token (the deploy-gap pattern: minted, persisted
	// or not, but ack-frame not consumed by the old binary in flight).
	seedRecord, seedCleartext, err := store.IssueToken(context.Background(), "claimed-provider", "claimed-provider hostname")
	if err != nil {
		t.Fatalf("seed unused token: %v", err)
	}
	if seedCleartext == "" {
		t.Fatalf("seed cleartext empty")
	}
	h := selfServeHarness(t, store)
	defer h.HTTP.Close()

	// The same provider_id reconnects tokenless (binary lost the
	// ack-frame's assigned_provider_token across a coordinator
	// restart, or never persisted it). Self-heal should kick in.
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial tokenless reconnect: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(validHello("claimed-provider"))); err != nil {
		t.Fatalf("write hello: %v", err)
	}

	// Self-heal path: the ack frame should arrive normally with a NEW
	// assigned_provider_token, not a close frame.
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read self-heal ack: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text (self-heal ack), not close (legacy strict reject)", op)
	}
	var ack providerws.HelloAck
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("ack json: %v", err)
	}
	if ack.Type != "hello_ack" {
		t.Fatalf("ack type = %q, want hello_ack", ack.Type)
	}
	if ack.AssignedProviderToken == "" {
		t.Fatalf("assigned_provider_token empty in self-heal hello_ack: %#v", ack)
	}
	if ack.AssignedProviderToken == seedCleartext {
		t.Fatalf("self-heal ack returned the SAME cleartext as the seed; expected a freshly minted token")
	}

	// DB invariant: the seed row is revoked, exactly one active row
	// remains (the fresh mint), and the fresh row resolves to the
	// declared provider_id.
	records, err := store.ListTokens(context.Background())
	if err != nil {
		t.Fatalf("list tokens: %v", err)
	}
	if len(records) != 2 {
		t.Fatalf("token rows after self-heal = %d, want 2 (revoked seed + fresh mint): %#v", len(records), records)
	}
	var seedRow, freshRow *auth.TokenRecord
	for i := range records {
		r := records[i]
		if r.ID == seedRecord.ID {
			cp := r
			seedRow = &cp
		} else {
			cp := r
			freshRow = &cp
		}
	}
	if seedRow == nil || freshRow == nil {
		t.Fatalf("could not classify rows: seed=%v fresh=%v records=%#v", seedRow, freshRow, records)
	}
	if !seedRow.RevokedAt.Valid {
		t.Fatalf("seed row should be revoked after self-heal; revoked_at=%v", seedRow.RevokedAt)
	}
	if freshRow.RevokedAt.Valid {
		t.Fatalf("fresh row should be active after self-heal; revoked_at=%v", freshRow.RevokedAt)
	}
	if freshRow.ProviderID != "claimed-provider" {
		t.Fatalf("fresh row provider_id = %q, want claimed-provider", freshRow.ProviderID)
	}
	providerID, ok, err := store.ValidateToken(context.Background(), ack.AssignedProviderToken)
	if err != nil || !ok || providerID != "claimed-provider" {
		t.Fatalf("self-heal token validation: id=%q ok=%v err=%v (want claimed-provider true nil)", providerID, ok, err)
	}

	// Composition with PR #69 (v0.8.4 fix-pass): the self-healed
	// session is admitted with a freshly-minted token, so its
	// AuthState MUST be AuthSelfMinted — fully routable, no
	// quarantine. The bearer-less duplicate path is for the
	// IssueToken race-loss case, not the self-heal path.
	provider, ok := h.Registry.Resolve("claimed-provider", ack.AssignedID)
	if !ok {
		t.Fatalf("registry has no entry for assigned_id %q after self-heal", ack.AssignedID)
	}
	if provider.AuthState != pool.AuthSelfMinted {
		t.Fatalf("self-heal auth_state = %q, want %q (self-mint must mark routable, not quarantined)", provider.AuthState, pool.AuthSelfMinted)
	}
}

// SPEC-003 v0.8.4 FR-C9.4 strict-reject — the security path. When
// the active row's last_used_at IS NOT NULL the codex MAJOR-1
// credential-capture vector applies in full: the row represents a
// live credential. A tokenless reconnect for that provider_id MUST
// be rejected with CloseInvalidToken / "invalid_token" and the
// operator runbook applies (revoke-token + retry). This test
// preserves the v0.8.1 strict-reject behavior for the
// used-token-tokenless-reconnect shape.
func TestSelfServeProvisionalTokenRejectedWhenExistingTokenUsed(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	// Seed: a legitimate provider self-minted AND used the token at
	// least once (the row's last_used_at is NOT NULL). This is the
	// shape an attacker would also produce after capturing-and-using
	// a victim's bearer.
	_, seedCleartext, err := store.IssueToken(context.Background(), "claimed-provider", "claimed-provider hostname")
	if err != nil {
		t.Fatalf("seed token: %v", err)
	}
	if err := store.MarkTokenUsed(context.Background(), seedCleartext); err != nil {
		t.Fatalf("mark seed used: %v", err)
	}
	h := selfServeHarness(t, store)
	defer h.HTTP.Close()

	// A tokenless connect declaring the SAME provider_id arrives.
	// This is indistinguishable from an attacker trying to mint a
	// parallel credential for the in-use identity, so strict reject.
	conn, br, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial tokenless: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(validHello("claimed-provider"))); err != nil {
		t.Fatalf("write hello: %v", err)
	}

	var src io.Reader = conn
	if br != nil {
		src = br
	}
	frame, err := gobwas.ReadFrame(src)
	if err != nil {
		t.Fatalf("read tofu close: %v", err)
	}
	if frame.Header.OpCode != gobwas.OpClose {
		t.Fatalf("op = %v, want close (TOFU strict reject)", frame.Header.OpCode)
	}
	code, reason := gobwas.ParseCloseFrameData(frame.Payload)
	if code != providerws.CloseInvalidToken || reason != "invalid_token" {
		t.Fatalf("close = %d %q, want %d invalid_token (FR-C9.4 strict reject)", code, reason, providerws.CloseInvalidToken)
	}

	// Critically: no NEW row was minted AND the seed row is still
	// active (NOT auto-revoked, since it has last_used_at NOT NULL).
	records, err := store.ListTokens(context.Background())
	if err != nil {
		t.Fatalf("list tokens: %v", err)
	}
	if len(records) != 1 {
		t.Fatalf("token rows after strict reject = %d, want 1 (no parallel mint, no self-heal on used token): %#v", len(records), records)
	}
	if records[0].RevokedAt.Valid {
		t.Fatalf("seed row should remain active after strict reject; revoked_at=%v", records[0].RevokedAt)
	}
}

func TestProviderTokenBootstrapRejectsTokenlessWhenExistingTokenUsed(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	_, seedCleartext, err := store.IssueToken(context.Background(), "claimed-provider", "claimed-provider hostname")
	if err != nil {
		t.Fatalf("seed token: %v", err)
	}
	if err := store.MarkTokenUsed(context.Background(), seedCleartext); err != nil {
		t.Fatalf("mark seed used: %v", err)
	}
	h := newProviderHarnessWithTokenValidator(t, store, func(cfg *config.Config) {
		cfg.Providers = nil
		cfg.Auth.RequireProviderTokens = true
		cfg.Auth.AllowTokenlessProvisionalBootstrap = true
	})
	defer h.HTTP.Close()

	conn, br, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial tokenless bootstrap: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(validHello("claimed-provider"))); err != nil {
		t.Fatalf("write hello: %v", err)
	}

	var src io.Reader = conn
	if br != nil {
		src = br
	}
	frame, err := gobwas.ReadFrame(src)
	if err != nil {
		t.Fatalf("read tofu close: %v", err)
	}
	if frame.Header.OpCode != gobwas.OpClose {
		t.Fatalf("op = %v, want close", frame.Header.OpCode)
	}
	code, reason := gobwas.ParseCloseFrameData(frame.Payload)
	if code != providerws.CloseInvalidToken || reason != "invalid_token" {
		t.Fatalf("close = %d %q, want %d invalid_token", code, reason, providerws.CloseInvalidToken)
	}

	records, err := store.ListTokens(context.Background())
	if err != nil {
		t.Fatalf("list tokens: %v", err)
	}
	if len(records) != 1 {
		t.Fatalf("token rows after strict reject = %d, want 1: %#v", len(records), records)
	}
	if records[0].RevokedAt.Valid {
		t.Fatalf("seed row should remain active after strict reject; revoked_at=%v", records[0].RevokedAt)
	}
}

// SPEC-003 v0.8.4 (fix-pass-5) — DOCUMENTED BRANCH CHANGE.
//
// This test originally exercised the pool-registry eviction defense
// (PR #69 fix-pass-3 codex security MAJOR-1): an attacker tokenless
// connect with AuthBearerlessDuplicate marking would reach
// pool.Registry.Register, and the defense would refuse to evict the
// legitimate session.
//
// Under v0.8.4 (composition with PR #78), the legitimate Bearer
// connect's atomic ValidateAndMarkTokenUsed stamps last_used_at at WS
// upgrade. By the time the attacker's tokenless connect reaches
// resolveProvisionalToken, RevokeUnusedTokenForProvider returns false
// (row is not NULL), HasActiveTokenForProvider returns true, and the
// attacker is closed via STRICT TOFU REJECT — before any Register call
// is made.
//
// The test still proves the right end-state property (attacker closed,
// legitimate session preserved, AuthBearerValidated positively locked),
// but the fired layer is the strict-reject path, not the registry
// eviction defense. The registry defense is now exercised directly by
// TestRegistryRefusesBearerlessDuplicateReplacement in the pool
// package.
func TestSelfServeProvisionalTokenStrictRejectPreservesRoutableSession(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	// Seed: legitimate provider already minted (or was issued a token).
	// They've reconnected with a valid Bearer (modeled via the store
	// holding a row + later seeding the registry directly).
	_, legitToken, err := store.IssueToken(context.Background(), "claimed-provider", "claimed-provider hostname")
	if err != nil {
		t.Fatalf("seed token: %v", err)
	}
	h := selfServeHarness(t, store)
	defer h.HTTP.Close()

	// Step 1: legitimate provider connects with the Bearer. The
	// existing harness behavior admits + registers as a routable
	// session.
	legitConn, _, _, err := bearerDialer(legitToken).Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial legitimate: %v", err)
	}
	defer legitConn.Close()
	if err := wsutil.WriteClientText(legitConn, mustJSON(validHello("claimed-provider"))); err != nil {
		t.Fatalf("write legit hello: %v", err)
	}
	legitPayload, _, err := wsutil.ReadServerData(legitConn)
	if err != nil {
		t.Fatalf("read legit hello_ack: %v", err)
	}
	var legitAck providerws.HelloAck
	if err := json.Unmarshal(legitPayload, &legitAck); err != nil {
		t.Fatalf("legit ack json: %v", err)
	}
	legitAssigned := legitAck.AssignedID
	if legitAssigned == "" {
		t.Fatal("legitimate provider: empty assigned_id in hello_ack")
	}

	// Step 2: attacker (or confused racer) connects tokenless declaring
	// the SAME provider_id.
	attackerConn, br, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial attacker tokenless: %v", err)
	}
	defer attackerConn.Close()
	if err := wsutil.WriteClientText(attackerConn, mustJSON(validHello("claimed-provider"))); err != nil {
		t.Fatalf("write attacker hello: %v", err)
	}
	// The attacker connect MUST be closed with CloseInvalidToken —
	// eviction defense kicked in.
	var src io.Reader = attackerConn
	if br != nil {
		src = br
	}
	frame, err := gobwas.ReadFrame(src)
	if err != nil {
		t.Fatalf("read attacker close: %v", err)
	}
	if frame.Header.OpCode != gobwas.OpClose {
		t.Fatalf("attacker op = %v, want close (eviction defense)", frame.Header.OpCode)
	}
	code, reason := gobwas.ParseCloseFrameData(frame.Payload)
	if code != providerws.CloseInvalidToken || reason != "invalid_token" {
		t.Fatalf("attacker close = %d %q, want %d invalid_token (FR-C9.4 eviction defense)", code, reason, providerws.CloseInvalidToken)
	}

	// Step 3: legitimate provider's session MUST still be registered,
	// with the original assigned_id. The pool resolves on the original
	// session, and that session is routing-eligible (modulo State/slots
	// which depend on hello timing — we only assert presence here).
	legit, ok := h.Registry.Resolve("claimed-provider", legitAssigned)
	if !ok {
		t.Fatalf("legitimate session evicted (registry has no entry for assigned_id %q): eviction defense failed", legitAssigned)
	}
	// fix-pass-4 (code MINOR-1): positively lock the Bearer-validated state.
	// The prior assertion only checked the negation (not AuthBearerlessDuplicate);
	// future regressions could land an empty AuthState (pre-FR-C9 conflation)
	// and still pass. The legitimate Bearer-token connect MUST resolve to
	// AuthBearerValidated.
	if legit.AuthState != pool.AuthBearerValidated {
		t.Fatalf("legitimate auth_state = %q, want %q (Bearer-validated must be positively locked, not just non-duplicate)",
			legit.AuthState, pool.AuthBearerValidated)
	}
}

// SPEC-003 v0.8 FR-C9.2 (v2 path) — the proof-stage-accepted
// auth_response MUST carry assigned_provider_token for a tokenless
// provisional v2 connect. Mirrors TestSelfServeProvisionalTokenMintedOnHelloAck
// across the v2 ECDH handshake. Codex code-reviewer / architect on
// PR #44 flagged that only the v1 path had regression coverage.
func TestSelfServeProvisionalTokenMintedOnAuthResponseV2(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	h := newProviderHarnessWithTokenValidator(t, store, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = false
		// Drop the default pinned provider so "v2-self-serve" is treated
		// as provisional.
		cfg.Providers = nil
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial tokenless v2: %v", err)
	}
	defer conn.Close()

	_, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("keypair: %v", err)
	}
	providerPublic := base64.RawURLEncoding.EncodeToString(providerPublicRaw)
	if err := wsutil.WriteClientText(conn, mustJSON(validAuthInitial("v2-self-serve", providerPublic))); err != nil {
		t.Fatalf("write auth_request initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	writeAuthProof(t, conn, challenge, "v2-self-serve", nil)
	response := readAuthResponse(t, conn)

	if response.Status != "accepted" {
		t.Fatalf("auth_response.status = %q, want accepted: %+v", response.Status, response)
	}
	if response.AssignedProviderToken == "" {
		t.Fatalf("v2 auth_response.assigned_provider_token empty; want minted token: %+v", response)
	}
	if len(response.AssignedProviderToken) != 64 {
		t.Fatalf("v2 token length = %d, want 64 hex chars: %q", len(response.AssignedProviderToken), response.AssignedProviderToken)
	}

	providerID, ok, err := store.ValidateToken(context.Background(), response.AssignedProviderToken)
	if err != nil {
		t.Fatalf("validate v2-minted token: %v", err)
	}
	if !ok || providerID != "v2-self-serve" {
		t.Fatalf("validated provider_id = %q ok=%v, want v2-self-serve true", providerID, ok)
	}
}

func TestProviderTokenBootstrapMintsOnAuthResponseV2WhenTokensRequired(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	h := newProviderHarnessWithTokenValidator(t, store, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = true
		cfg.Auth.AllowTokenlessProvisionalBootstrap = true
		cfg.Providers = nil
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial tokenless v2 bootstrap: %v", err)
	}
	defer conn.Close()

	_, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("keypair: %v", err)
	}
	providerPublic := base64.RawURLEncoding.EncodeToString(providerPublicRaw)
	if err := wsutil.WriteClientText(conn, mustJSON(validAuthInitial("v2-bootstrap", providerPublic))); err != nil {
		t.Fatalf("write auth_request initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	writeAuthProof(t, conn, challenge, "v2-bootstrap", nil)
	response := readAuthResponse(t, conn)

	if response.Status != "accepted" {
		t.Fatalf("auth_response.status = %q, want accepted: %+v", response.Status, response)
	}
	if response.AssignedProviderToken == "" {
		t.Fatalf("v2 bootstrap auth_response.assigned_provider_token empty: %+v", response)
	}
	providerID, ok, err := store.ValidateToken(context.Background(), response.AssignedProviderToken)
	if err != nil || !ok || providerID != "v2-bootstrap" {
		t.Fatalf("v2 bootstrap token validation: provider_id=%q ok=%v err=%v", providerID, ok, err)
	}
	provider, ok := h.Registry.Resolve("v2-bootstrap", response.AssignedID)
	if !ok {
		t.Fatalf("registry has no entry for assigned_id %q after v2 bootstrap", response.AssignedID)
	}
	if provider.AuthState != pool.AuthSelfMinted {
		t.Fatalf("v2 bootstrap auth_state = %q, want %q", provider.AuthState, pool.AuthSelfMinted)
	}
}

func TestProviderTokenBootstrapRejectsTokenlessUsedTokenOnAuthResponseV2(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	_, seedCleartext, err := store.IssueToken(context.Background(), "v2-claimed", "v2-claimed hostname")
	if err != nil {
		t.Fatalf("seed token: %v", err)
	}
	if err := store.MarkTokenUsed(context.Background(), seedCleartext); err != nil {
		t.Fatalf("mark seed used: %v", err)
	}
	h := newProviderHarnessWithTokenValidator(t, store, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = true
		cfg.Auth.AllowTokenlessProvisionalBootstrap = true
		cfg.Providers = nil
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial tokenless v2 used-token bootstrap: %v", err)
	}
	defer conn.Close()

	_, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("keypair: %v", err)
	}
	providerPublic := base64.RawURLEncoding.EncodeToString(providerPublicRaw)
	if err := wsutil.WriteClientText(conn, mustJSON(validAuthInitial("v2-claimed", providerPublic))); err != nil {
		t.Fatalf("write auth_request initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	writeAuthProof(t, conn, challenge, "v2-claimed", nil)

	frame, err := gobwas.ReadFrame(conn)
	if err != nil {
		t.Fatalf("read v2 tofu close: %v", err)
	}
	if frame.Header.OpCode != gobwas.OpClose {
		t.Fatalf("op = %v, want close", frame.Header.OpCode)
	}
	code, reason := gobwas.ParseCloseFrameData(frame.Payload)
	if code != providerws.CloseInvalidToken || reason != "invalid_token" {
		t.Fatalf("close = %d %q, want %d invalid_token", code, reason, providerws.CloseInvalidToken)
	}

	records, err := store.ListTokens(context.Background())
	if err != nil {
		t.Fatalf("list tokens: %v", err)
	}
	if len(records) != 1 {
		t.Fatalf("token rows after v2 strict reject = %d, want 1: %#v", len(records), records)
	}
	if records[0].RevokedAt.Valid {
		t.Fatalf("seed row should remain active after v2 strict reject; revoked_at=%v", records[0].RevokedAt)
	}
}

// SPEC-003 v0.8.4 — v2 mirror of TestSelfServeProvisionalTokenSelfHealsWhenExistingTokenUnused.
// The composed self-heal contract MUST hold across the v2 ECDH path
// too: a tokenless v2 connect declaring a provider_id whose active row
// has last_used_at IS NULL self-heals (revoke + remint), and the
// auth_response carries the fresh token. Also forces retainSpec010=true
// via SPEC-010 catalog fields so the R-7.9.7 defer's terminal-path
// release is exercised — AuthAttemptCount MUST return to 0.
func TestSelfServeProvisionalTokenSelfHealsOnAuthResponseV2WithRetentionCleanup(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	seedRecord, seedCleartext, err := store.IssueToken(context.Background(), "v2-selfheal", "v2-selfheal hostname")
	if err != nil {
		t.Fatalf("seed unused token: %v", err)
	}
	h := newProviderHarnessWithTokenValidator(t, store, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = false
		cfg.Providers = nil
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial tokenless v2: %v", err)
	}
	defer conn.Close()

	_, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("keypair: %v", err)
	}
	providerPublic := base64.RawURLEncoding.EncodeToString(providerPublicRaw)
	// SPEC-010 catalog fields force retainSpec010=true so the auth-attempt
	// retention store reserves an entry. ANY terminal path (including
	// successful self-heal mint) must release it via the R-7.9.7 defer.
	initial := validAuthInitial("v2-selfheal", providerPublic)
	initial["supported_models"] = []string{
		"mlx-community/Qwen2.5-7B-Instruct-4bit",
	}
	initial["publishes_supported_models"] = true

	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write auth_request initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	writeAuthProof(t, conn, challenge, "v2-selfheal", nil)
	response := readAuthResponse(t, conn)

	if response.Status != "accepted" {
		t.Fatalf("v2 auth_response.status = %q, want accepted (self-heal mints fresh token): %+v", response.Status, response)
	}
	if response.AssignedProviderToken == "" {
		t.Fatalf("v2 assigned_provider_token empty; want freshly-minted token from self-heal: %+v", response)
	}
	if response.AssignedProviderToken == seedCleartext {
		t.Fatalf("v2 self-heal returned the SAME cleartext as the seed; expected a freshly minted token")
	}

	// DB invariant: seed row revoked, fresh row active.
	records, err := store.ListTokens(context.Background())
	if err != nil {
		t.Fatalf("list tokens: %v", err)
	}
	if len(records) != 2 {
		t.Fatalf("token rows after v2 self-heal = %d, want 2: %#v", len(records), records)
	}
	for _, r := range records {
		if r.ID == seedRecord.ID && !r.RevokedAt.Valid {
			t.Fatalf("v2 seed row should be revoked after self-heal: %#v", r)
		}
		if r.ID != seedRecord.ID && r.RevokedAt.Valid {
			t.Fatalf("v2 fresh row should be active after self-heal: %#v", r)
		}
	}

	provider, ok := h.Registry.Resolve("v2-selfheal", response.AssignedID)
	if !ok {
		t.Fatalf("registry has no entry for assigned_id %q after v2 self-heal", response.AssignedID)
	}
	if provider.AuthState != pool.AuthSelfMinted {
		t.Fatalf("v2 self-heal auth_state = %q, want %q (self-mint is routable)", provider.AuthState, pool.AuthSelfMinted)
	}

	// The R-7.9.7 defer MUST release the retention entry on EVERY
	// terminal path — including successful self-heal. Without the
	// release, AuthAttemptCount stays at 1 and (with enough connects)
	// reaches the 1024 bound and locks out legitimate provisional
	// connects.
	if got := h.Provider.AuthAttemptCount(); got != 0 {
		t.Fatalf("auth-attempt retention count = %d, want 0 (self-heal terminal path must release the entry — R-7.9.7 defer)", got)
	}
}
