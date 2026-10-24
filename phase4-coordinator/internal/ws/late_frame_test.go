package ws

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
)

// lateFrameHarness is the encrypted relay harness with room for two
// concurrent requests, so a late frame can land beside a live request.
func lateFrameHarness(t *testing.T) (*Server, *pool.Provider, net.Conn, *bytes.Buffer) {
	t.Helper()
	var logs bytes.Buffer
	s, provider, providerConn := newEncryptedRelayHarnessWithConfig(t, config.Default(), zerolog.New(&logs), time.Now())
	provider.SlotsFree, provider.SlotsTotal, provider.MaxConcurrency = 2, 2, 2
	got, ok := s.pool.Resolve("p1", "s1")
	if !ok {
		t.Fatal("provider missing from pool")
	}
	got.SlotsFree, got.SlotsTotal, got.MaxConcurrency = 2, 2, 2
	return s, provider, providerConn, &logs
}

// resetInactiveLogLimit lets the next inactive-frame drop log immediately.
func resetInactiveLogLimit(s *Server) {
	if session, ok := s.storedSessionFor("p1", "s1"); ok {
		session.inactiveLogMu.Lock()
		session.inactiveLogAt = time.Time{}
		session.inactiveLogMu.Unlock()
	}
}

func assertSessionOpen(t *testing.T, s *Server, logs *bytes.Buffer) {
	t.Helper()
	if _, ok := s.storedSessionFor("p1", "s1"); !ok {
		t.Fatalf("provider session closed: %s", logs.String())
	}
	got, ok := s.pool.Resolve("p1", "s1")
	if !ok || got.State != pool.StateReady {
		t.Fatalf("provider not ready after late frame: %#v ok=%v", got, ok)
	}
	if bytes.Contains(logs.Bytes(), []byte(`"event":"aead_decrypt_failed"`)) {
		t.Fatalf("late frame logged an AEAD failure: %s", logs.String())
	}
}

func dispatchAndRead(t *testing.T, s *Server, provider *pool.Provider, providerConn net.Conn, requestID string, stream bool) *RelayStream {
	t.Helper()
	relay, err := s.DispatchInference(context.Background(), *provider, requestID, []byte(`{"model":"model-a"}`), stream)
	if err != nil {
		t.Fatalf("dispatch %s: %v", requestID, err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read inference_request %s: %v", requestID, err)
	}
	return relay
}

// The 2026-10-24 incident: a cancelled request's encrypted end frame arrived
// after its retired entry had expired. The coordinator closed the whole
// provider session and dropped every other in-flight request.
func TestEncryptedRelayLateEndAfterRetiredTTLKeepsSessionAndOtherRequests(t *testing.T) {
	s, provider, providerConn, logs := lateFrameHarness(t)
	session, _ := s.storedSessionFor("p1", "s1")

	cancelled := dispatchAndRead(t, s, provider, providerConn, "req-cancelled", true)
	cancelled.Cancel("buyer_disconnected")
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read cancel_request: %v", err)
	}
	session.activeMu.Lock()
	entry := session.retired["req-cancelled"]
	entry.retiredAt = time.Now().Add(-2 * session.retiredTTL)
	session.retired["req-cancelled"] = entry
	session.activeMu.Unlock()

	live := dispatchAndRead(t, s, provider, providerConn, "req-live", true)
	before := RelayInactiveFrameDroppedTotalForTest()

	s.handleInferenceEnd("p1", "s1", encryptedResponseEnd(t, provider, "req-cancelled", true, 0, InferenceResponseEnd{
		Type: "inference_response_end", RequestID: "req-cancelled", Status: "cancelled",
	}))
	assertSessionOpen(t, s, logs)
	if got := RelayInactiveFrameDroppedTotalForTest() - before; got != 1 {
		t.Fatalf("inactive frame drops = %d, want 1", got)
	}
	if !bytes.Contains(logs.Bytes(), []byte(`"reason":"unknown_request"`)) {
		t.Fatalf("missing structured drop log: %s", logs.String())
	}

	s.handleInferenceChunk("p1", "s1", encryptedResponseChunk(t, provider, "req-live", true, 1, []byte(`{"ok":true}`)))
	s.handleInferenceEnd("p1", "s1", encryptedResponseEnd(t, provider, "req-live", true, 2, InferenceResponseEnd{
		Type: "inference_response_end", RequestID: "req-live", Status: "complete", ChunksSent: 1,
	}))
	select {
	case chunk := <-live.Chunks:
		if chunk.Data != `{"ok":true}` {
			t.Fatalf("live chunk = %#v", chunk)
		}
	case err := <-live.Errors:
		t.Fatalf("live request failed after late frame: %v", err)
	case <-time.After(time.Second):
		t.Fatal("live chunk timeout")
	}
	select {
	case end := <-live.Done:
		if end.Status != "complete" {
			t.Fatalf("live end = %#v", end)
		}
	case <-time.After(time.Second):
		t.Fatal("live end timeout")
	}
	assertSessionOpen(t, s, logs)
	if provider.Tier2Session.P2CCounter != 3 || len(provider.Tier2Session.P2CSeen) != 0 {
		t.Fatalf("p2c counter=%d seen=%d, want 3 and 0: the dropped frame must consume its slot", provider.Tier2Session.P2CCounter, len(provider.Tier2Session.P2CSeen))
	}
}

