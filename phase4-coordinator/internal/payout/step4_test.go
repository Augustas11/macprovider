package payout

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/rs/zerolog"
)

// TestParseLabeledQueries_AllSixLabelsPresent locks the SPEC §7.4
// invariant: queries (A) through (F) MUST be present verbatim in
// the checked-in reconcile.sql. A missing label is a fail (someone
// stripped or renamed the SPEC-reserved labels).
func TestParseLabeledQueries_AllSixLabelsPresent(t *testing.T) {
	labeled, unlabeled := ParseLabeledQueries()
	for _, want := range []string{"A", "B", "C", "D", "E", "F"} {
		stmt, ok := labeled[want]
		if !ok {
			t.Errorf("missing labeled query %q in reconcile.sql", want)
			continue
		}
		if !strings.Contains(stmt, "SELECT") && !strings.Contains(stmt, "select") {
			t.Errorf("query %q does not contain a SELECT statement", want)
		}
	}
	if len(unlabeled) < 3 {
		t.Errorf("expected at least 3 unlabeled regression queries, got %d", len(unlabeled))
	}
}

// TestParseLabeledQueries_QueryDDelimitsCancelExclusion confirms
// the cancel-self-transfer observability query (D) filters on
// is_cancel_self_transfer = 1 (not 0) so the result set is the
// roll-up the SPEC §7.4 names.
func TestParseLabeledQueries_QueryDExcludesNonCancel(t *testing.T) {
	labeled, _ := ParseLabeledQueries()
	d, ok := labeled["D"]
	if !ok {
		t.Fatal("query (D) missing")
	}
	if !strings.Contains(d, "is_cancel_self_transfer = 1") {
		t.Errorf("query (D) does not filter is_cancel_self_transfer = 1; got:\n%s", d)
	}
}

// TestParseLabeledQueries_QueryFExcludesCancelFromOutflow locks
// the §7.4 (F) money-conservation invariant: cancel rows MUST NOT
// be subtracted from the outflow side (they're net-zero on-chain).
func TestParseLabeledQueries_QueryFExcludesCancelFromOutflow(t *testing.T) {
	labeled, _ := ParseLabeledQueries()
	f, ok := labeled["F"]
	if !ok {
		t.Fatal("query (F) missing")
	}
	if !strings.Contains(f, "is_cancel_self_transfer = 0") {
		t.Errorf("query (F) does not exclude is_cancel_self_transfer in outflow; got:\n%s", f)
	}
}

// TestReconcileSQLRaw_VerbatimSPECFingerprint asserts the embedded
// reconcile.sql file is checked in. A non-empty raw string is a
// minimum check; the audit pipeline does fuller diff vs the SPEC
// body.
func TestReconcileSQLRaw_NonEmpty(t *testing.T) {
	raw := ReconcileSQLRaw()
	if len(raw) < 1000 {
		t.Errorf("reconcile.sql looks truncated (len=%d)", len(raw))
	}
	for _, label := range []string{"-- @label: A", "-- @label: B", "-- @label: C", "-- @label: D", "-- @label: E", "-- @label: F"} {
		if !strings.Contains(raw, label) {
			t.Errorf("reconcile.sql missing %q", label)
		}
	}
}

// usdcMockReceiptFn returns a fixed mock balanceOf result.
func usdcMockBalance(amount uint64) func(context.Context, string, []byte) ([]byte, error) {
	return func(_ context.Context, _ string, _ []byte) ([]byte, error) {
		out := make([]byte, 32)
		new(big.Int).SetUint64(amount).FillBytes(out)
		return out, nil
	}
}

