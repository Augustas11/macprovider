package stats

import (
	"context"
	"crypto/sha256"
	"net/http"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/stats/store"
)

// SPEC §5.4.3 partner-key authn dispatcher — 7-row decision
// table. Returns the authentication outcome the rest of the
// handler stack uses to pick the response projection.

// authKey is the unexported context key under which the
// redaction middleware stashes the parsed Bearer token. Using
// a typed struct value prevents cross-package retrieval.
type authKey struct{}

// authPresentKey marks the request as carrying an
// Authorization header (regardless of whether the bearer
// parsed). Round-1 ARCH C3 fix — the dispatcher must
// distinguish absent Authorization (row 1, public) from
// malformed Authorization (row 6, 401).
type authPresentKey struct{}

func withAuthPresentContext(ctx context.Context, present bool) context.Context {
	return context.WithValue(ctx, authPresentKey{}, present)
}

func authPresentFromContext(ctx context.Context) bool {
	v, _ := ctx.Value(authPresentKey{}).(bool)
	return v
}

// projectionKey marks the request as carrying a partner-key
// projection after a successful §5.4.3 row 2 / row 4 auth.
// writeError reads this to pick the partner Cache-Control /
// Vary row for post-auth errors (round-3 CODE H2 fix).
type projectionKey struct{}

func withPartnerProjectionContext(ctx context.Context) context.Context {
	return context.WithValue(ctx, projectionKey{}, true)
}

func partnerProjectionFromContext(ctx context.Context) bool {
	v, _ := ctx.Value(projectionKey{}).(bool)
	return v
}

// partnerKeyIDFromContext reads the matched partner_keys.id
// from the mutable observability struct. Round-2 CODE H1 fix:
// the value lives in `requestObs.PartnerKeyID`, NOT in a
// separate immutable context value, so the outer access-log
// middleware (which holds the original request) can observe
// dispatcher updates.
func partnerKeyIDFromContext(ctx context.Context) int64 {
	obs := requestObsFromContext(ctx)
	if obs == nil {
		return 0
	}
	return obs.PartnerKeyID
}

// requestObs is a mutable per-request observability struct
// stored as a pointer in r.Context. Handlers + the mux
// dispatcher write into it; the outer access-log middleware
// reads it AFTER `next.ServeHTTP` returns. Pointer semantics
// let the middleware see updates even though the http.Request
// value it holds is immutable through r.WithContext chains.
//
// Round-2 CODE H1 fix: PartnerKeyID and TierOverride also live
// on this struct (not in separate immutable context values)
// because the dispatcher does `r = r.WithContext(...)` on its
// local r — the outer access-log middleware's r still points
// at the parent context. The pointer-in-context pattern is
// the only way to propagate observability back out.
type requestObs struct {
	GeneratedAtAgeMs int64
	PartnerKeyID     int64
}

type requestObsKey struct{}

func withRequestObsContext(ctx context.Context) (context.Context, *requestObs) {
	obs := &requestObs{}
	return context.WithValue(ctx, requestObsKey{}, obs), obs
}

func requestObsFromContext(ctx context.Context) *requestObs {
	v, _ := ctx.Value(requestObsKey{}).(*requestObs)
	return v
}

func generatedAtAgeMsFromContext(ctx context.Context) int64 {
	obs := requestObsFromContext(ctx)
	if obs == nil {
		return 0
	}
	return obs.GeneratedAtAgeMs
}

// authResult bundles the §5.4.3 dispatch outcome.
type authResult struct {
	// projection picks the response shape. One of:
	//   "public"  — no Authorization OR auth-failed; emit
	//               the public projection (row 1).
	//   "partner" — valid key, allowlist matched OR allowlist
	//               empty (rows 2, 4).
	projection string

	// statusCode is 0 for the success / public-projection
	// paths, or 401 for rows 3, 5, 6, 7.
	statusCode int

	// matchedKey is the row from `partner_keys` when
	// projection = "partner". Nil otherwise.
	matchedKey *store.PartnerKey

	// originPresent tracks whether the Origin header was
	// present-and-valid AFTER normalization. Used by the
	// CORS response writer + the Vary picker.
	originPresent bool
	originValue   string

	// bearerPresent reports whether the request carried an
	// Authorization header that parsed as a Bearer token. Used
	// to pick `Vary` on auth-failed 401 responses (public Vary
	// since the response body is not key-derived).
	bearerPresent bool
}

