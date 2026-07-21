package ws_test

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
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