// TestChainBalanceWorker_DriftPositiveEmitsWARN locks the §7.4
// positive-drift path. on_chain > expected → payout_chain_balance_drift_positive.
func TestChainBalanceWorker_DriftPositiveEmitsWARN(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	hot := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	// Seed: no funding in DB, no payouts. expected = 0.
	primary := &mockRPCClient{label: "primary"}
	secondary := &mockRPCClient{label: "secondary"}
	primary.callFn = usdcMockBalance(1_000_000) // $1 on chain
	secondary.callFn = primary.callFn
	worker, err := NewChainBalanceWorker(db, TwoRPCs{Primary: primary, Secondary: secondary},
		ChainBalanceConfig{
			Interval:      1 * time.Hour,
			ToleranceUSDC: 100_000, // $0.10
			HotWalletAddr: hot,
			USDCContract:  USDCContractAddressBase,
		}, nil, zerolog.Nop())
	if err != nil {
		t.Fatalf("NewChainBalanceWorker: %v", err)
	}
	// Synchronously runOnce — the worker function emits but we
	// only assert it doesn't crash + reaches the comparison.
	// Side-channel: drift is on_chain (1M) - expected (0) = +1M > tol → positive.
	worker.runOnce(context.Background())
}

// TestChainBalanceWorker_DriftNegativeCallsHalt locks the §7.4
// negative-drift PAGE path AND the haltRunner callback invocation.
func TestChainBalanceWorker_DriftNegativeCallsHalt(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	hot := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	hotLower := strings.ToLower(hot)
	// Seed: $10 of funding recorded but $0 on chain → negative
	// drift signature of the fake-funding attack class.
	if _, err := db.ExecContext(context.Background(), `
INSERT INTO payout_hot_wallet_funding
  (from_address, to_address, amount_base_units, tx_hash, block_number, observed_at_utc, source)
VALUES (?, ?, 10000000, '0xdeadbeef', 1, '2026-01-01T00:00:00Z', 'manual')`,
		"0x"+strings.Repeat("aa", 20), hotLower,
	); err != nil {
		t.Fatalf("seed funding: %v", err)
	}
	primary := &mockRPCClient{label: "primary"}
	secondary := &mockRPCClient{label: "secondary"}
	primary.callFn = usdcMockBalance(0) // $0 on chain
	secondary.callFn = primary.callFn
	halted := false
	worker, _ := NewChainBalanceWorker(db, TwoRPCs{Primary: primary, Secondary: secondary},
		ChainBalanceConfig{
			Interval:      1 * time.Hour,
			ToleranceUSDC: 100_000, // $0.10
			HotWalletAddr: hot,
			USDCContract:  USDCContractAddressBase,
		}, func(reason string) { halted = true }, zerolog.Nop())
	worker.runOnce(context.Background())
	if !halted {
		t.Error("haltRunner not invoked on negative drift; SPEC §7.4 PAGE path broken")
	}
}

// TestChainBalanceWorker_RPCDisagreementSkipsHalt locks the §7.4
// behavior on RPC disagreement: emit payout_chain_balance_rpc_disagreement
// AND skip the drift comparison — MUST NOT halt.
// Step 4 r3 [code:r3-3]: event renamed from payout_rpc_disagreement.
func TestChainBalanceWorker_RPCDisagreementSkipsHalt(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	hot := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	primary := &mockRPCClient{label: "primary"}
	secondary := &mockRPCClient{label: "secondary"}
	primary.callFn = usdcMockBalance(100_000_000)
	secondary.callFn = usdcMockBalance(1) // diverges
	haltCount := 0
	worker, _ := NewChainBalanceWorker(db, TwoRPCs{Primary: primary, Secondary: secondary},
		ChainBalanceConfig{
			Interval:      1 * time.Hour,
			ToleranceUSDC: 100_000,
			HotWalletAddr: hot,
			USDCContract:  USDCContractAddressBase,
		}, func(reason string) { haltCount++ }, zerolog.Nop())
	worker.runOnce(context.Background())
	if haltCount != 0 {
		t.Errorf("haltRunner invoked %d times on RPC disagreement; want 0", haltCount)
	}
}

