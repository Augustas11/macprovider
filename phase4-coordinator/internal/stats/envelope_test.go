package stats

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestWriteErrorEnvelopeShape(t *testing.T) {
	cases := []struct {
		code    string
		message string
		status  int
		retry   *int
	}{
		{codeBadRequest, "invalid window", http.StatusBadRequest, nil},
		{codeUnauthorized, "unauthorized", http.StatusUnauthorized, nil},
		{codeMethodNotAllowed, "method not allowed", http.StatusMethodNotAllowed, nil},
		{codeRateLimited, "rate limited", http.StatusTooManyRequests, errorRetry(60)},
		{codeStatsStale, "stats are stale", http.StatusServiceUnavailable, errorRetry(30)},
		{codeInternal, "internal", http.StatusInternalServerError, nil},
	}
	now := time.Date(2026, 6, 26, 12, 0, 0, 0, time.UTC)
	for _, c := range cases {
		w := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/v1/stats/health", nil)
		writeError(w, req, c.status, c.code, c.message, now, c.retry)
		if w.Code != c.status {
			t.Errorf("status: got %d want %d", w.Code, c.status)
		}
		ct := w.Header().Get("Content-Type")
		if !strings.HasPrefix(ct, "application/json") {
			t.Errorf("Content-Type: got %q want application/json prefix", ct)
		}
		if got := w.Header().Get("X-Stats-Generated-At"); got == "" {
			t.Errorf("X-Stats-Generated-At missing on non-304 error response")
		}
		var body errorEnvelope
		if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
			t.Fatalf("decode: %v", err)
		}
		if body.Error.Code != c.code {
			t.Errorf("code: got %q want %q", body.Error.Code, c.code)
		}
		if body.Error.Message != c.message {
			t.Errorf("message: got %q want %q", body.Error.Message, c.message)
		}
		if c.retry != nil {
			if body.Error.RetryAfterSeconds == nil || *body.Error.RetryAfterSeconds != *c.retry {
				t.Errorf("retry_after_seconds: got %v want %d", body.Error.RetryAfterSeconds, *c.retry)
			}
			if got := w.Header().Get("Retry-After"); got == "" {
				t.Errorf("Retry-After header missing on rate_limited/stats_stale")
			}
		}
	}
}

// HEAD must produce empty body across all error envelopes.
func TestWriteErrorHEADDropsBody(t *testing.T) {
	now := time.Date(2026, 6, 26, 12, 0, 0, 0, time.UTC)
	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodHead, "/v1/stats/overview", nil)
	writeError(w, req, http.StatusServiceUnavailable, codeStatsStale, "stale", now, errorRetry(30))
	if w.Code != http.StatusServiceUnavailable {
		t.Errorf("status: got %d want 503", w.Code)
	}
	if w.Body.Len() != 0 {
		t.Errorf("HEAD error body should be empty, got %d bytes: %q", w.Body.Len(), w.Body.String())
	}
}

// TestErrorCodeVocabulary pins the §5.9 closed list. Any new
// constant added here MUST be a SPEC bump.
func TestErrorCodeVocabulary(t *testing.T) {
	got := map[string]bool{
		codeBadRequest:       true,
		codeUnauthorized:     true,
		codeMethodNotAllowed: true,
		codeRateLimited:      true,
		codeStatsStale:       true,
		codeInternal:         true,
	}
	want := []string{
		"bad_request", "unauthorized", "method_not_allowed",
		"rate_limited", "stats_stale", "internal",
	}
	for _, w := range want {
		if !got[w] {
			t.Errorf("code %q missing from envelope vocabulary", w)
		}
	}
	if len(got) != len(want) {
		t.Errorf("envelope has %d codes, want exactly %d", len(got), len(want))
	}
}
