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

// negotiatedTestRecorderMode is negotiatedTestRecorder whose attempt has a
// route snapshot in mode.
func negotiatedTestRecorderMode(mode string) *billingRecorder {
	rec := negotiatedTestRecorder()
	rec.hasSettlementAttemptN = true
	rec.settlementPolicyMode = mode
	return rec
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

// Review R3 MEDIUM-2: a failed post-delivery record in enforce mode sends a
// signed, closed refund tuple; in observe mode (and with no route snapshot)
// the signed legacy tuple, so the buyer is debited as the provider credit is
// payable. Nothing is sent before trailers are declared.
func TestSettlementRecordFailedFinalityFollowsRouteMode(t *testing.T) {
	rec := negotiatedTestRecorderMode(billing.RouteSnapshotModeEnforce)
	dst := http.Header{internalRequestIDHeader: {"internal-1"}}
	setSettlementRecordFailedFinality(dst, rec)
	if dst.Get(settlementOutcomeHeader) != "" || dst.Get(settlementModeHeader) != "" {
		t.Fatalf("tuple set before trailers were declared: %v", dst)
	}
	declareNonStreamingSettlementTrailers(dst, rec)
	setSettlementRecordFailedFinality(dst, rec)
	if dst.Get(settlementOutcomeHeader) != billing.SettlementOutcomeQuarantined || dst.Get(settlementReceiptResultHeader) != billing.SettlementReceiptResultInconclusive ||
		dst.Get(settlementReasonHeader) != settlementRecordFailedAfterDeliveryReason || dst.Get(settlementClosedHeader) != "true" ||
		dst.Get(settlementModeHeader) != billing.RouteSnapshotModeEnforce || dst.Get(settlementPolicyVersionHeader) != billing.RouteSnapshotPolicyVersion {
		t.Fatalf("enforce tuple=%v, want a closed enforce-mode quarantine", dst)
	}
	if got, want := dst.Get(settlementFinalityMACHeader), finalityMACOf(dst); got != want {
		t.Fatalf("refund MAC=%q, want %q", got, want)
	}
	for _, rec := range []*billingRecorder{negotiatedTestRecorderMode(billing.RouteSnapshotModeObserve), negotiatedTestRecorder()} {
		dst := http.Header{internalRequestIDHeader: {"internal-1"}}
		declareNonStreamingSettlementTrailers(dst, rec)
		setSettlementRecordFailedFinality(dst, rec)
		if dst.Get(settlementModeHeader) != settlementLegacyMode || dst.Get(settlementOutcomeHeader) != "" || dst.Get(settlementFinalityMACHeader) != finalityMACOf(dst) {
			t.Fatalf("observe/no-snapshot tuple=%v, want the signed legacy tuple", dst)
		}
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

// Review R2 MEDIUM 1 / R3 MEDIUM-2 (HTTP), over the wire: with no route
// snapshot the post-delivery record failure arrives as the signed legacy
// tuple (the enforce refund is covered by
// TestHTTPEnforceRecordFailureRefundsAndQuarantinesCredit).
func TestHTTPNegotiatedRecordFailureNoSnapshotSendsSignedLegacyOverWire(t *testing.T) {
	prev := settlementOutputWriteErrForTest
	settlementOutputWriteErrForTest = errors.New("settlement attempt output table missing")
	t.Cleanup(func() { settlementOutputWriteErrForTest = prev })
	resp := postNegotiatedOverWire(t, h4HTTPServer(t, h4HTTPCompletion))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d, want the delivered 200", resp.StatusCode)
	}
	if resp.Trailer.Get(settlementModeHeader) != settlementLegacyMode || resp.Trailer.Get(settlementOutcomeHeader) != "" {
		t.Fatalf("trailers=%v, want the signed legacy tuple", resp.Trailer)
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

// assertSignedLegacy checks a signed legacy tuple in the trailers: the
// observe/no-snapshot outcome of a post-delivery evidence failure.
func assertSignedLegacy(t *testing.T, resp *http.Response, requestID string) {
	t.Helper()
	tr := resp.Trailer
	if tr.Get(settlementModeHeader) != settlementLegacyMode || tr.Get(settlementOutcomeHeader) != "" {
		t.Fatalf("trailers=%v, want the signed legacy tuple", tr)
	}
	values := make([]string, 0, len(settlementOutcomeHeaderNames))
	for _, name := range settlementOutcomeHeaderNames {
		values = append(values, tr.Get(name))
	}
	if requestID == "" {
		t.Fatal("the MAC must be checked over a non-empty request id")
	}
	if want := settlementFinalityMAC(h4GatewayToken, "acct_h4", requestID, resp.Header.Get(internalRequestIDHeader), values); tr.Get(settlementFinalityMACHeader) != want {
		t.Fatalf("legacy MAC=%q, want %q", tr.Get(settlementFinalityMACHeader), want)
	}
}

// Codex R2 HIGH 2 / R3 MEDIUM-2 (HTTP, no route snapshot): the credit
// committed and its evidence write failed transiently. Without an enforce
// snapshot the credit stays payable, so the buyer gets the signed legacy
// tuple (#1675); the enforce refund is
// TestHTTPEnforceOutputMissingAfterCreditRefundsAndQuarantinesCredit.
func TestHTTPNegotiatedOutputMissingAfterCreditNoSnapshotSendsLegacyOverWire(t *testing.T) {
	forceTransientOutputLoss(t)
	resp := postNegotiatedOverWire(t, h4HTTPServer(t, h4HTTPCompletion))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d, want the delivered 200", resp.StatusCode)
	}
	assertSignedLegacy(t, resp, "req-wire")
}

// Codex R2 HIGH 2 / R3 MEDIUM-2 (WS non-streaming, no route snapshot):
// same outcome on the WS path.
func TestWSNegotiatedOutputMissingAfterCreditNoSnapshotSendsLegacy(t *testing.T) {
	forceTransientOutputLoss(t)
	reqLog, _ := h4OpenRequestLog(t)
	var observed *requestTerminal
	s := h4Server(t, reqLog, h4RelaySuccess(), &observed)
	rr := h4PostChatNegotiated(t, s, []byte(h4ChatBody))
	res := rr.Result()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status=%d, want the delivered 200", res.StatusCode)
	}
	assertSignedLegacy(t, res, h4RequestID)
}

// The handler-end finalizer: a negotiated non-streaming response with no
// tuple is refunded, never left to a 404 hold; a stream keeps its
// reconciler-resolvable hold unless its evidence was marked missing.
func TestFinalizeNegotiatedSettlementFinality(t *testing.T) {
	rec := negotiatedTestRecorderMode(billing.RouteSnapshotModeEnforce)
	dst := http.Header{internalRequestIDHeader: {"internal-1"}}
	declareNonStreamingSettlementTrailers(dst, rec)
	finalizeNegotiatedSettlementFinality(dst, rec)
	if dst.Get(settlementReasonHeader) != settlementFinalityUnsetReason || dst.Get(settlementClosedHeader) != "true" || dst.Get(settlementFinalityMACHeader) != finalityMACOf(dst) {
		t.Fatalf("enforce non-streaming unset tuple finalized to %v, want the signed refund", dst)
	}
	observe := negotiatedTestRecorderMode(billing.RouteSnapshotModeObserve)
	odst := http.Header{internalRequestIDHeader: {"internal-1"}}
	declareNonStreamingSettlementTrailers(odst, observe)
	finalizeNegotiatedSettlementFinality(odst, observe)
	if odst.Get(settlementModeHeader) != settlementLegacyMode || odst.Get(settlementFinalityMACHeader) != finalityMACOf(odst) {
		t.Fatalf("observe non-streaming unset tuple finalized to %v, want the signed legacy tuple", odst)
	}

	// A stream is finalized the same way: no negotiated stream ends with
	// declared-but-empty trailers the reconciler could never resolve.
	stream := negotiatedTestRecorderMode(billing.RouteSnapshotModeEnforce)
	stream.stream = true
	udst := http.Header{internalRequestIDHeader: {"internal-1"}}
	declareNonStreamingSettlementTrailers(udst, stream)
	finalizeNegotiatedSettlementFinality(udst, stream)
	if udst.Get(settlementReasonHeader) != settlementFinalityUnsetReason || udst.Get(settlementClosedHeader) != "true" || udst.Get(settlementFinalityMACHeader) != finalityMACOf(udst) {
		t.Fatalf("an enforce stream without a tuple finalized to %v, want the signed refund", udst)
	}
	sdst := http.Header{internalRequestIDHeader: {"internal-1"}}
	declareNonStreamingSettlementTrailers(sdst, stream)
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

// Codex ARCH MEDIUM (WS, no route snapshot): a negotiated WS non-streaming
// success whose attempt recorded no route snapshot takes the delivered-only
// order and ends with a signed legacy tuple in its trailers, never an
// unsigned or empty declaration the gateway would hold.
func TestWSNegotiatedNoSnapshotSendsSignedLegacyTrailers(t *testing.T) {
	reqLog, _ := h4OpenRequestLog(t)
	var observed *requestTerminal
	s := h4Server(t, reqLog, h4RelaySuccess(), &observed)
	rr := h4PostChatNegotiated(t, s, []byte(h4ChatBody))
	res := rr.Result()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status=%d body=%s", res.StatusCode, rr.Body.String())
	}
	if res.Header.Get(settlementModeHeader) != "" || res.Trailer.Get(settlementModeHeader) != settlementLegacyMode {
		t.Fatalf("header mode=%q trailer mode=%q, want the legacy tuple as a trailer only", res.Header.Get(settlementModeHeader), res.Trailer.Get(settlementModeHeader))
	}
	values := make([]string, 0, len(settlementOutcomeHeaderNames))
	for _, name := range settlementOutcomeHeaderNames {
		values = append(values, res.Trailer.Get(name))
	}
	if want := settlementFinalityMAC(h4GatewayToken, "acct_h4", h4RequestID, res.Header.Get(internalRequestIDHeader), values); res.Trailer.Get(settlementFinalityMACHeader) != want {
		t.Fatalf("legacy MAC=%q, want %q", res.Trailer.Get(settlementFinalityMACHeader), want)
	}
}

// failingFlushWriter accepts the body but fails its flush, like a buyer
// connection that went away under a buffered write.
type failingFlushWriter struct{ *httptest.ResponseRecorder }

func (failingFlushWriter) FlushError() error { return errors.New("buyer connection reset") }

// Review R3 LOW-2: the handler's writer wrappers pass a flush failure
// through, so writeDelivered does not report an undelivered body as
// delivered.
func TestWriterWrappersPropagateFlushError(t *testing.T) {
	inner := failingFlushWriter{httptest.NewRecorder()}
	rec := &billingRecorder{}
	for name, w := range map[string]http.ResponseWriter{
		"phaseTiming":     &phaseTimingResponseWriter{ResponseWriter: inner, state: newForwardState(time.Now())},
		"noPriorDispatch": &noPriorDispatchResponseWriter{ResponseWriter: inner, rec: rec},
		"both":            &noPriorDispatchResponseWriter{ResponseWriter: &phaseTimingResponseWriter{ResponseWriter: inner, state: newForwardState(time.Now())}, rec: rec},
	} {
		if writeDelivered(w, []byte("body")) {
			t.Fatalf("%s: a failed flush was reported delivered", name)
		}
	}
	if !writeDelivered(&phaseTimingResponseWriter{ResponseWriter: httptest.NewRecorder(), state: newForwardState(time.Now())}, []byte("body")) {
		t.Fatal("a healthy writer was reported undelivered")
	}
}

// Review R4 LOW-3: each dispatch forgets the previous attempt's credit, so
// an evidence failure on a later attempt that recorded no row of its own
// cannot quarantine an earlier attempt's credit.
func TestRouteSnapshotDispatchForgetsPreviousProviderAttempt(t *testing.T) {
	reqLog, _ := h4OpenRequestLog(t)
	var observed *requestTerminal
	s := h4Server(t, reqLog, h4RelaySuccess(), &observed)
	rec := &billingRecorder{server: s, hasLastProviderAttempt: true, lastProviderAttemptN: 0, lastProviderID: "p1"}
	_, _ = rec.recordRouteSnapshot([]byte(h4ChatBody), pool.Provider{ProviderID: "p2", AssignedID: "s2", ModelID: "model-a"})
	if rec.hasLastProviderAttempt {
		t.Fatal("a new dispatch kept the previous attempt's credit identity")
	}
}

// Review R4 open question: the finalizer never adds a tuple to a non-200.
// The gateway settles a non-200 from its headers; a request whose earlier
// attempt billed a 502 must not gain a refund trailer on its final 503.
func TestFinalizeSkipsNon200Responses(t *testing.T) {
	rec := negotiatedTestRecorderMode(billing.RouteSnapshotModeEnforce)
	rec.terminal = newRequestTerminal(nil, "req-1", "acct_1")
	rec.terminal.claimBuyer(http.StatusServiceUnavailable)
	dst := http.Header{internalRequestIDHeader: {"internal-1"}}
	declareNonStreamingSettlementTrailers(dst, rec)
	finalizeNegotiatedSettlementFinality(dst, rec)
	if dst.Get(settlementOutcomeHeader) != "" || dst.Get(settlementModeHeader) != "" {
		t.Fatalf("a 503 was finalized: %v", dst)
	}
	ok := negotiatedTestRecorderMode(billing.RouteSnapshotModeEnforce)
	ok.terminal = newRequestTerminal(nil, "req-1", "acct_1")
	ok.terminal.claimBuyer(http.StatusOK)
	odst := http.Header{internalRequestIDHeader: {"internal-1"}}
	declareNonStreamingSettlementTrailers(odst, ok)
	finalizeNegotiatedSettlementFinality(odst, ok)
	if odst.Get(settlementReasonHeader) != settlementFinalityUnsetReason {
		t.Fatalf("a 200 without a tuple finalized to %v, want the refund", odst)
	}
}