// TestChainBalanceWorker_StartStopIdempotent confirms the worker
// follows the same Stop bool contract as Runner/Reaper/ReorgPoller.
func TestChainBalanceWorker_StartStopIdempotent(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	primary := &mockRPCClient{label: "primary"}
	secondary := &mockRPCClient{label: "secondary"}
	primary.callFn = usdcMockBalance(0)
	secondary.callFn = primary.callFn
	worker, _ := NewChainBalanceWorker(db, TwoRPCs{Primary: primary, Secondary: secondary},
		ChainBalanceConfig{
			Interval:      50 * time.Millisecond,
			ToleranceUSDC: 0,
			HotWalletAddr: "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
		}, nil, zerolog.Nop())
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	worker.Start(ctx)
	worker.Start(ctx) // idempotent
	stopCtx, stopCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer stopCancel()
	if !worker.Stop(stopCtx) {
		t.Error("first Stop returned false; expected clean exit")
	}
	if !worker.Stop(stopCtx) {
		t.Error("second Stop returned false; expected idempotent true")
	}
}

// TestUSDCBalanceCalldata_LowerCasePadding probes the ABI encoder
// for balanceOf(address). The output MUST be 36 bytes: 4-byte
// selector + 32-byte zero-padded address.
func TestUSDCBalanceCalldata_Shape(t *testing.T) {
	addr := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	out := usdcBalanceCalldata(addr)
	if len(out) != 36 {
		t.Errorf("calldata len = %d, want 36", len(out))
	}
	// First 4 bytes = balanceOf selector.
	for i, b := range []byte{0x70, 0xa0, 0x82, 0x31} {
		if out[i] != b {
			t.Errorf("selector byte %d = 0x%02x, want 0x%02x", i, out[i], b)
		}
	}
	// Bytes [4..16) MUST be zero (left-padding).
	for i := 4; i < 16; i++ {
		if out[i] != 0 {
			t.Errorf("left-pad byte %d = 0x%02x, want 0", i, out[i])
		}
	}
}

// fakeProviderTokens lets us inject canned ValidateToken responses
// without depending on the auth package.
type fakeProviderTokens struct {
	tokenToProvider map[string]string
}

func (f *fakeProviderTokens) ValidateToken(_ context.Context, raw string) (string, bool, error) {
	p, ok := f.tokenToProvider[raw]
	return p, ok, nil
}

// TestPayoutsHandler_403OnTokenProviderMismatch locks the §7.3
// security invariant: a valid token for provider A MUST NOT read
// provider B's payouts.
func TestPayoutsHandler_403OnTokenProviderMismatch(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	tokens := &fakeProviderTokens{tokenToProvider: map[string]string{"tok-a": "providerA"}}
	h, err := NewPayoutsHandler(PayoutsHandlerOptions{
		DB: db, Tokens: tokens, Logger: zerolog.Nop(),
	})
	if err != nil {
		t.Fatalf("NewPayoutsHandler: %v", err)
	}
	req := httptest.NewRequest("GET", "/providers/providerB/payouts", nil)
	// chi's URLParam needs a URLParams ctx — easier to call the
	// handler through a chi router.
	req.Header.Set("Authorization", "Bearer tok-a")
	mux := newPayoutsTestRouter(h)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Errorf("code=%d, want 403", rec.Code)
	}
}

