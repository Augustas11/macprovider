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

// SPEC-003 v0.8 FR-C9.4 TOFU — refuse a SECOND token for a provider_id
// that already has an unrevoked token. Closes the credential-capture
// vector from the codex security audit on PR #44: without this guard,
// an attacker who declares a victim's provider_id on a tokenless
// connect would receive a valid bearer for it. Pre-fix, the helper
// would mint freely; the security audit's MAJOR-1 finding spelled out
// the exploit chain.
func TestSelfServeProvisionalTokenRejectedWhenActiveTokenExists(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	// Seed: a legitimate provider already self-minted on a prior connect.
	_, _, err = store.IssueToken(context.Background(), "claimed-provider", "claimed-provider hostname")
	if err != nil {
		t.Fatalf("seed token: %v", err)
	}
	h := selfServeHarness(t, store)
	defer h.HTTP.Close()

	// Attacker: connects tokenless declaring the SAME provider_id.
	conn, br, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial tokenless attacker: %v", err)
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
		t.Fatalf("op = %v, want close (TOFU rejection)", frame.Header.OpCode)
	}
	code, reason := gobwas.ParseCloseFrameData(frame.Payload)
	if code != providerws.CloseInvalidToken || reason != "invalid_token" {
		t.Fatalf("close = %d %q, want %d invalid_token (FR-C9.4 TOFU)", code, reason, providerws.CloseInvalidToken)
	}

	// Critically: no NEW row was minted. Exactly the seeded row should remain.
	records, err := store.ListTokens(context.Background())
	if err != nil {
		t.Fatalf("list tokens: %v", err)
	}
	if len(records) != 1 {
		t.Fatalf("token rows after TOFU rejection = %d, want 1 (no parallel mint): %#v", len(records), records)
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
