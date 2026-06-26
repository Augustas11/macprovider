package stats

import (
	"encoding/json"
	"net/http"
)

// §5.9 closed error code vocabulary. The IMPL author MUST NOT
// introduce new codes outside this list.
const (
	codeBadRequest       = "bad_request"
	codeUnauthorized     = "unauthorized"
	codeMethodNotAllowed = "method_not_allowed"
	codeRateLimited      = "rate_limited"
	codeStatsStale       = "stats_stale"
	codeInternal         = "internal"
)

// errorEnvelope is the §5.9 wire shape. `Detail` is a short
// human-readable hint; the IMPL author MUST NEVER place
// SQL state, stack frames, environment vars, DSN substrings,
// host names, internal IPs, raw tokens, token_hash, or origin
// strings into Detail.
type errorEnvelope struct {
	Error errorBody `json:"error"`
}

type errorBody struct {
	Code   string `json:"code"`
	Detail string `json:"detail,omitempty"`
}

// writeError emits a §5.9 envelope at the given HTTP status.
// The 304 path MUST bypass this — 304 carries only the RFC 7232
// headers and an empty body.
func writeError(w http.ResponseWriter, status int, code, detail string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	// json.Encoder.Encode writes a trailing newline; tolerated
	// per §5.9 — the JSON object shape is the contract, not
	// the byte-for-byte body.
	_ = json.NewEncoder(w).Encode(errorEnvelope{Error: errorBody{Code: code, Detail: detail}})
}
