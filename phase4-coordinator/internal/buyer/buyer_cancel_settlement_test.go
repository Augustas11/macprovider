package buyer_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
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

// buyerCancelReceipt signs the v0.4 buyer_cancel tuple an honest provider
// signs over the output the buyer received (SPEC-015 §N.5-§N.7).
func buyerCancelReceipt(t *testing.T, key ed25519.PrivateKey, meta *providerws.SettlementReceiptMetadata, content string, promptTokens, completionTokens, terminalTS int64) string {
	t.Helper()
	delivered := billing.SettlementDeliveredOutputBytes(content)
	outputHash, _, err := billing.SettlementOutput{
		Content:               content,
		Available:             true,
		OutputPrefixStartByte: meta.OutputPrefixStartByte,
		OutputPrefixEndByte:   meta.OutputPrefixStartByte + delivered,
		TerminalState:         billing.TerminalStateBuyerCancel,
	}.Digest()
	if err != nil {
		t.Fatalf("output digest: %v", err)
	}
	billableInput, billableOutput := promptTokens, completionTokens
	if delivered == 0 {
		billableInput, billableOutput = 0, 0
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
		"output_prefix_end_byte":        meta.OutputPrefixStartByte + delivered,
		"output_prefix_start_byte":      meta.OutputPrefixStartByte,
		"prompt_hash":                   meta.PromptHash,
		"provider_id":                   meta.ProviderID,
		"provider_receipt_key_id":       meta.ProviderReceiptKeyID,
		"receipt_version":               "4",
		"request_id":                    meta.RequestID,
		"route_snapshot_digest":         meta.RouteSnapshotDigest,
		"route_snapshot_mode":           meta.RouteSnapshotMode,
		"route_snapshot_policy_version": meta.RouteSnapshotPolicyVersion,
		"signature_key_alg":             "Ed25519",
		"terminal_state":                billing.TerminalStateBuyerCancel,
		"terminal_state_ts_unix_ms":     terminalTS,
		"usage": map[string]any{
			"billable_input_tokens":  billableInput,
			"billable_output_tokens": billableOutput,
			"delivered_output_bytes": delivered,
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

type buyerCancelHarness struct {
	server  *buyer.Server
	dbPath  string
	store   *billing.Store
	key     ed25519.PrivateKey
	ctx     context.Context
	cancel  context.CancelFunc
	reqBody []byte
}

func newBuyerCancelHarness(t *testing.T, catalogID string, relay func(h *buyerCancelHarness, ctx context.Context, requestID string, meta *providerws.SettlementReceiptMetadata) *providerws.RelayStream) *buyerCancelHarness {
	t.Helper()
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	raw, pubkey := routeSnapshotCatalogFixture(t, catalogID, time.Now().UTC().Add(time.Hour))
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
	_, key, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("receipt key: %v", err)
	}
	h := &buyerCancelHarness{dbPath: dbPath, store: store, key: key}
	h.ctx, h.cancel = context.WithCancel(context.Background())
	t.Cleanup(h.cancel)
	registry := pool.NewRegistry(nil)
	registerSettlementWSProvider(registry, "p1", "session-1", 20, key.Public().(ed25519.PublicKey))
	h.server = buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithGatewayServiceToken("operator-key"),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(store, cfg),
		buyer.WithBillingSnapshotID(snapshotID),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			t.Fatalf("settlement attempt dispatched without settlement metadata")
			return nil, nil
		}, 5*time.Second),
		buyer.WithSettlementRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool, meta *providerws.SettlementReceiptMetadata) (*providerws.RelayStream, error) {
			return relay(h, ctx, requestID, meta), nil
		}),
	)
	return h
}

func (h *buyerCancelHarness) post(t *testing.T, body []byte) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body)).WithContext(h.ctx)
	req.Header.Set("Authorization", "Bearer operator-key")
	req.Header.Set("X-MacProvider-Account", "acct_gateway")
	rr := httptest.NewRecorder()
	h.server.Handler().ServeHTTP(rr, req)
	return rr
}

