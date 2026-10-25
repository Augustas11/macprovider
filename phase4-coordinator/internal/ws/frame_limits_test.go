package ws

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/gobwas/ws/wsutil"
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
	// Absent or not an int64 JSON integer: decoded as not advertised, and the
	// rest of the capability object still parses (SPEC-001-R012).
	for _, raw := range []string{
		`{"encrypted_leg":true}`,
		`{"encrypted_leg":true,"ws_max_message_bytes":"67108864"}`,
		`{"encrypted_leg":true,"ws_max_message_bytes":1.5}`,
		`{"encrypted_leg":true,"ws_max_message_bytes":1e9}`,
		`{"encrypted_leg":true,"ws_max_message_bytes":{"n":1}}`,
		`{"encrypted_leg":true,"ws_max_message_bytes":null}`,
		`{"encrypted_leg":true,"ws_max_message_bytes":99999999999999999999999}`,
	} {
		caps = Tier2Caps{}
		if err := json.Unmarshal([]byte(raw), &caps); err != nil {
			t.Fatalf("%s: %v", raw, err)
		}
		if !caps.EncryptedLeg {
			t.Fatalf("%s: other capabilities lost", raw)
		}
		if providerInboundMessageLimit(int64(caps.WSMaxMessageBytes)) != LegacyProviderWSMaxMessageBytes {
			t.Fatalf("%s: limit %d, want legacy 1 MiB", raw, caps.WSMaxMessageBytes)
		}
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
	// A closed session reports closed, not too-large, so a dead provider is
	// never misreported as a buyer size error.
	ps.close()
	if err := ps.send(bytes.Repeat([]byte{'x'}, 1025)); !errors.Is(err, ErrRelayClosed) {
		t.Fatalf("over-limit send on closed session err = %v, want ErrRelayClosed", err)
	}
	ps = newProviderSession("p", "a", server, 4)
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

// Through the real dispatch path: an over-limit encrypted request is refused
// without spending the C2P sequence, the rekey request count, or the session;
// the next request goes out at sequence 0.
func TestDispatchRefusesOverLimitRequestAndKeepsSessionInStep(t *testing.T) {
	s, provider, providerConn := newEncryptedRelayHarness(t)
	big := chatBody(int(LegacyProviderWSMaxMessageBytes))
	if _, err := s.DispatchInference(context.Background(), *provider, "req-big", big, true); !errors.Is(err, ErrProviderFrameTooLarge) {
		t.Fatalf("dispatch err = %v, want ErrProviderFrameTooLarge", err)
	}
	if provider.Tier2Session.C2PCounter != 0 || provider.Tier2Session.RequestsDispatched != 0 {
		t.Fatalf("refusal spent state: c2p=%d dispatched=%d", provider.Tier2Session.C2PCounter, provider.Tier2Session.RequestsDispatched)
	}
	session, ok := s.storedSessionFor("p1", "s1")
	if !ok || !session.isOpen() {
		t.Fatal("session closed after a refused request")
	}
	if p, ok := s.pool.Resolve("p1", "s1"); !ok || p.State != pool.StateReady {
		t.Fatalf("provider after refusal: ok=%v state=%v", ok, p.State)
	}
	if _, err := s.DispatchInference(context.Background(), *provider, "req-next", chatBody(10), true); err != nil {
		t.Fatalf("next dispatch: %v", err)
	}
	_ = providerConn.SetReadDeadline(time.Now().Add(2 * time.Second))
	payload, _, err := wsutil.ReadServerData(providerConn)
	if err != nil {
		t.Fatalf("read next inference_request: %v", err)
	}
	var outer encryptedInferenceRequest
	if err := json.Unmarshal(payload, &outer); err != nil {
		t.Fatal(err)
	}
	if outer.RequestID != "req-next" || outer.Enc.Seq != 0 {
		t.Fatalf("next frame request=%q seq=%d, want req-next at seq 0", outer.RequestID, outer.Enc.Seq)
	}
}

// A refusal undoes the dispatch count on the Tier-2 epoch it was counted
// against, even when a rekey installed a new epoch in between.
func TestUnmarkTier2RequestDispatchedTargetsCountedEpoch(t *testing.T) {
	epochA := &pool.Tier2Session{KeyID: "a"}
	epochB := &pool.Tier2Session{KeyID: "b", RequestsDispatched: 5}
	ps := &providerSession{tier2: epochA}
	marked := ps.markTier2RequestDispatched()
	if marked != epochA || epochA.RequestsDispatched != 1 {
		t.Fatalf("mark: epoch %v count %d", marked, epochA.RequestsDispatched)
	}
	ps.tier2 = epochB
	ps.unmarkTier2RequestDispatched(marked)
	if epochA.RequestsDispatched != 0 || epochB.RequestsDispatched != 5 {
		t.Fatalf("rollback hit the wrong epoch: a=%d b=%d", epochA.RequestsDispatched, epochB.RequestsDispatched)
	}
	ps.unmarkTier2RequestDispatched(nil)
	ps.unmarkTier2RequestDispatched(epochA)
	if epochA.RequestsDispatched != 0 {
		t.Fatal("rollback went below zero")
	}
}

// A sealed encrypted frame that cannot be queued has spent a C2P sequence
// number the provider never sees, so the session ends instead of staying out
// of step.
func TestEncryptedDispatchEndsSessionWhenSealedFrameCannotBeQueued(t *testing.T) {
	s, provider, _ := newEncryptedRelayHarness(t)
	session, ok := s.storedSessionFor("p1", "s1")
	if !ok {
		t.Fatal("no session")
	}
	// Nobody reads the provider side: the writer blocks on its first frame and
	// the queue then fills. Wait until the writer holds the first frame, or it
	// frees a queue slot after the fill and the dispatch below gets queued.
	if err := session.send([]byte(`{"type":"warm_up"}`)); err != nil {
		t.Fatalf("first send: %v", err)
	}
	for deadline := time.Now().Add(time.Second); len(session.writeCh) != 0; {
		if time.Now().After(deadline) {
			t.Fatal("writer never took the first frame")
		}
		time.Sleep(time.Millisecond)
	}
	full := false
	for i := 0; i < 64 && !full; i++ {
		full = errors.Is(session.send([]byte(`{"type":"warm_up"}`)), ErrRelayBackpressure)
	}
	if !full {
		t.Fatalf("write queue never filled (len %d cap %d)", len(session.writeCh), cap(session.writeCh))
	}
	if _, err := s.DispatchInference(context.Background(), *provider, "req-full", chatBody(10), true); !errors.Is(err, ErrRelayClosed) {
		t.Fatalf("dispatch err = %v, want ErrRelayClosed", err)
	}
	if provider.Tier2Session.C2PCounter != 1 {
		t.Fatalf("c2p counter %d, want the spent sequence 1", provider.Tier2Session.C2PCounter)
	}
	if _, ok := s.storedSessionFor("p1", "s1"); ok {
		t.Fatal("out-of-step session kept")
	}
}
