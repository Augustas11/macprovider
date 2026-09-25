package router

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// settlementFinalityMACGolden is the coordinator's pinned vector
// (phase4-coordinator TestSettlementFinalityMACGoldenVector): both sides
// must compute the same MAC.
const settlementFinalityMACGolden = "ae41121fb9352158dbbd4cfefd1095baae9f4ebbeda2b8942c010854275b9270"

func TestSettlementFinalityMACMatchesCoordinatorGolden(t *testing.T) {
	values := []string{"quarantined", "invalid", "signature_verify_failed", "true", "enforce", "1", ""}
	if got := settlementFinalityMAC("service-token", "acct_1", "req-1", "internal-1", values); got != settlementFinalityMACGolden {
		t.Fatalf("finality MAC=%s, want the coordinator golden %s", got, settlementFinalityMACGolden)
	}
	// The key is trimmed on both sides (the coordinator trims its token).
	if got := settlementFinalityMAC(" service-token\n", "acct_1", "req-1", "internal-1", values); got != settlementFinalityMACGolden {
		t.Fatalf("untrimmed key MAC=%s", got)
	}
}

const (
	testKey      = "service-token"
	testAccount  = "acct_1"
	testReqID    = "req-1"
	testInternal = "internal-1"
)

func testBinding(pin bool) settlementFinalityBinding {
	return settlementFinalityBinding{key: testKey, accountID: testAccount, requestID: testReqID, requireSigned: pin}
}

func quarantinedFinality() http.Header {
	h := http.Header{}
	h.Set(settlementOutcomeHeader, "quarantined")
	h.Set(settlementReceiptResultHeader, "invalid")
	h.Set(settlementReasonHeader, "signature_verify_failed")
	h.Set(settlementClosedHeader, "true")
	h.Set(settlementModeHeader, "enforce")
	h.Set(settlementPolicyVersionHeader, settlementPolicyVersion)
	return h
}

func legacyFinality() http.Header {
	h := http.Header{}
	h.Set(settlementModeHeader, "legacy")
	return h
}

// recordFailedRefundFinality is the coordinator's closed refund tuple for a
// failed post-delivery record.
func recordFailedRefundFinality() http.Header {
	h := http.Header{}
	h.Set(settlementOutcomeHeader, "quarantined")
	h.Set(settlementReceiptResultHeader, "inconclusive")
	h.Set(settlementReasonHeader, "settlement_record_failed_after_delivery")
	h.Set(settlementClosedHeader, "true")
	h.Set(settlementModeHeader, "enforce")
	h.Set(settlementPolicyVersionHeader, settlementPolicyVersion)
	return h
}

func signFinality(key, account, requestID, internalID string, h http.Header) {
	h.Set(settlementFinalityMACHeader, settlementFinalityMAC(key, account, requestID, internalID, settlementFinalityMACValues(h)))
}

func withInternalID(h http.Header, id string) http.Header {
	h.Set(coordinatorInternalRequestIDHeader, id)
	return h
}

func declaredTrailerResponse(trailer http.Header) *http.Response {
	resp := &http.Response{Header: withInternalID(http.Header{"Content-Type": {"application/json"}}, testInternal), Trailer: trailer}
	resp.Header.Add("Trailer", settlementOutcomeHeader+", "+settlementReceiptResultHeader+", "+settlementClosedHeader+", "+settlementModeHeader+", "+settlementPolicyVersionHeader)
	resp.Header.Add("Trailer", settlementFinalityMACHeader)
	return resp
}

func isMissingHold(got coordinatorSettlementFinality) bool {
	return got.Action == settlementFinalityHold && got.Reason == missingSettlementFinalityTrailer
}

