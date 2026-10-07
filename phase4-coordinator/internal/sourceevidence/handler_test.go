package sourceevidence

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHandlerRejectsNonOperatorBearerAndDoesNotStore(t *testing.T) {
	for _, token := range []string{"provider-secret", "creator-secret", ""} {
		t.Run(token, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/source-evidence/export", strings.NewReader(`{}`))
			if token != "" {
				req.Header.Set("Authorization", "Bearer "+token)
			}
			rec := httptest.NewRecorder()
			NewHandler("operator-secret", nil, 0).ServeHTTP(rec, req)
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("status=%d want %d", rec.Code, http.StatusUnauthorized)
			}
			if got := rec.Header().Get("Cache-Control"); got != "no-store" {
				t.Fatalf("Cache-Control=%q want no-store", got)
			}
		})
	}
}

func TestHandlerNilProducerFailsClosedWithNoStore(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/source-evidence/export", strings.NewReader(`{}`))
	req.Header.Set("Authorization", "Bearer operator-secret")
	rec := httptest.NewRecorder()
	NewHandler("operator-secret", nil, 0).ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d want %d", rec.Code, http.StatusServiceUnavailable)
	}
	if got := rec.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("Cache-Control=%q want no-store", got)
	}
}
