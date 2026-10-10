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
	// An old public release that no allowlist in these tests carries.
	compatibilityOldSet     = "Augustas11/macprovider:v1.8.117@b84b430aad74574e8a37bc052fe4f9863d0c0ce8"
	compatibilityFutureSet  = "Augustas11/macprovider:v1.8.12@dddddddddddddddddddddddddddddddddddddddd"
	compatibilityRevokedSet = "Augustas11/macprovider:v1.8.10@eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
	compatibilityLaterSet   = "Augustas11/macprovider:v1.8.13@ffffffffffffffffffffffffffffffffffffffff"
	compatibilityOtherRepo  = "Augustas11/other:v1.8.12@1111111111111111111111111111111111111111"
)

func strictCompatibilityPolicy(cfg *config.Config) {
	cfg.Coordinator.CompatibilitySet = config.CompatibilitySetConfig{
		TargetID: compatibilityTargetSet,
	}
}

// revocationCompatibilityPolicy: the target repository with one exact
// revocation (SPEC-002-R004).
func revocationCompatibilityPolicy(cfg *config.Config) {
	cfg.Coordinator.CompatibilitySet = config.CompatibilitySetConfig{
		TargetID:   compatibilityFutureSet,
		RevokedIDs: []string{compatibilityRevokedSet},
	}
	cfg.CoordinatorAdvertisedVersion.LatestBinaryVersion = "1.8.12"
}

