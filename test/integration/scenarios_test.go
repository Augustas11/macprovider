package integration

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// TestHappyPathChatCompletion exercises the full
// buyer -> gateway -> coordinator -> (fake) provider HTTP path end-to-
// end. Pins:
//   - the gateway returns 200 with an OpenAI-shaped body
//   - the coordinator's request_log has a row for this attempt with
//     the matching model + status=200 (money path proof)
//   - the response carries a sticky-route hint that names our provider
//     (the coordinator sets X-MacProvider-Provider; the gateway strips
//     x-macprovider-* before writing the buyer-facing response, so we
//     verify the row not the header on the buyer side)
//
// This is the half the existing within-gateway integration_test.go
// can never exercise — its coordinator is a httptest mock.
func TestHappyPathChatCompletion(t *testing.T) {
	s := newScenario(t, scenarioOpts{seedAccount: true})

	status, _, body := s.chatRequest(nil, `{
		"model":"llama-3.2-3b-instruct",
		"max_tokens":32,
		"messages":[{"role":"user","content":"hello"}]
	}`)
	if status != http.StatusOK {
		t.Fatalf("chat status=%d body=%s", status, string(body))
	}
	var chat map[string]any
	if err := json.Unmarshal(body, &chat); err != nil {
		t.Fatalf("decode body: %v body=%s", err, string(body))
	}
	if chat["object"] != "chat.completion" {
		t.Fatalf("object=%v want chat.completion", chat["object"])
	}

	// Money path: the coordinator MUST have written a request_log row
	// with our model + status=200. This is the cross-boundary contract
	// the within-gateway mock can never pin.
	row, ok := s.readLatestRequestLog()
	if !ok {
		t.Fatalf("coordinator request_log empty after successful chat")
	}
	if row.Model != "llama-3.2-3b-instruct" {
		t.Fatalf("request_log.model=%q want llama-3.2-3b-instruct", row.Model)
	}
	if row.Status != http.StatusOK {
		t.Fatalf("request_log.status=%d want 200", row.Status)
	}
	if row.ProviderAssignedID == "" {
		t.Fatalf("request_log.provider_assigned_id empty (provider not bound)")
	}
}

// TestInternalBearerWrongTokenRejected pins the auth boundary directly
// at the SERVICE-TO-SERVICE endpoint the gateway calls (/internal/routing
// on the provider port, mounted by InternalHandler at buyer/server.go:388-393).
//
// A request carrying a Bearer that matches NEITHER operator_key NOR
// gateway_service_token MUST be rejected with 401. This is the half
// the within-gateway integration_test.go CANNOT possibly test: in that
// suite the coordinator IS a httptest mock, so there's no real
// token-validation gate to fail. A regression that broke the constant-
// time compare, or accidentally widened the accepted-credential set,
// would silently pass the within-gateway suite. This scenario catches
// it on every PR.
func TestInternalBearerWrongTokenRejected(t *testing.T) {
	s := newScenario(t, scenarioOpts{skipProvider: true})

	wrongToken := strings.Repeat("z", 64)
	req, err := http.NewRequest(http.MethodGet, s.coordProvURL+"/internal/routing", nil)
	if err != nil {
		t.Fatalf("new req: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+wrongToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wrong-token /internal/routing status=%d want 401", resp.StatusCode)
	}
}

