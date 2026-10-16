package buyer_test

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

const (
	nonStrictFalseBody  = `{"model":"model-a","messages":[{"role":"user","content":"hi"}],"response_format":{"type":"json_schema","json_schema":{"name":"person","strict":false,"schema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}}}}`
	nonStrictAbsentBody = `{"model":"model-a","messages":[{"role":"user","content":"hi"}],"response_format":{"type":"json_schema","json_schema":{"name":"person","schema":{"type":"object","properties":{"name":{"type":"string"},"age":{"type":"integer"}},"required":["name"],"additionalProperties":false}}}}`
	strictSubsetBody    = `{"model":"model-a","messages":[{"role":"user","content":"hi"}],"response_format":{"type":"json_schema","json_schema":{"name":"person","strict":true,"schema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}}}}`
	absentSubsetBody    = `{"model":"model-a","messages":[{"role":"user","content":"hi"}],"response_format":{"type":"json_schema","json_schema":{"name":"person","schema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}}}}`
)

func nonStrictGateServer(t *testing.T, binaries ...string) (*buyer.Server, *[]string) {
	t.Helper()
	registry := pool.NewRegistry(nil)
	for i, binary := range binaries {
		id := string(rune('a' + i))
		registry.Register(&pool.Provider{
			ProviderID: "p-" + id, AssignedID: "s-" + id, Hostname: id + ".local",
			ModelID: "model-a", ModelParamsB: 7, RAMGB: 16,
			MaxContextTokens: 20000, MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1,
			ThroughputTPSEstimate: 20, Tier: pool.TierProvisional,
			InferencePath: pool.InferencePathWSTunneled, State: pool.StateReady,
			LastHeartbeatAt: time.Now().UTC(), ConnectedAt: time.Now().UTC(),
			BinaryVersion: binary,
		}, nil)
	}
	var dispatched []string
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			dispatched = append(dispatched, provider.BinaryVersion)
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			chunks <- providerws.InferenceResponseChunk{
				Type: "inference_response_chunk", RequestID: requestID, Seq: 0,
				Data: `{"id":"ok","choices":[{"message":{"content":"{\"name\":\"a\"}"}}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}`,
			}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: make(chan error, 1)}, nil
		}, time.Second),
	)
	return server, &dispatched
}

func errorCode(t *testing.T, body []byte) string {
	t.Helper()
	var env struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		t.Fatalf("decode error body %s: %v", body, err)
	}
	return env.Error.Code
}

// TestNonStrictJSONSchemaRoutesOnlyToCapableBinaries pins the SPEC-019 v0.3.0
// §1a capability gate: a non-strict json_schema request reaches only provider
// CLIs 1.8.242 and later. With none left it gets the pre-v0.3.0 400 and no
// provider is dispatched.
func TestNonStrictJSONSchemaRoutesOnlyToCapableBinaries(t *testing.T) {
	cases := []struct {
		name     string
		body     string
		binaries []string
		wantCode string // "" means 200
		wantSent string
	}{
		{"strict false on 1.8.240", nonStrictFalseBody, []string{"1.8.240"}, "json_schema_non_strict_unsupported", ""},
		{"strict false on 1.8.241", nonStrictFalseBody, []string{"1.8.241"}, "json_schema_non_strict_unsupported", ""},
		{"strict false on 1.8.242", nonStrictFalseBody, []string{"1.8.242"}, "", "1.8.242"},
		{"strict false on 1.9.0", nonStrictFalseBody, []string{"1.9.0"}, "", "1.9.0"},
		{"strict false on unparseable", nonStrictFalseBody, []string{"1.8.242-dev"}, "json_schema_non_strict_unsupported", ""},
		{"strict false on empty version", nonStrictFalseBody, []string{""}, "json_schema_non_strict_unsupported", ""},
		{"absent strict non-subset on 1.8.240", nonStrictAbsentBody, []string{"1.8.240"}, "json_schema_strict_requires_all_properties_required", ""},
		{"absent strict non-subset on 1.8.242", nonStrictAbsentBody, []string{"1.8.242"}, "", "1.8.242"},
		{"mixed fleet picks capable", nonStrictFalseBody, []string{"1.8.240", "1.8.242"}, "", "1.8.242"},
		{"strict true on 1.8.240", strictSubsetBody, []string{"1.8.240"}, "", "1.8.240"},
		{"absent strict subset on 1.8.240", absentSubsetBody, []string{"1.8.240"}, "", "1.8.240"},
		{"absent strict subset on unparseable", absentSubsetBody, []string{"dev"}, "", "dev"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			server, dispatched := nonStrictGateServer(t, tc.binaries...)
			resp := postChat(t, server, []byte(tc.body), http.Header{})
			if tc.wantCode != "" {
				if resp.Code != http.StatusBadRequest || errorCode(t, resp.Body.Bytes()) != tc.wantCode {
					t.Fatalf("status=%d body=%s, want 400 %s", resp.Code, resp.Body.String(), tc.wantCode)
				}
				if len(*dispatched) != 0 {
					t.Fatalf("dispatched to %q, want no dispatch", *dispatched)
				}
				return
			}
			if resp.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s, want 200", resp.Code, resp.Body.String())
			}
			if len(*dispatched) != 1 || (*dispatched)[0] != tc.wantSent {
				t.Fatalf("dispatched to %q, want [%s]", *dispatched, tc.wantSent)
			}
		})
	}
}
