package buyer_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// Unified-billing audit (#1690): a buyer is billed, and a provider credited,
// only for output confirmed delivered to the buyer (SPEC-015 §N.7, SPEC-022
// R-5.6, AC-022-54/63).

// resetBuyerWriter is a buyer connection that is gone by the time the body
// is written.
type resetBuyerWriter struct{ *httptest.ResponseRecorder }

func (resetBuyerWriter) Write([]byte) (int, error) {
	return 0, errors.New("buyer connection reset")
}

const deliveredOnlyChatBody = `{"model":"model-a","messages":[{"role":"user","content":"hi"}],"temperature":0.000001,"top_p":0.5,"presence_penalty":-0.25,"frequency_penalty":0.125}`

const deliveredOnlyCompletion = `{"id":"c","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"Hello world"},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":4,"total_tokens":9}}`

// settlementTrailersCapabilityHeader is the request header a gateway sends
// to negotiate non-streaming settlement trailers (settlement_trailers.go).
const settlementTrailersCapabilityHeader = "X-MacProvider-Internal-Settlement-Trailers"

// postDeliveredOnly posts as a gateway that negotiated settlement trailers.
func postDeliveredOnly(server *buyer.Server, ctx context.Context, body string, w http.ResponseWriter) {
	postNonStreaming(server, ctx, body, w, true)
}

func postNonStreaming(server *buyer.Server, ctx context.Context, body string, w http.ResponseWriter, negotiated bool) {
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader([]byte(body))).WithContext(ctx)
	req.Header.Set("Authorization", "Bearer operator-key")
	req.Header.Set("X-MacProvider-Account", "acct_gateway")
	req.Header.Set("X-Request-ID", "ext-req-1")
	if negotiated {
		req.Header.Set(settlementTrailersCapabilityHeader, "1")
	}
	server.Handler().ServeHTTP(w, req)
}

// assertNothingDeliveredBilled checks the attempt was recorded as a buyer
// cancel over an empty prefix and the ledger billed none of the provider's
// 5/4 usage.
func assertNothingDeliveredBilled(t *testing.T, dbPath string) {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	var terminalState string
	var delivered int64
	if err := db.QueryRow(`SELECT terminal_state, output_prefix_end_byte - output_prefix_start_byte FROM settlement_attempt_outputs`).Scan(&terminalState, &delivered); err != nil {
		t.Fatalf("query attempt output: %v", err)
	}
	if terminalState != billing.TerminalStateBuyerCancel || delivered != 0 {
		t.Fatalf("recorded (%s, %d bytes), want (buyer_cancel, 0 bytes): no full success for an undelivered body", terminalState, delivered)
	}
	rows, err := db.Query(`SELECT prompt_tokens, completion_tokens FROM ledger_request_credits`)
	if err != nil {
		t.Fatalf("query ledger: %v", err)
	}
	defer rows.Close()
	for rows.Next() {
		var prompt, completion sql.NullInt64
		if err := rows.Scan(&prompt, &completion); err != nil {
			t.Fatalf("scan ledger: %v", err)
		}
		if (prompt.Valid && prompt.Int64 == 5) || (completion.Valid && completion.Int64 == 4) {
			t.Fatalf("ledger billed the undelivered usage: prompt=%v completion=%v", prompt, completion)
		}
	}
}

func TestWSNonStreamingBuyerWriteFailureRecordsNoSuccess(t *testing.T) {
	h := newBuyerCancelHarness(t, "delivered-only-ws-catalog", func(h *buyerCancelHarness, ctx context.Context, requestID string, meta *providerws.SettlementReceiptMetadata) *providerws.RelayStream {
		chunks := make(chan providerws.InferenceResponseChunk, 1)
		done := make(chan providerws.InferenceResponseEnd, 1)
		chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Data: deliveredOnlyCompletion}
		close(chunks)
		go func() {
			time.Sleep(50 * time.Millisecond)
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1, Usage: json.RawMessage(`{"prompt_tokens":5,"completion_tokens":4,"total_tokens":9}`)}
		}()
		return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: make(chan error, 1)}
	})
	postDeliveredOnly(h.server, h.ctx, deliveredOnlyChatBody, resetBuyerWriter{httptest.NewRecorder()})
	assertNothingDeliveredBilled(t, h.dbPath)
}

func TestHTTPNonStreamingBuyerWriteFailureRecordsNoSuccess(t *testing.T) {
	server, dbPath := newDeliveredOnlyHTTPServer(t)
	postDeliveredOnly(server, context.Background(), deliveredOnlyChatBody, resetBuyerWriter{httptest.NewRecorder()})
	assertNothingDeliveredBilled(t, dbPath)
}