func TestEncryptedRelayDropsFramesForNeverIssuedRequest(t *testing.T) {
	s, provider, _, logs := lateFrameHarness(t)
	before := RelayInactiveFrameDroppedTotalForTest()

	s.handleInferenceChunk("p1", "s1", encryptedResponseChunk(t, provider, "req-never", false, 0, []byte(`x`)))
	resetInactiveLogLimit(s)
	s.handleInferenceEnd("p1", "s1", encryptedResponseEnd(t, provider, "req-never", false, 1, InferenceResponseEnd{
		Type: "inference_response_end", RequestID: "req-never", Status: "complete",
	}))
	validationAAD := tier2.AEADFrameAAD{Type: "inference_response_validation", Direction: "p2c", RequestID: "req-never", ProviderID: "p1", AssignedID: "s1", Seq: 2}
	validation, err := tier2.SealPillarBFrame(provider.Tier2Session.P2CKey, provider.Tier2Session.P2CNonceBase, provider.Tier2Session.KeyID, 2, validationAAD, []byte(`{}`))
	if err != nil {
		t.Fatalf("seal validation: %v", err)
	}
	resetInactiveLogLimit(s)
	s.handleInferenceValidation("p1", "s1", mustJSON(encryptedInferenceResponseEnd{Type: "inference_response_validation", RequestID: "req-never", Encrypted: true, Enc: validation.Enc}))

	assertSessionOpen(t, s, logs)
	if got := RelayInactiveFrameDroppedTotalForTest() - before; got != 3 {
		t.Fatalf("inactive frame drops = %d, want 3", got)
	}
	if provider.Tier2Session.P2CCounter != 3 {
		t.Fatalf("p2c counter = %d, want 3", provider.Tier2Session.P2CCounter)
	}
	for _, frameType := range []string{"inference_response_chunk", "inference_response_end", "inference_response_validation"} {
		if !bytes.Contains(logs.Bytes(), []byte(`"frame_type":"`+frameType+`"`)) {
			t.Fatalf("missing drop log for %s: %s", frameType, logs.String())
		}
	}
}

// A frame sealed under a key epoch the session no longer holds (an in-band
// rekey committed after it was sealed) cannot be authenticated. Its sequence
// number belongs to the old epoch, so dropping it must not touch the current
// receive window.
func TestEncryptedRelayDropsUnknownFrameFromStaleKeyEpoch(t *testing.T) {
	s, provider, _, logs := lateFrameHarness(t)
	old := *provider.Tier2Session
	old.P2CKey = bytes.Repeat([]byte{0x33}, 32)
	old.KeyID = "retired-kid"
	stale := &pool.Provider{ProviderID: "p1", AssignedID: "s1", Tier2Session: &old}

	s.handleInferenceEnd("p1", "s1", encryptedResponseEnd(t, stale, "req-old-epoch", false, 0, InferenceResponseEnd{
		Type: "inference_response_end", RequestID: "req-old-epoch", Status: "complete",
	}))

	assertSessionOpen(t, s, logs)
	if provider.Tier2Session.P2CCounter != 0 || len(provider.Tier2Session.P2CSeen) != 0 {
		t.Fatalf("stale-epoch frame changed the receive window: counter=%d seen=%d", provider.Tier2Session.P2CCounter, len(provider.Tier2Session.P2CSeen))
	}
	if !bytes.Contains(logs.Bytes(), []byte(`"reason":"stale_key_epoch"`)) {
		t.Fatalf("missing stale_key_epoch drop log: %s", logs.String())
	}
}

