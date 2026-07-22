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
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
	_ "modernc.org/sqlite"
)

func TestRouteSnapshotsPersistBeforeDispatchAndRetryAttempts(t *testing.T) {
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	raw, pubkey := routeSnapshotCatalogFixture(t, "settlement-catalog", time.Now().UTC().Add(time.Hour))
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
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	setSettlementModeForTest(billingStore, billing.RouteSnapshotModeEnforce)
	cfg := config.Default().Rewards
	snapshotID, err := billingStore.InsertConfigSnapshot(context.Background(), cfg, time.Unix(1716768000, 0).UTC())
	if err != nil {
		t.Fatalf("InsertConfigSnapshot: %v", err)
	}

	var firstSawSnapshot bool
	first := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		firstSawSnapshot = routeSnapshotCount(t, dbPath) == 1
		writeProviderError(w, http.StatusBadGateway)
	}))
	defer first.Close()
	const futureProviderTerminalTS = int64(4102444800000)
	second := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		observeSettlement := config.Default().Settlement
		observeSettlement.VerifiedModelSettlementMode = billing.RouteSnapshotModeObserve
		billingStore.SetSettlementConfig(observeSettlement)
		w.Header().Set("X-MacProvider-Receipt-Terminal-State-TS-Unix-MS", "4102444800000")
		writeProviderOK(w)
	}))
	defer second.Close()

	registry := pool.NewRegistry(nil)
	registerSettlementProvider(registry, "p1", "session-1", first.URL, 30, bytes.Repeat([]byte{0x71}, 32))
	registerSettlementProvider(registry, "p2", "session-2", second.URL, 20, bytes.Repeat([]byte{0x72}, 32))
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithInternalAuthKey("operator-key"),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, cfg),
		buyer.WithBillingSnapshotID(snapshotID),
		buyer.WithRoutingConfig(config.RoutingConfig{
			MaxRetries: 1,
			ModelClasses: map[string]config.ModelClassConfig{
				"mlx-fast": {Models: []string{"model-a"}, Objective: "fast"},
			},
		}),
	)

	rr := postChat(t, server, []byte(`{"model":"mlx-fast","messages":[{"role":"user","content":"hi"}],"temperature":0.000001,"top_p":0.5,"presence_penalty":-0.25,"frequency_penalty":0.125}`), http.Header{
		"Authorization":         {"Bearer operator-key"},
		"X-MacProvider-Account": {"acct_gateway"},
		"X-MacProvider-Retry":   {"1"},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if got := rr.Header().Get("X-MacProvider-Settlement-Outcome"); got != billing.SettlementOutcomePending {
		t.Fatalf("internal settlement outcome header = %q, want %q", got, billing.SettlementOutcomePending)
	}
	if got := rr.Header().Get("X-MacProvider-Settlement-Mode"); got != billing.RouteSnapshotModeEnforce {
		t.Fatalf("internal settlement mode header = %q, want %q", got, billing.RouteSnapshotModeEnforce)
	}
	if !firstSawSnapshot {
		t.Fatal("first upstream did not observe its route snapshot before dispatch")
	}
	rows := queryRouteSnapshots(t, dbPath)
	if len(rows) != 2 {
		t.Fatalf("snapshot rows=%d want 2: %#v", len(rows), rows)
	}
	if rows[0].AttemptN != 0 || rows[0].ProviderID != "p1" {
		t.Fatalf("row0=(attempt=%d provider=%s), want (0,p1)", rows[0].AttemptN, rows[0].ProviderID)
	}
	if rows[1].AttemptN != 1 || rows[1].ProviderID != "p2" {
		t.Fatalf("row1=(attempt=%d provider=%s), want (1,p2)", rows[1].AttemptN, rows[1].ProviderID)
	}
	for _, row := range rows {
		if row.Status != string(pool.HashStatusVerified) {
			t.Fatalf("hash status=%q want %q", row.Status, pool.HashStatusVerified)
		}
		if row.Mode != billing.RouteSnapshotModeEnforce {
			t.Fatalf("route_snapshot_mode=%q want enforce", row.Mode)
		}
		if len(row.Digest) != 64 || len(row.PromptHash) != 64 {
			t.Fatalf("digest/prompt hash lengths invalid: %#v", row)
		}
	}
	wantPromptHash := expectedRouteSnapshotPromptHash(t, "model-a")
	aliasPromptHash := expectedRouteSnapshotPromptHash(t, "mlx-fast")
	if rows[0].PromptHash != wantPromptHash || rows[1].PromptHash != wantPromptHash {
		t.Fatalf("prompt_hashes=(%s,%s), want provider body hash %s", rows[0].PromptHash, rows[1].PromptHash, wantPromptHash)
	}
	if rows[0].PromptHash == aliasPromptHash || rows[1].PromptHash == aliasPromptHash {
		t.Fatalf("prompt_hash used buyer alias hash %s", aliasPromptHash)
	}
	outputRows := querySettlementAttemptOutputs(t, dbPath)
	if len(outputRows) != 2 {
		t.Fatalf("output rows=%d want 2: %#v", len(outputRows), outputRows)
	}
	if outputRows[0].AttemptN != 0 || outputRows[0].ProviderID != "p1" || outputRows[0].TerminalState != billing.TerminalStateProviderError {
		t.Fatalf("row0 output=%#v, want provider_error for p1 attempt 0", outputRows[0])
	}
	if outputRows[0].Start != 0 || outputRows[0].End != 0 {
		t.Fatalf("row0 range=[%d,%d), want empty prefix", outputRows[0].Start, outputRows[0].End)
	}
	if outputRows[1].AttemptN != 1 || outputRows[1].ProviderID != "p2" || outputRows[1].TerminalState != billing.TerminalStateNormalDone {
		t.Fatalf("row1 output=%#v, want normal_done for p2 attempt 1", outputRows[1])
	}
	if outputRows[1].Start != 0 || outputRows[1].End != 2 || outputRows[1].UsageSource != billing.UsageSourceCoordinatorObserved {
		t.Fatalf("row1 range/source=(%d,%d,%s), want (0,2,%s)", outputRows[1].Start, outputRows[1].End, outputRows[1].UsageSource, billing.UsageSourceCoordinatorObserved)
	}
	if outputRows[0].TerminalStateTSUnixMS <= 0 || outputRows[1].TerminalStateTSUnixMS <= 0 {
		t.Fatalf("terminal_state_ts_unix_ms missing: %#v", outputRows)
	}
	if outputRows[1].TerminalStateTSUnixMS == futureProviderTerminalTS {
		t.Fatalf("provider-controlled terminal timestamp was persisted: %#v", outputRows[1])
	}
	if len(outputRows[0].OutputHash) != 64 || len(outputRows[1].OutputHash) != 64 {
		t.Fatalf("output hashes invalid: %#v", outputRows)
	}
	verdicts := querySettlementReceiptVerdicts(t, dbPath)
	if len(verdicts) != 2 {
		t.Fatalf("receipt verdict rows=%d want 2 covered attempts: %#v", len(verdicts), verdicts)
	}
	for _, verdict := range verdicts {
		if verdict.ReceiptPresent != 0 || verdict.ReceiptResult != billing.SettlementReceiptResultInconclusive || verdict.SettlementOutcome != billing.SettlementOutcomePending {
			t.Fatalf("verdict=%#v, want missing receipt pending/inconclusive", verdict)
		}
	}
	ledgerPolicies := queryLedgerSettlementPolicies(t, dbPath)
	if len(ledgerPolicies) != 2 {
		t.Fatalf("ledger policy rows=%d want 2: %#v", len(ledgerPolicies), ledgerPolicies)
	}
	for _, policy := range ledgerPolicies {
		if policy != billing.RouteSnapshotModeEnforce {
			t.Fatalf("ledger settlement policy=%q want enforce", policy)
		}
	}
	if err := billingStore.RunSettlement(context.Background(), config.SettlementConfig{
		CadenceDays:                 7,
		MinPayoutCredits:            1,
		StartupReconcileWindowHours: 24,
		NightlyReconcileWindowDays:  7,
		RecoveryGraceSeconds:        30,
		VerifiedModelSettlementMode: billing.RouteSnapshotModeEnforce,
		JobEnabled:                  true,
	}, time.Unix(1716768000, 0).UTC().Add(-time.Hour), time.Unix(4102444800, 0).UTC().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if got := payoutReadyCount(t, dbPath); got != 0 {
		t.Fatalf("payout-ready rows without verified receipt=%d want 0", got)
	}
}

// TestRouteSnapshotPendingDeadlineUsesDedicatedKeyNotRecoveryGrace locks the
// money-path wiring: settlement.pending_deadline_seconds and
// settlement.recovery_grace_seconds are set to distinct values and the
// persisted route snapshot must use the former. A future refactor that
// reverts the pending-deadline derivation back to RecoveryGraceSeconds would
// fail this test (it would not, with equal values).
func TestRouteSnapshotPendingDeadlineUsesDedicatedKeyNotRecoveryGrace(t *testing.T) {
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	raw, pubkey := routeSnapshotCatalogFixture(t, "pending-deadline-wiring-catalog", time.Now().UTC().Add(time.Hour))
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
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	settlementCfg := config.Default().Settlement
	settlementCfg.RecoveryGraceSeconds = 17
	settlementCfg.PendingDeadlineSeconds = 321
	billingStore.SetSettlementConfig(settlementCfg)
	cfg := config.Default().Rewards
	snapshotID, err := billingStore.InsertConfigSnapshot(context.Background(), cfg, time.Unix(1716768000, 0).UTC())
	if err != nil {
		t.Fatalf("InsertConfigSnapshot: %v", err)
	}

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeProviderOK(w)
	}))
	defer upstream.Close()

	registry := pool.NewRegistry(nil)
	registerSettlementProvider(registry, "p1", "session-1", upstream.URL, 30, bytes.Repeat([]byte{0x82}, 32))
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, cfg),
		buyer.WithBillingSnapshotID(snapshotID),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if got := routeSnapshotCount(t, dbPath); got != 1 {
		t.Fatalf("route snapshots=%d want 1", got)
	}
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	var pendingDeadline int64
	if err := db.QueryRow(`SELECT pending_deadline_seconds FROM settlement_route_snapshots`).Scan(&pendingDeadline); err != nil {
		t.Fatalf("query pending_deadline_seconds: %v", err)
	}
	if pendingDeadline != 321 {
		t.Fatalf("pending_deadline_seconds=%d, want 321 (settlement.pending_deadline_seconds); a wiring regression to recovery_grace_seconds would yield 17", pendingDeadline)
	}
}

