package integration

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"
)

// TestNonStrictJSONSchemaRoutesOnlyToCapableCLI is the SPEC-019 v0.3.0 §1a
// capability gate through the gateway: a non-strict json_schema request is
// never dispatched to a provider CLI before 1.8.242, which rejects it. With
// only such a provider the buyer gets the pre-v0.3.0 400; with a 1.8.242
// provider it gets 200. The coordinator and the CLI can deploy in either
// order.
func TestNonStrictJSONSchemaRoutesOnlyToCapableCLI(t *testing.T) {
	requireBins(t)
	for _, tc := range []struct {
		binary     string
		wantStatus int
	}{
		{"1.8.240", http.StatusBadRequest},
		{"1.8.242", http.StatusOK},
	} {
		t.Run(tc.binary, func(t *testing.T) {
			providerID := "prov-nonstrict-" + randHex(t, 4)
			s := newScenario(t, scenarioOpts{
				seedAccount:               true,
				providerID:                providerID,
				externalWebSocketProvider: true,
			})
			defer s.shutdown()
			provider := connectKeyedServeProvider(t, s.rootCtx, s, settlementFixtureModelID, tc.binary)
			s.waitForProviderReady(providerID)

			status, _, body := s.chatRequest(nil, fmt.Sprintf(
				`{"model":%q,"max_tokens":16,"messages":[{"role":"user","content":"hello"}],"response_format":{"type":"json_schema","json_schema":{"name":"person","strict":false,"schema":{"type":"object","properties":{"name":{"type":"string"}}}}}}`,
				staticLlama32CandidateKey))
			if status != tc.wantStatus {
				t.Fatalf("status %d body %s, want %d", status, body, tc.wantStatus)
			}
			dispatches := len(provider.dispatchedKeys())
			if tc.wantStatus == http.StatusOK {
				if dispatches != 1 {
					t.Fatalf("dispatches=%d, want 1", dispatches)
				}
				return
			}
			if dispatches != 0 {
				t.Fatalf("dispatches=%d, want none to CLI %s", dispatches, tc.binary)
			}
			var env struct {
				Error struct {
					Code string `json:"code"`
				} `json:"error"`
			}
			if err := json.Unmarshal([]byte(body), &env); err != nil || env.Error.Code != "json_schema_non_strict_unsupported" {
				t.Fatalf("error body %s (decode err %v), want code json_schema_non_strict_unsupported", body, err)
			}
		})
	}
}