// A frame that claims the current key epoch but does not authenticate is not a
// late frame: an authentic late frame always opens under the current key. It
// stays an AEAD failure whatever its request_id says.
func TestEncryptedRelayClosesOnForgedUnknownFrameUnderCurrentKey(t *testing.T) {
	s, provider, _, logs := lateFrameHarness(t)
	forged := *provider.Tier2Session
	forged.P2CKey = bytes.Repeat([]byte{0x44}, 32)
	forger := &pool.Provider{ProviderID: "p1", AssignedID: "s1", Tier2Session: &forged}

	s.handleInferenceEnd("p1", "s1", encryptedResponseEnd(t, forger, "req-forged", false, 0, InferenceResponseEnd{
		Type: "inference_response_end", RequestID: "req-forged", Status: "complete",
	}))

	if _, ok := s.storedSessionFor("p1", "s1"); ok {
		t.Fatal("session stayed open after a forged frame under the current key")
	}
	if !bytes.Contains(logs.Bytes(), []byte(`"event":"aead_decrypt_failed"`)) {
		t.Fatalf("forged frame did not log an AEAD failure: %s", logs.String())
	}
}

// SPEC-008 §6.7.1: an AEAD failure on a frame for a request the coordinator is
// serving still closes the provider session and fails the request.
func TestEncryptedRelayKnownRequestAEADFailureStillClosesSession(t *testing.T) {
	s, provider, providerConn, logs := lateFrameHarness(t)
	relay := dispatchAndRead(t, s, provider, providerConn, "req-known", true)
	forged := *provider.Tier2Session
	forged.P2CKey = bytes.Repeat([]byte{0x55}, 32)
	forger := &pool.Provider{ProviderID: "p1", AssignedID: "s1", Tier2Session: &forged}

	s.handleInferenceChunk("p1", "s1", encryptedResponseChunk(t, forger, "req-known", true, 0, []byte(`x`)))

	if _, ok := s.storedSessionFor("p1", "s1"); ok {
		t.Fatal("session stayed open after an AEAD failure on a known request")
	}
	select {
	case err := <-relay.Errors:
		if err != ErrRelayAEADFailed {
			t.Fatalf("relay error = %v, want ErrRelayAEADFailed", err)
		}
	case <-time.After(time.Second):
		t.Fatal("known request not failed")
	}
	if !bytes.Contains(logs.Bytes(), []byte(`"event":"aead_decrypt_failed"`)) {
		t.Fatalf("missing AEAD failure log: %s", logs.String())
	}
}

func TestRelayDropsPlaintextFramesForUnknownRequest(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()
	var logs bytes.Buffer
	registry := pool.NewRegistry(nil)
	registry.Register(&pool.Provider{ProviderID: "p1", AssignedID: "s1", ModelID: "model-a", InferencePath: pool.InferencePathWSTunneled, State: pool.StateReady, SlotsFree: 1, SlotsTotal: 1, MaxConcurrency: 1}, serverConn)
	s := NewServer(config.Default(), registry, zerolog.New(&logs))
	session := newProviderSession("p1", "s1", serverConn, 1)
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()
	before := RelayInactiveFrameDroppedTotalForTest()

	s.handleInferenceChunk("p1", "s1", mustJSON(InferenceResponseChunk{Type: "inference_response_chunk", RequestID: "req-gone", Seq: 0, Data: "x"}))
	resetInactiveLogLimit(s)
	s.handleInferenceEnd("p1", "s1", mustJSON(InferenceResponseEnd{Type: "inference_response_end", RequestID: "req-gone", Status: "complete"}))
	resetInactiveLogLimit(s)
	s.handleInferenceValidation("p1", "s1", mustJSON(InferenceResponseValidation{Type: "inference_response_validation", RelayBlindValidation: RelayBlindValidation{RequestID: "req-gone"}}))

	if _, ok := s.storedSessionFor("p1", "s1"); !ok {
		t.Fatal("plaintext unknown frames closed the session")
	}
	if got := RelayInactiveFrameDroppedTotalForTest() - before; got != 3 {
		t.Fatalf("inactive frame drops = %d, want 3; logs=%s", got, logs.String())
	}
	if !bytes.Contains(logs.Bytes(), []byte(`"event":"relay_inactive_frame_dropped"`)) {
		t.Fatalf("missing structured drop log: %s", logs.String())
	}
}

