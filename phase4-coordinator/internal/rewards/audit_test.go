package rewards

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

type fakeAuditTokens map[string]string

func (f fakeAuditTokens) ValidateAndMarkTokenUsed(_ context.Context, raw string) (string, bool, error) {
	providerID, ok := f[raw]
	return providerID, ok, nil
}

type readOnlyAuditTokens struct {
	providerID string
	readOnly   int
	marked     int
}

func (f *readOnlyAuditTokens) ValidateTokenReadOnly(context.Context, string) (string, bool, error) {
	f.readOnly++
	return f.providerID, true, nil
}

func (f *readOnlyAuditTokens) ValidateAndMarkTokenUsed(context.Context, string) (string, bool, error) {
	f.marked++
	return f.providerID, true, nil
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

func TestRewardAuditHandlerPrefersReadOnlyTokenValidation(t *testing.T) {
	tokens := &readOnlyAuditTokens{providerID: "provider-a"}
	h := NewRewardAuditHandler(AuditHandlerDeps{
		TokenStore:            tokens,
		RequireProviderTokens: true,
	})

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/malibu-reward-audit?limit=101", nil)
	req.Header.Set("Authorization", "Bearer good")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("code=%d body=%s", rec.Code, rec.Body.String())
	}
	if tokens.readOnly != 1 || tokens.marked != 0 {
		t.Fatalf("validation calls readOnly=%d marked=%d, want readOnly only", tokens.readOnly, tokens.marked)
	}
}

func TestRewardAuditLimiterEnforcesProviderWindowAndConcurrency(t *testing.T) {
	limiter := NewRewardAuditLimiter(2, 1)
	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)

	release, ok := limiter.Allow("provider-a", now)
	if !ok {
		t.Fatal("first request should be allowed")
	}
	if _, ok := limiter.Allow("provider-a", now); ok {
		t.Fatal("second concurrent request should be rejected")
	}
	release()
	release, ok = limiter.Allow("provider-a", now)
	if !ok {
		t.Fatal("second request after release should be allowed")
	}
	release()
	if _, ok := limiter.Allow("provider-a", now); ok {
		t.Fatal("third request in the same minute should be rate limited")
	}
	if release, ok := limiter.Allow("provider-a", now.Add(time.Minute)); !ok {
		t.Fatal("next window should be allowed")
	} else {
		release()
	}
}

func TestRewardAuditLimiterPreservesInflightAcrossMinuteRollover(t *testing.T) {
	limiter := NewRewardAuditLimiter(10, 1)
	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)

	releaseA, ok := limiter.Allow("provider-a", now)
	if !ok {
		t.Fatal("first request should be allowed")
	}
	if _, ok := limiter.Allow("provider-a", now.Add(time.Minute)); ok {
		t.Fatal("second request in next window must be rejected while first remains in flight")
	}
	releaseA()
	if release, ok := limiter.Allow("provider-a", now.Add(time.Minute)); !ok {
		t.Fatal("request after release should be allowed")
	} else {
		release()
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