func TestSettlementOutputDoesNotUseV04ReceiptTerminalTimestamp(t *testing.T) {
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	raw, pubkey := routeSnapshotCatalogFixture(t, "settlement-terminal-ts-catalog", time.Now().UTC().Add(time.Hour))
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
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	setSettlementModeForTest(billingStore, billing.RouteSnapshotModeEnforce)
	cfg := config.Default().Rewards
	snapshotID, err := billingStore.InsertConfigSnapshot(context.Background(), cfg, time.Unix(1716768000, 0).UTC())
	if err != nil {
		t.Fatalf("InsertConfigSnapshot: %v", err)
	}

	const futureProviderTerminalTS = int64(4102444800000)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-MacProvider-Receipt", syntheticV04ReceiptHeader(t, futureProviderTerminalTS))
		writeProviderOK(w)
	}))
	defer upstream.Close()

	registry := pool.NewRegistry(nil)
	registerSettlementProvider(registry, "p1", "session-1", upstream.URL, 30, bytes.Repeat([]byte{0x78}, 32))
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithInternalAuthKey("operator-key"),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, cfg),
		buyer.WithBillingSnapshotID(snapshotID),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}],"temperature":0.000001,"top_p":0.5,"presence_penalty":-0.25,"frequency_penalty":0.125}`), nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if got := rr.Header().Get("X-MacProvider-Receipt"); got != "" {
		t.Fatalf("v0.4 settlement receipt leaked to buyer: %q", got)
	}
	if got := rr.Header().Get("X-MacProvider-Settlement-Outcome"); got != "" {
		t.Fatalf("direct buyer response leaked settlement outcome header: %q", got)
	}
	if got := rr.Header().Get("X-MacProvider-Settlement-Receipt-Result"); got != "" {
		t.Fatalf("direct buyer response leaked settlement receipt result header: %q", got)
	}
	if got := rr.Header().Get("X-MacProvider-Settlement-Closed"); got != "" {
		t.Fatalf("direct buyer response leaked settlement closed header: %q", got)
	}
	outputRows := querySettlementAttemptOutputs(t, dbPath)
	if len(outputRows) != 1 {
		t.Fatalf("output rows=%d want 1: %#v", len(outputRows), outputRows)
	}
	if outputRows[0].TerminalStateTSUnixMS <= 0 {
		t.Fatalf("terminal_state_ts_unix_ms missing: %#v", outputRows[0])
	}
	if outputRows[0].TerminalStateTSUnixMS == futureProviderTerminalTS {
		t.Fatalf("provider-controlled terminal timestamp was persisted: %#v", outputRows[0])
	}

	internalHeaders := http.Header{}
	internalHeaders.Set("Authorization", "Bearer operator-key")
	internalHeaders.Set("X-MacProvider-Account", "acct_gateway")
	internalRR := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}],"temperature":0.000001,"top_p":0.5,"presence_penalty":-0.25,"frequency_penalty":0.125}`), internalHeaders)
	if internalRR.Code != http.StatusOK {
		t.Fatalf("internal status=%d body=%s", internalRR.Code, internalRR.Body.String())
	}
	if got := internalRR.Header().Get("X-MacProvider-Settlement-Outcome"); got != billing.SettlementOutcomeQuarantined {
		t.Fatalf("internal settlement outcome header = %q, want %q", got, billing.SettlementOutcomeQuarantined)
	}
	if got := internalRR.Header().Get("X-MacProvider-Settlement-Receipt-Result"); got != billing.SettlementReceiptResultInvalid {
		t.Fatalf("internal settlement receipt result header = %q, want %q", got, billing.SettlementReceiptResultInvalid)
	}
	if got := internalRR.Header().Get("X-MacProvider-Settlement-Closed"); got != "true" {
		t.Fatalf("internal settlement closed header = %q, want true", got)
	}
	if got := internalRR.Header().Get("X-MacProvider-Settlement-Mode"); got != billing.RouteSnapshotModeEnforce {
		t.Fatalf("internal settlement mode header = %q, want %q", got, billing.RouteSnapshotModeEnforce)
	}
}

