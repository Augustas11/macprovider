package spec015

import (
	"bytes"
	"encoding/json"
	"fmt"
	"sort"
)

// IndependentTupleCanonicalForm re-encodes a SPEC-015 receipt tuple using
// an independent canonicalization path (Go json + manual sort), then
// compares against the buyer-observed tupleData bytes. Architect audit
// round 1 flagged that the Go verifier treats tupleData as opaque, so a
// future Swift-side canonicalization regression (key-sort drift, missing
// field, accidental whitespace) would re-sign correctly and self-verify
// but diverge from a strict third-party verifier with no in-tree signal.
//
// This implementation does NOT re-derive prompt_hash / output_hash (that
// would require running the full request/response through a Go-side JCS
// implementation — v0.2 work). It DOES bind that the seven required
// fields are present, sorted, and round-trip byte-equal under a second
// implementation of the §4.3 tuple shape.
func IndependentTupleCanonicalForm(tupleData []byte) ([]byte, error) {
	var tuple map[string]any
	if err := json.Unmarshal(tupleData, &tuple); err != nil {
		return nil, fmt.Errorf("tuple decode: %w", err)
	}
	if err := requireReceiptTupleShape(tuple); err != nil {
		return nil, err
	}
	keys := make([]string, 0, len(tuple))
	for k := range tuple {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	var buf bytes.Buffer
	buf.WriteByte('{')
	for i, key := range keys {
		if i > 0 {
			buf.WriteByte(',')
		}
		keyBytes, err := marshalJSONNoHTMLEscape(key)
		if err != nil {
			return nil, fmt.Errorf("encode tuple key %s: %w", key, err)
		}
		buf.Write(keyBytes)
		buf.WriteByte(':')
		valBytes, err := canonicalTupleValue(tuple[key])
		if err != nil {
			return nil, fmt.Errorf("encode tuple value for %s: %w", key, err)
		}
		buf.Write(valBytes)
	}
	buf.WriteByte('}')
	return buf.Bytes(), nil
}

// canonicalTupleValue handles the closed shape of v0.1.x receipt tuples
// (string and int fields only — §4.3). Non-integer numbers are rejected
// because the SPEC pins ttft_ms / tokens_out / unix_ts as int64.
//
// Strings are encoded WITHOUT Go's default HTML escaping (<, >, &,
// U+2028, U+2029 stay as raw UTF-8) so the byte stream matches the
// Swift-side RFC 8785 §3.2.2.2 string escape rules. Otherwise this
// "independent" canonicalizer would falsely fail the drift check on
// any v0.2 string field carrying those characters even when Swift was
// emitting RFC-correct bytes.
func canonicalTupleValue(v any) ([]byte, error) {
	switch typed := v.(type) {
	case string:
		return marshalJSONNoHTMLEscape(typed)
	case float64:
		if typed != float64(int64(typed)) {
			return nil, fmt.Errorf("tuple value %v is not an integer", typed)
		}
		return []byte(fmt.Sprintf("%d", int64(typed))), nil
	default:
		return nil, fmt.Errorf("unsupported tuple value type %T", v)
	}
}

// marshalJSONNoHTMLEscape encodes v as JSON without escaping <, >, &,
// U+2028, U+2029 (Go's encoding/json escapes these by default for
// browser-safe embedding). json.Encoder appends a trailing newline; we
// trim it so the result matches json.Marshal's no-newline contract.
//
// Audit-trail note: this MUST match the Swift authority for SPEC-015,
// which is phase3-binary/Sources/malibu-cli/RFC8785JCS.swift —
// NOT phase3-binary/Sources/malibu-cli/Tier2Attestation.swift's
// `goJSONString`. The Tier2 attestation helper deliberately escapes
// <, >, & to match Go's default json.Marshal because it's signing
// over Go-equivalent bytes; the SPEC-015 receipt path uses
// RFC8785JCS.escapeString instead, which passes those code points
// through as raw UTF-8 per RFC 8785 §3.2.2.2. A round-3 review of
// commit 62ac9ff mistook the two paths; this comment is the
// rebuttal so a future reviewer does not repeat the misreading.
func marshalJSONNoHTMLEscape(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	out := buf.Bytes()
	if n := len(out); n > 0 && out[n-1] == '\n' {
		out = out[:n-1]
	}
	return out, nil
}

// AssertTupleCanonicalizationMatches re-canonicalizes the buyer-observed
// tupleData via the independent Go path and reports byte mismatches. The
// SPEC-015 cross-service test exercises this on every receipted response.
func AssertTupleCanonicalizationMatches(tupleData []byte) error {
	independent, err := IndependentTupleCanonicalForm(tupleData)
	if err != nil {
		return err
	}
	if !bytes.Equal(independent, tupleData) {
		return fmt.Errorf("tuple canonicalization mismatch:\n  swift: %s\n  go:    %s", string(tupleData), string(independent))
	}
	return nil
}
