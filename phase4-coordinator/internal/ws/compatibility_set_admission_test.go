package ws_test

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
)

const (
	compatibilityTargetSet   = "Augustas11/macprovider:v1.8.4@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	compatibilityRollbackSet = "Augustas11/macprovider:v1.8.3@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	compatibilityUnknownSet  = "Augustas11/macprovider:v1.8.2@cccccccccccccccccccccccccccccccccccccccc"
	// Exact public pre-fix set used by #610 first-hop production bootstrap.
	compatibilityFirstHopSet = "Augustas11/macprovider:v1.8.48@b84b430aad74574e8a37bc052fe4f9863d0c0ce8"
	compatibilityFutureSet   = "Augustas11/macprovider:v1.8.12@dddddddddddddddddddddddddddddddddddddddd"
	compatibilityRevokedSet  = "Augustas11/macprovider:v1.8.10@eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
)

func strictCompatibilityPolicy(cfg *config.Config) {
	cfg.Coordinator.CompatibilitySet = config.CompatibilitySetConfig{
		TargetID:    compatibilityTargetSet,
		AcceptedIDs: []string{compatibilityTargetSet, compatibilityRollbackSet},
	}
}

func firstHopBridgeCompatibilityPolicy(cfg *config.Config) {
	strictCompatibilityPolicy(cfg)
	cfg.Coordinator.CompatibilitySet.FirstHopBridgeIDs = []string{compatibilityFirstHopSet}
	// Raise the buyer-serving floor above the bridge cohort so the test proves
	// first-hop sessions skip required_binary_version while still receiving the
	// recommended target admission.
	cfg.CoordinatorAdvertisedVersion.RequiredBinaryVersion = "1.8.56"
	cfg.CoordinatorAdvertisedVersion.LatestBinaryVersion = "1.8.56"
}

func versionFloorCompatibilityPolicy(cfg *config.Config) {
	cfg.Coordinator.CompatibilitySet = config.CompatibilitySetConfig{
		TargetID:       compatibilityFutureSet,
		MinimumVersion: "1.8.4",
		RevokedIDs:     []string{compatibilityRevokedSet},
	}
}

func TestConfiguredCompatibilitySetRejectsMissingMalformedAndUnacceptedHello(t *testing.T) {
	tests := []struct {
		name   string
		setID  any
		reason string
	}{
		{name: "missing", reason: "compatibility_set_required"},
		{name: "malformed", setID: "not-a-signed-release-set", reason: "compatibility_set_invalid"},
		{name: "unaccepted", setID: compatibilityUnknownSet, reason: "compatibility_set_unaccepted"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			ts := newProviderServer(t, strictCompatibilityPolicy)
			defer ts.Close()
			hello := validHello("m4-anon")
			if test.setID != nil {
				hello["compatibility_set_id"] = test.setID
			}
			code, reason := sendHelloExpectClose(t, ts.URL, hello)
			if code != providerws.CloseInvalidHello || reason != test.reason {
				t.Fatalf("close = %d %q, want %d %q", code, reason, providerws.CloseInvalidHello, test.reason)
			}
		})
	}
}

func TestConfiguredCompatibilitySetAcceptsRollbackHelloAndRecommendsTarget(t *testing.T) {
	ts := newProviderServer(t, strictCompatibilityPolicy)
	defer ts.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	hello := validHello("m4-anon")
	hello["compatibility_set_id"] = compatibilityRollbackSet
	if err := wsutil.WriteClientText(conn, mustJSON(hello)); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read hello_ack: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}
	var ack providerws.HelloAck
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("decode hello_ack: %v", err)
	}
	if ack.CompatibilityPolicy != "configured" ||
		ack.AcceptedCompatibilitySetID != compatibilityRollbackSet ||
		ack.RecommendedCompatibilitySetID != compatibilityTargetSet {
		t.Fatalf("compatibility contract = %+v", ack)
	}
}

