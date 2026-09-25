package buyer

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// settlementFinalityMACGolden pins the finality MAC encoding. The gateway
// test TestSettlementFinalityMACMatchesCoordinatorGolden pins the same value,
// so the two independent implementations cannot drift apart.
const settlementFinalityMACGolden = "ae41121fb9352158dbbd4cfefd1095baae9f4ebbeda2b8942c010854275b9270"

var goldenFinalityValues = []string{"quarantined", "invalid", "signature_verify_failed", "true", "enforce", "1", ""}

func TestSettlementFinalityMACGoldenVector(t *testing.T) {
	got := settlementFinalityMAC("service-token", "acct_1", "req-1", "internal-1", goldenFinalityValues)
	if got != settlementFinalityMACGolden {
		t.Fatalf("finality MAC=%s, want %s", got, settlementFinalityMACGolden)
	}
	// The key is trimmed like the bearer the coordinator matches.
	if settlementFinalityMAC(" service-token\n", "acct_1", "req-1", "internal-1", goldenFinalityValues) != got {
		t.Fatal("the MAC key is not trimmed")
	}
	// Length prefixes keep field boundaries, and the internal request id is
	// bound.
	if settlementFinalityMAC("service-token", "acct_1r", "eq-1", "internal-1", goldenFinalityValues) == got {
		t.Fatal("field boundaries are not bound")
	}
	if settlementFinalityMAC("service-token", "acct_1", "req-1", "internal-2", goldenFinalityValues) == got {
		t.Fatal("the internal request id is not bound")
	}
}

// Only a caller holding the gateway service token negotiates trailers.
func TestGatewayNegotiatedSettlementTrailersNeedsServiceToken(t *testing.T) {
	s := &Server{gatewayServiceToken: "service-token"}
	h := http.Header{}
	h.Set(settlementTrailersCapabilityHeader, "1")
	if s.gatewayNegotiatedSettlementTrailers(h) {
		t.Fatal("capability without the service token negotiated trailers")
	}
	h.Set("Authorization", "Bearer wrong")
	if s.gatewayNegotiatedSettlementTrailers(h) {
		t.Fatal("capability with a wrong bearer negotiated trailers")
	}
	h.Set("Authorization", "Bearer service-token")
	if !s.gatewayNegotiatedSettlementTrailers(h) {
		t.Fatal("the gateway's advertised capability was not honored")
	}
	h.Set(settlementTrailersCapabilityHeader, "0")
	if s.gatewayNegotiatedSettlementTrailers(h) {
		t.Fatal("a capability other than 1 negotiated trailers")
	}
	if (&Server{}).gatewayNegotiatedSettlementTrailers(http.Header{"Authorization": {"Bearer "}, settlementTrailersCapabilityHeader: {"1"}}) {
		t.Fatal("an unset service token negotiated trailers")
	}
	// The capability header is gateway-owned: a buyer-port request that
	// carries it without the bearer is refused like every internal header.
	if !hasInternalRoutingHeader(http.Header{settlementTrailersCapabilityHeader: {"1"}}) {
		t.Fatal("the capability header is outside the internal-header guard")
	}
}

func negotiatedTestRecorder() *billingRecorder {
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	req.Header.Set("X-MacProvider-Account", "acct_1")
	req.Header.Set("X-Request-ID", "req-1")
	return &billingRecorder{
		server:                       &Server{gatewayServiceToken: "service-token", log: zerolog.Nop()},
		req:                          req,
		accountID:                    "acct_1",
		settlementTrailersNegotiated: true,
	}
}

func finalityMACOf(dst http.Header) string {
	values := make([]string, 0, len(settlementOutcomeHeaderNames))
	for _, name := range settlementOutcomeHeaderNames {
		values = append(values, dst.Get(name))
	}
	return settlementFinalityMAC("service-token", "acct_1", "req-1", dst.Get(internalRequestIDHeader), values)
}

