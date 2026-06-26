package stats

import (
	"net"
	"net/http"
	"strconv"
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
// Round-1 ARCH C1 / CODE H6 / SECURITY M1 fix: freshness
// pre-checks (overview/leaderboard) run BEFORE the post-auth
// success-bucket debit, so a stale 503 cannot exhaust client
// quotas.
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

func (m *Mux) Handler() http.Handler {
	inner := http.HandlerFunc(m.dispatch)
	with := http.Handler(inner)
	with = accessLogMiddleware(m.logger)(with)
	with = recoverMiddleware(m.logger)(with)
	with = redactionContextMiddleware(with)
	return with
}

// dispatch is the inner-most routing layer.
func (m *Mux) dispatch(w http.ResponseWriter, r *http.Request) {
	now := time.Now().UTC()

	if r.Method == http.MethodOptions {
		servePreflight(w, r, m.h.CORS)
		return
	}

	endpoint := trimEndpointFromPath(r.URL.Path)
	if endpoint == "" {
		writeError(w, r, http.StatusNotFound, codeBadRequest, "unknown endpoint", now, nil)
		return
	}

	switch r.Method {
	case http.MethodGet, http.MethodHead:
	default:
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		writeError(w, r, http.StatusMethodNotAllowed, codeMethodNotAllowed, "method not allowed", now, nil)
		return
	}

	ip := clientIP(r, m.trustedCIDRs)

	// Layer 4 — auth-failure tier (Authorization-present only).
	// Round-1 ARCH C3: present-but-malformed counts as
	// Authorization-present (will 401 in layer 5, debits this
	// tier).
	authHeaderPresent := authPresentFromContext(r.Context())
	reservedKey := ""
	if authHeaderPresent {
		reservedKey = "authfail|" + ip + "|" + endpoint
		if !m.authFailLimit.allow(reservedKey, now, 300) {
			retry := 60
			writeError(w, r, http.StatusTooManyRequests, codeRateLimited, "rate limited", now, &retry)
			return
		}
	}

	// Layer 5 — auth dispatcher (§5.4.3).
	ar, err := dispatchAuth(r.Context(), m.h.Store, r)
	if err != nil {
		// Auth dispatcher error → 500. Refund the auth-failure
		// reservation (round-2 CODE H2 fix — non-401 outcomes
		// MUST release the slot).
		if authHeaderPresent {
			m.authFailLimit.refund(reservedKey, now)
		}
		writeError(w, r, http.StatusInternalServerError, codeInternal, "auth dispatch failed", now, nil)
		return
	}
	if ar.statusCode == http.StatusUnauthorized {
		// Round-1 ARCH H6 / SECURITY L1 fix: rejected keyed
		// requests with non-empty allowlists / revoked / no-
		// match (rows 3, 5, 6, 7) MUST omit ACAO. The response
		// body is not key-derived; we use public Vary but DO
		// NOT echo Origin. The auth-failure tier KEEPS the
		// reservation since this is exactly the 401 case the
		// tier exists to throttle.
		w.Header().Set("Vary", varyForPublic())
		writeError(w, r, http.StatusUnauthorized, codeUnauthorized, "unauthorized", now, nil)
		return
	}

	// Round-2 CODE H2 fix: auth succeeded → refund the auth-
	// failure reservation BEFORE any subsequent error path
	// (freshness pre-check, rate-limit, handler error). Valid
	// partner-key requests that produce stale 503 / 500 must
	// not count against the auth-failure 300 rpm bucket.
	if authHeaderPresent {
		m.authFailLimit.refund(reservedKey, now)
	}

	// Round-1 ARCH C1 / CODE H6 / SECURITY M1 fix: freshness
	// pre-check BEFORE post-auth bucket debit. The 503 stale
	// path MUST NOT count against the client's success bucket
	// (a rollup outage cannot exhaust quotas for healthy
	// clients).
	if endpoint == "overview" {
		if stale, snapshotGen, perr := m.h.overviewStaleProbe(r.Context(), now); perr != nil {
			writeError(w, r, http.StatusInternalServerError, codeInternal, "overview probe failed", now, nil)
			return
		} else if stale {
			retry := 30
			writeError(w, r, http.StatusServiceUnavailable, codeStatsStale, "overview is stale", snapshotGen, &retry)
			return
		}
	} else if endpoint == "leaderboard" {
		// Handler does its own per-window probe (it needs the
		// window from query params); we just need to avoid
		// debiting the post-auth bucket if it returns 503. The
		// cleanest way is a response-status capture (below).
	}

	// Layer 6 — post-auth success bucket. Round-1 fix: use a
	// response-recording wrapper so non-2xx responses (notably
	// the leaderboard's per-window 503) refund the slot.
	rec := &statusRecorder{ResponseWriter: w}
	var allowed bool
	switch ar.projection {
	case "partner":
		limit := 600
		if ar.matchedKey != nil && ar.matchedKey.RateLimitRPM > 0 {
			limit = ar.matchedKey.RateLimitRPM
		}
		key := "partner|" + strconv.FormatInt(ar.matchedKey.ID, 10) + "|" + endpoint
		allowed = m.partnerLimit.allow(key, now, limit)
		defer func() {
			if rec.status != 0 && (rec.status < 200 || rec.status >= 300) && rec.status != http.StatusNotModified {
				m.partnerLimit.refund(key, now)
			}
		}()
	default:
		key := "public|" + ip + "|" + endpoint
		allowed = m.publicLimit.allow(key, now, 60)
		defer func() {
			if rec.status != 0 && (rec.status < 200 || rec.status >= 300) && rec.status != http.StatusNotModified {
				m.publicLimit.refund(key, now)
			}
		}()
	}
	if !allowed {
		retry := 60
		writeError(rec, r, http.StatusTooManyRequests, codeRateLimited, "rate limited", now, &retry)
		return
	}

	// Layer 7 — handler.
	switch endpoint {
	case "overview":
		m.h.handleOverview(rec, r, ar)
	case "leaderboard":
		m.h.handleLeaderboard(rec, r, ar)
	case "health":
		m.h.handleHealth(rec, r, ar)
	}
}

// statusRecorder wraps an http.ResponseWriter and remembers
// the status code so the mux can refund the post-auth bucket
// on non-2xx responses (round-1 ARCH C1 fix).
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	if s.status == 0 {
		s.status = code
	}
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusRecorder) Write(b []byte) (int, error) {
	if s.status == 0 {
		s.status = http.StatusOK
	}
	return s.ResponseWriter.Write(b)
}