func TestWSTunneledNonStreamingEmitsInternalSettlementHeaders(t *testing.T) {
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	raw, pubkey := routeSnapshotCatalogFixture(t, "settlement-ws-catalog", time.Now().UTC().Add(time.Hour))
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
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	setSettlementModeForTest(billingStore, billing.RouteSnapshotModeEnforce)
	cfg := config.Default().Rewards
	snapshotID, err := billingStore.InsertConfigSnapshot(context.Background(), cfg, time.Unix(1716768000, 0).UTC())
	if err != nil {
		t.Fatalf("InsertConfigSnapshot: %v", err)
	}

	const futureProviderTerminalTS = int64(4102444800000)
	registry := pool.NewRegistry(nil)
	registerSettlementWSProvider(registry, "p1", "session-1", 20, bytes.Repeat([]byte{0x79}, 32))
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithInternalAuthKey("operator-key"),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, cfg),
		buyer.WithBillingSnapshotID(snapshotID),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: `{"id":"ws","object":"chat.completion","choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1, Receipt: syntheticV04ReceiptHeader(t, futureProviderTerminalTS)}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}],"temperature":0.000001,"top_p":0.5,"presence_penalty":-0.25,"frequency_penalty":0.125}`), http.Header{
		"Authorization":         {"Bearer operator-key"},
		"X-MacProvider-Account": {"acct_gateway"},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if got := rr.Header().Get("X-MacProvider-Receipt"); got != "" {
		t.Fatalf("v0.4 settlement receipt leaked to buyer: %q", got)
	}
	if got := rr.Header().Get("X-MacProvider-Settlement-Outcome"); got != billing.SettlementOutcomeQuarantined {
		t.Fatalf("internal WS settlement outcome header = %q, want %q", got, billing.SettlementOutcomeQuarantined)
	}
	if got := rr.Header().Get("X-MacProvider-Settlement-Receipt-Result"); got != billing.SettlementReceiptResultInvalid {
		t.Fatalf("internal WS settlement receipt result header = %q, want %q", got, billing.SettlementReceiptResultInvalid)
	}
	if got := rr.Header().Get("X-MacProvider-Settlement-Closed"); got != "true" {
		t.Fatalf("internal WS settlement closed header = %q, want true", got)
	}
	if got := rr.Header().Get("X-MacProvider-Settlement-Mode"); got != billing.RouteSnapshotModeEnforce {
		t.Fatalf("internal WS settlement mode header = %q, want %q", got, billing.RouteSnapshotModeEnforce)
	}
	if got := rr.Header().Get("X-MacProvider-Settlement-Policy-Version"); got != billing.RouteSnapshotPolicyVersion {
		t.Fatalf("internal WS settlement policy version header = %q, want %q", got, billing.RouteSnapshotPolicyVersion)
	}
	verdicts := querySettlementReceiptVerdicts(t, dbPath)
	if len(verdicts) != 1 || verdicts[0].ProviderID != "p1" || verdicts[0].SettlementOutcome != billing.SettlementOutcomeQuarantined || verdicts[0].ReceiptResult != billing.SettlementReceiptResultInvalid {
		t.Fatalf("WS settlement verdicts = %#v, want one quarantined invalid verdict for p1", verdicts)
	}
}

