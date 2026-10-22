package buyer_test

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// #2084 VM acceptance V-3: a buyer reads a WS-tunnelled stream to its final
// "data: [DONE]" and closes before the provider's terminal frame arrives. The
// whole response reached the buyer, so the attempt is not cancelled: the
// coordinator waits for the terminal frame and settles its normal_done receipt
// like any completed stream. Before the fix the disconnect cancelled the
// attempt, the late "complete" terminal was dropped, and the stream was
// refunded as a missing receipt.
func TestWSStreamBuyerClosedAfterDoneStillSettlesTheTerminalReceipt(t *testing.T) {
	const content = "Once upon a time"
	cancels := make(chan string, 4)
	buyerCtx, buyerGone := context.WithCancel(context.Background())
	defer buyerGone()
	fx := defaultExternalRuntimeFixture()
	fx.wsRelay = func(h *externalRuntimeHarness, ctx context.Context, requestID string, meta *providerws.SettlementReceiptMetadata) *providerws.RelayStream {
		chunks := make(chan providerws.InferenceResponseChunk)
		done := make(chan providerws.InferenceResponseEnd, 1)
		relay := providerws.NewRelayStreamForTest(providerws.RelayStream{
			RequestID: requestID, Chunks: chunks, Done: done, Errors: make(chan error, 1), CancelTerminal: make(chan providerws.InferenceResponseEnd, 1),
		}, func(reason string, _ *int64) { cancels <- reason })
		send := func(seq int, data string) {
			select {
			case chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: seq, Data: data}:
			case <-ctx.Done():
			}
		}
		go func() {
			send(0, `data: {"choices":[{"delta":{"content":"`+content+`"}}]}`+"\n\n")
			send(1, `data: {"choices":[{"delta":{}}]}`+"\n\n"+
				`data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":4,"total_tokens":9}}`+"\n\n"+"data: [DONE]\n\n")
			// An empty delta after [DONE] was taken: the [DONE] block was written.
			send(2, "")
			// The buyer read [DONE] and went away; the terminal frame follows.
			buyerGone()
			time.Sleep(150 * time.Millisecond)
			terminalTS := time.Now().UTC().UnixMilli()
			done <- providerws.InferenceResponseEnd{
				Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 3,
				Usage:                 json.RawMessage(`{"prompt_tokens":5,"completion_tokens":4,"total_tokens":9}`),
				TerminalStateTSUnixMS: terminalTS,
				Receipt:               signedNormalDoneReceipt(t, h.key, meta, content, 5, 4, terminalTS),
			}
			close(chunks)
		}()
		return relay
	}
	h := newExternalRuntimeHarness(t, fx)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions",
		bytes.NewReader([]byte(`{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hi"}]}`))).WithContext(buyerCtx)
	for k, values := range externalRuntimePoolHeaders(h.poolID) {
		for _, v := range values {
			req.Header.Add(k, v)
		}
	}
	rec := httptest.NewRecorder()
	h.server.Handler().ServeHTTP(rec, req)
	select {
	case reason := <-cancels:
		t.Fatalf("the provider was sent a %q cancel for a stream the buyer received to [DONE]", reason)
	default:
	}
	ev := queryBuyerCancelEvidence(t, h.dbPath)
	if ev.terminalState != billing.TerminalStateNormalDone || ev.deliveredBytes != int64(len(content)) {
		t.Fatalf("recorded (%s, %d bytes), want (normal_done, %d bytes)", ev.terminalState, ev.deliveredBytes, len(content))
	}
	if ev.receiptResult != billing.SettlementReceiptResultValid || ev.settlementOutcome != billing.SettlementOutcomeVerified {
		db, _ := sql.Open("sqlite", h.dbPath)
		var reason string
		_ = db.QueryRow(`SELECT reason FROM settlement_receipt_verdicts`).Scan(&reason)
		db.Close()
		t.Fatalf("verdict=(%s,%s) reason=%s, want valid verified", ev.receiptResult, ev.settlementOutcome, reason)
	}
}

// V-3, the relay half: the buyer's disconnect retires the request at the relay
// (cancel_request sent) before the provider's "complete" terminal arrives; the
// terminal then comes on CancelTerminal. A buyer that had received [DONE] is
// settled from it as a completed stream.
func TestWSStreamRetiredOnDisconnectAfterDoneSettlesTheCompleteTerminal(t *testing.T) {
	const content = "Once upon a time"
	cancels := make(chan string, 4)
	buyerCtx, buyerGone := context.WithCancel(context.Background())
	defer buyerGone()
	fx := defaultExternalRuntimeFixture()
	fx.wsRelay = func(h *externalRuntimeHarness, ctx context.Context, requestID string, meta *providerws.SettlementReceiptMetadata) *providerws.RelayStream {
		chunks := make(chan providerws.InferenceResponseChunk)
		terminal := make(chan providerws.InferenceResponseEnd, 1)
		errs := make(chan error, 1)
		var relay *providerws.RelayStream
		relay = providerws.NewRelayStreamForTest(providerws.RelayStream{
			RequestID: requestID, Chunks: chunks, Done: make(chan providerws.InferenceResponseEnd), Errors: errs, CancelTerminal: terminal,
		}, func(reason string, _ *int64) {
			cancels <- reason
			// The provider had already finished: its terminal is "complete".
			terminalTS := time.Now().UTC().UnixMilli()
			terminal <- providerws.InferenceResponseEnd{
				Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 2,
				Usage:                 json.RawMessage(`{"prompt_tokens":5,"completion_tokens":4,"total_tokens":9}`),
				TerminalStateTSUnixMS: terminalTS,
				Receipt:               signedNormalDoneReceipt(t, h.key, meta, content, 5, 4, terminalTS),
			}
		})
		send := func(seq int, data string) {
			select {
			case chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: seq, Data: data}:
			case <-ctx.Done():
			}
		}
		go func() {
			send(0, `data: {"choices":[{"delta":{"content":"`+content+`"}}]}`+"\n\n")
			send(1, `data: {"choices":[{"delta":{}}]}`+"\n\n"+
				`data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":4,"total_tokens":9}}`+"\n\n"+"data: [DONE]\n\n")
			send(2, "")
			// The relay's own context watcher retires the request.
			relay.Cancel("buyer_disconnected")
			buyerGone()
			errs <- providerws.ErrRelayClosed
		}()
		return relay
	}
	h := newExternalRuntimeHarness(t, fx)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions",
		bytes.NewReader([]byte(`{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hi"}]}`))).WithContext(buyerCtx)
	for k, values := range externalRuntimePoolHeaders(h.poolID) {
		for _, v := range values {
			req.Header.Add(k, v)
		}
	}
	h.server.Handler().ServeHTTP(httptest.NewRecorder(), req)
	if reason := <-cancels; reason != "buyer_disconnected" {
		t.Fatalf("cancel reason %q", reason)
	}
	ev := queryBuyerCancelEvidence(t, h.dbPath)
	if ev.terminalState != billing.TerminalStateNormalDone || ev.deliveredBytes != int64(len(content)) {
		t.Fatalf("recorded (%s, %d bytes), want (normal_done, %d bytes)", ev.terminalState, ev.deliveredBytes, len(content))
	}
	if ev.receiptResult != billing.SettlementReceiptResultValid || ev.settlementOutcome != billing.SettlementOutcomeVerified {
		t.Fatalf("verdict=(%s,%s), want valid verified", ev.receiptResult, ev.settlementOutcome)
	}
}
