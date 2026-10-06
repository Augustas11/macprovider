package buyer

import (
	"context"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// boundaryRecorder captures the delivered_output_bytes every cancel would
// send, and answers the first buyer_disconnected cancel with a terminal.
type boundaryRecorder struct {
	mu       sync.Mutex
	sealed   []*int64
	terminal chan providerws.InferenceResponseEnd
}

func (b *boundaryRecorder) onCancel(requestID string) func(string, *int64) {
	return func(reason string, deliveredOutputBytes *int64) {
		if reason != "buyer_disconnected" {
			return
		}
		b.mu.Lock()
		defer b.mu.Unlock()
		b.sealed = append(b.sealed, deliveredOutputBytes)
		if deliveredOutputBytes != nil {
			select {
			case b.terminal <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "cancelled"}:
			default:
			}
		}
	}
}

// boundary is the one boundary a cancel_request carried.
func (b *boundaryRecorder) boundary(t *testing.T) int64 {
	t.Helper()
	b.mu.Lock()
	defer b.mu.Unlock()
	var got []int64
	for _, n := range b.sealed {
		if n != nil {
			got = append(got, *n)
		}
	}
	if len(got) != 1 {
		t.Fatalf("sent boundaries=%v, want exactly one", got)
	}
	return got[0]
}

// Audit round 1 (#1690 BUG-2): a buffered stream whose final write tears
// records the accepted events before relay.Cancel seals, so the boundary the
// provider signs equals the buyer_cancel prefix the coordinator records.
func TestForwardWSStreamingBufferedTornWriteSealsTheAcceptedPrefix(t *testing.T) {
	requestID := "req-ws-buffered-torn-boundary"
	first := `data: {"choices":[{"delta":{"content":"Hello"}}]}` + "\n\n"
	chunks := make(chan providerws.InferenceResponseChunk, 2)
	chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: first}
	chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 1,
		Data: `data: {"choices":[{"delta":{"content":" world"},"finish_reason":"stop"}]}` + "\n\n" + "data: [DONE]\n\n"}
	close(chunks)
	done := make(chan providerws.InferenceResponseEnd, 1)
	rec := &boundaryRecorder{terminal: make(chan providerws.InferenceResponseEnd, 1)}
	relay := providerws.NewRelayStreamForTest(providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: make(chan error, 1)}, rec.onCancel(requestID))
	go func() {
		time.Sleep(50 * time.Millisecond)
		done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 2}
	}()
	req := httptest.NewRequest("POST", "/v1/chat/completions", nil)
	w := &failingWriter{ResponseRecorder: httptest.NewRecorder(), accept: len(first) + 10}
	server := &Server{}
	result, attempt := server.forwardWSStreamingBuffered(w, req, requestID, pool.Provider{ProviderID: "provider-a"}, relay, streamingModeBufferedKillSwitch, "buyer", &forwardState{}, 0)
	if result != wsForwardCancelled {
		t.Fatalf("result=%q, want cancelled", result)
	}
	out := attempt.SettlementOutput
	if out == nil || out.TerminalState != billing.TerminalStateBuyerCancel || out.Content != "Hello" {
		t.Fatalf("settlement output=%+v, want buyer_cancel over the accepted %q", out, "Hello")
	}
	if got := rec.boundary(t); got != billing.SettlementDeliveredOutputBytes(out.Content) {
		t.Fatalf("sealed boundary=%d, want the recorded prefix's %d bytes", got, billing.SettlementDeliveredOutputBytes(out.Content))
	}
}

// cancelDuringWrite accepts every write; during the second one the buyer
// goes away and the relay's cancel races the write.
type cancelDuringWrite struct {
	*httptest.ResponseRecorder
	writes int
	race   func()
}

func (w *cancelDuringWrite) Write(p []byte) (int, error) {
	w.writes++
	if w.writes == 2 {
		started := make(chan struct{})
		go func() {
			close(started)
			w.race()
		}()
		<-started
		time.Sleep(20 * time.Millisecond)
	}
	return w.ResponseRecorder.Write(p)
}

// Audit round 1 (#1690 BUG-2): a cancel that fires while an incremental write
// is in flight seals only after the bytes that write accepted are recorded,
// so delivered output reaching the buyer is never dropped from the boundary
// and the boundary equals the recorded prefix.
func TestForwardWSStreamingCancelDuringWriteSealsAfterAcceptedBytes(t *testing.T) {
	requestID := "req-ws-write-window"
	chunks := make(chan providerws.InferenceResponseChunk, 2)
	chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0,
		Data: `data: {"choices":[{"delta":{"content":"Hello"}}]}` + "\n\n"}
	chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 1,
		Data: `data: {"choices":[{"delta":{"content":" world"}}]}` + "\n\n"}
	rec := &boundaryRecorder{terminal: make(chan providerws.InferenceResponseEnd, 1)}
	relay := providerws.NewRelayStreamForTest(providerws.RelayStream{
		RequestID: requestID, Chunks: chunks, Done: make(chan providerws.InferenceResponseEnd), Errors: make(chan error, 1), CancelTerminal: rec.terminal,
	}, rec.onCancel(requestID))
	ctx, buyerGone := context.WithCancel(context.Background())
	defer buyerGone()
	w := &cancelDuringWrite{ResponseRecorder: httptest.NewRecorder(), race: func() {
		relay.Cancel("buyer_disconnected")
		buyerGone()
	}}
	req := httptest.NewRequest("POST", "/v1/chat/completions", nil).WithContext(ctx)
	server := &Server{}
	result, attempt := server.forwardWSStreaming(w, req, requestID, pool.Provider{ProviderID: "provider-a", AssignedID: "session-a"}, relay, &forwardState{}, 0)
	if result != wsForwardCancelled {
		t.Fatalf("result=%q, want cancelled", result)
	}
	out := attempt.SettlementOutput
	if out == nil || out.TerminalState != billing.TerminalStateBuyerCancel || out.Content != "Hello world" {
		t.Fatalf("settlement output=%+v, want buyer_cancel over both written events", out)
	}
	if got := rec.boundary(t); got != int64(len("Hello world")) {
		t.Fatalf("sealed boundary=%d, want %d: the write in flight was accepted", got, len("Hello world"))
	}
}
