package rewards

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

type fakeAuditTokens map[string]string

func (f fakeAuditTokens) ValidateAndMarkTokenUsed(_ context.Context, raw string) (string, bool, error) {
	providerID, ok := f[raw]
	return providerID, ok, nil
}

func TestParseAuditPageBounds(t *testing.T) {
	if got, err := ParseAuditLimit(""); err != nil || got != defaultAuditLimit {
		t.Fatalf("default limit got (%d,%v)", got, err)
	}
	if got, err := ParseAuditLimit("100"); err != nil || got != 100 {
		t.Fatalf("max limit got (%d,%v)", got, err)
	}
	for _, raw := range []string{"0", "-1", "101", "many"} {
		if _, err := ParseAuditLimit(raw); err == nil {
			t.Fatalf("ParseAuditLimit(%q) succeeded, want error", raw)
		}
	}
	if got, err := ParseAuditBeforeID("mra_42"); err != nil || got != 42 {
		t.Fatalf("before id got (%d,%v)", got, err)
	}
	for _, raw := range []string{"mra_0", "mra_bad", "-1"} {
		if _, err := ParseAuditBeforeID(raw); err == nil {
			t.Fatalf("ParseAuditBeforeID(%q) succeeded, want error", raw)
		}
	}
}

func TestRewardAuditHandlerAuthAndCursorValidation(t *testing.T) {
	h := NewRewardAuditHandler(AuditHandlerDeps{
		TokenStore:            fakeAuditTokens{"good": "provider-a"},
		RequireProviderTokens: true,
	})

	unauth := httptest.NewRecorder()
	h.ServeHTTP(unauth, httptest.NewRequest(http.MethodGet, "/v1/provider/malibu-reward-audit", nil))
	if unauth.Code != http.StatusUnauthorized {
		t.Fatalf("unauth code=%d", unauth.Code)
	}

	badLimit := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/provider/malibu-reward-audit?limit=101", nil)
	req.Header.Set("Authorization", "Bearer good")
	h.ServeHTTP(badLimit, req)
	if badLimit.Code != http.StatusBadRequest {
		t.Fatalf("bad limit code=%d body=%s", badLimit.Code, badLimit.Body.String())
	}
}

func TestRewardAuditAdminHandlerAuthAndProviderRequired(t *testing.T) {
	h := NewRewardAuditAdminHandler(AuditHandlerDeps{OperatorKey: "operator"})

	unauth := httptest.NewRecorder()
	h.ServeHTTP(unauth, httptest.NewRequest(http.MethodGet, "/admin/malibu-reward-audit?provider_id=p", nil))
	if unauth.Code != http.StatusUnauthorized {
		t.Fatalf("unauth code=%d", unauth.Code)
	}

	missingProvider := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/admin/malibu-reward-audit", nil)
	req.Header.Set("Authorization", "Bearer operator")
	h.ServeHTTP(missingProvider, req)
	if missingProvider.Code != http.StatusBadRequest {
		t.Fatalf("missing provider code=%d body=%s", missingProvider.Code, missingProvider.Body.String())
	}
}
