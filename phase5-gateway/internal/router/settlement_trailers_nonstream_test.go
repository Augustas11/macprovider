package router

import (
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// settlementFinalityMACGolden is the coordinator's pinned vector
// (phase4-coordinator TestSettlementFinalityMACGoldenVector): both sides
// must compute the same MAC.
const settlementFinalityMACGolden = "6d50472d4203def3b4c03d6bc03732193faf42f871aa61ea1ce03c008b56da2d"

func TestSettlementFinalityMACMatchesCoordinatorGolden(t *testing.T) {
	got := settlementFinalityMAC("service-token", "acct_1", "req-1",
		[]string{"quarantined", "invalid", "signature_verify_failed", "true", "enforce", "1", ""})
	if got != settlementFinalityMACGolden {
		t.Fatalf("finality MAC=%s, want the coordinator golden %s", got, settlementFinalityMACGolden)
	}
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

func signFinality(key, account, requestID string, h http.Header) {
	h.Set(settlementFinalityMACHeader, settlementFinalityMAC(key, account, requestID, settlementFinalityMACValues(h)))
}

func declaredTrailerResponse(trailer http.Header) *http.Response {
	resp := &http.Response{Header: http.Header{"Content-Type": {"application/json"}}, Trailer: trailer}
	resp.Header.Add("Trailer", settlementOutcomeHeader+", "+settlementReceiptResultHeader+", "+settlementClosedHeader+", "+settlementModeHeader+", "+settlementPolicyVersionHeader)
	resp.Header.Add("Trailer", settlementFinalityMACHeader)
	return resp
}

// Review F1/F4: non-streaming trailer finality is authoritative only when it
// arrived with a valid MAC; missing values, a missing MAC or a tampered tuple
// hold, never fall back to a local debit.
func TestCoordinatorNonStreamingSettlementFinality(t *testing.T) {
	const key, account, reqID = "service-token", "acct_1", "req-1"

	// No declaration (an older coordinator, or no route snapshot): headers.
	if got := coordinatorNonStreamingSettlementFinality(&http.Response{Header: http.Header{}}, key, account, reqID, false); got.Action != settlementFinalityLegacy {
		t.Fatalf("no finality anywhere: %+v, want legacy", got)
	}
	if got := coordinatorNonStreamingSettlementFinality(&http.Response{Header: quarantinedFinality()}, key, account, reqID, false); got.Action != settlementFinalityRefund {
		t.Fatalf("header finality from an older coordinator: %+v, want refund", got)
	}

	// Declared and present with a valid MAC.
	signed := quarantinedFinality()
	signFinality(key, account, reqID, signed)
	if got := coordinatorNonStreamingSettlementFinality(declaredTrailerResponse(signed), key, account, reqID, false); got.Action != settlementFinalityRefund || got.Outcome != "quarantined" {
		t.Fatalf("signed trailer finality: %+v, want the quarantined refund", got)
	}

	hold := func(name string, resp *http.Response, key string) {
		t.Helper()
		got := coordinatorNonStreamingSettlementFinality(resp, key, account, reqID, false)
		if got.Action != settlementFinalityHold || got.Reason != missingSettlementFinalityTrailer {
			t.Fatalf("%s: %+v, want a missing_settlement_finality_trailer hold", name, got)
		}
	}
	hold("declared, values stripped", declaredTrailerResponse(http.Header{}), key)
	unsigned := quarantinedFinality()
	hold("missing MAC", declaredTrailerResponse(unsigned), key)
	tampered := quarantinedFinality()
	tampered.Set(settlementOutcomeHeader, "verified")
	tampered.Set(settlementReceiptResultHeader, "valid")
	signFinality(key, account, reqID, tampered)
	tampered.Set(settlementOutcomeHeader, "quarantined")
	tampered.Set(settlementReceiptResultHeader, "invalid")
	hold("tampered tuple", declaredTrailerResponse(tampered), key)
	otherRequest := quarantinedFinality()
	signFinality(key, account, "req-2", otherRequest)
	hold("tuple replayed from another request", declaredTrailerResponse(otherRequest), key)
	hold("no MAC key", declaredTrailerResponse(signed), "")
	// Header finality does not substitute for declared trailers.
	stripped := declaredTrailerResponse(http.Header{})
	for name, values := range quarantinedFinality() {
		stripped.Header[name] = values
	}
	hold("declared trailers stripped, header tuple injected", stripped, key)
}

// Integration through the chat path, both mixed pairings included.
func TestNonStreamingTrailerFinalityThroughChatPath(t *testing.T) {
	const serviceToken = "service-token"
	const completion = `{"id":"chatcmpl_1","object":"chat.completion","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`
	body := `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
	cases := []struct {
		name string
		// respond builds the coordinator's reply from the request it got.
		respond func(r *http.Request) *http.Response
		check   func(t *testing.T, got gatewaySettlementState)
	}{
		{
			name: "negotiated coordinator, signed quarantined trailers refund",
			respond: func(r *http.Request) *http.Response {
				trailer := quarantinedFinality()
				signFinality(serviceToken, r.Header.Get("X-MacProvider-Account"), r.Header.Get("X-Request-ID"), trailer)
				resp := declaredTrailerResponse(trailer)
				resp.StatusCode, resp.Body = http.StatusOK, io.NopCloser(strings.NewReader(completion))
				return resp
			},
			check: func(t *testing.T, got gatewaySettlementState) {
				if got.usageRows != 0 || got.refundedRows != 1 {
					t.Fatalf("snapshot=%+v, want a refund and no usage", got)
				}
			},
		},
		{
			name: "negotiated coordinator, trailers stripped hold",
			respond: func(r *http.Request) *http.Response {
				resp := declaredTrailerResponse(http.Header{})
				resp.StatusCode, resp.Body = http.StatusOK, io.NopCloser(strings.NewReader(completion))
				return resp
			},
			check: func(t *testing.T, got gatewaySettlementState) {
				if got.usageRows != 0 || got.settledRows != 0 || got.refundedRows != 0 || got.activeRows != 1 {
					t.Fatalf("snapshot=%+v, want a held reservation and no debit", got)
				}
			},
		},
		{
			name: "negotiated coordinator, unsigned quarantined trailers hold",
			respond: func(r *http.Request) *http.Response {
				resp := declaredTrailerResponse(quarantinedFinality())
				resp.StatusCode, resp.Body = http.StatusOK, io.NopCloser(strings.NewReader(completion))
				return resp
			},
			check: func(t *testing.T, got gatewaySettlementState) {
				if got.usageRows != 0 || got.refundedRows != 0 || got.activeRows != 1 {
					t.Fatalf("snapshot=%+v, want a hold, not a refund, for an unsigned tuple", got)
				}
			},
		},
		{
			name: "older coordinator, header finality still honored",
			respond: func(r *http.Request) *http.Response {
				h := quarantinedFinality()
				h.Set("Content-Type", "application/json")
				return responseWithBody(http.StatusOK, h, completion)
			},
			check: func(t *testing.T, got gatewaySettlementState) {
				if got.usageRows != 0 || got.refundedRows != 1 {
					t.Fatalf("snapshot=%+v, want the header quarantine refund", got)
				}
			},
		},
		{
			name: "older coordinator, no finality settles locally",
			respond: func(r *http.Request) *http.Response {
				return responseWithBody(http.StatusOK, http.Header{"Content-Type": {"application/json"}}, completion)
			},
			check: func(t *testing.T, got gatewaySettlementState) {
				if got.usageRows != 1 || got.settledRows != 1 {
					t.Fatalf("snapshot=%+v, want the legacy local debit", got)
				}
			},
		},
	}
	for i, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var advertised string
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				advertised = r.Header.Get(settlementTrailersCapabilityHeader)
				return tc.respond(r), nil
			})}
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
				cfg.Coordinator.ServiceToken = serviceToken
			}, WithHTTPClient(client))
			accountID := "acct_trailer_finality_" + string(rune('a'+i))
			fullKey := createAccountAndKey(t, store, cfg, accountID)
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

// The coordinator.require_settlement_trailers pin: a 200 whose settlement
// Trailer declaration was stripped holds instead of settling from headers or
// legacy mode, on the non-streaming and the streaming path alike.
func TestRequireSettlementTrailersPinFinality(t *testing.T) {
	const key, account, reqID = "service-token", "acct_1", "req-1"
	isMissingHold := func(got coordinatorSettlementFinality) bool {
		return got.Action == settlementFinalityHold && got.Reason == missingSettlementFinalityTrailer
	}
	stripped := &http.Response{Header: quarantinedFinality()}
	if got := coordinatorNonStreamingSettlementFinality(stripped, key, account, reqID, true); !isMissingHold(got) {
		t.Fatalf("pin on, declaration stripped, header tuple present: %+v, want a hold", got)
	}
	if got := coordinatorNonStreamingSettlementFinality(&http.Response{Header: http.Header{}}, key, account, reqID, true); !isMissingHold(got) {
		t.Fatalf("pin on, no finality at all: %+v, want a hold, not legacy", got)
	}
	signed := quarantinedFinality()
	signFinality(key, account, reqID, signed)
	if got := coordinatorNonStreamingSettlementFinality(declaredTrailerResponse(signed), key, account, reqID, true); got.Action != settlementFinalityRefund {
		t.Fatalf("pin on, signed trailers: %+v, want the refund", got)
	}
	if got := coordinatorNonStreamingSettlementFinality(stripped, key, account, reqID, false); got.Action != settlementFinalityRefund {
		t.Fatalf("pin off, header finality: %+v, want the header refund", got)
	}

	if got := coordinatorStreamingSettlementFinality(&http.Response{Header: quarantinedFinality()}, true); !isMissingHold(got) {
		t.Fatalf("streaming, pin on, no declaration: %+v, want a hold", got)
	}
	if got := coordinatorStreamingSettlementFinality(&http.Response{Header: http.Header{}}, true); !isMissingHold(got) {
		t.Fatalf("streaming, pin on, no finality: %+v, want a hold, not legacy", got)
	}
	if got := coordinatorStreamingSettlementFinality(&http.Response{Header: http.Header{}, Trailer: quarantinedFinality()}, true); got.Action != settlementFinalityRefund {
		t.Fatalf("streaming, pin on, trailer finality: %+v, want the refund", got)
	}
	if got := coordinatorStreamingSettlementFinality(&http.Response{Header: http.Header{}}, false); got.Action != settlementFinalityLegacy {
		t.Fatalf("streaming, pin off, no finality: %+v, want legacy", got)
	}
}

func TestRequireSettlementTrailersPinThroughChatPath(t *testing.T) {
	const serviceToken = "service-token"
	const completion = `{"id":"chatcmpl_1","object":"chat.completion","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`
	const sse = "data: {\"id\":\"c\",\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":4,\"total_tokens\":7},\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"
	strippedNonStream := func(r *http.Request) *http.Response {
		h := quarantinedFinality()
		h.Set("Content-Type", "application/json")
		return responseWithBody(http.StatusOK, h, completion)
	}
	signedNonStream := func(r *http.Request) *http.Response {
		trailer := quarantinedFinality()
		signFinality(serviceToken, r.Header.Get("X-MacProvider-Account"), r.Header.Get("X-Request-ID"), trailer)
		resp := declaredTrailerResponse(trailer)
		resp.StatusCode, resp.Body = http.StatusOK, io.NopCloser(strings.NewReader(completion))
		return resp
	}
	strippedStream := func(r *http.Request) *http.Response {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": {"text/event-stream; charset=utf-8"}}, sse)
	}
	held := func(t *testing.T, got gatewaySettlementState) {
		if got.usageRows != 0 || got.settledRows != 0 || got.refundedRows != 0 || got.activeRows != 1 {
			t.Fatalf("snapshot=%+v, want a held reservation", got)
		}
	}
	cases := []struct {
		name    string
		pin     bool
		stream  bool
		respond func(r *http.Request) *http.Response
		check   func(t *testing.T, got gatewaySettlementState)
	}{
		{name: "non-streaming, pin on, declaration stripped", pin: true, respond: strippedNonStream, check: held},
		{name: "non-streaming, pin on, signed trailers", pin: true, respond: signedNonStream, check: func(t *testing.T, got gatewaySettlementState) {
			if got.usageRows != 0 || got.refundedRows != 1 {
				t.Fatalf("snapshot=%+v, want the signed quarantine refund", got)
			}
		}},
		{name: "non-streaming, pin off, header finality", respond: strippedNonStream, check: func(t *testing.T, got gatewaySettlementState) {
			if got.usageRows != 0 || got.refundedRows != 1 {
				t.Fatalf("snapshot=%+v, want the header quarantine refund", got)
			}
		}},
		{name: "streaming, pin on, declaration stripped", pin: true, stream: true, respond: strippedStream, check: held},
		{name: "streaming, pin off, no finality", stream: true, respond: strippedStream, check: func(t *testing.T, got gatewaySettlementState) {
			if got.usageRows != 1 || got.settledRows != 1 {
				t.Fatalf("snapshot=%+v, want the legacy local debit", got)
			}
		}},
	}
	for i, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				return tc.respond(r), nil
			})}
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
				cfg.Coordinator.ServiceToken = serviceToken
				cfg.Coordinator.RequireSettlementTrailers = tc.pin
			}, WithHTTPClient(client))
			accountID := "acct_trailer_pin_" + string(rune('a'+i))
			fullKey := createAccountAndKey(t, store, cfg, accountID)
			body := `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
			if tc.stream {
				body = `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
			}
			resp := postChat(t, h, fullKey, body, nil)
			if resp.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
			}
			tc.check(t, gatewaySettlementSnapshot(t, dbPath, accountID))
		})
	}
}