func TestSettlementOutputUsesBoundedTerminalTimestampHeader(t *testing.T) {
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	raw, pubkey := routeSnapshotCatalogFixture(t, "settlement-terminal-header-catalog", time.Now().UTC().Add(time.Hour))
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
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	cfg := config.Default().Rewards
	snapshotID, err := billingStore.InsertConfigSnapshot(context.Background(), cfg, time.Unix(1716768000, 0).UTC())
	if err != nil {
		t.Fatalf("InsertConfigSnapshot: %v", err)
	}

	var terminalTS int64
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		terminalTS = time.Now().UTC().UnixMilli()
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-MacProvider-Receipt-Terminal-State-TS-Unix-MS", strconv.FormatInt(terminalTS, 10))
		w.Header().Set("X-MacProvider-Receipt", syntheticV04ReceiptHeader(t, terminalTS))
		writeProviderOK(w)
	}))
	defer upstream.Close()

	registry := pool.NewRegistry(nil)
	registerSettlementProvider(registry, "p1", "session-1", upstream.URL, 30, bytes.Repeat([]byte{0x79}, 32))
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, cfg),
		buyer.WithBillingSnapshotID(snapshotID),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}],"temperature":0.000001,"top_p":0.5,"presence_penalty":-0.25,"frequency_penalty":0.125}`), nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	outputRows := querySettlementAttemptOutputs(t, dbPath)
	if len(outputRows) != 1 {
		t.Fatalf("output rows=%d want 1: %#v", len(outputRows), outputRows)
	}
	if outputRows[0].TerminalStateTSUnixMS != terminalTS {
		t.Fatalf("terminal_state_ts_unix_ms=%d want bounded terminal header ts %d", outputRows[0].TerminalStateTSUnixMS, terminalTS)
	}
}

func TestStreamingSettlementOutputPersistsOpenAICompatibleSSE(t *testing.T) {
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	raw, pubkey := routeSnapshotCatalogFixture(t, "streaming-settlement-catalog", time.Now().UTC().Add(time.Hour))
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
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	setSettlementModeForTest(billingStore, billing.RouteSnapshotModeEnforce)
	cfg := config.Default().Rewards
	snapshotID, err := billingStore.InsertConfigSnapshot(context.Background(), cfg, time.Unix(1716768000, 0).UTC())
	if err != nil {
		t.Fatalf("InsertConfigSnapshot: %v", err)
	}

	const futureStreamingProviderTerminalTS = int64(4102444800000)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
		w.Header().Add("Trailer", "X-MacProvider-Receipt")
		w.Header().Add("Trailer", "X-MacProvider-Receipt-Terminal-State-TS-Unix-MS")
		_, _ = w.Write([]byte(`data: {"id":"chatcmpl-test","choices":[{"delta":{"content":"he"},"finish_reason":null}]}` + "\n\n"))
		_, _ = w.Write([]byte(`data: {"id":"chatcmpl-test","choices":[{"delta":{"content":"llo"},"finish_reason":null}]}` + "\n\n"))
		_, _ = w.Write([]byte(`data: {"id":"chatcmpl-test","usage":{"prompt_tokens":2,"completion_tokens":2,"total_tokens":4},"choices":[{"delta":{},"finish_reason":"stop"}]}` + "\n\n"))
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
		w.Header().Set("X-MacProvider-Receipt", syntheticV04ReceiptHeader(t, futureStreamingProviderTerminalTS))
		w.Header().Set("X-MacProvider-Receipt-Terminal-State-TS-Unix-MS", "4102444800000")
	}))
	defer upstream.Close()

	registry := pool.NewRegistry(nil)
	registerSettlementProvider(registry, "p1", "session-1", upstream.URL, 30, bytes.Repeat([]byte{0x73}, 32))
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithInternalAuthKey("operator-key"),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, cfg),
		buyer.WithBillingSnapshotID(snapshotID),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hi"}]}`), nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	body := rr.Body.String()
	if !bytes.Contains([]byte(body), []byte(`data: {"id":"chatcmpl-test"`)) || !bytes.Contains([]byte(body), []byte("data: [DONE]")) {
		t.Fatalf("stream body not relayed as OpenAI-compatible SSE: %s", body)
	}
	if got := rr.Header().Get("X-MacProvider-Settlement-Outcome"); got != "" {
		t.Fatalf("direct buyer response leaked settlement outcome header: %q", got)
	}
	if got := rr.Header().Get("Trailer"); got != "" {
		t.Fatalf("direct buyer response leaked internal Trailer declaration: %q", got)
	}

	outputRows := querySettlementAttemptOutputs(t, dbPath)
	if len(outputRows) != 1 {
		t.Fatalf("output rows=%d want 1: %#v", len(outputRows), outputRows)
	}
	row := outputRows[0]
	if row.AttemptN != 0 || row.ProviderID != "p1" || row.TerminalState != billing.TerminalStateNormalDone {
		t.Fatalf("output row=%#v, want normal_done for p1 attempt 0", row)
	}
	if row.Start != 0 || row.End != 5 || row.UsageSource != billing.UsageSourceCoordinatorObserved {
		t.Fatalf("range/source=(%d,%d,%s), want (0,5,%s)", row.Start, row.End, row.UsageSource, billing.UsageSourceCoordinatorObserved)
	}
	if row.TerminalStateTSUnixMS <= 0 {
		t.Fatalf("terminal_state_ts_unix_ms missing: %#v", row)
	}
	if row.TerminalStateTSUnixMS == futureStreamingProviderTerminalTS {
		t.Fatalf("provider-controlled streaming terminal timestamp was persisted: %#v", row)
	}
	if row.CanonicalJSON != "" {
		t.Fatalf("raw canonical output persisted unexpectedly: %s", row.CanonicalJSON)
	}

	internalHeaders := http.Header{}
	internalHeaders.Set("Authorization", "Bearer operator-key")
	internalHeaders.Set("X-MacProvider-Account", "acct_gateway")
	internalRR := postChat(t, server, []byte(`{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hi"}]}`), internalHeaders)
	if internalRR.Code != http.StatusOK {
		t.Fatalf("internal status=%d body=%s", internalRR.Code, internalRR.Body.String())
	}
	internalBody := internalRR.Body.String()
	if !bytes.Contains([]byte(internalBody), []byte(`data: {"id":"chatcmpl-test"`)) || !bytes.Contains([]byte(internalBody), []byte("data: [DONE]")) {
		t.Fatalf("internal stream body not relayed as OpenAI-compatible SSE: %s", internalBody)
	}
	internalResult := internalRR.Result()
	if got := internalResult.Trailer.Get("X-MacProvider-Settlement-Outcome"); got != billing.SettlementOutcomeQuarantined {
		t.Fatalf("internal streaming settlement outcome trailer = %q, want %q", got, billing.SettlementOutcomeQuarantined)
	}
	if got := internalResult.Trailer.Get("X-MacProvider-Settlement-Receipt-Result"); got != billing.SettlementReceiptResultInvalid {
		t.Fatalf("internal streaming settlement receipt result trailer = %q, want %q", got, billing.SettlementReceiptResultInvalid)
	}
	if got := internalResult.Trailer.Get("X-MacProvider-Settlement-Closed"); got != "true" {
		t.Fatalf("internal streaming settlement closed trailer = %q, want true", got)
	}
	if got := internalResult.Trailer.Get("X-MacProvider-Settlement-Mode"); got != billing.RouteSnapshotModeEnforce {
		t.Fatalf("internal streaming settlement mode trailer = %q, want %q", got, billing.RouteSnapshotModeEnforce)
	}
	if got := internalResult.Trailer.Get("X-MacProvider-Settlement-Policy-Version"); got != billing.RouteSnapshotPolicyVersion {
		t.Fatalf("internal streaming settlement policy version trailer = %q, want %q", got, billing.RouteSnapshotPolicyVersion)
	}
}

