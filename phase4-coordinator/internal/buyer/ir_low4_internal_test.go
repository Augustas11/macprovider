package buyer

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// Independent review LOW: a non-streaming buyer cancel never bills bytes the
// provider sent but the buyer never received, with or without a cancel
// terminal.
func TestForwardWSNonStreamingBuyerCancelBillsNoUndeliveredBytes(t *testing.T) {
	requestID := "req-ws-nonstream-cancel-bytes"
	chunks := make(chan providerws.InferenceResponseChunk, 1)
	chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0,
		Data: `{"id":"c","object":"chat.completion","choices":[{"message":{"role":"assistant","content":"a long answer the buyer never received"}}]}`}
	errs := make(chan error, 1)
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
		errs <- providerws.ErrRelayClosed
	}()
	relay := &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: make(chan providerws.InferenceResponseEnd), Errors: errs}
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(ctx)
	server := &Server{}
	result, attempt := server.forwardWSNonStreaming(httptest.NewRecorder(), req, requestID, pool.Provider{ProviderID: "provider-a"}, relay, nil, &forwardState{}, 0)
	if result != wsForwardCancelled {
		t.Fatalf("result=%q, want cancelled", result)
	}
	if attempt.EstimatedCompTokens != nil || attempt.CompletionTokens != nil {
		t.Fatalf("estimated=%v completion=%v, want nothing billed for undelivered bytes", attempt.EstimatedCompTokens, attempt.CompletionTokens)
	}
}
