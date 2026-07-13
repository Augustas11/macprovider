package referralapi

import (
	"errors"
	"html/template"
	"net/http"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

// JoinHandler serves durable invite links. It remains mounted after the gate is
// disabled so links already in circulation resolve to the open-access page.
type JoinHandler struct {
	Store            ValidationStore
	Policy           auth.ReferralPolicy
	PublicLimiter    *BoundedLimiter
	ValidateSlots    chan struct{}
	SourceIP         func(*http.Request) string
	Now              func() time.Time
	RequestAccessURL string
	ErrorLogger      func(op string, err error)
}

type joinView struct {
	Code             string
	RequestAccessURL string
}

const joinCSS = `body{margin:0;background:#101116;color:#f7f3ee;font:17px system-ui,sans-serif}main{max-width:620px;margin:10vh auto;padding:32px}h1{font-size:42px;margin:.2em 0}.card{background:#1b1d25;border-radius:18px;padding:26px}code{display:block;overflow-wrap:anywhere;background:#0b0c10;padding:12px;border-radius:8px}.actions{display:flex;gap:10px;flex-wrap:wrap;margin-top:20px}a,button{border:0;border-radius:9px;padding:12px 16px;font:inherit;font-weight:650;cursor:pointer}a{display:inline-block;background:#ff765f;color:#171717;text-decoration:none}a.secondary,button{background:#343744;color:#fff}`

var joinValidPage = template.Must(template.New("join-valid").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow"><title>You're invited to Malibu</title><style>` + joinCSS + `</style></head>
<body><main><p>Malibu pre-beta</p><h1>Put your Mac to work.</h1><div class="card"><p>You've been invited to join Malibu's private pre-beta compute network.</p>
<p>Invite code</p><code id="invite">{{.Code}}</code><div class="actions"><a href="https://download.malibu.tech/latest.dmg">Download Malibu</a><button id="copy" type="button">Copy invite code</button></div>
<p id="copied" aria-live="polite"></p><p>You choose when to launch the provider after installing Malibu.</p></div></main>
<script>document.getElementById('copy').addEventListener('click',async()=>{await navigator.clipboard.writeText(document.getElementById('invite').textContent);document.getElementById('copied').textContent='Invite code copied.'})</script></body></html>`))

var joinFullPage = template.Must(template.New("join-full").Parse(joinUnavailableDocument(
	"This invite filled up.",
	"All early-access spots on this invite have been claimed. Ask your inviter for another invite.",
)))

var joinExpiredPage = template.Must(template.New("join-expired").Parse(joinUnavailableDocument(
	"This invite is no longer available.",
	"This invite has expired. Ask your inviter for another invite.",
)))

var joinRevokedPage = template.Must(template.New("join-revoked").Parse(joinUnavailableDocument(
	"This invite is no longer available.",
	"This invite is no longer active. Ask your inviter for another invite.",
)))

var joinInvalidPage = template.Must(template.New("join-invalid").Parse(joinUnavailableDocument(
	"This invite link isn't valid.",
	"Check the link with your inviter or request access to Malibu's pre-beta.",
)))

func joinUnavailableDocument(title, message string) string {
	return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><title>Malibu pre-beta invite</title><style>` + joinCSS + `</style></head><body><main><p>Malibu pre-beta</p><h1>` + title + `</h1><div class="card"><p>` + message + `</p><div class="actions">{{if .RequestAccessURL}}<a href="{{.RequestAccessURL}}">Request access</a>{{end}}<a class="secondary" href="https://malibu.tech">Learn more about Malibu</a></div></div></main></body></html>`
}

var joinUnavailablePage = template.Must(template.New("join-unavailable").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><title>Malibu pre-beta invite</title><style>` + joinCSS + `</style></head>
<body><main><p>Malibu pre-beta</p><h1>We couldn't check this invite.</h1><div class="card"><p>Something went wrong on our side. Please try again in a moment.</p><div class="actions"><a href="https://malibu.tech">Learn more about Malibu</a></div></div></main></body></html>`))

var joinOpenBetaPage = template.Must(template.New("join-open").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><title>Malibu</title><style>` + joinCSS + `</style></head>
<body><main><p>Malibu</p><h1>Put your Mac to work.</h1><div class="card"><p>Malibu is open. You don't need an invite code.</p><div class="actions"><a href="https://download.malibu.tech/latest.dmg">Download Malibu</a><a class="secondary" href="https://malibu.tech">Learn more about Malibu</a></div></div></main></body></html>`))

func (h *JoinHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h.setHeaders(w)
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	code, ok := joinCode(r.URL.Path)
	if !ok {
		http.NotFound(w, r)
		return
	}
	if !h.Policy.RequireForRegistration {
		h.render(w, r, http.StatusOK, joinOpenBetaPage, joinView{})
		return
	}
	if h.Store == nil {
		h.renderOperationalFailure(w, r, errors.New("referral authority unavailable"))
		return
	}
	if h.ValidateSlots != nil {
		select {
		case h.ValidateSlots <- struct{}{}:
			defer func() { <-h.ValidateSlots }()
		default:
			h.renderOperationalFailure(w, r, errors.New("referral authority busy"))
			return
		}
	}
	if !h.allow(r) {
		w.Header().Set("Retry-After", "60")
		http.Error(w, "too many invite checks", http.StatusTooManyRequests)
		return
	}

	_, err := h.Store.ValidateReferral(r.Context(), h.Policy, code, h.now())
	view := joinView{RequestAccessURL: strings.TrimSpace(h.RequestAccessURL)}
	switch {
	case errors.Is(err, auth.ErrReferralExhausted):
		h.render(w, r, http.StatusOK, joinFullPage, view)
	case errors.Is(err, auth.ErrReferralExpired):
		h.render(w, r, http.StatusOK, joinExpiredPage, view)
	case errors.Is(err, auth.ErrReferralRevoked):
		h.render(w, r, http.StatusOK, joinRevokedPage, view)
	case errors.Is(err, auth.ErrReferralInvalid), errors.Is(err, auth.ErrReferralRequired):
		h.render(w, r, http.StatusNotFound, joinInvalidPage, view)
	case err != nil:
		h.renderOperationalFailure(w, r, err)
	default:
		view.Code = code
		h.render(w, r, http.StatusOK, joinValidPage, view)
	}
}

func (h *JoinHandler) setHeaders(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'none'; img-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("X-Frame-Options", "DENY")
}

func (h *JoinHandler) allow(r *http.Request) bool {
	key := r.RemoteAddr
	if h.SourceIP != nil {
		key = h.SourceIP(r)
	}
	return h.PublicLimiter != nil && h.PublicLimiter.Allow("join:"+key)
}

func joinCode(path string) (string, bool) {
	if !strings.HasPrefix(path, "/j/") {
		return "", false
	}
	code := strings.TrimPrefix(path, "/j/")
	return code, code != "" && len(code) <= 256 && !strings.Contains(code, "/")
}

func (h *JoinHandler) renderOperationalFailure(w http.ResponseWriter, r *http.Request, err error) {
	if h.ErrorLogger != nil {
		h.ErrorLogger("join_validate", err)
	}
	w.Header().Set("Retry-After", "5")
	h.render(w, r, http.StatusServiceUnavailable, joinUnavailablePage, joinView{})
}

func (h *JoinHandler) render(w http.ResponseWriter, r *http.Request, status int, page *template.Template, view joinView) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	if r.Method == http.MethodHead {
		return
	}
	_ = page.Execute(w, view)
}

func (h *JoinHandler) now() time.Time {
	if h.Now != nil {
		return h.Now().UTC()
	}
	return time.Now().UTC()
}