// newDeliveredOnlyHTTPServer is an enforce-mode coordinator with one HTTP
// provider that answers deliveredOnlyCompletion without a receipt.
func newDeliveredOnlyHTTPServer(t *testing.T) (*buyer.Server, string) {
	t.Helper()
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	raw, pubkey := routeSnapshotCatalogFixture(t, "delivered-only-http-catalog", time.Now().UTC().Add(time.Hour))
	if err := tier2.Configure(config.Tier2Config{
		ObserveEnabled:      true,
		CatalogPath:         writeRouteSnapshotCatalog(t, raw),
		CatalogPublicKey:    pubkey,
		RequireHashVerified: true,
	}, zerolog.Nop()); err != nil {
		t.Fatalf("tier2.Configure: %v", err)
	}
	reqLog, dbPath := openBuyerRequestLog(t)
	t.Cleanup(func() { _ = reqLog.Close() })
	store, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	setSettlementModeForTest(store, billing.RouteSnapshotModeEnforce)
	cfg := config.Default().Rewards
	snapshotID, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Unix(1716768000, 0).UTC())
	if err != nil {
		t.Fatalf("InsertConfigSnapshot: %v", err)
	}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(deliveredOnlyCompletion))
	}))
	registry := pool.NewRegistry(nil)
	registerSettlementProvider(registry, "p1", "session-1", upstream.URL, 20, bytes.Repeat([]byte{0x71}, 32))
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithGatewayServiceToken("operator-key"),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(store, cfg),
		buyer.WithBillingSnapshotID(snapshotID),
	)
	t.Cleanup(upstream.Close)
	return server, dbPath
}

// settlementOutcomeNames are the finality tuple names in MAC order.
var settlementOutcomeNames = []string{
	"X-MacProvider-Settlement-Outcome",
	"X-MacProvider-Settlement-Receipt-Result",
	"X-MacProvider-Settlement-Reason",
	"X-MacProvider-Settlement-Closed",
	"X-MacProvider-Settlement-Mode",
	"X-MacProvider-Settlement-Policy-Version",
	"X-MacProvider-Settlement-Pending-Deadline-Unix-Ms",
}

// independentFinalityMAC re-derives the finality MAC outside the package.
func independentFinalityMAC(key, account, requestID string, h http.Header) string {
	fields := []string{"macprovider-settlement-finality-trailers-v1", account, requestID}
	for _, name := range settlementOutcomeNames {
		fields = append(fields, h.Get(name))
	}
	mac := hmac.New(sha256.New, []byte(key))
	for _, field := range fields {
		field = strings.TrimSpace(field)
		fmt.Fprintf(mac, "%d:%s", len(field), field)
	}
	return hex.EncodeToString(mac.Sum(nil))
}

// SPEC-022 R-12.8 negotiation: a gateway that advertised trailer finality
// gets the delivered-only order, the finality tuple as declared trailers
// (none of it in the headers), and a MAC over it keyed by the service token.
func TestHTTPNonStreamingNegotiatedCallerGetsMACdTrailerFinality(t *testing.T) {
	server, _ := newDeliveredOnlyHTTPServer(t)
	rr := httptest.NewRecorder()
	postDeliveredOnly(server, context.Background(), deliveredOnlyChatBody, rr)
	resp := rr.Result()
	_, _ = io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d, want 200", resp.StatusCode)
	}
	if got := resp.Header.Get(settlementOutcomeNames[0]); got != "" {
		t.Fatalf("finality outcome %q sent as a header; negotiated finality travels only as a trailer", got)
	}
	if resp.Trailer.Get(settlementOutcomeNames[0]) == "" {
		t.Fatalf("no finality outcome trailer: trailers=%v", resp.Trailer)
	}
	mac := resp.Trailer.Get("X-MacProvider-Settlement-Finality-Mac")
	if want := independentFinalityMAC("operator-key", "acct_gateway", "ext-req-1", resp.Trailer); mac == "" || !hmac.Equal([]byte(mac), []byte(want)) {
		t.Fatalf("finality MAC=%q, want %q", mac, want)
	}
}

