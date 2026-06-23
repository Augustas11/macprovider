package spec015

import (
	"strings"
	"testing"
)

// Round-2 audit M-R2: the independent Go canonicalizer must emit the
// same byte stream as the Swift-side RFC 8785 implementation for the
// closed v0.1 tuple shape, but it ALSO has to stay compatible with
// future v0.2 fields that carry the HTML-sensitive characters '<',
// '>', '&'. Go's default encoding/json escapes those to < /
// > / &, which would falsely fail the drift check the moment
// a real v0.2 string contained any of them. Pin the behavior now so
// the regression cannot return.
func TestIndependentTupleCanonicalFormDoesNotEscapeHTMLEntities(t *testing.T) {
	hashes := strings.Repeat("a", 64)
	const ltChar = "<"
	const gtChar = ">"
	const ampChar = "&"
	cases := []struct {
		name       string
		tuple      string
		expectChar string
	}{
		{
			name:       "less_than",
			tuple:      `{"model_id":"mlx-` + ltChar + `repro` + gtChar + `","output_hash":"` + hashes + `","prompt_hash":"` + hashes + `","provider_pubkey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","tokens_out":1,"ttft_ms":2,"unix_ts":3}`,
			expectChar: ltChar,
		},
		{
			name:       "ampersand",
			tuple:      `{"model_id":"a` + ampChar + `b","output_hash":"` + hashes + `","prompt_hash":"` + hashes + `","provider_pubkey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","tokens_out":1,"ttft_ms":2,"unix_ts":3}`,
			expectChar: ampChar,
		},
	}
	escapedForms := []string{"\\u003c", "\\u003e", "\\u0026"}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			canonical, err := IndependentTupleCanonicalForm([]byte(tc.tuple))
			if err != nil {
				t.Fatalf("canonicalize: %v", err)
			}
			if !strings.Contains(string(canonical), tc.expectChar) {
				t.Fatalf("canonical form must keep %q as raw UTF-8 per RFC 8785 §3.2.2.2; got %s", tc.expectChar, string(canonical))
			}
			for _, esc := range escapedForms {
				if strings.Contains(string(canonical), esc) {
					t.Fatalf("canonical form must NOT contain Go's default HTML escape %q; got %s", esc, string(canonical))
				}
			}
		})
	}
}