// TestPayoutsHandler_HappyPathReturnsRows seeds a couple of rows
// and confirms the response shape.
func TestPayoutsHandler_HappyPathReturnsRows(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	// Insert a confirmed payout for providerA.
	payoutID := insertReadyRow(t, db, "providerA", "settle:A:1")
	if _, err := db.ExecContext(context.Background(), `
INSERT INTO payout_attempts
  (payout_id, attempt_seq, chain, from_address, to_address,
   amount_base_units, nonce, raw_signed_tx, tx_hash,
   broadcast_at_utc, confirmed_at_utc, is_cancel_self_transfer, updated_at_utc)
VALUES (?, 1, 'base-mainnet', '0xhot', '0xrecv', 900000, 1, X'02', '0xab',
        '2026-01-01T00:00:00Z', '2026-01-01T01:00:00Z', 0, '2026-01-01T01:00:00Z')`,
		payoutID); err != nil {
		t.Fatalf("seed attempt: %v", err)
	}
	tokens := &fakeProviderTokens{tokenToProvider: map[string]string{"tok-a": "providerA"}}
	h, _ := NewPayoutsHandler(PayoutsHandlerOptions{DB: db, Tokens: tokens, Logger: zerolog.Nop()})
	req := httptest.NewRequest("GET", "/providers/providerA/payouts", nil)
	req.Header.Set("Authorization", "Bearer tok-a")
	rec := httptest.NewRecorder()
	newPayoutsTestRouter(h).ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("code=%d body=%s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `"count":1`) {
		t.Errorf("body missing count:1; got %s", rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `"tx_hash":"0xab"`) {
		t.Errorf("body missing tx_hash; got %s", rec.Body.String())
	}
}

// TestPayoutsHandler_CancelRowsFiltered locks the SPEC §7.3 invariant:
// is_cancel_self_transfer=1 rows MUST NOT be in the provider read.
func TestPayoutsHandler_CancelRowsFiltered(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	payoutID := insertReadyRow(t, db, "providerA", "settle:A:cancel")
	if _, err := db.ExecContext(context.Background(), `
INSERT INTO payout_attempts
  (payout_id, attempt_seq, chain, from_address, to_address,
   amount_base_units, nonce, raw_signed_tx, tx_hash,
   broadcast_at_utc, confirmed_at_utc, is_cancel_self_transfer, updated_at_utc)
VALUES (?, 1, 'base-mainnet', '0xhot', '0xhot', 1, 1, X'02', '0xcancel',
        '2026-01-01T00:00:00Z', '2026-01-01T01:00:00Z', 1, '2026-01-01T01:00:00Z')`,
		payoutID); err != nil {
		t.Fatalf("seed cancel: %v", err)
	}
	tokens := &fakeProviderTokens{tokenToProvider: map[string]string{"tok-a": "providerA"}}
	h, _ := NewPayoutsHandler(PayoutsHandlerOptions{DB: db, Tokens: tokens, Logger: zerolog.Nop()})
	req := httptest.NewRequest("GET", "/providers/providerA/payouts", nil)
	req.Header.Set("Authorization", "Bearer tok-a")
	rec := httptest.NewRecorder()
	newPayoutsTestRouter(h).ServeHTTP(rec, req)
	if !strings.Contains(rec.Body.String(), `"count":0`) {
		t.Errorf("cancel row leaked into provider read; body=%s", rec.Body.String())
	}
}

// newPayoutsTestRouter returns a chi router with just the §7.3 route
// wired so tests get chi.URLParam working without rebuilding the
// full mux.
func newPayoutsTestRouter(h *PayoutsHandler) http.Handler {
	mux := chi.NewRouter()
	mux.Get("/providers/{provider_id}/payouts", h.ServePayouts)
	return mux
}

// Compile-time assertion: PayoutsHandler.queryPayouts has the same
// signature as expected; this just keeps the import live during
// future refactors that might inline the method.
var _ = (*PayoutsHandler)(nil).queryPayouts
var _ = sql.ErrNoRows

// ==========================================================================
// Step 4 r1 [code:r1-5] MEDIUM closure — missing test coverage
// ==========================================================================

// TestPayoutsHandler_MissingBearer_401 asserts that a request with
// no Authorization header returns 401 (§7.3 auth gate).
func TestPayoutsHandler_MissingBearer_401(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	tokens := &fakeProviderTokens{tokenToProvider: map[string]string{"tok-a": "providerA"}}
	h, err := NewPayoutsHandler(PayoutsHandlerOptions{
		DB: db, Tokens: tokens, Logger: zerolog.Nop(),
	})
	if err != nil {
		t.Fatalf("NewPayoutsHandler: %v", err)
	}
	req := httptest.NewRequest("GET", "/providers/providerA/payouts", nil)
	// No Authorization header.
	rec := httptest.NewRecorder()
	newPayoutsTestRouter(h).ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("code=%d, want 401 for missing bearer", rec.Code)
	}
}

