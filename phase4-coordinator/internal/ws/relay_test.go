package ws

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
)

type blockingWriteConn struct {
	mu            sync.Mutex
	writeDeadline time.Time
	closed        chan struct{}
	closeOnce     sync.Once
}

func newBlockingWriteConn() *blockingWriteConn {
	return &blockingWriteConn{closed: make(chan struct{})}
}

func (c *blockingWriteConn) Read(_ []byte) (int, error) {
	<-c.closed
	return 0, net.ErrClosed
}

func (c *blockingWriteConn) Write(_ []byte) (int, error) {
	for {
		c.mu.Lock()
		deadline := c.writeDeadline
		c.mu.Unlock()
		if deadline.IsZero() {
			select {
			case <-c.closed:
				return 0, net.ErrClosed
			case <-time.After(10 * time.Millisecond):
				continue
			}
		}
		wait := time.Until(deadline)
		if wait <= 0 {
			return 0, os.ErrDeadlineExceeded
		}
		select {
		case <-c.closed:
			return 0, net.ErrClosed
		case <-time.After(wait):
			return 0, os.ErrDeadlineExceeded
		}
	}
}

func (c *blockingWriteConn) Close() error {
	c.closeOnce.Do(func() { close(c.closed) })
	return nil
}

func (c *blockingWriteConn) LocalAddr() net.Addr  { return testAddr("local") }
func (c *blockingWriteConn) RemoteAddr() net.Addr { return testAddr("remote") }

func (c *blockingWriteConn) SetDeadline(t time.Time) error {
	c.mu.Lock()
	c.writeDeadline = t
	c.mu.Unlock()
	return nil
}

func (c *blockingWriteConn) SetReadDeadline(time.Time) error { return nil }

func (c *blockingWriteConn) SetWriteDeadline(t time.Time) error {
	c.mu.Lock()
	c.writeDeadline = t
	c.mu.Unlock()
	return nil
}

type testAddr string

func (a testAddr) Network() string { return "test" }
func (a testAddr) String() string  { return string(a) }

type firstWriteSucceedsConn struct {
	*blockingWriteConn
	mu     sync.Mutex
	writes int
}

func newFirstWriteSucceedsConn() *firstWriteSucceedsConn {
	return &firstWriteSucceedsConn{blockingWriteConn: newBlockingWriteConn()}
}

func (c *firstWriteSucceedsConn) Write(p []byte) (int, error) {
	c.mu.Lock()
	if c.writes == 0 {
		c.writes++
		c.mu.Unlock()
		return len(p), nil
	}
	c.mu.Unlock()
	return c.blockingWriteConn.Write(p)
}

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
	if req.ConversationKey != "" {
		t.Fatalf("conversation_key = %q, want empty without relay context", req.ConversationKey)
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

func TestActiveRelayPreventsHeartbeatMonitorCloseBeforeFirstChunk(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	cfg := config.Default()
	cfg.Routing.FailoverTimeoutS = 1
	cfg.Routing.RequestTimeoutS = 5
	cfg.Pool.HeartbeatMissThresholdS = 1

	registry := pool.NewRegistry(nil)
	stale := time.Now().Add(-2 * time.Second)
	provider := &pool.Provider{
		ProviderID:      "p-active",
		AssignedID:      "s-active",
		ModelID:         "model-a",
		Tier:            pool.TierProvisional,
		InferencePath:   pool.InferencePathWSTunneled,
		State:           pool.StateReady,
		SlotsFree:       1,
		SlotsTotal:      1,
		MaxConcurrency:  1,
		LastActivityAt:  stale,
		LastHeartbeatAt: stale,
	}
	registry.Register(provider, serverConn)
	s := NewServer(cfg, registry, zerolog.Nop())
	session := newProviderSession("p-active", "s-active", serverConn, 1)
	s.sessions.Store(sessionKey("p-active", "s-active"), session)
	go session.runWriter()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	relay, err := s.DispatchInference(ctx, *provider, "req-slow", []byte(`{"model":"model-a"}`), true)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	defer relay.cancel("test_done")
	if _, op, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read inference_request: %v", err)
	} else if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}

	go s.monitorHeartbeat("p-active", "s-active", serverConn)
	time.Sleep(1500 * time.Millisecond)

	if providerConn.SetReadDeadline(time.Now().Add(100*time.Millisecond)) != nil {
		t.Fatal("set provider read deadline")
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err == nil {
		t.Fatal("expected no server frame while active relay is still waiting")
	} else if !errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatalf("provider websocket was closed while relay was active: %v", err)
	}
	if !session.hasActive() {
		t.Fatal("relay active state was removed before request context ended")
	}
}

func TestActiveRelayLivenessSuppressionEndsWhenRequestContextExpires(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	cfg := config.Default()
	cfg.Routing.FailoverTimeoutS = 1
	cfg.Routing.RequestTimeoutS = 1
	cfg.Pool.HeartbeatMissThresholdS = 1

	registry := pool.NewRegistry(nil)
	stale := time.Now().Add(-2 * time.Second)
	provider := &pool.Provider{
		ProviderID:      "p-expiring",
		AssignedID:      "s-expiring",
		ModelID:         "model-a",
		Tier:            pool.TierProvisional,
		InferencePath:   pool.InferencePathWSTunneled,
		State:           pool.StateReady,
		SlotsFree:       1,
		SlotsTotal:      1,
		MaxConcurrency:  1,
		LastActivityAt:  stale,
		LastHeartbeatAt: stale,
	}
	registry.Register(provider, serverConn)
	s := NewServer(cfg, registry, zerolog.Nop())
	session := newProviderSession("p-expiring", "s-expiring", serverConn, 1)
	s.sessions.Store(sessionKey("p-expiring", "s-expiring"), session)
	go session.runWriter()

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	relay, err := s.DispatchInference(ctx, *provider, "req-expiring", []byte(`{"model":"model-a"}`), true)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	defer relay.cancel("test_done")
	if _, op, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read inference_request: %v", err)
	} else if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}

	go s.monitorHeartbeat("p-expiring", "s-expiring", serverConn)
	until := time.Now().Add(3 * time.Second)
	for session.hasActive() && time.Now().Before(until) {
		time.Sleep(10 * time.Millisecond)
	}
	if session.hasActive() {
		t.Fatal("relay active state did not clear after request context expired")
	}
	for time.Now().Before(until) {
		if err := providerConn.SetReadDeadline(time.Now().Add(100 * time.Millisecond)); err != nil {
			t.Fatalf("set provider read deadline: %v", err)
		}
		if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
			if errors.Is(err, os.ErrDeadlineExceeded) {
				continue
			}
			return
		}
	}
	t.Fatal("provider websocket stayed open after active relay expired and heartbeat remained stale")
}

func TestRelayDispatchCarriesConversationKeyFromContext(t *testing.T) {
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

	ctx := ContextWithConversationKey(context.Background(), "conv:relay-cache")
	if _, err := s.DispatchInference(ctx, *provider, "req-conv", []byte(`{"model":"model-a"}`), false); err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	payload, _, err := wsutil.ReadServerData(providerConn)
	if err != nil {
		t.Fatalf("read inference_request: %v", err)
	}
	var req InferenceRequest
	if err := json.Unmarshal(payload, &req); err != nil {
		t.Fatalf("request json: %v", err)
	}
	if req.ConversationKey != "conv:relay-cache" {
		t.Fatalf("conversation_key=%q want conv:relay-cache", req.ConversationKey)
	}
}

func TestRelayWriteFailureMarksProviderUnavailable(t *testing.T) {
	serverConn, providerConn := net.Pipe()
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
	session := newProviderSession("p1", "s1", serverConn, 4)
	session.onWriteFailure = s.handleProviderWriteFailure
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()

	if err := providerConn.Close(); err != nil {
		t.Fatalf("close provider side: %v", err)
	}
	relay, err := s.DispatchInference(context.Background(), *provider, "req-dead", []byte(`{"model":"model-a"}`), false)
	if err != nil && !errors.Is(err, ErrRelayClosed) {
		t.Fatalf("dispatch = %v, want nil or ErrRelayClosed", err)
	}
	if relay != nil {
		select {
		case relayErr := <-relay.Errors:
			if !errors.Is(relayErr, ErrRelayClosed) {
				t.Fatalf("relay error = %v, want ErrRelayClosed", relayErr)
			}
		case <-time.After(500 * time.Millisecond):
			t.Fatal("timed out waiting for relay close after write failure")
		}
	}
	deadline := time.Now().Add(500 * time.Millisecond)
	for {
		got, ok := s.pool.Resolve("p1", "s1")
		if ok && got.State == pool.StateUnavailable {
			break
		}
		if time.Now().After(deadline) {
			if !ok {
				t.Fatal("timed out waiting for provider to remain registered as unavailable")
			}
			t.Fatalf("timed out waiting for unavailable state; state=%s", got.State)
		}
		time.Sleep(10 * time.Millisecond)
	}
	if _, ok := s.storedSessionFor("p1", "s1"); ok {
		t.Fatal("session still routable after websocket write failure")
	}
}

func TestRelayWriteProbeTimesOutBlockingProviderWrite(t *testing.T) {
	conn := newBlockingWriteConn()
	defer conn.Close()

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
	registry.Register(provider, conn)
	s := NewServer(config.Default(), registry, zerolog.Nop())
	session := newProviderSession("p1", "s1", conn, 4, 10*time.Second)
	session.probeWrites = true
	session.onWriteFailure = s.handleProviderWriteFailure
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()

	start := time.Now()
	_, err := s.DispatchInference(context.Background(), *provider, "req-blocked", []byte(`{"model":"model-a"}`), false)
	elapsed := time.Since(start)
	if !errors.Is(err, ErrRelayClosed) {
		t.Fatalf("dispatch = %v, want ErrRelayClosed", err)
	}
	if elapsed > time.Second {
		t.Fatalf("dispatch took %v, want below 1s probe bound", elapsed)
	}
	got, ok := s.pool.Resolve("p1", "s1")
	if !ok {
		t.Fatal("provider missing")
	}
	if got.State != pool.StateUnavailable {
		t.Fatalf("state = %s, want unavailable", got.State)
	}
	if _, ok := s.storedSessionFor("p1", "s1"); ok {
		t.Fatal("session still routable after blocked write probe failure")
	}
}