func TestRetiredRelayRequestTTLCoversTheRequestWall(t *testing.T) {
	if got := retiredRelayRequestTTL(3600 * time.Second); got != 61*time.Minute {
		t.Fatalf("ttl(3600s) = %s, want 1h1m", got)
	}
	if got := retiredRelayRequestTTL(30 * time.Second); got != retiredRelayRequestTTLFloor {
		t.Fatalf("ttl(30s) = %s, want floor %s", got, retiredRelayRequestTTLFloor)
	}

	cfg := config.Default()
	cfg.Routing.RequestTimeoutS = 7200
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()
	s := NewServer(cfg, pool.NewRegistry(nil), zerolog.Nop())
	session, refusal := s.registerProviderSessionLocked(serverConn, &pool.Provider{ProviderID: "p1", AssignedID: "s1", ModelID: "model-a", InferencePath: pool.InferencePathWSTunneled, State: pool.StateReady})
	if session == nil {
		t.Fatalf("register refused: %s", refusal)
	}
	defer session.close()
	if session.retiredTTL != 121*time.Minute {
		t.Fatalf("session retired TTL = %s, want the 7200 s wall plus grace", session.retiredTTL)
	}
}

func TestRetiredRelayRequestsAreCapped(t *testing.T) {
	session := newProviderSession("p1", "s1", nil, 1)
	start := time.Now()
	for i := 0; i <= maxRetiredRelayRequests; i++ {
		id, _ := json.Marshal(i)
		session.activeMu.Lock()
		session.markRetiredLocked(&relayActive{requestID: "req-" + string(id)}, start.Add(time.Duration(i)*time.Millisecond))
		session.activeMu.Unlock()
	}
	if len(session.retired) != maxRetiredRelayRequests {
		t.Fatalf("retired entries = %d, want cap %d", len(session.retired), maxRetiredRelayRequests)
	}
	if _, ok := session.retired["req-0"]; ok {
		t.Fatal("oldest retired entry survived the cap")
	}
	if _, ok := session.retired["req-8192"]; !ok {
		t.Fatal("newest retired entry missing")
	}
}

// A plaintext frame on a Tier-2 session is an encryption violation only for a
// request the coordinator is serving; for an inactive request it is dropped.
func TestTier2SessionDropsPlaintextFramesForInactiveRequest(t *testing.T) {
	s, _, _, logs := lateFrameHarness(t)
	before := RelayInactiveFrameDroppedTotalForTest()

	s.handleInferenceChunk("p1", "s1", mustJSON(InferenceResponseChunk{Type: "inference_response_chunk", RequestID: "req-gone", Seq: 0, Data: "x"}))
	s.handleInferenceEnd("p1", "s1", mustJSON(InferenceResponseEnd{Type: "inference_response_end", RequestID: "req-gone", Status: "complete"}))
	s.handleInferenceValidation("p1", "s1", mustJSON(InferenceResponseValidation{Type: "inference_response_validation", RequestID: "req-gone"}))

	assertSessionOpen(t, s, logs)
	if got := RelayInactiveFrameDroppedTotalForTest() - before; got != 3 {
		t.Fatalf("inactive frame drops = %d, want 3", got)
	}
}

func TestTier2SessionStillClosesOnPlaintextFrameForActiveRequest(t *testing.T) {
	s, provider, providerConn, _ := lateFrameHarness(t)
	relay := dispatchAndRead(t, s, provider, providerConn, "req-active", true)

	s.handleInferenceChunk("p1", "s1", mustJSON(InferenceResponseChunk{Type: "inference_response_chunk", RequestID: "req-active", Seq: 0, Data: "x"}))

	if _, ok := s.storedSessionFor("p1", "s1"); ok {
		t.Fatal("plaintext chunk for an active request on a Tier-2 session kept the session")
	}
	select {
	case err := <-relay.Errors:
		if err != ErrRelayAEADFailed {
			t.Fatalf("relay error = %v, want ErrRelayAEADFailed", err)
		}
	case <-time.After(time.Second):
		t.Fatal("active request not failed")
	}
}

