package buyer

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// SPEC-001-R015 / SPEC-006-R026: provider decode progress reaches a gateway
// that opted in as one comment line between whole events, at most once per
// second, and is never part of the delivered output or its settlement.
func TestForwardWSStreamingWritesDecodeProgressOnlyWhenNegotiated(t *testing.T) {
	bodies := map[bool]string{}
	for _, negotiated := range []bool{true, false} {
		t.Run(map[bool]string{true: "negotiated", false: "not_negotiated"}[negotiated], func(t *testing.T) {
			requestID := "req-ws-progress"
			chunks := make(chan providerws.InferenceResponseChunk)
			done := make(chan providerws.InferenceResponseEnd, 1)
			progress := make(chan struct{})
			go func() {
				chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: r3Delivered}
				// A burst within one second yields one line.
				progress <- struct{}{}
				progress <- struct{}{}
				progress <- struct{}{}
				chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 1, Data: r3Terminated}
				chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 2, Data: r3DoneEvent}
				close(chunks)
				done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 3}
			}()
			relay := &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: make(chan error, 1), Progress: progress}
			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
			if negotiated {
				req.Header.Set(decodeProgressCapabilityHeader, "1")
			} else {
				// An unread progress channel must never block the stream.
				go func() {
					for range progress {
					}
				}()
			}
			rec := httptest.NewRecorder()
			_, attempt := (&Server{}).forwardWSStreaming(rec, req, requestID, pool.Provider{ProviderID: "provider-a"}, relay, &forwardState{}, 0)
			body := rec.Body.String()
			lines := strings.Count(body, decodeProgressSSEComment)
			if negotiated {
				if lines != 1 {
					t.Fatalf("progress lines=%d, want exactly 1 for a sub-second burst; body=%q", lines, body)
				}
				if !strings.Contains(body, r3Delivered+decodeProgressSSEComment+"data: ") {
					t.Fatalf("progress must sit between whole events; body=%q", body)
				}
			} else if lines != 0 {
				t.Fatalf("progress written without the capability header; body=%q", body)
			}
			bodies[negotiated] = strings.ReplaceAll(body, decodeProgressSSEComment, "")
			if out := attempt.SettlementOutput; out == nil || out.Content != r3FullContent {
				t.Fatalf("settlement output=%+v, want %q", out, r3FullContent)
			}
		})
	}
	if bodies[true] == "" || bodies[true] != bodies[false] {
		t.Fatalf("event bytes differ with progress:\n%q\n%q", bodies[true], bodies[false])
	}
}