type buyerCancelEvidence struct {
	terminalState     string
	deliveredBytes    int64
	usageSource       string
	usageJSON         string
	settlementOutcome string
	receiptResult     string
	closed            bool
	ledgerPrompt      sql.NullInt64
	ledgerCompletion  sql.NullInt64
	ledgerGross       int64
	ledgerQuarantined bool
}

func queryBuyerCancelEvidence(t *testing.T, dbPath string) buyerCancelEvidence {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	var ev buyerCancelEvidence
	if err := db.QueryRow(`
SELECT terminal_state, output_prefix_end_byte - output_prefix_start_byte, usage_source, usage_canonical_json
FROM settlement_attempt_outputs`).Scan(&ev.terminalState, &ev.deliveredBytes, &ev.usageSource, &ev.usageJSON); err != nil {
		t.Fatalf("query attempt output: %v", err)
	}
	if err := db.QueryRow(`
SELECT settlement_outcome, receipt_result, closed
FROM settlement_receipt_verdicts`).Scan(&ev.settlementOutcome, &ev.receiptResult, &ev.closed); err != nil {
		t.Fatalf("query verdict: %v", err)
	}
	if err := db.QueryRow(`
SELECT prompt_tokens, completion_tokens, gross_credits, quarantined
FROM ledger_request_credits`).Scan(&ev.ledgerPrompt, &ev.ledgerCompletion, &ev.ledgerGross, &ev.ledgerQuarantined); err != nil {
		t.Fatalf("query ledger credit: %v", err)
	}
	return ev
}

func buyerCancelUsage(t *testing.T, raw string) map[string]int64 {
	t.Helper()
	var usage map[string]int64
	if err := json.Unmarshal([]byte(raw), &usage); err != nil {
		t.Fatalf("usage json %q: %v", raw, err)
	}
	return usage
}

// A buyer that cancels a stream mid-way received a prefix. The coordinator
// must record buyer_cancel over that prefix, carry the provider's receipt into
// settlement, and settle exactly the delivered prefix (SPEC-015 §N.7,
// SPEC-022 R-5.6, AC-022-50c).
func TestWSStreamingBuyerCancelSettlesDeliveredPrefixReceipt(t *testing.T) {
	const delivered = "Hello, partial"
	h := newBuyerCancelHarness(t, "buyer-cancel-stream-catalog", func(h *buyerCancelHarness, ctx context.Context, requestID string, meta *providerws.SettlementReceiptMetadata) *providerws.RelayStream {
		chunks := make(chan providerws.InferenceResponseChunk)
		terminal := make(chan providerws.InferenceResponseEnd, 1)
		terminalTS := time.Now().UTC().UnixMilli()
		terminal <- providerws.InferenceResponseEnd{
			Type:                  "inference_response_end",
			RequestID:             requestID,
			Status:                "cancelled",
			ChunksSent:            1,
			Usage:                 json.RawMessage(`{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8}`),
			TerminalStateTSUnixMS: terminalTS,
			Receipt:               buyerCancelReceipt(t, h.key, meta, delivered, 5, 3, terminalTS),
		}
		go func() {
			chunks <- providerws.InferenceResponseChunk{
				Type:      "inference_response_chunk",
				RequestID: requestID,
				Data:      `data: {"choices":[{"delta":{"content":"` + delivered + `"}}]}` + "\n\n",
			}
			// The buyer goes away after reading the prefix.
			time.Sleep(50 * time.Millisecond)
			h.cancel()
		}()
		return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: make(chan providerws.InferenceResponseEnd), Errors: make(chan error, 1), CancelTerminal: terminal}
	})

	h.post(t, []byte(`{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hi"}],"temperature":0.000001,"top_p":0.5,"presence_penalty":-0.25,"frequency_penalty":0.125}`))

	ev := queryBuyerCancelEvidence(t, h.dbPath)
	if ev.terminalState != billing.TerminalStateBuyerCancel {
		t.Fatalf("recorded terminal_state=%q, want buyer_cancel (the state the provider signs)", ev.terminalState)
	}
	if ev.deliveredBytes != int64(len(delivered)) {
		t.Fatalf("recorded delivered bytes=%d, want %d", ev.deliveredBytes, len(delivered))
	}
	if ev.usageSource != billing.UsageSourceCoordinatorObserved {
		t.Fatalf("usage_source=%q, want coordinator_observed", ev.usageSource)
	}
	if ev.settlementOutcome != billing.SettlementOutcomeVerified || ev.receiptResult != billing.SettlementReceiptResultValid || !ev.closed {
		t.Fatalf("verdict=(%s,%s,closed=%v), want verified valid closed", ev.settlementOutcome, ev.receiptResult, ev.closed)
	}
	usage := buyerCancelUsage(t, ev.usageJSON)
	if usage["billable_input_tokens"] != 5 || usage["billable_output_tokens"] != 3 || usage["delivered_output_bytes"] != int64(len(delivered)) {
		t.Fatalf("settled usage=%v, want the delivered prefix 5/3", usage)
	}
	if !ev.ledgerCompletion.Valid || ev.ledgerCompletion.Int64 != 3 || ev.ledgerQuarantined {
		t.Fatalf("ledger completion=%v quarantined=%v, want the delivered 3 tokens billed", ev.ledgerCompletion, ev.ledgerQuarantined)
	}
	finality, ok, err := h.store.RequestSettlementFinalityForAccount(context.Background(), "acct_gateway", finalityRequestID(t, h.dbPath), time.Now().UTC().UnixMilli())
	if err != nil || !ok {
		t.Fatalf("finality ok=%v err=%v", ok, err)
	}
	if finality.Outcome != billing.SettlementOutcomeVerified || finality.CompletionTokens != 3 || finality.VerifiedAttempts != 1 {
		t.Fatalf("finality=%+v, want verified with 3 completion tokens", finality)
	}
}

