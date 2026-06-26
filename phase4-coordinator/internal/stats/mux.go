package stats

import (
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/stats/store"
	"github.com/rs/zerolog"
)

// Mux is the SPEC-017 §7.1 mux. Exposes
// /v1/stats/{overview,leaderboard,health} with the pinned
// 7-layer middleware stack from BUILD §2 Step 3:
//
//  1. redaction-context  (outermost — strips Authorization)
//  2. recover            (panic → 500 + structured log)
//  3. access-log/trace
//  4. auth-failure tier  (per-IP 300 rpm, Authorization-only)
//  5. auth dispatcher    (§5.4.3 7-row)
//  6. post-auth success  (public 60 rpm or partner key rpm)
//  7. handler            (overview / leaderboard / health)
//
// HEAD is added to the explicit method allowlist alongside
// GET. Go's `http.ServeMux` does NOT auto-handle HEAD; we
// dispatch HEAD identically to GET and rely on writeJSON to
// drop the body. POST / PUT / DELETE / PATCH → 405 with
// `Allow: GET, HEAD, OPTIONS` + §5.9 envelope.
type Mux struct {
	h             *Handler
	logger        zerolog.Logger
	authFailLimit *limiter
	publicLimit   *limiter
	partnerLimit  *limiter
	trustedCIDRs  []*net.IPNet
}

// NewMux constructs the SPEC-017 handler tree. The caller
// (cmd/coordinator/main.go) injects the stats_reader pool
// and the operator-tunable CORS/backfill/partial-history
// config.
func NewMux(reader *store.Store, cors CORSConfig, backfillMode, partialSince string, trustedProxies []string, logger zerolog.Logger) *Mux {
	return &Mux{
		h: &Handler{
			Store:        reader,
			CORS:         cors,
			BackfillMode: backfillMode,
			PartialSince: partialSince,
		},
		logger:        logger,
		authFailLimit: newLimiter(),
		publicLimit:   newLimiter(),
		partnerLimit:  newLimiter(),
		trustedCIDRs:  parseTrustedProxies(trustedProxies),
	}
}

// Handler returns the http.Handler the coordinator mounts on
// `/v1/stats/`. The returned handler is the full middleware
// stack — callers wrap it under their own mux registration:
//
//	mux.Handle("/v1/stats/", statsMux.Handler())
func (m *Mux) Handler() http.Handler {
	inner := http.HandlerFunc(m.dispatch)

	// Layers 1-3 wrap the entire subtree (panic recovery,
	// redaction, access logging). Layers 4-6 live inside
	// dispatch() so they have access to the per-endpoint
	// label.
	with := http.Handler(inner)
	with = accessLogMiddleware(m.logger)(with)
	with = recoverMiddleware(m.logger)(with)
	with = redactionContextMiddleware(with)
	return with
}

// dispatch is the inner-most routing layer. It performs:
//
//   - method allow-listing (GET, HEAD, OPTIONS only);
//   - OPTIONS preflight short-circuit (§5.7);
//   - endpoint extraction + 404 on unknown;
//   - layers 4-6 (auth-failure, auth dispatch, post-auth success);
//   - calls into the matching handler with the auth result.
func (m *Mux) dispatch(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		servePreflight(w, r, m.h.CORS)
		return
	}

	endpoint := trimEndpointFromPath(r.URL.Path)
	if endpoint == "" {
		// Unknown /v1/stats/* path → 404 with §5.9 envelope.
		writeError(w, http.StatusNotFound, codeBadRequest, "unknown endpoint")
		return
	}

	switch r.Method {
	case http.MethodGet, http.MethodHead:
	default:
		// Per §4.3 + AC-21: 405 with Allow header + §5.9
		// envelope. Allow header must list every accepted
		// method.
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		writeError(w, http.StatusMethodNotAllowed, codeMethodNotAllowed, "method not allowed")
		return
	}

	now := time.Now().UTC()
	ip := clientIP(r, m.trustedCIDRs)

	// Layer 4 — auth-failure tier (Authorization-present
	// requests only; reserve-then-refund on 200 partner).
	bearer, hasBearer := bearerFromContext(r.Context())
	_ = bearer
	reservedKey := ""
	if hasBearer {
		reservedKey = "authfail|" + ip + "|" + endpoint
		if !m.authFailLimit.allow(reservedKey, now, 300) {
			w.Header().Set("Retry-After", "60")
			writeError(w, http.StatusTooManyRequests, codeRateLimited, "rate limited")
			return
		}
	}

	// Layer 5 — auth dispatcher (§5.4.3).
	ar, err := dispatchAuth(r.Context(), m.h.Store, r)
	if err != nil {
		writeError(w, http.StatusInternalServerError, codeInternal, "auth dispatch failed")
		return
	}
	if ar.statusCode == http.StatusUnauthorized {
		// 401 takes the public Vary (response is not key-
		// derived). CORS headers follow the public branch.
		w.Header().Set("Vary", varyForPublic())
		writeCORSHeaders(w, false, ar.originPresent, ar.originValue)
		writeError(w, http.StatusUnauthorized, codeUnauthorized, "unauthorized")
		return
	}

	// Layer 6 — post-auth success bucket. Stale 503 responses
	// MUST NOT debit; the handler emits 503 BEFORE returning
	// to the mux so the limiter never sees it.
	var allowed bool
	switch ar.projection {
	case "partner":
		// Refund the auth-failure slot so valid keys are not
		// double-counted across the two tiers (v0.1.8
		// reserve-then-refund pattern).
		if hasBearer {
			m.authFailLimit.refund(reservedKey, now)
		}
		limit := 600
		if ar.matchedKey != nil && ar.matchedKey.RateLimitRPM > 0 {
			limit = ar.matchedKey.RateLimitRPM
		}
		key := "partner|" + strconv.FormatInt(ar.matchedKey.ID, 10) + "|" + endpoint
		allowed = m.partnerLimit.allow(key, now, limit)
	default:
		key := "public|" + ip + "|" + endpoint
		allowed = m.publicLimit.allow(key, now, 60)
	}
	if !allowed {
		w.Header().Set("Retry-After", "60")
		writeError(w, http.StatusTooManyRequests, codeRateLimited, "rate limited")
		return
	}

	// Layer 7 — handler.
	switch endpoint {
	case "overview":
		m.h.handleOverview(w, r, ar)
	case "leaderboard":
		m.h.handleLeaderboard(w, r, ar)
	case "health":
		m.h.handleHealth(w, r, ar)
	}
}

// Suppress unused warnings on shared helpers that the tests
// reach for via different paths.
var _ = strings.HasPrefix
