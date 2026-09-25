package buyer

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// tornWriter accepts the first write and then tears the next one in half,
// the way a buyer socket that closes mid-write does.
type tornWriter struct {
	*httptest.ResponseRecorder
	writes int
}

func (w *tornWriter) Write(p []byte) (int, error) {
	w.writes++
	if w.writes == 1 {
		return w.ResponseRecorder.Write(p)
	}
	half := len(p) / 2
	n, _ := w.ResponseRecorder.Write(p[:half])
	return n, errors.New("buyer connection reset")
}

// Audit R1 SECURITY M1: a torn buyer write must not count the unwritten part
// of the block as delivered output.
func TestForwardWSStreamingTornWriteBindsOnlyAcceptedEvents(t *testing.T) {
	requestID := "req-ws-torn-write"
	chunks := make(chan providerws.InferenceResponseChunk)
	go func() {
		chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0,
			Data: `data: {"choices":[{"delta":{"content":"Hello"}}]}` + "\n\n"}
		chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 1,
			Data: `data: {"choices":[{"delta":{"content":" world, and much more"}}]}` + "\n\n"}
	}()
	server := &Server{}
	relay := &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: make(chan providerws.InferenceResponseEnd), Errors: make(chan error, 1)}
	req := httptest.NewRequest("POST", "/v1/chat/completions", nil)
	w := &tornWriter{ResponseRecorder: httptest.NewRecorder()}

	result, attempt := server.forwardWSStreaming(w, req, requestID, pool.Provider{ProviderID: "provider-a", AssignedID: "session-a"}, relay, &forwardState{}, 0)
	if result != wsForwardCancelled {
		t.Fatalf("result=%q, want cancelled", result)
	}
	if attempt.SettlementOutput == nil || attempt.SettlementOutput.TerminalState != billing.TerminalStateBuyerCancel {
		t.Fatalf("settlement output=%+v, want buyer_cancel", attempt.SettlementOutput)
	}
	if got := attempt.SettlementOutput.Content; got != "Hello" {
		t.Fatalf("delivered content=%q, want only the fully written %q", got, "Hello")
	}
}

func bufferedCancelRelay(requestID string, terminal providerws.InferenceResponseEnd) *providerws.RelayStream {
	ch := make(chan providerws.InferenceResponseEnd, 1)
	ch <- terminal
	return &providerws.RelayStream{RequestID: requestID, Chunks: make(chan providerws.InferenceResponseChunk), Done: make(chan providerws.InferenceResponseEnd), Errors: make(chan error, 1), CancelTerminal: ch}
}

// Audit R1 CODE M2 / SECURITY M3: a buyer cancel on a buffered stream waits
// for the provider's buyer_cancel terminal and carries its receipt, binding
// the empty prefix the buyer received.
func TestForwardWSStreamingBufferedBuyerCancelCarriesCancelReceipt(t *testing.T) {
	requestID := "req-ws-buffered-cancel"
	relay := bufferedCancelRelay(requestID, providerws.InferenceResponseEnd{
		Type: "inference_response_end", RequestID: requestID, Status: "cancelled", Receipt: "tuple.signature",
	})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	req := httptest.NewRequest("POST", "/v1/chat/completions", nil).WithContext(ctx)
	server := &Server{}
	result, attempt := server.forwardWSStreamingBuffered(httptest.NewRecorder(), req, requestID, pool.Provider{ProviderID: "provider-a"}, relay, streamingModeBufferedKillSwitch, "buyer", &forwardState{}, 0)
	if result != wsForwardCancelled {
		t.Fatalf("result=%q, want cancelled", result)
	}
	if attempt.SettlementReceipt != "tuple.signature" {
		t.Fatalf("receipt=%q, want the provider's cancel receipt", attempt.SettlementReceipt)
	}
	if attempt.SettlementOutput == nil || attempt.SettlementOutput.TerminalState != billing.TerminalStateBuyerCancel ||
		attempt.SettlementOutput.OutputPrefixEndByte != 0 {
		t.Fatalf("settlement output=%+v, want an empty buyer_cancel prefix", attempt.SettlementOutput)
	}
}

// Audit R1 CODE M2: a provider "cancelled" end on a buffered stream is the
// provider's buyer_cancel, not a generic provider_error without its receipt.
func TestForwardWSStreamingBufferedCancelledEndCarriesReceipt(t *testing.T) {
	requestID := "req-ws-buffered-cancelled-end"
	done := make(chan providerws.InferenceResponseEnd, 1)
	done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "cancelled", Receipt: "tuple.signature"}
	relay := &providerws.RelayStream{RequestID: requestID, Chunks: make(chan providerws.InferenceResponseChunk), Done: done, Errors: make(chan error, 1)}
	req := httptest.NewRequest("POST", "/v1/chat/completions", nil)
	server := &Server{}
	_, attempt := server.forwardWSStreamingBuffered(httptest.NewRecorder(), req, requestID, pool.Provider{ProviderID: "provider-a"}, relay, streamingModeBufferedKillSwitch, "buyer", &forwardState{}, 0)
	if attempt.SettlementReceipt != "tuple.signature" {
		t.Fatalf("receipt=%q, want the provider's cancel receipt", attempt.SettlementReceipt)
	}
	if attempt.SettlementOutput == nil || attempt.SettlementOutput.TerminalState != billing.TerminalStateBuyerCancel {
		t.Fatalf("settlement output=%+v, want buyer_cancel", attempt.SettlementOutput)
	}
}

// failingWriter accepts nothing once the buffered stream is written.
type failingWriter struct {
	*httptest.ResponseRecorder
	accept int
}

func (w *failingWriter) Write(p []byte) (int, error) {
	n := w.accept
	if n > len(p) {
		n = len(p)
	}
	_, _ = w.ResponseRecorder.Write(p[:n])
	return n, errors.New("buyer connection reset")
}

// Audit R1 CODE M2 / SECURITY M1: a buffered stream whose final write tears
// records buyer_cancel over only the complete events the writer accepted.
func TestForwardWSStreamingBufferedTornFinalWriteBindsAcceptedEvents(t *testing.T) {
	requestID := "req-ws-buffered-torn"
	first := `data: {"choices":[{"delta":{"content":"Hello"}}]}` + "\n\n"
	chunks := make(chan providerws.InferenceResponseChunk, 2)
	chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: first}
	chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 1,
		Data: `data: {"choices":[{"delta":{"content":" world"},"finish_reason":"stop"}]}` + "\n\n" + "data: [DONE]\n\n"}
	close(chunks)
	done := make(chan providerws.InferenceResponseEnd, 1)
	relay := &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: make(chan error, 1)}
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
}

var _ http.ResponseWriter = (*tornWriter)(nil)
