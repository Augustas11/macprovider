package ws

import (
	"bytes"
	"encoding/json"
	"errors"
	"net"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
)

func TestProviderInboundMessageLimitNormalizesAdvertisedValue(t *testing.T) {
	for _, tc := range []struct{ advertised, want int64 }{
		{0, LegacyProviderWSMaxMessageBytes},
		{-5, LegacyProviderWSMaxMessageBytes},
		{LegacyProviderWSMaxMessageBytes - 1, LegacyProviderWSMaxMessageBytes},
		{LegacyProviderWSMaxMessageBytes, LegacyProviderWSMaxMessageBytes},
		{8 << 20, 8 << 20},
		{MaxProviderWSMaxMessageBytes, MaxProviderWSMaxMessageBytes},
		{MaxProviderWSMaxMessageBytes + 1, MaxProviderWSMaxMessageBytes},
	} {
		if got := providerInboundMessageLimit(tc.advertised); got != tc.want {
			t.Fatalf("advertised %d: limit %d, want %d", tc.advertised, got, tc.want)
		}
	}
}

func TestTier2CapsParsesWSMaxMessageBytes(t *testing.T) {
	var caps Tier2Caps
	if err := json.Unmarshal([]byte(`{"encrypted_leg":true,"ws_max_message_bytes":67108864}`), &caps); err != nil {
		t.Fatal(err)
	}
	if caps.WSMaxMessageBytes != 64<<20 {
		t.Fatalf("ws_max_message_bytes = %d", caps.WSMaxMessageBytes)
	}
	caps = Tier2Caps{}
	if err := json.Unmarshal([]byte(`{"encrypted_leg":true}`), &caps); err != nil {
		t.Fatal(err)
	}
	if providerInboundMessageLimit(caps.WSMaxMessageBytes) != LegacyProviderWSMaxMessageBytes {
		t.Fatal("a provider that does not advertise must get the legacy 1 MiB limit")
	}
}

func TestNewProviderSessionDefaultsToLegacyMessageLimit(t *testing.T) {
	ps := newProviderSession("p", "a", nil, 4)
	if ps.maxTextFrameBytes != LegacyProviderWSMaxMessageBytes {
		t.Fatalf("default limit %d", ps.maxTextFrameBytes)
	}
}

// An over-limit text frame is refused before it reaches the wire and the
// session stays open for the next frame (SPEC-001-R012).
func TestEnqueueFrameRefusesOverLimitTextFrameAndKeepsSession(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()
	ps := newProviderSession("p", "a", server, 4)
	ps.maxTextFrameBytes = 1024
	if err := ps.send(bytes.Repeat([]byte{'x'}, 1025)); !errors.Is(err, ErrProviderFrameTooLarge) {
		t.Fatalf("over-limit send err = %v", err)
	}
	if !ps.isOpen() {
		t.Fatal("session closed after an over-limit frame")
	}
	if len(ps.writeCh) != 0 {
		t.Fatal("over-limit frame was queued")
	}
	if err := ps.send(bytes.Repeat([]byte{'x'}, 1024)); err != nil {
		t.Fatalf("at-limit send err = %v", err)
	}
	if len(ps.writeCh) != 1 {
		t.Fatal("at-limit frame was not queued")
	}
	// Raw control frames are not text messages and are never size-checked.
	if err := ps.enqueueFrame(providerFrame{raw: true, payload: bytes.Repeat([]byte{0}, 2048)}); err != nil {
		t.Fatalf("raw frame err = %v", err)
	}
}

func sealedSizeTestSession() (*providerSession, []byte, []byte) {
	key := bytes.Repeat([]byte{0x11}, 32)
	nonce := []byte{1, 2, 3, 4}
	ps := &providerSession{tier2: &pool.Tier2Session{
		C2PKey: key, P2CKey: key, C2PNonceBase: nonce, P2CNonceBase: nonce, KeyID: "kid-1",
	}}
	return ps, key, nonce
}

func chatBody(n int) []byte {
	prefix := `{"model":"m","messages":[{"role":"user","content":"`
	suffix := `"}]}`
	return []byte(prefix + strings.Repeat("a", n) + suffix)
}

