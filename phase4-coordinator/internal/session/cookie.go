package session

import (
	"fmt"
	"net/http"
	"strings"
	"time"
)

const Name = "mp_session"
const MaxAgeSeconds = 2592000

func SetCookie(w http.ResponseWriter, id, domain string) {
	header := fmt.Sprintf("mp_session=%s; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=2592000", id)
	if strings.TrimSpace(domain) != "" {
		header += "; Domain=" + strings.TrimSpace(domain)
	}
	w.Header().Add("Set-Cookie", header)
}

func ClearCookie(w http.ResponseWriter, domain string) {
	header := "mp_session=; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0"
	if strings.TrimSpace(domain) != "" {
		header += "; Domain=" + strings.TrimSpace(domain)
	}
	w.Header().Add("Set-Cookie", header)
}

func NeedsReissue(lastSet time.Time, now time.Time) bool {
	return lastSet.IsZero() || now.Sub(lastSet) >= 24*time.Hour
}