// parseBearer extracts the token following `Bearer ` (case-
// insensitive on the scheme per RFC 6750 §2.1). Returns the
// raw token + a present flag. The token is bytes-equivalent to
// the operator-issued opaque string; do NOT trim, lowercase, or
// otherwise transform.
//
// Reverted from the standard "scheme + space" parse to permit
// the SPEC test fixtures that send `Bearer<SPACE><token>` with
// no further whitespace.
func parseBearer(h string) (string, bool) {
	const scheme = "bearer"
	if len(h) < len(scheme)+1 {
		return "", false
	}
	if !strings.EqualFold(h[:len(scheme)], scheme) {
		return "", false
	}
	rest := h[len(scheme):]
	if rest == "" || (rest[0] != ' ' && rest[0] != '\t') {
		return "", false
	}
	tok := strings.TrimLeft(rest, " \t")
	if tok == "" {
		return "", false
	}
	return tok, true
}

// withBearerContext stores the parsed Bearer token in the
// request context under the unexported authKey. The auth
// dispatcher retrieves it; downstream code never sees the raw
// token.
func withBearerContext(ctx context.Context, token string) context.Context {
	return context.WithValue(ctx, authKey{}, token)
}

// bearerFromContext is the dispatcher's accessor.
func bearerFromContext(ctx context.Context) (string, bool) {
	v, ok := ctx.Value(authKey{}).(string)
	return v, ok
}

// dispatchAuth implements §5.4.3 rows 1-7. The caller MUST have
// already (a) stashed the bearer in r.Context (redaction
// middleware) and (b) reserved the auth-failure slot when the
// bearer was present (auth-failure middleware). This function
// performs the sha256 + SELECT and returns the outcome.
//
// Timing equivalence (AC-18 + v0.1.7 rule 4): rows 3, 5, 6, 7
// all perform the sha256 + SELECT BEFORE branching on Origin /
// row presence / revocation. No early return on prefix or
// missing row.
func dispatchAuth(ctx context.Context, st *store.Store, r *http.Request) (authResult, error) {
	bearer, ok := bearerFromContext(ctx)
	if !ok || bearer == "" {
		// Origin normalized for CORS reflection.
		norm, valid := NormalizeOrigin(r.Header.Get("Origin"))
		if authPresentFromContext(ctx) {
			// Round-1 ARCH C3 fix: Authorization header is
			// present but failed to parse as Bearer — this is
			// a malformed credential, NOT row 1. Treat as
			// row 6 (no matching key) → 401.
			return authResult{
				projection:    "public",
				statusCode:    http.StatusUnauthorized,
				originPresent: valid,
				originValue:   norm,
				bearerPresent: true,
			}, nil
		}
		// Row 1: no Authorization — public projection.
		return authResult{
			projection:    "public",
			statusCode:    0,
			originPresent: valid,
			originValue:   norm,
			bearerPresent: false,
		}, nil
	}

	// Authorization present. Compute hash + SELECT
	// unconditionally; do NOT branch on Origin / prefix yet.
	hash := sha256.Sum256([]byte(bearer))
	pk, err := st.LookupPartnerKeyByHash(ctx, hash[:])
	if err != nil {
		return authResult{}, err
	}

	rawOrigin := r.Header.Get("Origin")
	normOrigin, originValid := NormalizeOrigin(rawOrigin)
	res := authResult{
		bearerPresent: true,
		originPresent: originValid,
		originValue:   normOrigin,
	}

	if pk == nil {
		// Row 6: no matching row → 401.
		res.projection = "public"
		res.statusCode = http.StatusUnauthorized
		return res, nil
	}
	if pk.RevokedAt.Valid {
		// Row 7: matched-but-revoked → 401. Round-1 CODE M3
		// fix: removed the no-op ConstantTimeCompare touch —
		// the timing equivalence guarantee is delivered by the
		// shared `sha256 + SELECT by token_hash` work above
		// (DB SELECT dominates branch cost), not by a sentinel
		// compare. AC-18 statistical test verifies rows 5/6/7
		// share the same latency band.
		res.projection = "public"
		res.statusCode = http.StatusUnauthorized
		return res, nil
	}

	// Active key. Origin allowlist check now (post-SELECT).
	if len(pk.AllowedOrigins) > 0 {
		if !originValid {
			// Row 3: allowlist non-empty + Origin absent /
			// malformed → 401 (same hash+SELECT work as
			// rows 5, 6, 7).
			res.projection = "public"
			res.statusCode = http.StatusUnauthorized
			return res, nil
		}
		if !originAllowed(normOrigin, pk.AllowedOrigins) {
			// Row 5: Origin not in allowlist → 401.
			res.projection = "public"
			res.statusCode = http.StatusUnauthorized
			return res, nil
		}
	}

	// Row 2 (allowlist empty) or row 4 (allowlist match):
	// success — partner projection.
	res.projection = "partner"
	res.statusCode = 0
	res.matchedKey = pk
	return res, nil
}