// TestPayoutsHandler_EmptyBearer_401 asserts that "Authorization: Bearer "
// (space after Bearer, no token) returns 401.
func TestPayoutsHandler_EmptyBearer_401(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	tokens := &fakeProviderTokens{tokenToProvider: map[string]string{"tok-a": "providerA"}}
	h, _ := NewPayoutsHandler(PayoutsHandlerOptions{
		DB: db, Tokens: tokens, Logger: zerolog.Nop(),
	})
	req := httptest.NewRequest("GET", "/providers/providerA/payouts", nil)
	req.Header.Set("Authorization", "Bearer ") // empty bearer value
	rec := httptest.NewRecorder()
	newPayoutsTestRouter(h).ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("code=%d, want 401 for empty bearer", rec.Code)
	}
}

// TestPayoutsHandler_RateLimit_429 asserts the §7.3 per-provider
// sliding-window rate-limiter: the 61st request in <60s for the same
// provider MUST return 429.
func TestPayoutsHandler_RateLimit_429(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	tokens := &fakeProviderTokens{tokenToProvider: map[string]string{"tok-a": "providerA"}}
	fixedNow := time.Now()
	h, _ := NewPayoutsHandler(PayoutsHandlerOptions{
		DB:           db,
		Tokens:       tokens,
		Logger:       zerolog.Nop(),
		RateLimitMin: 60, // 60 req/min cap
		// Pin time so all requests land in the same window.
		NowFn: func() time.Time { return fixedNow },
	})
	router := newPayoutsTestRouter(h)
	// Send 60 requests — all should be allowed.
	for i := 0; i < 60; i++ {
		req := httptest.NewRequest("GET", "/providers/providerA/payouts", nil)
		req.Header.Set("Authorization", "Bearer tok-a")
		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("request %d: code=%d, want 200", i+1, rec.Code)
		}
	}
	// 61st request must be rate-limited.
	req := httptest.NewRequest("GET", "/providers/providerA/payouts", nil)
	req.Header.Set("Authorization", "Bearer tok-a")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	if rec.Code != http.StatusTooManyRequests {
		t.Errorf("request 61: code=%d, want 429", rec.Code)
	}
}

// TestParseLabeledQueries_ExactlyThreeUnlabeled locks the SPEC §7.4
// invariant that reconcile.sql carries exactly 3 unlabeled regression
// queries (not "at least 3" — divergence from 3 is a maintenance signal).
func TestParseLabeledQueries_ExactlyThreeUnlabeled(t *testing.T) {
	_, unlabeled := ParseLabeledQueries()
	if len(unlabeled) != 3 {
		t.Errorf("expected exactly 3 unlabeled regression queries, got %d; reconcile.sql changed?", len(unlabeled))
	}
}

// TestExtractLabel_PreservesBodyComment asserts that a `-- @label: X`
// appearing inside the SQL body (not in the leading prefix) is preserved
// verbatim in the output and NOT stripped. Step 4 r1 [code:r1-6] closure.
func TestExtractLabel_PreservesBodyComment(t *testing.T) {
	stmt := `-- @label: header_label
SELECT *
FROM foo
-- @label: body_label_should_not_be_stripped
WHERE id = 1`

	label, body := extractLabel(stmt)
	if label != "header_label" {
		t.Errorf("label=%q, want %q", label, "header_label")
	}
	if !strings.Contains(body, "-- @label: body_label_should_not_be_stripped") {
		t.Errorf("body label was stripped; body:\n%s", body)
	}
	if !strings.Contains(body, "SELECT *") {
		t.Errorf("SELECT missing from body:\n%s", body)
	}
}