// A caller that did not advertise trailer finality (a pre-#1690 gateway)
// gets the pre-#1690 order: the attempt is recorded before the write and its
// finality arrives in headers, which that gateway reads. No trailers.
func TestHTTPNonStreamingLegacyCallerGetsHeaderFinalityRecordedBeforeWrite(t *testing.T) {
	server, dbPath := newDeliveredOnlyHTTPServer(t)
	rr := httptest.NewRecorder()
	postNonStreaming(server, context.Background(), deliveredOnlyChatBody, rr, false)
	resp := rr.Result()
	_, _ = io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d, want 200", resp.StatusCode)
	}
	if resp.Header.Get(settlementOutcomeNames[0]) == "" {
		t.Fatal("a legacy caller got no header finality")
	}
	if len(resp.Header.Values("Trailer")) != 0 || resp.Header.Get("X-MacProvider-Settlement-Finality-Mac") != "" {
		t.Fatalf("a legacy caller got trailer declarations or a MAC: %v", resp.Header)
	}

	// The pre-#1690 order records before the write, so a failed buyer write
	// still leaves the full success recorded (SPEC-022 v0.2.2 change log).
	server2, dbPath2 := newDeliveredOnlyHTTPServer(t)
	postNonStreaming(server2, context.Background(), deliveredOnlyChatBody, resetBuyerWriter{httptest.NewRecorder()}, false)
	db, err := sql.Open("sqlite", dbPath2)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	var terminalState string
	if err := db.QueryRow(`SELECT terminal_state FROM settlement_attempt_outputs`).Scan(&terminalState); err != nil {
		t.Fatalf("query attempt output: %v", err)
	}
	if terminalState != billing.TerminalStateNormalDone {
		t.Fatalf("legacy caller recorded %s, want normal_done recorded before the write", terminalState)
	}
	_ = dbPath
}

// The WS non-streaming path keeps the same split: a legacy caller is
// recorded before the write.
func TestWSNonStreamingLegacyCallerRecordsBeforeWrite(t *testing.T) {
	h := newBuyerCancelHarness(t, "delivered-only-ws-legacy-catalog", func(h *buyerCancelHarness, ctx context.Context, requestID string, meta *providerws.SettlementReceiptMetadata) *providerws.RelayStream {
		chunks := make(chan providerws.InferenceResponseChunk, 1)
		done := make(chan providerws.InferenceResponseEnd, 1)
		chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Data: deliveredOnlyCompletion}
		close(chunks)
		go func() {
			time.Sleep(50 * time.Millisecond)
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1, Usage: json.RawMessage(`{"prompt_tokens":5,"completion_tokens":4,"total_tokens":9}`)}
		}()
		return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: make(chan error, 1)}
	})
	rr := httptest.NewRecorder()
	postNonStreaming(h.server, h.ctx, deliveredOnlyChatBody, rr, false)
	resp := rr.Result()
	_, _ = io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK || resp.Header.Get(settlementOutcomeNames[0]) == "" || len(resp.Header.Values("Trailer")) != 0 {
		t.Fatalf("legacy WS caller: status=%d headers=%v, want 200 with header finality and no trailers", resp.StatusCode, resp.Header)
	}
	ev := queryBuyerCancelEvidence(t, h.dbPath)
	if ev.terminalState != billing.TerminalStateNormalDone {
		t.Fatalf("terminal_state=%s, want normal_done", ev.terminalState)
	}
}

// normalDoneReceipt signs the v0.4 normal_done tuple an honest provider signs
// over its whole output.
func normalDoneReceipt(t *testing.T, key ed25519.PrivateKey, meta *providerws.SettlementReceiptMetadata, output billing.SettlementOutput, promptTokens, completionTokens, terminalTS int64) string {
	t.Helper()
	outputHash, _, err := output.Digest()
	if err != nil {
		t.Fatalf("output digest: %v", err)
	}
	tuple := map[string]any{
		"account_scope":                 meta.AccountScope,
		"attempt_n":                     meta.AttemptN,
		"catalog_body_digest":           meta.CatalogBodyDigest,
		"catalog_id":                    meta.CatalogID,
		"expected_catalog_model_hash":   meta.ExpectedCatalogModelHash,
		"issued_at_unix_ms":             terminalTS,
		"model_hash":                    meta.ExpectedCatalogModelHash,
		"model_id":                      meta.ModelID,
		"output_hash":                   outputHash,
		"output_prefix_end_byte":        output.OutputPrefixEndByte,
		"output_prefix_start_byte":      output.OutputPrefixStartByte,
		"prompt_hash":                   meta.PromptHash,
		"provider_id":                   meta.ProviderID,
		"provider_receipt_key_id":       meta.ProviderReceiptKeyID,
		"receipt_version":               "4",
		"request_id":                    meta.RequestID,
		"route_snapshot_digest":         meta.RouteSnapshotDigest,
		"route_snapshot_mode":           meta.RouteSnapshotMode,
		"route_snapshot_policy_version": meta.RouteSnapshotPolicyVersion,
		"signature_key_alg":             "Ed25519",
		"terminal_state":                output.TerminalState,
		"terminal_state_ts_unix_ms":     terminalTS,
		"usage": map[string]any{
			"billable_input_tokens":  promptTokens,
			"billable_output_tokens": completionTokens,
			"delivered_output_bytes": output.OutputPrefixEndByte - output.OutputPrefixStartByte,
			"observed_input_tokens":  promptTokens,
			"observed_output_tokens": completionTokens,
		},
	}
	_, canonical, err := billing.CanonicalSHA256Hex(tuple)
	if err != nil {
		t.Fatalf("canonical tuple: %v", err)
	}
	return base64.StdEncoding.EncodeToString(canonical) + "." + base64.StdEncoding.EncodeToString(ed25519.Sign(key, canonical))
}