// Review R2 MEDIUM 1: a failed post-delivery record sends a signed, closed
// refund tuple; nothing is sent before trailers are declared.
func TestSettlementRecordFailedRefundIsSignedClosed(t *testing.T) {
	rec := negotiatedTestRecorder()
	dst := http.Header{internalRequestIDHeader: {"internal-1"}}
	setSettlementRecordFailedRefund(dst, rec)
	if dst.Get(settlementOutcomeHeader) != "" {
		t.Fatalf("refund set before trailers were declared: %v", dst)
	}
	declareNonStreamingSettlementTrailers(dst, rec)
	setSettlementRecordFailedRefund(dst, rec)
	if dst.Get(settlementOutcomeHeader) != billing.SettlementOutcomeQuarantined || dst.Get(settlementReceiptResultHeader) != billing.SettlementReceiptResultInconclusive ||
		dst.Get(settlementReasonHeader) != settlementRecordFailedAfterDeliveryReason || dst.Get(settlementClosedHeader) != "true" ||
		dst.Get(settlementModeHeader) != billing.RouteSnapshotModeEnforce || dst.Get(settlementPolicyVersionHeader) != billing.RouteSnapshotPolicyVersion {
		t.Fatalf("refund tuple=%v, want a closed enforce-mode quarantine", dst)
	}
	if got, want := dst.Get(settlementFinalityMACHeader), finalityMACOf(dst); got != want {
		t.Fatalf("refund MAC=%q, want %q", got, want)
	}
}

// Review R2 HIGH: an attempt without receipt state gets a signed legacy
// tuple, as trailers (non-streaming) or headers (a stream with no route
// snapshot), so the gateway pin settles it instead of holding it.
func TestNegotiatedLegacyTuplesAreSigned(t *testing.T) {
	rec := negotiatedTestRecorder()
	dst := http.Header{internalRequestIDHeader: {"internal-1"}}
	declareNonStreamingSettlementTrailers(dst, rec)
	setNonStreamingSettlementFinality(dst, rec, billing.SettlementReceiptState{}, false)
	if dst.Get(settlementModeHeader) != settlementLegacyMode || dst.Get(settlementFinalityMACHeader) != finalityMACOf(dst) {
		t.Fatalf("non-streaming legacy tuple=%v", dst)
	}

	stream := http.Header{internalRequestIDHeader: {"internal-1"}}
	stream.Add("Trailer", "X-Other")
	declareNonStreamingSettlementTrailers(stream, rec)
	if !prepareStreamingSettlementFinality(stream, rec, false) {
		t.Fatal("a negotiating gateway's stream was not prepared")
	}
	if got := stream.Values("Trailer"); len(got) != 1 || got[0] != "X-Other" {
		t.Fatalf("a retry kept the previous attempt's declarations: %v", got)
	}
	if stream.Get(settlementModeHeader) != settlementLegacyMode || stream.Get(settlementFinalityMACHeader) != finalityMACOf(stream) {
		t.Fatalf("streaming legacy header tuple=%v", stream)
	}
	if prepareStreamingSettlementFinality(http.Header{}, &billingRecorder{accountID: "acct_1"}, false) {
		t.Fatal("a caller that did not negotiate was prepared")
	}
}

// h4RegisterHTTPProvider registers an HTTP-forwarding provider served by
// endpointURL.
func h4RegisterHTTPProvider(reg *pool.Registry, endpointURL string) {
	now := time.Now().UTC()
	reg.Register(&pool.Provider{
		ProviderID: "p1", AssignedID: "s1", Hostname: "p1.local", ModelID: "model-a",
		ModelParamsB: 7, RAMGB: 16, MaxContextTokens: 20000, MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1,
		ThroughputTPSEstimate: 30, EndpointURL: endpointURL, Tier: pool.TierPinned,
		InferencePath: pool.InferencePathHTTPForwarding, State: pool.StateReady,
		LastHeartbeatAt: now, ConnectedAt: now, BinaryVersion: "0.1.0",
	}, nil)
	slotsFree := 1
	reg.ApplyStateUpdate("p1", "s1", pool.StateUpdate{State: pool.StateReady, SlotsFree: &slotsFree, At: now})
}

