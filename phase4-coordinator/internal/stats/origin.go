package stats

import (
	"net/url"
	"strings"

	"golang.org/x/net/idna"
)

// normalizeOrigin applies RFC 6454 ASCII serialization to a
// raw `Origin` header value per §5.7 / §5.4.3 rule 5.
//
// Returns ("", false) when the input is empty OR malformed
// (any of: trailing slash, path, query, fragment, invalid
// scheme, missing host). The handler treats `ok=false` AS IF
// the Origin header were absent — that is the lock-pinned
// branch for AC-18 row 3 timing equivalence.
//
// Returns (normalized, true) where `normalized`:
//
//   - lowercases scheme + host
//   - converts IDN host to Punycode
//   - strips default ports (`:80` for http, `:443` for https)
//   - has no path / query / fragment / trailing slash
//
// Only http and https are accepted per RFC 6454. Other schemes
// (ws, wss, file, data, custom) return ok=false.
func normalizeOrigin(raw string) (string, bool) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", false
	}
	u, err := url.Parse(raw)
	if err != nil {
		return "", false
	}
	scheme := strings.ToLower(u.Scheme)
	if scheme != "http" && scheme != "https" {
		return "", false
	}
	if u.Path != "" || u.RawQuery != "" || u.Fragment != "" {
		// Trailing slash / path / query / fragment → malformed
		// per locked §5.7 "treat as if absent". `https://x/`
		// has u.Path = "/".
		return "", false
	}
	if u.User != nil {
		return "", false
	}
	host := strings.ToLower(u.Hostname())
	if host == "" {
		return "", false
	}
	// IDN → Punycode (ASCII). idna.Lookup applies the strictest
	// profile that suits a security comparison.
	ascii, err := idna.Lookup.ToASCII(host)
	if err != nil {
		return "", false
	}
	port := u.Port()
	if port == "" {
		return scheme + "://" + ascii, true
	}
	// Strip default ports.
	if (scheme == "http" && port == "80") || (scheme == "https" && port == "443") {
		return scheme + "://" + ascii, true
	}
	return scheme + "://" + ascii + ":" + port, true
}

// originAllowed checks `normalized` against the partner-key's
// `allowed_origins` array. Empty allowlist = wildcard ("any
// Origin permitted, including absent"). Non-empty allowlist
// requires an exact normalized match. Caller MUST have
// normalized before calling.
func originAllowed(normalized string, allowlist []string) bool {
	if len(allowlist) == 0 {
		return true
	}
	for _, o := range allowlist {
		// Allowlist entries are operator-provided; treat them
		// as already-normalized per the §5.7 CLI validation
		// (Step 4.A enforces idempotent normalization on
		// `coordinator partner-keys issue --allowed-origin`).
		// Defensive lowercase here is a belt-and-braces.
		if strings.EqualFold(o, normalized) {
			return true
		}
	}
	return false
}
