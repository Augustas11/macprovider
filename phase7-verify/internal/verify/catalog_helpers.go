package verify

import (
	"encoding/base64"
	"encoding/json"
)

// SPEC-015 §M.4 — capital-E ASCII alg string.
const catalogPubkeyAlg = "Ed25519"

// jsonUnmarshal centralizes the stdlib JSON decode for catalog
// pubkey fetches.
func jsonUnmarshal(body []byte, v any) error {
	return json.Unmarshal(body, v)
}

func decodeRawURLBase64(s string) ([]byte, error) {
	return base64.RawURLEncoding.DecodeString(s)
}