// A stale-epoch validation frame takes the inactive path before any
// validation-specific AAD check, like chunk and end frames.
func TestEncryptedRelayDropsStaleEpochValidationFrame(t *testing.T) {
	s, provider, _, logs := lateFrameHarness(t)
	aad := tier2.AEADFrameAAD{Type: "inference_response_end", Direction: "p2c", RequestID: "req-old-epoch", ProviderID: "p1", AssignedID: "s1", Seq: 0}
	sealed, err := tier2.SealPillarBFrame(bytes.Repeat([]byte{0x66}, 32), provider.Tier2Session.P2CNonceBase, "retired-kid", 0, aad, []byte(`{}`))
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	s.handleInferenceValidation("p1", "s1", mustJSON(encryptedInferenceResponseEnd{Type: "inference_response_validation", RequestID: "req-old-epoch", Encrypted: true, Enc: sealed.Enc}))

	assertSessionOpen(t, s, logs)
	if provider.Tier2Session.P2CCounter != 0 {
		t.Fatalf("p2c counter = %d, want 0", provider.Tier2Session.P2CCounter)
	}
}

// An authentic frame whose AAD request_id the coordinator could never have
// issued still consumes its sequence slot; only the logged ID is replaced.
func TestEncryptedRelayConsumesUnloggableRequestIDFrame(t *testing.T) {
	s, provider, _, logs := lateFrameHarness(t)
	odd := "req-\x1b[2J"
	s.handleInferenceEnd("p1", "s1", encryptedResponseEnd(t, provider, odd, false, 0, InferenceResponseEnd{Type: "inference_response_end", RequestID: odd, Status: "complete"}))

	assertSessionOpen(t, s, logs)
	if provider.Tier2Session.P2CCounter != 1 {
		t.Fatalf("p2c counter = %d, want 1", provider.Tier2Session.P2CCounter)
	}
	if !bytes.Contains(logs.Bytes(), []byte(`"request_id":"invalid"`)) || bytes.Contains(logs.Bytes(), []byte(`\u001b`)) {
		t.Fatalf("unsafe request_id logged: %s", logs.String())
	}
}

func TestInactiveFrameDropLogsAreRateLimitedPerSession(t *testing.T) {
	s, _, _, logs := lateFrameHarness(t)
	session, _ := s.storedSessionFor("p1", "s1")
	before := RelayInactiveFrameDroppedTotalForTest()
	flood := func() {
		s.handleInferenceEnd("p1", "s1", mustJSON(InferenceResponseEnd{Type: "inference_response_end", RequestID: "req-flood", Status: "complete"}))
	}
	flood()
	// Pin the last log time in the future so the window cannot lapse mid-test.
	session.inactiveLogMu.Lock()
	session.inactiveLogAt = time.Now().Add(time.Hour)
	session.inactiveLogMu.Unlock()
	for i := 0; i < 49; i++ {
		flood()
	}
	if got := RelayInactiveFrameDroppedTotalForTest() - before; got != 50 {
		t.Fatalf("inactive frame drops = %d, want 50", got)
	}
	if got := bytes.Count(logs.Bytes(), []byte(`"event":"relay_inactive_frame_dropped"`)); got != 1 {
		t.Fatalf("drop log lines = %d, want 1", got)
	}
	resetInactiveLogLimit(s)
	flood()
	if !bytes.Contains(logs.Bytes(), []byte(`"suppressed_since_last":49`)) {
		t.Fatalf("suppressed drops not reported: %s", logs.String())
	}
}

