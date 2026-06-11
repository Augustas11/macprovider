package ws_test

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"path/filepath"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
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

// SPEC-003 v0.8 FR-C9.1 — mint failure (e.g. transient DB error) MUST
// NOT prevent provisional admission. The ack still ships, the binary
// connects without a token, and FR-C9.4 multi-mint will retry on the
// next reconnect.
func TestSelfServeProvisionalTokenMintFailureTolerated(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	h := newProviderHarnessWithTokenValidator(t, mintFailingStore{Store: store}, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = false
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial tokenless: %v", err)
	}
	defer conn.Close()

	if err := wsutil.WriteClientText(conn, mustJSON(validHello("flaky-mint-provider"))); err != nil {
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
	if ack.Type != "hello_ack" {
		t.Fatalf("ack type = %q, want hello_ack despite mint failure", ack.Type)
	}
	if ack.AssignedProviderToken != "" {
		t.Fatalf("assigned_provider_token = %q, want empty on mint failure", ack.AssignedProviderToken)
	}
}

// SPEC-003 v0.8.3 FR-C9.4 unused-token self-heal — when an active row
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
}

// SPEC-003 v0.8.3 FR-C9.4 strict-reject — the security path. When
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
