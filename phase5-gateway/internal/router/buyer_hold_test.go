package router

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func postBuyerHold(t *testing.T, h http.Handler, token, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/admin/buyer-hold", strings.NewReader(body))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func healthzBuyerHold(t *testing.T, h http.Handler) bool {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("/healthz status = %d body=%s", rec.Code, rec.Body.String())
	}
	var body struct {
		BuyerHold *bool `json:"buyer_hold"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil || body.BuyerHold == nil {
		t.Fatalf("/healthz lacks buyer_hold: %s", rec.Body.String())
	}
	return *body.BuyerHold
}

func usageRequest(h http.Handler, key string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, "/v1/usage", nil)
	req.Header.Set("Authorization", "Bearer "+key)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func errorCode(t *testing.T, rec *httptest.ResponseRecorder) string {
	t.Helper()
	var body struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &body)
	return body.Error.Code
}

func TestBuyerHoldRefusesNewBuyerRequestsWith503AndRetryAfter(t *testing.T) {
	h, store, _, cfg := newTestHarness(t, nil)
	key := createAccountAndKey(t, store, cfg, "acct_hold_buyer")
	if healthzBuyerHold(t, h) {
		t.Fatal("buyer hold is on before anyone set it")
	}
	if rec := postBuyerHold(t, h, cfg.Coordinator.OperatorKey, `{"active":true}`); rec.Code != http.StatusOK {
		t.Fatalf("hold on status = %d body=%s", rec.Code, rec.Body.String())
	}
	if !healthzBuyerHold(t, h) {
		t.Fatal("/healthz does not report the hold")
	}
	for _, req := range []*http.Request{
		httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"m","messages":[]}`)),
		httptest.NewRequest(http.MethodGet, "/v1/usage", nil),
		httptest.NewRequest(http.MethodGet, "/v1/models", nil),
	} {
		req.Header.Set("Authorization", "Bearer "+key)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != http.StatusServiceUnavailable {
			t.Fatalf("%s %s status = %d, want 503", req.Method, req.URL.Path, rec.Code)
		}
		if got := rec.Header().Get("Retry-After"); got != "30" {
			t.Fatalf("%s Retry-After = %q, want 30", req.URL.Path, got)
		}
		var body struct {
			Error struct {
				Type      string `json:"type"`
				Code      string `json:"code"`
				Message   string `json:"message"`
				Retryable bool   `json:"retryable"`
			} `json:"error"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
			t.Fatalf("held body is not JSON: %s", rec.Body.String())
		}
		if body.Error.Type != "server_error" || body.Error.Code != "public_api_paused" || !body.Error.Retryable || body.Error.Message == "" {
			t.Fatalf("held body = %+v", body.Error)
		}
	}
	if rec := postBuyerHold(t, h, cfg.Coordinator.OperatorKey, `{"active":false}`); rec.Code != http.StatusOK {
		t.Fatalf("hold off status = %d", rec.Code)
	}
	if healthzBuyerHold(t, h) {
		t.Fatal("/healthz still reports the hold after release")
	}
	if rec := usageRequest(h, key); rec.Code != http.StatusOK {
		t.Fatalf("usage after release status = %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestBuyerHoldAdmitsOnlyTheCanaryKey(t *testing.T) {
	h, store, _, cfg := newTestHarness(t, nil)
	canary := createAccountAndKey(t, store, cfg, "acct_hold_canary")
	buyer := createAccountAndKey(t, store, cfg, "acct_hold_other")
	sum := sha256.Sum256([]byte(canary))
	body := `{"active":true,"admit_api_key_sha256":"` + hex.EncodeToString(sum[:]) + `"}`
	if rec := postBuyerHold(t, h, cfg.Coordinator.OperatorKey, body); rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"canary_admitted":true`) {
		t.Fatalf("hold with canary status = %d body=%s", rec.Code, rec.Body.String())
	}
	if rec := usageRequest(h, canary); rec.Code != http.StatusOK {
		t.Fatalf("canary request status = %d body=%s", rec.Code, rec.Body.String())
	}
	if rec := usageRequest(h, buyer); rec.Code != http.StatusServiceUnavailable || errorCode(t, rec) != "public_api_paused" {
		t.Fatalf("other buyer status = %d body=%s", rec.Code, rec.Body.String())
	}
	// Turning the hold off forgets the admitted key: a new hold admits nobody.
	postBuyerHold(t, h, cfg.Coordinator.OperatorKey, `{"active":false}`)
	postBuyerHold(t, h, cfg.Coordinator.OperatorKey, `{"active":true}`)
	if rec := usageRequest(h, canary); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("canary passed a hold that admits nobody: %d", rec.Code)
	}
}

