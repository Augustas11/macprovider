package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/relayblind"
)

// SPEC-041-R003/R004: the reference client derives requires from the inner
// body before encryption and sends the same value in the reservation and in
// the authenticated envelope; a body that needs nothing declares nothing.
func TestRunDeclaresNonStrictJSONSchemaInReservationAndEnvelope(t *testing.T) {
	strict := `{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}`
	loose := `{"type":"object","properties":{"name":{"type":"string"}}}`
	for name, tc := range map[string]struct {
		format string
		want   []string
	}{
		"strict false":                 {`{"type":"json_schema","json_schema":{"name":"person","strict":false,"schema":` + strict + `}}`, []string{relayblind.CapabilityJSONSchemaNonStrict}},
		"strict absent outside subset": {`{"type":"json_schema","json_schema":{"name":"person","schema":` + loose + `}}`, []string{relayblind.CapabilityJSONSchemaNonStrict}},
		"strict absent subset":         {`{"type":"json_schema","json_schema":{"name":"person","schema":` + strict + `}}`, nil},
		"strict true":                  {`{"type":"json_schema","json_schema":{"name":"person","strict":true,"schema":` + strict + `}}`, nil},
		"json_object":                  {`{"type":"json_object"}`, nil},
	} {
		t.Run(name, func(t *testing.T) {
			now := time.Now().UTC()
			record, pin, providerPrivate := cliIdentity(t, now)
			pinPath := writePin(t, pin)
			inner := []byte(`{"model":"model-a","messages":[{"role":"user","content":"client secret prompt"}],"max_tokens":32,"stream":false,"response_format":` + tc.format + `}`)
			var reserved, enveloped []string
			var reservationRaw string
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				body, _ := io.ReadAll(r.Body)
				switch r.URL.Path {
				case "/v1/relay-blind/route-reservations":
					reservationRaw = string(body)
					request, err := relayblind.ParseReservationRequest(body)
					if err != nil {
						t.Errorf("reservation: %v", err)
						http.Error(w, "bad", 400)
						return
					}
					reserved = request.Requires
					_ = json.NewEncoder(w).Encode(relayblind.ReservationResponse{
						Version:         relayblind.ReservationVersion,
						ProviderBinding: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x33}, 32)),
						BuyerBinding:    base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x44}, 32)),
						KeyRecordDigest: record.KeyRecordDigest, KeyRecord: record, KID: record.KID,
						EndpointFamily: request.EndpointFamily, Model: request.Model, ProviderModel: request.Model,
						Stream: request.Stream, MaxEncryptedRequestBytes: record.MaxEncryptedRequestBytes,
						MaxOutputTokens: request.MaxOutputTokens, InputTokenUpperBound: request.InputTokenUpperBound,
						ReservationTokenCap: request.MaxOutputTokens + request.InputTokenUpperBound,
						ExpiresAtUnix:       now.Add(30 * time.Second).Unix(), CachePolicy: relayblind.CachePolicyNoStore,
						FailoverPolicy: relayblind.FailoverPolicyDisabled,
					})
				case "/v1/chat/completions":
					envelope, err := relayblind.ParseEnvelope(body)
					if err != nil {
						t.Errorf("envelope: %v", err)
						http.Error(w, "bad", 400)
						return
					}
					enveloped = envelope.Requires
					if _, err := envelope.Decrypt(providerPrivate.Bytes()); err != nil {
						t.Errorf("decrypt: %v", err)
					}
					stripped := envelope
					stripped.Requires = nil
					if tc.want != nil {
						if _, err := stripped.Decrypt(providerPrivate.Bytes()); err == nil {
							t.Error("requires is not bound into the envelope")
						}
					}
					w.Header().Set("X-MacProvider-Requested-Privacy-Mode", "relay_blind_required")
					w.Header().Set("X-MacProvider-Effective-Privacy-Outcome", "relay_blind_satisfied")
					_, _ = io.WriteString(w, successfulUsageJSON)
				default:
					http.NotFound(w, r)
				}
			}))
			defer server.Close()
			opts := options{
				baseURL: server.URL, identityPin: pinPath, model: "model-a", input: "-",
				maxOutputTokens: 32, inputTokenUpperBound: 96, apiKeyEnv: "TEST_API_KEY", timeout: time.Minute,
			}
			getenv := func(name string) string {
				if name == "TEST_API_KEY" {
					return "test-bearer-secret"
				}
				return ""
			}
			var stdout, stderr bytes.Buffer
			if err := run(context.Background(), opts, bytes.NewReader(inner), &stdout, &stderr, getenv); err != nil {
				t.Fatalf("run: %v", err)
			}
			if !reflect.DeepEqual(reserved, tc.want) || !reflect.DeepEqual(enveloped, tc.want) {
				t.Fatalf("reservation requires %v, envelope requires %v, want %v", reserved, enveloped, tc.want)
			}
			if strings.Contains(reservationRaw, "person") || strings.Contains(reservationRaw, "response_format") {
				t.Fatalf("reservation disclosed more than the flag: %s", reservationRaw)
			}
		})
	}
}

// The capability-gate refusal reaches the buyer as its error code; any other
// error text stays out of the client's message.
func TestRunReportsCapabilityRefusalCode(t *testing.T) {
	now := time.Now().UTC()
	_, pin, _ := cliIdentity(t, now)
	pinPath := writePin(t, pin)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = io.WriteString(w, `{"error":{"message":"secret detail","code":"json_schema_non_strict_unsupported"}}`)
	}))
	defer server.Close()
	inner := []byte(`{"model":"model-a","messages":[{"role":"user","content":"x"}],"max_tokens":32,"response_format":{"type":"json_schema","json_schema":{"name":"p","strict":false,"schema":{"type":"object"}}}}`)
	opts := options{baseURL: server.URL, identityPin: pinPath, model: "model-a", input: "-", maxOutputTokens: 32, inputTokenUpperBound: 96, apiKeyEnv: "TEST_API_KEY", timeout: time.Minute}
	getenv := func(name string) string {
		if name == "TEST_API_KEY" {
			return "test-bearer-secret"
		}
		return ""
	}
	var stdout, stderr bytes.Buffer
	err := run(context.Background(), opts, bytes.NewReader(inner), &stdout, &stderr, getenv)
	if err == nil || !strings.Contains(err.Error(), "HTTP 400 json_schema_non_strict_unsupported") || strings.Contains(err.Error(), "secret detail") {
		t.Fatalf("err=%v", err)
	}
	for raw, want := range map[string]string{`{"error":{"code":"Bad Code"}}`: "", `not json`: "", `{"error":{"code":"relay_blind_replay"}}`: "relay_blind_replay"} {
		if got := errorCode([]byte(raw)); got != want {
			t.Fatalf("errorCode(%s)=%q want %q", raw, got, want)
		}
	}
}
