package stats

import (
	"crypto/sha256"
	"encoding/hex"
)

// weakETag returns the §5.1 weak ETag string for the response
// body. Format: `W/"<32-hex>"` (truncated sha256, 128 bits;
// sufficient for the request-path collision resistance §5.1
// targets). The leading `W/` marks it weak per RFC 7232.
//
// Computed once per snapshot from the response body bytes —
// the handler buffers the body, calls weakETag, sets the
// header, then writes the body or empties for HEAD.
func weakETag(body []byte) string {
	sum := sha256.Sum256(body)
	return `W/"` + hex.EncodeToString(sum[:16]) + `"`
}

// ifNoneMatchEquals does the RFC 7232 weak comparison: strip
// any `W/` prefix from both sides and compare the quoted
// portion. Returns true on match.
func ifNoneMatchEquals(ifNoneMatch, etag string) bool {
	if ifNoneMatch == "" || etag == "" {
		return false
	}
	return stripWeak(ifNoneMatch) == stripWeak(etag)
}

func stripWeak(v string) string {
	if len(v) >= 2 && (v[0] == 'W' || v[0] == 'w') && v[1] == '/' {
		return v[2:]
	}
	return v
}