// postNegotiatedOverWire sends a negotiated chat request to a real
// httptest.Server, so trailers cross real net/http framing.
func postNegotiatedOverWire(t *testing.T, s *Server) *http.Response {
	t.Helper()
	srv := httptest.NewServer(s.Handler())
	t.Cleanup(srv.Close)
	req, err := http.NewRequest(http.MethodPost, srv.URL+"/v1/chat/completions", bytes.NewReader([]byte(h4ChatBody)))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+h4GatewayToken)
	req.Header.Set("X-MacProvider-Account", "acct_h4")
	req.Header.Set("X-Request-ID", "req-wire")
	req.Header.Set(settlementTrailersCapabilityHeader, "1")
	resp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.ReadAll(resp.Body); err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	return resp
}

func assertWireFinalityMAC(t *testing.T, resp *http.Response) {
	t.Helper()
	values := make([]string, 0, len(settlementOutcomeHeaderNames))
	for _, name := range settlementOutcomeHeaderNames {
		values = append(values, resp.Trailer.Get(name))
	}
	want := settlementFinalityMAC(h4GatewayToken, "acct_h4", "req-wire", resp.Header.Get(internalRequestIDHeader), values)
	if resp.Header.Get(internalRequestIDHeader) == "" || resp.Trailer.Get(settlementFinalityMACHeader) != want {
		t.Fatalf("wire MAC=%q internal=%q, want %q", resp.Trailer.Get(settlementFinalityMACHeader), resp.Header.Get(internalRequestIDHeader), want)
	}
}

func h4HTTPServer(t *testing.T, upstreamBody string) *Server {
	t.Helper()
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, upstreamBody)
	}))
	t.Cleanup(upstream.Close)
	reqLog, _ := h4OpenRequestLog(t)
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	registry := pool.NewRegistry(nil)
	h4RegisterHTTPProvider(registry, upstream.URL)
	return NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		WithRequestLog(reqLog),
		WithBilling(billingStore, h4Rewards()),
		WithRoutingConfig(config.RoutingConfig{MaxRetries: 0, StickyTTLS: 1800, StickyMaxEntries: 10000}),
		WithGatewayServiceToken(h4GatewayToken),
	)
}

const h4HTTPCompletion = `{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}`

// Review R2 HIGH + LOW 3, over the wire: a negotiated non-streaming 200
// with no route snapshot (the default observe setup) carries a signed legacy
// tuple as real trailers.
func TestHTTPNegotiatedNoSnapshotSendsSignedLegacyTrailersOverWire(t *testing.T) {
	resp := postNegotiatedOverWire(t, h4HTTPServer(t, h4HTTPCompletion))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d", resp.StatusCode)
	}
	if resp.Header.Get(settlementModeHeader) != "" || resp.Trailer.Get(settlementModeHeader) != settlementLegacyMode {
		t.Fatalf("header mode=%q trailer mode=%q, want the legacy tuple as a trailer only", resp.Header.Get(settlementModeHeader), resp.Trailer.Get(settlementModeHeader))
	}
	assertWireFinalityMAC(t, resp)
}

// Review R2 MEDIUM 1 (HTTP), over the wire: the post-delivery record
// failure arrives as a signed closed refund tuple.
func TestHTTPNegotiatedRecordFailureSendsSignedRefundOverWire(t *testing.T) {
	prev := settlementOutputWriteErrForTest
	settlementOutputWriteErrForTest = errors.New("settlement attempt output table missing")
	t.Cleanup(func() { settlementOutputWriteErrForTest = prev })
	resp := postNegotiatedOverWire(t, h4HTTPServer(t, h4HTTPCompletion))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d, want the delivered 200", resp.StatusCode)
	}
	if resp.Trailer.Get(settlementOutcomeHeader) != billing.SettlementOutcomeQuarantined || resp.Trailer.Get(settlementClosedHeader) != "true" ||
		resp.Trailer.Get(settlementReasonHeader) != settlementRecordFailedAfterDeliveryReason || resp.Trailer.Get(settlementModeHeader) != billing.RouteSnapshotModeEnforce {
		t.Fatalf("trailers=%v, want the signed closed refund tuple", resp.Trailer)
	}
	assertWireFinalityMAC(t, resp)
}

