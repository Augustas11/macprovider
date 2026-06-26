package stats

import (
	"encoding/json"
	"net/http"
	"time"
)

// §5.9 closed error code vocabulary. The IMPL author MUST NOT
// introduce new codes outside this list.
const (
	codeBadRequest       = "bad_request"
	codeUnauthorized     = "unauthorized"
	codeMethodNotAllowed = "method_not_allowed"
	codeRateLimited      = "rate_limited"
	codeStatsStale       = "stats_stale"
	codeInternal         = "internal"
)

// errorEnvelope is the §5.9 wire shape:
//
//	{"error":{"code":..., "message":..., "retry_after_seconds":...}}
//
// `retry_after_seconds` is OPTIONAL and present only for
// `rate_limited` + `stats_stale` per §5.9. `message` is the
// human-readable string; the IMPL author MUST NEVER place SQL
// state, stack frames, environment vars, DSN substrings, host
// names, internal IPs, raw tokens, token_hash, or origin
// strings into Message.
type errorEnvelope struct {
	Error errorBody `json:"error"`
}

type errorBody struct {
	Code              string `json:"code"`
	Message           string `json:"message"`
	RetryAfterSeconds *int   `json:"retry_after_seconds,omitempty"`
}

// writeError emits a §5.9 envelope. The HEAD path drops the
// body bytes per §4.3 (CRITICAL per round-1 CODE C1). 304 is
// a separate path and never goes through this writer.
//
// Round-2 CODE H1 fix: writeError now derives the response's
// Cache-Control + Vary from the request path, so every non-304
// `/v1/stats/*` error response carries the endpoint's locked
// header row instead of a blanket `no-store`. The locked SPEC
// header table applies to BOTH success and error responses;
// §5.9 exempts only 304 from carrying a JSON body, not the
// per-endpoint Cache-Control.
//
// `now` is the request time used for `X-Stats-Generated-At` so
// every non-304 response carries the header per BUILD §2 Step 3
// CODE r8 M2 (round-1 ARCH M3 / CODE H6).
func writeError(w http.ResponseWriter, r *http.Request, status int, code, message string, now time.Time, retryAfter *int) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	cc, vary := errorHeadersForRequest(r, status)
	w.Header().Set("Cache-Control", cc)
	w.Header().Set("Vary", vary)
	w.Header().Set("X-Stats-Generated-At", now.UTC().Format(time.RFC3339))
	if retryAfter != nil && *retryAfter > 0 {
		w.Header().Set("Retry-After", itoaPos(*retryAfter))
	}
	w.WriteHeader(status)
	if r != nil && r.Method == http.MethodHead {
		return
	}
	buf, _ := json.Marshal(errorEnvelope{Error: errorBody{
		Code:              code,
		Message:           message,
		RetryAfterSeconds: retryAfter,
	}})
	_, _ = w.Write(buf)
	_, _ = w.Write([]byte{'\n'})
}

// errorHeadersForRequest picks the Cache-Control + Vary row
// that matches the request's endpoint AND projection. Errors
// carry the same row as the corresponding endpoint success
// response so the edge cache key is stable across stale-503,
// rate-limit-429, bad-request-400 and the eventual 200 from
// the same path.
//
// Round-3 CODE H2 fix: post-auth partner-key requests that
// produce 4xx/5xx errors after the dispatcher succeeded MUST
// use the partner Cache-Control row (`private, max-age=30,
// s-maxage=30`) + partner Vary (`Accept-Encoding, Origin,
// Authorization`). The mux tags r.Context with the partner
// projection marker after dispatchAuth returns success; the
// auth-failed 401 path leaves the marker unset and falls
// through to the public row.
//
// Public projection is used for: row 1 anonymous, any 4xx/5xx
// before/during auth dispatch (including 401), and all error
// paths on /overview + /health (which are §4.3 Auth: None).
func errorHeadersForRequest(r *http.Request, status int) (string, string) {
	if r == nil {
		return "no-store", "Accept-Encoding, Origin"
	}
	partner := partnerProjectionFromContext(r.Context())
	switch trimEndpointFromPath(r.URL.Path) {
	case "overview":
		return "public, max-age=30, s-maxage=30, stale-while-revalidate=60",
			"Accept-Encoding, Origin"
	case "leaderboard":
		if partner {
			return "private, max-age=30, s-maxage=30",
				"Accept-Encoding, Origin, Authorization"
		}
		return "public, max-age=60, s-maxage=60, stale-while-revalidate=120",
			"Accept-Encoding, Origin"
	case "health":
		return "public, max-age=10, s-maxage=10",
			"Accept-Encoding, Origin"
	}
	return "no-store", "Accept-Encoding, Origin"
}

// itoaPos is a tiny positive-int → string helper that avoids
// pulling in strconv at this seam (we already import strconv
// elsewhere; keeping the dependency-graph annotation tidy in
// reviews).
func itoaPos(n int) string {
	if n <= 0 {
		return "0"
	}
	if n < 10 {
		return string(rune('0' + n))
	}
	// strconv path for multi-digit.
	buf := make([]byte, 0, 12)
	for n > 0 {
		buf = append([]byte{byte('0' + n%10)}, buf...)
		n /= 10
	}
	return string(buf)
}

// errorRetry returns a *int for the §5.9 envelope's
// retry_after_seconds field. Use this helper to keep the
// optional-int idiom uniform at call sites.
func errorRetry(s int) *int { return &s }