func TestRouteSnapshotFailsClosedOnTier2AdmissionConflictInObserveMode(t *testing.T) {
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	raw, pubkey := routeSnapshotCatalogFixture(t, "conflict-catalog", time.Now().UTC().Add(time.Hour))
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
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	setSettlementModeForTest(billingStore, billing.RouteSnapshotModeObserve)
	cfg := config.Default().Rewards
	snapshotID, err := billingStore.InsertConfigSnapshot(context.Background(), cfg, time.Unix(1716768000, 0).UTC())
	if err != nil {
		t.Fatalf("InsertConfigSnapshot: %v", err)
	}

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("upstream must not be reached when Tier-2 conflicts with admission hash")
	}))
	defer upstream.Close()

	registry := pool.NewRegistry(nil)
	registerSettlementProvider(registry, "p1", "session-1", upstream.URL, 30, bytes.Repeat([]byte{0x76}, 32))
	providers := registry.Snapshot()
	if len(providers) != 1 {
		t.Fatalf("providers=%d", len(providers))
	}
	provider := providers[0]
	// Admission identity differs from the active Tier-2 row for model-a.
	provider.ExpectedModelHash = strings.Repeat("c", 64)
	provider.ModelHash = strings.Repeat("c", 64)
	provider.HashStatus = pool.HashStatusVerified
	registry.Register(&provider, nil)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, cfg),
		buyer.WithBillingSnapshotID(snapshotID),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), nil)
	if rr.Code == http.StatusOK {
		t.Fatalf("observe-mode conflict must fail closed, got status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !strings.Contains(rr.Body.String(), "tier2 catalog does not match signed admission row") &&
		!strings.Contains(rr.Body.String(), "route snapshot") {
		// Buyer surfaces the recorder error; accept either the exact conflict
		// text or a route-snapshot failure wrapper.
		t.Fatalf("response missing conflict signal: status=%d body=%s", rr.Code, rr.Body.String())
	}
	if got := routeSnapshotCount(t, dbPath); got != 0 {
		t.Fatalf("route snapshots=%d want 0 on conflict", got)
	}
}

func TestRouteSnapshotSkippedForNonSettlementCapableModelHash(t *testing.T) {
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	raw, pubkey := routeSnapshotCatalogFixture(t, "non-settlement-capable-catalog", time.Now().UTC().Add(time.Hour))
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
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	setSettlementModeForTest(billingStore, billing.RouteSnapshotModeObserve)
	cfg := config.Default().Rewards
	snapshotID, err := billingStore.InsertConfigSnapshot(context.Background(), cfg, time.Unix(1716768000, 0).UTC())
	if err != nil {
		t.Fatalf("InsertConfigSnapshot: %v", err)
	}

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeProviderOK(w)
	}))
	defer upstream.Close()

	registry := pool.NewRegistry(nil)
	registerSettlementProvider(registry, "p1", "session-1", upstream.URL, 30, bytes.Repeat([]byte{0x76}, 32))
	providers := registry.Snapshot()
	if len(providers) != 1 {
		t.Fatalf("providers=%d", len(providers))
	}
	provider := providers[0]
	provider.ModelHash = strings.Repeat("b", 64)
	provider.HashStatus = pool.HashStatusMismatch
	registry.Register(&provider, nil)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, cfg),
		buyer.WithBillingSnapshotID(snapshotID),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if got := routeSnapshotCount(t, dbPath); got != 0 {
		t.Fatalf("route snapshots=%d want 0 for non-settlement-capable hash", got)
	}
	if verdicts := querySettlementReceiptVerdicts(t, dbPath); len(verdicts) != 0 {
		t.Fatalf("receipt verdict rows=%d want 0: %#v", len(verdicts), verdicts)
	}
}

func TestRouteSnapshotSkippedForUppercaseModelHash(t *testing.T) {
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	raw, pubkey := routeSnapshotCatalogFixture(t, "uppercase-hash-catalog", time.Now().UTC().Add(time.Hour))
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
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	setSettlementModeForTest(billingStore, billing.RouteSnapshotModeObserve)
	cfg := config.Default().Rewards
	snapshotID, err := billingStore.InsertConfigSnapshot(context.Background(), cfg, time.Unix(1716768000, 0).UTC())
	if err != nil {
		t.Fatalf("InsertConfigSnapshot: %v", err)
	}

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeProviderOK(w)
	}))
	defer upstream.Close()

	registry := pool.NewRegistry(nil)
	registerSettlementProvider(registry, "p1", "session-1", upstream.URL, 30, bytes.Repeat([]byte{0x77}, 32))
	providers := registry.Snapshot()
	if len(providers) != 1 {
		t.Fatalf("providers=%d", len(providers))
	}
	provider := providers[0]
	provider.ModelHash = strings.ToUpper(buyerTestHash)
	provider.HashStatus = pool.HashStatusVerified
	registry.Register(&provider, nil)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, cfg),
		buyer.WithBillingSnapshotID(snapshotID),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if got := routeSnapshotCount(t, dbPath); got != 0 {
		t.Fatalf("route snapshots=%d want 0 for uppercase model hash", got)
	}
	if verdicts := querySettlementReceiptVerdicts(t, dbPath); len(verdicts) != 0 {
		t.Fatalf("receipt verdict rows=%d want 0: %#v", len(verdicts), verdicts)
	}
}

