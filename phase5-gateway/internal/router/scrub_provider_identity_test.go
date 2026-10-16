package router

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func setIdentityHeaders(h http.Header) {
	h.Set("X-Provider-Id", "peer")
	h["x-provider-fingerprint"] = []string{"peer"}
	h.Set("X-Provider-Assigned-Id", "peer")
	h.Set("X-Route-Provider", "peer")
	h.Set("X-MacProvider-Provider", "peer")
	h.Set("X-MacProvider-Route", "peer")
	h.Set("X-MacProvider-Session", "peer")
	h.Set("X-MacProvider-Route-Trace", "keep")
	h.Set("X-Request-ID", "keep")
}

func assertScrubbed(t *testing.T, h http.Header) {
	t.Helper()
	for name := range h {
		if isProviderIdentityHeader(name) {
			t.Errorf("identity header %s survived the scrub", name)
		}
	}
	if h.Get("X-MacProvider-Route-Trace") != "keep" || h.Get("X-Request-ID") != "keep" {
		t.Errorf("non-identifying headers were stripped: %v", h)
	}
}

func TestScrubProviderIdentityWriter(t *testing.T) {
	cases := map[string]func(w http.ResponseWriter){
		"write": func(w http.ResponseWriter) { _, _ = w.Write([]byte("x")) },
		"flush-first": func(w http.ResponseWriter) {
			w.(http.Flusher).Flush()
			_, _ = w.Write([]byte("x"))
		},
		"1xx-then-200": func(w http.ResponseWriter) {
			w.WriteHeader(http.StatusEarlyHints)
			w.Header().Set("X-Provider-Id", "late")
			w.WriteHeader(http.StatusOK)
		},
		"response-controller-flush": func(w http.ResponseWriter) {
			if err := http.NewResponseController(w).Flush(); err != nil {
				panic(err)
			}
		},
		"explicit-status": func(w http.ResponseWriter) { w.WriteHeader(http.StatusBadGateway) },
	}
	for name, act := range cases {
		t.Run(name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			w := &scrubProviderIdentityWriter{ResponseWriter: rec}
			setIdentityHeaders(w.Header())
			act(w)
			assertScrubbed(t, rec.Result().Header)
		})
	}
}