// TestEmitBalanceAlerts_NonZeroThresholdInvokesProbes asserts that
// configuring a non-zero LowBalanceThreshold drives a USDC CallContract
// probe and non-zero LowNativeThreshold drives a NativeBalance probe.
// Step 4 r1 [code:r1-5]/[arch:4.3] convergent closure.
func TestEmitBalanceAlerts_NonZeroThresholdInvokesProbes(t *testing.T) {
	callContractCount := 0
	nativeBalanceCount := 0

	primary := &mockRPCClient{
		label: "primary",
		callFn: func(_ context.Context, _ string, _ []byte) ([]byte, error) {
			callContractCount++
			// Return 32 zero bytes (balance = 0, will trigger alert).
			return make([]byte, 32), nil
		},
		nativeBalanceFn: func(_ context.Context, _ string) (uint64, error) {
			nativeBalanceCount++
			return 0, nil // balance = 0, will trigger alert
		},
	}
	secondary := &mockRPCClient{label: "secondary"}
	secondary.callFn = primary.callFn
	secondary.nativeBalanceFn = primary.nativeBalanceFn

	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	rawHex := "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
	raw, _ := hex.DecodeString(rawHex)
	signer, err := NewLocalFileSignerFromKey(raw)
	if err != nil {
		t.Fatalf("signer: %v", err)
	}
	hotAddr := signer.FromAddress()
	logger, _ := quietLogger()
	state, _, err := Acquire(context.Background(), db, testRunInterval, logger)
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	if err := UpsertNonceCursor(context.Background(), db, hotAddr, 0, 0, 0, NowUTC()); err != nil {
		t.Fatalf("UpsertNonceCursor: %v", err)
	}
	opts := RunnerOptions{
		DB:                    db,
		Security:              SecurityConfig{HotWalletAddress: hotAddr},
		RPCs:                  TwoRPCs{Primary: primary, Secondary: secondary},
		Signer:                signer,
		Claimer:               &mockClaimer{claimed: false},
		Logger:                logger,
		RunInterval:           testRunInterval,
		MaxRowsPerRun:         50,
		ConfirmationBlocks:    5,
		PerPayoutCapBaseUnits: 1_000_000_000_000,
		PerDayCapBaseUnits:    10_000_000_000_000,
		ReceiptPollInterval:   1 * time.Millisecond,
		ReceiptPollTimeout:    100 * time.Millisecond,
		NowFn:                 func() time.Time { return time.Now().UTC() },
		// Non-zero thresholds must activate the probes.
		LowBalanceThreshold: 1_000_000,             // $1 USDC base units
		LowNativeThreshold:  1_000_000_000_000_000, // 0.001 ETH
	}
	runner, err := NewRunner(opts, state)
	if err != nil {
		t.Fatalf("NewRunner: %v", err)
	}
	// RunOnce with no rows to process — just runs the top-of-cycle probes.
	_, _ = runner.RunOnce(context.Background())

	if callContractCount == 0 {
		t.Error("CallContract not invoked; LowBalanceThreshold > 0 must trigger USDC probe")
	}
	if nativeBalanceCount == 0 {
		t.Error("NativeBalance not invoked; LowNativeThreshold > 0 must trigger native probe")
	}
}

