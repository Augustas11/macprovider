package buyer

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-network-harness/internal/scenario"
)

// TestFireRequest_StickyHeader_EmittedWhenTemplateSet asserts that the
// buyer client sets the X-MacProvider-Conversation header when the
// scenario's Buyers.StickyConversationKey template is non-empty. The
// template's %d verb resolves to the buyer index.
func TestFireRequest_StickyHeader_EmittedWhenTemplateSet(t *testing.T) {
	var gotHeader string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotHeader = r.Header.Get("X-MacProvider-Conversation")
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`)
	}))
	defer srv.Close()

	sc := &scenario.Scenario{
		Target: scenario.Target{
			GatewayURL: srv.URL,
			BuyerToken: "test-token",
		},
		Buyers: scenario.Buyers{
			Count:                 3,
			Stream:                false,
			StickyConversationKey: "harness-scenario-03-buyer-%d",
		},
		Prompts: []scenario.Prompt{
			{Model: "test-model", User: "hi", MaxTokens: 4},
		},
		RequestTimeout:      5 * time.Second,
		SilentHangThreshold: 30 * time.Second,
	}

	res := fireOnce(context.Background(), http.DefaultClient, sc, sc.Prompts[0], 7, 0)
	if res.HTTPStatus != 200 {
		t.Fatalf("expected 200 (mock ok), got %d — err=%q", res.HTTPStatus, res.ErrorMsg)
	}
	want := "harness-scenario-03-buyer-7"
	if gotHeader != want {
		t.Errorf("X-MacProvider-Conversation = %q, want %q", gotHeader, want)
	}
}

// TestFireRequest_StickyHeader_OmittedWhenTemplateEmpty asserts that
// the header is NOT sent when the sticky_conversation_key template is
// empty (the default). This preserves the pre-sticky behavior for every
// scenario that hasn't opted into sticky affinity.
func TestFireRequest_StickyHeader_OmittedWhenTemplateEmpty(t *testing.T) {
	var seenHeader bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-MacProvider-Conversation") != "" {
			seenHeader = true
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`)
	}))
	defer srv.Close()

	sc := &scenario.Scenario{
		Target: scenario.Target{
			GatewayURL: srv.URL,
			BuyerToken: "test-token",
		},
		Buyers: scenario.Buyers{
			Count:                 2,
			Stream:                false,
			StickyConversationKey: "", // explicit empty
		},
		Prompts: []scenario.Prompt{
			{Model: "test-model", User: "hi", MaxTokens: 4},
		},
		RequestTimeout:      5 * time.Second,
		SilentHangThreshold: 30 * time.Second,
	}

	res := fireOnce(context.Background(), http.DefaultClient, sc, sc.Prompts[0], 0, 0)
	if res.HTTPStatus != 200 {
		t.Fatalf("expected 200, got %d — err=%q", res.HTTPStatus, res.ErrorMsg)
	}
	if seenHeader {
		t.Errorf("X-MacProvider-Conversation must be OMITTED when template is empty")
	}
}

// TestFireRequest_StickyHeader_TemplateExpandsBuyerIndex asserts the %d
// verb resolves to the buyer index passed to fireRequest, so per-buyer
// tags are actually distinct across the fleet.
func TestFireRequest_StickyHeader_TemplateExpandsBuyerIndex(t *testing.T) {
	seen := map[int]string{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if h := r.Header.Get("X-MacProvider-Conversation"); h != "" {
			// crude: buyer index is the trailing integer
			parts := strings.Split(h, "-")
			if len(parts) > 0 {
				seen[len(seen)] = parts[len(parts)-1]
			}
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`)
	}))
	defer srv.Close()

	sc := &scenario.Scenario{
		Target: scenario.Target{
			GatewayURL: srv.URL,
			BuyerToken: "test-token",
		},
		Buyers: scenario.Buyers{
			Count:                 3,
			Stream:                false,
			StickyConversationKey: "buyer-%d",
		},
		Prompts: []scenario.Prompt{
			{Model: "test-model", User: "hi", MaxTokens: 4},
		},
		RequestTimeout:      5 * time.Second,
		SilentHangThreshold: 30 * time.Second,
	}

	for buyerIdx := 0; buyerIdx < 3; buyerIdx++ {
		_ = fireOnce(context.Background(), http.DefaultClient, sc, sc.Prompts[0], buyerIdx, 0)
	}
	if len(seen) != 3 {
		t.Fatalf("expected 3 headers seen, got %d — %v", len(seen), seen)
	}
	for i := 0; i < 3; i++ {
		want := ""
		switch i {
		case 0:
			want = "0"
		case 1:
			want = "1"
		case 2:
			want = "2"
		}
		if seen[i] != want {
			t.Errorf("call %d saw buyer suffix %q, want %q", i, seen[i], want)
		}
	}
}
