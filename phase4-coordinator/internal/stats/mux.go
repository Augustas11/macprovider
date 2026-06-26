package stats

import (
	"net"
	"net/http"
	"strconv"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/stats/metrics"
	"github.com/augstar/macprovider-coordinator/internal/stats/store"
	"github.com/rs/zerolog"
)

// Mux is the SPEC-017 §7.1 mux. Exposes
// /v1/stats/{overview,leaderboard,health}.
//
// SPEC §4.3 auth scoping (round-3 ARCH C1 fix):
//
//	/overview      — Auth: None (Authorization IGNORED).
//	/leaderboard   — Auth: optional Bearer <partner_key>;
//	                 §5.4.3 7-row decision table applies.
//	/health        — Auth: None.
//
// Only `/v1/stats/leaderboard` runs the auth-failure tier and
// the §5.4.3 dispatcher. `/overview` and `/health` get a
// synthesized public authResult so they emit public-tier CORS
// + Vary regardless of what the request Authorization header
// looks like.
type Mux struct {
	h             *Handler
	logger        zerolog.Logger
	authFailLimit *limiter
	publicLimit   *limiter
	partnerLimit  *limiter
	trustedCIDRs  []*net.IPNet
	metrics       *metrics.Metrics // optional; nil → no metric emit
}

func NewMux(reader *store.Store, cors CORSConfig, backfillMode, partialSince string, trustedProxies []string, logger zerolog.Logger) *Mux {
	return NewMuxWithMetrics(reader, cors, backfillMode, partialSince, trustedProxies, logger, nil)
}

// NewMuxWithMetrics is the Step 4.C constructor that accepts an
// optional metrics handle. Tests that don't need metric assertions
// can call NewMux for the nil-metrics behavior; production wires
// the coordinator-owned Metrics from main.go.
func NewMuxWithMetrics(reader *store.Store, cors CORSConfig, backfillMode, partialSince string, trustedProxies []string, logger zerolog.Logger, m *metrics.Metrics) *Mux {
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
		metrics:       m,
	}
}

func (m *Mux) Handler() http.Handler {
	inner := http.HandlerFunc(m.dispatch)
	with := http.Handler(inner)
	with = accessLogMiddleware(m.logger, m.metrics)(with)
	with = recoverMiddleware(m.logger)(with)
	with = redactionContextMiddleware(with)
	return with
}