func TestPreflightWriteProbeTimesOutBlockingProviderWrite(t *testing.T) {
	conn := newBlockingWriteConn()
	defer conn.Close()

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
	registry.Register(provider, conn)
	s := NewServer(config.Default(), registry, zerolog.Nop())
	session := newProviderSession("p1", "s1", conn, 4, 10*time.Second)
	session.probeWrites = true
	session.onWriteFailure = s.handleProviderWriteFailure
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()

	start := time.Now()
	_, _, err := s.Preflight(*provider, "req-preflight-blocked", 1024, 5*time.Second)
	elapsed := time.Since(start)
	if !errors.Is(err, ErrRelayClosed) {
		t.Fatalf("preflight = %v, want ErrRelayClosed", err)
	}
	if elapsed > time.Second {
		t.Fatalf("preflight took %v, want below 1s probe bound", elapsed)
	}
	got, ok := s.pool.Resolve("p1", "s1")
	if !ok {
		t.Fatal("provider missing")
	}
	if got.State != pool.StateUnavailable {
		t.Fatalf("state = %s, want unavailable", got.State)
	}
	if _, ok := s.storedSessionFor("p1", "s1"); ok {
		t.Fatal("session still routable after blocked preflight write probe failure")
	}
}

func TestRelayWriteProbeDoesNotEvictSlowRequestPayloadWrite(t *testing.T) {
	conn := newFirstWriteSucceedsConn()
	defer conn.Close()

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
	registry.Register(provider, conn)
	s := NewServer(config.Default(), registry, zerolog.Nop())
	session := newProviderSession("p1", "s1", conn, 4, 10*time.Second)
	session.probeWrites = true
	session.onWriteFailure = s.handleProviderWriteFailure
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()

	start := time.Now()
	relay, err := s.DispatchInference(context.Background(), *provider, "req-slow-payload", []byte(`{"model":"model-a"}`), false)
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("dispatch = %v, want probe success before slow payload write", err)
	}
	if relay == nil {
		t.Fatal("relay is nil after successful probe")
	}
	if elapsed > time.Second {
		t.Fatalf("dispatch took %v, want below 1s after probe success", elapsed)
	}
	got, ok := s.pool.Resolve("p1", "s1")
	if !ok {
		t.Fatal("provider missing")
	}
	if got.State == pool.StateUnavailable {
		t.Fatal("provider marked unavailable even though small write probe succeeded")
	}
	if _, ok := s.storedSessionFor("p1", "s1"); !ok {
		t.Fatal("session removed even though small write probe succeeded")
	}
	relay.Cancel("test_cleanup")
}

func TestRegisteredProviderSessionEnablesWriteProbes(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	s := NewServer(config.Default(), pool.NewRegistry(nil), zerolog.Nop())
	session, refusal := s.registerProviderSession(serverConn, &pool.Provider{
		ProviderID:     "p1",
		AssignedID:     "s1",
		ModelID:        "model-a",
		Tier:           pool.TierProvisional,
		InferencePath:  pool.InferencePathWSTunneled,
		State:          pool.StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 1,
	})
	if refusal != pool.RegisterRefusalNone || session == nil {
		t.Fatalf("registerProviderSession refusal=%q session=%v", refusal, session)
	}
	if !session.probeWrites {
		t.Fatal("production-registered provider session did not enable write probes")
	}
	session.close()
}

func TestRelayClosedSendMarksProviderUnavailable(t *testing.T) {
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
	session := newProviderSession("p1", "s1", serverConn, 4)
	session.onWriteFailure = s.handleProviderWriteFailure
	s.sessions.Store(sessionKey("p1", "s1"), session)
	session.close()

	if _, err := s.DispatchInference(context.Background(), *provider, "req-closed", []byte(`{"model":"model-a"}`), false); !errors.Is(err, ErrRelayClosed) {
		t.Fatalf("dispatch = %v, want ErrRelayClosed", err)
	}
	got, ok := s.pool.Resolve("p1", "s1")
	if !ok {
		t.Fatal("provider missing")
	}
	if got.State != pool.StateUnavailable {
		t.Fatalf("state = %s, want unavailable", got.State)
	}
	if _, ok := s.storedSessionFor("p1", "s1"); ok {
		t.Fatal("session still routable after closed send")
	}
}

func TestProviderLivenessThresholdCapsB1ProvidersAtSixtySeconds(t *testing.T) {
	cfg := config.Default()
	cfg.Pool.HeartbeatMissThresholdS = 90
	s := NewServer(cfg, pool.NewRegistry(nil), zerolog.Nop())

	legacy := s.providerLivenessThreshold(pool.Provider{BinaryVersion: "1.8.0"})
	if legacy != 90*time.Second {
		t.Fatalf("legacy threshold = %v, want 90s", legacy)
	}
	b1 := s.providerLivenessThreshold(pool.Provider{BinaryVersion: "1.8.1"})
	if b1 != 60*time.Second {
		t.Fatalf("b1 threshold = %v, want 60s", b1)
	}
	next := s.providerLivenessThreshold(pool.Provider{BinaryVersion: "1.8.2"})
	if next != 60*time.Second {
		t.Fatalf("next release threshold = %v, want 60s", next)
	}
	malformed := s.providerLivenessThreshold(pool.Provider{BinaryVersion: "1.8.2-dev"})
	if malformed != 90*time.Second {
		t.Fatalf("malformed threshold = %v, want 90s", malformed)
	}

	cfg.Pool.HeartbeatMissThresholdS = 10
	s = NewServer(cfg, pool.NewRegistry(nil), zerolog.Nop())
	tight := s.providerLivenessThreshold(pool.Provider{BinaryVersion: "1.8.1"})
	if tight != 10*time.Second {
		t.Fatalf("tight configured threshold = %v, want 10s", tight)
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
	var plaintext encryptedInferencePlaintext
	if err := json.Unmarshal(opened, &plaintext); err != nil {
		t.Fatalf("encrypted plaintext envelope json: %v", err)
	}
	if plaintext.Type != "inference_request_plaintext" || plaintext.Body != string(body) || plaintext.ConversationKey != "" {
		t.Fatalf("encrypted plaintext envelope = %+v, want body without conversation key", plaintext)
	}
	if provider.Tier2Session.C2PCounter != 1 {
		t.Fatalf("c2p counter = %d, want 1", provider.Tier2Session.C2PCounter)
	}
}

func TestEncryptedRelayDispatchSealsConversationKeyInsideBodyEnvelope(t *testing.T) {
	s, provider, providerConn := newEncryptedRelayHarness(t)

	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"secret prompt"}]}`)
	ctx := ContextWithConversationKey(context.Background(), "conv:encrypted-cache")
	if _, err := s.DispatchInference(ctx, *provider, "req-encrypted-cache", body, true); err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	payload, _, err := wsutil.ReadServerData(providerConn)
	if err != nil {
		t.Fatalf("read encrypted inference_request: %v", err)
	}
	if bytes.Contains(payload, []byte("secret prompt")) || bytes.Contains(payload, []byte("conv:encrypted-cache")) || bytes.Contains(payload, []byte(`"body"`)) {
		t.Fatalf("encrypted request leaked plaintext material: %s", payload)
	}
	var req encryptedInferenceRequest
	if err := json.Unmarshal(payload, &req); err != nil {
		t.Fatalf("encrypted request json: %v", err)
	}
	aad := tier2.AEADFrameAAD{
		Type:       "inference_request",
		Direction:  "c2p",
		RequestID:  "req-encrypted-cache",
		Stream:     true,
		ProviderID: provider.ProviderID,
		AssignedID: provider.AssignedID,
		Seq:        0,
	}
	opened, err := tier2.OpenPillarBFrame(provider.Tier2Session.C2PKey, provider.Tier2Session.C2PNonceBase, provider.Tier2Session.KeyID, 0, aad, tier2.AEADEnvelope{Encrypted: req.Encrypted, Enc: req.Enc})
	if err != nil {
		t.Fatalf("open encrypted request: %v", err)
	}
	var plaintext encryptedInferencePlaintext
	if err := json.Unmarshal(opened, &plaintext); err != nil {
		t.Fatalf("encrypted plaintext envelope json: %v", err)
	}
	if plaintext.Type != "inference_request_plaintext" || plaintext.Body != string(body) || plaintext.ConversationKey != "conv:encrypted-cache" {
		t.Fatalf("encrypted plaintext envelope = %+v, want body + sealed conversation key", plaintext)
	}
}

func TestRelayDispatchCarriesSettlementMetadata(t *testing.T) {
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

	metadata := settlementMetadataFixture()
	metadata.RequestID = "settlement"
	if _, err := s.DispatchInferenceWithSettlement(context.Background(), *provider, metadata.RequestID, []byte(`{"model":"model-a"}`), false, metadata); err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	payload, _, err := wsutil.ReadServerData(providerConn)
	if err != nil {
		t.Fatalf("read inference_request: %v", err)
	}
	var req InferenceRequest
	if err := json.Unmarshal(payload, &req); err != nil {
		t.Fatalf("request json: %v", err)
	}
	if req.Settlement == nil {
		t.Fatal("settlement metadata missing")
	}
	if req.RequestID != metadata.RequestID || req.Settlement.RequestID != metadata.RequestID {
		t.Fatalf("request IDs outer=%q settlement=%q want canonical=%q", req.RequestID, req.Settlement.RequestID, metadata.RequestID)
	}
	if req.Settlement.RouteSnapshotDigest != metadata.RouteSnapshotDigest || req.Settlement.PendingDeadlineSeconds != metadata.PendingDeadlineSeconds {
		t.Fatalf("settlement metadata = %+v, want %+v", req.Settlement, metadata)
	}
	if bytes.Contains(payload, []byte("Authorization")) || bytes.Contains(payload, []byte("Bearer ")) {
		t.Fatalf("settlement metadata leaked credential-looking material: %s", payload)
	}
}

func TestEncryptedRelayDispatchCarriesSettlementMetadataOutsideBody(t *testing.T) {
	s, provider, providerConn := newEncryptedRelayHarness(t)
	metadata := settlementMetadataFixture()
	metadata.RequestID = "settlement-encrypted"

	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"secret prompt"}]}`)
	if _, err := s.DispatchInferenceWithSettlement(context.Background(), *provider, metadata.RequestID, body, true, metadata); err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	payload, _, err := wsutil.ReadServerData(providerConn)
	if err != nil {
		t.Fatalf("read encrypted inference_request: %v", err)
	}
	if bytes.Contains(payload, []byte("secret prompt")) || bytes.Contains(payload, []byte(`"body"`)) {
		t.Fatalf("encrypted request leaked plaintext body: %s", payload)
	}
	var req encryptedInferenceRequest
	if err := json.Unmarshal(payload, &req); err != nil {
		t.Fatalf("encrypted request json: %v", err)
	}
	if req.RequestID != metadata.RequestID || req.Settlement == nil || req.Settlement.RequestID != metadata.RequestID {
		t.Fatalf("request IDs outer=%q settlement=%v want canonical=%q", req.RequestID, req.Settlement, metadata.RequestID)
	}
	if req.Settlement == nil || req.Settlement.ProviderReceiptKeyID != metadata.ProviderReceiptKeyID {
		t.Fatalf("settlement metadata = %+v, want %+v", req.Settlement, metadata)
	}
}

