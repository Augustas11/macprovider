package ws

import (
	"encoding/base64"
	"encoding/json"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/relayblind"
	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
)

func TestParsePrivacyAppAttestEnrollRequest(t *testing.T) {
	keyID := base64.RawURLEncoding.EncodeToString(make([]byte, 32))
	good := `{"type":"privacy_app_attest_enroll_request","version":1,"app_attest_key_id":"` + keyID + `"}`
	if request, err := ParsePrivacyAppAttestEnrollRequest([]byte(good)); err != nil || request.AppAttestKeyID != keyID {
		t.Fatalf("good request: %v", err)
	}
	for name, raw := range map[string]string{
		"version 2":    strings.Replace(good, `"version":1`, `"version":2`, 1),
		"wrong type":   strings.Replace(good, "enroll_request", "enroll_result", 1),
		"unknown":      strings.Replace(good, "{", `{"extra":1,`, 1),
		"trailing":     good + "{}",
		"short key":    strings.Replace(good, keyID, keyID[:42], 1),
		"padded key":   strings.Replace(good, keyID, keyID+"=", 1),
		"oversized":    good + strings.Repeat(" ", maxPrivacyAppAttestEnrollRequestBytes),
		"missing key":  `{"type":"privacy_app_attest_enroll_request","version":1}`,
		"standard b64": strings.Replace(good, keyID, base64.StdEncoding.EncodeToString(make([]byte, 32)), 1),
	} {
		if _, err := ParsePrivacyAppAttestEnrollRequest([]byte(raw)); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
}

// With code-bound off (the default), an enrollment request is answered
// unavailable over the provider WebSocket, echoing the keyId.
func TestPrivacyAppAttestRequestRepliesUnavailableWhenDisabled(t *testing.T) {
	clock := time.Unix(1_800_000_000, 0).UTC()
	material := newWSPrivacyMaterial(t, clock)
	reg := pool.NewRegistry(nil)
	provider := pool.Provider{
		ProviderID: "provider-a", AssignedID: "session-a", Hostname: "provider.local",
		ModelID: "model-a", ModelParamsB: 7, RAMGB: 16, MaxContextTokens: 4096, MaxConcurrency: 1,
		BinaryVersion: "0.0.0-fixture", Tier: pool.TierPinned, State: pool.StateReady,
	}
	serverConn, clientConn := net.Pipe()
	t.Cleanup(func() { clientConn.Close() })
	t.Cleanup(func() { serverConn.Close() })
	reg.RegisterAt(&provider, serverConn, clock)
	s := &Server{pool: reg, log: zerolog.Nop(), now: func() time.Time { return clock }}
	WithPrivacyAuthority(material.auth)(s)
	sess := newProviderSession(provider.ProviderID, provider.AssignedID, serverConn, 64)
	go sess.runWriter()
	t.Cleanup(func() { sess.close() })
	s.sessions.Store(provider.ProviderID+"/"+provider.AssignedID, sess)

	keyID := base64.RawURLEncoding.EncodeToString(make([]byte, 32))
	got := make(chan []byte, 1)
	go func() {
		payload, _, err := wsutil.ReadServerData(clientConn)
		if err == nil {
			got <- payload
		}
	}()
	s.handleMessage(serverConn, provider.ProviderID, provider.AssignedID, []byte(`{"type":"privacy_app_attest_enroll_request","version":1,"app_attest_key_id":"`+keyID+`"}`))
	select {
	case payload := <-got:
		var result PrivacyAppAttestEnrollResult
		if err := json.Unmarshal(payload, &result); err != nil {
			t.Fatal(err)
		}
		if result.Type != privacyAppAttestEnrollResultType || result.Version != 1 || result.AppAttestKeyID != keyID || result.Status != relayblind.AppAttestUnavailable {
			t.Fatalf("result %+v", result)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no enrollment result")
	}
	// An enrollment with no outstanding challenge gets no reply and no
	// quarantine.
	s.handleMessage(serverConn, provider.ProviderID, provider.AssignedID, []byte(`{"type":"privacy_app_attest_enrollment","version":1}`))
}
