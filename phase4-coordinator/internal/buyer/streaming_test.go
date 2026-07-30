package buyer

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

const streamingTestCompleteToolCall = "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_0123456789abcdef\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{}\"}}]}}]}\n\n" +
	"data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" +
	"data: [DONE]\n\n"

func TestStreamingModeHeaderAdversarialBuyerDoesNotDowngradeOtherBuyer(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte(streamingTestCompleteToolCall))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "provider-x", EndpointURL: upstream.URL}})
	registerStreamingTestProvider(registry, "provider-x", "session-1", "model-a", upstream.URL)
	server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	for i := 0; i < 3; i++ {
		server.streamingDowngrade.recordMalformed("ip:198.51.100.10", "provider-x", server.now().Add(time.Duration(i)*time.Minute))
	}

	rrA := postStreamingTestChat(t, server, "198.51.100.10:12345")
	if rrA.Code != http.StatusOK {
		t.Fatalf("buyer-a status = %d body=%s", rrA.Code, rrA.Body.String())
	}
	if got := rrA.Header().Get(streamingModeHeader); got != streamingModeBufferedProviderDowngrade {
		t.Fatalf("buyer-a streaming mode = %q, want %q", got, streamingModeBufferedProviderDowngrade)
	}

	rrB := postStreamingTestChat(t, server, "198.51.100.11:12345")
	if rrB.Code != http.StatusOK {
		t.Fatalf("buyer-b status = %d body=%s", rrB.Code, rrB.Body.String())
	}
	if got := rrB.Header().Get(streamingModeHeader); got != streamingModeIncremental {
		t.Fatalf("buyer-b streaming mode = %q, want %q", got, streamingModeIncremental)
	}
	if !strings.Contains(rrB.Body.String(), "tool_calls") {
		t.Fatalf("buyer-b response was not streamed tool-call data: %s", rrB.Body.String())
	}
}

func TestStreamingIncrementalOpenAcceptsArgumentFragments(t *testing.T) {
	line := streamingToolDelta(0, "call_0123456789abcdef", "lookup", `{"city":`)
	if !isCommitWorthyDataLine([]byte(line)) {
		t.Fatal("incremental-open validator rejected a valid first tool-call delta")
	}

	validator := newStreamToolCallFinalValidator()
	if err := validator.observeLine([]byte(line)); err != nil {
		t.Fatalf("observeLine opening: %v", err)
	}
	if err := validator.observeLine([]byte(streamingToolDeltaFragment(0, `"Vilnius"}`))); err != nil {
		t.Fatalf("observeLine fragment: %v", err)
	}
	_ = validator.observeLine([]byte(`data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}` + "\n"))
	_ = validator.observeLine([]byte("data: [DONE]\n"))
	if !validator.finalCloseOK() {
		t.Fatal("final-close validator rejected a complete fragmented tool-call stream")
	}
}

func TestFinalCloseRequiresFinishReasonAndTransportDone(t *testing.T) {
	for _, tc := range []struct {
		name       string
		finish     bool
		done       bool
		wantClosed bool
	}{
		{"missing_finish_reason", false, true, false},
		{"missing_done", true, false, false},
		{"complete", true, true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			validator := newStreamToolCallFinalValidator()
			if err := validator.observeLine([]byte(streamingToolDelta(0, "call_0123456789abcdef", "lookup", `{"ok":true}`))); err != nil {
				t.Fatalf("observeLine opening: %v", err)
			}
			if tc.finish {
				_ = validator.observeLine([]byte(`data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}` + "\n"))
			}
			if tc.done {
				_ = validator.observeLine([]byte("data: [DONE]\n"))
			}
			if validator.finalCloseOK() != tc.wantClosed {
				t.Fatalf("finalCloseOK = %v, want %v", validator.finalCloseOK(), tc.wantClosed)
			}
		})
	}
}

func TestFinalCloseNoWithdrawalRejectsContentAfterToolOpen(t *testing.T) {
	validator := newStreamToolCallFinalValidator()
	if err := validator.observeLine([]byte(streamingToolDelta(0, "call_0123456789abcdef", "lookup", `{"ok":`))); err != nil {
		t.Fatalf("observeLine opening: %v", err)
	}
	if err := validator.observeLine([]byte(`data: {"choices":[{"delta":{"content":"fallback"}}]}` + "\n")); err == nil {
		t.Fatal("content fallback after tool-call open must be rejected")
	}
}

func TestByteCapInclusiveBoundaryAndAggregateStreaming(t *testing.T) {
	t.Run("per_call_inclusive", func(t *testing.T) {
		arguments := `{"blob":"` + strings.Repeat("x", maxToolCallArgumentsBytes-len(`{"blob":""}`)) + `"}`
		if len(arguments) != maxToolCallArgumentsBytes {
			t.Fatalf("fixture argument length = %d, want %d", len(arguments), maxToolCallArgumentsBytes)
		}
		validator := newStreamToolCallFinalValidator()
		if err := validator.observeLine([]byte(streamingToolDelta(0, "call_0123456789abcdef", "lookup", arguments))); err != nil {
			t.Fatalf("inclusive cap observeLine: %v", err)
		}
		_ = validator.observeLine([]byte(`data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}` + "\n"))
		_ = validator.observeLine([]byte("data: [DONE]\n"))
		if !validator.finalCloseOK() {
			t.Fatal("inclusive per-call cap should pass final-close")
		}
	})

	t.Run("per_call_crossing", func(t *testing.T) {
		arguments := `{"blob":"` + strings.Repeat("x", maxToolCallArgumentsBytes-len(`{"blob":""}`)+1) + `"}`
		validator := newStreamToolCallFinalValidator()
		if err := validator.observeLine([]byte(streamingToolDelta(0, "call_0123456789abcdef", "lookup", arguments))); err == nil {
			t.Fatal("per-call cap crossing must fail")
		}
	})

	t.Run("aggregate_crossing", func(t *testing.T) {
		validator := newStreamToolCallFinalValidator()
		part := strings.Repeat("x", 700*1024)
		for index, id := range []string{"call_0123456789abcdef", "call_abcdefabcdefabcd", "call_0011223344556677"} {
			if err := validator.observeLine([]byte(streamingToolDelta(index, id, "lookup", `{"blob":"`+part+`"}`))); err != nil {
				if index < 2 {
					t.Fatalf("unexpected early aggregate error at index %d: %v", index, err)
				}
				return
			}
		}
		t.Fatal("aggregate cap crossing must fail")
	})
}