// A non-streaming buyer cancel delivers nothing. The provider's empty-prefix
// buyer_cancel receipt must reach verification and settle to zero, and the
// ledger must bill nothing (SPEC-015 §N.7 zero_settled).
func TestWSNonStreamingBuyerCancelZeroSettlesEmptyPrefixReceipt(t *testing.T) {
	h := newBuyerCancelHarness(t, "buyer-cancel-nonstream-catalog", func(h *buyerCancelHarness, ctx context.Context, requestID string, meta *providerws.SettlementReceiptMetadata) *providerws.RelayStream {
		errs := make(chan error, 1)
		terminal := make(chan providerws.InferenceResponseEnd, 1)
		terminalTS := time.Now().UTC().UnixMilli()
		terminal <- providerws.InferenceResponseEnd{
			Type:                  "inference_response_end",
			RequestID:             requestID,
			Status:                "cancelled",
			Usage:                 json.RawMessage(`{"prompt_tokens":5,"completion_tokens":4,"total_tokens":9}`),
			TerminalStateTSUnixMS: terminalTS,
			Receipt:               buyerCancelReceipt(t, h.key, meta, "", 5, 4, terminalTS),
		}
		go func() {
			time.Sleep(50 * time.Millisecond)
			h.cancel()
			<-ctx.Done()
			errs <- providerws.ErrRelayClosed
		}()
		return &providerws.RelayStream{RequestID: requestID, Chunks: make(chan providerws.InferenceResponseChunk), Done: make(chan providerws.InferenceResponseEnd), Errors: errs, CancelTerminal: terminal}
	})

	h.post(t, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}],"temperature":0.000001,"top_p":0.5,"presence_penalty":-0.25,"frequency_penalty":0.125}`))

	ev := queryBuyerCancelEvidence(t, h.dbPath)
	if ev.terminalState != billing.TerminalStateBuyerCancel || ev.deliveredBytes != 0 {
		t.Fatalf("recorded (%s, %d bytes), want (buyer_cancel, 0 bytes)", ev.terminalState, ev.deliveredBytes)
	}
	if ev.usageSource != billing.UsageSourceCoordinatorObserved {
		t.Fatalf("usage_source=%q, want coordinator_observed", ev.usageSource)
	}
	if ev.settlementOutcome != billing.SettlementOutcomeZeroSettled || ev.receiptResult != billing.SettlementReceiptResultValid || !ev.closed {
		t.Fatalf("verdict=(%s,%s,closed=%v), want zero_settled valid closed", ev.settlementOutcome, ev.receiptResult, ev.closed)
	}
	usage := buyerCancelUsage(t, ev.usageJSON)
	if usage["billable_input_tokens"] != 0 || usage["billable_output_tokens"] != 0 || usage["observed_input_tokens"] != 5 || usage["observed_output_tokens"] != 4 {
		t.Fatalf("settled usage=%v, want zero billable with observed 5/4", usage)
	}
	if !ev.ledgerPrompt.Valid || ev.ledgerPrompt.Int64 != 0 || !ev.ledgerCompletion.Valid || ev.ledgerCompletion.Int64 != 0 || ev.ledgerGross != 0 {
		t.Fatalf("ledger prompt=%v completion=%v gross=%d, want nothing billed", ev.ledgerPrompt, ev.ledgerCompletion, ev.ledgerGross)
	}
	finality, ok, err := h.store.RequestSettlementFinalityForAccount(context.Background(), "acct_gateway", finalityRequestID(t, h.dbPath), time.Now().UTC().UnixMilli())
	if err != nil || !ok {
		t.Fatalf("finality ok=%v err=%v", ok, err)
	}
	if finality.ZeroSettledAttempts != 1 || finality.PromptTokens != 0 || finality.CompletionTokens != 0 {
		t.Fatalf("finality=%+v, want one zero-settled attempt and nothing billable", finality)
	}
}

// A receipt that claims more output than reached the buyer must not bill the
// provider's usage: the ledger keeps the byte estimate and verification fails.
func TestWSStreamingBuyerCancelReceiptClaimingUndeliveredOutputIsNotBilled(t *testing.T) {
	const delivered = "Hello"
	h := newBuyerCancelHarness(t, "buyer-cancel-overclaim-catalog", func(h *buyerCancelHarness, ctx context.Context, requestID string, meta *providerws.SettlementReceiptMetadata) *providerws.RelayStream {
		chunks := make(chan providerws.InferenceResponseChunk)
		terminal := make(chan providerws.InferenceResponseEnd, 1)
		terminalTS := time.Now().UTC().UnixMilli()
		terminal <- providerws.InferenceResponseEnd{
			Type:                  "inference_response_end",
			RequestID:             requestID,
			Status:                "cancelled",
			Usage:                 json.RawMessage(`{"prompt_tokens":5,"completion_tokens":400,"total_tokens":405}`),
			TerminalStateTSUnixMS: terminalTS,
			Receipt:               buyerCancelReceipt(t, h.key, meta, delivered+" and much more", 5, 400, terminalTS),
		}
		go func() {
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Data: `data: {"choices":[{"delta":{"content":"` + delivered + `"}}]}` + "\n\n"}
			time.Sleep(50 * time.Millisecond)
			h.cancel()
		}()
		return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: make(chan providerws.InferenceResponseEnd), Errors: make(chan error, 1), CancelTerminal: terminal}
	})

	h.post(t, []byte(`{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hi"}],"temperature":0.000001,"top_p":0.5,"presence_penalty":-0.25,"frequency_penalty":0.125}`))

	ev := queryBuyerCancelEvidence(t, h.dbPath)
	if ev.terminalState != billing.TerminalStateBuyerCancel || ev.deliveredBytes != int64(len(delivered)) {
		t.Fatalf("recorded (%s, %d bytes), want (buyer_cancel, %d bytes)", ev.terminalState, ev.deliveredBytes, len(delivered))
	}
	if ev.ledgerCompletion.Valid && ev.ledgerCompletion.Int64 == 400 {
		t.Fatal("ledger billed the provider's undelivered completion tokens")
	}
	if ev.settlementOutcome == billing.SettlementOutcomeVerified || ev.settlementOutcome == billing.SettlementOutcomeZeroSettled {
		t.Fatalf("over-claiming receipt settled as %s", ev.settlementOutcome)
	}
}

func finalityRequestID(t *testing.T, dbPath string) string {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	var requestID string
	if err := db.QueryRow(`SELECT request_id FROM settlement_attempt_outputs`).Scan(&requestID); err != nil {
		t.Fatalf("query request id: %v", err)
	}
	return requestID
}