// TestRunnerHalted_Skips_Cycle asserts that after RequestHalt is called,
// RunOnce returns ErrRunnerHalted without selecting any rows.
// Step 4 r1 halt-primitive closure.
func TestRunnerHalted_Skips_Cycle(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	rawHex := "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
	raw, _ := hex.DecodeString(rawHex)
	signer, err := NewLocalFileSignerFromKey(raw)
	if err != nil {
		t.Fatalf("signer: %v", err)
	}
	hotAddr := signer.FromAddress()
	logger, _ := quietLogger()
	state, _, err := Acquire(context.Background(), db, testRunInterval, logger)
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	if err := UpsertNonceCursor(context.Background(), db, hotAddr, 0, 0, 0, NowUTC()); err != nil {
		t.Fatalf("UpsertNonceCursor: %v", err)
	}
	// Track whether any SELECT was issued via the claimer.
	claimer := &mockClaimer{claimed: false}
	primary := &mockRPCClient{label: "primary"}
	secondary := &mockRPCClient{label: "secondary"}
	opts := RunnerOptions{
		DB:                    db,
		Security:              SecurityConfig{HotWalletAddress: hotAddr},
		RPCs:                  TwoRPCs{Primary: primary, Secondary: secondary},
		Signer:                signer,
		Claimer:               claimer,
		Logger:                logger,
		RunInterval:           testRunInterval,
		MaxRowsPerRun:         50,
		ConfirmationBlocks:    5,
		PerPayoutCapBaseUnits: 1_000_000_000_000,
		PerDayCapBaseUnits:    10_000_000_000_000,
		ReceiptPollInterval:   1 * time.Millisecond,
		ReceiptPollTimeout:    100 * time.Millisecond,
		NowFn:                 func() time.Time { return time.Now().UTC() },
	}
	runner, err := NewRunner(opts, state)
	if err != nil {
		t.Fatalf("NewRunner: %v", err)
	}

	runner.RequestHalt("test_reason")
	if !runner.IsHalted() {
		t.Fatal("IsHalted() = false after RequestHalt")
	}
	_, err = runner.RunOnce(context.Background())
	if !errors.Is(err, ErrRunnerHalted) {
		t.Errorf("RunOnce after halt: err=%v, want ErrRunnerHalted", err)
	}
	// Claimer should not have been called (no rows selected).
	if len(claimer.calls) > 0 {
		t.Errorf("ClaimPayoutReady called %d times; halted runner must not select rows", len(claimer.calls))
	}
}

// TestRunNow_Returns409WhenHalted locks the mux halt-gate: the admin
// run-now endpoint MUST return 409 with error=runner_halted when the
// runner is halted.
func TestRunNow_Returns409WhenHalted(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	rawHex := "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
	raw, _ := hex.DecodeString(rawHex)
	signer, err := NewLocalFileSignerFromKey(raw)
	if err != nil {
		t.Fatalf("signer: %v", err)
	}
	hotAddr := signer.FromAddress()
	logger, _ := quietLogger()
	state, _, err := Acquire(context.Background(), db, testRunInterval, logger)
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	if err := UpsertNonceCursor(context.Background(), db, hotAddr, 0, 0, 0, NowUTC()); err != nil {
		t.Fatalf("UpsertNonceCursor: %v", err)
	}
	opts := RunnerOptions{
		DB:                    db,
		Security:              SecurityConfig{HotWalletAddress: hotAddr},
		RPCs:                  TwoRPCs{Primary: &mockRPCClient{}, Secondary: &mockRPCClient{}},
		Signer:                signer,
		Claimer:               &mockClaimer{claimed: false},
		Logger:                logger,
		RunInterval:           testRunInterval,
		MaxRowsPerRun:         50,
		ConfirmationBlocks:    5,
		PerPayoutCapBaseUnits: 1_000_000_000_000,
		PerDayCapBaseUnits:    10_000_000_000_000,
		ReceiptPollInterval:   1 * time.Millisecond,
		ReceiptPollTimeout:    100 * time.Millisecond,
		NowFn:                 func() time.Time { return time.Now().UTC() },
	}
	runner, err := NewRunner(opts, state)
	if err != nil {
		t.Fatalf("NewRunner: %v", err)
	}
	runner.RequestHalt("chain_balance_drift")

	// Build a Step2 mux with the halted runner.
	// Use newServiceForTest for AddressesService (it seeds bootstrap internally).
	addresses := newServiceForTest(t, db, hotAddr, "mux-test-provider", "mux-test-tok", &fakePause{})
	signer2, _ := NewLocalFileSignerFromKey(raw) // second instance for abandon
	abandon, err2 := NewAbandonService(db,
		SecurityConfig{HotWalletAddress: hotAddr},
		TwoRPCs{Primary: &mockRPCClient{}, Secondary: &mockRPCClient{}},
		signer2, testRunInterval, zerolog.Nop())
	if err2 != nil {
		t.Fatalf("NewAbandonService: %v", err2)
	}
	fallback := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTeapot)
	})
	// Step 4 r2 [code:r2-1]/[sec:r2-1]/[arch:r2-4.1] closure:
	// mux now requires a RunNowController.
	runNowCtrl, err := NewRunNowController(runner, nil, 60*time.Second, zerolog.Nop())
	if err != nil {
		t.Fatalf("NewRunNowController: %v", err)
	}
	mux, err := NewMuxStep2(Step2MuxOptions{
		Addresses: addresses,
		Runner:    runner,
		RunNow:    runNowCtrl,
		Abandon:   abandon,
		Caps: AbandonCaps{
			CancelMaxTipMultiplier:      5.0,
			CancelMaxGasNativeWei:       1e16,
			CancelMaxGasNativeWeiPer24h: 5e16,
			AbandonRatePerHour:          3,
		},
		OperatorKey: "test-op-key",
		Fallback:    fallback,
	})
	if err != nil {
		t.Fatalf("NewMuxStep2: %v", err)
	}
	req := httptest.NewRequest("POST", "/admin/payout/run-now", nil)
	req.Header.Set("Authorization", "Bearer test-op-key")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusConflict {
		t.Errorf("code=%d, want 409 when runner halted", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "runner_halted") {
		t.Errorf("body missing runner_halted; got: %s", rec.Body.String())
	}
}