func TestVersionFloorCompatibilitySetAcceptsFutureHelloWithoutEightIDCap(t *testing.T) {
	ts := newProviderServer(t, versionFloorCompatibilityPolicy)
	defer ts.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	hello := validHello("m4-anon")
	hello["compatibility_set_id"] = compatibilityFutureSet
	hello["binary_version"] = "1.8.12"
	if err := wsutil.WriteClientText(conn, mustJSON(hello)); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read hello_ack: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}
	var ack providerws.HelloAck
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("decode hello_ack: %v", err)
	}
	if ack.CompatibilityPolicy != "configured" ||
		ack.AcceptedCompatibilitySetID != compatibilityFutureSet ||
		ack.RecommendedCompatibilitySetID != compatibilityFutureSet {
		t.Fatalf("compatibility contract = %+v", ack)
	}
}

func TestVersionFloorCompatibilitySetRejectsRevokedAndMismatchedHello(t *testing.T) {
	tests := []struct {
		name    string
		setID   string
		version string
		reason  string
	}{
		{name: "below floor", setID: compatibilityRollbackSet, version: "1.8.3", reason: "provider_version_below_minimum"},
		{name: "revoked", setID: compatibilityRevokedSet, version: "1.8.10", reason: "provider_release_revoked"},
		{name: "binary mismatch", setID: compatibilityFutureSet, version: "1.8.11", reason: "provider_binary_version_mismatch"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			ts := newProviderServer(t, versionFloorCompatibilityPolicy)
			defer ts.Close()
			hello := validHello("m4-anon")
			hello["compatibility_set_id"] = test.setID
			hello["binary_version"] = test.version
			code, reason := sendHelloExpectClose(t, ts.URL, hello)
			if code != providerws.CloseInvalidHello {
				t.Fatalf("close code = %d, want %d", code, providerws.CloseInvalidHello)
			}
			if !strings.HasPrefix(reason, test.reason) {
				t.Fatalf("close reason = %q, want prefix %q", reason, test.reason)
			}
		})
	}
}