// A frame exactly at the provider's limit is sealed; a larger one is refused
// before sealing, leaving the c2p counter where the provider expects it, so
// the next request still opens (SPEC-001-R012).
func TestSealInferenceRequestEnforcesProviderMessageLimitWithoutSpendingSeq(t *testing.T) {
	provider := pool.Provider{ProviderID: "provider-a", AssignedID: "session-a"}
	const n = 48_000
	probe, _, _ := sealedSizeTestSession()
	probe.maxTextFrameBytes = 0
	atLimit, err := probe.sealInferenceRequest(provider, "req-near", chatBody(n), false, nil, "")
	if err != nil {
		t.Fatal(err)
	}
	limit := int64(len(atLimit))

	ps, key, nonce := sealedSizeTestSession()
	ps.maxTextFrameBytes = limit
	raw, err := ps.sealInferenceRequest(provider, "req-near", chatBody(n), false, nil, "")
	if err != nil {
		t.Fatalf("at-limit frame refused: %v", err)
	}
	if int64(len(raw)) != limit {
		t.Fatalf("at-limit frame is %d bytes, limit %d", len(raw), limit)
	}
	if ps.tier2.C2PCounter != 1 {
		t.Fatalf("counter after at-limit seal = %d", ps.tier2.C2PCounter)
	}
	// Three more plaintext bytes add four base64 bytes.
	if _, err := ps.sealInferenceRequest(provider, "req-near", chatBody(n+3), false, nil, ""); !errors.Is(err, ErrProviderFrameTooLarge) {
		t.Fatalf("over-limit seal err = %v", err)
	}
	if ps.tier2.C2PCounter != 1 {
		t.Fatalf("over-limit seal spent a sequence number: counter %d", ps.tier2.C2PCounter)
	}
	small, err := ps.sealInferenceRequest(provider, "req-next", chatBody(1), false, nil, "")
	if err != nil {
		t.Fatal(err)
	}
	var outer encryptedInferenceRequest
	if err := json.Unmarshal(small, &outer); err != nil {
		t.Fatal(err)
	}
	if _, err := tier2.OpenPillarBFrame(key, nonce, "kid-1", 1, tier2.AEADFrameAAD{
		Type: "inference_request", Direction: "c2p", RequestID: "req-next",
		ProviderID: provider.ProviderID, AssignedID: provider.AssignedID, Seq: 1,
	}, tier2.AEADEnvelope{Encrypted: true, Enc: outer.Enc}); err != nil {
		t.Fatalf("next request does not open at the provider's expected seq: %v", err)
	}
}

func TestSealPlaintextInferenceRequestEnforcesProviderMessageLimit(t *testing.T) {
	provider := pool.Provider{ProviderID: "provider-a", AssignedID: "session-a"}
	ps := &providerSession{maxTextFrameBytes: 4096}
	raw, err := ps.sealInferenceRequest(provider, "req-1", chatBody(10), false, nil, "")
	if err != nil {
		t.Fatal(err)
	}
	ps.maxTextFrameBytes = int64(len(raw))
	if _, err := ps.sealInferenceRequest(provider, "req-1", chatBody(10), false, nil, ""); err != nil {
		t.Fatalf("at-limit plaintext frame refused: %v", err)
	}
	if _, err := ps.sealInferenceRequest(provider, "req-1", chatBody(11), false, nil, ""); !errors.Is(err, ErrProviderFrameTooLarge) {
		t.Fatalf("over-limit plaintext frame err = %v", err)
	}
}

// The live incident: a 783,886-byte chat body of source code (quotes and
// newlines escaped once in the body, again in the sealed plaintext) becomes a
// frame over the legacy 1 MiB provider limit after base64; the advertised
// 64 MiB limit takes it.
func TestLegacyLimitRefusesIncidentSizedRequestThatAdvertisedLimitAccepts(t *testing.T) {
	provider := pool.Provider{ProviderID: "provider-a", AssignedID: "session-a"}
	line := `    let value = \"name\"\n`
	prefix := `{"model":"m","stream":true,"messages":[{"role":"user","content":"`
	suffix := `"}]}`
	content := strings.Repeat(line, (783_886-len(prefix)-len(suffix))/len(line))
	body := []byte(prefix + content + suffix)
	legacy, _, _ := sealedSizeTestSession()
	legacy.maxTextFrameBytes = providerInboundMessageLimit(0)
	if _, err := legacy.sealInferenceRequest(provider, "req-big", body, true, nil, ""); !errors.Is(err, ErrProviderFrameTooLarge) {
		t.Fatalf("legacy provider (%d-byte body) err = %v, want ErrProviderFrameTooLarge", len(body), err)
	}
	current, _, _ := sealedSizeTestSession()
	current.maxTextFrameBytes = providerInboundMessageLimit(MaxProviderWSMaxMessageBytes)
	raw, err := current.sealInferenceRequest(provider, "req-big", body, true, nil, "")
	if err != nil {
		t.Fatalf("64 MiB provider refused the request: %v", err)
	}
	if int64(len(raw)) <= LegacyProviderWSMaxMessageBytes {
		t.Fatalf("frame %d bytes does not exceed the legacy limit", len(raw))
	}
	t.Logf("%d-byte body -> %d-byte frame", len(body), len(raw))
}

// The largest chat body the gateway and coordinator accept by default (4 MiB,
// SPEC-006) fits a provider advertising the 64 MiB limit even when every
// content byte takes Go's worst-case six-byte JSON escape before base64.
func TestMaximumChatBodyWorstCaseEscapingFitsAdvertisedLimit(t *testing.T) {
	provider := pool.Provider{ProviderID: "provider-a", AssignedID: "session-a"}
	const maxBody = 4 << 20
	prefix := `{"model":"m","messages":[{"role":"user","content":"`
	suffix := `"}]}`
	body := []byte(prefix + strings.Repeat("<", maxBody-len(prefix)-len(suffix)) + suffix)
	ps, _, _ := sealedSizeTestSession()
	ps.maxTextFrameBytes = providerInboundMessageLimit(MaxProviderWSMaxMessageBytes)
	raw, err := ps.sealInferenceRequest(provider, "req-max", body, true, nil, "")
	if err != nil {
		t.Fatalf("worst-case %d-byte body refused: %v", len(body), err)
	}
	t.Logf("%d-byte worst-case body -> %d-byte frame (limit %d)", len(body), len(raw), MaxProviderWSMaxMessageBytes)
}
