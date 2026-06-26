package stats

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestWriteErrorEnvelopeShape(t *testing.T) {
	cases := []struct {
		code   string
		detail string
		status int
	}{
		{codeBadRequest, "invalid window", http.StatusBadRequest},
		{codeUnauthorized, "unauthorized", http.StatusUnauthorized},
		{codeMethodNotAllowed, "method not allowed", http.StatusMethodNotAllowed},
		{codeRateLimited, "rate limited", http.StatusTooManyRequests},
		{codeStatsStale, "stats are stale", http.StatusServiceUnavailable},
		{codeInternal, "internal", http.StatusInternalServerError},
	}
	for _, c := range cases {
		w := httptest.NewRecorder()
		writeError(w, c.status, c.code, c.detail)
		if w.Code != c.status {
			t.Errorf("status: got %d want %d", w.Code, c.status)
		}
		ct := w.Header().Get("Content-Type")
		if !strings.HasPrefix(ct, "application/json") {
			t.Errorf("Content-Type: got %q want application/json prefix", ct)
		}
		var body errorEnvelope
		if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
			t.Fatalf("decode: %v", err)
		}
		if body.Error.Code != c.code {
			t.Errorf("code: got %q want %q", body.Error.Code, c.code)
		}
		if body.Error.Detail != c.detail {
			t.Errorf("detail: got %q want %q", body.Error.Detail, c.detail)
		}
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
