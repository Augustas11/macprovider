package ws

import (
	"bytes"
	"encoding/json"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/relayblind"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
)

func TestSealInferenceRequestCopiesPrivacyClass(t *testing.T) {
	clear := &providerSession{}
	withClass := &RelayBlindDispatchContext{RequestID: "req-1", AssignedSession: "session-a", PrivacyClass: relayblind.PrivacyClassV1}
	raw, err := clear.sealInferenceRequestWithRelayBlind(pool.Provider{ProviderID: "provider-a", AssignedID: "session-a"}, "req-1", []byte(`{}`), false, nil, "", nil, withClass)
	if err != nil {
		t.Fatal(err)
	}
	var msg InferenceRequest
	if err := json.Unmarshal(raw, &msg); err != nil {
		t.Fatal(err)
	}
	if msg.PrivacyClass != relayblind.PrivacyClassV1 {
		t.Fatalf("clear privacy class = %q", msg.PrivacyClass)
	}
	without := &RelayBlindDispatchContext{RequestID: "req-1", AssignedSession: "session-a"}
	raw, err = clear.sealInferenceRequestWithRelayBlind(pool.Provider{ProviderID: "provider-a", AssignedID: "session-a"}, "req-1", []byte(`{}`), false, nil, "", nil, without)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, []byte(`"privacy_class"`)) {
		t.Fatalf("empty privacy class was serialized: %s", raw)
	}

	key := bytes.Repeat([]byte{0x11}, 32)
	nonce := []byte{1, 2, 3, 4}
	sealedSession := &providerSession{tier2: &pool.Tier2Session{
		C2PKey: key, P2CKey: key, C2PNonceBase: nonce, P2CNonceBase: nonce, KeyID: "kid-1",
	}}
	provider := pool.Provider{ProviderID: "provider-a", AssignedID: "session-a"}
	raw, err = sealedSession.sealInferenceRequestWithRelayBlind(provider, "req-1", []byte(`{}`), false, nil, "", nil, withClass)
	if err != nil {
		t.Fatal(err)
	}
	var outer encryptedInferenceRequest
	if err := json.Unmarshal(raw, &outer); err != nil {
		t.Fatal(err)
	}
	plain, err := tier2.OpenPillarBFrame(key, nonce, "kid-1", 0, tier2.AEADFrameAAD{
		Type: "inference_request", Direction: "c2p", RequestID: "req-1", Stream: false,
		ProviderID: provider.ProviderID, AssignedID: provider.AssignedID, Seq: 0,
	}, tier2.AEADEnvelope{Encrypted: true, Enc: outer.Enc})
	if err != nil {
		t.Fatal(err)
	}
	var decoded encryptedInferencePlaintext
	if err := json.Unmarshal(plain, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.PrivacyClass != relayblind.PrivacyClassV1 {
		t.Fatalf("protected privacy class = %q", decoded.PrivacyClass)
	}
	if bytes.Contains(raw, []byte(relayblind.PrivacyClassV1)) {
		t.Fatal("privacy class leaked onto the outer encrypted request")
	}
}
