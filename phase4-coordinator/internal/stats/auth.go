package stats

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
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
		// Row 1: no Authorization — public projection.
		// Origin still normalized for CORS reflection.
		norm, valid := normalizeOrigin(r.Header.Get("Origin"))
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
	normOrigin, originValid := normalizeOrigin(rawOrigin)
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
		// Row 7: matched-but-revoked → 401.
		res.projection = "public"
		res.statusCode = http.StatusUnauthorized
		// Constant-time defense: even though we already
		// returned on `pk == nil`, the SQL SELECT did the work
		// — the time spent here is dominated by the SELECT.
		// Keep one ConstantTimeCompare touch on a known-equal
		// byte slice to ensure the branch carries the same
		// cost shape.
		_ = subtle.ConstantTimeCompare(hash[:], hash[:])
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