// Review F1/F4: non-streaming trailer finality is authoritative only when it
// arrived with a valid MAC; missing values, a missing MAC or a tampered tuple
// hold, never fall back to a local debit.
func TestCoordinatorNonStreamingSettlementFinality(t *testing.T) {
	b := testBinding(false)
	if got := coordinatorNonStreamingSettlementFinality(&http.Response{Header: http.Header{}}, b); got.Action != settlementFinalityLegacy {
		t.Fatalf("no finality anywhere: %+v, want legacy", got)
	}
	if got := coordinatorNonStreamingSettlementFinality(&http.Response{Header: quarantinedFinality()}, b); got.Action != settlementFinalityRefund {
		t.Fatalf("header finality from an older coordinator: %+v, want refund", got)
	}
	signed := quarantinedFinality()
	signFinality(testKey, testAccount, testReqID, testInternal, signed)
	if got := coordinatorNonStreamingSettlementFinality(declaredTrailerResponse(signed), b); got.Action != settlementFinalityRefund || got.Outcome != "quarantined" {
		t.Fatalf("signed trailer finality: %+v, want the quarantined refund", got)
	}
	hold := func(name string, resp *http.Response, b settlementFinalityBinding) {
		t.Helper()
		if got := coordinatorNonStreamingSettlementFinality(resp, b); !isMissingHold(got) {
			t.Fatalf("%s: %+v, want a missing_settlement_finality_trailer hold", name, got)
		}
	}
	hold("declared, values stripped", declaredTrailerResponse(http.Header{}), b)
	hold("missing MAC", declaredTrailerResponse(quarantinedFinality()), b)
	tampered := quarantinedFinality()
	tampered.Set(settlementOutcomeHeader, "verified")
	tampered.Set(settlementReceiptResultHeader, "valid")
	signFinality(testKey, testAccount, testReqID, testInternal, tampered)
	tampered.Set(settlementOutcomeHeader, "quarantined")
	tampered.Set(settlementReceiptResultHeader, "invalid")
	hold("tampered tuple", declaredTrailerResponse(tampered), b)
	otherRequest := quarantinedFinality()
	signFinality(testKey, testAccount, "req-2", testInternal, otherRequest)
	hold("tuple replayed from another request", declaredTrailerResponse(otherRequest), b)
	otherAttempt := quarantinedFinality()
	signFinality(testKey, testAccount, testReqID, "internal-2", otherAttempt)
	hold("tuple replayed from another coordinator attempt", declaredTrailerResponse(otherAttempt), b)
	hold("no MAC key", declaredTrailerResponse(signed), settlementFinalityBinding{accountID: testAccount, requestID: testReqID})
	stripped := declaredTrailerResponse(http.Header{})
	for name, values := range quarantinedFinality() {
		stripped.Header[name] = values
	}
	hold("declared trailers stripped, header tuple injected", stripped, b)
	// The signed legacy tuple (no route snapshot) settles locally.
	legacy := legacyFinality()
	signFinality(testKey, testAccount, testReqID, testInternal, legacy)
	if got := coordinatorNonStreamingSettlementFinality(declaredTrailerResponse(legacy), b); got.Action != settlementFinalityLegacy {
		t.Fatalf("signed legacy trailers: %+v, want legacy", got)
	}
	refund := recordFailedRefundFinality()
	signFinality(testKey, testAccount, testReqID, testInternal, refund)
	if got := coordinatorNonStreamingSettlementFinality(declaredTrailerResponse(refund), b); got.Action != settlementFinalityRefund {
		t.Fatalf("signed record-failed tuple: %+v, want a terminal refund", got)
	}
}

