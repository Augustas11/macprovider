package billing

import "github.com/augstar/macprovider-coordinator/internal/jcs"

// RawJSONString is re-exported from internal/jcs so existing billing callers
// keep working; JCS canonicalization is a shared utility, not billing logic.
type RawJSONString = jcs.RawJSONString

// CanonicalJSON re-exports the shared JCS (RFC 8785) canonicalizer.
func CanonicalJSON(v any) ([]byte, error) { return jcs.CanonicalJSON(v) }

// CanonicalJSONRawStrings re-exports the shared JCS canonicalizer variant.
func CanonicalJSONRawStrings(v any) ([]byte, error) { return jcs.CanonicalJSONRawStrings(v) }

// CanonicalSHA256Hex re-exports the shared JCS canonical hash helper.
func CanonicalSHA256Hex(v any) (string, []byte, error) { return jcs.CanonicalSHA256Hex(v) }
