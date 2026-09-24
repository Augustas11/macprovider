package buyer_test

import (
	"bytes"
	"context"
	"database/sql"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
)

// A buyer who cancels a pool loopback stream received a prefix, but the
// runtime never reported usage and so no receipt can settle it. The attempt is
// byte_estimated and must carry no provider credit and no buyer debit at the
// source, not only a later quarantine (SPEC-047-R003(iv), SPEC-022-R012).
func TestLoopbackPoolStreamCancelledWithoutReceiptIsZeroBilled(t *testing.T) {
	chunkSent := make(chan struct{})
	fx := defaultExternalRuntimeFixture()
	fx.upstream = func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Once upon a time"}}]}` + "\n\n"))
		w.(http.Flusher).Flush()
		close(chunkSent)
		<-r.Context().Done()
	}
	h := newExternalRuntimeHarness(t, fx)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions",
		bytes.NewReader([]byte(`{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hi"}]}`))).WithContext(ctx)
	for k, values := range trustedPoolLayer2Headers(externalRuntimePoolAccount, h.poolID) {
		for _, v := range values {
			req.Header.Add(k, v)
		}
	}
	rec := httptest.NewRecorder()
	served := make(chan struct{})
	go func() {
		h.server.Handler().ServeHTTP(rec, req)
		close(served)
	}()
	select {
	case <-chunkSent:
	case <-time.After(5 * time.Second):
		t.Fatal("upstream never streamed")
	}
	time.Sleep(100 * time.Millisecond)
	cancel() // the buyer goes away mid-stream
	select {
	case <-served:
	case <-time.After(10 * time.Second):
		t.Fatal("handler did not return after the buyer cancelled")
	}

	db, err := sql.Open("sqlite", h.dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	var terminal, usageSource string
	var delivered int64
	if err := db.QueryRow(`SELECT terminal_state, output_prefix_end_byte - output_prefix_start_byte, usage_source FROM settlement_attempt_outputs`).
		Scan(&terminal, &delivered, &usageSource); err != nil {
		t.Fatalf("attempt output: %v", err)
	}
	if terminal != billing.TerminalStateBuyerCancel || delivered == 0 || usageSource != billing.UsageSourceByteEstimated {
		t.Fatalf("attempt output=(%s, %d bytes, %s), want a delivered buyer_cancel prefix recorded byte_estimated", terminal, delivered, usageSource)
	}
	var gross, provider, quarantined int64
	var reason sql.NullString
	if err := db.QueryRow(`SELECT gross_credits, provider_credits, quarantined, quarantine_reason FROM ledger_request_credits`).
		Scan(&gross, &provider, &quarantined, &reason); err != nil {
		t.Fatalf("ledger: %v", err)
	}
	if gross != 0 || provider != 0 || quarantined != 1 || reason.String != billing.LoopbackRuntimeNotSettlementEligible {
		t.Fatalf("ledger gross=%d provider=%d quarantined=%d reason=%q, want zero debit, zero credit, quarantined %s",
			gross, provider, quarantined, reason.String, billing.LoopbackRuntimeNotSettlementEligible)
	}
	var operatorRows, payable int64
	if err := db.QueryRow(`SELECT COUNT(*) FROM ledger_operator_credits`).Scan(&operatorRows); err != nil {
		t.Fatalf("operator credits: %v", err)
	}
	if err := db.QueryRow(`SELECT COUNT(*) FROM spec022_payable_request_credits`).Scan(&payable); err != nil {
		t.Fatalf("payable view: %v", err)
	}
	if operatorRows != 0 || payable != 0 {
		t.Fatalf("operator credit rows=%d payable rows=%d, want none", operatorRows, payable)
	}
	var outcome string
	if err := db.QueryRow(`SELECT settlement_outcome FROM settlement_receipt_verdicts`).Scan(&outcome); err != nil {
		t.Fatalf("verdict: %v", err)
	}
	if outcome == billing.SettlementOutcomeVerified || outcome == billing.SettlementOutcomeZeroSettled {
		t.Fatalf("a receipt-less cancel settled as %s", outcome)
	}
}