// Review R2 HIGH (streaming): a negotiated stream with no route snapshot
// carries a signed legacy tuple in its headers, decided before the first
// byte, and declares no settlement trailers.
func TestStreamingNegotiatedNoSnapshotSignsLegacyHeaders(t *testing.T) {
	relay := func(_ context.Context, _ pool.Provider, reqID string, _ []byte, _ bool) (*providerws.RelayStream, error) {
		chunks := make(chan providerws.InferenceResponseChunk, 2)
		done := make(chan providerws.InferenceResponseEnd, 1)
		go func() {
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: reqID, Seq: 0, Data: "data: {\"id\":\"ok\",\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n"}
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: reqID, Seq: 1, Data: "data: [DONE]\n\n"}
			close(chunks)
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: reqID, Status: "complete", ChunksSent: 2}
		}()
		return &providerws.RelayStream{RequestID: reqID, Chunks: chunks, Done: done, Errors: make(chan error, 1)}, nil
	}
	reqLog, _ := h4OpenRequestLog(t)
	var observed *requestTerminal
	s := h4Server(t, reqLog, relay, &observed)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader([]byte(`{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hi"}]}`)))
	req.Header.Set("Authorization", "Bearer "+h4GatewayToken)
	req.Header.Set("X-MacProvider-Account", "acct_h4")
	req.Header.Set("X-Request-ID", "req-stream")
	req.Header.Set(settlementTrailersCapabilityHeader, "1")
	rr := httptest.NewRecorder()
	s.Handler().ServeHTTP(rr, req)
	res := rr.Result()
	_, _ = io.ReadAll(res.Body)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status=%d body=%s", res.StatusCode, rr.Body.String())
	}
	if res.Header.Get(settlementModeHeader) != settlementLegacyMode {
		t.Fatalf("stream headers=%v, want the signed legacy tuple", res.Header)
	}
	for _, name := range res.Header.Values("Trailer") {
		if isFinality := name == settlementFinalityMACHeader; isFinality {
			t.Fatalf("a no-snapshot stream declared finality trailers: %v", res.Header.Values("Trailer"))
		}
	}
	values := make([]string, 0, len(settlementOutcomeHeaderNames))
	for _, name := range settlementOutcomeHeaderNames {
		values = append(values, res.Header.Get(name))
	}
	if want := settlementFinalityMAC(h4GatewayToken, "acct_h4", "req-stream", res.Header.Get(internalRequestIDHeader), values); res.Header.Get(settlementFinalityMACHeader) != want {
		t.Fatalf("stream header MAC=%q, want %q", res.Header.Get(settlementFinalityMACHeader), want)
	}
}

// forceTransientOutputLoss makes the settlement-output write fail
// transiently on both tries after the credit committed, so the recorder
// marks the evidence missing and returns nil (billing_recorder.go
// persistSettlementAttemptOutput).
func forceTransientOutputLoss(t *testing.T) {
	t.Helper()
	prevErr, prevCtx := settlementOutputWriteErrForTest, settlementOutputWriteContextForTest
	settlementOutputWriteErrForTest = errors.New("database is locked")
	settlementOutputWriteContextForTest = func(attempt int, ctx context.Context) context.Context {
		if attempt == 2 {
			dead, cancel := context.WithCancel(ctx)
			cancel()
			return dead
		}
		return ctx
	}
	t.Cleanup(func() { settlementOutputWriteErrForTest, settlementOutputWriteContextForTest = prevErr, prevCtx })
}

func assertSignedRefund(t *testing.T, resp *http.Response, requestID, reason string) {
	t.Helper()
	tr := resp.Trailer
	if tr.Get(settlementOutcomeHeader) != billing.SettlementOutcomeQuarantined || tr.Get(settlementReceiptResultHeader) != billing.SettlementReceiptResultInconclusive ||
		tr.Get(settlementClosedHeader) != "true" || tr.Get(settlementReasonHeader) != reason || tr.Get(settlementModeHeader) != billing.RouteSnapshotModeEnforce {
		t.Fatalf("trailers=%v, want the signed closed refund with reason %s", tr, reason)
	}
	values := make([]string, 0, len(settlementOutcomeHeaderNames))
	for _, name := range settlementOutcomeHeaderNames {
		values = append(values, tr.Get(name))
	}
	if want := settlementFinalityMAC(h4GatewayToken, "acct_h4", requestID, resp.Header.Get(internalRequestIDHeader), values); tr.Get(settlementFinalityMACHeader) != want {
		t.Fatalf("refund MAC=%q, want %q", tr.Get(settlementFinalityMACHeader), want)
	}
}

