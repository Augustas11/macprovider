package ws_test

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/providerevents"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
)

// preAckDispatch runs inside the handshake window, after registration and
// before the ack is enqueued. The session must be unroutable there, and an
// inference dispatched anyway must reach the wire only after the ack.
type preAckDispatch struct {
	h           *providerHarness
	ran         bool
	eligible    bool
	pending     bool
	dispatchErr error
	done        chan struct{}
}

func newPreAckDispatch() *preAckDispatch {
	return &preAckDispatch{done: make(chan struct{})}
}

func (d *preAckDispatch) hook() {
	defer close(d.done)
	provider, ok := d.h.Registry.Resolve("m4-anon", "")
	if !ok {
		return
	}
	d.ran = true
	d.eligible = provider.RoutingEligible()
	d.pending = provider.HandshakeAckPending
	stream, err := d.h.Provider.DispatchInference(context.Background(), provider, "req-pre-ack", []byte(`{"model":"m","messages":[]}`), false)
	d.dispatchErr = err
	if stream == nil && err == nil {
		d.dispatchErr = context.Canceled
	}
}

func (d *preAckDispatch) assertWindow(t *testing.T) {
	t.Helper()
	select {
	case <-d.done:
	case <-time.After(5 * time.Second):
		t.Fatal("pre-ack hook did not run")
	}
	if !d.ran {
		t.Fatal("pre-ack hook did not observe the registered session")
	}
	if d.eligible || !d.pending {
		t.Fatalf("pre-ack session routing_eligible=%v handshake_ack_pending=%v", d.eligible, d.pending)
	}
	if d.dispatchErr != nil {
		t.Fatalf("pre-ack dispatch: %v", d.dispatchErr)
	}
}

func assertRoutableAfterAck(t *testing.T, h providerHarness, assignedID string) {
	t.Helper()
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", assignedID)
		return ok && !provider.HandshakeAckPending && provider.RoutingEligible()
	})
}

func TestHelloAckPrecedesFramesDispatchedBeforeAck(t *testing.T) {
	d := newPreAckDispatch()
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithBeforeHandshakeAckSendForTest(func() { d.hook() }),
	})
	d.h = &h
	defer h.HTTP.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(validHello("m4-anon"))); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	if got := readFrameType(t, conn); got != "hello_ack" {
		t.Fatalf("first frame after hello = %q, want hello_ack", got)
	}
	if got := readFrameType(t, conn); got != "inference_request" {
		t.Fatalf("second frame after hello = %q, want the held inference_request", got)
	}
	d.assertWindow(t)
	provider, ok := h.Registry.Resolve("m4-anon", "")
	if !ok {
		t.Fatal("provider not registered")
	}
	assertRoutableAfterAck(t, h, provider.AssignedID)
}

func TestAuthResponseV2PrecedesFramesDispatchedBeforeAck(t *testing.T) {
	d := newPreAckDispatch()
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithBeforeHandshakeAckSendForTest(func() { d.hook() }),
	}, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	d.h = &h
	defer h.HTTP.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(validAuthInitialWithFreshKey(t, "m4-anon"))); err != nil {
		t.Fatalf("write auth initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	writeAuthProof(t, conn, challenge, "m4-anon", nil)
	if got := readFrameType(t, conn); got != "auth_response" {
		t.Fatalf("first frame after auth proof = %q, want auth_response", got)
	}
	if got := readFrameType(t, conn); got != "inference_request" {
		t.Fatalf("second frame after auth proof = %q, want the held inference_request", got)
	}
	d.assertWindow(t)
	assertRoutableAfterAck(t, h, challenge.AssignedID)
	if provider, _ := h.Registry.Resolve("m4-anon", challenge.AssignedID); provider.InferencePath != pool.InferencePathWSTunneled {
		t.Fatalf("inference path = %q", provider.InferencePath)
	}
}

// The last-known snapshot written at registration predates the ack, so it
// must not claim routability; the post-ack re-persist records it.
func TestLastKnownRoutabilityPersistsOnlyAfterHandshakeAck(t *testing.T) {
	// providerevents.Open sets busy_timeout, as production does; the bare
	// test store can lose the synchronous upsert to the async event writer.
	store, err := providerevents.Open(filepath.Join(t.TempDir(), "events.db"))
	if err != nil {
		t.Fatalf("open events store: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	window := make(chan bool, 1)
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithConnectionEventStore(store),
		providerws.WithBeforeHandshakeAckSendForTest(func() {
			snap, ok, err := store.GetLastKnown(context.Background(), "m4-anon")
			window <- err == nil && ok && !snap.RoutingEligible
		}),
	})
	defer h.HTTP.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assertHelloAck(t, conn)
	if !<-window {
		t.Fatal("pre-ack last-known snapshot missing or marked routable")
	}
	eventually(t, func() bool {
		snap, ok, err := store.GetLastKnown(context.Background(), "m4-anon")
		return err == nil && ok && snap.RoutingEligible
	})
}