func TestRelayDispatchRejectsSettlementRequestIDMismatch(t *testing.T) {
	s, provider, _ := newEncryptedRelayHarness(t)
	metadata := settlementMetadataFixture()

	if _, err := s.DispatchInferenceWithSettlement(context.Background(), *provider, "different-request", []byte(`{"model":"model-a"}`), false, metadata); !errors.Is(err, ErrRelaySettlementIDMismatch) {
		t.Fatalf("dispatch error = %v, want %v", err, ErrRelaySettlementIDMismatch)
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

func TestEncryptedRelayAcceptsOutOfOrderConcurrentP2CSequences(t *testing.T) {
	s, provider, providerConn := newEncryptedRelayHarness(t)
	provider.MaxConcurrency = 2
	provider.SlotsFree = 2
	provider.SlotsTotal = 2

	relayA, err := s.DispatchInference(context.Background(), *provider, "req-a", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch a: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request a: %v", err)
	}
	relayB, err := s.DispatchInference(context.Background(), *provider, "req-b", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch b: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request b: %v", err)
	}

	s.handleInferenceChunk("p1", "s1", encryptedResponseChunkWithAppSeq(t, provider, "req-b", false, 1, 0, []byte(`{"request":"b"}`)))
	select {
	case chunk := <-relayB.Chunks:
		if chunk.RequestID != "req-b" || chunk.Seq != 0 || chunk.Data != `{"request":"b"}` {
			t.Fatalf("decrypted out-of-order chunk b = %#v", chunk)
		}
	case err := <-relayB.Errors:
		t.Fatalf("relay b unexpected error: %v", err)
	case <-time.After(time.Second):
		t.Fatal("decrypted out-of-order chunk b timeout")
	}

	s.handleInferenceChunk("p1", "s1", encryptedResponseChunk(t, provider, "req-a", false, 0, []byte(`{"request":"a"}`)))
	select {
	case chunk := <-relayA.Chunks:
		if chunk.RequestID != "req-a" || chunk.Seq != 0 || chunk.Data != `{"request":"a"}` {
			t.Fatalf("decrypted lower-sequence chunk a = %#v", chunk)
		}
	case err := <-relayA.Errors:
		t.Fatalf("relay a unexpected error: %v", err)
	case <-time.After(time.Second):
		t.Fatal("decrypted lower-sequence chunk a timeout")
	}
	if provider.Tier2Session.P2CCounter != 2 {
		t.Fatalf("p2c contiguous counter = %d, want 2", provider.Tier2Session.P2CCounter)
	}
	if len(provider.Tier2Session.P2CSeen) != 0 {
		t.Fatalf("p2c out-of-order gap count = %d, want 0", len(provider.Tier2Session.P2CSeen))
	}
}

func TestEncryptedRelayDecryptsLegacyRawDataChunksWithAEADSequence(t *testing.T) {
	s, provider, providerConn := newEncryptedRelayHarness(t)
	provider.Tier2Session.ResponseChunkPlaintextEnvelope = false
	relay, err := s.DispatchInference(context.Background(), *provider, "req-legacy-raw-chunk", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request: %v", err)
	}

	s.handleInferenceChunk("p1", "s1", encryptedLegacyRawResponseChunk(t, provider, "req-legacy-raw-chunk", false, 0, []byte(`{"legacy":true}`)))
	select {
	case chunk := <-relay.Chunks:
		if chunk.RequestID != "req-legacy-raw-chunk" || chunk.Seq != 0 || chunk.Data != `{"legacy":true}` {
			t.Fatalf("legacy raw encrypted chunk = %#v", chunk)
		}
	case err := <-relay.Errors:
		t.Fatalf("legacy raw encrypted chunk error: %v", err)
	case <-time.After(time.Second):
		t.Fatal("legacy raw encrypted chunk timeout")
	}

	s.handleInferenceChunk("p1", "s1", encryptedLegacyRawResponseChunk(t, provider, "req-legacy-raw-chunk", false, 1, []byte(`{"legacy":2}`)))
	select {
	case chunk := <-relay.Chunks:
		if chunk.RequestID != "req-legacy-raw-chunk" || chunk.Seq != 1 || chunk.Data != `{"legacy":2}` {
			t.Fatalf("second legacy raw encrypted chunk = %#v", chunk)
		}
	case err := <-relay.Errors:
		t.Fatalf("second legacy raw encrypted chunk error: %v", err)
	case <-time.After(time.Second):
		t.Fatal("second legacy raw encrypted chunk timeout")
	}
}

func TestEncryptedRelayLegacyRawDataPreservesWrapperShapedOutput(t *testing.T) {
	s, provider, providerConn := newEncryptedRelayHarness(t)
	provider.Tier2Session.ResponseChunkPlaintextEnvelope = false
	relay, err := s.DispatchInference(context.Background(), *provider, "req-legacy-wrapper-shaped-chunk", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request: %v", err)
	}

	raw := []byte(`{"type":"inference_response_chunk_plaintext","seq":5,"data":"x"}`)
	s.handleInferenceChunk("p1", "s1", encryptedLegacyRawResponseChunk(t, provider, "req-legacy-wrapper-shaped-chunk", false, 0, raw))
	select {
	case chunk := <-relay.Chunks:
		if chunk.RequestID != "req-legacy-wrapper-shaped-chunk" || chunk.Seq != 0 || chunk.Data != string(raw) {
			t.Fatalf("legacy wrapper-shaped raw chunk = %#v", chunk)
		}
	case err := <-relay.Errors:
		t.Fatalf("legacy wrapper-shaped raw chunk error: %v", err)
	case <-time.After(time.Second):
		t.Fatal("legacy wrapper-shaped raw chunk timeout")
	}
}

func TestEncryptedRelayRejectsMalformedTypedChunkPlaintext(t *testing.T) {
	s, provider, providerConn := newEncryptedRelayHarness(t)
	relay, err := s.DispatchInference(context.Background(), *provider, "req-malformed-typed-chunk", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request: %v", err)
	}

	s.handleInferenceChunk("p1", "s1", encryptedLegacyRawResponseChunk(t, provider, "req-malformed-typed-chunk", false, 0, []byte(`{"type":"inference_response_chunk_plaintext","data":"missing seq"}`)))
	select {
	case err := <-relay.Errors:
		if err != ErrRelayAEADFailed {
			t.Fatalf("err = %v, want ErrRelayAEADFailed", err)
		}
	case <-time.After(time.Second):
		t.Fatal("malformed typed chunk error timeout")
	}
	if _, ok := s.storedSessionFor("p1", "s1"); ok {
		t.Fatal("session remained stored after malformed typed chunk plaintext")
	}
}

func TestEncryptedRelayRejectsCapabilityTrueRawChunkPlaintext(t *testing.T) {
	s, provider, providerConn := newEncryptedRelayHarness(t)
	relay, err := s.DispatchInference(context.Background(), *provider, "req-cap-true-raw-chunk", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request: %v", err)
	}

	s.handleInferenceChunk("p1", "s1", encryptedLegacyRawResponseChunk(t, provider, "req-cap-true-raw-chunk", false, 0, []byte(`{"raw":true}`)))
	select {
	case err := <-relay.Errors:
		if err != ErrRelayAEADFailed {
			t.Fatalf("err = %v, want ErrRelayAEADFailed", err)
		}
	case <-time.After(time.Second):
		t.Fatal("capability-true raw chunk error timeout")
	}
	if _, ok := s.storedSessionFor("p1", "s1"); ok {
		t.Fatal("session remained stored after capability-true raw chunk plaintext")
	}
}

func TestDecodeEncryptedInferenceChunkPlaintextRejectsMalformedTypedEnvelope(t *testing.T) {
	tests := []struct {
		name      string
		plaintext []byte
	}{
		{
			name:      "missing_seq",
			plaintext: []byte(`{"type":"inference_response_chunk_plaintext","data":"x"}`),
		},
		{
			name:      "wrong_seq_type",
			plaintext: []byte(`{"type":"inference_response_chunk_plaintext","seq":"0","data":"x"}`),
		},
		{
			name:      "negative_seq",
			plaintext: []byte(`{"type":"inference_response_chunk_plaintext","seq":-1,"data":"x"}`),
		},
		{
			name:      "missing_data",
			plaintext: []byte(`{"type":"inference_response_chunk_plaintext","seq":0}`),
		},
		{
			name:      "wrong_data_type",
			plaintext: []byte(`{"type":"inference_response_chunk_plaintext","seq":0,"data":{}}`),
		},
		{
			name:      "raw_json",
			plaintext: []byte(`{"raw":true}`),
		},
		{
			name:      "non_json",
			plaintext: []byte(`raw`),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := decodeEncryptedInferenceChunkPlaintext("req-malformed", 9, true, tt.plaintext); err == nil {
				t.Fatal("decode succeeded for malformed typed envelope")
			}
		})
	}
}

func TestEncryptedRelayRejectsReplayedP2CSequence(t *testing.T) {
	s, provider, providerConn := newEncryptedRelayHarness(t)
	relay, err := s.DispatchInference(context.Background(), *provider, "req-replay", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request: %v", err)
	}

	first := encryptedResponseChunk(t, provider, "req-replay", false, 0, []byte(`{"ok":true}`))
	s.handleInferenceChunk("p1", "s1", first)
	select {
	case <-relay.Chunks:
	case err := <-relay.Errors:
		t.Fatalf("unexpected first-frame error: %v", err)
	case <-time.After(time.Second):
		t.Fatal("first chunk timeout")
	}

	s.handleInferenceChunk("p1", "s1", first)
	select {
	case err := <-relay.Errors:
		if err != ErrRelayAEADFailed {
			t.Fatalf("err = %v, want ErrRelayAEADFailed", err)
		}
	case <-time.After(time.Second):
		t.Fatal("replay error timeout")
	}
}

func TestEncryptedRelayRejectsSparseP2CSequenceGap(t *testing.T) {
	s, provider, providerConn := newEncryptedRelayHarness(t)
	relay, err := s.DispatchInference(context.Background(), *provider, "req-sparse-gap", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request: %v", err)
	}

	s.handleInferenceChunk("p1", "s1", encryptedResponseChunk(t, provider, "req-sparse-gap", false, tier2MaxOutOfOrderP2CFrames+1, []byte(`{"ok":true}`)))
	select {
	case err := <-relay.Errors:
		if err != ErrRelayAEADFailed {
			t.Fatalf("err = %v, want ErrRelayAEADFailed", err)
		}
	case <-time.After(time.Second):
		t.Fatal("sparse sequence gap error timeout")
	}
	if _, ok := s.storedSessionFor("p1", "s1"); ok {
		t.Fatal("session remained stored after sparse sequence gap")
	}
	if len(provider.Tier2Session.P2CSeen) != 0 {
		t.Fatalf("p2c seen count = %d, want 0 after rejected sparse gap", len(provider.Tier2Session.P2CSeen))
	}
}

func TestEncryptedRelayRoutesEndByAADWhenPlaintextRequestIDDiffers(t *testing.T) {
	s, provider, providerConn := newEncryptedRelayHarness(t)
	relay, err := s.DispatchInference(context.Background(), *provider, "req-aad", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request: %v", err)
	}
	before := RelayEndFrameAADMismatchTotalForTest()
	s.handleInferenceEnd("p1", "s1", encryptedResponseEnd(t, provider, "req-aad", false, 0, InferenceResponseEnd{
		Type:      "inference_response_end",
		RequestID: "req-plaintext",
		Status:    "complete",
	}))
	select {
	case end := <-relay.Done:
		if end.RequestID != "req-aad" || end.Status != "complete" {
			t.Fatalf("end=%#v, want AAD-routed request id", end)
		}
	case <-time.After(time.Second):
		t.Fatal("decrypted end timeout")
	}
	if got := RelayEndFrameAADMismatchTotalForTest(); got != before+1 {
		t.Fatalf("mismatch counter=%d, want %d", got, before+1)
	}
}

func TestRelayRequestBufferCapDropsRequest(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()
	cfg := config.Default()
	cfg.Relay.MaxRequestBufferBytes = 4
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
	s := NewServer(cfg, registry, zerolog.Nop())
	session := newProviderSession("p1", "s1", serverConn, 4)
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()
	relay, err := s.DispatchInference(context.Background(), *provider, "req-cap", []byte(`{"model":"model-a"}`), true)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read inference_request: %v", err)
	}
	before := RelayBufferExceededTotalForTest()
	s.handleInferenceChunk("p1", "s1", mustJSON(InferenceResponseChunk{Type: "inference_response_chunk", RequestID: "req-cap", Seq: 0, Data: "12345"}))
	select {
	case err := <-relay.Errors:
		if !errors.Is(err, ErrRelayBufferExceeded) {
			t.Fatalf("err=%v, want ErrRelayBufferExceeded", err)
		}
	case <-time.After(time.Second):
		t.Fatal("buffer exceeded error timeout")
	}
	if got := RelayBufferExceededTotalForTest(); got != before+1 {
		t.Fatalf("buffer counter=%d, want %d", got, before+1)
	}
}

