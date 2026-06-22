package session

import (
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestSetCookieHeader_ExactAttributes(t *testing.T) {
	rr := httptest.NewRecorder()
	SetCookie(rr, "sess-123", "")
	got := rr.Header().Get("Set-Cookie")
	wantParts := []string{"mp_session=sess-123", "HttpOnly", "Secure", "SameSite=Lax", "Path=/", "Max-Age=2592000"}
	for _, part := range wantParts {
		if !strings.Contains(got, part) {
			t.Fatalf("Set-Cookie %q missing %q", got, part)
		}
	}
	if strings.Contains(strings.ToLower(got), "domain=") {
		t.Fatalf("Set-Cookie %q must omit Domain by default", got)
	}
}

func TestSlidingSession_24hCookieReissue(t *testing.T) {
	now := time.Date(2026, 6, 21, 12, 0, 0, 0, time.UTC)
	if NeedsReissue(now.Add(-23*time.Hour), now) {
		t.Fatalf("23h-old Set-Cookie should not reissue")
	}
	if !NeedsReissue(now.Add(-25*time.Hour), now) {
		t.Fatalf("25h-old Set-Cookie should reissue")
	}
}

func TestInvalidSession_401_Plus_ClearCookie_LogoutException_204(t *testing.T) {
	rr := httptest.NewRecorder()
	ClearCookie(rr, "")
	got := rr.Header().Get("Set-Cookie")
	if !strings.Contains(got, "mp_session=") || !strings.Contains(got, "Max-Age=0") {
		t.Fatalf("clear cookie header = %q, want mp_session Max-Age=0", got)
	}
}

func TestClearCookie_IncludesConfiguredDomain(t *testing.T) {
	rr := httptest.NewRecorder()
	ClearCookie(rr, ".example.com")
	got := rr.Header().Get("Set-Cookie")
	for _, part := range []string{"mp_session=", "Path=/", "Max-Age=0", "Domain=.example.com"} {
		if !strings.Contains(got, part) {
			t.Fatalf("clear cookie header = %q missing %q", got, part)
		}
	}
}
