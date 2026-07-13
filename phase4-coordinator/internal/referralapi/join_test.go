package referralapi

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

func joinHandlerFor(result error) *JoinHandler {
	return &JoinHandler{
		Store: validationStoreFunc(func(string) (auth.ReferralValidation, error) {
			if result != nil {
				return auth.ReferralValidation{}, result
			}
			return auth.ReferralValidation{Valid: true, Reason: "valid"}, nil
		}),
		Policy:           validationPolicy(),
		PublicLimiter:    NewBoundedLimiter(20, time.Minute, 20),
		ValidateSlots:    make(chan struct{}, 1),
		RequestAccessURL: "https://access.example.test/waitlist",
	}
}

func TestJoinHandlerRendersLifecycleStates(t *testing.T) {
	cases := []struct {
		name       string
		err        error
		wantStatus int
		wantBody   string
	}{
		{name: "valid", wantStatus: http.StatusOK, wantBody: "Copy invite code"},
		{name: "exhausted", err: auth.ErrReferralExhausted, wantStatus: http.StatusOK, wantBody: "invite filled up"},
		{name: "expired", err: auth.ErrReferralExpired, wantStatus: http.StatusOK, wantBody: "invite has expired"},
		{name: "revoked", err: auth.ErrReferralRevoked, wantStatus: http.StatusOK, wantBody: "no longer active"},
		{name: "invalid", err: auth.ErrReferralInvalid, wantStatus: http.StatusNotFound, wantBody: "invite link isn't valid"},
		{name: "operational", err: errors.New("database is locked"), wantStatus: http.StatusServiceUnavailable, wantBody: "try again"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			response := httptest.NewRecorder()
			joinHandlerFor(tc.err).ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/j/MAL1-S-k1-seed-AAAAAAAAAAAAAAAAAAAAAAAAAA", nil))
			if response.Code != tc.wantStatus || !strings.Contains(response.Body.String(), tc.wantBody) {
				t.Fatalf("status=%d body=%q", response.Code, response.Body.String())
			}
			if got := response.Header().Get("Cache-Control"); got != "no-store" {
				t.Fatalf("Cache-Control=%q", got)
			}
			if tc.err == auth.ErrReferralExpired && !strings.Contains(response.Body.String(), "https://access.example.test/waitlist") {
				t.Fatal("request-access CTA missing")
			}
			if tc.err == auth.ErrReferralInvalid && (!strings.Contains(response.Body.String(), "Request access") || strings.Contains(response.Body.String(), "MAL1-S-k1-seed")) {
				t.Fatal("invalid invite page must offer access without echoing the code")
			}
			if tc.name == "operational" && response.Header().Get("Retry-After") != "5" {
				t.Fatal("operational failure missing Retry-After")
			}
		})
	}
}

func TestJoinHandlerOmitsAccessCTAWhenNotConfigured(t *testing.T) {
	h := joinHandlerFor(auth.ErrReferralExpired)
	h.RequestAccessURL = ""
	response := httptest.NewRecorder()
	h.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/j/invite", nil))
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "Ask your inviter for another invite.") {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if strings.Contains(response.Body.String(), "Request access") || strings.Contains(response.Body.String(), "access.example.test") {
		t.Fatalf("unconfigured request-access CTA rendered: %s", response.Body.String())
	}
}

func TestJoinHandlerRemainsMountedForOpenAccess(t *testing.T) {
	h := joinHandlerFor(nil)
	h.Policy.RequireForRegistration = false
	h.Store = nil
	response := httptest.NewRecorder()
	h.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/j/old-invite", nil))
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "don't need an invite") {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestJoinHandlerRejectsMalformedPathsAndBoundsConcurrency(t *testing.T) {
	h := joinHandlerFor(nil)
	for _, path := range []string{"/j/", "/j/a/b", "/j/" + strings.Repeat("a", 257)} {
		response := httptest.NewRecorder()
		h.ServeHTTP(response, httptest.NewRequest(http.MethodGet, path, nil))
		if response.Code != http.StatusNotFound {
			t.Fatalf("path=%q status=%d", path, response.Code)
		}
	}
	h.ValidateSlots <- struct{}{}
	response := httptest.NewRecorder()
	h.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/j/code", nil))
	<-h.ValidateSlots
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("busy status=%d", response.Code)
	}
}

func TestJoinHandlerHEADHasNoBodyAndMissingAuthorityIs503(t *testing.T) {
	h := joinHandlerFor(nil)
	h.Store = nil
	var logged error
	h.ErrorLogger = func(_ string, err error) { logged = err }
	response := httptest.NewRecorder()
	h.ServeHTTP(response, httptest.NewRequest(http.MethodHead, "/j/code", nil))
	if response.Code != http.StatusServiceUnavailable || response.Body.Len() != 0 || logged == nil {
		t.Fatalf("status=%d body=%q logged=%v", response.Code, response.Body.String(), logged)
	}
}