func TestRouteSnapshotEnforceFailsClosedWithoutValidReceiptKey(t *testing.T) {
	for _, tc := range []struct {
		name string
		key  []byte
	}{
		{name: "missing", key: nil},
		{name: "malformed", key: []byte{0x01, 0x02, 0x03}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tier2.ResetForTest()
			t.Cleanup(tier2.ResetForTest)
			raw, pubkey := routeSnapshotCatalogFixture(t, "enforce-"+tc.name+"-receipt-key-catalog", time.Now().UTC().Add(time.Hour))
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
			billingStore, err := billing.NewStore(reqLog.DB())
			if err != nil {
				t.Fatalf("billing.NewStore: %v", err)
			}
			setSettlementModeForTest(billingStore, billing.RouteSnapshotModeEnforce)
			cfg := config.Default().Rewards
			snapshotID, err := billingStore.InsertConfigSnapshot(context.Background(), cfg, time.Unix(1716768000, 0).UTC())
			if err != nil {
				t.Fatalf("InsertConfigSnapshot: %v", err)
			}

			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				writeProviderOK(w)
			}))
			defer upstream.Close()

			registry := pool.NewRegistry(nil)
			registerSettlementProvider(registry, "p1", "session-1", upstream.URL, 30, tc.key)
			server := buyer.NewServer(
				registry,
				zerolog.Nop(),
				time.Unix(1716768000, 0),
				buyer.WithRequestLog(reqLog),
				buyer.WithBilling(billingStore, cfg),
				buyer.WithBillingSnapshotID(snapshotID),
			)

			rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), nil)
			if rr.Code != http.StatusInternalServerError {
				t.Fatalf("status=%d body=%s, want enforce fail-closed", rr.Code, rr.Body.String())
			}
			if got := routeSnapshotCount(t, dbPath); got != 0 {
				t.Fatalf("route snapshots=%d want 0", got)
			}
			if got := ledgerCreditCount(t, dbPath); got != 0 {
				t.Fatalf("ledger credits=%d want 0", got)
			}
		})
	}
}

func TestMalformedNonStreamingOutputPersistsUnavailableEvidence(t *testing.T) {
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	raw, pubkey := routeSnapshotCatalogFixture(t, "malformed-output-catalog", time.Now().UTC().Add(time.Hour))
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
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	cfg := config.Default().Rewards
	snapshotID, err := billingStore.InsertConfigSnapshot(context.Background(), cfg, time.Unix(1716768000, 0).UTC())
	if err != nil {
		t.Fatalf("InsertConfigSnapshot: %v", err)
	}

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":["not","string"]},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":2,"total_tokens":4}}`))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry(nil)
	registerSettlementProvider(registry, "p1", "session-1", upstream.URL, 30, bytes.Repeat([]byte{0x74}, 32))
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, cfg),
		buyer.WithBillingSnapshotID(snapshotID),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}

	row := querySettlementAttemptOutputs(t, dbPath)[0]
	if row.OutputAvailable != 0 || row.OutputHash != "" {
		t.Fatalf("output availability/hash=(%d,%q), want unavailable with null hash: %#v", row.OutputAvailable, row.OutputHash, row)
	}
}

func TestUnavailableOutputAfterPrefixKeepsEmptyRange(t *testing.T) {
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	raw, pubkey := routeSnapshotCatalogFixture(t, "unavailable-after-prefix-catalog", time.Now().UTC().Add(time.Hour))
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
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	cfg := config.Default().Rewards
	snapshotID, err := billingStore.InsertConfigSnapshot(context.Background(), cfg, time.Unix(1716768000, 0).UTC())
	if err != nil {
		t.Fatalf("InsertConfigSnapshot: %v", err)
	}

	var calls int
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.Header().Set("Content-Type", "application/json")
		if calls == 1 {
			writeProviderOK(w)
			return
		}
		_, _ = w.Write([]byte(`{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":["not","string"]},"finish_reason":"stop"}]}`))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry(nil)
	registerSettlementProvider(registry, "p1", "session-1", upstream.URL, 30, bytes.Repeat([]byte{0x75}, 32))
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, cfg),
		buyer.WithBillingSnapshotID(snapshotID),
	)

	for i := 0; i < 2; i++ {
		rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), nil)
		if rr.Code != http.StatusOK {
			t.Fatalf("request %d status=%d body=%s", i, rr.Code, rr.Body.String())
		}
	}

	rows := querySettlementAttemptOutputs(t, dbPath)
	if len(rows) != 2 {
		t.Fatalf("output rows=%d want 2: %#v", len(rows), rows)
	}
	if rows[0].OutputAvailable != 1 || rows[0].End <= rows[0].Start {
		t.Fatalf("row0=%#v, want available non-empty prefix", rows[0])
	}
	if rows[1].OutputAvailable != 0 || rows[1].Start != 0 || rows[1].End != 0 || rows[1].OutputHash != "" {
		t.Fatalf("row1=%#v, want unavailable empty range with null hash", rows[1])
	}
}

type routeSnapshotRow struct {
	AttemptN   int
	ProviderID string
	Status     string
	Mode       string
	Digest     string
	PromptHash string
}