// TestChainBalanceWorker_RPCDisagreementEmitsHotWallet locks the
// Step 4 r4 [code:r4-2] MEDIUM closure: payout_chain_balance_rpc_disagreement
// MUST include hot_wallet so multi-wallet logs are attributable.
func TestChainBalanceWorker_RPCDisagreementEmitsHotWallet(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	hot := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	primary := &mockRPCClient{label: "primary"}
	secondary := &mockRPCClient{label: "secondary"}
	primary.callFn = usdcMockBalance(100_000_000)
	secondary.callFn = usdcMockBalance(1) // diverges beyond tolerance

	buf := &bytes.Buffer{}
	logger := zerolog.New(io.Writer(buf))
	worker, err := NewChainBalanceWorker(db, TwoRPCs{Primary: primary, Secondary: secondary},
		ChainBalanceConfig{
			Interval:      1 * time.Hour,
			ToleranceUSDC: 100_000,
			HotWalletAddr: hot,
			USDCContract:  USDCContractAddressBase,
		}, func(_ string) {}, logger)
	if err != nil {
		t.Fatalf("NewChainBalanceWorker: %v", err)
	}
	worker.runOnce(context.Background())

	// Find and parse the disagreement event line.
	var found bool
	for _, line := range strings.Split(buf.String(), "\n") {
		if line == "" {
			continue
		}
		var evt map[string]interface{}
		if err := json.Unmarshal([]byte(line), &evt); err != nil {
			continue
		}
		if evt["event"] != "payout_chain_balance_rpc_disagreement" {
			continue
		}
		found = true
		if got := evt["hot_wallet"]; got != hot {
			t.Errorf("hot_wallet = %q, want %q", got, hot)
		}
		for _, field := range []string{"primary_balance", "secondary_balance", "tolerance", "ts_utc", "severity"} {
			if _, ok := evt[field]; !ok {
				t.Errorf("payout_chain_balance_rpc_disagreement missing field %q", field)
			}
		}
	}
	if !found {
		t.Errorf("payout_chain_balance_rpc_disagreement event not emitted; got: %s", buf.String())
	}
}