func TestRelayRequestBufferCapCountsChunksUntilBuyerReads(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()
	cfg := config.Default()
	cfg.Relay.MaxRequestBufferBytes = 4
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
	s := NewServer(cfg, registry, zerolog.Nop())
	session := newProviderSession("p1", "s1", serverConn, 4)
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()
	relay, err := s.DispatchInference(context.Background(), *provider, "req-cap-slow", []byte(`{"model":"model-a"}`), true)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read inference_request: %v", err)
	}

	s.handleInferenceChunk("p1", "s1", mustJSON(InferenceResponseChunk{Type: "inference_response_chunk", RequestID: "req-cap-slow", Seq: 0, Data: "1234"}))
	s.handleInferenceChunk("p1", "s1", mustJSON(InferenceResponseChunk{Type: "inference_response_chunk", RequestID: "req-cap-slow", Seq: 1, Data: "x"}))
	select {
	case err := <-relay.Errors:
		if !errors.Is(err, ErrRelayBufferExceeded) {
			t.Fatalf("err=%v, want ErrRelayBufferExceeded", err)
		}
	case <-time.After(time.Second):
		t.Fatal("buffer exceeded error timeout")
	}
}

func TestRelayRequestBufferCapReleasesDeliveredChunks(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()
	cfg := config.Default()
	cfg.Relay.MaxRequestBufferBytes = 4
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
	s := NewServer(cfg, registry, zerolog.Nop())
	session := newProviderSession("p1", "s1", serverConn, 4)
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()
	relay, err := s.DispatchInference(context.Background(), *provider, "req-cap-release", []byte(`{"model":"model-a"}`), true)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read inference_request: %v", err)
	}

	s.handleInferenceChunk("p1", "s1", mustJSON(InferenceResponseChunk{Type: "inference_response_chunk", RequestID: "req-cap-release", Seq: 0, Data: "1234"}))
	select {
	case chunk := <-relay.Chunks:
		if chunk.Data != "1234" {
			t.Fatalf("chunk data=%q, want 1234", chunk.Data)
		}
	case err := <-relay.Errors:
		t.Fatalf("unexpected relay error before release: %v", err)
	case <-time.After(time.Second):
		t.Fatal("first chunk timeout")
	}

	s.handleInferenceChunk("p1", "s1", mustJSON(InferenceResponseChunk{Type: "inference_response_chunk", RequestID: "req-cap-release", Seq: 1, Data: "abcd"}))
	select {
	case chunk := <-relay.Chunks:
		if chunk.Data != "abcd" {
			t.Fatalf("chunk data=%q, want abcd", chunk.Data)
		}
	case err := <-relay.Errors:
		t.Fatalf("buffer accounting did not release delivered chunk: %v", err)
	case <-time.After(time.Second):
		t.Fatal("second chunk timeout")
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

func TestEncryptedRelayRejectsSparseLateRetiredP2CSequenceGap(t *testing.T) {
	s, provider, providerConn := newEncryptedRelayHarness(t)
	relay, err := s.DispatchInference(context.Background(), *provider, "req-late-sparse-gap", []byte(`{"model":"model-a"}`), false)
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

	s.handleInferenceEnd("p1", "s1", encryptedResponseEnd(t, provider, "req-late-sparse-gap", false, tier2MaxOutOfOrderP2CFrames+1, InferenceResponseEnd{
		Type:       "inference_response_end",
		RequestID:  "req-late-sparse-gap",
		Status:     "complete",
		ChunksSent: 0,
	}))

	if _, ok := s.storedSessionFor("p1", "s1"); ok {
		t.Fatal("session remained stored after sparse retired sequence gap")
	}
	if len(provider.Tier2Session.P2CSeen) != 0 {
		t.Fatalf("p2c seen count = %d, want 0 after rejected retired sparse gap", len(provider.Tier2Session.P2CSeen))
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
	oldKID := provider.Tier2Session.KeyID

	relay, err := s.DispatchInference(context.Background(), *provider, "req-rekey", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request: %v", err)
	}
	s.handleInferenceChunk("p1", "s1", encryptedResponseChunk(t, provider, "req-rekey", false, 0, []byte(`{"ok":true}`)))
	select {
	case <-relay.Chunks:
	case <-time.After(time.Second):
		t.Fatal("chunk timeout")
	}
	s.handleInferenceEnd("p1", "s1", encryptedResponseEnd(t, provider, "req-rekey", false, 1, InferenceResponseEnd{Type: "inference_response_end", RequestID: "req-rekey", Status: "complete", ChunksSent: 1}))

	select {
	case end := <-relay.Done:
		if end.Status != "complete" {
			t.Fatalf("end = %#v", end)
		}
	case <-time.After(time.Second):
		t.Fatal("end timeout")
	}

	rekeyedProvider := completeTestTier2Rekey(t, s, providerConn, provider)
	if rekeyedProvider.AssignedID != provider.AssignedID {
		t.Fatalf("assigned id changed across in-band rekey: got %q want %q", rekeyedProvider.AssignedID, provider.AssignedID)
	}
	if rekeyedProvider.Tier2Session == nil || rekeyedProvider.Tier2Session.KeyID == oldKID {
		t.Fatalf("rekey did not install independent key material: old=%q new=%#v", oldKID, rekeyedProvider.Tier2Session)
	}
	if _, ok := s.storedSessionFor("p1", "s1"); !ok {
		t.Fatal("same authenticated provider session was removed during in-band rekey")
	}
	if rekeyedProvider.State != pool.StateReady {
		t.Fatalf("state = %s, want ready", rekeyedProvider.State)
	}

	relay2, err := s.DispatchInference(context.Background(), *rekeyedProvider, "req-after-rekey", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch after rekey: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read post-rekey inference_request: %v", err)
	}
	s.handleInferenceChunk("p1", "s1", encryptedResponseChunk(t, rekeyedProvider, "req-after-rekey", false, 1, []byte(`{"ok":true}`)))
	select {
	case <-relay2.Chunks:
	case <-time.After(time.Second):
		t.Fatal("post-rekey chunk timeout")
	}
	s.handleInferenceEnd("p1", "s1", encryptedResponseEnd(t, rekeyedProvider, "req-after-rekey", false, 2, InferenceResponseEnd{Type: "inference_response_end", RequestID: "req-after-rekey", Status: "complete", ChunksSent: 1}))
	select {
	case end := <-relay2.Done:
		if end.Status != "complete" {
			t.Fatalf("post-rekey end = %#v", end)
		}
	case <-time.After(time.Second):
		t.Fatal("post-rekey end timeout")
	}
	if !bytes.Contains(logs.Bytes(), []byte(`"event":"aead_rekey_committed"`)) || !bytes.Contains(logs.Bytes(), []byte(`"reason":"request_threshold"`)) ||
		!bytes.Contains(logs.Bytes(), []byte(`"alg":"A256GCM"`)) || !bytes.Contains(logs.Bytes(), []byte(`"kid":"`)) {
		t.Fatalf("missing request-threshold rekey log: %s", logs.String())
	}
}

func TestEncryptedRelayBoundsWaitersDuringRekey(t *testing.T) {
	cfg := config.Default()
	cfg.Tier2.EncryptedLegRekeyAfterSeconds = 1
	s, provider, providerConn := newEncryptedRelayHarnessWithConfig(t, cfg, zerolog.Nop(), time.Now().Add(-2*time.Second))
	limit := tier2RekeyWaiterLimit(provider.MaxConcurrency)
	results := make(chan error, limit)
	cancels := make([]context.CancelFunc, 0, limit)
	for i := 0; i < limit; i++ {
		ctx, cancel := context.WithCancel(context.Background())
		cancels = append(cancels, cancel)
		go func(i int) {
			_, err := s.DispatchInference(ctx, *provider, fmt.Sprintf("req-rekey-waiter-%d", i), []byte(`{"model":"model-a"}`), false)
			results <- err
		}(i)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read aead_rekey_request: %v", err)
	}
	deadline := time.Now().Add(time.Second)
	for {
		session := sessionForTest(s, provider.ProviderID, provider.AssignedID)
		session.rekeyMu.Lock()
		waiters := session.rekeyWaiters
		session.rekeyMu.Unlock()
		if waiters == limit {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("rekey waiters = %d, want %d", waiters, limit)
		}
		time.Sleep(time.Millisecond)
	}
	if _, err := s.DispatchInference(context.Background(), *provider, "req-rekey-overload", []byte(`{"model":"model-a"}`), false); !errors.Is(err, ErrRelayBackpressure) {
		t.Fatalf("overflow rekey waiter = %v, want ErrRelayBackpressure", err)
	}
	for _, cancel := range cancels {
		cancel()
	}
	for i := 0; i < limit; i++ {
		select {
		case err := <-results:
			if !errors.Is(err, ErrRelayClosed) {
				t.Fatalf("canceled rekey waiter = %v, want ErrRelayClosed", err)
			}
		case <-time.After(time.Second):
			t.Fatal("canceled rekey waiter did not release")
		}
	}
	got, ok := s.pool.Resolve(provider.ProviderID, provider.AssignedID)
	if !ok || got.State != pool.StateReady {
		t.Fatalf("provider after waiter overload = %#v ok=%v, want ready", got, ok)
	}
}

func TestEncryptedRelayRekeyWaitsForPendingLosslessnessProbe(t *testing.T) {
	now := time.Date(2026, 7, 13, 12, 0, 0, 0, time.UTC)
	cfg := config.Default()
	cfg.Tier2.EncryptedLegRekeyAfterSeconds = 1
	s, provider, providerConn := newEncryptedRelayHarnessWithConfig(t, cfg, zerolog.Nop(), now.Add(-2*time.Second))
	s.now = func() time.Time { return now }
	request := losslessnessTestRequestPayload(now.Add(time.Minute))
	pending, err := s.recordLosslessnessPendingProbe(provider.ProviderID, provider.AssignedID, request, "sha256:rekey-barrier", now)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	result := make(chan error, 1)
	go func() {
		_, err := s.DispatchInference(ctx, *provider, "req-after-losslessness", []byte(`{"model":"model-a"}`), false)
		result <- err
	}()
	if err := providerConn.SetReadDeadline(time.Now().Add(75 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err == nil {
		t.Fatal("rekey request sent before old-epoch losslessness probe drained")
	}
	if err := providerConn.SetReadDeadline(time.Time{}); err != nil {
		t.Fatal(err)
	}
	s.losslessnessPending.Delete(losslessnessProbeStoreKey(provider.ProviderID, provider.AssignedID, pending.ProbeID))
	s.deleteLosslessnessPendingIndexes(pending)
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read aead_rekey_request after probe drain: %v", err)
	}
	cancel()
	select {
	case err := <-result:
		if !errors.Is(err, ErrRelayClosed) {
			t.Fatalf("canceled dispatch = %v, want ErrRelayClosed", err)
		}
	case <-time.After(time.Second):
		t.Fatal("canceled dispatch did not release")
	}
}

func TestEncryptedRelayRejectsExpiredCommittedProof(t *testing.T) {
	now := time.Date(2026, 7, 13, 12, 0, 0, 0, time.UTC)
	s, provider, _ := newEncryptedRelayHarness(t)
	s.now = func() time.Time { return now }
	payload, exchange := seedTestTier2Committed(t, s, provider, now, []byte(`{"proof":"valid"}`))
	s.handleAEADRekeyCommitted(provider.ProviderID, provider.AssignedID, payload)
	if !errors.Is(exchange.err, ErrRelayAEADFailed) {
		t.Fatalf("expired committed proof error = %v, want ErrRelayAEADFailed", exchange.err)
	}
	if _, ok := s.storedSessionFor(provider.ProviderID, provider.AssignedID); ok {
		t.Fatal("expired committed proof left provider session stored")
	}
}

func TestEncryptedRelayRejectsTamperedCommittedProof(t *testing.T) {
	now := time.Date(2026, 7, 13, 12, 0, 0, 0, time.UTC)
	s, provider, _ := newEncryptedRelayHarness(t)
	s.now = func() time.Time { return now }
	payload, exchange := seedTestTier2Committed(t, s, provider, now.Add(time.Minute), []byte(`{"proof":"wire"}`))
	exchange.proof = []byte(`{"proof":"expected"}`)
	s.handleAEADRekeyCommitted(provider.ProviderID, provider.AssignedID, payload)
	if !errors.Is(exchange.err, ErrRelayAEADFailed) {
		t.Fatalf("tampered committed proof error = %v, want ErrRelayAEADFailed", exchange.err)
	}
	if _, ok := s.storedSessionFor(provider.ProviderID, provider.AssignedID); ok {
		t.Fatal("tampered committed proof left provider session stored")
	}
}

func TestEncryptedRelayStartsNewEpochAgeAtCommitInstallation(t *testing.T) {
	requestedAt := time.Date(2026, 7, 13, 12, 0, 0, 0, time.UTC)
	installedAt := requestedAt.Add(5 * time.Second)
	s, provider, _ := newEncryptedRelayHarness(t)
	now := requestedAt
	s.now = func() time.Time { return now }
	payload, _ := seedTestTier2Committed(t, s, provider, requestedAt.Add(time.Minute), []byte(`{"proof":"valid"}`))
	now = installedAt
	s.handleAEADRekeyCommitted(provider.ProviderID, provider.AssignedID, payload)
	resolved, ok := s.pool.Resolve(provider.ProviderID, provider.AssignedID)
	if !ok || resolved.Tier2Session == nil {
		t.Fatalf("provider after commit = %#v ok=%v", resolved, ok)
	}
	if !resolved.Tier2Session.StartedAt.Equal(installedAt) {
		t.Fatalf("new epoch StartedAt = %s, want install time %s", resolved.Tier2Session.StartedAt, installedAt)
	}
	cfg := config.Default().Tier2
	cfg.EncryptedLegRekeyAfterSeconds = 1
	if _, due := sessionForTest(s, provider.ProviderID, provider.AssignedID).tier2RekeyReason(installedAt.Add(500*time.Millisecond), cfg); due {
		t.Fatal("new epoch became due before receiving its full configured lifetime")
	}
}

func TestEncryptedRelayIgnoresReplayedCommittedProofAfterCutover(t *testing.T) {
	now := time.Date(2026, 7, 13, 12, 0, 0, 0, time.UTC)
	s, provider, _ := newEncryptedRelayHarness(t)
	s.now = func() time.Time { return now }
	payload, exchange := seedTestTier2Committed(t, s, provider, now.Add(time.Minute), []byte(`{"proof":"valid"}`))
	s.handleAEADRekeyCommitted(provider.ProviderID, provider.AssignedID, payload)
	committed, ok := s.pool.Resolve(provider.ProviderID, provider.AssignedID)
	if !ok || committed.Tier2Session == nil || committed.Tier2Session.KeyID == exchange.oldKID {
		t.Fatalf("provider after first commit = %#v ok=%v", committed, ok)
	}

	s.handleAEADRekeyCommitted(provider.ProviderID, provider.AssignedID, payload)
	replayed, ok := s.pool.Resolve(provider.ProviderID, provider.AssignedID)
	if !ok || replayed.Tier2Session != committed.Tier2Session || replayed.Tier2Session.P2CCounter != 1 || replayed.State != pool.StateReady {
		t.Fatalf("provider after replayed commit = %#v ok=%v, want unchanged committed epoch", replayed, ok)
	}
	if exchange.err != nil {
		t.Fatalf("replayed commit mutated completed exchange error: %v", exchange.err)
	}
}

func TestEncryptedRelayCounterExhaustionClosesSession(t *testing.T) {
	s, provider, _ := newEncryptedRelayHarness(t)
	provider.Tier2Session.C2PCounter = ^uint64(0)
	if _, err := s.DispatchInference(context.Background(), *provider, "req-counter-exhausted", []byte(`{"model":"model-a"}`), false); !errors.Is(err, ErrRelayAEADFailed) {
		t.Fatalf("counter-exhausted dispatch = %v, want ErrRelayAEADFailed", err)
	}
	if _, ok := s.storedSessionFor(provider.ProviderID, provider.AssignedID); ok {
		t.Fatal("counter-exhausted session remained stored")
	}
	resolved, ok := s.pool.Resolve(provider.ProviderID, provider.AssignedID)
	if !ok || resolved.State != pool.StateUnavailable {
		t.Fatalf("counter-exhausted provider = %#v ok=%v, want unavailable", resolved, ok)
	}
}

func TestEncryptedRelayRekeySocketWriteFailureEmitsFailedAudit(t *testing.T) {
	var logs bytes.Buffer
	cfg := config.Default()
	cfg.Tier2.EncryptedLegRekeyAfterSeconds = 1
	s, provider, providerConn := newEncryptedRelayHarnessWithConfig(t, cfg, zerolog.New(&logs), time.Now().Add(-2*time.Second))
	if err := providerConn.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := s.DispatchInference(context.Background(), *provider, "req-rekey-write-failure", []byte(`{"model":"model-a"}`), false); !errors.Is(err, ErrRelayClosed) {
		t.Fatalf("dispatch after rekey write failure = %v, want ErrRelayClosed", err)
	}
	if !bytes.Contains(logs.Bytes(), []byte(`"event":"aead_rekey_failed"`)) ||
		!bytes.Contains(logs.Bytes(), []byte(`"reason":"write_failed"`)) ||
		!bytes.Contains(logs.Bytes(), []byte(`"alg":"A256GCM"`)) {
		t.Fatalf("missing write-failure rekey audit: %s", logs.String())
	}
	resolved, ok := s.pool.Resolve(provider.ProviderID, provider.AssignedID)
	if !ok || resolved.State != pool.StateUnavailable {
		t.Fatalf("provider after rekey write failure = %#v ok=%v, want unavailable", resolved, ok)
	}
}

func TestEncryptedRelayRekeySessionCloseEmitsFailedAudit(t *testing.T) {
	var logs bytes.Buffer
	cfg := config.Default()
	cfg.Tier2.EncryptedLegRekeyAfterSeconds = 1
	s, provider, providerConn := newEncryptedRelayHarnessWithConfig(t, cfg, zerolog.New(&logs), time.Now().Add(-2*time.Second))
	result := make(chan error, 1)
	go func() {
		_, err := s.DispatchInference(context.Background(), *provider, "req-rekey-session-close", []byte(`{"model":"model-a"}`), false)
		result <- err
	}()
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read aead_rekey_request: %v", err)
	}
	sessionForTest(s, provider.ProviderID, provider.AssignedID).close()
	select {
	case err := <-result:
		if !errors.Is(err, ErrRelayClosed) {
			t.Fatalf("dispatch after rekey session close = %v, want ErrRelayClosed", err)
		}
	case <-time.After(time.Second):
		t.Fatal("session close did not release rekey waiter")
	}
	if !bytes.Contains(logs.Bytes(), []byte(`"event":"aead_rekey_failed"`)) ||
		!bytes.Contains(logs.Bytes(), []byte(`"reason":"session_closed"`)) {
		t.Fatalf("missing session-close rekey audit: %s", logs.String())
	}
	if _, ok := s.storedSessionFor(provider.ProviderID, provider.AssignedID); ok {
		t.Fatal("session-close rekey remained stored")
	}
	resolved, ok := s.pool.Resolve(provider.ProviderID, provider.AssignedID)
	if !ok || resolved.State != pool.StateUnavailable {
		t.Fatalf("provider after rekey session close = %#v ok=%v, want unavailable", resolved, ok)
	}
}

func seedTestTier2Committed(t *testing.T, s *Server, provider *pool.Provider, expiresAt time.Time, proof []byte) ([]byte, *tier2RekeyExchange) {
	t.Helper()
	next := &pool.Tier2Session{
		AEADSuite:                      tier2.PillarBAEADA256GCM,
		ResponseChunkPlaintextEnvelope: true,
		InBandAEADRekeyV1:              true,
		C2PKey:                         bytes.Repeat([]byte{0x31}, 32),
		P2CKey:                         bytes.Repeat([]byte{0x32}, 32),
		C2PNonceBase:                   []byte{0x11, 0x12, 0x13, 0x14},
		P2CNonceBase:                   []byte{0x21, 0x22, 0x23, 0x24},
		C2PCounter:                     1,
		KeyID:                          "test-next-kid",
	}
	exchange := &tier2RekeyExchange{
		id:        "test-rekey-id",
		reason:    "age_threshold",
		requestID: "req-rekey-proof",
		oldKID:    provider.Tier2Session.KeyID,
		request: AEADRekeyRequest{
			ExpiresAt: expiresAt.UTC().Format(time.RFC3339Nano),
		},
		next:  next,
		proof: append([]byte(nil), proof...),
		phase: "commit_sent",
		done:  make(chan struct{}),
	}
	session := sessionForTest(s, provider.ProviderID, provider.AssignedID)
	session.rekeyMu.Lock()
	session.rekey = exchange
	session.rekeyMu.Unlock()
	aad := tier2.AEADFrameAAD{
		Type: "aead_rekey_committed", Direction: "p2c", RequestID: exchange.id,
		ProviderID: provider.ProviderID, AssignedID: provider.AssignedID, Seq: 0,
	}
	envelope, err := tier2.SealPillarBFrame(next.P2CKey, next.P2CNonceBase, next.KeyID, 0, aad, proof)
	if err != nil {
		t.Fatal(err)
	}
	return mustJSON(AEADRekeyConfirmation{
		Type: "aead_rekey_committed", Version: 1, RekeyID: exchange.id,
		AssignedID: provider.AssignedID, OldKID: exchange.oldKID, NewKID: next.KeyID,
		Encrypted: true, Enc: envelope.Enc,
	}), exchange
}

func completeTestTier2Rekey(t *testing.T, s *Server, providerConn net.Conn, provider *pool.Provider) *pool.Provider {
	t.Helper()
	payload, _, err := wsutil.ReadServerData(providerConn)
	if err != nil {
		t.Fatalf("read aead_rekey_request: %v", err)
	}
	var request struct {
		Type                           string `json:"type"`
		Version                        int    `json:"version"`
		RekeyID                        string `json:"rekey_id"`
		AssignedID                     string `json:"assigned_id"`
		Reason                         string `json:"reason"`
		OldKID                         string `json:"old_kid"`
		CoordinatorECDHPublicKey       string `json:"coordinator_ecdh_public_key"`
		SelectedAEAD                   string `json:"selected_aead"`
		ExpiresAt                      string `json:"expires_at"`
		ResponseChunkPlaintextEnvelope bool   `json:"response_chunk_plaintext_envelope"`
	}
	if err := json.Unmarshal(payload, &request); err != nil {
		t.Fatalf("decode aead_rekey_request: %v", err)
	}
	if request.Type != "aead_rekey_request" || request.Version != 1 || request.RekeyID == "" {
		t.Fatalf("invalid aead_rekey_request: %#v", request)
	}
	if request.AssignedID != provider.AssignedID || request.OldKID != provider.Tier2Session.KeyID {
		t.Fatalf("rekey binding mismatch: %#v", request)
	}

	coordinatorPublic, coordinatorPublicRaw, err := tier2.ParseX25519PublicKey(request.CoordinatorECDHPublicKey)
	if err != nil {
		t.Fatalf("parse coordinator rekey public key: %v", err)
	}
	providerPrivate, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate provider rekey key: %v", err)
	}
	shared, err := providerPrivate.ECDH(coordinatorPublic)
	if err != nil {
		t.Fatalf("derive rekey shared secret: %v", err)
	}
	providerPublicRaw := providerPrivate.PublicKey().Bytes()
	keys, err := tier2.DerivePillarBKeysFromSharedSecret(shared, provider.ProviderID, provider.AssignedID, providerPublicRaw, coordinatorPublicRaw, request.SelectedAEAD)
	if err != nil {
		t.Fatalf("derive provider rekey material: %v", err)
	}
	nextSession := &pool.Tier2Session{
		AEADSuite:                      keys.AEADSuite,
		ResponseChunkPlaintextEnvelope: request.ResponseChunkPlaintextEnvelope,
		C2PKey:                         keys.C2PKey,
		P2CKey:                         keys.P2CKey,
		C2PNonceBase:                   keys.C2PNonceBase,
		P2CNonceBase:                   keys.P2CNonceBase,
		KeyID:                          keys.KeyID,
		StartedAt:                      time.Now(),
	}
	s.handleMessage(providerConn, provider.ProviderID, provider.AssignedID, mustJSON(map[string]any{
		"type": "aead_rekey_response", "version": 1, "rekey_id": request.RekeyID,
		"assigned_id": provider.AssignedID, "old_kid": request.OldKID, "new_kid": keys.KeyID,
		"provider_ecdh_public_key": base64.RawURLEncoding.EncodeToString(providerPublicRaw),
	}))

	commitPayload, _, err := wsutil.ReadServerData(providerConn)
	if err != nil {
		t.Fatalf("read aead_rekey_commit: %v", err)
	}
	var commit struct {
		Type       string                 `json:"type"`
		Version    int                    `json:"version"`
		RekeyID    string                 `json:"rekey_id"`
		AssignedID string                 `json:"assigned_id"`
		OldKID     string                 `json:"old_kid"`
		NewKID     string                 `json:"new_kid"`
		Encrypted  bool                   `json:"encrypted"`
		Enc        tier2.AEADEnvelopeBody `json:"enc"`
	}
	if err := json.Unmarshal(commitPayload, &commit); err != nil {
		t.Fatalf("decode aead_rekey_commit: %v", err)
	}
	if commit.Type != "aead_rekey_commit" || commit.RekeyID != request.RekeyID || commit.NewKID != keys.KeyID {
		t.Fatalf("invalid aead_rekey_commit: %#v", commit)
	}
	commitAAD := tier2.AEADFrameAAD{
		Type: "aead_rekey_commit", Direction: "c2p", RequestID: request.RekeyID,
		ProviderID: provider.ProviderID, AssignedID: provider.AssignedID, Seq: 0,
	}
	commitPlaintext, err := tier2.OpenPillarBFrame(keys.C2PKey, keys.C2PNonceBase, keys.KeyID, 0, commitAAD, tier2.AEADEnvelope{Encrypted: commit.Encrypted, Enc: commit.Enc})
	if err != nil {
		t.Fatalf("open aead_rekey_commit proof: %v", err)
	}
	var proof map[string]any
	if err := json.Unmarshal(commitPlaintext, &proof); err != nil {
		t.Fatalf("decode aead_rekey_commit proof: %v", err)
	}
	if proof["old_kid"] != request.OldKID || proof["new_kid"] != keys.KeyID {
		t.Fatalf("aead_rekey_commit proof binding mismatch: %#v", proof)
	}
	nextSession.C2PCounter = 1
	committedAAD := tier2.AEADFrameAAD{
		Type: "aead_rekey_committed", Direction: "p2c", RequestID: request.RekeyID,
		ProviderID: provider.ProviderID, AssignedID: provider.AssignedID, Seq: 0,
	}
	committedEnvelope, err := tier2.SealPillarBFrame(keys.P2CKey, keys.P2CNonceBase, keys.KeyID, 0, committedAAD, commitPlaintext)
	if err != nil {
		t.Fatalf("seal aead_rekey_committed proof: %v", err)
	}
	nextSession.P2CCounter = 1
	s.handleMessage(providerConn, provider.ProviderID, provider.AssignedID, mustJSON(map[string]any{
		"type": "aead_rekey_committed", "version": 1, "rekey_id": request.RekeyID,
		"assigned_id": provider.AssignedID, "old_kid": request.OldKID, "new_kid": keys.KeyID,
		"encrypted": true, "enc": committedEnvelope.Enc,
	}))

	resolved, ok := s.pool.Resolve(provider.ProviderID, provider.AssignedID)
	if !ok {
		t.Fatal("provider missing after committed rekey")
	}
	if resolved.Tier2Session == nil || resolved.Tier2Session.KeyID != nextSession.KeyID {
		t.Fatalf("pool rekey session = %#v, want kid %q", resolved.Tier2Session, nextSession.KeyID)
	}
	return &resolved
}

func TestEncryptedRelayQueuesDispatchUntilActiveRequestsFinishAndRekeyCommits(t *testing.T) {
	var logs bytes.Buffer
	cfg := config.Default()
	cfg.Tier2.EncryptedLegRekeyAfterRequests = 2
	s, provider, providerConn := newEncryptedRelayHarnessWithConfig(t, cfg, zerolog.New(&logs), time.Now())
	provider.MaxConcurrency = 2

	relayA, err := s.DispatchInference(context.Background(), *provider, "req-rekey-active-a", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("first dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request a: %v", err)
	}
	relayB, err := s.DispatchInference(context.Background(), *provider, "req-rekey-active-b", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("second dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request b: %v", err)
	}
	type dispatchResult struct {
		relay *RelayStream
		err   error
	}
	thirdResult := make(chan dispatchResult, 1)
	thirdCtx, cancelThird := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancelThird()
	go func() {
		relay, err := s.DispatchInference(thirdCtx, *provider, "req-rekey-third", []byte(`{"model":"model-a"}`), false)
		thirdResult <- dispatchResult{relay: relay, err: err}
	}()
	if _, ok := s.storedSessionFor("p1", "s1"); !ok {
		t.Fatal("session closed before active requests completed")
	}

	s.handleInferenceChunk("p1", "s1", encryptedResponseChunk(t, provider, "req-rekey-active-a", false, 0, []byte(`{"a":true}`)))
	select {
	case <-relayA.Chunks:
	case <-time.After(time.Second):
		t.Fatal("chunk a timeout")
	}
	s.handleInferenceEnd("p1", "s1", encryptedResponseEnd(t, provider, "req-rekey-active-a", false, 1, InferenceResponseEnd{Type: "inference_response_end", RequestID: "req-rekey-active-a", Status: "complete", ChunksSent: 1}))

	select {
	case end := <-relayA.Done:
		if end.Status != "complete" {
			t.Fatalf("end = %#v", end)
		}
	case <-time.After(time.Second):
		t.Fatal("end a timeout")
	}
	if _, ok := s.storedSessionFor("p1", "s1"); !ok {
		t.Fatal("session closed before second active request completed")
	}
	select {
	case result := <-thirdResult:
		t.Fatalf("third dispatch returned before old in-flight work drained: %v", result.err)
	case <-time.After(50 * time.Millisecond):
	}

	s.handleInferenceChunk("p1", "s1", encryptedResponseChunk(t, provider, "req-rekey-active-b", false, 2, []byte(`{"b":true}`)))
	select {
	case <-relayB.Chunks:
	case <-time.After(time.Second):
		t.Fatal("chunk b timeout")
	}
	s.handleInferenceEnd("p1", "s1", encryptedResponseEnd(t, provider, "req-rekey-active-b", false, 3, InferenceResponseEnd{Type: "inference_response_end", RequestID: "req-rekey-active-b", Status: "complete", ChunksSent: 1}))

	select {
	case end := <-relayB.Done:
		if end.Status != "complete" {
			t.Fatalf("end = %#v", end)
		}
	case <-time.After(time.Second):
		t.Fatal("end b timeout")
	}

	rekeyedProvider := completeTestTier2Rekey(t, s, providerConn, provider)
	select {
	case result := <-thirdResult:
		if result.err != nil || result.relay == nil {
			t.Fatalf("queued dispatch after rekey = relay %#v err %v", result.relay, result.err)
		}
	case <-time.After(time.Second):
		t.Fatal("queued dispatch did not resume after rekey commit")
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read queued post-rekey inference_request: %v", err)
	}
	if _, ok := s.storedSessionFor("p1", "s1"); !ok {
		t.Fatal("same session removed after drained rekey")
	}
	if rekeyedProvider.State != pool.StateReady {
		t.Fatalf("state = %s, want ready", rekeyedProvider.State)
	}
	if !bytes.Contains(logs.Bytes(), []byte(`"event":"aead_rekey_committed"`)) || !bytes.Contains(logs.Bytes(), []byte(`"reason":"request_threshold"`)) {
		t.Fatalf("missing request-threshold rekey log: %s", logs.String())
	}
}

func TestEncryptedRelayRekeysAfterActiveCancelWithoutUnpublishing(t *testing.T) {
	var logs bytes.Buffer
	cfg := config.Default()
	cfg.Tier2.EncryptedLegRekeyAfterRequests = 2
	s, provider, providerConn := newEncryptedRelayHarnessWithConfig(t, cfg, zerolog.New(&logs), time.Now())
	provider.MaxConcurrency = 2

	relayA, err := s.DispatchInference(context.Background(), *provider, "req-rekey-cancel-a", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("first dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request a: %v", err)
	}
	relayB, err := s.DispatchInference(context.Background(), *provider, "req-rekey-cancel-b", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("second dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request b: %v", err)
	}
	thirdResult := make(chan error, 1)
	thirdCtx, cancelThird := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancelThird()
	go func() {
		_, err := s.DispatchInference(thirdCtx, *provider, "req-rekey-cancel-third", []byte(`{"model":"model-a"}`), false)
		thirdResult <- err
	}()

	relayA.Cancel("buyer_disconnected")
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read cancel_request a: %v", err)
	}
	if _, ok := s.storedSessionFor("p1", "s1"); !ok {
		t.Fatal("session closed before second active request canceled")
	}

	relayB.Cancel("buyer_disconnected")
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read cancel_request b: %v", err)
	}
	rekeyedProvider := completeTestTier2Rekey(t, s, providerConn, provider)
	select {
	case err := <-thirdResult:
		if err != nil {
			t.Fatalf("queued dispatch after canceled drain: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("queued dispatch did not resume after canceled drain rekey")
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read queued inference_request after cancel: %v", err)
	}
	if rekeyedProvider.State != pool.StateReady {
		t.Fatalf("state = %s, want ready", rekeyedProvider.State)
	}
	if !bytes.Contains(logs.Bytes(), []byte(`"event":"aead_rekey_committed"`)) || !bytes.Contains(logs.Bytes(), []byte(`"reason":"request_threshold"`)) {
		t.Fatalf("missing request-threshold rekey log: %s", logs.String())
	}
}

func TestEncryptedRelayRekeysExpiredSessionBeforeDispatch(t *testing.T) {
	var logs bytes.Buffer
	cfg := config.Default()
	cfg.Tier2.EncryptedLegRekeyAfterSeconds = 1
	s, provider, providerConn := newEncryptedRelayHarnessWithConfig(t, cfg, zerolog.New(&logs), time.Now().Add(-2*time.Second))
	oldSession := provider.Tier2Session

	dispatchResult := make(chan error, 1)
	dispatchCtx, cancelDispatch := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancelDispatch()
	go func() {
		_, err := s.DispatchInference(dispatchCtx, *provider, "req-expired", []byte(`{"model":"model-a"}`), false)
		dispatchResult <- err
	}()
	rekeyedProvider := completeTestTier2Rekey(t, s, providerConn, provider)
	select {
	case err := <-dispatchResult:
		if err != nil {
			t.Fatalf("dispatch after age rekey: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("expired-session dispatch did not resume after rekey")
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read post-age-rekey inference_request: %v", err)
	}
	if oldSession.C2PCounter != 0 {
		t.Fatalf("old c2p counter = %d, want 0", oldSession.C2PCounter)
	}
	if oldSession.RequestsDispatched != 0 {
		t.Fatalf("old requests dispatched = %d, want 0", oldSession.RequestsDispatched)
	}
	if rekeyedProvider.State != pool.StateReady {
		t.Fatalf("state = %s, want ready", rekeyedProvider.State)
	}
	if !bytes.Contains(logs.Bytes(), []byte(`"event":"aead_rekey_committed"`)) || !bytes.Contains(logs.Bytes(), []byte(`"reason":"age_threshold"`)) {
		t.Fatalf("missing age-threshold rekey log: %s", logs.String())
	}
}

func TestEncryptedRelayRekeyTimeoutFailsClosedAfterIdle(t *testing.T) {
	var logs bytes.Buffer
	cfg := config.Default()
	cfg.WS.HandshakeTimeoutS = 1
	cfg.Tier2.EncryptedLegRekeyAfterSeconds = 1
	s, provider, providerConn := newEncryptedRelayHarnessWithConfig(t, cfg, zerolog.New(&logs), time.Now().Add(-2*time.Second))

	result := make(chan error, 1)
	go func() {
		_, err := s.DispatchInference(context.Background(), *provider, "req-timeout-rekey", []byte(`{"model":"model-a"}`), false)
		result <- err
	}()
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read aead_rekey_request: %v", err)
	}
	select {
	case err := <-result:
		if err != ErrRelayTimeout {
			t.Fatalf("dispatch after rekey timeout = %v, want ErrRelayTimeout", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("rekey timeout did not release queued dispatch")
	}
	if _, ok := s.storedSessionFor("p1", "s1"); ok {
		t.Fatal("timed-out rekey session remained stored")
	}
	got, ok := s.pool.Resolve("p1", "s1")
	if !ok || got.State != pool.StateUnavailable {
		t.Fatalf("provider after timeout = %#v ok=%v, want unavailable", got, ok)
	}
	if !bytes.Contains(logs.Bytes(), []byte(`"event":"aead_rekey_failed"`)) || !bytes.Contains(logs.Bytes(), []byte(`"reason":"timeout"`)) {
		t.Fatalf("missing timeout audit log: %s", logs.String())
	}
}

func TestEncryptedRelayRejectsMismatchedRekeyResponseAndFailsClosed(t *testing.T) {
	cfg := config.Default()
	cfg.Tier2.EncryptedLegRekeyAfterSeconds = 1
	s, provider, providerConn := newEncryptedRelayHarnessWithConfig(t, cfg, zerolog.Nop(), time.Now().Add(-2*time.Second))

	result := make(chan error, 1)
	go func() {
		_, err := s.DispatchInference(context.Background(), *provider, "req-bad-rekey", []byte(`{"model":"model-a"}`), false)
		result <- err
	}()
	payload, _, err := wsutil.ReadServerData(providerConn)
	if err != nil {
		t.Fatalf("read aead_rekey_request: %v", err)
	}
	var request AEADRekeyRequest
	if err := json.Unmarshal(payload, &request); err != nil {
		t.Fatalf("decode aead_rekey_request: %v", err)
	}
	s.handleMessage(providerConn, "p1", "s1", mustJSON(AEADRekeyResponse{
		Type: "aead_rekey_response", Version: 1, RekeyID: request.RekeyID,
		AssignedID: "s1", OldKID: "wrong-old-kid", NewKID: "attacker-kid",
		ProviderECDHPublicKey: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x41}, 32)),
	}))
	select {
	case err := <-result:
		if err != ErrRelayAEADFailed {
			t.Fatalf("dispatch after invalid rekey response = %v, want ErrRelayAEADFailed", err)
		}
	case <-time.After(time.Second):
		t.Fatal("invalid rekey response did not release queued dispatch")
	}
	if _, ok := s.storedSessionFor("p1", "s1"); ok {
		t.Fatal("invalid rekey response left session stored")
	}
}

func TestEncryptedRelayRekeyWaitHonorsBuyerContextWithoutUnpublishingProvider(t *testing.T) {
	cfg := config.Default()
	cfg.Tier2.EncryptedLegRekeyAfterSeconds = 1
	s, provider, providerConn := newEncryptedRelayHarnessWithConfig(t, cfg, zerolog.Nop(), time.Now().Add(-2*time.Second))
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() {
		_, err := s.DispatchInference(ctx, *provider, "req-canceled-rekey-wait", []byte(`{"model":"model-a"}`), false)
		result <- err
	}()
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read aead_rekey_request: %v", err)
	}
	cancel()
	select {
	case err := <-result:
		if err != ErrRelayClosed {
			t.Fatalf("canceled rekey wait = %v, want ErrRelayClosed", err)
		}
	case <-time.After(time.Second):
		t.Fatal("buyer cancellation did not release rekey waiter")
	}
	got, ok := s.pool.Resolve("p1", "s1")
	if !ok || got.State != pool.StateReady {
		t.Fatalf("provider after one canceled waiter = %#v ok=%v, want ready", got, ok)
	}
	sessionForTest(s, "p1", "s1").close()
}

