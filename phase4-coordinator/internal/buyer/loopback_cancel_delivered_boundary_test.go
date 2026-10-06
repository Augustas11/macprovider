package buyer_test

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// #1690 BUG-2: a buyer disconnects from a Trusted Pool loopback stream while
// the provider keeps streaming. The relay retires the request and sends the
// cancel_request before the buyer handler sees the disconnect, and the
// provider's later chunks are dropped. The cancel carries the delivered
// prefix; an honest provider signs exactly that prefix, and its buyer_cancel
// receipt verifies and settles pool_operator_attested usage.
func TestLoopbackPoolBuyerCancelBindsDeliveredBoundaryAndVerifies(t *testing.T) {
	const delivered = "Once upon a time"
	type cancelSeen struct {
		reason string
		bytes  *int64
	}
	cancels := make(chan cancelSeen, 4)
	buyerCtx, buyerGone := context.WithCancel(context.Background())
	defer buyerGone()
	fx := defaultExternalRuntimeFixture()
	fx.wsRelay = func(h *externalRuntimeHarness, ctx context.Context, requestID string, meta *providerws.SettlementReceiptMetadata) *providerws.RelayStream {
		chunks := make(chan providerws.InferenceResponseChunk)
		terminal := make(chan providerws.InferenceResponseEnd, 1)
		var relay *providerws.RelayStream
		relay = providerws.NewRelayStreamForTest(providerws.RelayStream{
			RequestID: requestID, Chunks: chunks, Done: make(chan providerws.InferenceResponseEnd), Errors: make(chan error, 1), CancelTerminal: terminal,
		}, func(reason string, deliveredOutputBytes *int64) {
			cancels <- cancelSeen{reason: reason, bytes: deliveredOutputBytes}
			if reason != "buyer_disconnected" || deliveredOutputBytes == nil {
				return
			}
			// The provider signs the prefix the cancel names, with the
			// completion tokens generated through it.
			content := delivered[:*deliveredOutputBytes]
			terminalTS := time.Now().UTC().UnixMilli()
			terminal <- providerws.InferenceResponseEnd{
				Type: "inference_response_end", RequestID: requestID, Status: "cancelled", ChunksSent: 3,
				Usage:                 json.RawMessage(`{"prompt_tokens":5,"completion_tokens":4,"total_tokens":9}`),
				TerminalStateTSUnixMS: terminalTS,
				Receipt:               buyerCancelReceipt(t, h.key, meta, content, 5, 4, terminalTS),
			}
		})
		send := func(seq int, data string) {
			select {
			case chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: seq, Data: data}:
			case <-ctx.Done():
			}
		}
		go func() {
			send(0, `data: {"choices":[{"delta":{"content":"`+delivered+`"}}]}`+"\n\n")
			// An empty delta: once the handler takes it, the prefix above
			// was written and recorded.
			send(1, `data: {"choices":[{"delta":{}}]}`+"\n\n")
			// The buyer's context ends; the relay's own cancel wins the race.
			relay.Cancel("buyer_disconnected")
			// A chunk the provider sent before it saw the cancel reaches the
			// buyer handler after the boundary was sent: it is past it.
			send(2, `data: {"choices":[{"delta":{"content":", there was a stream"}}]}`+"\n\n")
			buyerGone()
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

	first := <-cancels
	if first.reason != "buyer_disconnected" || first.bytes == nil || *first.bytes != int64(len(delivered)) {
		t.Fatalf("cancel=(%q, %v), want buyer_disconnected with delivered_output_bytes=%d", first.reason, first.bytes, len(delivered))
	}
	ev := queryBuyerCancelEvidence(t, h.dbPath)
	if ev.terminalState != billing.TerminalStateBuyerCancel || ev.deliveredBytes != int64(len(delivered)) {
		t.Fatalf("recorded (%s, %d bytes), want (buyer_cancel, %d bytes): the post-boundary chunk must not count", ev.terminalState, ev.deliveredBytes, len(delivered))
	}
	if ev.usageSource != billing.UsageSourcePoolOperatorAttested {
		t.Fatalf("usage_source=%q, want pool_operator_attested", ev.usageSource)
	}
	if ev.receiptResult != billing.SettlementReceiptResultValid || ev.settlementOutcome != billing.SettlementOutcomeVerified {
		t.Fatalf("verdict=(%s,%s), want valid verified", ev.receiptResult, ev.settlementOutcome)
	}
	if !ev.ledgerCompletion.Valid || ev.ledgerCompletion.Int64 != 4 || ev.ledgerQuarantined {
		t.Fatalf("ledger completion=%v quarantined=%v, want the receipt's 4 delivered-prefix tokens", ev.ledgerCompletion, ev.ledgerQuarantined)
	}
}
