package buyer

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-network-harness/internal/scenario"
)

func TestFireOnceInvalid2xxMalformedJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"choices":[`)
	}))
	defer srv.Close()

	res := fireOnce(context.Background(), http.DefaultClient, validLoadgenScenario(srv.URL), scenario.Prompt{Model: "m", User: "hi"}, 0, 0)
	if res.Outcome != "invalid_response" {
		t.Fatalf("Outcome=%q want invalid_response: %+v", res.Outcome, res)
	}
	if res.ErrorCode != "invalid_response" {
		t.Fatalf("ErrorCode=%q want invalid_response", res.ErrorCode)
	}
}

func TestFireOnceInvalid2xxWrongShapeJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"ok":true}`)
	}))
	defer srv.Close()

	res := fireOnce(context.Background(), http.DefaultClient, validLoadgenScenario(srv.URL), scenario.Prompt{Model: "m", User: "hi"}, 0, 0)
	if res.Outcome != "invalid_response" {
		t.Fatalf("Outcome=%q want invalid_response: %+v", res.Outcome, res)
	}
	if res.SawTerminator {
		t.Fatalf("wrong-shape JSON must not set SawTerminator")
	}
}

func TestFireOnceInvalid2xxRejectsNullToolCalls(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"choices":[{"message":{"tool_calls":null}}]}`)
	}))
	defer srv.Close()

	res := fireOnce(context.Background(), http.DefaultClient, validLoadgenScenario(srv.URL), scenario.Prompt{Model: "m", User: "hi"}, 0, 0)
	if res.Outcome != "invalid_response" {
		t.Fatalf("Outcome=%q want invalid_response: %+v", res.Outcome, res)
	}
}

func TestFireOnceInvalid2xxRejectsEmptyToolCalls(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"choices":[{"message":{"tool_calls":[]}}]}`)
	}))
	defer srv.Close()

	res := fireOnce(context.Background(), http.DefaultClient, validLoadgenScenario(srv.URL), scenario.Prompt{Model: "m", User: "hi"}, 0, 0)
	if res.Outcome != "invalid_response" {
		t.Fatalf("Outcome=%q want invalid_response: %+v", res.Outcome, res)
	}
}

func TestFireOnceInvalid2xxRejectsMixedInvalidChoice(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"choices":[{"message":{"content":"ok"}},{"message":{"tool_calls":[]}}]}`)
	}))
	defer srv.Close()

	res := fireOnce(context.Background(), http.DefaultClient, validLoadgenScenario(srv.URL), scenario.Prompt{Model: "m", User: "hi"}, 0, 0)
	if res.Outcome != "invalid_response" {
		t.Fatalf("Outcome=%q want invalid_response: %+v", res.Outcome, res)
	}
}

func TestFireOnceInvalid2xxRejectsMalformedToolCallsWithContent(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"choices":[{"message":{"content":"ok","tool_calls":[]}}]}`)
	}))
	defer srv.Close()

	res := fireOnce(context.Background(), http.DefaultClient, validLoadgenScenario(srv.URL), scenario.Prompt{Model: "m", User: "hi"}, 0, 0)
	if res.Outcome != "invalid_response" {
		t.Fatalf("Outcome=%q want invalid_response: %+v", res.Outcome, res)
	}
}

func TestFireOnceAcceptsToolCallResponseShape(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"choices":[{"message":{"tool_calls":[{"id":"call_1","type":"function","function":{"name":"lookup","arguments":"{}"}}]}}]}`)
	}))
	defer srv.Close()

	res := fireOnce(context.Background(), http.DefaultClient, validLoadgenScenario(srv.URL), scenario.Prompt{Model: "m", User: "hi"}, 0, 0)
	if res.Outcome != "ok" {
		t.Fatalf("Outcome=%q want ok: %+v", res.Outcome, res)
	}
	if !res.SawTerminator {
		t.Fatalf("valid tool-call response should set SawTerminator")
	}
}

func TestFireOnceAcceptsOpenAISignalResponseShapes(t *testing.T) {
	cases := []struct {
		name string
		body string
	}{
		{"refusal", `{"choices":[{"message":{"refusal":"cannot comply"}}]}`},
		{"reasoning", `{"choices":[{"message":{"reasoning":"thinking"}}]}`},
		{"function_call", `{"choices":[{"message":{"function_call":{"name":"lookup","arguments":"{}"}}}]}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusOK)
				_, _ = io.WriteString(w, tc.body)
			}))
			defer srv.Close()

			res := fireOnce(context.Background(), http.DefaultClient, validLoadgenScenario(srv.URL), scenario.Prompt{Model: "m", User: "hi"}, 0, 0)
			if res.Outcome != "ok" {
				t.Fatalf("Outcome=%q want ok: %+v", res.Outcome, res)
			}
		})
	}
}

func TestFireOnceInvalid2xxRejectsRoleOnlyMessage(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"choices":[{"message":{"role":"assistant"}}]}`)
	}))
	defer srv.Close()

	res := fireOnce(context.Background(), http.DefaultClient, validLoadgenScenario(srv.URL), scenario.Prompt{Model: "m", User: "hi"}, 0, 0)
	if res.Outcome != "invalid_response" {
		t.Fatalf("Outcome=%q want invalid_response: %+v", res.Outcome, res)
	}
}

func TestFireOnceInvalid2xxRejectsEmptyStringSignals(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"choices":[{"message":{"content":"","role":"","refusal":"","reasoning":""}}]}`)
	}))
	defer srv.Close()

	res := fireOnce(context.Background(), http.DefaultClient, validLoadgenScenario(srv.URL), scenario.Prompt{Model: "m", User: "hi"}, 0, 0)
	if res.Outcome != "invalid_response" {
		t.Fatalf("Outcome=%q want invalid_response: %+v", res.Outcome, res)
	}
}

func TestRunContextCancelStopsInitialDelay(t *testing.T) {
	sc := validLoadgenScenario("http://127.0.0.1")
	sc.Buyers.InitialDelay = time.Hour
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()

	started := time.Now()
	results, err := Run(ctx, sc)
	if err != nil {
		t.Fatalf("Run err=%v", err)
	}
	if len(results) != 0 {
		t.Fatalf("results len=%d want 0", len(results))
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("Run ignored context during initial delay; elapsed=%s", elapsed)
	}
}

func TestRunDurationStopsInitialDelayWithoutParentCancel(t *testing.T) {
	sc := validLoadgenScenario("http://127.0.0.1")
	sc.Buyers.InitialDelay = time.Hour
	sc.Duration = 10 * time.Millisecond

	started := time.Now()
	results, err := Run(context.Background(), sc)
	if err != nil {
		t.Fatalf("Run err=%v", err)
	}
	if len(results) != 0 {
		t.Fatalf("results len=%d want 0", len(results))
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("Run ignored duration during initial delay; elapsed=%s", elapsed)
	}
}

func validLoadgenScenario(url string) *scenario.Scenario {
	return &scenario.Scenario{
		Target: scenario.Target{
			GatewayURL: url,
			BuyerToken: "test-token",
		},
		Buyers: scenario.Buyers{
			Count:            1,
			RequestsPerBuyer: 1,
		},
		RequestTimeout:      5 * time.Second,
		SilentHangThreshold: 30 * time.Second,
	}
}
