package buyer

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

// Audit R2 CODE HIGH / ARCH M: on the direct HTTP SSE path a torn buyer write
// of a usage-bearing event must neither record that event as delivered nor
// bill the provider usage it carried.
func TestForwardStreamingHTTPTornUsageWriteBillsOnlyDelivered(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("data: {\"id\":\"c\",\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n"))
		w.(http.Flusher).Flush()
		time.Sleep(20 * time.Millisecond)
		_, _ = w.Write([]byte("data: {\"id\":\"c\",\"choices\":[{\"delta\":{\"content\":\" and a great deal more\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":400,\"total_tokens\":405}}\n\n"))
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer upstream.Close()

	server := NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Now())
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{}`))
	body := []byte(`{"model":"llama","stream":true,"messages":[{"role":"user","content":"hi"}]}`)
	provider := pool.Provider{ProviderID: "provider-1", AssignedID: "route-1", EndpointURL: upstream.URL}
	w := &tornWriter{ResponseRecorder: httptest.NewRecorder()}

	result, _, attempt := server.forwardStreaming(w, req, "req-1", body, provider, "llama", time.Second, nil, &forwardState{}, 0)
	if result != wsForwardCancelled {
		t.Fatalf("result=%q, want cancelled", result)
	}
	if attempt.CompletionTokens != nil || attempt.PromptTokens != nil {
		t.Fatalf("usage prompt=%v completion=%v, want none: the usage event never reached the buyer", attempt.PromptTokens, attempt.CompletionTokens)
	}
	out := attempt.SettlementOutput
	if out == nil || out.TerminalState != billing.TerminalStateBuyerCancel || out.Content != "Hello" {
		t.Fatalf("settlement output=%+v, want buyer_cancel over the delivered %q", out, "Hello")
	}
}

// Audit R2 CODE M: CRLF-framed events count toward a torn prefix exactly as
// LF-framed ones do.
func TestObserveCompleteEventsCountsCRLFFramedEvents(t *testing.T) {
	first := "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\r\n\r\n"
	second := "data: {\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\r\n\r\n"
	for name, tc := range map[string]struct {
		prefix string
		want   string
	}{
		"one complete CRLF event":          {first, "Hello"},
		"torn second CRLF event":           {first + second[:len(second)-3], "Hello"},
		"two complete CRLF events":         {first + second, "Hello world"},
		"data line without its terminator": {first[:len(first)-2], ""},
		"LF framing still counted":         {strings.ReplaceAll(first, "\r\n", "\n"), "Hello"},
	} {
		t.Run(name, func(t *testing.T) {
			tracker := newSettlementStreamOutputTracker()
			tracker.observeCompleteEvents([]byte(tc.prefix))
			if got := tracker.output(billing.TerminalStateBuyerCancel).Content; got != tc.want {
				t.Fatalf("delivered content=%q, want %q", got, tc.want)
			}
		})
	}
}
