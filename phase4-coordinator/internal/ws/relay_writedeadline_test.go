package ws

import (
	"net"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
)

// TestProviderControlPongSurvivesStaleWriteDeadline is a regression test for the
// idle-provider disconnect bug.
//
// runWriter (relay.go) sets an absolute write deadline only at the top of each
// writeCh send, and socket write deadlines are never cleared after a successful
// write. Once a provider goes idle (no server-initiated writes), that deadline
// silently lapses. The next keepalive PING the provider sends drives gobwas's
// HandlePing to write a PONG reply synchronously from the read goroutine
// (readClientData) directly to the conn — inheriting the stale, already-expired
// deadline. Pre-fix, that PONG write fails instantly with `i/o timeout`, which
// readProviderLoop surfaces as a read failure and tears the session down,
// disconnecting an otherwise healthy provider.
//
// The fix routes reactive control replies through deadlineRefreshingWriter so
// every PONG/Close write re-arms the deadline first. This test lets the writer's
// deadline lapse with no server-initiated write, then sends a client PING and
// asserts the session survives (PONG returns, no read-loop teardown).
func TestProviderControlPongSurvivesStaleWriteDeadline(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer serverConn.Close()
	defer providerConn.Close()

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

	// Short writer deadline so a single real server send leaves behind a deadline
	// that lapses within the test rather than after the 10s default WriteTimeoutS.
	// The fix's refresh still uses config WriteTimeoutS (10s), so re-armed writes
	// have ample headroom.
	const writeLimit = 50 * time.Millisecond
	session := newProviderSession("p1", "s1", serverConn, 8, writeLimit)
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()

	done := make(chan struct{})
	go func() {
		s.readProviderLoop(serverConn, "p1", "s1")
		close(done)
	}()

	// 1) Drive a real server-initiated write through runWriter. This is the only
	//    place the provider conn's write deadline is set, exactly as in prod.
	if err := session.send([]byte("warmup")); err != nil {
		t.Fatalf("seed server write: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read seeded server frame: %v", err)
	}

	// 2) Let the write deadline lapse with no further server-initiated write —
	//    the idle gap an unused provider sits in between keepalives.
	time.Sleep(4 * writeLimit)

	// 3) A keepalive PING now would, pre-fix, make the reactive PONG inherit the
	//    expired deadline and fail. Post-fix the deadline is re-armed, the client
	//    receives the PONG, and the read loop keeps running.
	assertKeepalivePingPong(t, providerConn, "after-deadline-lapse")

	// 4) Re-arm the stale deadline directly and confirm repeated idle keepalives
	//    keep surviving — i.e. no read-loop teardown across successive cycles.
	for i := 0; i < 2; i++ {
		if err := serverConn.SetWriteDeadline(time.Now().Add(-time.Hour)); err != nil {
			t.Fatalf("re-arm stale write deadline: %v", err)
		}
		assertKeepalivePingPong(t, providerConn, "re-armed-stale-deadline")
	}

	// Clean shutdown: closing the client end ends the server read loop.
	_ = providerConn.Close()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("readProviderLoop did not exit after client close")
	}
}

// assertKeepalivePingPong sends a client keepalive PING and asserts a PONG comes
// back within a short deadline, proving the reactive control write succeeded and
// the provider read loop did not tear the session down.
func assertKeepalivePingPong(t *testing.T, clientConn net.Conn, label string) {
	t.Helper()
	if err := wsutil.WriteClientMessage(clientConn, gobwas.OpPing, []byte("keepalive")); err != nil {
		t.Fatalf("%s: write client ping: %v", label, err)
	}
	if err := clientConn.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatalf("%s: set client read deadline: %v", label, err)
	}
	frame, err := gobwas.ReadFrame(clientConn)
	if err != nil {
		t.Fatalf("%s: expected PONG, got read error (session torn down by stale write deadline?): %v", label, err)
	}
	if frame.Header.OpCode != gobwas.OpPong {
		t.Fatalf("%s: frame opcode = %v, want PONG", label, frame.Header.OpCode)
	}
	_ = clientConn.SetReadDeadline(time.Time{})
}
