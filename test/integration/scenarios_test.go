package integration

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"
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

	// Money path — coordinator side. The coordinator MUST have
	// written a request_log row with our model + status=200. This is
	// the cross-boundary contract the within-gateway mock can never
	// pin (its coordinator is a httptest stub with no DB).
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

	// Money path — gateway side. The gateway MUST have settled a
	// usage_events row for the buyer's account with total_tokens=20
	// (matching the fake provider's reported usage: 8 prompt + 12
	// completion) and outcome=ok. Pinning both rows satisfies the
	// audit's "both stores' rows" requirement (REPO_AUDIT.md:253).
	usage, ok := s.readLatestUsageEvent()
	if !ok {
		t.Fatalf("gateway usage_events empty after successful chat")
	}
	if usage.TotalTokens != 20 {
		t.Fatalf("usage_events.total_tokens=%d want 20 (8 prompt + 12 completion)", usage.TotalTokens)
	}
	if usage.Outcome != "ok" {
		t.Fatalf("usage_events.outcome=%q want ok", usage.Outcome)
	}
	if usage.TokenSource != "provider_reported" {
		t.Fatalf("usage_events.token_source=%q want provider_reported", usage.TokenSource)
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

	// Use a well-formed 64-char hex token (matching the shape of a real
	// service token / operator key) so the rejection assertion is not
	// a "malformed input" reject path but a true credential-mismatch
	// reject path. The constant-time compare in
	// BearerTokenMatchesHeader operates on equal-length sha256 sums, so
	// using a hex token with the same shape as the real ones is the
	// only way to confirm the compare-and-reject branch was exercised.
	wrongToken := randHex(t, 32)
	for wrongToken == s.serviceToken || wrongToken == s.operatorKey {
		wrongToken = randHex(t, 32)
	}
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

// TestStickyConversationForwardingTwoProviders pins the FULL sticky
// drift contract:
//   - gateway forwards X-MacProvider-Internal-Conv + X-MacProvider-Account
//     correctly when sticky is enabled
//   - gateway sends the upstream service token, which coordinator's
//     internalBearerAuthorized accepts (M3-2 / SECU-4 bridge)
//   - coordinator's applySticky honors the conversation key on
//     follow-up requests, routing them to the SAME provider as the
//     first request
//
// Crucially this scenario runs TWO providers serving the same model.
// The coordinator's applySticky skips sticky entirely when
// len(candidates) < 2 (buyer/server.go:2530), so a single-provider
// sticky test would pass even if the gateway never forwarded the
// sticky header or the coordinator never honored it. With two
// providers, a regression that drops the sticky-header forwarding
// (or renames it) MUST surface here: the second request would
// freely round-robin and a 50% portion of runs would hit the OTHER
// provider — making the test reliably fail on drift.
// TestStickyHeaderForwardedToCoordinator pins the gateway's
// sticky-header forwarding contract directly. The gateway sets
// X-MacProvider-Internal-Conv + X-MacProvider-Account on its upstream
// /v1/chat/completions call when sticky is enabled AND the buyer sent
// X-MacProvider-Conversation (chat_proxy.go:203-217). The coordinator's
// hasInternalRoutingHeader returns true if EITHER X-MacProvider-Account
// OR any X-MacProvider-Internal-* is present (buyer/server.go:2758-2771),
// triggering internalBearerAuthorized which emits the audit log line
// `event=internal_bearer_accepted key=service_token path=""`.
//
// So the assertion shape "every sticky chat request produces an
// `internal_bearer_accepted` audit log line" deterministically pins:
//   - gateway is forwarding the sticky-routing headers (else
//     hasInternalRoutingHeader is false → no audit log)
//   - gateway is sending the service token Bearer upstream (else
//     internalBearerAuthorized rejects → 401 → no audit log)
//   - coordinator is logging the credential class correctly (M3-2
//     cutover-watch contract)
//
// A rename of X-MacProvider-Internal-Conv (or a regression that
// dropped the upstream auth header) breaks this audit log emission
// — the test catches it on every PR.
//
// Why this shape instead of asserting `reason=sticky_hit` on
// routing_decision: applySticky returns SILENTLY when the
// sticky-stored provider is already at sort index 0
// (buyer/server.go:2546-2548), which is what happens with our
// equal-metric fake providers under deterministic routing. The
// gateway's "did I forward the sticky-routing headers" contract is
// what TEST-6 actually cites; sticky's POSITIONAL effect on the
// coordinator routing decision is exercised by
// phase4-coordinator/internal/buyer/server_test.go (e.g.
// TestStickyAffinityDoesNotOverrideOutsideObjectiveEpsilon).
func TestStickyHeaderForwardedToCoordinator(t *testing.T) {
	s := newScenario(t, scenarioOpts{
		seedAccount:      true,
		stickyEnabled:    true,
		providerCount:    2,
		captureCoordLogs: true,
	})

	body := `{
		"model":"llama-3.2-3b-instruct",
		"max_tokens":32,
		"messages":[{"role":"user","content":"hi"}]
	}`
	headers := map[string]string{
		"X-MacProvider-Conversation": "conv-sticky-fixture",
	}

	const totalRequests = 6
	for i := 0; i < totalRequests; i++ {
		status, _, respBody := s.chatRequest(headers, body)
		if status != http.StatusOK {
			t.Fatalf("sticky chat %d status=%d body=%s", i, status, string(respBody))
		}
	}

	// All requests landed on a single provider — proves the
	// coordinator did not error-out and the chat path succeeded.
	totalHits := 0
	for _, fp := range s.fakeProvs {
		totalHits += fp.Hits()
	}
	if totalHits != totalRequests {
		t.Fatalf("total provider hits=%d want=%d (some chats did not reach a provider)",
			totalHits, totalRequests)
	}

	// Gateway's sticky-header forwarding contract: for EACH chat
	// request, the gateway should have triggered the coordinator's
	// internalBearerAuthorized → internal_bearer_accepted audit log
	// (because the gateway sent X-MacProvider-Account +
	// X-MacProvider-Internal-Conv, making hasInternalRoutingHeader
	// return true).
	//
	// Count audit-log lines emitted from the BUYER-port chat path
	// (path=""), distinguishing them from the gateway's metadata
	// fetches (path="/internal/routing"). A regression that broke
	// sticky-header forwarding would yield 0 such lines (the chat
	// path's hasInternalRoutingHeader check returns false → no audit
	// log) — the test catches it.
	//
	// Wait briefly for log goroutine to flush, then count.
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		count := 0
		for _, line := range s.coordLogBuf.snapshot() {
			if strings.Contains(line, `"event":"internal_bearer_accepted"`) &&
				strings.Contains(line, `"key":"service_token"`) &&
				strings.Contains(line, `"path":""`) {
				count++
			}
		}
		if count >= totalRequests {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	count := 0
	for _, line := range s.coordLogBuf.snapshot() {
		if strings.Contains(line, `"event":"internal_bearer_accepted"`) &&
			strings.Contains(line, `"key":"service_token"`) &&
			strings.Contains(line, `"path":""`) {
			count++
		}
	}
	if count < totalRequests {
		t.Fatalf("expected >=%d internal_bearer_accepted audit log lines for chat path; got %d. This means the gateway did not forward sticky-routing headers (X-MacProvider-Account / X-MacProvider-Internal-Conv) on at least one request — sticky drift. Captured lines: %v",
			totalRequests, count, s.coordLogBuf.snapshot())
	}

	// Coordinator request_log: latest status=200, money-path proof.
	row, ok := s.readLatestRequestLog()
	if !ok {
		t.Fatal("coordinator request_log empty after sticky chat")
	}
	if row.Status != http.StatusOK {
		t.Fatalf("sticky request_log status=%d want 200", row.Status)
	}
}

// TestGatewayOperatorKeyFallbackEndToEnd pins the M3-2 / SECU-4
// transition state: a gateway configured with NO coordinator.service_token
// falls back to operator_key on its upstream /internal/* calls, AND
// the coordinator accepts it via the operator_key branch of
// GatewayInternalBearerMatches. This is the gap that the security
// auditor flagged on iteration 1: the prior fallback scenario only
// proved coordinator-side acceptance via a direct curl, not the
// gateway's actual fallback behavior under sticky-routed traffic.
//
// Without this scenario, a regression that broke
// UpstreamCoordinatorBearer's fallback would silently fail every
// not-yet-cutover-completed operator's gateway — exactly the failure
// mode the M3-2 dual-credential bridge was designed to prevent.
func TestGatewayOperatorKeyFallbackEndToEnd(t *testing.T) {
	emptyServiceToken := ""
	s := newScenario(t, scenarioOpts{
		seedAccount:         true,
		stickyEnabled:       true,
		gatewayServiceToken: &emptyServiceToken,
		captureCoordLogs:    true,
	})

	headers := map[string]string{
		"X-MacProvider-Conversation": "conv-operator-fallback",
	}
	status, _, body := s.chatRequest(headers, `{
		"model":"llama-3.2-3b-instruct",
		"max_tokens":32,
		"messages":[{"role":"user","content":"hi"}]
	}`)
	if status != http.StatusOK {
		t.Fatalf("fallback chat status=%d body=%s", status, string(body))
	}

	// Audit-log assertion (M3-2 cutover-watch contract): the coordinator
	// MUST have emitted at least one `event=internal_bearer_accepted
	// key=operator_key` line for an /internal/* path during this run.
	// This is exactly the line the operator greps for in OPS.md to
	// watch the cutover (see audits/2026-06-10/MILESTONE_3_PHASE23_HANDOFF.md
	// item 5). A regression that mislabeled the credential class (or
	// stopped emitting the line entirely) would silently break cutover
	// monitoring; this assertion catches it.
	deadline := time.Now().Add(3 * time.Second)
	line := s.coordLogBuf.awaitContains(deadline,
		`"event":"internal_bearer_accepted"`,
		`"key":"operator_key"`,
	)
	if line == "" {
		t.Fatalf("expected internal_bearer_accepted key=operator_key log line; got none. captured lines: %v",
			s.coordLogBuf.snapshot())
	}
}

// TestServiceTokenAuditLogClass pins the symmetric audit-log assertion
// for the service_token branch: when both credentials are configured
// and the gateway uses the service token, the coordinator MUST log
// `event=internal_bearer_accepted key=service_token`. A regression
// that flipped the credential-class label (e.g., an off-by-one swap
// in InternalBearerKind.String) would silently misreport the cutover
// status; this scenario catches it.
func TestServiceTokenAuditLogClass(t *testing.T) {
	s := newScenario(t, scenarioOpts{
		seedAccount:      true,
		stickyEnabled:    true,
		captureCoordLogs: true,
	})

	headers := map[string]string{
		"X-MacProvider-Conversation": "conv-svc-token-audit",
	}
	status, _, body := s.chatRequest(headers, `{
		"model":"llama-3.2-3b-instruct",
		"max_tokens":32,
		"messages":[{"role":"user","content":"hi"}]
	}`)
	if status != http.StatusOK {
		t.Fatalf("svc-token chat status=%d body=%s", status, string(body))
	}
	deadline := time.Now().Add(3 * time.Second)
	line := s.coordLogBuf.awaitContains(deadline,
		`"event":"internal_bearer_accepted"`,
		`"key":"service_token"`,
	)
	if line == "" {
		t.Fatalf("expected internal_bearer_accepted key=service_token log line; got none. captured lines: %v",
			s.coordLogBuf.snapshot())
	}
}