type settlementAttemptOutputRow struct {
	AccountScope          string
	AttemptN              int
	ProviderID            string
	TerminalState         string
	Start                 int64
	End                   int64
	OutputHash            string
	UsageSource           string
	CanonicalJSON         string
	TerminalStateTSUnixMS int64
	OutputAvailable       int
}

type settlementReceiptVerdictRow struct {
	AttemptN          int
	ProviderID        string
	ReceiptPresent    int
	ReceiptResult     string
	SettlementOutcome string
	Closed            int
}

func querySettlementReceiptVerdicts(t *testing.T, dbPath string) []settlementReceiptVerdictRow {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	rows, err := db.Query(`
SELECT attempt_n, provider_id, receipt_present, receipt_result, settlement_outcome, closed
FROM settlement_receipt_verdicts
ORDER BY attempt_n ASC`)
	if err != nil {
		t.Fatalf("query verdicts: %v", err)
	}
	defer rows.Close()
	var got []settlementReceiptVerdictRow
	for rows.Next() {
		var row settlementReceiptVerdictRow
		if err := rows.Scan(&row.AttemptN, &row.ProviderID, &row.ReceiptPresent, &row.ReceiptResult, &row.SettlementOutcome, &row.Closed); err != nil {
			t.Fatalf("scan verdicts: %v", err)
		}
		got = append(got, row)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("verdict rows: %v", err)
	}
	return got
}

func querySettlementAttemptOutputs(t *testing.T, dbPath string) []settlementAttemptOutputRow {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	rows, err := db.Query(`
SELECT attempt_n, provider_id, terminal_state, output_prefix_start_byte,
       output_prefix_end_byte, COALESCE(output_hash, ''), usage_source, COALESCE(settlement_output_canonical_json, ''),
       terminal_state_ts_unix_ms
       , output_available, account_scope
FROM settlement_attempt_outputs
ORDER BY attempt_n ASC`)
	if err != nil {
		t.Fatalf("query outputs: %v", err)
	}
	defer rows.Close()
	var got []settlementAttemptOutputRow
	for rows.Next() {
		var row settlementAttemptOutputRow
		if err := rows.Scan(&row.AttemptN, &row.ProviderID, &row.TerminalState, &row.Start, &row.End, &row.OutputHash, &row.UsageSource, &row.CanonicalJSON, &row.TerminalStateTSUnixMS, &row.OutputAvailable, &row.AccountScope); err != nil {
			t.Fatalf("scan outputs: %v", err)
		}
		got = append(got, row)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("outputs rows: %v", err)
	}
	return got
}

func queryRouteSnapshots(t *testing.T, dbPath string) []routeSnapshotRow {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	rows, err := db.Query(`
SELECT attempt_n, provider_id, spec008_hash_status, route_snapshot_mode, route_snapshot_digest, prompt_hash
FROM settlement_route_snapshots
ORDER BY attempt_n ASC`)
	if err != nil {
		t.Fatalf("query snapshots: %v", err)
	}
	defer rows.Close()
	var got []routeSnapshotRow
	for rows.Next() {
		var row routeSnapshotRow
		if err := rows.Scan(&row.AttemptN, &row.ProviderID, &row.Status, &row.Mode, &row.Digest, &row.PromptHash); err != nil {
			t.Fatalf("scan snapshots: %v", err)
		}
		got = append(got, row)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("snapshots rows: %v", err)
	}
	return got
}

func queryLedgerSettlementPolicies(t *testing.T, dbPath string) []string {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	rows, err := db.Query(`SELECT settlement_policy_mode FROM ledger_request_credits ORDER BY attempt_n ASC`)
	if err != nil {
		t.Fatalf("query ledger policies: %v", err)
	}
	defer rows.Close()
	var got []string
	for rows.Next() {
		var policy string
		if err := rows.Scan(&policy); err != nil {
			t.Fatalf("scan ledger policy: %v", err)
		}
		got = append(got, policy)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("ledger policy rows: %v", err)
	}
	return got
}

func payoutReadyCount(t *testing.T, dbPath string) int {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM ledger_payout_ready`).Scan(&count); err != nil {
		t.Fatalf("count payout-ready: %v", err)
	}
	return count
}

func ledgerCreditCount(t *testing.T, dbPath string) int {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM ledger_request_credits`).Scan(&count); err != nil {
		t.Fatalf("count ledger credits: %v", err)
	}
	return count
}

func setSettlementModeForTest(store *billing.Store, mode string) {
	cfg := config.Default().Settlement
	cfg.VerifiedModelSettlementMode = mode
	store.SetSettlementConfig(cfg)
}