func TestVersionFloorCompatibilityHealthzPublishesPolicy(t *testing.T) {
	ts := newProviderServer(t, versionFloorCompatibilityPolicy)
	defer ts.Close()
	resp, err := http.Get(ts.URL + "/healthz")
	if err != nil {
		t.Fatalf("healthz: %v", err)
	}
	defer resp.Body.Close()
	var body struct {
		CompatibilityPolicyMode           string   `json:"compatibility_policy_mode"`
		CompatibilityPolicyTargetID       string   `json:"compatibility_policy_target_id"`
		CompatibilityPolicyMinimumVersion string   `json:"compatibility_policy_minimum_version"`
		CompatibilityPolicyRevokedIDs     []string `json:"compatibility_policy_revoked_ids"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode healthz: %v", err)
	}
	if body.CompatibilityPolicyMode != "version_floor" ||
		body.CompatibilityPolicyTargetID != compatibilityFutureSet ||
		body.CompatibilityPolicyMinimumVersion != "1.8.4" ||
		len(body.CompatibilityPolicyRevokedIDs) != 1 ||
		body.CompatibilityPolicyRevokedIDs[0] != compatibilityRevokedSet {
		t.Fatalf("flattened compatibility policy = %+v", body)
	}
}

func TestVersionFloorCompatibilityHealthzPublishesEmptyRevokedIDs(t *testing.T) {
	ts := newProviderServer(t, func(cfg *config.Config) {
		cfg.Coordinator.CompatibilitySet = config.CompatibilitySetConfig{
			TargetID:       compatibilityFutureSet,
			MinimumVersion: "1.8.4",
		}
	})
	defer ts.Close()
	resp, err := http.Get(ts.URL + "/healthz")
	if err != nil {
		t.Fatalf("healthz: %v", err)
	}
	defer resp.Body.Close()
	var body map[string]json.RawMessage
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode healthz: %v", err)
	}
	raw, ok := body["compatibility_policy_revoked_ids"]
	if !ok {
		t.Fatalf("compatibility_policy_revoked_ids missing from healthz: keys=%v", body)
	}
	var revoked []string
	if err := json.Unmarshal(raw, &revoked); err != nil {
		t.Fatalf("decode revoked ids: %v", err)
	}
	if revoked == nil || len(revoked) != 0 {
		t.Fatalf("compatibility_policy_revoked_ids = %#v", revoked)
	}
}

func TestCompatibilityPolicyReloadDuringAckWindowDeliversAckThenCloses(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	var (
		h    providerHarness
		once sync.Once
	)
	h = newProviderHarnessWithServerOptions(t, store, []providerws.Option{
		providerws.WithBeforeHandshakeAckSendForTest(func() {
			once.Do(func() {
				closed := h.Provider.SetCompatibilitySetPolicy(config.CompatibilitySetConfig{
					TargetID:       compatibilityTargetSet,
					MinimumVersion: "1.8.4",
					RevokedIDs:     []string{compatibilityFutureSet},
				})
				if closed != 0 {
					t.Errorf("SetCompatibilitySetPolicy closed %d ack-pending sessions, want 0", closed)
				}
			})
		}),
	}, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = false
		cfg.Coordinator.CompatibilitySet = config.CompatibilitySetConfig{
			TargetID:       compatibilityFutureSet,
			MinimumVersion: "1.8.4",
		}
	})
	defer h.HTTP.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	hello := validHello("postmint-provider")
	hello["compatibility_set_id"] = compatibilityFutureSet
	hello["binary_version"] = "1.8.12"
	if err := wsutil.WriteClientText(conn, mustJSON(hello)); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, err := wsutil.ReadServerText(conn)
	if err != nil {
		t.Fatalf("read hello_ack: %v", err)
	}
	var ack providerws.HelloAck
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("decode hello_ack: %v", err)
	}
	if ack.Type != "hello_ack" || ack.AssignedID == "" {
		t.Fatalf("hello_ack = %+v", ack)
	}
	if ack.AssignedProviderToken == "" {
		t.Fatalf("assigned_provider_token empty in hello_ack: %+v", ack)
	}
	if ack.AuthState != string(pool.AuthSelfMinted) {
		t.Fatalf("auth_state = %q, want %q", ack.AuthState, pool.AuthSelfMinted)
	}
	frame, err := gobwas.ReadFrame(conn)
	if err != nil {
		t.Fatalf("read close: %v", err)
	}
	if frame.Header.OpCode != gobwas.OpClose {
		t.Fatalf("op = %v, want close", frame.Header.OpCode)
	}
	code, reason := gobwas.ParseCloseFrameData(frame.Payload)
	if code != providerws.CloseInvalidHello || reason != "provider_release_revoked" {
		t.Fatalf("close = %d %q, want %d provider_release_revoked", code, reason, providerws.CloseInvalidHello)
	}
}

func TestCompatibilityPolicyReloadFencesActiveRevokedSession(t *testing.T) {
	h := newProviderHarness(t, versionFloorCompatibilityPolicy)
	defer h.HTTP.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	hello := validHello("m4-anon")
	hello["compatibility_set_id"] = compatibilityFutureSet
	hello["binary_version"] = "1.8.12"
	if err := wsutil.WriteClientText(conn, mustJSON(hello)); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, _, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read hello_ack: %v", err)
	}
	var ack providerws.HelloAck
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("decode hello_ack: %v", err)
	}
	if provider, ok := h.Registry.Resolve("m4-anon", ack.AssignedID); !ok || !provider.RoutingEligible() {
		t.Fatalf("provider should start routable: ok=%v provider=%+v", ok, provider)
	}
	closed := h.Provider.SetCompatibilitySetPolicy(config.CompatibilitySetConfig{
		TargetID:       compatibilityTargetSet,
		MinimumVersion: "1.8.4",
		RevokedIDs:     []string{compatibilityFutureSet},
	})
	if closed != 1 {
		t.Fatalf("closed sessions = %d, want 1", closed)
	}
	if provider, ok := h.Registry.Resolve("m4-anon", ack.AssignedID); !ok || provider.State != pool.StateUnavailable || !provider.HandshakeAckPending || provider.RoutingEligible() {
		t.Fatalf("provider should be fenced before close: ok=%v provider=%+v", ok, provider)
	}
	h.Registry.ApplyHeartbeatDetailed("m4-anon", ack.AssignedID, pool.HeartbeatUpdate{
		Status:           pool.StateBusy,
		MaxContextTokens: 50000,
		MaxConcurrency:   1,
		SlotsFree:        1,
		SlotsTotal:       1,
	})
	if provider, ok := h.Registry.Resolve("m4-anon", ack.AssignedID); !ok || provider.RoutingEligible() {
		t.Fatalf("policy-fenced provider revived after busy heartbeat: ok=%v provider=%+v", ok, provider)
	}
	if err := conn.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatalf("set read deadline: %v", err)
	}
	frame, err := gobwas.ReadFrame(conn)
	if err != nil {
		t.Fatalf("read close frame: %v", err)
	}
	if frame.Header.OpCode != gobwas.OpClose {
		t.Fatalf("op = %v, want close", frame.Header.OpCode)
	}
	code, reason := gobwas.ParseCloseFrameData(frame.Payload)
	if code != providerws.CloseInvalidHello || !strings.HasPrefix(reason, "provider_release_revoked") {
		t.Fatalf("close = %d %q, want revoked invalid hello", code, reason)
	}
}

func TestCompatibilityPolicyReloadClosesBuyerServingSessionDemotedToBridgeOnly(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Coordinator.CompatibilitySet = config.CompatibilitySetConfig{
			TargetID:       compatibilityFutureSet,
			MinimumVersion: "1.8.4",
		}
	})
	defer h.HTTP.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	hello := validHello("m4-anon")
	hello["compatibility_set_id"] = compatibilityRevokedSet
	hello["binary_version"] = "1.8.10"
	if err := wsutil.WriteClientText(conn, mustJSON(hello)); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, _, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read hello_ack: %v", err)
	}
	var ack providerws.HelloAck
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("decode hello_ack: %v", err)
	}
	if provider, ok := h.Registry.Resolve("m4-anon", ack.AssignedID); !ok || provider.CatalogAdmissionMode == "update_bridge" || !provider.RoutingEligible() {
		t.Fatalf("provider should start as buyer-serving, not bridge-only: ok=%v provider=%+v", ok, provider)
	}
	closed := h.Provider.SetCompatibilitySetPolicy(config.CompatibilitySetConfig{
		TargetID:          compatibilityFutureSet,
		MinimumVersion:    "1.8.12",
		FirstHopBridgeIDs: []string{compatibilityRevokedSet},
	})
	if closed != 1 {
		t.Fatalf("closed sessions = %d, want 1", closed)
	}
	if provider, ok := h.Registry.Resolve("m4-anon", ack.AssignedID); !ok || provider.State != "unavailable" || provider.RoutingEligible() {
		t.Fatalf("provider should be fenced when demoted to bridge-only: ok=%v provider=%+v", ok, provider)
	}
}

func TestConfiguredCompatibilitySetRejectsMissingAuthInitial(t *testing.T) {
	h := newProviderHarness(t, strictCompatibilityPolicy)
	defer h.HTTP.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	initial := validAuthInitialWithFreshKey(t, "m4-anon")
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write auth initial: %v", err)
	}
	response := readAuthResponse(t, conn)
	if response.Status != "rejected" || response.Error == nil || response.Error.Code != "compatibility_set_required" {
		t.Fatalf("auth_response = %+v", response)
	}
}

func TestConfiguredCompatibilitySetEchoesAcceptedAuthSetAndTarget(t *testing.T) {
	h := newProviderHarness(t, strictCompatibilityPolicy)
	defer h.HTTP.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	_, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("provider keypair: %v", err)
	}
	initial := validAuthInitial("m4-anon", base64.RawURLEncoding.EncodeToString(providerPublicRaw))
	initial["compatibility_set_id"] = compatibilityRollbackSet
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write auth initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	writeAuthProof(t, conn, challenge, "m4-anon", nil)
	response := readAuthResponse(t, conn)
	if response.Status != "accepted" ||
		response.CompatibilityPolicy != "configured" ||
		response.AcceptedCompatibilitySetID != compatibilityRollbackSet ||
		response.RecommendedCompatibilitySetID != compatibilityTargetSet {
		t.Fatalf("auth_response compatibility contract = %+v", response)
	}
}

func TestFirstHopBridgeHelloRecommendsTargetWithoutBuyerRouting(t *testing.T) {
	h := newProviderHarness(t, firstHopBridgeCompatibilityPolicy)
	defer h.HTTP.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	hello := validHello("m4-anon")
	hello["compatibility_set_id"] = compatibilityFirstHopSet
	hello["binary_version"] = "1.8.48"
	if err := wsutil.WriteClientText(conn, mustJSON(hello)); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read hello_ack: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}
	var ack providerws.HelloAck
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("decode hello_ack: %v", err)
	}
	if ack.CompatibilityPolicy != "configured" ||
		ack.AcceptedCompatibilitySetID != compatibilityFirstHopSet ||
		ack.RecommendedCompatibilitySetID != compatibilityTargetSet {
		t.Fatalf("first-hop compatibility contract = %+v", ack)
	}
	if ack.RecommendedBinaryVersion != "1.8.56" {
		t.Fatalf("recommended_binary_version = %q, want 1.8.56", ack.RecommendedBinaryVersion)
	}
	provider, ok := h.Registry.Resolve("m4-anon", ack.AssignedID)
	if !ok {
		t.Fatal("first-hop bridge provider was not registered")
	}
	if provider.CatalogAdmissionMode != "update_bridge" {
		t.Fatalf("CatalogAdmissionMode = %q, want update_bridge", provider.CatalogAdmissionMode)
	}
	if provider.BinaryVersion != "1.8.48" {
		t.Fatalf("BinaryVersion = %q, want 1.8.48", provider.BinaryVersion)
	}
	if provider.RoutingEligible() || provider.ServingCapable() {
		t.Fatalf("first-hop bridge provider must not be buyer-routable: %+v", provider)
	}
}

func TestFirstHopBridgeRejectsUnknownSets(t *testing.T) {
	ts := newProviderServer(t, firstHopBridgeCompatibilityPolicy)
	defer ts.Close()
	hello := validHello("m4-anon")
	hello["compatibility_set_id"] = compatibilityUnknownSet
	hello["binary_version"] = "1.8.48"
	code, reason := sendHelloExpectClose(t, ts.URL, hello)
	if code != providerws.CloseInvalidHello || reason != "compatibility_set_unaccepted" {
		t.Fatalf("close = %d %q, want %d compatibility_set_unaccepted", code, reason, providerws.CloseInvalidHello)
	}
}

func TestUnconfiguredCompatibilitySetExplicitlyRetainsLegacyHello(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(validHello("m4-anon"))); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, _, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read hello_ack: %v", err)
	}
	var ack providerws.HelloAck
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("decode hello_ack: %v", err)
	}
	if ack.Type != "hello_ack" || ack.CompatibilityPolicy != "unconfigured" ||
		ack.AcceptedCompatibilitySetID != "" || ack.RecommendedCompatibilitySetID != "" {
		t.Fatalf("legacy compatibility contract = %+v", ack)
	}
}