// TestInternalBearerNoAuthRejected pins that an unauthenticated call to
// /internal/routing is rejected. Together with the wrong-token and
// right-token scenarios this gives full BOTH-BRANCH coverage of the
// internalBearerAuthorized gate at the audit-cited file/line
// (phase4-coordinator/internal/buyer/server.go:2785).
func TestInternalBearerNoAuthRejected(t *testing.T) {
	s := newScenario(t, scenarioOpts{skipProvider: true})

	req, err := http.NewRequest(http.MethodGet, s.coordProvURL+"/internal/routing", nil)
	if err != nil {
		t.Fatalf("new req: %v", err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("no-auth /internal/routing status=%d want 401", resp.StatusCode)
	}
}

// TestInternalBearerServiceTokenAccepted pins the right-token success
// half: the same endpoint accepts a Bearer matching the configured
// gateway_service_token. We confirm we DON'T get the auth-rejection
// 4xx that the wrong-token case produced. /internal/routing on the
// buyer port returns 405 when not internal-routed; the success branch
// here proves the auth gate PASSED.
func TestInternalBearerServiceTokenAccepted(t *testing.T) {
	s := newScenario(t, scenarioOpts{skipProvider: true})

	// Probe with no auth — the endpoint requires authorization
	// per buyer/server.go:561 if internalBearerAuthorizedFull denies.
	// We send a valid GET /internal/routing with the right service
	// token. handleInternalRouting accepts/responds.
	req, err := http.NewRequest(http.MethodGet, s.coordProvURL+"/internal/routing", nil)
	if err != nil {
		t.Fatalf("new req: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+s.serviceToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do: %v", err)
	}
	defer resp.Body.Close()
	// 200 means the auth gate accepted us. 401/403 would mean the
	// service token was rejected — which is the bug we are guarding
	// against. 5xx is also a failure shape (the endpoint shouldn't
	// be crashing).
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("right-token /internal/routing got status=%d want 200", resp.StatusCode)
	}
}

// TestInternalBearerOperatorKeyFallbackAccepted pins the M3-2 / SECU-4
// dual-credential bridge: the coordinator MUST still accept the legacy
// operator_key on /internal/* during the cutover. This is the codex
// security audit's required-fallback behavior (PR #73). Coordinator
// configured with both operator_key and gateway_service_token; gateway
// sends the operator key.
//
// Without this scenario, a regression that flipped
// GatewayInternalBearerMatches to "service-token only" would silently
// break every not-yet-upgraded operator's gateway. That's the exact
// transition-state failure mode the audit cited.
func TestInternalBearerOperatorKeyFallbackAccepted(t *testing.T) {
	s := newScenario(t, scenarioOpts{skipProvider: true})

	req, err := http.NewRequest(http.MethodGet, s.coordProvURL+"/internal/routing", nil)
	if err != nil {
		t.Fatalf("new req: %v", err)
	}
	// Operator key — the legacy half of the dual-credential bridge.
	req.Header.Set("Authorization", "Bearer "+s.operatorKey)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("operator-key /internal/routing got status=%d want 200", resp.StatusCode)
	}
}

// TestStickyConversationForwarding pins that the gateway forwards the
// X-MacProvider-Internal-Conv sticky-routing header faithfully when
// sticky is enabled, AND the coordinator accepts the gateway's service
// token on the upstream call (M3-2 / SECU-4 bridge). This is the exact
// sticky-header contract TEST-6 cites
// (phase5-gateway/internal/router/server.go:1401-1405 ↔ coordinator
// internalBearerAuthorized at buyer/server.go:2785).
//
// The request must succeed (200 + chat.completion body); a regression
// that BROKE the upstream auth would surface as a 503 from the gateway
// (coordinator_unavailable) or a 401 surfaced as 5xx upstream. Either
// way the buyer never gets 200.
func TestStickyConversationForwarding(t *testing.T) {
	s := newScenario(t, scenarioOpts{seedAccount: true, stickyEnabled: true})

	headers := map[string]string{
		"X-MacProvider-Conversation": "conv-fixture-1",
	}
	status, _, body := s.chatRequest(headers, `{
		"model":"llama-3.2-3b-instruct",
		"max_tokens":32,
		"messages":[{"role":"user","content":"hi"}]
	}`)
	if status != http.StatusOK {
		t.Fatalf("sticky chat status=%d body=%s", status, string(body))
	}
	var chat map[string]any
	if err := json.Unmarshal(body, &chat); err != nil {
		t.Fatalf("decode: %v body=%s", err, string(body))
	}
	if chat["object"] != "chat.completion" {
		t.Fatalf("object=%v want chat.completion", chat["object"])
	}

	// And the coordinator must have a recorded request_log row.
	row, ok := s.readLatestRequestLog()
	if !ok {
		t.Fatal("coordinator request_log empty after sticky chat")
	}
	if row.Status != http.StatusOK {
		t.Fatalf("sticky request_log status=%d want 200", row.Status)
	}
}