func (m *Mux) dispatch(w http.ResponseWriter, r *http.Request) {
	now := time.Now().UTC()

	if r.Method == http.MethodOptions {
		servePreflight(w, r, m.h.Store, m.h.CORS)
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

	// Round-3 ARCH C1 fix: only /leaderboard runs the
	// auth-failure tier + §5.4.3 dispatcher. /overview and
	// /health are §4.3 `Auth: None`; Authorization is ignored.
	var ar authResult
	if endpoint == "leaderboard" {
		// Layer 4 — auth-failure tier (Authorization-present
		// only). Round-3 CODE H1: only schedule the refund
		// AFTER allow returns true.
		authHeaderPresent := authPresentFromContext(r.Context())
		reservedKey := ""
		if authHeaderPresent {
			reservedKey = "authfail|" + ip + "|" + endpoint
			if !m.authFailLimit.allow(reservedKey, now, 300) {
				retry := 60
				// Round-1 CODE H1 fix: tag the request as
				// auth-failure tier so the access-log middleware
				// labels the rate_limit_exceeded counter
				// correctly. Without this the 429 lands as
				// `tier="public"` and dashboards can't
				// distinguish auth-failure floods from public
				// quota exhaustion.
				r = r.WithContext(withTierOverrideContext(r.Context(), "auth_failure"))
				writeError(w, r, http.StatusTooManyRequests, codeRateLimited, "rate limited", now, &retry)
				return
			}
		}

		// Layer 5 — auth dispatcher.
		var err error
		ar, err = dispatchAuth(r.Context(), m.h.Store, r)
		if err != nil {
			if authHeaderPresent {
				m.authFailLimit.refund(reservedKey, now)
			}
			writeError(w, r, http.StatusInternalServerError, codeInternal, "auth dispatch failed", now, nil)
			return
		}
		if ar.statusCode == http.StatusUnauthorized {
			// Rejected keyed — omit ACAO per §5.7 rows 3/5/6/7.
			w.Header().Set("Vary", varyForPublic())
			writeError(w, r, http.StatusUnauthorized, codeUnauthorized, "unauthorized", now, nil)
			return
		}
		// Auth succeeded — release the auth-failure slot before
		// any subsequent error path can keep the reservation
		// against a valid partner key.
		if authHeaderPresent {
			m.authFailLimit.refund(reservedKey, now)
		}
		// Round-3 CODE H2: tag the request context with the
		// projection so writeError picks the partner Cache-
		// Control / Vary row for post-auth errors.
		if ar.projection == "partner" {
			ctx := withPartnerProjectionContext(r.Context())
			if ar.matchedKey != nil {
				// Step 4.C `stats_request_served` event needs the
				// matched partner_keys.id; the access-log
				// middleware reads this via partnerKeyIDFromContext.
				ctx = withPartnerKeyIDContext(ctx, ar.matchedKey.ID)
			}
			r = r.WithContext(ctx)
		}
	} else {
		// /overview + /health: synthesize a public authResult
		// with normalized Origin for CORS reflection. The
		// Authorization header (if any) is IGNORED.
		norm, valid := NormalizeOrigin(r.Header.Get("Origin"))
		ar = authResult{
			projection:    "public",
			statusCode:    0,
			originPresent: valid,
			originValue:   norm,
			bearerPresent: false,
		}
	}

	// Round-1 freshness pre-check for overview (must run BEFORE
	// post-auth success-bucket debit).
	if endpoint == "overview" {
		if stale, snapshotGen, perr := m.h.overviewStaleProbe(r.Context(), now); perr != nil {
			writeError(w, r, http.StatusInternalServerError, codeInternal, "overview probe failed", now, nil)
			return
		} else if stale {
			retry := 30
			writeError(w, r, http.StatusServiceUnavailable, codeStatsStale, "overview is stale", snapshotGen, &retry)
			return
		}
	}

	// Layer 6 — post-auth success bucket. Round-3 CODE H1 fix:
	// only schedule the refund AFTER allow returned true; a
	// rejected bucket call must NOT decrement the existing
	// count on the 429 path.
	rec := &statusRecorder{ResponseWriter: w}
	var allowed bool
	var refundKey string
	var refundLimiter *limiter
	switch ar.projection {
	case "partner":
		limit := 600
		if ar.matchedKey != nil && ar.matchedKey.RateLimitRPM > 0 {
			limit = ar.matchedKey.RateLimitRPM
		}
		key := "partner|" + strconv.FormatInt(ar.matchedKey.ID, 10) + "|" + endpoint
		allowed = m.partnerLimit.allow(key, now, limit)
		if allowed {
			refundKey = key
			refundLimiter = m.partnerLimit
		}
	default:
		key := "public|" + ip + "|" + endpoint
		allowed = m.publicLimit.allow(key, now, 60)
		if allowed {
			refundKey = key
			refundLimiter = m.publicLimit
		}
	}
	if !allowed {
		retry := 60
		writeError(w, r, http.StatusTooManyRequests, codeRateLimited, "rate limited", now, &retry)
		return
	}
	defer func() {
		// Refund the success-bucket slot if the handler did
		// NOT return a 2xx (and not 304). 503 stale, 500
		// internal, 400 bad-request from inside the handler
		// must not count against the success bucket. Round-4
		// SECURITY M1 fix: `rec.status == 0` also means the
		// handler panicked before writing a status — the
		// outer recover middleware will emit a 500, so this
		// path is non-success and the slot MUST be refunded.
		if rec.status == 0 {
			refundLimiter.refund(refundKey, now)
			return
		}
		if (rec.status < 200 || rec.status >= 300) && rec.status != http.StatusNotModified {
			refundLimiter.refund(refundKey, now)
		}
	}()

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
// on non-2xx responses.
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

// AuthFailureCountForTest returns the auth-failure tier
// bucket count for (ip, endpoint) at `now`. Exported only
// for round-7 CODE M coverage of the reserve-then-refund
// invariant. Production MUST NOT call this.
func (m *Mux) AuthFailureCountForTest(ip, endpoint string, now time.Time) int {
	return m.authFailLimit.CountForTest("authfail|"+ip+"|"+endpoint, now)
}
