package buyer

import (
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestContextOverflowPreservesOnlyCapacity(t *testing.T) {
	for _, message := range []string{
		"Prompt length (9000 tokens) exceeds this provider's safe capacity (8192 tokens).",
		"Prompt length (9000 tokens) plus max_tokens (100) exceeds this provider's context window (8192 tokens).",
	} {
		w := httptest.NewRecorder()
		writeWSEndError(w, providerws.InferenceResponseEnd{Status: "error_context_exceeded", Error: message})
		if !strings.Contains(w.Body.String(), "maximum context length is 8192 tokens") {
			t.Fatalf("body=%s", w.Body.String())
		}
	}
}

func TestContextOverflowRejectsUntrustedCapacityText(t *testing.T) {
	for _, message := range []string{
		"secret Prompt length (9000 tokens) exceeds this provider's safe capacity (8192 tokens).",
		"Prompt length (9000 tokens) exceeds this provider's safe capacity (8192 tokens). secret",
		"Prompt length (9000 tokens) exceeds this provider's safe capacity (9223372036854775808 tokens).",
		"Prompt length (9000 tokens) exceeds this provider's safe capacity (0 tokens).",
	} {
		if got := contextOverflowMessage(message); got != "Request exceeds provider context capacity" {
			t.Fatalf("untrusted capacity accepted: %s", got)
		}
	}
}

func TestContextOverflowStreamAndPinnedCapacity(t *testing.T) {
	const detail = "Prompt length (9000 tokens) exceeds this provider's safe capacity (8192 tokens)."
	w := httptest.NewRecorder()
	writeStreamForwardError(w, wsForwardContextExceeded, requestLogEndErrorMessage(providerws.InferenceResponseEnd{Status: "error_context_exceeded", Error: detail}))
	if !strings.Contains(w.Body.String(), "maximum context length is 8192 tokens") {
		t.Fatal(w.Body.String())
	}
	stream := httptest.NewRecorder()
	writeSSEContextOverflow(stream, detail)
	if !strings.Contains(stream.Body.String(), `"code":"context_length_exceeded"`) || !strings.Contains(stream.Body.String(), "maximum context length is 8192 tokens") {
		t.Fatal(stream.Body.String())
	}
	_, routeErr := validatePinnedProvider(pool.Provider{ModelID: "llama", MaxContextTokens: 4096}, "llama", 5000, "unavailable")
	if routeErr == nil || !strings.Contains(routeErr.message, "maximum context length is 4096 tokens") {
		t.Fatalf("route=%+v", routeErr)
	}
}

func TestContextRejectedCapacityUsesLargestRefusedWindow(t *testing.T) {
	checker := &eligibilityCtx{estimatedTokens: 9000}
	for _, capacity := range []int{4096, 8192, 2048} {
		if checker.ProviderContextSufficient(pool.Provider{MaxContextTokens: capacity}) {
			t.Fatalf("window %d accepted", capacity)
		}
	}
	if !checker.ProviderContextSufficient(pool.Provider{MaxContextTokens: 131072}) {
		t.Fatal("sufficient window rejected")
	}
	if checker.contextRejectedCapacity != 8192 {
		t.Fatalf("capacity=%d want 8192", checker.contextRejectedCapacity)
	}
	otherRequest := &eligibilityCtx{estimatedTokens: 9000}
	if otherRequest.contextRejectedCapacity != 0 {
		t.Fatal("capacity leaked across requests")
	}
}