// The coordinator.require_settlement_trailers pin: only a stripped
// declaration or MAC holds; every signed tuple, the no-snapshot legacy
// tuple included, settles.
func TestRequireSettlementTrailersPinFinality(t *testing.T) {
	pin := testBinding(true)
	if got := coordinatorNonStreamingSettlementFinality(&http.Response{Header: withInternalID(quarantinedFinality(), testInternal)}, pin); !isMissingHold(got) {
		t.Fatalf("pin on, declaration stripped, unsigned header tuple: %+v, want a hold", got)
	}
	if got := coordinatorNonStreamingSettlementFinality(&http.Response{Header: http.Header{}}, pin); !isMissingHold(got) {
		t.Fatalf("pin on, no finality at all: %+v, want a hold, not legacy", got)
	}
	signed := quarantinedFinality()
	signFinality(testKey, testAccount, testReqID, testInternal, signed)
	if got := coordinatorNonStreamingSettlementFinality(declaredTrailerResponse(signed), pin); got.Action != settlementFinalityRefund {
		t.Fatalf("pin on, signed trailers: %+v, want the refund", got)
	}
	if got := coordinatorNonStreamingSettlementFinality(&http.Response{Header: quarantinedFinality()}, testBinding(false)); got.Action != settlementFinalityRefund {
		t.Fatalf("pin off, header finality: %+v, want the header refund", got)
	}

	// Streaming.
	if got := coordinatorStreamingSettlementFinality(&http.Response{Header: withInternalID(quarantinedFinality(), testInternal)}, pin); !isMissingHold(got) {
		t.Fatalf("streaming, pin on, unsigned headers: %+v, want a hold", got)
	}
	if got := coordinatorStreamingSettlementFinality(&http.Response{Header: http.Header{}}, pin); !isMissingHold(got) {
		t.Fatalf("streaming, pin on, no finality: %+v, want a hold, not legacy", got)
	}
	signedLegacyHeaders := withInternalID(legacyFinality(), testInternal)
	signFinality(testKey, testAccount, testReqID, testInternal, signedLegacyHeaders)
	if got := coordinatorStreamingSettlementFinality(&http.Response{Header: signedLegacyHeaders}, pin); got.Action != settlementFinalityLegacy {
		t.Fatalf("streaming, pin on, signed no-snapshot legacy headers: %+v, want legacy", got)
	}
	if got := coordinatorStreamingSettlementFinality(declaredTrailerResponse(quarantinedFinality()), pin); !isMissingHold(got) {
		t.Fatalf("streaming, pin on, unsigned trailers: %+v, want a hold", got)
	}
	if got := coordinatorStreamingSettlementFinality(declaredTrailerResponse(signed), pin); got.Action != settlementFinalityRefund {
		t.Fatalf("streaming, pin on, signed trailers: %+v, want the refund", got)
	}
	if got := coordinatorStreamingSettlementFinality(&http.Response{Header: http.Header{}, Trailer: quarantinedFinality()}, testBinding(false)); got.Action != settlementFinalityRefund {
		t.Fatalf("streaming, pin off, older coordinator's unsigned trailers: %+v, want the refund", got)
	}
	if got := coordinatorStreamingSettlementFinality(&http.Response{Header: http.Header{}}, testBinding(false)); got.Action != settlementFinalityLegacy {
		t.Fatalf("streaming, pin off, no finality: %+v, want legacy", got)
	}

	// A stream the gateway ends itself settles locally only on a (with the
	// pin, signed) legacy header tuple or, without the pin, no finality.
	if streamingLocalTerminalMustHold(&http.Response{Header: signedLegacyHeaders}, pin) {
		t.Fatal("pin on, signed legacy headers: a local terminal was held")
	}
	if !streamingLocalTerminalMustHold(&http.Response{Header: http.Header{}}, pin) {
		t.Fatal("pin on, no finality: a local terminal settled locally")
	}
	if streamingLocalTerminalMustHold(&http.Response{Header: http.Header{}}, testBinding(false)) {
		t.Fatal("pin off, no finality: a local terminal was held")
	}
	if !streamingLocalTerminalMustHold(declaredTrailerResponse(http.Header{}), testBinding(false)) {
		t.Fatal("declared trailers: a local terminal settled locally")
	}
}

const trailerTestCompletion = `{"id":"chatcmpl_1","object":"chat.completion","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`

const trailerTestSSE = "data: {\"id\":\"c\",\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":4,\"total_tokens\":7},\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"

type trailerChatCase struct {
	name    string
	pin     bool
	stream  bool
	respond func(r *http.Request) *http.Response
	check   func(t *testing.T, got gatewaySettlementState)
}

