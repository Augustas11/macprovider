package buyer_test

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

type streamDeadlineRow struct {
	status              int
	errMsg              string
	errorCode           sql.NullString
	promptTokens        sql.NullInt64
	completionTokens    sql.NullInt64
	estimatedCompletion sql.NullInt64
	evidence            buyerCancelEvidence
}

// runGatewayCancelledStream streams a prefix, then cancels the buyer context
// the way the gateway does when its stream_ceiling fires, and returns the
// request_log row plus the settlement evidence.
func runGatewayCancelledStream(t *testing.T, deadline string) streamDeadlineRow {
	t.Helper()
	return runGatewayCancelledStreamTerminalAfter(t, deadline, 0)
}

// runGatewayCancelledStreamTerminalAfter delays the provider's cancel
// terminal, so the row is logged well after the cancel arrived.
func runGatewayCancelledStreamTerminalAfter(t *testing.T, deadline string, terminalDelay time.Duration) streamDeadlineRow {
	t.Helper()
	const delivered = "Hello, partial"
	h := newBuyerCancelHarness(t, "stream-deadline-label-catalog", func(h *buyerCancelHarness, ctx context.Context, requestID string, meta *providerws.SettlementReceiptMetadata) *providerws.RelayStream {
		chunks := make(chan providerws.InferenceResponseChunk)
		terminal := make(chan providerws.InferenceResponseEnd, 1)
		terminalTS := time.Now().UTC().UnixMilli()
		end := providerws.InferenceResponseEnd{
			Type:                  "inference_response_end",
			RequestID:             requestID,
			Status:                "cancelled",
			ChunksSent:            1,
			Usage:                 json.RawMessage(`{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8}`),
			TerminalStateTSUnixMS: terminalTS,
			Receipt:               buyerCancelReceipt(t, h.key, meta, delivered, 5, 3, terminalTS),
		}
		if terminalDelay == 0 {
			terminal <- end
		} else {
			time.AfterFunc(terminalDelay, func() { terminal <- end })
		}
		go func() {
			chunks <- providerws.InferenceResponseChunk{
				Type:      "inference_response_chunk",
				RequestID: requestID,
				Data:      `data: {"choices":[{"delta":{"content":"` + delivered + `"}}]}` + "\n\n",
			}
			time.Sleep(50 * time.Millisecond)
			h.cancel()
		}()
		return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: make(chan providerws.InferenceResponseEnd), Errors: make(chan error, 1), CancelTerminal: terminal}
	})
	body := []byte(`{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hi"}],"temperature":0.000001,"top_p":0.5,"presence_penalty":0,"frequency_penalty":0}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body)).WithContext(h.ctx)
	req.Header.Set("Authorization", "Bearer operator-key")
	req.Header.Set("X-MacProvider-Account", "acct_gateway")
	if deadline != "" {
		req.Header.Set("X-MacProvider-Internal-Stream-Deadline-Unix-Ms", deadline)
	}
	h.server.Handler().ServeHTTP(httptest.NewRecorder(), req)

	db, err := sql.Open("sqlite", h.dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	var row streamDeadlineRow
	if err := db.QueryRow(`SELECT status, COALESCE(error, ''), error_code, prompt_tokens, completion_tokens, estimated_completion_tokens FROM request_log`).
		Scan(&row.status, &row.errMsg, &row.errorCode, &row.promptTokens, &row.completionTokens, &row.estimatedCompletion); err != nil {
		t.Fatalf("query request_log: %v", err)
	}
	row.evidence = queryBuyerCancelEvidence(t, h.dbPath)
	return row
}

// A stream the gateway cut at its stream_ceiling reaches the coordinator as a
// buyer cancel. Its request_log row says request_timeout, and everything the
// money path reads (terminal state, usage source, tokens, ledger credit) is
// exactly the unlabelled buyer cancel's.
func TestGatewayStreamDeadlineLabelsRequestLogWithoutChangingSettlement(t *testing.T) {
	baseline := runGatewayCancelledStream(t, "")
	if baseline.errorCode.Valid && baseline.errorCode.String != "" {
		t.Fatalf("an ordinary buyer cancel got error_code=%q", baseline.errorCode.String)
	}
	past := strconv.FormatInt(time.Now().Add(-time.Second).UnixMilli(), 10)
	labelled := runGatewayCancelledStream(t, past)
	if labelled.errorCode.String != "request_timeout" {
		t.Fatalf("request_log error_code=%q want request_timeout", labelled.errorCode.String)
	}
	if labelled.status != baseline.status || labelled.errMsg != baseline.errMsg {
		t.Fatalf("status/error=(%d,%q) want the buyer-cancel row (%d,%q)", labelled.status, labelled.errMsg, baseline.status, baseline.errMsg)
	}
	if labelled.promptTokens != baseline.promptTokens || labelled.completionTokens != baseline.completionTokens ||
		labelled.estimatedCompletion != baseline.estimatedCompletion {
		t.Fatalf("tokens=(%v,%v,%v) want the unlabelled (%v,%v,%v)",
			labelled.promptTokens, labelled.completionTokens, labelled.estimatedCompletion,
			baseline.promptTokens, baseline.completionTokens, baseline.estimatedCompletion)
	}
	if labelled.evidence.terminalState != billing.TerminalStateBuyerCancel {
		t.Fatalf("terminal_state=%q want buyer_cancel", labelled.evidence.terminalState)
	}
	b, l := baseline.evidence, labelled.evidence
	if l.terminalState != b.terminalState || l.deliveredBytes != b.deliveredBytes || l.usageSource != b.usageSource ||
		l.usageJSON != b.usageJSON || l.settlementOutcome != b.settlementOutcome || l.receiptResult != b.receiptResult ||
		l.ledgerPrompt != b.ledgerPrompt || l.ledgerCompletion != b.ledgerCompletion || l.ledgerGross != b.ledgerGross ||
		l.ledgerQuarantined != b.ledgerQuarantined {
		t.Fatalf("settlement evidence changed by the label:\n labelled %+v\n baseline %+v", l, b)
	}
}

// A buyer that leaves before the gateway deadline is an ordinary cancel.
func TestGatewayStreamDeadlineInFutureDoesNotLabel(t *testing.T) {
	future := strconv.FormatInt(time.Now().Add(time.Hour).UnixMilli(), 10)
	row := runGatewayCancelledStream(t, future)
	if row.errorCode.Valid && row.errorCode.String != "" {
		t.Fatalf("a cancel before the gateway deadline got error_code=%q", row.errorCode.String)
	}
}

// The label follows when the cancel arrived, not when the row is logged: a
// buyer that left more than the skew before the deadline stays unlabelled
// even when the provider's cancel terminal arrives after the deadline.
func TestGatewayStreamDeadlineUsesCancelTimeNotLogTime(t *testing.T) {
	deadline := strconv.FormatInt(time.Now().Add(1500*time.Millisecond).UnixMilli(), 10)
	row := runGatewayCancelledStreamTerminalAfter(t, deadline, 1900*time.Millisecond)
	if row.errorCode.Valid && row.errorCode.String != "" {
		t.Fatalf("a cancel 1.4 s before the deadline got error_code=%q from its later log time", row.errorCode.String)
	}
}
