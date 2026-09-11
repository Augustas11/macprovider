package stats

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/stats/store"
)

func intakeHandlerFixture(t *testing.T, generatedAt time.Time, now time.Time) *Handler {
	t.Helper()
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if _, err := db.Exec(`CREATE TABLE stats_intake_current (
		singleton BOOLEAN PRIMARY KEY,
		generated_at TIMESTAMP,
		unmatched_models TEXT,
		fleet_ram TEXT)`); err != nil {
		t.Fatal(err)
	}
	unmatched := `{"contract":"SPEC-023-16.2a","windows":[]}`
	fleet := `{"window_start":"2026-08-12T00:00:00Z","window_end":"2026-09-11T00:00:00Z","k_anonymity_min":3,"provider_total":0,"provider_suppressed":0,"classes":[]}`
	if _, err := db.Exec(`INSERT INTO stats_intake_current (singleton, generated_at, unmatched_models, fleet_ram) VALUES (1, ?, ?, ?)`, generatedAt, unmatched, fleet); err != nil {
		t.Fatal(err)
	}
	return &Handler{
		Store:              store.New(db),
		Now:                func() time.Time { return now },
		IntakeEnabled:      true,
		IntakeReaderKeyIDs: map[int64]struct{}{7: {}},
	}
}

func partnerAuth(id int64, providerBound bool) authResult {
	key := &store.PartnerKey{ID: id}
	if providerBound {
		key.ProviderID = sql.NullString{String: "provider-1", Valid: true}
	}
	return authResult{projection: "partner", matchedKey: key}
}

func TestIntakeHandlerRequiresListedNonProviderBoundPartnerKey(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	h := intakeHandlerFixture(t, now.Add(-10*time.Second), now)
	get := func(ar authResult, rawQuery string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, "/v1/stats/intake"+rawQuery, nil)
		rr := httptest.NewRecorder()
		h.handleIntake(rr, req, ar)
		return rr
	}
	if rr := get(authResult{projection: "public"}, ""); rr.Code != http.StatusUnauthorized {
		t.Fatalf("public projection: status=%d, want 401", rr.Code)
	}
	if rr := get(partnerAuth(9, false), ""); rr.Code != http.StatusUnauthorized {
		t.Fatalf("unlisted key: status=%d, want 401", rr.Code)
	}
	if rr := get(partnerAuth(7, true), ""); rr.Code != http.StatusUnauthorized {
		t.Fatalf("provider-bound key: status=%d, want 401", rr.Code)
	}
	if rr := get(partnerAuth(7, false), "?window=30d"); rr.Code != http.StatusBadRequest {
		t.Fatalf("query parameter: status=%d, want 400", rr.Code)
	}
	withOrigin := partnerAuth(7, false)
	withOrigin.originPresent, withOrigin.originValue = true, "https://console.example"
	rr := get(withOrigin, "")
	if rr.Code != http.StatusOK {
		t.Fatalf("listed key: status=%d body=%s, want 200", rr.Code, rr.Body.String())
	}
	if cc := rr.Header().Get("Cache-Control"); cc != "private, max-age=900" {
		t.Fatalf("Cache-Control = %q", cc)
	}
	if vary := rr.Header().Get("Vary"); !strings.Contains(vary, "Authorization") {
		t.Fatalf("Vary = %q, want Authorization", vary)
	}
	if _, present := rr.Header()["Access-Control-Allow-Origin"]; present {
		t.Fatalf("intake must emit no Access-Control-Allow-Origin at all: %q", rr.Header().Get("Access-Control-Allow-Origin"))
	}
	if _, present := rr.Header()["Access-Control-Allow-Credentials"]; present {
		t.Fatalf("intake must emit no Access-Control-Allow-Credentials")
	}
	var body map[string]json.RawMessage
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"schema_version", "generated_at", "stale_after", "unmatched_models", "fleet_ram", "methodology"} {
		if _, ok := body[k]; !ok {
			t.Fatalf("response missing %q: %s", k, rr.Body.String())
		}
	}
	if len(body) != 6 {
		t.Fatalf("response carries %d keys, want 6: %s", len(body), rr.Body.String())
	}
	if string(body["schema_version"]) != `"macprovider.stats-intake.v1"` {
		t.Fatalf("schema_version = %s", body["schema_version"])
	}
	// Empty reader list refuses every key.
	h.IntakeReaderKeyIDs = map[int64]struct{}{}
	if rr := get(partnerAuth(7, false), ""); rr.Code != http.StatusUnauthorized {
		t.Fatalf("empty allowlist: status=%d, want 401", rr.Code)
	}
}