func TestPlaintextInactiveFramesAreCountedAndClassified(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()
	var logs bytes.Buffer
	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{ProviderID: "p1", AssignedID: "s1", ModelID: "model-a", InferencePath: pool.InferencePathWSTunneled, State: pool.StateReady, SlotsFree: 1, SlotsTotal: 1, MaxConcurrency: 1}
	registry.Register(provider, serverConn)
	s := NewServer(config.Default(), registry, zerolog.New(&logs))
	session := newProviderSession("p1", "s1", serverConn, 4)
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()
	go func() {
		for {
			if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
				return
			}
		}
	}()
	relay, err := s.DispatchInference(context.Background(), *provider, "req-retired", []byte(`{"model":"model-a"}`), true)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	relay.Cancel("timeout")
	before := RelayInactiveFrameDroppedTotalForTest()

	s.handleInferenceChunk("p1", "s1", mustJSON(InferenceResponseChunk{Type: "inference_response_chunk", RequestID: "req-retired", Seq: 0, Data: "x"}))
	if !bytes.Contains(logs.Bytes(), []byte(`"reason":"retired_request"`)) {
		t.Fatalf("retired plaintext frame not classified: %s", logs.String())
	}
	resetInactiveLogLimit(s)
	s.handleInferenceEnd("p1", "s1", mustJSON(InferenceResponseEnd{Type: "inference_response_end", RequestID: "req-\x1b[2J", Status: "complete"}))
	s.handleInferenceChunk("p1", "s1", mustJSON(InferenceResponseChunk{Type: "inference_response_chunk", RequestID: "req-\x1b[2J", Seq: 0, Data: "x"}))
	s.handleInferenceValidation("p1", "s1", mustJSON(InferenceResponseValidation{Type: "inference_response_validation", RequestID: "req-\x1b[2J"}))

	if got := RelayInactiveFrameDroppedTotalForTest() - before; got != 4 {
		t.Fatalf("inactive frame drops = %d, want 4", got)
	}
	if bytes.Contains(logs.Bytes(), []byte(`\u001b`)) {
		t.Fatalf("control characters reached the log: %s", logs.String())
	}
	if _, ok := s.storedSessionFor("p1", "s1"); !ok {
		t.Fatal("session closed")
	}
}

// An encrypted frame whose AAD does not decode is a stale-epoch drop when its
// kid is not current, and an AEAD failure when it is.
func TestEncryptedRelayUndecodableAADFollowsKeyEpoch(t *testing.T) {
	undecodable := func(t *testing.T, provider *pool.Provider, kid string) []byte {
		t.Helper()
		var envelope encryptedInferenceResponseEnd
		if err := json.Unmarshal(encryptedResponseEnd(t, provider, "req-x", false, 0, InferenceResponseEnd{Type: "inference_response_end", RequestID: "req-x", Status: "complete"}), &envelope); err != nil {
			t.Fatal(err)
		}
		envelope.Enc.AAD = "not-base64!"
		envelope.Enc.KID = kid
		return mustJSON(envelope)
	}

	s, provider, _, logs := lateFrameHarness(t)
	s.handleInferenceEnd("p1", "s1", undecodable(t, provider, "retired-kid"))
	assertSessionOpen(t, s, logs)
	if provider.Tier2Session.P2CCounter != 0 {
		t.Fatalf("p2c counter = %d, want 0", provider.Tier2Session.P2CCounter)
	}

	s, provider, _, _ = lateFrameHarness(t)
	s.handleInferenceEnd("p1", "s1", undecodable(t, provider, provider.Tier2Session.KeyID))
	if _, ok := s.storedSessionFor("p1", "s1"); ok {
		t.Fatal("undecodable current-epoch frame kept the session")
	}
}

func TestRetiredRelayRequestCapKeepsArmedCancelTerminal(t *testing.T) {
	session := newProviderSession("p1", "s1", nil, 1)
	start := time.Now()
	session.activeMu.Lock()
	session.markRetiredLocked(&relayActive{requestID: "req-armed"}, start)
	armed := session.retired["req-armed"]
	armed.cancelTerminal = make(chan InferenceResponseEnd, 1)
	session.retired["req-armed"] = armed
	for i := 1; i <= maxRetiredRelayRequests; i++ {
		id, _ := json.Marshal(i)
		session.markRetiredLocked(&relayActive{requestID: "req-" + string(id)}, start.Add(time.Duration(i)*time.Millisecond))
	}
	session.activeMu.Unlock()
	if _, ok := session.retired["req-armed"]; !ok {
		t.Fatal("armed cancel-terminal entry evicted")
	}
	if _, ok := session.retired["req-1"]; ok {
		t.Fatal("oldest unarmed entry survived the cap")
	}
	if len(session.retired) != maxRetiredRelayRequests {
		t.Fatalf("retired entries = %d, want %d", len(session.retired), maxRetiredRelayRequests)
	}
}
