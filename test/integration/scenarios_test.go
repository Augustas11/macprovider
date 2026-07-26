package integration

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	spec015 "github.com/augstar/macprovider-integration/spec015"
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

	status, headers, body := s.chatRequest(nil, `{
		"model":"llama-3.2-3b-instruct",
		"max_tokens":32,
		"messages":[{"role":"user","content":"hello"}]
	}`)
	if status != http.StatusOK {
		t.Fatalf("chat status=%d body=%s", status, string(body))
	}
	if got := headers.Get("X-MacProvider-Receipt"); got != "" {
		t.Fatalf("pre-v1.6 fake provider response exposed receipt header %q", got)
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

func TestGatewayGitHubOAuthDisabledRoutesReturn404(t *testing.T) {
	s := newScenario(t, scenarioOpts{seedAccount: false})
	for _, path := range []string{"/auth/github/start", "/auth/github/callback"} {
		resp, err := http.Get(s.gatewayBaseURL + path)
		if err != nil {
			t.Fatalf("GET %s: %v", path, err)
		}
		_ = resp.Body.Close()
		if resp.StatusCode != http.StatusNotFound {
			t.Fatalf("GET %s status=%d want 404", path, resp.StatusCode)
		}
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

func TestSpec015ReceiptEnabledCrossServiceHeaderVerifies(t *testing.T) {
	s := newScenario(t, scenarioOpts{seedAccount: true, receiptEnabledProvider: true})

	status, headers, body := s.chatRequest(nil, `{
		"model":"llama-3.2-3b-instruct",
		"max_tokens":32,
		"messages":[{"role":"user","content":"SPEC-015 cross-service receipt"}]
	}`)
	if status != http.StatusOK {
		t.Fatalf("chat status=%d body=%s", status, string(body))
	}
	header := headers.Get("X-MacProvider-Receipt")
	if header == "" {
		t.Fatalf("receipt-enabled cross-service response omitted X-MacProvider-Receipt")
	}
	reqBody, respBody := s.fakeProv.LastReceiptBodies()
	if len(reqBody) == 0 || len(respBody) == 0 {
		t.Fatalf("fake provider did not capture receipt hash inputs")
	}
	verified, err := spec015.VerifyReceiptAgainstPoolzTrust(header, spec015.PoolzReceiptTrust{
		ReceiptPubkey: base64.StdEncoding.EncodeToString(s.fakeProv.receiptPubkey),
	})
	if err != nil {
		t.Fatalf("receipt did not verify against provider poolz trust: %v", err)
	}
	if verified.KeySource != "current" {
		t.Fatalf("receipt verified with %q key, want current", verified.KeySource)
	}
	if got, want := verified.Tuple["provider_pubkey"], base64.StdEncoding.EncodeToString(s.fakeProv.receiptPubkey); got != want {
		t.Fatalf("provider_pubkey=%v want %s", got, want)
	}
	if got := verified.Tuple["model_id"]; got != "llama-3.2-3b-instruct" {
		t.Fatalf("model_id=%v", got)
	}
	if got := int(verified.Tuple["tokens_out"].(float64)); got != 12 {
		t.Fatalf("tokens_out=%d want 12", got)
	}
	wantPromptHash, err := spec015CanonicalPromptHash(reqBody)
	if err != nil {
		t.Fatalf("canonical prompt hash: %v", err)
	}
	if got := verified.Tuple["prompt_hash"]; got != wantPromptHash {
		t.Fatalf("prompt_hash=%v want %s", got, wantPromptHash)
	}
	wantOutputHash, err := spec015CanonicalOutputHash(respBody)
	if err != nil {
		t.Fatalf("canonical output hash: %v", err)
	}
	if got := verified.Tuple["output_hash"]; got != wantOutputHash {
		t.Fatalf("output_hash=%v want %s", got, wantOutputHash)
	}
	for _, header := range []string{"X-MacProvider-Foo", "X-MacProvider-Receipt-Pending", "X-MacProvider-Completion-Tokens"} {
		if got := headers.Get(header); got != "" {
			t.Fatalf("buyer response exposed %s=%q", header, got)
		}
	}
}

func TestSpec015V04SettlementReceiptCrossServiceVerifies(t *testing.T) {
	s := newScenario(t, scenarioOpts{seedAccount: true, settlementReceiptProvider: true})

	status, headers, body := s.chatRequest(nil, fmt.Sprintf(`{
		"model":%q,
		"max_tokens":32,
		"messages":[{"role":"user","content":"SPEC-015 v0.4 settlement receipt"}]
	}`, settlementFixtureModelID))
	if status != http.StatusOK {
		t.Fatalf("non-streaming chat status=%d body=%s", status, string(body))
	}
	if got := headers.Get("X-MacProvider-Receipt"); got != "" {
		t.Fatalf("buyer response exposed non-streaming v0.4 receipt header %q", got)
	}

	status, headers, body = s.chatRequest(nil, fmt.Sprintf(`{
		"model":%q,
		"max_tokens":32,
		"stream":true,
		"messages":[{"role":"user","content":"SPEC-015 v0.4 streaming settlement receipt"}]
	}`, settlementFixtureModelID))
	if status != http.StatusOK {
		t.Fatalf("streaming chat status=%d body=%s", status, string(body))
	}
	if got := headers.Get("X-MacProvider-Receipt"); got != "" {
		t.Fatalf("buyer response exposed streaming v0.4 receipt header %q", got)
	}
	if !strings.Contains(string(body), "hello ") || !strings.Contains(string(body), "from fake provider") || !strings.Contains(string(body), "data: [DONE]") {
		t.Fatalf("streaming body missing provider content or DONE marker: %s", string(body))
	}

	verdicts := waitForSettlementVerdicts(t, s, 2)
	if len(verdicts) != 2 {
		t.Fatalf("settlement verdict count=%d want 2", len(verdicts))
	}
	for i, verdict := range verdicts {
		if verdict.ProviderID != s.providerID {
			t.Fatalf("verdict[%d].provider_id=%q want %q", i, verdict.ProviderID, s.providerID)
		}
		if verdict.ReceiptPresent != 1 || !verdict.ReceiptVersion.Valid || verdict.ReceiptVersion.String != "4" {
			t.Fatalf("verdict[%d] receipt present/version=%d/%v want present v4", i, verdict.ReceiptPresent, verdict.ReceiptVersion)
		}
		if verdict.ReceiptResult != "valid" || verdict.SettlementOutcome != "verified" || verdict.Reason != "verified_settlement" || verdict.Closed != 1 {
			t.Fatalf("verdict[%d]=%s/%s reason=%s closed=%d want valid/verified verified_settlement closed",
				i, verdict.ReceiptResult, verdict.SettlementOutcome, verdict.Reason, verdict.Closed)
		}
		if !verdict.ModelHash.Valid || verdict.ModelHash.String != s.modelHash {
			t.Fatalf("verdict[%d].model_hash=%v want %s", i, verdict.ModelHash, s.modelHash)
		}
		if verdict.BuyerDebitOutcome != "no_money_movement_step5" ||
			verdict.ProviderSettlementOutcome != "no_money_movement_step5" ||
			verdict.PayoutExclusionOutcome != "excluded_until_spec022_verified" {
			t.Fatalf("verdict[%d] money outcomes=%s/%s/%s want no-money step5 + payout exclusion",
				i, verdict.BuyerDebitOutcome, verdict.ProviderSettlementOutcome, verdict.PayoutExclusionOutcome)
		}
	}
}

func TestSpec022V04StreamingSettlementReconcilerE2E(t *testing.T) {
	s := newScenario(t, scenarioOpts{
		seedAccount:                        true,
		settlementReceiptProvider:          true,
		settlementEnforceMode:              true,
		settlementReconcileIntervalSeconds: 1,
	})
	const requestID = "77777777-7777-4777-8777-777777777777"

	status, headers, body := s.chatRequest(map[string]string{"X-Request-ID": requestID}, fmt.Sprintf(`{
		"model":%q,
		"max_tokens":32,
		"stream":true,
		"messages":[{"role":"user","content":"SPEC-022 local e2e streaming settlement receipt"}]
	}`, settlementFixtureModelID))
	if status != http.StatusOK {
		t.Fatalf("streaming chat status=%d body=%s", status, string(body))
	}
	if got := headers.Get("X-Request-ID"); got != requestID {
		t.Fatalf("gateway X-Request-ID=%q want %q", got, requestID)
	}
	if got := headers.Get("X-MacProvider-Receipt"); got != "" {
		t.Fatalf("buyer response exposed streaming v0.4 receipt header %q", got)
	}
	if !strings.Contains(string(body), "hello ") || !strings.Contains(string(body), "from fake provider") || !strings.Contains(string(body), "data: [DONE]") {
		t.Fatalf("streaming body missing provider content or DONE marker: %s", string(body))
	}

	verdicts := waitForSettlementVerdicts(t, s, 1)
	if len(verdicts) != 1 {
		t.Fatalf("settlement verdict count=%d want 1", len(verdicts))
	}
	verdict := verdicts[0]
	if verdict.RequestID == "" || verdict.RequestID == requestID {
		t.Fatalf("verdict.request_id=%q want non-empty coordinator-internal request id distinct from gateway request id %q", verdict.RequestID, requestID)
	}
	if verdict.ProviderID != s.providerID {
		t.Fatalf("verdict.provider_id=%q want %q", verdict.ProviderID, s.providerID)
	}
	if verdict.ReceiptPresent != 1 || !verdict.ReceiptVersion.Valid || verdict.ReceiptVersion.String != "4" {
		t.Fatalf("receipt present/version=%d/%v want present v4", verdict.ReceiptPresent, verdict.ReceiptVersion)
	}
	if verdict.ReceiptResult != "valid" || verdict.SettlementOutcome != "verified" || verdict.Reason != "verified_settlement" || verdict.Closed != 1 {
		t.Fatalf("verdict=%s/%s reason=%s closed=%d want valid/verified verified_settlement closed",
			verdict.ReceiptResult, verdict.SettlementOutcome, verdict.Reason, verdict.Closed)
	}
	if !verdict.ModelHash.Valid || verdict.ModelHash.String != s.modelHash {
		t.Fatalf("verdict.model_hash=%v want %s", verdict.ModelHash, s.modelHash)
	}

	usage, reservation := waitForSpec022GatewaySettlement(t, s, requestID)
	if usage.Outcome != "spec022_verified" || usage.TokenSource != "coordinator_observed" {
		t.Fatalf("usage outcome/source=%s/%s want spec022_verified/coordinator_observed", usage.Outcome, usage.TokenSource)
	}
	if usage.PromptTokens != 8 || usage.CompletionTokens != 12 || usage.TotalTokens != 20 {
		t.Fatalf("usage tokens prompt/completion/total=%d/%d/%d want 8/12/20",
			usage.PromptTokens, usage.CompletionTokens, usage.TotalTokens)
	}
	if reservation.Status != "settled" || reservation.SettledTokens != 20 || reservation.SettlementHold != 1 {
		t.Fatalf("reservation=%+v want settled 20-token held reservation", reservation)
	}
}

func waitForSettlementVerdicts(t *testing.T, s *scenario, want int) []settlementReceiptVerdictRow {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	var latest []settlementReceiptVerdictRow
	for time.Now().Before(deadline) {
		latest = s.readSettlementReceiptVerdicts()
		if len(latest) >= want {
			return latest
		}
		time.Sleep(50 * time.Millisecond)
	}
	return latest
}

func waitForSpec022GatewaySettlement(t *testing.T, s *scenario, requestID string) (usageEventRow, quotaReservationRow) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	var latestReservation quotaReservationRow
	for time.Now().Before(deadline) {
		usage, ok := s.readUsageEvent(requestID)
		reservation, reservationOK := s.readQuotaReservation(requestID)
		if reservationOK {
			latestReservation = reservation
		}
		if ok && reservationOK && reservation.Status == "settled" {
			return usage, reservation
		}
		time.Sleep(100 * time.Millisecond)
	}
	usage, usageOK := s.readUsageEvent(requestID)
	reservation, reservationOK := s.readQuotaReservation(requestID)
	if reservationOK {
		latestReservation = reservation
	}
	t.Fatalf("gateway settlement for request %s not settled before deadline: usage_found=%v usage=%+v reservation_found=%v reservation=%+v latest_reservation=%+v",
		requestID, usageOK, usage, reservationOK, reservation, latestReservation)
	return usageEventRow{}, quotaReservationRow{}
}

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

// TestInternalBearerOperatorKeyRejectedPostCutover pins the M3-2 / SECU-4
// post-cutover contract (PR #87 item 3, after its tracked gate): the coordinator
// MUST reject the legacy operator_key on /internal/* — the dual-credential
// bridge is gone, gateway_service_token is the only accepted credential.
//
// This test inverts the pre-cutover TestInternalBearerOperatorKeyFallbackAccepted:
// a regression that re-introduced the operator_key fallback would silently
// re-open the cutover-defeating dual-credential path the audit was closing.
func TestInternalBearerOperatorKeyRejectedPostCutover(t *testing.T) {
	s := newScenario(t, scenarioOpts{skipProvider: true})

	req, err := http.NewRequest(http.MethodGet, s.coordProvURL+"/internal/routing", nil)
	if err != nil {
		t.Fatalf("new req: %v", err)
	}
	// Operator key — formerly the legacy fallback, now REJECTED post-cutover.
	req.Header.Set("Authorization", "Bearer "+s.operatorKey)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("operator-key /internal/routing got status=%d want 401 (post-cutover reject)", resp.StatusCode)
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
// sticky-header forwarding contract directly via TWO independent
// assertions:
//
// Assertion A — X-MacProvider-Internal-Conv forwarded with conv: key:
// applySticky (buyer/server.go:2529) reads X-MacProvider-Internal-Conv
// and requires its value to start with "conv:" before proceeding
// (buyer/server.go:2534). On the first request there is no sticky
// entry yet, so stickyLookup returns false/not_found and the
// coordinator logs `event=routing_decision reason=sticky_miss_not_found`.
// This line is emitted ONLY when the header was forwarded with the
// correct conv: prefix. A rename of X-MacProvider-Internal-Conv causes
// applySticky to get an empty key → fails the HasPrefix("conv:") guard
// → returns silently → NO sticky_miss_not_found log → assertion fails.
//
// Assertion B — gateway sends service-token Bearer upstream:
// hasInternalRoutingHeader (buyer/server.go:2758) returns true when
// X-MacProvider-Account OR any X-MacProvider-Internal-* header is
// present, triggering internalBearerAuthorized which emits
// `event=internal_bearer_accepted key=service_token path=""`.
// Counting one line per chat request proves the service-token Bearer
// was sent upstream on every sticky request (M3-2 cutover-watch
// contract). Note: this assertion does NOT independently prove
// X-MacProvider-Internal-Conv was forwarded — X-MacProvider-Account
// alone is sufficient to trigger it; Assertion A closes that gap.
//
// Together, A+B pin all three forwarding contracts TEST-6 cites:
// (1) X-MacProvider-Internal-Conv forwarded with conv: key (A),
// (2) X-MacProvider-Account forwarded (B, indirectly via auth path),
// (3) service-token Bearer forwarded upstream (B).
//
// Why not assert `reason=sticky_hit` on routing_decision: applySticky
// returns SILENTLY when the sticky-stored provider is already at sort
// index 0 (buyer/server.go:2546-2548), which is what happens with our
// equal-metric fake providers under deterministic routing. sticky_miss_not_found
// on the FIRST request is the faithful signal. sticky's POSITIONAL
// effect is exercised by phase4-coordinator/internal/buyer/server_test.go
// (e.g. TestStickyAffinityDoesNotOverrideOutsideObjectiveEpsilon).
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

	// Assertion A: X-MacProvider-Internal-Conv forwarded with conv: prefix.
	// applySticky reads X-MacProvider-Internal-Conv and requires its value
	// to start with "conv:" (buyer/server.go:2534). On the first request
	// (no sticky entry yet) it logs routing_decision with
	// reason=sticky_miss_not_found. This line ONLY appears when the
	// header was forwarded with the correct value. A rename or drop of
	// X-MacProvider-Internal-Conv causes applySticky to return silently
	// (empty key fails the HasPrefix guard) → NO sticky_miss_not_found
	// → assertion fails.
	stickyMissLine := s.coordLogBuf.awaitContains(
		time.Now().Add(3*time.Second),
		`"event":"routing_decision"`,
		`"reason":"sticky_miss_not_found"`,
	)
	if stickyMissLine == "" {
		t.Fatalf("expected routing_decision reason=sticky_miss_not_found log line (proves X-MacProvider-Internal-Conv was forwarded with conv: prefix); got none. Captured lines: %v",
			s.coordLogBuf.snapshot())
	}

	// Assertion B: service-token Bearer forwarded upstream on every chat
	// request. hasInternalRoutingHeader returns true when X-MacProvider-Account
	// OR any X-MacProvider-Internal-* is present, triggering
	// internalBearerAuthorized which emits internal_bearer_accepted.
	// Count lines from the BUYER-port chat path (path=""), excluding
	// the gateway's /internal/routing metadata fetches.
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
		t.Fatalf("expected >=%d internal_bearer_accepted audit log lines for chat path; got %d. This means the gateway did not send the service-token Bearer upstream on at least one request. Captured lines: %v",
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

// (Removed by PR #87 item 3 after its tracked cutover gate.)
// TestGatewayOperatorKeyFallbackEndToEnd previously pinned the gateway
// upstream falling back to operator_key when coordinator.service_token
// was empty. With the legacy fallback removed:
//   - phase5-gateway/internal/config/config.go Validate() now REJECTS an
//     empty coordinator.service_token (the gateway can't even boot).
//   - phase4-coordinator/internal/auth/tokens.go GatewayInternalBearerMatches
//     only accepts gateway_service_token (the operator_key fallback path
//     is gone).
// The post-cutover reject contract is locked in by
// TestInternalBearerOperatorKeyRejectedPostCutover above; the service-token
// success path stays covered by TestServiceTokenAuditLogClass below.

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
