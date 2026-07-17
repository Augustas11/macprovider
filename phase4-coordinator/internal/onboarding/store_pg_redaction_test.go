package onboarding

import (
	"strings"
	"testing"
)

// TestOpenPostgresDBRedactsMalformedDSN pins issue #582 FIX 6: lib/pq's sql.Open
// defers DSN parsing, so a malformed connection string only fails later — and
// lib/pq's parse error echoes the raw, credential-bearing URL. openPostgresDB now
// builds the connector eagerly (pq.NewConnector) and, on failure, returns ONLY a
// redacted message naming the config handle. The returned error must never
// contain the DSN or its embedded secret.
func TestOpenPostgresDBRedactsMalformedDSN(t *testing.T) {
	const secret = "SUPERSECRETPW"
	// An unparseable port makes pq.NewConnector fail eagerly; lib/pq's own error
	// for this input embeds the full URL (including the password), which is exactly
	// what must not reach logs.
	dsn := "postgres://user:" + secret + "@host:notaport/db"

	db, err := openPostgresDB(dsn, "hardware trust approve")
	if err == nil {
		if db != nil {
			_ = db.Close()
		}
		t.Fatal("expected a malformed DSN to fail eagerly, got nil error")
	}
	msg := err.Error()
	if strings.Contains(msg, secret) {
		t.Fatalf("redacted error must not contain the DSN secret; got %q", msg)
	}
	if strings.Contains(msg, dsn) {
		t.Fatalf("redacted error must not contain the raw DSN; got %q", msg)
	}
	if strings.Contains(msg, "notaport") || strings.Contains(strings.ToLower(msg), "postgres://") {
		t.Fatalf("redacted error must not echo DSN fragments; got %q", msg)
	}
	if !strings.Contains(msg, "hardware trust approve") {
		t.Fatalf("redacted error should name the config handle; got %q", msg)
	}
}
