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
	if _, err := db.Exec(`INSERT INTO stats_intake_current (singleton, generated_at, unmatched_models, fleet_ram) VALUES (1, ?, ?, ?)`, generatedAt, fixtureUnmatchedJSON, fixtureFleetJSON); err != nil {
		t.Fatal(err)
	}
	return &Handler{
		Store:              store.New(db),
		Now:                func() time.Time { return now },
		IntakeEnabled:      true,
		IntakeReaderKeyIDs: map[int64]struct{}{7: {}},
	}
}

// fixtureUnmatchedJSON is one complete window in the closed §5.2b shape.
const fixtureUnmatchedJSON = `{"contract":"SPEC-023-16.2a","windows":[{"window_id":"3f1c0a9b7d2e4c6f8a1b3d5e7f9a0c2d","window_start":"2026-08-01T00:00:00Z","window_end":"2026-08-31T00:00:00Z","parameters":{"key_buckets":64,"principals_per_bucket":64,"distinct_key_cap":10000,"buyer_request_floor":250,"principal_cap_pct":10,"principal_cap_requests":25,"k_anonymity_min":3,"window_max_days":30},"eligibility_policy_id":"9a2e6c1d4b8f0a3e5c7d9b1f3a5c7e90","buckets":[{"model_key":"qwen3-14b","lower_bound":311,"count":311,"error":0}],"suppressed_bucket_count":7,"other_suppressed":{"request_count":57,"request_count_saturated":false,"distinct_key_count":41,"distinct_key_count_saturated":false}}]}`

// fixtureFleetJSON is the §5.2b canonical histogram: 32 GB emitted, the
// rest suppressed, 11 = 5 + 6.
const fixtureFleetJSON = `{"window_start":"2026-08-12T00:00:00Z","window_end":"2026-09-11T00:00:00Z","k_anonymity_min":3,"provider_total":11,"provider_suppressed":6,"classes":[{"ram_gb_floor":8,"provider_count":null,"suppressed":true},{"ram_gb_floor":16,"provider_count":null,"suppressed":true},{"ram_gb_floor":24,"provider_count":null,"suppressed":true},{"ram_gb_floor":32,"provider_count":5,"suppressed":false},{"ram_gb_floor":48,"provider_count":null,"suppressed":true},{"ram_gb_floor":64,"provider_count":null,"suppressed":true},{"ram_gb_floor":96,"provider_count":null,"suppressed":true},{"ram_gb_floor":128,"provider_count":null,"suppressed":true},{"ram_gb_floor":192,"provider_count":null,"suppressed":true},{"ram_gb_floor":256,"provider_count":null,"suppressed":true},{"ram_gb_floor":512,"provider_count":null,"suppressed":true}]}`

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
	// AC-INTAKE-1: closed shape at every nested level.
	var um struct {
		Contract string                       `json:"contract"`
		Windows  []map[string]json.RawMessage `json:"windows"`
	}
	if err := json.Unmarshal(body["unmatched_models"], &um); err != nil || len(um.Windows) != 1 {
		t.Fatalf("unmatched_models: %v %s", err, body["unmatched_models"])
	}
	assertKeys := func(name string, got map[string]json.RawMessage, want ...string) {
		t.Helper()
		if len(got) != len(want) {
			t.Fatalf("%s carries %d keys, want %d: %v", name, len(got), len(want), got)
		}
		for _, k := range want {
			if _, ok := got[k]; !ok {
				t.Fatalf("%s missing %q", name, k)
			}
		}
	}
	assertKeys("window", um.Windows[0], "window_id", "window_start", "window_end", "parameters", "eligibility_policy_id", "buckets", "suppressed_bucket_count", "other_suppressed")
	var params map[string]json.RawMessage
	_ = json.Unmarshal(um.Windows[0]["parameters"], &params)
	assertKeys("parameters", params, "key_buckets", "principals_per_bucket", "distinct_key_cap", "buyer_request_floor", "principal_cap_pct", "principal_cap_requests", "k_anonymity_min", "window_max_days")
	var buckets []map[string]json.RawMessage
	_ = json.Unmarshal(um.Windows[0]["buckets"], &buckets)
	assertKeys("bucket", buckets[0], "model_key", "lower_bound", "count", "error")
	var other map[string]json.RawMessage
	_ = json.Unmarshal(um.Windows[0]["other_suppressed"], &other)
	assertKeys("other_suppressed", other, "request_count", "request_count_saturated", "distinct_key_count", "distinct_key_count_saturated")
	var fleet map[string]json.RawMessage
	_ = json.Unmarshal(body["fleet_ram"], &fleet)
	assertKeys("fleet_ram", fleet, "window_start", "window_end", "k_anonymity_min", "provider_total", "provider_suppressed", "classes")
	var classes []map[string]json.RawMessage
	_ = json.Unmarshal(fleet["classes"], &classes)
	if len(classes) != 11 {
		t.Fatalf("classes = %d, want 11", len(classes))
	}
	assertKeys("class", classes[0], "ram_gb_floor", "provider_count", "suppressed")
	var methodology map[string]json.RawMessage
	_ = json.Unmarshal(body["methodology"], &methodology)
	assertKeys("methodology", methodology, "version", "unmatched_models", "fleet_ram", "redaction")
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
	// An ENABLED intake endpoint never answers a CORS preflight: OPTIONS
	// is 405 with Allow: GET, HEAD and no Access-Control-* header.
	opt := httptest.NewRequest(http.MethodOptions, "/v1/stats/intake", nil)
	opt.Header.Set("Origin", "https://console.example")
	opt.Header.Set("Access-Control-Request-Method", "GET")
	rr = httptest.NewRecorder()
	m.Handler().ServeHTTP(rr, opt)
	if rr.Code != http.StatusMethodNotAllowed || rr.Header().Get("Allow") != "GET, HEAD" {
		t.Fatalf("enabled OPTIONS: status=%d allow=%q, want 405 / GET, HEAD", rr.Code, rr.Header().Get("Allow"))
	}
	for name := range rr.Header() {
		if strings.HasPrefix(name, "Access-Control-") {
			t.Fatalf("enabled OPTIONS must not emit %s", name)
		}
	}
}