func runTrailerChatCases(t *testing.T, prefix string, cases []trailerChatCase) {
	t.Helper()
	for i, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var advertised string
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				if r.URL.Path == "/v1/chat/completions" {
					advertised = r.Header.Get(settlementTrailersCapabilityHeader)
					return tc.respond(r), nil
				}
				// A held settlement nudges the reconciler's finality lookup.
				return responseWithBody(http.StatusNotFound, nil, `{}`), nil
			})}
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
				cfg.Coordinator.ServiceToken = testKey
				cfg.Coordinator.RequireSettlementTrailers = tc.pin
			}, WithHTTPClient(client))
			accountID := prefix + string(rune('a'+i))
			fullKey := createAccountAndKey(t, store, cfg, accountID)
			body := `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
			if tc.stream {
				body = `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
			}
			// A buyer-supplied copy of the capability header is never
			// forwarded: the gateway sets its own.
			resp := postChat(t, h, fullKey, body, map[string]string{settlementTrailersCapabilityHeader: "0"})
			if resp.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
			}
			if advertised != "1" {
				t.Fatalf("capability header=%q, want the gateway's own 1", advertised)
			}
			tc.check(t, gatewaySettlementSnapshot(t, dbPath, accountID))
		})
	}
}

// signedTrailerReply is a negotiating coordinator's non-streaming 200.
func signedTrailerReply(tuple func() http.Header) func(r *http.Request) *http.Response {
	return func(r *http.Request) *http.Response {
		trailer := tuple()
		signFinality(testKey, r.Header.Get("X-MacProvider-Account"), r.Header.Get("X-Request-ID"), testInternal, trailer)
		resp := declaredTrailerResponse(trailer)
		resp.StatusCode, resp.Body = http.StatusOK, io.NopCloser(strings.NewReader(trailerTestCompletion))
		return resp
	}
}

func wantHeld(t *testing.T, got gatewaySettlementState) {
	t.Helper()
	if got.usageRows != 0 || got.settledRows != 0 || got.refundedRows != 0 || got.activeRows != 1 {
		t.Fatalf("snapshot=%+v, want a held reservation and no debit", got)
	}
}

func wantRefunded(t *testing.T, got gatewaySettlementState) {
	t.Helper()
	if got.usageRows != 0 || got.refundedRows != 1 || got.activeRows != 0 {
		t.Fatalf("snapshot=%+v, want a refund and no usage", got)
	}
}

func wantLocalDebit(t *testing.T, got gatewaySettlementState) {
	t.Helper()
	if got.usageRows != 1 || got.settledRows != 1 || got.activeRows != 0 {
		t.Fatalf("snapshot=%+v, want the legacy local debit", got)
	}
}

// Integration through the chat path, both mixed pairings included.
func TestNonStreamingTrailerFinalityThroughChatPath(t *testing.T) {
	runTrailerChatCases(t, "acct_trailer_finality_", []trailerChatCase{
		{name: "negotiated coordinator, signed quarantined trailers refund", respond: signedTrailerReply(quarantinedFinality), check: wantRefunded},
		{name: "negotiated coordinator, trailers stripped hold", respond: func(r *http.Request) *http.Response {
			resp := declaredTrailerResponse(http.Header{})
			resp.StatusCode, resp.Body = http.StatusOK, io.NopCloser(strings.NewReader(trailerTestCompletion))
			return resp
		}, check: wantHeld},
		{name: "negotiated coordinator, unsigned quarantined trailers hold", respond: func(r *http.Request) *http.Response {
			resp := declaredTrailerResponse(quarantinedFinality())
			resp.StatusCode, resp.Body = http.StatusOK, io.NopCloser(strings.NewReader(trailerTestCompletion))
			return resp
		}, check: wantHeld},
		// Review R2 MEDIUM 1: the record-failed tuple reaches a terminal
		// refund with no reconciler or operator step.
		{name: "negotiated coordinator, record failed after delivery refunds", respond: signedTrailerReply(recordFailedRefundFinality), check: wantRefunded},
		{name: "older coordinator, header finality still honored", respond: func(r *http.Request) *http.Response {
			h := quarantinedFinality()
			h.Set("Content-Type", "application/json")
			return responseWithBody(http.StatusOK, h, trailerTestCompletion)
		}, check: wantRefunded},
		{name: "older coordinator, no finality settles locally", respond: func(r *http.Request) *http.Response {
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": {"application/json"}}, trailerTestCompletion)
		}, check: wantLocalDebit},
	})
}

