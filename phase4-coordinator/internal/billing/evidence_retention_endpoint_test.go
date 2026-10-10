package billing

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestEvidenceRetentionAdminRouteIsOperatorOnlyAndGatedByEnabled(t *testing.T) {
	f := newRetentionFixture(t, false)
	f.seed(t, "first")
	f.seed(t, "b")
	f.settle(t)
	h := f.store.Handlers("operator-key", nil, false, 0)
	call := func(method, path, bearer string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, path, nil)
		if bearer != "" {
			req.Header.Set("Authorization", "Bearer "+bearer)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		return w
	}
	if w := call(http.MethodGet, evidenceRetentionPath, "operator-key"); w.Code != http.StatusServiceUnavailable {
		t.Fatalf("unconfigured dry run status=%d", w.Code)
	}
	opts := retentionTestOptions(t.TempDir(), nil)
	opts.Enabled = false
	f.store.SetEvidenceRetentionOptions(opts)
	if w := call(http.MethodGet, evidenceRetentionPath, ""); w.Code != http.StatusForbidden {
		t.Fatalf("no bearer status=%d", w.Code)
	}
	if w := call(http.MethodGet, evidenceRetentionPath, "wrong"); w.Code != http.StatusForbidden {
		t.Fatalf("wrong bearer status=%d", w.Code)
	}
	w := call(http.MethodGet, evidenceRetentionPath, "operator-key")
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"status":"dry_run"`) || !strings.Contains(w.Body.String(), `"eligible_requests":1`) {
		t.Fatalf("dry run status=%d body=%s", w.Code, w.Body.String())
	}
	if w := call(http.MethodPost, evidenceRetentionRunPath, "operator-key"); w.Code != http.StatusConflict || !strings.Contains(w.Body.String(), "retention_disabled") {
		t.Fatalf("disabled run status=%d body=%s", w.Code, w.Body.String())
	}
	if w := call(http.MethodPost, evidenceRetentionPath, "operator-key"); w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST dry-run path status=%d", w.Code)
	}
	if f.hotRows(t, "b") != 3 {
		t.Fatal("admin dry run or refused run deleted evidence")
	}
	if w := call(http.MethodGet, evidenceRetentionPath+"?report=last", "operator-key"); w.Code != http.StatusNotFound {
		t.Fatalf("last report before any run status=%d", w.Code)
	}
}