func TestConfiguredCompatibilitySetRejectsMissingMalformedAndForeignHello(t *testing.T) {
	tests := []struct {
		name   string
		setID  any
		reason string
	}{
		{name: "missing", reason: "compatibility_set_required"},
		{name: "malformed", setID: "not-a-signed-release-set", reason: "compatibility_set_invalid"},
		{name: "foreign repository", setID: compatibilityOtherRepo, reason: "compatibility_set_repository_mismatch"},
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
	hello["binary_version"] = "1.8.3"
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

func TestRepositoryCompatibilitySetAcceptsFutureHelloWithoutAllowlist(t *testing.T) {
	ts := newProviderServer(t, revocationCompatibilityPolicy)
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

func TestRepositoryCompatibilitySetRejectsForeignAndMalformedHello(t *testing.T) {
	tests := []struct {
		name    string
		setID   string
		version string
		reason  string
	}{
		{name: "foreign repository", setID: compatibilityOtherRepo, version: "1.8.12", reason: "compatibility_set_repository_mismatch"},
		{name: "binary version differs from the set version", setID: compatibilityFutureSet, version: "1.8.11", reason: "provider_binary_version_mismatch"},
		{name: "leading-zero binary version", setID: compatibilityFutureSet, version: "01.8.12", reason: "provider_binary_version_mismatch"},
		{name: "revoked set with a different binary version", setID: compatibilityRevokedSet, version: "1.8.12", reason: "provider_binary_version_mismatch"},
		{name: "leading-zero release identity", setID: "Augustas11/macprovider:v1.8.012@dddddddddddddddddddddddddddddddddddddddd", version: "1.8.12", reason: "compatibility_set_invalid"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			ts := newProviderServer(t, revocationCompatibilityPolicy)
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

func TestRepositoryCompatibilityHealthzPublishesPolicy(t *testing.T) {
	ts := newProviderServer(t, revocationCompatibilityPolicy)
	defer ts.Close()
	resp, err := http.Get(ts.URL + "/healthz")
	if err != nil {
		t.Fatalf("healthz: %v", err)
	}
	defer resp.Body.Close()
	var body struct {
		CompatibilityPolicyMode       string   `json:"compatibility_policy_mode"`
		CompatibilityPolicyTargetID   string   `json:"compatibility_policy_target_id"`
		CompatibilityPolicyRevokedIDs []string `json:"compatibility_policy_revoked_ids"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode healthz: %v", err)
	}
	if body.CompatibilityPolicyMode != "repository" ||
		body.CompatibilityPolicyTargetID != compatibilityFutureSet ||
		len(body.CompatibilityPolicyRevokedIDs) != 1 ||
		body.CompatibilityPolicyRevokedIDs[0] != compatibilityRevokedSet {
		t.Fatalf("flattened compatibility policy = %+v", body)
	}
}

func TestRepositoryCompatibilityHealthzPublishesEmptyRevokedIDs(t *testing.T) {
	ts := newProviderServer(t, func(cfg *config.Config) {
		cfg.Coordinator.CompatibilitySet = config.CompatibilitySetConfig{
			TargetID: compatibilityFutureSet,
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
				closed, err := h.Provider.SetCompatibilitySetPolicy(config.CompatibilitySetConfig{
					TargetID:   compatibilityTargetSet,
					RevokedIDs: []string{compatibilityFutureSet},
				})
				if err != nil {
					t.Errorf("SetCompatibilitySetPolicy error = %v", err)
				}
				if closed != 0 {
					t.Errorf("SetCompatibilitySetPolicy closed %d ack-pending sessions, want 0", closed)
				}
			})
		}),
	}, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = false
		cfg.Coordinator.CompatibilitySet = config.CompatibilitySetConfig{
			TargetID: compatibilityFutureSet,
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
	h := newProviderHarness(t, revocationCompatibilityPolicy)
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
	// The routing hold is released just after the hello_ack write.
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", ack.AssignedID)
		return ok && provider.RoutingEligible()
	})
	closed, err := h.Provider.SetCompatibilitySetPolicy(config.CompatibilitySetConfig{
		TargetID:   compatibilityTargetSet,
		RevokedIDs: []string{compatibilityFutureSet},
	})
	if err != nil {
		t.Fatalf("SetCompatibilitySetPolicy error = %v", err)
	}
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

func TestCompatibilityPolicyReloadRefusesRepositoryDrift(t *testing.T) {
	tests := []struct {
		name       string
		configure  func(*config.Config)
		setID      string
		version    string
		reload     config.CompatibilitySetConfig
		wantReason string
	}{
		{
			name:      "repository drift",
			configure: revocationCompatibilityPolicy,
			setID:     compatibilityFutureSet,
			version:   "1.8.12",
			reload: config.CompatibilitySetConfig{
				TargetID: compatibilityOtherRepo,
			},
			wantReason: "compatibility_set_repository_mismatch",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			h := newProviderHarness(t, test.configure)
			defer h.HTTP.Close()
			conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
			if err != nil {
				t.Fatalf("dial: %v", err)
			}
			defer conn.Close()
			hello := validHello("m4-anon")
			hello["compatibility_set_id"] = test.setID
			hello["binary_version"] = test.version
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
			// The routing hold is released just after the hello_ack write.
			eventually(t, func() bool {
				provider, ok := h.Registry.Resolve("m4-anon", ack.AssignedID)
				return ok && provider.RoutingEligible()
			})
			closed, err := h.Provider.SetCompatibilitySetPolicy(test.reload)
			if err == nil || !strings.Contains(err.Error(), test.wantReason) {
				t.Fatalf("SetCompatibilitySetPolicy error = %v, want %q", err, test.wantReason)
			}
			if closed != 0 {
				t.Fatalf("closed sessions = %d, want 0", closed)
			}
			if provider, ok := h.Registry.Resolve("m4-anon", ack.AssignedID); !ok || !provider.RoutingEligible() {
				t.Fatalf("provider should remain routable after refused reload: ok=%v provider=%+v", ok, provider)
			}
		})
	}
}

func TestCompatibilityPolicyReloadRefusesRepositoryDriftForHTTPForwardingProvider(t *testing.T) {
	h := newProviderHarness(t, revocationCompatibilityPolicy)
	defer h.HTTP.Close()
	provider := &pool.Provider{
		ProviderID:           "http-live",
		AssignedID:           "http-session",
		EndpointURL:          "https://provider.example.test",
		InferencePath:        pool.InferencePathHTTPForwarding,
		State:                pool.StateReady,
		SlotsFree:            1,
		SlotsTotal:           1,
		MaxConcurrency:       1,
		MaxContextTokens:     8192,
		BinaryVersion:        "1.8.12",
		CompatibilitySetID:   compatibilityFutureSet,
		CatalogAdmissionMode: "current",
	}
	if _, ok := h.Registry.Register(provider, nil); !ok {
		t.Fatal("register HTTP provider failed")
	}
	closed, err := h.Provider.SetCompatibilitySetPolicy(config.CompatibilitySetConfig{
		TargetID: compatibilityOtherRepo,
	})
	if err == nil || !strings.Contains(err.Error(), "compatibility_set_repository_mismatch") {
		t.Fatalf("SetCompatibilitySetPolicy error = %v, want compatibility_set_repository_mismatch", err)
	}
	if closed != 0 {
		t.Fatalf("closed sessions = %d, want 0", closed)
	}
	if got, ok := h.Registry.Resolve("http-live", "http-session"); !ok || got.State != pool.StateReady || !got.RoutingEligible() {
		t.Fatalf("HTTP provider should remain routable after refused reload: ok=%v provider=%+v", ok, got)
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
	initial["binary_version"] = "1.8.3"
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

// helloAckFor sends a hello with setID/version and returns the hello_ack.
func helloAckFor(t *testing.T, url string, setID, version string) (providerws.HelloAck, func()) {
	t.Helper()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(url))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	hello := validHello("m4-anon")
	hello["compatibility_set_id"] = setID
	hello["binary_version"] = version
	if err := wsutil.WriteClientText(conn, mustJSON(hello)); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil || op != gobwas.OpText {
		t.Fatalf("read hello_ack: op=%v err=%v", op, err)
	}
	var ack providerws.HelloAck
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("decode hello_ack: %v", err)
	}
	return ack, func() { conn.Close() }
}

// An old, valid release from the target repository connects, serves buyers
// and receives the recommendation; deprecated accepted_ids /
// first_hop_bridge_ids in the config are ignored (SPEC-002-R004).
func TestOldReleaseConnectsRoutableAndReceivesRecommendation(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Coordinator.CompatibilitySet = config.CompatibilitySetConfig{
			TargetID:          compatibilityFutureSet,
			AcceptedIDs:       []string{compatibilityFutureSet, compatibilityLaterSet},
			FirstHopBridgeIDs: []string{compatibilityTargetSet},
		}
		cfg.CoordinatorAdvertisedVersion.LatestBinaryVersion = "1.8.12"
	})
	defer h.HTTP.Close()
	ack, done := helloAckFor(t, h.HTTP.URL, compatibilityOldSet, "1.8.117")
	defer done()
	if ack.Type != "hello_ack" || ack.CompatibilityPolicy != "configured" ||
		ack.AcceptedCompatibilitySetID != compatibilityOldSet ||
		ack.RecommendedCompatibilitySetID != compatibilityFutureSet || ack.RecommendedBinaryVersion != "1.8.12" {
		t.Fatalf("old release hello_ack = %+v", ack)
	}
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", ack.AssignedID)
		return ok && provider.CatalogAdmissionMode != "update_bridge" && provider.RoutingEligible()
	})
}

// An exactly revoked release keeps an update-only session that receives the
// recommendation, so its updater can move it forward; it never serves buyers.
func TestRevokedReleaseGetsUpdateOnlySessionWithRecommendation(t *testing.T) {
	h := newProviderHarness(t, revocationCompatibilityPolicy)
	defer h.HTTP.Close()
	ack, done := helloAckFor(t, h.HTTP.URL, compatibilityRevokedSet, "1.8.10")
	defer done()
	if ack.Type != "hello_ack" || ack.AcceptedCompatibilitySetID != compatibilityRevokedSet ||
		ack.RecommendedCompatibilitySetID != compatibilityFutureSet || ack.RecommendedBinaryVersion != "1.8.12" {
		t.Fatalf("revoked release hello_ack = %+v", ack)
	}
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", ack.AssignedID)
		return ok && !provider.HandshakeAckPending
	})
	provider, ok := h.Registry.Resolve("m4-anon", ack.AssignedID)
	if !ok || provider.CatalogAdmissionMode != "update_bridge" || provider.RoutingEligible() || provider.ServingCapable() {
		t.Fatalf("revoked release must be update-only and non-routable: ok=%v provider=%+v", ok, provider)
	}
}