func TestRequireSettlementTrailersPinThroughChatPath(t *testing.T) {
	strippedNonStream := func(r *http.Request) *http.Response {
		h := quarantinedFinality()
		h.Set("Content-Type", "application/json")
		return responseWithBody(http.StatusOK, h, trailerTestCompletion)
	}
	strippedStream := func(r *http.Request) *http.Response {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": {"text/event-stream; charset=utf-8"}}, trailerTestSSE)
	}
	signedLegacyStream := func(r *http.Request) *http.Response {
		h := withInternalID(legacyFinality(), testInternal)
		signFinality(testKey, r.Header.Get("X-MacProvider-Account"), r.Header.Get("X-Request-ID"), testInternal, h)
		h.Set("Content-Type", "text/event-stream; charset=utf-8")
		return responseWithBody(http.StatusOK, h, trailerTestSSE)
	}
	runTrailerChatCases(t, "acct_trailer_pin_", []trailerChatCase{
		{name: "non-streaming, pin on, declaration stripped", pin: true, respond: strippedNonStream, check: wantHeld},
		{name: "non-streaming, pin on, signed trailers", pin: true, respond: signedTrailerReply(quarantinedFinality), check: wantRefunded},
		// Review R2 HIGH: a no-snapshot 200 settles under the pin.
		{name: "non-streaming, pin on, no snapshot signed legacy trailers", pin: true, respond: signedTrailerReply(legacyFinality), check: wantLocalDebit},
		{name: "non-streaming, pin off, header finality", respond: strippedNonStream, check: wantRefunded},
		{name: "streaming, pin on, declaration stripped", pin: true, stream: true, respond: strippedStream, check: wantHeld},
		{name: "streaming, pin on, no snapshot signed legacy headers", pin: true, stream: true, respond: signedLegacyStream, check: wantLocalDebit},
		{name: "streaming, pin off, no finality", stream: true, respond: strippedStream, check: wantLocalDebit},
	})
}

// Review R2 LOW 3: a real net/http round trip. The fake coordinator emits
// declared trailers through net/http's own trailer framing; the gateway
// reads them off the wire and settles from them.
func TestNonStreamingSignedTrailersOverRealWire(t *testing.T) {
	for _, tc := range []struct {
		name  string
		tuple func() http.Header
		pin   bool
		check func(t *testing.T, got gatewaySettlementState)
	}{
		{name: "signed refund", tuple: quarantinedFinality, check: wantRefunded},
		{name: "signed no-snapshot legacy under the pin", tuple: legacyFinality, pin: true, check: wantLocalDebit},
		{name: "record failed after delivery", tuple: recordFailedRefundFinality, pin: true, check: wantRefunded},
	} {
		t.Run(tc.name, func(t *testing.T) {
			coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				tuple := tc.tuple()
				w.Header().Set("Content-Type", "application/json")
				w.Header().Set(coordinatorInternalRequestIDHeader, testInternal)
				for name := range tuple {
					w.Header().Add("Trailer", name)
				}
				w.Header().Add("Trailer", settlementFinalityMACHeader)
				w.WriteHeader(http.StatusOK)
				_, _ = io.WriteString(w, trailerTestCompletion)
				for name, values := range tuple {
					w.Header()[name] = values
				}
				signFinality(testKey, r.Header.Get("X-MacProvider-Account"), r.Header.Get("X-Request-ID"), testInternal, w.Header())
			}))
			defer coordinator.Close()
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = coordinator.URL
				cfg.Coordinator.ServiceToken = testKey
				cfg.Coordinator.RequireSettlementTrailers = tc.pin
			}, WithHTTPClient(coordinator.Client()))
			accountID := "acct_wire_" + strings.ReplaceAll(tc.name, " ", "_")
			fullKey := createAccountAndKey(t, store, cfg, accountID)
			resp := postChat(t, h, fullKey, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)
			if resp.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
			}
			tc.check(t, gatewaySettlementSnapshot(t, dbPath, accountID))
		})
	}
}