func TestIntakeHandlerDisabledAndStale(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	h := intakeHandlerFixture(t, now.Add(-10*time.Second), now)
	h.IntakeEnabled = false
	req := httptest.NewRequest(http.MethodGet, "/v1/stats/intake", nil)
	rr := httptest.NewRecorder()
	h.handleIntake(rr, req, partnerAuth(7, false))
	if rr.Code != http.StatusNotFound {
		t.Fatalf("disabled: status=%d, want 404", rr.Code)
	}
	stale := intakeHandlerFixture(t, now.Add(-46*time.Minute), now)
	rr = httptest.NewRecorder()
	stale.handleIntake(rr, req, partnerAuth(7, false))
	if rr.Code != http.StatusServiceUnavailable || !strings.Contains(rr.Body.String(), "stats_stale") {
		t.Fatalf("stale: status=%d body=%s, want 503 stats_stale", rr.Code, rr.Body.String())
	}
}

func TestIntakeEndpointUnknownWhenDisabledAtMux(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	h := intakeHandlerFixture(t, now.Add(-10*time.Second), now)
	m := &Mux{h: h, authFailLimit: newLimiterWithBounds(10, time.Minute), publicLimit: newLimiterWithBounds(10, time.Minute), partnerLimit: newLimiterWithBounds(10, time.Minute), preflightLimit: newLimiterWithBounds(10, time.Minute), preflightRPM: 10}
	m.WithIntake(false, nil)
	req := httptest.NewRequest(http.MethodGet, "/v1/stats/intake", nil)
	rr := httptest.NewRecorder()
	m.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("disabled at mux: status=%d body=%s, want 404 before auth", rr.Code, rr.Body.String())
	}
	// OPTIONS on the disabled path is equally unknown: no preflight
	// decision, no CORS header.
	opt := httptest.NewRequest(http.MethodOptions, "/v1/stats/intake", nil)
	opt.Header.Set("Origin", "https://console.example")
	opt.Header.Set("Access-Control-Request-Method", "GET")
	rr = httptest.NewRecorder()
	m.Handler().ServeHTTP(rr, opt)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("disabled OPTIONS: status=%d, want 404", rr.Code)
	}
	if _, present := rr.Header()["Access-Control-Allow-Origin"]; present {
		t.Fatalf("disabled OPTIONS must not emit CORS headers")
	}
}

// The intake path is routable through the mux (endpoint recognition,
// auth dispatch, handler) and refuses a key-less request with 401 before
// the public rate tier: a 404 here would mean the path never reached the
// handler at all.
func TestIntakeEndpointRoutedThroughMuxRequiresPartnerKey(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	h := intakeHandlerFixture(t, now.Add(-10*time.Second), now)
	m := &Mux{h: h, authFailLimit: newLimiterWithBounds(10, time.Minute), publicLimit: newLimiterWithBounds(1, time.Minute), partnerLimit: newLimiterWithBounds(10, time.Minute), preflightLimit: newLimiterWithBounds(10, time.Minute), preflightRPM: 10}
	m.WithIntake(true, []int64{7})
	for i := 0; i < 3; i++ {
		req := httptest.NewRequest(http.MethodGet, "/v1/stats/intake", nil)
		rr := httptest.NewRecorder()
		m.Handler().ServeHTTP(rr, req)
		if rr.Code != http.StatusUnauthorized || !strings.Contains(rr.Body.String(), "unauthorized") {
			t.Fatalf("key-less GET #%d: status=%d body=%s, want 401 unauthorized (never 404, never a public-tier 429)", i, rr.Code, rr.Body.String())
		}
		if _, present := rr.Header()["Access-Control-Allow-Origin"]; present {
			t.Fatalf("intake refusal must not emit CORS headers")
		}
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/stats/intake", nil)
	rr := httptest.NewRecorder()
	m.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST: status=%d, want 405", rr.Code)
	}
}