func TestBuyerHoldRequiresOperatorAuth(t *testing.T) {
	h, _, _, cfg := newTestHarness(t, nil)
	for _, token := range []string{"", "not-the-operator-key"} {
		if rec := postBuyerHold(t, h, token, `{"active":true}`); rec.Code != http.StatusUnauthorized {
			t.Fatalf("token %q status = %d, want 401", token, rec.Code)
		}
	}
	if healthzBuyerHold(t, h) {
		t.Fatal("an unauthenticated request turned the hold on")
	}
	for _, body := range []string{`{}`, `{"active":"yes"}`, `{"active":false,"admit_api_key_sha256":"` + strings.Repeat("a", 64) + `"}`, `{"active":true,"admit_api_key_sha256":"zz"}`, `{"active":true,"extra":1}`} {
		if rec := postBuyerHold(t, h, cfg.Coordinator.OperatorKey, body); rec.Code != http.StatusBadRequest {
			t.Fatalf("body %s status = %d, want 400", body, rec.Code)
		}
	}
	req := httptest.NewRequest(http.MethodGet, "/admin/buyer-hold", nil)
	req.Header.Set("Authorization", "Bearer "+cfg.Coordinator.OperatorKey)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET status = %d, want 405", rec.Code)
	}
	if healthzBuyerHold(t, h) {
		t.Fatal("a rejected request changed the hold")
	}
}

func TestBuyerHoldIsOffAfterRestart(t *testing.T) {
	h, store, _, cfg := newTestHarness(t, nil)
	postBuyerHold(t, h, cfg.Coordinator.OperatorKey, `{"active":true}`)
	if !healthzBuyerHold(t, h) {
		t.Fatal("hold not set")
	}
	restarted := New(cfg, store, nil, WithNow(fixedNow)).Handler()
	if healthzBuyerHold(t, restarted) {
		t.Fatal("a new process inherited the hold")
	}
	startedHeld := New(cfg, store, nil, WithNow(fixedNow), WithBuyerHoldAtStart(true)).Handler()
	if !healthzBuyerHold(t, startedHeld) {
		t.Fatal("WithBuyerHoldAtStart(true) did not start held")
	}
}

func TestBuyerHoldLetsInFlightStreamFinish(t *testing.T) {
	_, store, _, cfg := newTestHarness(t, nil)
	s := New(cfg, store, nil, WithNow(fixedNow))
	full := s.Handler()
	release := make(chan struct{})
	stream := s.middleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("data: first\n\n"))
		w.(http.Flusher).Flush()
		<-release
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/chat/completions" {
			stream.ServeHTTP(w, r)
			return
		}
		full.ServeHTTP(w, r)
	}))
	defer srv.Close()

	resp, err := http.Post(srv.URL+"/v1/chat/completions", "application/json", strings.NewReader(`{}`))
	if err != nil {
		t.Fatalf("stream request: %v", err)
	}
	defer resp.Body.Close()
	reader := bufio.NewReader(resp.Body)
	if line, err := reader.ReadString('\n'); err != nil || line != "data: first\n" {
		t.Fatalf("first line = %q err=%v", line, err)
	}

	hold, err := http.NewRequest(http.MethodPost, srv.URL+"/admin/buyer-hold", strings.NewReader(`{"active":true}`))
	if err != nil {
		t.Fatal(err)
	}
	hold.Header.Set("Authorization", "Bearer "+cfg.Coordinator.OperatorKey)
	holdResp, err := http.DefaultClient.Do(hold)
	if err != nil || holdResp.StatusCode != http.StatusOK {
		t.Fatalf("hold on: %v %v", err, holdResp)
	}
	holdResp.Body.Close()

	held, err := http.Post(srv.URL+"/v1/chat/completions", "application/json", strings.NewReader(`{}`))
	if err != nil {
		t.Fatalf("held request: %v", err)
	}
	held.Body.Close()
	if held.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("new request during hold status = %d, want 503", held.StatusCode)
	}

	close(release)
	done := make(chan string, 1)
	go func() {
		rest := ""
		for {
			line, err := reader.ReadString('\n')
			rest += line
			if err != nil {
				break
			}
		}
		done <- rest
	}()
	select {
	case rest := <-done:
		if !strings.Contains(rest, "data: [DONE]") {
			t.Fatalf("in-flight stream did not finish: %q", rest)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("in-flight stream did not finish")
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("in-flight stream status = %d", resp.StatusCode)
	}
}
