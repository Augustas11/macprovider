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
	"github.com/augstar/macprovider-coordinator/internal/pool"
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

// SPEC-003 v0.8.3 FR-C9.4 — during the settling window
// (RequireProviderTokens=false), a tokenless connect from a
// provider_id that already has an unrevoked token MUST be admitted
// without a token in the ack frame, NOT rejected. The DB partial
// unique index already prevents minting a parallel bearer for that
// provider_id, so the credential-capture vector the v0.8.2 codex
// security audit (PR #44 MAJOR-1) closed remains closed via the
// constraint. Rejecting the connection — what v0.8.2 did — bricks
// old-binary cohorts that connected tokenless before the new
// coordinator was live (they never persisted the assigned token they
// don't know about), so v0.8.3 (DECISION_CRITERIA Entry 66) replaced
// reject-on-duplicate with admit-tokenless.
//
// Pre-v0.8.3 this test was TestSelfServeProvisionalTokenRejectedWhen-
// ActiveTokenExists and asserted CloseInvalidToken / "invalid_token".
// The 2026-06-12 deploy attempt demonstrated that behavior was a
// structural brick of the settling window. The new test name + body
// document the corrected contract.
func TestSelfServeProvisionalTokenAdmitsTokenlessWhenActiveTokenExists(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	// Seed: someone (legitimate provider or a prior race winner)
	// already self-minted for "claimed-provider".
	_, _, err = store.IssueToken(context.Background(), "claimed-provider", "claimed-provider hostname")
	if err != nil {
		t.Fatalf("seed token: %v", err)
	}
	h := selfServeHarness(t, store)
	defer h.HTTP.Close()

	// Loser: connects tokenless declaring the SAME provider_id.
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial tokenless loser: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(validHello("claimed-provider"))); err != nil {
		t.Fatalf("write hello: %v", err)
	}

	// MUST receive a hello_ack (not a close frame). MUST admit tokenless.
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read hello_ack: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text (settling-window admit, not close)", op)
	}
	var ack providerws.HelloAck
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("ack json: %v", err)
	}
	if ack.Type != "hello_ack" {
		t.Fatalf("ack type = %q, want hello_ack (settling-window admit)", ack.Type)
	}
	// MUST NOT include a token in the ack frame — the loser does not get
	// a bearer because the winner already holds it via the DB constraint.
	if ack.AssignedProviderToken != "" {
		t.Fatalf("assigned_provider_token = %q, want empty (DB partial unique index prevented duplicate mint; loser is bearer-less)", ack.AssignedProviderToken)
	}

	// Critically: still exactly the seeded row, no new mint attempt
	// produced an extra row via races or fallback paths.
	records, err := store.ListTokens(context.Background())
	if err != nil {
		t.Fatalf("list tokens: %v", err)
	}
	active := 0
	for _, r := range records {
		if r.ProviderID == "claimed-provider" && !r.RevokedAt.Valid {
			active++
		}
	}
	if active != 1 {
		t.Fatalf("active rows for claimed-provider = %d, want 1: %#v", active, records)
	}

	// SPEC-003 v0.8.3 fix-pass-3 (PR #69 security MAJOR-1) — the
	// admitted entry MUST be marked AuthBearerlessDuplicate so the
	// registry refuses to evict an existing routable session and
	// routing/billing exclude it.
	provider, ok := h.Registry.Resolve("claimed-provider", ack.AssignedID)
	if !ok {
		t.Fatalf("registry has no entry for assigned_id %q", ack.AssignedID)
	}
	if provider.AuthState != pool.AuthBearerlessDuplicate {
		t.Fatalf("auth_state = %q, want %q (bearer-less duplicate marking)", provider.AuthState, pool.AuthBearerlessDuplicate)
	}
	if provider.RoutingEligible() {
		t.Fatalf("RoutingEligible() = true for bearer-less duplicate; must be false")
	}
}

// SPEC-003 v0.8.3 fix-pass-3 — eviction defense (PR #69 codex security
// MAJOR-1). A bearer-less duplicate connect MUST NOT be allowed to
// displace an existing routable session for the same provider_id. Pre-
// fix, registerProviderSession would last-writer-win on provider_id,
// kicking the legitimate provider out of the pool and routing buyer
// traffic + billing to the duplicate. The fix: pool.Registry.Register
// returns (oldConn, registered); when registered==false the WS handler
// closes the duplicate with CloseInvalidToken without disturbing the
// existing session.
func TestSelfServeProvisionalTokenEvictionDefenseProtectsRoutableSession(t *testing.T) {
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
	if legit.AuthState == pool.AuthBearerlessDuplicate {
		t.Fatalf("legitimate auth_state corrupted to bearerless_duplicate")
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

// SPEC-003 v0.8.3 fix-pass-3 (PR #69 codex code MAJOR-2) — v2 mirror
// of TestSelfServeProvisionalTokenAdmitsTokenlessWhenActiveTokenExists.
// The v0.8.3 admit-tokenless behavior on duplicate-token must hold on
// the v2 ECDH path too. Asserts proof-accepted auth_response with
// empty assigned_provider_token + AuthBearerlessDuplicate marking +
// not routing-eligible.
func TestSelfServeProvisionalTokenAdmitsTokenlessOnAuthResponseV2WhenActiveTokenExists(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	_, _, err = store.IssueToken(context.Background(), "v2-duplicate", "v2-duplicate hostname")
	if err != nil {
		t.Fatalf("seed token: %v", err)
	}
	h := newProviderHarnessWithTokenValidator(t, store, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = false
		cfg.Providers = nil
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial tokenless v2 duplicate: %v", err)
	}
	defer conn.Close()

	_, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("keypair: %v", err)
	}
	providerPublic := base64.RawURLEncoding.EncodeToString(providerPublicRaw)
	if err := wsutil.WriteClientText(conn, mustJSON(validAuthInitial("v2-duplicate", providerPublic))); err != nil {
		t.Fatalf("write auth_request initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	writeAuthProof(t, conn, challenge, "v2-duplicate", nil)
	response := readAuthResponse(t, conn)

	if response.Status != "accepted" {
		t.Fatalf("auth_response.status = %q, want accepted (settling-window admit on v2): %+v", response.Status, response)
	}
	if response.AssignedProviderToken != "" {
		t.Fatalf("v2 assigned_provider_token = %q, want empty (DB unique index prevented duplicate mint): %+v", response.AssignedProviderToken, response)
	}

	provider, ok := h.Registry.Resolve("v2-duplicate", response.AssignedID)
	if !ok {
		t.Fatalf("registry has no entry for assigned_id %q after v2 admit", response.AssignedID)
	}
	if provider.AuthState != pool.AuthBearerlessDuplicate {
		t.Fatalf("v2 auth_state = %q, want %q", provider.AuthState, pool.AuthBearerlessDuplicate)
	}
	if provider.RoutingEligible() {
		t.Fatalf("v2 bearer-less duplicate is routing-eligible; must not be")
	}

	// Exactly one row remains (the seed); no parallel mint succeeded.
	records, err := store.ListTokens(context.Background())
	if err != nil {
		t.Fatalf("list tokens: %v", err)
	}
	active := 0
	for _, r := range records {
		if r.ProviderID == "v2-duplicate" && !r.RevokedAt.Valid {
			active++
		}
	}
	if active != 1 {
		t.Fatalf("v2 active rows for v2-duplicate = %d, want 1: %#v", active, records)
	}
}