func routeSnapshotCount(t *testing.T, dbPath string) int {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM settlement_route_snapshots`).Scan(&count); err != nil {
		t.Fatalf("count snapshots: %v", err)
	}
	return count
}

func expectedRouteSnapshotPromptHash(t *testing.T, model string) string {
	t.Helper()
	digest, _, err := billing.CanonicalSHA256Hex(map[string]any{
		"model": model,
		"messages": []any{map[string]any{
			"role":         "user",
			"content":      "hi",
			"name":         nil,
			"tool_call_id": nil,
			"tool_calls":   nil,
		}},
		"tools":             nil,
		"temperature":       json.Number("0.000001"),
		"top_p":             json.Number("0.5"),
		"max_tokens":        nil,
		"stop":              nil,
		"seed":              nil,
		"response_format":   nil,
		"tool_choice":       nil,
		"presence_penalty":  json.Number("-0.25"),
		"frequency_penalty": json.Number("0.125"),
		"logit_bias":        nil,
		"logprobs":          nil,
		"top_logprobs":      nil,
		"n":                 nil,
	})
	if err != nil {
		t.Fatalf("expected prompt hash: %v", err)
	}
	return digest
}

func syntheticV04ReceiptHeader(t *testing.T, terminalTS int64) string {
	t.Helper()
	raw, err := json.Marshal(map[string]any{
		"receipt_version":               "4",
		"terminal_state_ts_unix_ms":     terminalTS,
		"terminal_state":                billing.TerminalStateNormalDone,
		"output_prefix_start_byte":      0,
		"output_prefix_end_byte":        2,
		"route_snapshot_policy_version": billing.RouteSnapshotPolicyVersion,
	})
	if err != nil {
		t.Fatalf("marshal synthetic receipt tuple: %v", err)
	}
	return base64.StdEncoding.EncodeToString(raw) + "." + base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x99}, 64))
}

func registerSettlementProvider(registry *pool.Registry, providerID, assignedID, endpointURL string, throughput float64, receiptPubkey []byte) {
	now := time.Now().UTC()
	registry.Register(&pool.Provider{
		ProviderID:            providerID,
		AssignedID:            assignedID,
		Hostname:              providerID + ".local",
		ModelID:               "model-a",
		ModelParamsB:          7,
		RAMGB:                 16,
		MaxContextTokens:      20000,
		MaxConcurrency:        1,
		SlotsFree:             1,
		SlotsTotal:            1,
		ThroughputTPSEstimate: throughput,
		EndpointURL:           endpointURL,
		Tier:                  pool.TierPinned,
		InferencePath:         pool.InferencePathHTTPForwarding,
		State:                 pool.StateReady,
		LastHeartbeatAt:       now,
		ConnectedAt:           now,
		BinaryVersion:         "0.1.0",
		ModelHash:             buyerTestHash,
		ModelHashAlgorithm:    modelidentity.SnapshotManifestV1,
		ExpectedModelHash:     buyerTestHash,
		HashStatus:            pool.HashStatusVerified,
		ReceiptPubkey:         append([]byte(nil), receiptPubkey...),
	}, nil)
	slotsFree := 1
	registry.ApplyStateUpdate(providerID, assignedID, pool.StateUpdate{State: pool.StateReady, SlotsFree: &slotsFree, At: now})
}

func registerSettlementWSProvider(registry *pool.Registry, providerID, assignedID string, throughput float64, receiptPubkey []byte) {
	now := time.Now().UTC()
	registry.Register(&pool.Provider{
		ProviderID:            providerID,
		AssignedID:            assignedID,
		Hostname:              providerID + ".local",
		ModelID:               "model-a",
		ModelParamsB:          7,
		RAMGB:                 16,
		MaxContextTokens:      20000,
		MaxConcurrency:        1,
		SlotsFree:             1,
		SlotsTotal:            1,
		ThroughputTPSEstimate: throughput,
		EndpointURL:           "ws://provider.local",
		Tier:                  pool.TierPinned,
		InferencePath:         pool.InferencePathWSTunneled,
		State:                 pool.StateReady,
		LastHeartbeatAt:       now,
		ConnectedAt:           now,
		BinaryVersion:         "0.1.0",
		ModelHash:             buyerTestHash,
		ModelHashAlgorithm:    modelidentity.SnapshotManifestV1,
		ExpectedModelHash:     buyerTestHash,
		HashStatus:            pool.HashStatusVerified,
		ReceiptPubkey:         append([]byte(nil), receiptPubkey...),
	}, nil)
	slotsFree := 1
	registry.ApplyStateUpdate(providerID, assignedID, pool.StateUpdate{State: pool.StateReady, SlotsFree: &slotsFree, At: now})
}

func writeProviderOK(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"id":      "cmpl-test",
		"object":  "chat.completion",
		"choices": []map[string]any{{"message": map[string]any{"role": "assistant", "content": "ok"}}},
		"usage":   map[string]int{"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
	})
}

func writeProviderError(w http.ResponseWriter, status int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]any{"message": "fail"}})
}

func routeSnapshotCatalogFixture(t *testing.T, catalogID string, expiresAt time.Time) ([]byte, string) {
	t.Helper()
	seed := bytes.Repeat([]byte{7}, ed25519.SeedSize)
	privateKey := ed25519.NewKeyFromSeed(seed)
	publicKey := privateKey.Public().(ed25519.PublicKey)
	issuedAt := time.Now().UTC().Add(-time.Hour)
	type catalogModel struct {
		ArtifactKind string `json:"artifact_kind"`
		HashScope    string `json:"hash_scope"`
		ModelID      string `json:"model_id"`
		SHA256       string `json:"sha256"`
		Source       string `json:"source"`
	}
	type canonicalBody struct {
		CatalogID string         `json:"catalog_id"`
		ExpiresAt string         `json:"expires_at"`
		IssuedAt  string         `json:"issued_at"`
		Models    []catalogModel `json:"models"`
		Version   int            `json:"version"`
	}
	body := canonicalBody{
		CatalogID: catalogID,
		ExpiresAt: expiresAt.UTC().Format(time.RFC3339),
		IssuedAt:  issuedAt.Format(time.RFC3339),
		Models: []catalogModel{{
			ArtifactKind: "mlx_weight_file",
			HashScope:    "primary_weight_file",
			ModelID:      "model-a",
			SHA256:       buyerTestHash,
			Source:       "operator-curated",
		}},
		Version: 1,
	}
	canonical, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("catalog canonical marshal: %v", err)
	}
	sig := ed25519.Sign(privateKey, canonical)
	type signature struct {
		Alg   string `json:"alg"`
		KeyID string `json:"key_id"`
		Sig   string `json:"sig"`
	}
	type catalogFile struct {
		CatalogID string         `json:"catalog_id"`
		ExpiresAt string         `json:"expires_at"`
		IssuedAt  string         `json:"issued_at"`
		Models    []catalogModel `json:"models"`
		Signature signature      `json:"signature"`
		Version   int            `json:"version"`
	}
	file := catalogFile{
		CatalogID: body.CatalogID,
		ExpiresAt: body.ExpiresAt,
		IssuedAt:  body.IssuedAt,
		Models:    body.Models,
		Signature: signature{Alg: "Ed25519", KeyID: "buyer-test-key", Sig: base64.RawURLEncoding.EncodeToString(sig)},
		Version:   body.Version,
	}
	raw, err := json.Marshal(file)
	if err != nil {
		t.Fatalf("catalog marshal: %v", err)
	}
	return raw, base64.RawURLEncoding.EncodeToString(publicKey)
}

func writeRouteSnapshotCatalog(t *testing.T, raw []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "catalog.json")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatalf("write catalog: %v", err)
	}
	return path
}