func TestAutoDowngradeIsScopedPerBuyerProvider(t *testing.T) {
	store := newStreamingDowngradeStore()
	now := time.Unix(1716768000, 0)
	for i := 0; i < 3; i++ {
		store.recordMalformed("buyer-a", "provider-x", now.Add(time.Duration(i)*time.Minute))
	}

	if !store.isDowngraded("buyer-a", "provider-x", now.Add(3*time.Minute)) {
		t.Fatal("buyer-a/provider-x should be downgraded after three malformed streams")
	}
	if store.isDowngraded("buyer-b", "provider-x", now.Add(3*time.Minute)) {
		t.Fatal("buyer-b/provider-x must not inherit buyer-a downgrade")
	}
	if store.isDowngraded("buyer-a", "provider-y", now.Add(3*time.Minute)) {
		t.Fatal("buyer-a/provider-y must not inherit provider-x downgrade")
	}
	store.recordClean("buyer-a", "provider-x", now.Add(13*time.Minute))
	if store.isDowngraded("buyer-a", "provider-x", now.Add(13*time.Minute)) {
		t.Fatal("clean recovery window should lift the tuple downgrade")
	}
}

func TestStreamingDowngradeStoreBoundsEntries(t *testing.T) {
	store := newStreamingDowngradeStoreWithLimit(3)
	now := time.Unix(1716768000, 0)
	for i := 0; i < 5; i++ {
		store.recordMalformed("buyer-"+strconv.Itoa(i), "provider-x", now)
	}
	if got := store.sizeForTest(); got != 3 {
		t.Fatalf("downgrade entries=%d want 3", got)
	}
	if got := store.evictionsForTest(); got != 2 {
		t.Fatalf("downgrade evictions=%d want 2", got)
	}
	if store.isDowngraded("buyer-0", "provider-x", now) {
		t.Fatal("oldest buyer should have been evicted")
	}
}

func TestStreamingDowngradeStoreRemovesExpiredKeysFromOrder(t *testing.T) {
	store := newStreamingDowngradeStoreWithLimit(100)
	now := time.Unix(1716768000, 0)
	for i := 0; i < 5; i++ {
		buyerID := "buyer-expire-" + strconv.Itoa(i)
		store.recordMalformed(buyerID, "provider-x", now)
		if store.isDowngraded(buyerID, "provider-x", now.Add(6*time.Minute)) {
			t.Fatalf("%s should not be downgraded after one malformed stream", buyerID)
		}
	}
	if got := store.sizeForTest(); got != 0 {
		t.Fatalf("downgrade entries=%d want 0 after expiry pruning", got)
	}
	if got := store.orderSizeForTest(); got != 0 {
		t.Fatalf("downgrade order entries=%d want 0 after expiry pruning", got)
	}
}

func streamingToolDelta(index int, id, name, arguments string) string {
	return `data: {"choices":[{"delta":{"tool_calls":[{"index":` + itoa(index) + `,"id":"` + id + `","type":"function","function":{"name":"` + name + `","arguments":` + string(mustJSONStringForStreaming(arguments)) + `}}]}}]}` + "\n"
}

func streamingToolDeltaFragment(index int, arguments string) string {
	return `data: {"choices":[{"delta":{"tool_calls":[{"index":` + itoa(index) + `,"function":{"arguments":` + string(mustJSONStringForStreaming(arguments)) + `}}]}}]}` + "\n"
}

func mustJSONStringForStreaming(value string) []byte {
	raw, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return raw
}

func registerStreamingTestProvider(registry *pool.Registry, providerID, assignedID, modelID, endpointURL string) {
	registry.Register(&pool.Provider{
		ProviderID:            providerID,
		AssignedID:            assignedID,
		Hostname:              providerID + ".local",
		ModelID:               modelID,
		ModelParamsB:          7,
		RAMGB:                 16,
		MaxContextTokens:      20000,
		MaxConcurrency:        1,
		SlotsFree:             1,
		SlotsTotal:            1,
		ThroughputTPSEstimate: 20,
		EndpointURL:           endpointURL,
		Tier:                  pool.TierPinned,
		InferencePath:         pool.InferencePathHTTPForwarding,
		State:                 pool.StateReady,
		LastHeartbeatAt:       time.Now().UTC(),
		ConnectedAt:           time.Now().UTC(),
		BinaryVersion:         "0.2.0",
	}, nil)
}

func postStreamingTestChat(t *testing.T, server *Server, remoteAddr string) *httptest.ResponseRecorder {
	t.Helper()
	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	req.RemoteAddr = remoteAddr
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)
	return rr
}
