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
// `now` is the request time used for `X-Stats-Generated-At` so
// every non-304 response carries the header per BUILD §2 Step 3
// CODE r8 M2 (round-1 ARCH M3 / CODE H6).
func writeError(w http.ResponseWriter, r *http.Request, status int, code, message string, now time.Time, retryAfter *int) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Stats-Generated-At", now.UTC().Format(time.RFC3339))
	if retryAfter != nil && *retryAfter > 0 {
		// HTTP-level Retry-After header (mirrors body field for
		// clients that read headers but not body).
		w.Header().Set("Retry-After", itoaPos(*retryAfter))
	}
	w.WriteHeader(status)
	if r != nil && r.Method == http.MethodHead {
		// HEAD MUST return identical headers + empty body
		// (§4.3 + CODE r1 C1 fix).
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
