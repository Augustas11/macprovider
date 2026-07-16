package ws_test

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
)

// S-H1: `recommended_binary_version` (the autoupdate target advertised from
// `coordinator_advertised_version.latest_binary_version`) is capability-gated
// per connection. Legacy pre-compatibility-set clients (<=1.8.32) do not send
// `compatibility_set_id`; they must receive NO recommendation so their default
// binary-only autoupdater cannot self-swap into a mixed install. Clients that
// declare a compatibility-set identity (v1.8.33+, full signed-set updater) get
// the configured value. `required_binary_version` is unaffected by the gate.

const (
	gateAdvertisedVersion = "1.8.40"
	gateRequiredVersion   = "1.7.0"
	gateModernSetID       = "Augustas11/macprovider:v1.8.40@dddddddddddddddddddddddddddddddddddddddd"
)

func advertisedVersionConfig(cfg *config.Config) {
	cfg.CoordinatorAdvertisedVersion.LatestBinaryVersion = gateAdvertisedVersion
	cfg.CoordinatorAdvertisedVersion.RequiredBinaryVersion = gateRequiredVersion
}

// readHelloAck sends a caller-supplied hello and returns the decoded hello_ack.
func sendHelloReadAck(t *testing.T, conn net.Conn, hello map[string]any) providerws.HelloAck {
	t.Helper()
	if err := wsutil.WriteClientText(conn, mustJSON(hello)); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read hello_ack: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("hello_ack op = %v, want text", op)
	}
	var ack providerws.HelloAck
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("decode hello_ack: %v", err)
	}
	if ack.Type != "hello_ack" {
		t.Fatalf("hello_ack type = %q", ack.Type)
	}
	return ack
}

// TestHelloAckLegacyClientReceivesNoRecommendedBinaryVersion covers the v1
// hello_ack emission site (server.go ~1051). A legacy hello (no
// compatibility_set_id) under an unconfigured compatibility policy — the
// default production posture — must carry no recommended_binary_version while
// required_binary_version stays populated.
func TestHelloAckLegacyClientReceivesNoRecommendedBinaryVersion(t *testing.T) {
	ts := newProviderServer(t, advertisedVersionConfig)
	defer ts.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	// A real legacy CLI (e.g. v1.8.30) clears the required floor but sends no
	// compatibility_set_id — the exact cohort the gate must protect.
	hello := validHello("m4-anon")
	hello["binary_version"] = "1.8.30"
	ack := sendHelloReadAck(t, conn, hello)
	if ack.RecommendedBinaryVersion != "" {
		t.Fatalf("legacy hello_ack recommended_binary_version = %q, want empty (S-H1 gate)", ack.RecommendedBinaryVersion)
	}
	if ack.RequiredBinaryVersion != gateRequiredVersion {
		t.Fatalf("required_binary_version = %q, want %q (unchanged by gate)", ack.RequiredBinaryVersion, gateRequiredVersion)
	}
}

// TestHelloAckCompatibilityClientReceivesRecommendedBinaryVersion covers the
// v1 hello_ack site for a modern hello (compatibility_set_id present) even
// while the coordinator's compatibility policy is unconfigured: presence of the
// capability alone unlocks the recommendation.
func TestHelloAckCompatibilityClientReceivesRecommendedBinaryVersion(t *testing.T) {
	ts := newProviderServer(t, advertisedVersionConfig)
	defer ts.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	hello := validHello("m4-anon")
	hello["binary_version"] = "1.8.33"
	hello["compatibility_set_id"] = gateModernSetID
	ack := sendHelloReadAck(t, conn, hello)
	if ack.RecommendedBinaryVersion != gateAdvertisedVersion {
		t.Fatalf("compatibility hello_ack recommended_binary_version = %q, want %q", ack.RecommendedBinaryVersion, gateAdvertisedVersion)
	}
	if ack.RequiredBinaryVersion != gateRequiredVersion {
		t.Fatalf("required_binary_version = %q, want %q", ack.RequiredBinaryVersion, gateRequiredVersion)
	}
}

// TestAuthResponseLegacyClientReceivesNoRecommendedBinaryVersion covers the v2
// auth_response emission site (server.go ~1552). A v2 initial without a
// compatibility_set_id is legacy and must be denied the recommendation while
// required_binary_version is preserved.
func TestAuthResponseLegacyClientReceivesNoRecommendedBinaryVersion(t *testing.T) {
	h := newProviderHarness(t, advertisedVersionConfig)
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
	initial["binary_version"] = "1.8.30"
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write auth initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	writeAuthProof(t, conn, challenge, "m4-anon", nil)
	response := readAuthResponse(t, conn)
	if response.Status != "accepted" {
		t.Fatalf("auth_response.status = %q, want accepted: %+v", response.Status, response)
	}
	if response.RecommendedBinaryVersion != "" {
		t.Fatalf("legacy auth_response recommended_binary_version = %q, want empty (S-H1 gate)", response.RecommendedBinaryVersion)
	}
	if response.RequiredBinaryVersion != gateRequiredVersion {
		t.Fatalf("required_binary_version = %q, want %q (unchanged by gate)", response.RequiredBinaryVersion, gateRequiredVersion)
	}
}

// TestAuthResponseCompatibilityClientReceivesRecommendedBinaryVersion covers
// the v2 auth_response site for a modern initial (compatibility_set_id present)
// under an unconfigured policy.
func TestAuthResponseCompatibilityClientReceivesRecommendedBinaryVersion(t *testing.T) {
	h := newProviderHarness(t, advertisedVersionConfig)
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
	initial["binary_version"] = "1.8.33"
	initial["compatibility_set_id"] = gateModernSetID
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write auth initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	writeAuthProof(t, conn, challenge, "m4-anon", nil)
	response := readAuthResponse(t, conn)
	if response.Status != "accepted" {
		t.Fatalf("auth_response.status = %q, want accepted: %+v", response.Status, response)
	}
	if response.RecommendedBinaryVersion != gateAdvertisedVersion {
		t.Fatalf("compatibility auth_response recommended_binary_version = %q, want %q", response.RecommendedBinaryVersion, gateAdvertisedVersion)
	}
	if response.RequiredBinaryVersion != gateRequiredVersion {
		t.Fatalf("required_binary_version = %q, want %q", response.RequiredBinaryVersion, gateRequiredVersion)
	}
}

// TestConfiguredCompatibilitySetHelloAckStillRecommendsBinaryVersion confirms
// that under a configured strict compatibility policy an accepted (set-bearing)
// hello continues to receive the recommendation — the gate does not regress the
// modern cohort. Legacy hellos are already hard-rejected in this posture
// (covered by compatibility_set_admission_test.go), so they never reach the ack.
func TestConfiguredCompatibilitySetHelloAckStillRecommendsBinaryVersion(t *testing.T) {
	ts := newProviderServer(t, func(cfg *config.Config) {
		advertisedVersionConfig(cfg)
		strictCompatibilityPolicy(cfg)
	})
	defer ts.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	hello := validHello("m4-anon")
	hello["binary_version"] = "1.8.33"
	hello["compatibility_set_id"] = compatibilityRollbackSet
	ack := sendHelloReadAck(t, conn, hello)
	if ack.RecommendedBinaryVersion != gateAdvertisedVersion {
		t.Fatalf("configured-policy hello_ack recommended_binary_version = %q, want %q", ack.RecommendedBinaryVersion, gateAdvertisedVersion)
	}
}
