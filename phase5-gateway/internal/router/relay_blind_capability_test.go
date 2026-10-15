package router

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// SPEC-041-R004: the gateway forwards the reservation's requires member byte
// for byte, rejects a malformed one before the coordinator, and passes the
// coordinator's capability-gate 400 through unchanged at reservation and
// consume.
func TestRelayBlindCapabilityDeclarationForwardedAndRefusalPassedThrough(t *testing.T) {
	const refusal = `{"error":{"message":"Non-strict structured output is unsupported in SPEC-019 v0.1.0","type":"invalid_request_error","param":null,"code":"json_schema_non_strict_unsupported","retryable":false,"retry_action":"none"}}`
	res, _ := pilotReservationFixture(t, false)
	envelope := pilotEnvelopeFixture(t, res)
	var reservations atomic.Int32
	var forwarded atomic.Value
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		switch r.URL.Path {
		case "/v1/relay-blind/route-reservations":
			reservations.Add(1)
			forwarded.Store(string(body))
		case "/v1/relay-blind/consume":
		default:
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		io.WriteString(w, refusal)
	}))
	defer upstream.Close()
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
		c.Features.RelayBlindRequests.Enabled = true
		c.Coordinator.BuyerURL = upstream.URL
	})
	key := createAccountAndKey(t, store, cfg, "pilot-account")
	post := func(path string, body []byte) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(body))
		r.Header.Set("Authorization", "Bearer "+key)
		r.Header.Set("X-Request-ID", "123e4567-e89b-42d3-a456-426614174088")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	assertRefusal := func(w *httptest.ResponseRecorder) {
		t.Helper()
		var body struct {
			Error struct {
				Code string `json:"code"`
			} `json:"error"`
		}
		if w.Code != http.StatusBadRequest || json.Unmarshal(w.Body.Bytes(), &body) != nil || body.Error.Code != "json_schema_non_strict_unsupported" {
			t.Fatalf("status=%d body=%s, want 400 json_schema_non_strict_unsupported", w.Code, w.Body.String())
		}
	}
	reservation := `{"endpoint_family":"chat_completions","model":"test-model","stream":false,"max_output_tokens":8,"input_token_upper_bound":16,"encrypted_request_bytes":200`

	assertRefusal(post("/v1/relay-blind/route-reservations", []byte(reservation+`,"requires":["json_schema_non_strict"]}`)))
	if got, _ := forwarded.Load().(string); !strings.Contains(got, `"requires":["json_schema_non_strict"]`) {
		t.Fatalf("forwarded reservation %s lost requires", got)
	}
	for _, member := range []string{`[]`, `null`, `["other"]`, `"json_schema_non_strict"`} {
		before := reservations.Load()
		w := post("/v1/relay-blind/route-reservations", []byte(reservation+`,"requires":`+member+`}`))
		if w.Code != http.StatusBadRequest || !strings.Contains(w.Body.String(), "relay_blind_route_reservation_invalid") || reservations.Load() != before {
			t.Fatalf("requires %s: status=%d body=%s forwarded=%v", member, w.Code, w.Body.String(), reservations.Load() != before)
		}
	}
	assertRefusal(post("/v1/chat/completions", envelope))
}

// A malformed envelope requires member is rejected before replay admission
// and never reaches the coordinator.
func TestRelayBlindEnvelopeMalformedRequiresRejectedBeforeReplay(t *testing.T) {
	res, _ := pilotReservationFixture(t, false)
	envelope := pilotEnvelopeFixture(t, res)
	var upstreamCalls atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upstreamCalls.Add(1)
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer upstream.Close()
	h, store, path, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
		c.Features.RelayBlindRequests.Enabled = true
		c.Coordinator.BuyerURL = upstream.URL
	})
	key := createAccountAndKey(t, store, cfg, "pilot-account")
	for _, member := range []string{`[]`, `null`, `["other"]`, `["json_schema_non_strict","json_schema_non_strict"]`} {
		body := append(bytes.TrimSuffix(bytes.TrimSpace(envelope), []byte(`}`)), []byte(`,"requires":`+member+`}`)...)
		r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
		r.Header.Set("Authorization", "Bearer "+key)
		r.Header.Set("X-Request-ID", "123e4567-e89b-42d3-a456-426614174088")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != http.StatusBadRequest {
			t.Fatalf("requires %s: status=%d body=%s", member, w.Code, w.Body.String())
		}
	}
	if upstreamCalls.Load() != 0 {
		t.Fatalf("malformed requires reached the coordinator %d times", upstreamCalls.Load())
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var rows int
	if err := db.QueryRow("SELECT count(*) FROM relay_blind_replays").Scan(&rows); err != nil || rows != 0 {
		t.Fatalf("malformed requires created %d replay rows (err %v)", rows, err)
	}
}