func TestEncryptedRelayLegacyProviderFailsClosedAtRekeyBoundary(t *testing.T) {
	cfg := config.Default()
	cfg.Tier2.EncryptedLegRekeyAfterSeconds = 1
	s, provider, _ := newEncryptedRelayHarnessWithConfig(t, cfg, zerolog.Nop(), time.Now().Add(-2*time.Second))
	provider.Tier2Session.InBandAEADRekeyV1 = false

	if _, err := s.DispatchInference(context.Background(), *provider, "req-legacy-rekey", []byte(`{"model":"model-a"}`), false); err != ErrRelayClosed {
		t.Fatalf("legacy provider dispatch = %v, want ErrRelayClosed", err)
	}
	if _, ok := s.storedSessionFor("p1", "s1"); ok {
		t.Fatal("legacy provider remained stored past rekey boundary")
	}
	got, ok := s.pool.Resolve("p1", "s1")
	if !ok || got.State != pool.StateUnavailable {
		t.Fatalf("legacy provider after rekey boundary = %#v ok=%v, want unavailable", got, ok)
	}
}

func TestEncryptedRelayLegacyProviderDrainsInflightBeforeFailClosedRekey(t *testing.T) {
	cfg := config.Default()
	cfg.Tier2.EncryptedLegRekeyAfterRequests = 1
	s, provider, providerConn := newEncryptedRelayHarnessWithConfig(t, cfg, zerolog.Nop(), time.Now())
	provider.Tier2Session.InBandAEADRekeyV1 = false

	first, err := s.DispatchInference(context.Background(), *provider, "req-legacy-active", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("first legacy dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read first legacy inference_request: %v", err)
	}

	secondResult := make(chan error, 1)
	go func() {
		_, err := s.DispatchInference(context.Background(), *provider, "req-legacy-waiter", []byte(`{"model":"model-a"}`), false)
		secondResult <- err
	}()
	select {
	case err := <-secondResult:
		t.Fatalf("queued legacy dispatch returned before in-flight completion: %v", err)
	case <-time.After(50 * time.Millisecond):
	}
	if _, ok := s.storedSessionFor("p1", "s1"); !ok {
		t.Fatal("legacy session closed while old-epoch inference was active")
	}

	s.handleInferenceEnd("p1", "s1", encryptedResponseEnd(t, provider, "req-legacy-active", false, 0, InferenceResponseEnd{
		Type: "inference_response_end", RequestID: "req-legacy-active", Status: "complete",
	}))
	select {
	case end := <-first.Done:
		if end.Status != "complete" {
			t.Fatalf("first legacy end = %#v", end)
		}
	case <-time.After(time.Second):
		t.Fatal("first legacy inference did not complete")
	}
	select {
	case err := <-secondResult:
		if err != ErrRelayClosed {
			t.Fatalf("queued legacy dispatch after drain = %v, want ErrRelayClosed", err)
		}
	case <-time.After(time.Second):
		t.Fatal("legacy fail-closed rekey did not release queued dispatch")
	}
	if _, ok := s.storedSessionFor("p1", "s1"); ok {
		t.Fatal("legacy provider remained stored after old-epoch inference drained")
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
		AEADSuite:                      tier2.PillarBAEADA256GCM,
		ResponseChunkPlaintextEnvelope: true,
		InBandAEADRekeyV1:              true,
		C2PKey:                         bytes.Repeat([]byte{0x11}, 32),
		P2CKey:                         bytes.Repeat([]byte{0x22}, 32),
		C2PNonceBase:                   []byte{0x01, 0x02, 0x03, 0x04},
		P2CNonceBase:                   []byte{0x05, 0x06, 0x07, 0x08},
		KeyID:                          "test-kid",
		StartedAt:                      startedAt,
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
	session.onWriteFailure = s.handleProviderWriteFailure
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()
	return s, provider, providerConn
}

func encryptedResponseChunk(t *testing.T, provider *pool.Provider, requestID string, stream bool, seq uint64, plaintext []byte) []byte {
	t.Helper()
	return encryptedResponseChunkWithAppSeq(t, provider, requestID, stream, seq, int(seq), plaintext)
}

func encryptedResponseChunkWithAppSeq(t *testing.T, provider *pool.Provider, requestID string, stream bool, seq uint64, appSeq int, plaintext []byte) []byte {
	t.Helper()
	wrapped := mustJSON(encryptedInferenceChunkPlaintext{
		Type: "inference_response_chunk_plaintext",
		Seq:  appSeq,
		Data: string(plaintext),
	})
	return encryptedLegacyRawResponseChunk(t, provider, requestID, stream, seq, wrapped)
}

func encryptedLegacyRawResponseChunk(t *testing.T, provider *pool.Provider, requestID string, stream bool, seq uint64, plaintext []byte) []byte {
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

func settlementMetadataFixture() *SettlementReceiptMetadata {
	return &SettlementReceiptMetadata{
		AccountScope:               "acct_sha256:" + strings.Repeat("1", 64),
		RequestID:                  "req-settlement",
		AttemptN:                   0,
		ProviderID:                 "p1",
		ProviderReceiptKeyID:       "ed25519-sha256:" + strings.Repeat("2", 64),
		ModelID:                    "model-a",
		ExpectedCatalogModelHash:   strings.Repeat("3", 64),
		CatalogID:                  "catalog-a",
		CatalogBodyDigest:          strings.Repeat("4", 64),
		RouteSnapshotDigest:        strings.Repeat("5", 64),
		RouteSnapshotPolicyVersion: "spec022-prereq-v0",
		RouteSnapshotMode:          "observe",
		PromptHash:                 strings.Repeat("6", 64),
		OutputPrefixStartByte:      7,
		PendingDeadlineSeconds:     120,
	}
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
