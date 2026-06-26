package stats

import (
	"net/http"
	"runtime/debug"
	"strconv"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/stats/metrics"
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
				// Round-1 ARCH H1 fix: emit ONLY the locked
				// `stats_handler_panic` event with the BUILD §2
				// Step 4.C field set (`request_id`, `route`).
				// `panic_type` retained (type-only, not the
				// payload string) so dashboards can group by
				// recovered class without taking the public
				// log line beyond the locked taxonomy. The
				// `_stack` tag was widening the event surface
				// beyond the six-event contract.
				requestID := r.Header.Get("X-Request-Id")
				if requestID == "" {
					requestID = r.Header.Get("X-Correlation-Id")
				}
				logger.Error().
					Str("event", "stats_handler_panic").
					Str("route", trimEndpointFromPath(r.URL.Path)).
					Str("request_id", requestID).
					Type("panic_type", rec).
					Msg("stats handler panicked; returning 500 internal")
				// Private debug-only stack dump WITHOUT a
				// `stats_*` event tag (NOT part of the public
				// event taxonomy; intended for operator triage).
				logger.Debug().
					Bytes("stack", debug.Stack()).
					Msg("stats handler panic stack (debug-only, untagged)")
				// Best-effort 500 emit. If the underlying
				// handler already wrote a response, this will
				// no-op via the ResponseWriter contract.
				writeError(w, r, http.StatusInternalServerError, codeInternal, "internal error", time.Now().UTC(), nil)
			}()
			next.ServeHTTP(w, r)
		})
	}
}

// RecoverForTest is the exported test-only seam for AC-11
// panic-recovery integration tests. Wraps `next` in the same
// recover middleware the production mux uses, including the
// redaction-context layer (which strips Authorization /
// Cookie / X-Api-Key before the recover catches a panic).
//
// Production code MUST NOT call this — use Mux.Handler()
// instead. The seam exists so handlers_integration_test.go
// can drive the AC-11 injected-panic path without exposing
// a hook in the inner handler types.
func RecoverForTest(logger zerolog.Logger, next http.Handler) http.Handler {
	with := recoverMiddleware(logger)(next)
	return redactionContextMiddleware(with)
}

// accessLogMiddleware emits the SPEC-017 §8 v0.1.8 locked
// `stats_request_served` structured event for every request that
// reaches the /v1/stats/* mux.
//
// Step 4.C fields (per BUILD §2 Step 4.C):
//   - endpoint        — overview / leaderboard / health / "" for 404
//   - status          — final HTTP status code emitted by the stack
//   - latency_ms      — wall-clock from middleware entry to handler return
//   - generated_at_age_ms — set by handler via withGeneratedAtAgeContext (0 if unset)
//   - partner_key_id  — set by §5.4.3 dispatcher via partnerKeyIDKey (0 if unset)
//
// The event reads only the REDACTED header view (redaction
// middleware ran upstream); raw tokens, body substrings, and
// token_hash bytes are structurally unreachable from here.
func accessLogMiddleware(logger zerolog.Logger, m *metrics.Metrics) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			ctx, _ := withRequestObsContext(r.Context())
			r = r.WithContext(ctx)
			rec := &statusRecorder{ResponseWriter: w}
			next.ServeHTTP(rec, r)
			status := rec.status
			if status == 0 {
				// Panic-before-write — recover middleware
				// already emitted a 500; treat the access-log
				// event as a 500 for observability parity.
				status = http.StatusInternalServerError
			}
			endpoint := trimEndpointFromPath(r.URL.Path)
			ageMs := generatedAtAgeMsFromContext(r.Context())
			pkid := partnerKeyIDFromContext(r.Context())
			logger.Info().
				Str("event", "stats_request_served").
				Str("endpoint", endpoint).
				Str("method", r.Method).
				Int("status", status).
				Int64("latency_ms", time.Since(start).Milliseconds()).
				Int64("generated_at_age_ms", ageMs).
				Int64("partner_key_id", pkid).
				Msg("stats request served")

			// Step 4.C — Prometheus metrics. nil-safe so tests
			// using the default Mux constructor (no metrics)
			// don't have to register a registry.
			if m != nil {
				tier := "public"
				if pkid != 0 {
					tier = "partner"
				}
				// Round-1 CODE H1: the auth-failure limiter
				// reject sets a context override BEFORE this
				// middleware reads the tier; use it when
				// present so the counter labels are accurate.
				if over := tierOverrideFromContext(r.Context()); over != "" {
					tier = over
				}
				m.RequestTotal.WithLabelValues(endpoint, strconv.Itoa(status), tier).Inc()
				if pkid != 0 {
					m.PartnerKeyRequestTotal.WithLabelValues(strconv.FormatInt(pkid, 10)).Inc()
				}
				if status == http.StatusTooManyRequests {
					m.RateLimitExceededTotal.WithLabelValues(tier, endpoint).Inc()
				}
			}
		})
	}
}
