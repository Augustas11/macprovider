package stats

import (
	"net/http"
	"strconv"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/stats/store"
)

// SPEC §5.7 v0.1.8 — CORS preflight + per-projection rules.
//
// Preflight (OPTIONS): key-agnostic. Returns EXACTLY 204
// (NOT 200 — AC-13). Access-Control-Allow-Methods,
// Access-Control-Allow-Headers, Access-Control-Max-Age = 60
// (operator MAY raise via config to ≤300; >300 is a SPEC
// bump).
//
// `Access-Control-Allow-Origin` on preflight:
//   - Origin on global partner-origin allowlist → echoed +
//     Allow-Credentials: true.
//   - Otherwise → ACAO: * + no Allow-Credentials.
//
// On GET / HEAD:
//   - public projection (row 1)              → ACAO: * (no
//     Allow-Credentials).
//   - partner projection (rows 2, 4) with
//     Origin present                          → ACAO echoed +
//                                                 Allow-Credentials: true.
//   - partner projection server-to-server
//     (Origin absent, allowlist empty)        → OMIT ACAO entirely.
//   - 401 auth-failed responses (rows 3,5,6,7) take the
//     public Vary; CORS headers MAY echo or omit per the same
//     rules as the projection actually returned. Locked SPEC
//     ships the 401 with NO body-derived headers — Set-Cookie
//     / Allow-Credentials remain on the success path.
//
// Partner-key projection MUST NEVER use ACAO: * (CRITICAL).

// servePreflight implements the OPTIONS path for the entire
// /v1/stats/* subtree. The caller (mux dispatch) ensures
// only OPTIONS reaches here.
//
// Round-3 ARCH H1 fix: the global partner-origin allowlist is
// the UNION of (a) configured static origins (e.g.
// https://console.streamvc.live, https://portal.streamvc.live)
// AND (b) every active `partner_keys.allowed_origins` entry.
// The static-only allowlist would have rejected browser partners
// whose Origin lives only in their key row, forcing operators
// to duplicate every key origin in YAML.
func servePreflight(w http.ResponseWriter, r *http.Request, st *store.Store, cors CORSConfig) {
	maxAge := cors.AccessControlMaxAgeSeconds
	if maxAge <= 0 {
		maxAge = 60
	}
	if maxAge > 300 {
		maxAge = 300
	}
	w.Header().Set("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
	w.Header().Set("Access-Control-Max-Age", strconv.Itoa(maxAge))
	w.Header().Set("Vary", "Origin")

	norm, ok := NormalizeOrigin(r.Header.Get("Origin"))
	if ok && isOriginOnGlobalAllowlistUnion(r, norm, st, cors.PartnerOriginAllowlist) {
		w.Header().Set("Access-Control-Allow-Origin", norm)
		w.Header().Set("Access-Control-Allow-Credentials", "true")
	} else {
		w.Header().Set("Access-Control-Allow-Origin", "*")
	}
	w.WriteHeader(http.StatusNoContent)
}

// isOriginOnGlobalAllowlistUnion checks the union of the
// configured static allowlist AND the active partner_keys
// origins. The store query is best-effort — a SELECT failure
// is logged but does NOT bubble up to the client; preflight
// proceeds with the static-only allowlist in that case.
func isOriginOnGlobalAllowlistUnion(r *http.Request, normalized string, st *store.Store, static []string) bool {
	if isOriginOnGlobalAllowlist(normalized, static) {
		return true
	}
	if st == nil {
		return false
	}
	origins, err := st.ActivePartnerOrigins(r.Context())
	if err != nil {
		return false
	}
	for _, o := range origins {
		if strings.EqualFold(strings.TrimSpace(o), normalized) {
			return true
		}
	}
	return false
}

// writeCORSHeaders applies the per-projection CORS rules at GET
// response time. `partner` = true triggers the §5.7 NEVER-*
// branch. `originPresent` reflects whether the request had a
// valid Origin AFTER normalization.
//
// For partner projection:
//   - originPresent=true  → ACAO=echoed Origin + Allow-Credentials.
//   - originPresent=false → OMIT both headers.
//
// For public projection:
//   - Always ACAO: * — including for 401 auth-failed because
//     the response is not key-derived.
func writeCORSHeaders(w http.ResponseWriter, partner bool, originPresent bool, originValue string) {
	if partner {
		if originPresent {
			w.Header().Set("Access-Control-Allow-Origin", originValue)
			w.Header().Set("Access-Control-Allow-Credentials", "true")
		}
		// originPresent=false → omit ACAO entirely.
		return
	}
	w.Header().Set("Access-Control-Allow-Origin", "*")
}

// isOriginOnGlobalAllowlist checks the CORSConfig allowlist
// (operator-pinned partner origins like
// https://console.streamvc.live + https://portal.streamvc.live).
// Caller MUST normalize before calling.
func isOriginOnGlobalAllowlist(normalized string, allowlist []string) bool {
	for _, o := range allowlist {
		if strings.EqualFold(strings.TrimSpace(o), normalized) {
			return true
		}
	}
	return false
}
