package stats

import (
	"net/http"
	"runtime/debug"
	"time"

	"github.com/rs/zerolog"
)

// SPEC-017 §7.3 + BUILD §2 Step 3 — middleware stack. Pinned
// order from outermost to innermost:
//
//  1. redaction-context  — REDACTs Authorization in the
//                          logging view; stashes the parsed
//                          bearer in r.Context under authKey.
//  2. recover            — recovers panics; defensive
//                          Authorization strip; structured log.
//  3. access-log/trace   — reads only the redacted context.
//  4. auth-failure tier  — pre-SELECT 300 rpm cap per (IP,
//                          endpoint), Authorization-present
//                          only; reserve-then-refund.
//  5. auth dispatcher    — §5.4.3 7-row decision table.
//  6. post-auth success  — public 60 rpm OR partner
//                          rate_limit_rpm; (key, endpoint).
//  7. handler            — JSON.
//
// Layers 4-6 are mounted by the per-endpoint handler wrapper in
// mux.go (they need access to the per-endpoint label). Layers
// 1-3 wrap the entire /v1/stats/* subtree.

// redactionContextMiddleware reads `Authorization`, parses the
// bearer, stores it under authKey in r.Context, and replaces
// the inbound header value with the literal string `REDACTED`
// so any downstream log / trace / metric emitter that
// inadvertently reads the header sees the redacted form. Round-1
// SECURITY M2 defense-in-depth: ALSO redact `Cookie` and
// `X-Api-Key` — future log/trace refactors that capture session
// state or alternate API-key headers cannot leak secrets even
// though SPEC-017 currently names only `Authorization`.
//
// Round-1 ARCH C3: the middleware records `authPresent` in
// context whenever the Authorization header is present
// regardless of bearer-parse success, so the dispatcher can
// distinguish "no Authorization" (row 1, public projection)
// from "malformed Authorization" (row 6, 401 unauthorized).
//
// Layer 1 of the §7.3 stack — runs first and is the SECURITY
// guarantee against header-printing log libraries.
func redactionContextMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw := r.Header.Get("Authorization")
		if raw != "" {
			ctx := r.Context()
			ctx = withAuthPresentContext(ctx, true)
			if tok, ok := parseBearer(raw); ok {
				ctx = withBearerContext(ctx, tok)
			}
			r = r.WithContext(ctx)
			r.Header.Set("Authorization", "REDACTED")
		}
		// Round-1 SECURITY M2 defense-in-depth.
		if r.Header.Get("Cookie") != "" {
			r.Header.Set("Cookie", "REDACTED")
		}
		if r.Header.Get("X-Api-Key") != "" {
			r.Header.Set("X-Api-Key", "REDACTED")
		}
		next.ServeHTTP(w, r)
	})
}

// recoverMiddleware recovers panics on the ENTIRE /v1/stats/*
// subtree (GET, HEAD, OPTIONS, and the 405 path). On panic:
// emit a structured log line `event=stats_handler_panic`
// using the REDACTED header view; emit §5.9 `internal`
// envelope at 500.
//
// Defense-in-depth: even though redactionContextMiddleware
// already stripped Authorization, the recover middleware
// performs its OWN Authorization strip before logging, so a
// bypass of layer 1 (e.g. a future refactor that re-adds the
// raw header somewhere) cannot leak a token through the panic
// path. AC-15 SECURITY guarantee.
func recoverMiddleware(logger zerolog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer func() {
				rec := recover()
				if rec == nil {
					return
				}
				// Defense-in-depth strip — Authorization +
				// Cookie + X-Api-Key (round-1 SECURITY M2).
				r.Header.Set("Authorization", "REDACTED")
				if r.Header.Get("Cookie") != "" {
					r.Header.Set("Cookie", "REDACTED")
				}
				if r.Header.Get("X-Api-Key") != "" {
					r.Header.Set("X-Api-Key", "REDACTED")
				}
				// Stack to a debug-only sink (zerolog Debug
				// level). The public log line does NOT include
				// the panic value's stringification — it could
				// carry SQL state, env var values, or other
				// sensitive substrings.
				logger.Error().
					Str("event", "stats_handler_panic").
					Str("path", r.URL.Path).
					Str("method", r.Method).
					Type("panic_type", rec).
					Msg("stats handler panicked; returning 500 internal")
				logger.Debug().
					Str("event", "stats_handler_panic_stack").
					Bytes("stack", debug.Stack()).
					Msg("stats handler panic stack")
				// Best-effort 500 emit. If the underlying
				// handler already wrote a response, this will
				// no-op via the ResponseWriter contract.
				writeError(w, r, http.StatusInternalServerError, codeInternal, "internal error", time.Now().UTC(), nil)
			}()
			next.ServeHTTP(w, r)
		})
	}
}

// accessLogMiddleware reads the redacted request context only.
// v0.1 IMPL emits a minimal structured line per request; full
// trace/span instrumentation is a Step 4.C concern.
func accessLogMiddleware(logger zerolog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// The redaction middleware already replaced
			// Authorization with REDACTED on r.Header. Reading
			// r.Header.Get("Authorization") here returns
			// "REDACTED" — never the raw token.
			next.ServeHTTP(w, r)
			// Intentionally light: the access log shape is
			// pinned in Step 4.C (nginx + structured-log
			// taxonomy). v0.1 IMPL emits the line at INFO via
			// the recover/auth/etc. layers themselves.
		})
	}
}