// A persisted row that fails the closed contract — a sub-floor bucket, a
// stray window key, a histogram that does not reconcile — is never served.
func TestIntakeHandlerRefusesMalformedPersistedRow(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	for name, mutate := range map[string]func(u, f string) (string, string){
		"sub-floor bucket": func(u, f string) (string, string) {
			return strings.Replace(u, `"lower_bound":311,"count":311`, `"lower_bound":3,"count":3`, 1), f
		},
		"leaked window key": func(u, f string) (string, string) {
			return strings.Replace(u, `"suppressed_bucket_count":7`, `"suppressed_bucket_count":7,"excluded_account_count":2`, 1), f
		},
		"open window": func(u, f string) (string, string) {
			return strings.Replace(u, `"window_end":"2026-08-31T00:00:00Z"`, `"window_end":null`, 1), f
		},
		"fleet not reconciled": func(u, f string) (string, string) {
			return u, strings.Replace(f, `"provider_suppressed":6`, `"provider_suppressed":5`, 1)
		},
		"fleet sub-k class": func(u, f string) (string, string) {
			return u, strings.Replace(f, `"provider_count":5`, `"provider_count":2`, 1)
		},
	} {
		h := intakeHandlerFixture(t, now.Add(-10*time.Second), now)
		u, f := mutate(fixtureUnmatchedJSON, fixtureFleetJSON)
		if _, err := h.Store.DB().Exec(`UPDATE stats_intake_current SET unmatched_models = ?, fleet_ram = ?`, u, f); err != nil {
			t.Fatal(err)
		}
		req := httptest.NewRequest(http.MethodGet, "/v1/stats/intake", nil)
		rr := httptest.NewRecorder()
		h.handleIntake(rr, req, partnerAuth(7, false))
		if rr.Code != http.StatusServiceUnavailable || strings.Contains(rr.Body.String(), "qwen3-14b") {
			t.Fatalf("%s: status=%d body=%s, want 503 without the row's content", name, rr.Code, rr.Body.String())
		}
	}
}