// Independent review 2 MEDIUM: a buffered tool-call completion whose
// provider sends continuous usage and a final chunk carrying finish_reason
// and usage materializes one tool call, one finish event, and one usage
// event, and the provider's normal_done receipt verifies.
func TestBufferedToolCallContinuousUsageReceiptVerifies(t *testing.T) {
	t.Setenv("COORDINATOR_STREAMING_FORCE_BUFFERED", "1")
	const args = `{"path":"Makefile"}`
	chunks := []string{
		`data: {"id":"c","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_0123456789abcdef","type":"function","function":{"name":"read","arguments":""}}]}}],"usage":{"prompt_tokens":5,"completion_tokens":1,"total_tokens":6}}` + "\n\n",
		`data: {"id":"c","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\":"}}]}}],"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}` + "\n\n",
		`data: {"id":"c","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Makefile\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8}}` + "\n\n",
		"data: [DONE]\n\n",
	}
	h := newBuyerCancelHarness(t, "delivered-only-tool-catalog", func(h *buyerCancelHarness, ctx context.Context, requestID string, meta *providerws.SettlementReceiptMetadata) *providerws.RelayStream {
		ch := make(chan providerws.InferenceResponseChunk, len(chunks))
		done := make(chan providerws.InferenceResponseEnd, 1)
		terminalTS := time.Now().UTC().UnixMilli()
		finish := "tool_calls"
		output := billing.SettlementOutput{
			Available:             true,
			FinishReason:          &finish,
			OutputPrefixStartByte: meta.OutputPrefixStartByte,
			OutputPrefixEndByte:   meta.OutputPrefixStartByte,
			TerminalState:         billing.TerminalStateNormalDone,
			ToolCalls:             []billing.SettlementToolCall{{ID: "call_0123456789abcdef", Type: "function", Name: "read", Arguments: args}},
		}
		receipt := normalDoneReceipt(t, h.key, meta, output, 5, 3, terminalTS)
		for i, data := range chunks {
			ch <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: i, Data: data}
		}
		close(ch)
		go func() {
			time.Sleep(50 * time.Millisecond)
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: len(chunks), Usage: json.RawMessage(`{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8}`), TerminalStateTSUnixMS: terminalTS, Receipt: receipt}
		}()
		return &providerws.RelayStream{RequestID: requestID, Chunks: ch, Done: done, Errors: make(chan error, 1)}
	})

	rr := h.post(t, []byte(`{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hi"}],"temperature":0.000001,"top_p":0.5,"presence_penalty":-0.25,"frequency_penalty":0.125}`))

	body := rr.Body.Bytes()
	if n := bytes.Count(body, []byte(`"finish_reason":"tool_calls"`)); n != 1 {
		t.Fatalf("finish events=%d, want 1: %s", n, body)
	}
	if n := bytes.Count(body, []byte("Makefile")); n != 1 {
		t.Fatalf("argument fragments repeated (%d copies): %s", n, body)
	}
	ev := queryBuyerCancelEvidence(t, h.dbPath)
	if ev.terminalState != billing.TerminalStateNormalDone {
		t.Fatalf("terminal_state=%s, want normal_done", ev.terminalState)
	}
	if ev.settlementOutcome != billing.SettlementOutcomeVerified || ev.receiptResult != billing.SettlementReceiptResultValid {
		t.Fatalf("verdict=(%s,%s), want verified valid: the normal_done receipt must verify", ev.settlementOutcome, ev.receiptResult)
	}
	if !ev.ledgerPrompt.Valid || ev.ledgerPrompt.Int64 != 5 || !ev.ledgerCompletion.Valid || ev.ledgerCompletion.Int64 != 3 {
		t.Fatalf("ledger prompt=%v completion=%v, want 5/3", ev.ledgerPrompt, ev.ledgerCompletion)
	}
}
