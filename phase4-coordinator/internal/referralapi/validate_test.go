package referralapi

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

type validationStoreFunc func(string) (auth.ReferralValidation, error)

func (f validationStoreFunc) ValidateReferral(_ context.Context, _ auth.ReferralPolicy, code string, _ time.Time) (auth.ReferralValidation, error) {
	return f(code)
}

func validationPolicy() auth.ReferralPolicy {
	return auth.ReferralPolicy{
		RequireForRegistration: true,
		Campaign:               "prebeta_test",
		PolicyVersion:          "v1",
		CurrentKeyID:           "k1",
		HMACKeys:               map[string]string{"k1": strings.Repeat("s", 32)},
		ProviderBaseUses:       1,
	}
}

func TestValidationHandlerReturnsStableReasonWithoutReserving(t *testing.T) {
	metrics := &advocacyMetrics{}
	h := &ValidationHandler{
		Store: validationStoreFunc(func(code string) (auth.ReferralValidation, error) {
			if code == "expired" {
				return auth.ReferralValidation{}, auth.ErrReferralExpired
			}
			return auth.ReferralValidation{Valid: true, Reason: "valid"}, nil
		}),
		Policy:           validationPolicy(),
		PublicLimiter:    NewBoundedLimiter(10, time.Minute, 10),
		ValidateSlots:    make(chan struct{}, 1),
		SourceIP:         func(*http.Request) string { return "203.0.113.10" },
		RequestAccessURL: "https://access.example.test/waitlist",
		Metrics:          metrics,
	}

	for _, tc := range []struct {
		body string
		want string
	}{
		{`{"code":"good"}`, `"valid":true`},
		{`{"code":"expired"}`, `"reason":"expired"`},
	} {
		req := httptest.NewRequest(http.MethodPost, "/v1/referrals/validate", strings.NewReader(tc.body))
		response := httptest.NewRecorder()
		h.ServeHTTP(response, req)
		if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), tc.want) {
			t.Fatalf("status=%d body=%s want %s", response.Code, response.Body.String(), tc.want)
		}
		if !strings.Contains(response.Body.String(), `"request_access_url":"https://access.example.test/waitlist"`) {
			t.Fatalf("configured access URL missing from status=%d body=%s", response.Code, response.Body.String())
		}
	}
	if !containsEvent(metrics.events, "validate/valid") || !containsEvent(metrics.events, "validate/expired") {
		t.Fatalf("metrics=%v", metrics.events)
	}
}

func TestValidationHandlerOptionalAccessURLCoversDisabledAndCanBeOmitted(t *testing.T) {
	t.Run("disabled includes configured URL", func(t *testing.T) {
		h := &ValidationHandler{
			Policy:           auth.ReferralPolicy{RequireForRegistration: false},
			RequestAccessURL: " https://access.example.test/waitlist ",
		}
		response := httptest.NewRecorder()
		h.ServeHTTP(response, httptest.NewRequest(http.MethodPost, "/v1/referrals/validate", strings.NewReader(`{"code":""}`)))
		if response.Code != http.StatusOK ||
			!strings.Contains(response.Body.String(), `"reason":"disabled"`) ||
			!strings.Contains(response.Body.String(), `"request_access_url":"https://access.example.test/waitlist"`) {
			t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
		}
	})

	t.Run("invalid omits absent URL", func(t *testing.T) {
		h := &ValidationHandler{
			Store: validationStoreFunc(func(string) (auth.ReferralValidation, error) {
				return auth.ReferralValidation{}, auth.ErrReferralInvalid
			}),
			Policy:        validationPolicy(),
			PublicLimiter: NewBoundedLimiter(10, time.Minute, 10),
		}
		response := httptest.NewRecorder()
		h.ServeHTTP(response, httptest.NewRequest(http.MethodPost, "/v1/referrals/validate", strings.NewReader(`{"code":"bad"}`)))
		if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"reason":"invalid"`) {
			t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
		}
		if strings.Contains(response.Body.String(), "request_access_url") {
			t.Fatalf("absent access URL was serialized: %s", response.Body.String())
		}
	})
}

func TestValidationHandlerFailsClosedWhenAuthorityMissing(t *testing.T) {
	h := &ValidationHandler{
		Policy:        validationPolicy(),
		PublicLimiter: NewBoundedLimiter(1, time.Minute, 1),
	}
	request := httptest.NewRequest(http.MethodPost, "/v1/referrals/validate", strings.NewReader(`{"code":"x"}`))
	response := httptest.NewRecorder()
	h.ServeHTTP(response, request)
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestValidationHandlerDoesNotMisreportOperationalFailureAsInvalidCode(t *testing.T) {
	metrics := &advocacyMetrics{}
	h := &ValidationHandler{
		Store: validationStoreFunc(func(string) (auth.ReferralValidation, error) {
			return auth.ReferralValidation{}, errors.New("database busy")
		}),
		Policy:        validationPolicy(),
		PublicLimiter: NewBoundedLimiter(1, time.Minute, 1),
		Metrics:       metrics,
	}
	response := httptest.NewRecorder()
	h.ServeHTTP(response, httptest.NewRequest(http.MethodPost, "/v1/referrals/validate", strings.NewReader(`{"code":"well-formed"}`)))
	if response.Code != http.StatusServiceUnavailable || strings.Contains(response.Body.String(), `"reason":"invalid"`) {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if !containsEvent(metrics.events, "validate/unavailable") {
		t.Fatalf("metrics=%v", metrics.events)
	}
}

func TestReferralReasonDoesNotCollapseLifecycleFailures(t *testing.T) {
	cases := map[error]string{
		auth.ErrReferralRequired:  "missing",
		auth.ErrReferralInvalid:   "invalid",
		auth.ErrReferralExpired:   "expired",
		auth.ErrReferralRevoked:   "revoked",
		auth.ErrReferralExhausted: "exhausted",
	}
	for err, want := range cases {
		if got := referralReason(errors.Join(err)); got != want {
			t.Fatalf("reason(%v)=%q want=%q", err, got, want)
		}
	}
}

func TestBoundedLimiterNeverEvictsAnActiveBucketForANewKey(t *testing.T) {
	limiter := NewBoundedLimiter(2, time.Minute, 1)
	now := time.Date(2026, 7, 13, 12, 0, 0, 0, time.UTC)
	limiter.now = func() time.Time { return now }
	if !limiter.Allow("active") || limiter.Allow("unseen") {
		t.Fatal("full limiter admitted an unseen key")
	}
	if !limiter.Allow("active") || limiter.Allow("active") {
		t.Fatal("active bucket was reset or its budget was not preserved")
	}
	now = now.Add(time.Minute)
	if !limiter.Allow("unseen") {
		t.Fatal("expired bucket was not reclaimed")
	}
}
