package ws

import (
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
)

// TestProviderWriterSerializesUnderConcurrentControlAndDataFrames is a
// concurrency regression test for the framing-corruption hazard described in
// the Option-2 writer-ownership fix.
//
// Pre-fix: runWriter (the intended sole coordinator→provider writer) and the
// readProviderLoop goroutine (via gobwas's ControlHandler.HandlePing/HandleClose)
// both wrote WS frames directly to the same provider conn. Each wsutil-level
// frame write issues TWO underlying conn.Write calls (header, then payload). A
// PONG reply from the read goroutine arriving between the header and payload of
// an in-flight inference_request from runWriter would land its OWN header+
// payload on the wire mid-frame, corrupting the WS framing for both. The Go race
// detector cannot see this because net.TCPConn.Write is internally locked; the
// hazard lives one layer up at the WS framing boundary.
//
// Post-fix: every coordinator→provider write (text payloads, reactive control
// replies, server-initiated Close frames) is enqueued on session.writeCh and
// emitted by the single runWriter goroutine via one conn.Write per frame.
//
// This test drives a large number of concurrent text frames from the
// "coordinator" side AND a large number of inbound client PING frames whose
// reactive PONG replies must traverse the read-loop control-handler path. Every
// frame that lands on the wire is parsed with gobwas.ReadFrame. ANY framing
// corruption (header parsed from payload bytes, wrong declared length, garbage
// opcode) surfaces as a ReadFrame error and fails the test.
//
// Additional invariants asserted:
//   - All expected text frames arrive in their original send order (runWriter
//     preserves writeCh order).
//   - Every PING payload is echoed back exactly once in a PONG (no losses, no
//     duplicates).
//   - Total frame count on the wire matches expected text + ping counts.
//
// Must pass under `go test -race`.
func TestProviderWriterSerializesUnderConcurrentControlAndDataFrames(t *testing.T) {
	serverConn, clientConn := net.Pipe()
	t.Cleanup(func() {
		_ = serverConn.Close()
		_ = clientConn.Close()
	})

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

	// Large buffer + generous write limit so backpressure on writeCh stays
	// improbable under the load below; under net.Pipe's synchronous handoff,
	// runWriter drains as fast as the test's reader pulls.
	session := newProviderSession("p1", "s1", serverConn, 1024, 5*time.Second)
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()

	readLoopDone := make(chan struct{})
	go func() {
		s.readProviderLoop(serverConn, "p1", "s1")
		close(readLoopDone)
	}()

	const (
		textFrames = 200
		pingFrames = 200
	)

	// Distinct payloads so we can match received PONGs back to PINGs and
	// received TEXTs back to their send order without ambiguity. Padding the
	// text payload makes each WS frame multi-byte so the framing-interleave
	// window from the pre-fix bug is wide enough that ReadFrame would fail
	// fast if it ever returned.
	expectedText := make([]string, textFrames)
	for i := range expectedText {
		expectedText[i] = fmt.Sprintf(`{"type":"inference_request","seq":%d,"body":"%s"}`, i, strings.Repeat("x", 64))
	}
	expectedPing := make([][]byte, pingFrames)
	for i := range expectedPing {
		expectedPing[i] = []byte(fmt.Sprintf("ping-%04d", i))
	}

	var sendersWG sync.WaitGroup
	sendersWG.Add(2)

	// Text producer: pushes coordinator→provider text frames through
	// session.send (the runWriter-owned path). Retries on backpressure rather
	// than failing so the throughput is bounded only by net.Pipe.
	go func() {
		defer sendersWG.Done()
		for _, payload := range expectedText {
			for {
				err := session.send([]byte(payload))
				if err == nil {
					break
				}
				if errors.Is(err, ErrRelayClosed) {
					return
				}
				// ErrRelayBackpressure: writeCh full; spin briefly and retry.
				time.Sleep(50 * time.Microsecond)
			}
		}
	}()

	// Client PING producer: drives inbound control frames whose reactive PONG
	// replies must, post-fix, traverse session.enqueueRaw (NOT a direct
	// conn.Write from the read goroutine). Pre-fix, this is precisely the
	// goroutine whose direct PONG writes raced runWriter mid-text-frame.
	go func() {
		defer sendersWG.Done()
		for _, p := range expectedPing {
			if err := wsutil.WriteClientMessage(clientConn, gobwas.OpPing, p); err != nil {
				return
			}
		}
	}()

	receivedText := make([]string, 0, textFrames)
	pongCounts := make(map[string]int, pingFrames)
	totalDeadline := time.Now().Add(30 * time.Second)

	for len(receivedText)+sumValues(pongCounts) < textFrames+pingFrames {
		if err := clientConn.SetReadDeadline(totalDeadline); err != nil {
			t.Fatalf("set read deadline: %v", err)
		}
		frame, err := gobwas.ReadFrame(clientConn)
		if err != nil {
			t.Fatalf("ReadFrame failed at sawText=%d sawPong=%d (out of want text=%d ping=%d): %v "+
				"— this is the framing-corruption signal the writer-ownership fix is meant to prevent",
				len(receivedText), sumValues(pongCounts), textFrames, pingFrames, err)
		}
		switch frame.Header.OpCode {
		case gobwas.OpText:
			receivedText = append(receivedText, string(frame.Payload))
		case gobwas.OpPong:
			pongCounts[string(frame.Payload)]++
		default:
			t.Fatalf("unexpected opcode %v at sawText=%d sawPong=%d", frame.Header.OpCode, len(receivedText), sumValues(pongCounts))
		}
	}

	sendersWG.Wait()

	if got := len(receivedText); got != textFrames {
		t.Fatalf("text frame count: got %d, want %d", got, textFrames)
	}
	if got := sumValues(pongCounts); got != pingFrames {
		t.Fatalf("pong frame count: got %d, want %d", got, pingFrames)
	}
	// Order invariant: runWriter is the single writer, so writeCh order is
	// preserved on the wire. A regression that introduced multiple writers
	// would generally also break ordering.
	for i, want := range expectedText {
		if got := receivedText[i]; got != want {
			t.Fatalf("text frame %d out of order: got %q, want %q", i, got, want)
		}
	}
	// Echo invariant: each PING payload echoed exactly once as a PONG. Lost or
	// duplicated PONG payloads indicate frame-boundary slop.
	for _, p := range expectedPing {
		if n := pongCounts[string(p)]; n != 1 {
			t.Fatalf("PONG echo for %q: got %d times, want 1", string(p), n)
		}
	}

	// Clean shutdown: closing the client end ends the server read loop.
	_ = clientConn.Close()
	select {
	case <-readLoopDone:
	case <-time.After(2 * time.Second):
		t.Fatal("readProviderLoop did not exit after client close")
	}
}

func sumValues(m map[string]int) int {
	total := 0
	for _, v := range m {
		total += v
	}
	return total
}
