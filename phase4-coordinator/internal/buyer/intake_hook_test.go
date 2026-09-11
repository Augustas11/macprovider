package buyer_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

type recordingIntakeObserver struct {
	mu    sync.Mutex
	calls [][2]string
}

func (r *recordingIntakeObserver) Observe(rawModel, accountID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls = append(r.calls, [2]string{rawModel, accountID})
}

func (r *recordingIntakeObserver) snapshot() [][2]string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([][2]string(nil), r.calls...)
}

// SPEC-017 v0.2.1 §5.2b.2: only an authenticated (gateway-context) account
// that reaches model resolution and is not a demo subject feeds the
// aggregator; the raw requested string is passed through unchanged.
func TestIntakeHookObservesOnlyAuthenticatedUnmatchedRequests(t *testing.T) {
	registry := pool.NewRegistry(nil)
	obs := &recordingIntakeObserver{}
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithGatewayServiceToken("gateway-secret"),
		buyer.WithRequireGatewayContext(true),
		buyer.WithIntakeObserver(obs),
	)
	body := `{"model":"Qwen3-Coder-Next","messages":[{"role":"user","content":"hi"}]}`
	post := func(bearer, account string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
		if bearer != "" {
			req.Header.Set("Authorization", "Bearer "+bearer)
		}
		if account != "" {
			req.Header.Set("X-MacProvider-Account", account)
		}
		rr := httptest.NewRecorder()
		server.Handler().ServeHTTP(rr, req)
		return rr
	}

	// Authenticated gateway context: observed with the raw string.
	if rr := post("gateway-secret", "acct_buyer_1"); rr.Code != http.StatusNotFound || !strings.Contains(rr.Body.String(), "model_not_found") {
		t.Fatalf("status=%d body=%s, want 404 model_not_found", rr.Code, rr.Body.String())
	}
	// Demo subject: rejected as unmatched but never observed.
	post("gateway-secret", "demo:203.0.113.9")
	// Bare account header without the gateway bearer: no authenticated
	// account (the gateway context middleware refuses it), never observed.
	if rr := post("", "acct_buyer_2"); rr.Code != http.StatusUnauthorized {
		t.Fatalf("bare account header: status=%d, want 401", rr.Code)
	}
	// Malformed body is rejected before model resolution: never observed.
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{`))
	req.Header.Set("Authorization", "Bearer gateway-secret")
	req.Header.Set("X-MacProvider-Account", "acct_buyer_3")
	server.Handler().ServeHTTP(httptest.NewRecorder(), req)

	calls := obs.snapshot()
	if len(calls) != 1 || calls[0] != [2]string{"Qwen3-Coder-Next", "acct_buyer_1"} {
		t.Fatalf("observer calls = %v, want exactly the authenticated unmatched request", calls)
	}
}

func TestIntakeHookIsInertWithoutObserver(t *testing.T) {
	registry := pool.NewRegistry(nil)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithGatewayServiceToken("gateway-secret"), buyer.WithRequireGatewayContext(true), buyer.WithIntakeObserver(nil))
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"x","messages":[{"role":"user","content":"hi"}]}`))
	req.Header.Set("Authorization", "Bearer gateway-secret")
	req.Header.Set("X-MacProvider-Account", "acct_buyer_1")
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("status=%d, want 404", rr.Code)
	}
}