// Codex R2 HIGH 2 (HTTP): the credit committed, the evidence write failed
// transiently and was marked missing. The negotiated 200 must not carry a
// legacy tuple (a local buyer debit with unverifiable provider evidence):
// it carries the signed closed refund.
func TestHTTPNegotiatedOutputMissingAfterCreditRefundsOverWire(t *testing.T) {
	forceTransientOutputLoss(t)
	resp := postNegotiatedOverWire(t, h4HTTPServer(t, h4HTTPCompletion))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d, want the delivered 200", resp.StatusCode)
	}
	assertSignedRefund(t, resp, "req-wire", settlementOutputMissingAfterCreditReason)
}

// Codex R2 HIGH 2 (WS non-streaming): same outcome on the WS path.
func TestWSNegotiatedOutputMissingAfterCreditRefunds(t *testing.T) {
	forceTransientOutputLoss(t)
	reqLog, _ := h4OpenRequestLog(t)
	var observed *requestTerminal
	s := h4Server(t, reqLog, h4RelaySuccess(), &observed)
	rr := h4PostChatNegotiated(t, s, []byte(h4ChatBody))
	res := rr.Result()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status=%d, want the delivered 200", res.StatusCode)
	}
	assertSignedRefund(t, res, "", settlementOutputMissingAfterCreditReason)
}

// The handler-end finalizer: a negotiated non-streaming response with no
// tuple is refunded, never left to a 404 hold; a stream keeps its
// reconciler-resolvable hold unless its evidence was marked missing.
func TestFinalizeNegotiatedSettlementFinality(t *testing.T) {
	rec := negotiatedTestRecorder()
	dst := http.Header{internalRequestIDHeader: {"internal-1"}}
	declareNonStreamingSettlementTrailers(dst, rec)
	finalizeNegotiatedSettlementFinality(dst, rec)
	if dst.Get(settlementReasonHeader) != settlementFinalityUnsetReason || dst.Get(settlementClosedHeader) != "true" || dst.Get(settlementFinalityMACHeader) != finalityMACOf(dst) {
		t.Fatalf("non-streaming unset tuple finalized to %v, want the signed refund", dst)
	}

	stream := negotiatedTestRecorder()
	stream.stream = true
	sdst := http.Header{internalRequestIDHeader: {"internal-1"}}
	declareNonStreamingSettlementTrailers(sdst, stream)
	finalizeNegotiatedSettlementFinality(sdst, stream)
	if sdst.Get(settlementOutcomeHeader) != "" || sdst.Get(settlementModeHeader) != "" {
		t.Fatalf("a stream without a tuple was finalized: %v", sdst)
	}
	stream.settlementOutputMissingAfterCredit = true
	finalizeNegotiatedSettlementFinality(sdst, stream)
	if sdst.Get(settlementReasonHeader) != settlementOutputMissingAfterCreditReason || sdst.Get(settlementFinalityMACHeader) != finalityMACOf(sdst) {
		t.Fatalf("a stream whose evidence is missing finalized to %v, want the signed refund", sdst)
	}

	// A tuple already set is left alone; a caller that did not negotiate is
	// untouched.
	kept := http.Header{internalRequestIDHeader: {"internal-1"}}
	krec := negotiatedTestRecorder()
	declareNonStreamingSettlementTrailers(kept, krec)
	setNonStreamingSettlementFinality(kept, krec, billing.SettlementReceiptState{}, false)
	finalizeNegotiatedSettlementFinality(kept, krec)
	if kept.Get(settlementModeHeader) != settlementLegacyMode {
		t.Fatalf("finalizer overwrote a set tuple: %v", kept)
	}
	plain := http.Header{}
	finalizeNegotiatedSettlementFinality(plain, &billingRecorder{accountID: "acct_1"})
	if len(plain) != 0 {
		t.Fatalf("finalizer touched a non-negotiated response: %v", plain)
	}
}
