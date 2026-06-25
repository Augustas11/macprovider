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
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
)

func TestRelayDispatchRoutesChunkAndEndByRequestID(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{
		ProviderID:     "p1",
		AssignedID:     "s1",
		ModelID:        "model-a",
		Tier:           pool.TierProvisional,
		InferencePath:  pool.InferencePathWSTunneled,
		State:          pool.StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 1,
	}
	registry.Register(provider, serverConn)
	s := NewServer(config.Default(), registry, zerolog.Nop())
	session := newProviderSession("p1", "s1", serverConn, 1)
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()

	relay, err := s.DispatchInference(context.Background(), *provider, "req-test", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	payload, op, err := wsutil.ReadServerData(providerConn)
	if err != nil {
		t.Fatalf("read inference_request: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}
	var req InferenceRequest
	if err := json.Unmarshal(payload, &req); err != nil {
		t.Fatalf("request json: %v", err)
	}
	if req.Type != "inference_request" || req.RequestID != "req-test" {
		t.Fatalf("request = %#v", req)
	}

	s.handleInferenceChunk("p1", "s1", mustJSON(InferenceResponseChunk{Type: "inference_response_chunk", RequestID: "req-test", Seq: 0, Data: `{"ok":true}`}))
	s.handleInferenceEnd("p1", "s1", mustJSON(InferenceResponseEnd{Type: "inference_response_end", RequestID: "req-test", Status: "complete", ChunksSent: 1}))

	select {
	case chunk := <-relay.Chunks:
		if chunk.Data != `{"ok":true}` {
			t.Fatalf("chunk = %#v", chunk)
		}
	case <-time.After(time.Second):
		t.Fatal("chunk timeout")
	}
	select {
	case end := <-relay.Done:
		if end.Status != "complete" {
			t.Fatalf("end = %#v", end)
		}
	case <-time.After(time.Second):
		t.Fatal("end timeout")
	}
}

func TestEncryptedRelayDispatchEncryptsRequestBody(t *testing.T) {
	s, provider, providerConn := newEncryptedRelayHarness(t)

	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"secret prompt"}]}`)
	_, err := s.DispatchInference(context.Background(), *provider, "req-encrypted", body, true)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	payload, op, err := wsutil.ReadServerData(providerConn)
	if err != nil {
		t.Fatalf("read encrypted inference_request: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}
	if bytes.Contains(payload, []byte("secret prompt")) || bytes.Contains(payload, []byte(`"body"`)) {
		t.Fatalf("encrypted request leaked plaintext body: %s", payload)
	}
	var req encryptedInferenceRequest
	if err := json.Unmarshal(payload, &req); err != nil {
		t.Fatalf("encrypted request json: %v", err)
	}
	if req.Type != "inference_request" || req.RequestID != "req-encrypted" || !req.Stream || !req.Encrypted {
		t.Fatalf("encrypted request = %+v", req)
	}
	aad := tier2.AEADFrameAAD{
		Type:       "inference_request",
		Direction:  "c2p",
		RequestID:  "req-encrypted",
		Stream:     true,
		ProviderID: provider.ProviderID,
		AssignedID: provider.AssignedID,
		Seq:        0,
	}
	opened, err := tier2.OpenPillarBFrame(provider.Tier2Session.C2PKey, provider.Tier2Session.C2PNonceBase, provider.Tier2Session.KeyID, 0, aad, tier2.AEADEnvelope{Encrypted: req.Encrypted, Enc: req.Enc})
	if err != nil {
		t.Fatalf("open encrypted request: %v", err)
	}
	if !bytes.Equal(opened, body) {
		t.Fatalf("opened request = %s, want %s", opened, body)
	}
	if provider.Tier2Session.C2PCounter != 1 {
		t.Fatalf("c2p counter = %d, want 1", provider.Tier2Session.C2PCounter)
	}
}

func TestEncryptedRelayDecryptsResponseChunk(t *testing.T) {
	s, provider, providerConn := newEncryptedRelayHarness(t)
	relay, err := s.DispatchInference(context.Background(), *provider, "req-response", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request: %v", err)
	}

	s.handleInferenceChunk("p1", "s1", encryptedResponseChunk(t, provider, "req-response", false, 0, []byte(`{"ok":true}`)))

	select {
	case chunk := <-relay.Chunks:
		if chunk.RequestID != "req-response" || chunk.Data != `{"ok":true}` {
			t.Fatalf("decrypted chunk = %#v", chunk)
		}
	case <-time.After(time.Second):
		t.Fatal("decrypted chunk timeout")
	}
	if provider.Tier2Session.P2CCounter != 1 {
		t.Fatalf("p2c counter = %d, want 1", provider.Tier2Session.P2CCounter)
	}
}

func TestEncryptedRelayDecryptsResponseEnd(t *testing.T) {
	s, provider, providerConn := newEncryptedRelayHarness(t)
	relay, err := s.DispatchInference(context.Background(), *provider, "req-end", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request: %v", err)
	}

	s.handleInferenceEnd("p1", "s1", encryptedResponseEnd(t, provider, "req-end", false, 0, InferenceResponseEnd{Type: "inference_response_end", RequestID: "req-end", Status: "complete", ChunksSent: 0}))

	select {
	case end := <-relay.Done:
		if end.RequestID != "req-end" || end.Status != "complete" {
			t.Fatalf("decrypted end = %#v", end)
		}
	case <-time.After(time.Second):
		t.Fatal("decrypted end timeout")
	}
	if provider.Tier2Session.P2CCounter != 1 {
		t.Fatalf("p2c counter = %d, want 1", provider.Tier2Session.P2CCounter)
	}
}

func TestEncryptedRelayDropsLateEndForRetiredRequest(t *testing.T) {
	var logs bytes.Buffer
	s, provider, providerConn := newEncryptedRelayHarnessWithConfig(t, config.Default(), zerolog.New(&logs), time.Now())
	relay, err := s.DispatchInference(context.Background(), *provider, "req-late-end", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request: %v", err)
	}
	relay.Cancel("buyer_disconnected")
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read cancel_request: %v", err)
	}

	s.handleInferenceEnd("p1", "s1", encryptedResponseEnd(t, provider, "req-late-end", false, 0, InferenceResponseEnd{
		Type:       "inference_response_end",
		RequestID:  "req-late-end",
		Status:     "complete",
		ChunksSent: 0,
	}))

	if _, ok := s.storedSessionFor("p1", "s1"); !ok {
		t.Fatal("session closed after valid late encrypted end for retired request")
	}
	got, ok := s.pool.Resolve("p1", "s1")
	if !ok {
		t.Fatal("provider missing from pool")
	}
	if got.State != pool.StateReady {
		t.Fatalf("provider state = %s, want ready", got.State)
	}
	if provider.Tier2Session.P2CCounter != 1 {
		t.Fatalf("p2c counter = %d, want 1", provider.Tier2Session.P2CCounter)
	}
	if bytes.Contains(logs.Bytes(), []byte(`"event":"aead_decrypt_failed"`)) {
		t.Fatalf("late retired end logged AEAD failure: %s", logs.String())
	}
	if !bytes.Contains(logs.Bytes(), []byte("late encrypted inference_response_end for retired request dropped")) {
		t.Fatalf("missing late-drop log: %s", logs.String())
	}
}

func TestEncryptedRelayDropsLateChunkForRetiredRequest(t *testing.T) {
	var logs bytes.Buffer
	s, provider, providerConn := newEncryptedRelayHarnessWithConfig(t, config.Default(), zerolog.New(&logs), time.Now())
	relay, err := s.DispatchInference(context.Background(), *provider, "req-late-chunk", []byte(`{"model":"model-a"}`), true)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request: %v", err)
	}
	relay.Cancel("buyer_disconnected")
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read cancel_request: %v", err)
	}

	s.handleInferenceChunk("p1", "s1", encryptedResponseChunk(t, provider, "req-late-chunk", true, 0, []byte(`{"ok":true}`)))

	if _, ok := s.storedSessionFor("p1", "s1"); !ok {
		t.Fatal("session closed after valid late encrypted chunk for retired request")
	}
	got, ok := s.pool.Resolve("p1", "s1")
	if !ok {
		t.Fatal("provider missing from pool")
	}
	if got.State != pool.StateReady {
		t.Fatalf("provider state = %s, want ready", got.State)
	}
	if provider.Tier2Session.P2CCounter != 1 {
		t.Fatalf("p2c counter = %d, want 1", provider.Tier2Session.P2CCounter)
	}
	if bytes.Contains(logs.Bytes(), []byte(`"event":"aead_decrypt_failed"`)) {
		t.Fatalf("late retired chunk logged AEAD failure: %s", logs.String())
	}
	if !bytes.Contains(logs.Bytes(), []byte("late encrypted inference_response_chunk for retired request dropped")) {
		t.Fatalf("missing late-drop log: %s", logs.String())
	}
}

func TestEncryptedRelayRejectsLateRetiredFrameTypeMismatch(t *testing.T) {
	s, provider, providerConn := newEncryptedRelayHarness(t)
	relay, err := s.DispatchInference(context.Background(), *provider, "req-late-mismatch", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request: %v", err)
	}
	relay.Cancel("buyer_disconnected")
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read cancel_request: %v", err)
	}

	s.handleInferenceEnd("p1", "s1", encryptedResponseChunk(t, provider, "req-late-mismatch", false, 0, []byte(`{"ok":true}`)))

	if _, ok := s.storedSessionFor("p1", "s1"); ok {
		t.Fatal("session still stored after late retired frame type mismatch")
	}
	got, ok := s.pool.Resolve("p1", "s1")
	if !ok {
		t.Fatal("provider missing from pool")
	}
	if got.State != pool.StateUnavailable {
		t.Fatalf("provider state = %s, want unavailable", got.State)
	}
	if provider.Tier2Session.P2CCounter != 0 {
		t.Fatalf("p2c counter = %d, want 0", provider.Tier2Session.P2CCounter)
	}
}

func TestEncryptedRelayRekeysAfterRequestThreshold(t *testing.T) {
	var logs bytes.Buffer
	cfg := config.Default()
	cfg.Tier2.EncryptedLegRekeyAfterRequests = 1
	s, provider, providerConn := newEncryptedRelayHarnessWithConfig(t, cfg, zerolog.New(&logs), time.Now())

	relay, err := s.DispatchInference(context.Background(), *provider, "req-rekey", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request: %v", err)
	}
	s.handleInferenceChunk("p1", "s1", encryptedResponseChunk(t, provider, "req-rekey", false, 0, []byte(`{"ok":true}`)))
	s.handleInferenceEnd("p1", "s1", encryptedResponseEnd(t, provider, "req-rekey", false, 1, InferenceResponseEnd{Type: "inference_response_end", RequestID: "req-rekey", Status: "complete", ChunksSent: 1}))

	select {
	case end := <-relay.Done:
		if end.Status != "complete" {
			t.Fatalf("end = %#v", end)
		}
	case <-time.After(time.Second):
		t.Fatal("end timeout")
	}
	if _, ok := s.storedSessionFor("p1", "s1"); ok {
		t.Fatal("session still stored after request-threshold rekey")
	}
	got, ok := s.pool.Resolve("p1", "s1")
	if !ok {
		t.Fatal("provider not found")
	}
	if got.State != pool.StateUnavailable {
		t.Fatalf("state = %s, want unavailable", got.State)
	}
	if !bytes.Contains(logs.Bytes(), []byte(`"event":"aead_rekey"`)) || !bytes.Contains(logs.Bytes(), []byte(`"reason":"request_threshold"`)) {
		t.Fatalf("missing request-threshold rekey log: %s", logs.String())
	}
}

func TestEncryptedRelayDefersRekeyCloseUntilActiveCompletes(t *testing.T) {
	var logs bytes.Buffer
	cfg := config.Default()
	cfg.Tier2.EncryptedLegRekeyAfterRequests = 1
	s, provider, providerConn := newEncryptedRelayHarnessWithConfig(t, cfg, zerolog.New(&logs), time.Now())
	provider.MaxConcurrency = 2

	relay, err := s.DispatchInference(context.Background(), *provider, "req-rekey-active", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("first dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request: %v", err)
	}
	if _, err := s.DispatchInference(context.Background(), *provider, "req-rekey-second", []byte(`{"model":"model-a"}`), false); err != ErrRelayBackpressure {
		t.Fatalf("second dispatch = %v, want ErrRelayBackpressure while first request drains", err)
	}
	if _, ok := s.storedSessionFor("p1", "s1"); !ok {
		t.Fatal("session closed before active request completed")
	}

	s.handleInferenceChunk("p1", "s1", encryptedResponseChunk(t, provider, "req-rekey-active", false, 0, []byte(`{"ok":true}`)))
	s.handleInferenceEnd("p1", "s1", encryptedResponseEnd(t, provider, "req-rekey-active", false, 1, InferenceResponseEnd{Type: "inference_response_end", RequestID: "req-rekey-active", Status: "complete", ChunksSent: 1}))

	select {
	case end := <-relay.Done:
		if end.Status != "complete" {
			t.Fatalf("end = %#v", end)
		}
	case <-time.After(time.Second):
		t.Fatal("end timeout")
	}
	if _, ok := s.storedSessionFor("p1", "s1"); ok {
		t.Fatal("session still stored after drained rekey")
	}
	if !bytes.Contains(logs.Bytes(), []byte(`"event":"aead_rekey"`)) || !bytes.Contains(logs.Bytes(), []byte(`"reason":"request_threshold"`)) {
		t.Fatalf("missing request-threshold rekey log: %s", logs.String())
	}
}

func TestEncryptedRelayRekeysExpiredSessionBeforeDispatch(t *testing.T) {
	var logs bytes.Buffer
	cfg := config.Default()
	cfg.Tier2.EncryptedLegRekeyAfterSeconds = 1
	s, provider, _ := newEncryptedRelayHarnessWithConfig(t, cfg, zerolog.New(&logs), time.Now().Add(-2*time.Second))

	if _, err := s.DispatchInference(context.Background(), *provider, "req-expired", []byte(`{"model":"model-a"}`), false); err != ErrRelayClosed {
		t.Fatalf("dispatch = %v, want ErrRelayClosed", err)
	}
	if provider.Tier2Session.C2PCounter != 0 {
		t.Fatalf("c2p counter = %d, want 0", provider.Tier2Session.C2PCounter)
	}
	if provider.Tier2Session.RequestsDispatched != 0 {
		t.Fatalf("requests dispatched = %d, want 0", provider.Tier2Session.RequestsDispatched)
	}
	got, ok := s.pool.Resolve("p1", "s1")
	if !ok {
		t.Fatal("provider not found")
	}
	if got.State != pool.StateUnavailable {
		t.Fatalf("state = %s, want unavailable", got.State)
	}
	if !bytes.Contains(logs.Bytes(), []byte(`"event":"aead_rekey"`)) || !bytes.Contains(logs.Bytes(), []byte(`"reason":"age_threshold"`)) {
		t.Fatalf("missing age-threshold rekey log: %s", logs.String())
	}
}

func TestEncryptedRelayRejectsTamperedResponseChunk(t *testing.T) {
	s, provider, providerConn := newEncryptedRelayHarness(t)
	relay, err := s.DispatchInference(context.Background(), *provider, "req-tampered", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request: %v", err)
	}

	var chunk encryptedInferenceResponseChunk
	if err := json.Unmarshal(encryptedResponseChunk(t, provider, "req-tampered", false, 0, []byte(`{"ok":true}`)), &chunk); err != nil {
		t.Fatalf("encrypted chunk json: %v", err)
	}
	chunk.Enc.Tag = "AAAAAAAAAAAAAAAAAAAAAA"
	s.handleInferenceChunk("p1", "s1", mustJSON(chunk))

	select {
	case err := <-relay.Errors:
		if err != ErrRelayAEADFailed {
			t.Fatalf("err = %v, want ErrRelayAEADFailed", err)
		}
	case <-time.After(time.Second):
		t.Fatal("aead error timeout")
	}
	if _, ok := s.storedSessionFor("p1", "s1"); ok {
		t.Fatal("tier2 session still stored after tampered response chunk")
	}
}

func TestEncryptedRelayRejectsPlaintextResponseChunk(t *testing.T) {
	s, provider, providerConn := newEncryptedRelayHarness(t)
	relay, err := s.DispatchInference(context.Background(), *provider, "req-plaintext", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request: %v", err)
	}

	s.handleInferenceChunk("p1", "s1", mustJSON(InferenceResponseChunk{
		Type:      "inference_response_chunk",
		RequestID: "req-plaintext",
		Seq:       0,
		Data:      `{"ok":true}`,
	}))

	select {
	case err := <-relay.Errors:
		if err != ErrRelayAEADFailed {
			t.Fatalf("err = %v, want ErrRelayAEADFailed", err)
		}
	case <-time.After(time.Second):
		t.Fatal("plaintext tier2 error timeout")
	}
	if _, ok := s.storedSessionFor("p1", "s1"); ok {
		t.Fatal("tier2 session still stored after plaintext response chunk")
	}
}

func TestEncryptedRelayRejectsPlaintextResponseEnd(t *testing.T) {
	s, provider, providerConn := newEncryptedRelayHarness(t)
	relay, err := s.DispatchInference(context.Background(), *provider, "req-plaintext-end", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request: %v", err)
	}

	s.handleInferenceEnd("p1", "s1", mustJSON(InferenceResponseEnd{
		Type:      "inference_response_end",
		RequestID: "req-plaintext-end",
		Status:    "complete",
	}))

	select {
	case err := <-relay.Errors:
		if err != ErrRelayAEADFailed {
			t.Fatalf("err = %v, want ErrRelayAEADFailed", err)
		}
	case <-time.After(time.Second):
		t.Fatal("plaintext tier2 end error timeout")
	}
	if _, ok := s.storedSessionFor("p1", "s1"); ok {
		t.Fatal("tier2 session still stored after plaintext response end")
	}
}

func TestEncryptedRelayNAKClosesSessionAndFailsRequest(t *testing.T) {
	s, provider, providerConn := newEncryptedRelayHarness(t)
	relay, err := s.DispatchInference(context.Background(), *provider, "req-provider-nak", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request: %v", err)
	}

	s.handleNAK("p1", "s1", []byte(`{"type":"nak","in_reply_to":"req-provider-nak","error":{"code":"tier2_aead_decrypt_failed","message":"bad frame"}}`))

	select {
	case err := <-relay.Errors:
		if err != ErrRelayAEADFailed {
			t.Fatalf("err = %v, want ErrRelayAEADFailed", err)
		}
	case <-time.After(time.Second):
		t.Fatal("tier2 nak error timeout")
	}
	if _, ok := s.storedSessionFor("p1", "s1"); ok {
		t.Fatal("tier2 session still stored after provider decrypt failure")
	}
	got, ok := s.pool.Resolve("p1", "s1")
	if !ok {
		t.Fatal("provider not found")
	}
	if got.State != pool.StateUnavailable {
		t.Fatalf("state = %s, want unavailable", got.State)
	}
}

func TestRelayIgnoresResponsesFromReplacedSession(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	registry := pool.NewRegistry(nil)
	stale := &pool.Provider{
		ProviderID:     "p1",
		AssignedID:     "stale",
		ModelID:        "model-a",
		Tier:           pool.TierProvisional,
		InferencePath:  pool.InferencePathWSTunneled,
		State:          pool.StateReady,
		MaxConcurrency: 1,
	}
	registry.Register(stale, serverConn)
	s := NewServer(config.Default(), registry, zerolog.Nop())
	session := newProviderSession("p1", "stale", serverConn, 4)
	s.sessions.Store(sessionKey("p1", "stale"), session)
	go session.runWriter()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	relay, err := s.DispatchInference(ctx, *stale, "req-stale", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read inference_request: %v", err)
	}

	current := *stale
	current.AssignedID = "current"
	if old, _ := registry.Register(&current, nil); old != nil {
		_ = old.Close()
	}
	if _, err := s.DispatchInference(context.Background(), *stale, "req-after-replace", []byte(`{"model":"model-a"}`), false); err != ErrRelayClosed {
		t.Fatalf("stale dispatch = %v, want ErrRelayClosed", err)
	}

	s.handleInferenceChunk("p1", "stale", mustJSON(InferenceResponseChunk{Type: "inference_response_chunk", RequestID: "req-stale", Seq: 0, Data: `{"stale":true}`}))
	s.handleInferenceEnd("p1", "stale", mustJSON(InferenceResponseEnd{Type: "inference_response_end", RequestID: "req-stale", Status: "complete", ChunksSent: 1}))

	select {
	case chunk := <-relay.Chunks:
		t.Fatalf("stale chunk delivered: %#v", chunk)
	case <-time.After(50 * time.Millisecond):
	}
	select {
	case end := <-relay.Done:
		t.Fatalf("stale end delivered: %#v", end)
	case <-time.After(50 * time.Millisecond):
	}
}

func TestPreflightIgnoresAckFromReplacedSession(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	registry := pool.NewRegistry(nil)
	stale := &pool.Provider{ProviderID: "p1", AssignedID: "stale", ModelID: "model-a", Tier: pool.TierProvisional, InferencePath: pool.InferencePathWSTunneled}
	registry.Register(stale, serverConn)
	s := NewServer(config.Default(), registry, zerolog.Nop())
	session := newProviderSession("p1", "stale", serverConn, 4)
	s.sessions.Store(sessionKey("p1", "stale"), session)
	go session.runWriter()

	type preflightResult struct {
		ok  bool
		err error
	}
	done := make(chan preflightResult, 1)
	go func() {
		_, ok, err := s.Preflight(*stale, "pf-stale", 64, 50*time.Millisecond)
		done <- preflightResult{ok: ok, err: err}
	}()
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read preflight: %v", err)
	}

	current := *stale
	current.AssignedID = "current"
	if old, _ := registry.Register(&current, nil); old != nil {
		_ = old.Close()
	}
	s.handlePreflightAck("p1", "stale", mustJSON(PreflightAck{Type: "preflight_ack", RequestID: "pf-stale", Accepted: true}))

	select {
	case got := <-done:
		if got.err != nil || got.ok {
			t.Fatalf("preflight result = ok:%v err:%v, want timeout false nil", got.ok, got.err)
		}
	case <-time.After(time.Second):
		t.Fatal("preflight did not finish")
	}
}

func TestRelayIgnoresNAKFromReplacedSession(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	registry := pool.NewRegistry(nil)
	stale := &pool.Provider{ProviderID: "p1", AssignedID: "stale", ModelID: "model-a", Tier: pool.TierProvisional, InferencePath: pool.InferencePathWSTunneled}
	registry.Register(stale, serverConn)
	s := NewServer(config.Default(), registry, zerolog.Nop())
	session := newProviderSession("p1", "stale", serverConn, 4)
	s.sessions.Store(sessionKey("p1", "stale"), session)
	go session.runWriter()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	relay, err := s.DispatchInference(ctx, *stale, "req-stale-nak", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read inference_request: %v", err)
	}

	current := *stale
	current.AssignedID = "current"
	if old, _ := registry.Register(&current, nil); old != nil {
		_ = old.Close()
	}
	s.handleNAK("p1", "stale", []byte(`{"type":"nak","in_reply_to":"req-stale-nak","error":{"code":"unknown_message_type","message":"stale reject-nak"}}`))

	select {
	case err := <-relay.Errors:
		t.Fatalf("stale nak delivered error: %v", err)
	case <-time.After(50 * time.Millisecond):
	}
	got, ok := registry.Resolve("p1", "")
	if !ok {
		t.Fatal("provider not found")
	}
	if got.HTTPForwardingOnly {
		t.Fatalf("provider = %#v, stale nak marked http_forwarding_only", got)
	}
}

func TestRelayBackpressureWhenWriteBufferFull(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	session := newProviderSession("p1", "s1", serverConn, 1)
	if err := session.send([]byte(`{"type":"one"}`)); err != nil {
		t.Fatalf("first send: %v", err)
	}
	if err := session.send([]byte(`{"type":"two"}`)); err != ErrRelayBackpressure {
		t.Fatalf("second send = %v, want backpressure", err)
	}
}

func TestRelaySendAfterCloseReturnsClosed(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	session := newProviderSession("p1", "s1", serverConn, 1)
	session.close()
	if err := session.send([]byte(`{"type":"after_close"}`)); err != ErrRelayClosed {
		t.Fatalf("send after close = %v, want ErrRelayClosed", err)
	}
}

func TestRelayMaxConcurrencyRejectsAdditionalActiveRequest(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{ProviderID: "p1", AssignedID: "s1", ModelID: "model-a", Tier: pool.TierProvisional, InferencePath: pool.InferencePathWSTunneled, MaxConcurrency: 1}
	registry.Register(provider, serverConn)
	s := NewServer(config.Default(), registry, zerolog.Nop())
	session := newProviderSession("p1", "s1", serverConn, 4)
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()

	if _, err := s.DispatchInference(context.Background(), *provider, "req-one", []byte(`{"model":"model-a"}`), false); err != nil {
		t.Fatalf("first dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read first inference_request: %v", err)
	}
	if _, err := s.DispatchInference(context.Background(), *provider, "req-two", []byte(`{"model":"model-a"}`), false); err != ErrRelayBackpressure {
		t.Fatalf("second dispatch = %v, want ErrRelayBackpressure", err)
	}
}

func TestRelayCancelSendsCancelRequest(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{ProviderID: "p1", AssignedID: "s1", ModelID: "model-a", Tier: pool.TierProvisional, InferencePath: pool.InferencePathWSTunneled}
	registry.Register(provider, serverConn)
	s := NewServer(config.Default(), registry, zerolog.Nop())
	session := newProviderSession("p1", "s1", serverConn, 4)
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()

	relay, err := s.DispatchInference(context.Background(), *provider, "req-cancel", []byte(`{"model":"model-a"}`), true)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read inference_request: %v", err)
	}
	relay.Cancel("buyer_disconnected")
	payload, _, err := wsutil.ReadServerData(providerConn)
	if err != nil {
		t.Fatalf("read cancel_request: %v", err)
	}
	var cancel CancelRequest
	if err := json.Unmarshal(payload, &cancel); err != nil {
		t.Fatalf("cancel json: %v", err)
	}
	if cancel.Type != "cancel_request" || cancel.RequestID != "req-cancel" || cancel.Reason != "buyer_disconnected" {
		t.Fatalf("cancel = %#v", cancel)
	}
}

func TestRelayTimeoutCancelsAndCompletesWithError(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{ProviderID: "p1", AssignedID: "s1", ModelID: "model-a", Tier: pool.TierProvisional, InferencePath: pool.InferencePathWSTunneled, MaxConcurrency: 1}
	registry.Register(provider, serverConn)
	s := NewServer(config.Default(), registry, zerolog.Nop())
	session := newProviderSession("p1", "s1", serverConn, 4)
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	relay, err := s.DispatchInference(ctx, *provider, "req-timeout", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read inference_request: %v", err)
	}
	payload, _, err := wsutil.ReadServerData(providerConn)
	if err != nil {
		t.Fatalf("read cancel_request: %v", err)
	}
	var cancelMsg CancelRequest
	if err := json.Unmarshal(payload, &cancelMsg); err != nil {
		t.Fatalf("cancel json: %v", err)
	}
	if cancelMsg.RequestID != "req-timeout" || cancelMsg.Reason != "timeout" {
		t.Fatalf("cancel = %#v", cancelMsg)
	}

	select {
	case err := <-relay.Errors:
		if err != ErrRelayTimeout {
			t.Fatalf("err = %v, want ErrRelayTimeout", err)
		}
	case <-time.After(time.Second):
		t.Fatal("timeout error not delivered")
	}
	if _, ok := session.activeFor("req-timeout"); ok {
		t.Fatal("timed out request still active")
	}
}

func TestRelayNAKFallbackMarksHTTPForwardingOnly(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{ProviderID: "p1", AssignedID: "s1", ModelID: "model-a", Tier: pool.TierProvisional, InferencePath: pool.InferencePathWSTunneled}
	registry.Register(provider, serverConn)
	s := NewServer(config.Default(), registry, zerolog.Nop())
	session := newProviderSession("p1", "s1", serverConn, 4)
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()

	relay, err := s.DispatchInference(context.Background(), *provider, "req-nak", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read inference_request: %v", err)
	}
	s.handleNAK("p1", "s1", []byte(`{"type":"nak","in_reply_to":"req-nak","error":{"code":"unknown_message_type","message":"mock reject-nak"}}`))

	select {
	case err := <-relay.Errors:
		if err != ErrRelayNAKFallback {
			t.Fatalf("err = %v, want ErrRelayNAKFallback", err)
		}
	case <-time.After(time.Second):
		t.Fatal("nak error timeout")
	}
	got, ok := registry.Resolve("p1", "")
	if !ok || !got.HTTPForwardingOnly {
		t.Fatalf("provider = %#v ok=%v, want http_forwarding_only", got, ok)
	}
}

func newEncryptedRelayHarness(t *testing.T) (*Server, *pool.Provider, net.Conn) {
	t.Helper()
	return newEncryptedRelayHarnessWithConfig(t, config.Default(), zerolog.Nop(), time.Now())
}

func newEncryptedRelayHarnessWithConfig(t *testing.T, cfg config.Config, logger zerolog.Logger, startedAt time.Time) (*Server, *pool.Provider, net.Conn) {
	t.Helper()
	serverConn, providerConn := net.Pipe()
	t.Cleanup(func() {
		_ = providerConn.Close()
		_ = serverConn.Close()
	})
	tier2Session := &pool.Tier2Session{
		AEADSuite:    tier2.PillarBAEADA256GCM,
		C2PKey:       bytes.Repeat([]byte{0x11}, 32),
		P2CKey:       bytes.Repeat([]byte{0x22}, 32),
		C2PNonceBase: []byte{0x01, 0x02, 0x03, 0x04},
		P2CNonceBase: []byte{0x05, 0x06, 0x07, 0x08},
		KeyID:        "test-kid",
		StartedAt:    startedAt,
	}
	provider := &pool.Provider{
		ProviderID:     "p1",
		AssignedID:     "s1",
		ModelID:        "model-a",
		Tier:           pool.TierProvisional,
		InferencePath:  pool.InferencePathWSTunneled,
		State:          pool.StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 1,
		EncryptedLeg:   true,
		Tier2Session:   tier2Session,
	}
	registry := pool.NewRegistry(nil)
	registry.Register(provider, serverConn)
	s := NewServer(cfg, registry, logger)
	session := newProviderSession("p1", "s1", serverConn, 4)
	session.useTier2Session(tier2Session)
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()
	return s, provider, providerConn
}

func encryptedResponseChunk(t *testing.T, provider *pool.Provider, requestID string, stream bool, seq uint64, plaintext []byte) []byte {
	t.Helper()
	aad := tier2.AEADFrameAAD{
		Type:       "inference_response_chunk",
		Direction:  "p2c",
		RequestID:  requestID,
		Stream:     stream,
		ProviderID: provider.ProviderID,
		AssignedID: provider.AssignedID,
		Seq:        seq,
	}
	envelope, err := tier2.SealPillarBFrame(provider.Tier2Session.P2CKey, provider.Tier2Session.P2CNonceBase, provider.Tier2Session.KeyID, seq, aad, plaintext)
	if err != nil {
		t.Fatalf("seal encrypted response chunk: %v", err)
	}
	return mustJSON(encryptedInferenceResponseChunk{
		Type:      "inference_response_chunk",
		RequestID: requestID,
		Encrypted: true,
		Enc:       envelope.Enc,
	})
}

func encryptedResponseEnd(t *testing.T, provider *pool.Provider, requestID string, stream bool, seq uint64, end InferenceResponseEnd) []byte {
	t.Helper()
	aad := tier2.AEADFrameAAD{
		Type:       "inference_response_end",
		Direction:  "p2c",
		RequestID:  requestID,
		Stream:     stream,
		ProviderID: provider.ProviderID,
		AssignedID: provider.AssignedID,
		Seq:        seq,
	}
	envelope, err := tier2.SealPillarBFrame(provider.Tier2Session.P2CKey, provider.Tier2Session.P2CNonceBase, provider.Tier2Session.KeyID, seq, aad, mustJSON(end))
	if err != nil {
		t.Fatalf("seal encrypted response end: %v", err)
	}
	return mustJSON(encryptedInferenceResponseEnd{
		Type:      "inference_response_end",
		RequestID: requestID,
		Encrypted: true,
		Enc:       envelope.Enc,
	})
}

func sessionForTest(s *Server, providerID, assignedID string) *providerSession {
	session, ok := s.storedSessionFor(providerID, assignedID)
	if !ok {
		panic("missing test provider session")
	}
	return session
}

func mustJSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}
