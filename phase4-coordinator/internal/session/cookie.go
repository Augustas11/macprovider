package session

import (
	"net/http"
	"strings"
	"time"
)

// Name is the portal session cookie. The __Host- prefix makes browsers
// refuse it unless it is Secure, Path=/ and carries no Domain, so a sibling
// subdomain cannot plant or overwrite it (SPEC-014 v0.11).
const Name = "__Host-mp_session"

// LegacyName is the pre-v0.11 cookie. It never authenticates; the coordinator
// clears it on sight.
const LegacyName = "mp_session"

const MaxAgeSeconds = 2592000

func SetCookie(w http.ResponseWriter, id string) {
	w.Header().Add("Set-Cookie", Name+"="+id+"; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=2592000")
}

func ClearCookie(w http.ResponseWriter) {
	w.Header().Add("Set-Cookie", Name+"=; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0")
}

// ClearLegacyCookie expires the legacy cookie host-only and, when the
// deployment once configured a cookie domain, at that domain too.
func ClearLegacyCookie(w http.ResponseWriter, domain string) {
	base := LegacyName + "=; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0"
	w.Header().Add("Set-Cookie", base)
	if d := strings.TrimSpace(domain); d != "" {
		w.Header().Add("Set-Cookie", base+"; Domain="+d)
	}
}

// HasLegacyCookie reports whether the request still carries the legacy cookie.
func HasLegacyCookie(r *http.Request) bool {
	_, err := r.Cookie(LegacyName)
	return err == nil
}

func NeedsReissue(lastSet time.Time, now time.Time) bool {
	return lastSet.IsZero() || now.Sub(lastSet) >= 24*time.Hour
}
