package session

import (
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestSetCookieHeader_ExactAttributes(t *testing.T) {
	rr := httptest.NewRecorder()
	SetCookie(rr, "sess-123")
	got := rr.Header().Get("Set-Cookie")
	if !strings.HasPrefix(got, "__Host-mp_session=sess-123;") {
		t.Fatalf("Set-Cookie %q must use the __Host- prefixed name", got)
	}
	wantParts := []string{"__Host-mp_session=sess-123", "HttpOnly", "Secure", "SameSite=Lax", "Path=/", "Max-Age=2592000"}
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
	ClearCookie(rr)
	got := rr.Header().Get("Set-Cookie")
	if !strings.HasPrefix(got, "__Host-mp_session=;") || !strings.Contains(got, "Max-Age=0") {
		t.Fatalf("clear cookie header = %q, want __Host-mp_session Max-Age=0", got)
	}
	if strings.Contains(strings.ToLower(got), "domain=") {
		t.Fatalf("clear cookie header = %q must omit Domain", got)
	}
}

func TestClearLegacyCookie_HostOnlyAndConfiguredDomain(t *testing.T) {
	rr := httptest.NewRecorder()
	ClearLegacyCookie(rr, ".example.com")
	got := rr.Header().Values("Set-Cookie")
	if len(got) != 2 {
		t.Fatalf("legacy clear headers = %q, want host-only and domain clears", got)
	}
	for _, h := range got {
		if !strings.HasPrefix(h, "mp_session=;") || !strings.Contains(h, "Max-Age=0") || !strings.Contains(h, "Path=/") {
			t.Fatalf("legacy clear header = %q", h)
		}
	}
	if strings.Contains(got[0], "Domain=") || !strings.Contains(got[1], "Domain=.example.com") {
		t.Fatalf("legacy clear headers = %q, want [host-only, Domain=.example.com]", got)
	}
}
