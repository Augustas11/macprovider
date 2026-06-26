package stats

import "testing"

func TestNormalizeOrigin(t *testing.T) {
	cases := []struct {
		in     string
		want   string
		wantOk bool
	}{
		// Valid normalizations.
		{"https://acme.example", "https://acme.example", true},
		{"HTTPS://Acme.Example", "https://acme.example", true},
		{"https://acme.example:443", "https://acme.example", true},
		{"http://acme.example:80", "http://acme.example", true},
		{"https://acme.example:8080", "https://acme.example:8080", true},
		// Malformed (treated as absent per locked §5.7).
		{"", "", false},
		{"   ", "", false},
		{"https://acme.example/", "", false},
		{"https://acme.example?foo=bar", "", false},
		{"https://acme.example#frag", "", false},
		{"https://acme.example/path", "", false},
		{"ws://acme.example", "", false},
		{"file:///etc/passwd", "", false},
		{"https://user:pass@acme.example", "", false},
		{"not-a-url", "", false},
	}
	for _, c := range cases {
		got, ok := normalizeOrigin(c.in)
		if ok != c.wantOk {
			t.Errorf("normalizeOrigin(%q) ok=%v want %v", c.in, ok, c.wantOk)
			continue
		}
		if got != c.want {
			t.Errorf("normalizeOrigin(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestOriginAllowed(t *testing.T) {
	// Empty allowlist = wildcard.
	if !originAllowed("https://x", nil) {
		t.Errorf("empty allowlist should match any normalized")
	}
	// Exact match.
	if !originAllowed("https://acme.example", []string{"https://acme.example"}) {
		t.Errorf("exact-match should pass")
	}
	// Case-insensitive against allowlist entries (defensive).
	if !originAllowed("https://acme.example", []string{"HTTPS://ACME.EXAMPLE"}) {
		t.Errorf("case-insensitive allowlist compare should pass")
	}
	// Mismatch.
	if originAllowed("https://attacker.example", []string{"https://acme.example"}) {
		t.Errorf("non-match should fail")
	}
}
