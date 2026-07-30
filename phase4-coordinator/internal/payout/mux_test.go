package payout

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// TestNewMux_PathTableConsistency builds the mux against a
// minimal-but-real AddressesService and asserts the SPEC §3.3
// path-table verification passes.
func TestNewMux_PathTableConsistency(t *testing.T) {
	db := openTestDB(t)
	svc := newServiceForTest(t, db, "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359", "pid", "tok", &fakePause{})
	fallback := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTeapot)
	})
	mux, err := NewMux(svc, fallback)
	if err != nil {
		t.Fatalf("NewMux: %v", err)
	}
	if mux == nil {
		t.Fatal("NewMux returned nil")
	}
}

// TestMux_FallbackForNonPayoutProvidersPath asserts /providers/{id}/earnings
// (the existing billing surface) still reaches the fallback
// handler after chi mounts.
func TestMux_FallbackForNonPayoutProvidersPath(t *testing.T) {
	db := openTestDB(t)
	svc := newServiceForTest(t, db, "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359", "pid", "tok", &fakePause{})
	fallback := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Test", "fallback")
		w.WriteHeader(http.StatusTeapot)
	})
	mux, err := NewMux(svc, fallback)
	if err != nil {
		t.Fatalf("NewMux: %v", err)
	}
	req := httptest.NewRequest("GET", "/providers/foo/earnings", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Header().Get("X-Test") != "fallback" {
		t.Fatalf("fallback not invoked; X-Test=%q code=%d", rec.Header().Get("X-Test"), rec.Code)
	}
}

// TestMux_EscapedAndDotSegmentURLsLandOnExpectedRealm replays
// the SPEC §3.3 normative requirement: chi's longest-match must
// not collapse `/admin/payout/../providers/pid/payout-address`
// into the payout-address realm. We currently only have the
// /providers/{id}/payout-address surface declared; the test
// asserts that the path goes through normal chi routing without
// surprise rewrite.
func TestMux_EscapedURLsAreNotCollapsed(t *testing.T) {
	db := openTestDB(t)
	svc := newServiceForTest(t, db, "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359", "pid", "tok", &fakePause{})
	fallback := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTeapot)
	})
	mux, err := NewMux(svc, fallback)
	if err != nil {
		t.Fatalf("NewMux: %v", err)
	}
	// chi does not route /providers/../foo to /foo — it treats
	// the raw URL as-is. Verify the escaped/dot-segment form
	// does not magically land on the payout-address handler
	// without an explicit `/providers/{id}/payout-address` URL.
	escapedPaths := []string{
		"/admin/payout/../providers/pid/payout-address",
		"/providers/pid/../pid/payout-address",
		"/providers/pid%2Fpayout-address",
	}
	for _, p := range escapedPaths {
		req := httptest.NewRequest("POST", p, strings.NewReader(`{}`))
		req.Header.Set("Authorization", "Bearer tok")
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		// Per the path-table the only payout route is exact
		// match — any escaped form MUST NOT yield 200/201
		// (which would indicate the handler ran).
		if rec.Code == http.StatusCreated || rec.Code == http.StatusOK {
			t.Fatalf("escaped path %q reached payout handler unexpectedly (code=%d)", p, rec.Code)
		}
	}
	// Sanity: avoid time-unused import linter complaints.
	_ = time.Second
}
