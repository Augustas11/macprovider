package buyer

// Seam-hardening e2e harness — coordinator-side scenario H4
// (single-terminal-wins / paid-while-buyer-told-failed, INV-6). Companion to
// the H3 scenarios in seam_h3_test.go and the risk register in
// audits/seam-hardening/.
//
// These replace the documented H4 skip. The skip's premise ("a cross-path race
// observable only end-to-end") was WRONG in one important way and right in
// another: there is no goroutine race — recordRow and every buyer write run on
// the request goroutine — but there was no arbiter publishing the buyer
// terminal, so nothing could assert that the ledger and the buyer's HTTP
// status agreed. #766 adds that arbiter (terminal_arbiter.go, observe-only),
// which makes the property deterministically testable.
//
// Run: go test ./internal/buyer/ -run TestSeamH4 -count=1 -v

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// ---------------------------------------------------------------------------
// Local harness. Deliberately package-internal: the shared helpers in
// server_test.go live in the external buyer_test package and cannot reach the
// arbiter, which is request-scoped and unexported.
// ---------------------------------------------------------------------------

func h4OpenRequestLog(t *testing.T) (*requestlog.Store, string) {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	store, err := requestlog.OpenStore(dbPath)
	if err != nil {
		t.Fatalf("open request log: %v", err)
	}
	if _, err := store.DB().Exec(`
CREATE TABLE IF NOT EXISTS audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_utc TEXT NOT NULL,
    event_type TEXT NOT NULL,
    provider_id TEXT,
    payload_json TEXT NOT NULL
);`); err != nil {
		t.Fatalf("create audit_log: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	return store, dbPath
}

func h4RegisterWSProvider(reg *pool.Registry, providerID, assignedID, modelID string) {
	reg.Register(&pool.Provider{
		ProviderID:            providerID,
		AssignedID:            assignedID,
		Hostname:              providerID + ".local",
		ModelID:               modelID,
		ModelParamsB:          7,
		RAMGB:                 16,
		MaxContextTokens:      20000,
		MaxConcurrency:        1,
		SlotsFree:             1,
		SlotsTotal:            1,
		ThroughputTPSEstimate: 30,
		Tier:                  pool.TierProvisional,
		InferencePath:         pool.InferencePathWSTunneled,
		State:                 pool.StateReady,
		LastHeartbeatAt:       time.Now().UTC(),
		ConnectedAt:           time.Now().UTC(),
		BinaryVersion:         "0.1.0",
	}, nil)
}

func h4PostChat(t *testing.T, s *Server, body []byte) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	rr := httptest.NewRecorder()
	s.Handler().ServeHTTP(rr, req)
	_, _ = io.Copy(io.Discard, rr.Result().Body)
	return rr
}

func h4RequestLogStatuses(t *testing.T, dbPath string) []int {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open request log db: %v", err)
	}
	defer db.Close()
	rows, err := db.Query(`SELECT status FROM request_log ORDER BY id`)
	if err != nil {
		t.Fatalf("query request_log: %v", err)
	}
	defer rows.Close()
	var out []int
	for rows.Next() {
		var status int
		if err := rows.Scan(&status); err != nil {
			t.Fatalf("scan request_log: %v", err)
		}
		out = append(out, status)
	}
	return out
}

func h4Rewards() config.RewardsConfig {
	return config.RewardsConfig{
		GlobalMultiplier: 1.0,
		ProviderShare:    0.90,
		RateCard: map[string]config.RateCardEntry{
			"model-a": {PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 2000000},
		},
	}
}

// h4Server builds a WS-tunneled single-provider coordinator with billing wired
// and installs the arbiter observation seam.
func h4Server(t *testing.T, reqLog *requestlog.Store, relay RelayFunc, observed **requestTerminal) *Server {
	t.Helper()
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	registry := pool.NewRegistry(nil)
	h4RegisterWSProvider(registry, "p1", "s1", "model-a")
	s := NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		WithRequestLog(reqLog),
		WithBilling(billingStore, h4Rewards()),
		WithRoutingConfig(config.RoutingConfig{MaxRetries: 0, StickyTTLS: 1800, StickyMaxEntries: 10000}),
		WithRelay(relay, time.Second),
	)
	s.terminalObserver = func(rt *requestTerminal) { *observed = rt }
	return s
}

func h4RelayErr(err error) RelayFunc {
	return func(_ context.Context, _ pool.Provider, reqID string, _ []byte, _ bool) (*providerws.RelayStream, error) {
		errs := make(chan error, 1)
		errs <- err
		return &providerws.RelayStream{RequestID: reqID, Errors: errs}, nil
	}
}

func h4RelaySuccess() RelayFunc {
	return func(_ context.Context, _ pool.Provider, reqID string, _ []byte, _ bool) (*providerws.RelayStream, error) {
		chunks := make(chan providerws.InferenceResponseChunk, 2)
		done := make(chan providerws.InferenceResponseEnd, 1)
		errs := make(chan error, 1)
		go func() {
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: reqID, Seq: 0, Data: `{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}`}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: reqID, Status: "complete", ChunksSent: 1}
		}()
		return &providerws.RelayStream{RequestID: reqID, Chunks: chunks, Done: done, Errors: errs}, nil
	}
}

const h4ChatBody = `{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`

// ---------------------------------------------------------------------------
// H4-1 · agreeing terminal, bill-before-write ordering.
//
// Relay yields ErrRelayTimeout with a LIVE buyer context (so the #761
// buyer-cancel guard does not fire) → wsForwardTimedOut → retry budget is
// exhausted at MaxRetries=0 → renderRetryExhausted owns the buyer 504. That
// callback logs the attempt row BEFORE writeError, so the credited row is
// observed at a LOWER sequence than the buyer claim. Both sides say 504:
// agreement, zero conflicts.
// ---------------------------------------------------------------------------
func TestSeamH4_AgreeingTimeoutTerminal(t *testing.T) {
	reqLog, dbPath := h4OpenRequestLog(t)
	var observed *requestTerminal
	s := h4Server(t, reqLog, h4RelayErr(providerws.ErrRelayTimeout), &observed)

	rr := h4PostChat(t, s, []byte(h4ChatBody))

	if rr.Code != http.StatusGatewayTimeout {
		t.Fatalf("buyer status = %d, want 504; body=%s", rr.Code, rr.Body.String())
	}
	if statuses := h4RequestLogStatuses(t, dbPath); len(statuses) != 1 || statuses[0] != http.StatusGatewayTimeout {
		t.Fatalf("request_log statuses = %v, want exactly [504]", statuses)
	}
	if observed == nil {
		t.Fatal("terminal arbiter was never evaluated")
	}
	claim, ok := observed.claimedBuyer()
	if !ok {
		t.Fatal("no buyer terminal was claimed for a request that wrote a 504")
	}
	if claim.Status != http.StatusGatewayTimeout {
		t.Fatalf("claimed buyer terminal = %d, want 504", claim.Status)
	}
	if claim.Source != terminalSourceBuyerWrite {
		t.Fatalf("claim source = %q, want %q", claim.Source, terminalSourceBuyerWrite)
	}
	if got := observed.LateBuyerWrites(); got != 0 {
		t.Fatalf("late buyer writes = %d, want 0 (single write path)", got)
	}
	rows := observed.Rows()
	if len(rows) != 1 {
		t.Fatalf("credited rows = %d, want 1: %#v", len(rows), rows)
	}
	if rows[0].Status != http.StatusGatewayTimeout {
		t.Fatalf("credited row status = %d, want 504", rows[0].Status)
	}
	// ORDERING: renderRetryExhausted logs then writes.
	if rows[0].Seq >= claim.Seq {
		t.Fatalf("expected the billing row (seq %d) to precede the buyer terminal (seq %d) on the "+
			"retry-exhausted path — renderRetryExhausted logs the attempt before writeError",
			rows[0].Seq, claim.Seq)
	}
	if rows[0].Late {
		t.Fatal("credited row marked Late on a bill-before-write path")
	}
	if got := observed.Conflicts(); got != 0 {
		t.Fatalf("conflicts = %d, want 0 — buyer 504 and a 504 row agree", got)
	}
}

// ---------------------------------------------------------------------------
// H4-2 · agreeing terminal, write-before-bill (INVERSE) ordering.
//
// The WS-non-streaming relay error that is neither Timeout, Closed, AEAD nor
// NAK-fallback writes the 502 INLINE inside forwardWSNonStreaming and only
// then returns wsForwardFailed, whose row is written afterwards by
// handleNonRetryableTerminal. The arbiter must record the inverse sequence and
// flag the row Late — and still find zero conflicts, because a 502 row under a
// 502 buyer terminal agrees. This pins that "Late" is an ordering fact, not a
// fault, which is exactly why late rows are never suppressed.
// ---------------------------------------------------------------------------
func TestSeamH4_PostTerminalBillingRowIsOrderedAndAgrees(t *testing.T) {
	reqLog, dbPath := h4OpenRequestLog(t)
	var observed *requestTerminal
	s := h4Server(t, reqLog, h4RelayErr(errors.New("relay exploded")), &observed)

	rr := h4PostChat(t, s, []byte(h4ChatBody))

	if rr.Code != http.StatusBadGateway {
		t.Fatalf("buyer status = %d, want 502; body=%s", rr.Code, rr.Body.String())
	}
	if statuses := h4RequestLogStatuses(t, dbPath); len(statuses) != 1 || statuses[0] != http.StatusBadGateway {
		t.Fatalf("request_log statuses = %v, want exactly [502]", statuses)
	}
	if observed == nil {
		t.Fatal("terminal arbiter was never evaluated")
	}
	claim, ok := observed.claimedBuyer()
	if !ok {
		t.Fatal("no buyer terminal was claimed for a request that wrote a 502")
	}
	if claim.Status != http.StatusBadGateway {
		t.Fatalf("claimed buyer terminal = %d, want 502", claim.Status)
	}
	rows := observed.Rows()
	if len(rows) != 1 {
		t.Fatalf("credited rows = %d, want 1: %#v", len(rows), rows)
	}
	if rows[0].Status != http.StatusBadGateway {
		t.Fatalf("credited row status = %d, want 502", rows[0].Status)
	}
	// INVERSE ORDERING vs H4-1: buyer terminal first, billing row after.
	if claim.Seq >= rows[0].Seq {
		t.Fatalf("expected the buyer terminal (seq %d) to precede the billing row (seq %d) on the "+
			"WS write-before-bill path", claim.Seq, rows[0].Seq)
	}
	if !rows[0].Late {
		t.Fatal("credited row not marked Late although it was recorded after the buyer terminal — " +
			"the arbiter must observe write-before-bill ordering, which is precisely why late rows " +
			"are recorded rather than suppressed (suppression would under-bill every failover retry)")
	}
	if got := observed.Conflicts(); got != 0 {
		t.Fatalf("conflicts = %d, want 0 — buyer 502 and a 502 row agree", got)
	}
}

// ---------------------------------------------------------------------------
// H4-3 · THE TRIPWIRE: provider credited while the buyer was told the request
// failed (INV-6 / I-1).
//
// Forced deterministically without touching production code: drop
// settlement_attempt_outputs after the stores are built. The WS success path
// then runs logSuccess → recordRow → WriteHotPath SUCCEEDS (the provider is
// credited, providerCredited=true, row status 200) → recordSettlementAttemptOutput
// fails on the missing table → logSuccess returns an error → forwardWSNonStreaming
// writes 500 request_log_failed to the buyer.
//
// Result: the ledger says a provider earned a 200-status credit with no
// breaker-qualifying fault flag (so neither of the two accidental zeroing
// rules applies), while the buyer was told the request failed. Pre-#766
// nothing in the coordinator could see that. If this test ever reports zero
// conflicts, the arbiter has stopped observing the money seam it exists for.
// ---------------------------------------------------------------------------
func TestSeamH4_CreditedWhileBuyerToldFailedIsAConflict(t *testing.T) {
	reqLog, dbPath := h4OpenRequestLog(t)
	var observed *requestTerminal
	s := h4Server(t, reqLog, h4RelaySuccess(), &observed)

	// After billing.NewStore has migrated the schema: remove the settlement
	// attempt-output table so the post-credit bookkeeping fails.
	if _, err := reqLog.DB().Exec(`DROP TABLE settlement_attempt_outputs`); err != nil {
		t.Fatalf("drop settlement_attempt_outputs: %v", err)
	}

	before := buyerTerminalConflictTotal.Load()
	rr := h4PostChat(t, s, []byte(h4ChatBody))

	if rr.Code != http.StatusInternalServerError {
		t.Fatalf("buyer status = %d, want 500 (request_log_failed); body=%s", rr.Code, rr.Body.String())
	}
	if statuses := h4RequestLogStatuses(t, dbPath); len(statuses) != 1 || statuses[0] != http.StatusOK {
		t.Fatalf("request_log statuses = %v, want exactly [200] (the provider WAS credited)", statuses)
	}
	if observed == nil {
		t.Fatal("terminal arbiter was never evaluated")
	}
	claim, ok := observed.claimedBuyer()
	if !ok || claim.Status != http.StatusInternalServerError {
		t.Fatalf("claimed buyer terminal = %+v (ok=%v), want status 500", claim, ok)
	}
	rows := observed.Rows()
	if len(rows) != 1 {
		t.Fatalf("credited rows = %d, want 1: %#v", len(rows), rows)
	}
	if rows[0].Status != http.StatusOK {
		t.Fatalf("credited row status = %d, want 200", rows[0].Status)
	}
	if rows[0].FaultFlag == billing.FaultBreakerQualifying {
		t.Fatalf("credited row carries %q — the formula.go zeroing rule would apply and this would "+
			"not be a money conflict; the fixture no longer exercises INV-6", rows[0].FaultFlag)
	}
	if got := observed.Conflicts(); got != 1 {
		t.Fatalf("conflicts = %d, want 1 — a provider was credited (200, no breaker fault) while the "+
			"buyer was told 500. This is INV-6 'paid while the buyer was told it failed'; the arbiter "+
			"must observe it", got)
	}
	if delta := buyerTerminalConflictTotal.Load() - before; delta != 1 {
		t.Fatalf("buyerTerminalConflictTotal delta = %d, want 1", delta)
	}
	// The billing row is NOT suppressed: consistency arbiter, not suppression
	// arbiter. Suppressing it would erase a real provider credit.
	if !observed.Rows()[0].Conflicted {
		t.Fatal("conflicting row not marked Conflicted")
	}
}

// ---------------------------------------------------------------------------
// H4-4 · arbiter unit table. Pins the predicates independently of transport.
// ---------------------------------------------------------------------------
func TestSeamH4_TerminalArbiterPredicates(t *testing.T) {
	t.Run("credited_success_row_under_5xx_buyer_terminal_conflicts", func(t *testing.T) {
		rt := newRequestTerminal(nil, "req-1", "acct-1")
		rt.noteDispatch()
		if !rt.claimBuyer(http.StatusGatewayTimeout) {
			t.Fatal("first claim must win")
		}
		rt.noteBillableRow(http.StatusOK, 0, billing.FaultNone)
		rt.evaluateEndOfRequest(true)
		if got := rt.Conflicts(); got != 1 {
			t.Fatalf("conflicts = %d, want 1", got)
		}
	})

	t.Run("breaker_qualifying_row_is_not_a_conflict", func(t *testing.T) {
		rt := newRequestTerminal(nil, "req-2", "acct-1")
		rt.noteDispatch()
		rt.claimBuyer(http.StatusGatewayTimeout)
		// A breaker-qualifying 504 row is zeroed by billing/formula.go, and a
		// >=400 status is not success-shaped either.
		rt.noteBillableRow(http.StatusGatewayTimeout, 0, billing.FaultBreakerQualifying)
		rt.evaluateEndOfRequest(true)
		if got := rt.Conflicts(); got != 0 {
			t.Fatalf("conflicts = %d, want 0", got)
		}
	})

	t.Run("breaker_qualifying_success_row_is_not_a_conflict", func(t *testing.T) {
		rt := newRequestTerminal(nil, "req-2b", "acct-1")
		rt.noteDispatch()
		rt.claimBuyer(http.StatusGatewayTimeout)
		rt.noteBillableRow(http.StatusOK, 0, billing.FaultBreakerQualifying)
		rt.evaluateEndOfRequest(true)
		if got := rt.Conflicts(); got != 0 {
			t.Fatalf("conflicts = %d, want 0 — FaultBreakerQualifying zeroes the credit", got)
		}
	})

	t.Run("served_2xx_without_credited_row_conflicts_at_end_of_request", func(t *testing.T) {
		rt := newRequestTerminal(nil, "req-3", "acct-1")
		rt.noteDispatch()
		rt.claimBuyer(http.StatusOK)
		if got := rt.Conflicts(); got != 0 {
			t.Fatalf("conflicts = %d before end-of-request, want 0 — I-2 is a whole-request predicate", got)
		}
		rt.evaluateEndOfRequest(true)
		if got := rt.Conflicts(); got != 1 {
			t.Fatalf("conflicts = %d, want 1 (dispatched, served 2xx, never credited)", got)
		}
	})

	t.Run("served_2xx_without_dispatch_is_not_a_conflict", func(t *testing.T) {
		rt := newRequestTerminal(nil, "req-4", "acct-1")
		rt.claimBuyer(http.StatusOK)
		rt.evaluateEndOfRequest(true)
		if got := rt.Conflicts(); got != 0 {
			t.Fatalf("conflicts = %d, want 0 — nothing dispatched, nobody is owed", got)
		}
	})

	t.Run("served_2xx_without_billing_wired_is_not_a_conflict", func(t *testing.T) {
		rt := newRequestTerminal(nil, "req-5", "acct-1")
		rt.noteDispatch()
		rt.claimBuyer(http.StatusOK)
		rt.evaluateEndOfRequest(false)
		if got := rt.Conflicts(); got != 0 {
			t.Fatalf("conflicts = %d, want 0 — a coordinator with no billing store credits nobody by design", got)
		}
	})

	t.Run("double_claim_retains_the_first_and_counts_the_late_write", func(t *testing.T) {
		rt := newRequestTerminal(nil, "req-6", "acct-1")
		if !rt.claimBuyer(http.StatusGatewayTimeout) {
			t.Fatal("first claim must win")
		}
		if rt.claimBuyer(http.StatusOK) {
			t.Fatal("second claim must lose — net/http already committed the first status")
		}
		claim, ok := rt.claimedBuyer()
		if !ok || claim.Status != http.StatusGatewayTimeout {
			t.Fatalf("claim = %+v (ok=%v), want the FIRST terminal (504)", claim, ok)
		}
		if got := rt.LateBuyerWrites(); got != 1 {
			t.Fatalf("late buyer writes = %d, want 1", got)
		}
	})

	t.Run("end_of_request_is_idempotent", func(t *testing.T) {
		rt := newRequestTerminal(nil, "req-7", "acct-1")
		rt.noteDispatch()
		rt.claimBuyer(http.StatusOK)
		rt.evaluateEndOfRequest(true)
		rt.evaluateEndOfRequest(true)
		if got := rt.Conflicts(); got != 1 {
			t.Fatalf("conflicts = %d, want 1 — a second evaluation must not double-count", got)
		}
	})

	t.Run("nil_arbiter_is_inert", func(t *testing.T) {
		var rt *requestTerminal
		rt.noteDispatch()
		rt.noteBillableRow(http.StatusOK, 0, billing.FaultNone)
		rt.noteLateBuyerWrite(http.StatusOK)
		rt.setRequestID("x")
		rt.evaluateEndOfRequest(true)
		if rt.claimBuyer(http.StatusOK) {
			t.Fatal("nil arbiter must not report a winning claim")
		}
		if rt.Conflicts() != 0 || rt.LateBuyerWrites() != 0 || rt.Rows() != nil {
			t.Fatal("nil arbiter accessors must be zero-valued")
		}
		if _, ok := rt.claimedBuyer(); ok {
			t.Fatal("nil arbiter must not report a claim")
		}
	})
}

// ---------------------------------------------------------------------------
// H4-5 · claim-once across every transport. The latch lives on one wrapper, so
// this is a per-transport regression net against a future path that writes its
// terminal outside noPriorDispatchResponseWriter (which would leave the claim
// unset and silently blind the arbiter).
// ---------------------------------------------------------------------------
func TestSeamH4_ClaimOncePerTransport(t *testing.T) {
	const streamBody = `{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hello"}]}`
	cases := []struct {
		name     string
		body     string
		relay    RelayFunc
		buffered bool
	}{
		{name: "ws_non_streaming_success", body: h4ChatBody, relay: h4RelaySuccess()},
		{name: "ws_non_streaming_error", body: h4ChatBody, relay: h4RelayErr(errors.New("relay exploded"))},
		{name: "ws_streaming_incremental_success", body: streamBody, relay: h4RelaySuccess()},
		{name: "ws_streaming_incremental_error", body: streamBody, relay: h4RelayErr(errors.New("relay exploded"))},
		{name: "ws_streaming_buffered_success", body: streamBody, relay: h4RelaySuccess(), buffered: true},
		{name: "ws_streaming_buffered_error", body: streamBody, relay: h4RelayErr(errors.New("relay exploded")), buffered: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if tc.buffered {
				t.Setenv("COORDINATOR_STREAMING_FORCE_BUFFERED", "1")
			}
			reqLog, _ := h4OpenRequestLog(t)
			var observed *requestTerminal
			s := h4Server(t, reqLog, tc.relay, &observed)

			rr := h4PostChat(t, s, []byte(tc.body))

			if observed == nil {
				t.Fatal("terminal arbiter was never evaluated")
			}
			claim, ok := observed.claimedBuyer()
			if !ok {
				t.Fatalf("no buyer terminal claimed although the buyer received status %d — a write "+
					"path bypassed noPriorDispatchResponseWriter", rr.Code)
			}
			if claim.Status != rr.Code {
				t.Fatalf("claimed terminal = %d but the buyer observed %d — the latch must capture "+
					"the FIRST committed status", claim.Status, rr.Code)
			}
		})
	}

	t.Run("http_forwarding_transports", func(t *testing.T) {
		upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var buf bytes.Buffer
			_, _ = io.Copy(&buf, r.Body)
			if bytes.Contains(buf.Bytes(), []byte(`"stream":true`)) {
				w.Header().Set("Content-Type", "text/event-stream")
				w.WriteHeader(http.StatusOK)
				_, _ = w.Write([]byte("data: {\"id\":\"ok\",\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"))
				if f, ok := w.(http.Flusher); ok {
					f.Flush()
				}
				return
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}`))
		}))
		defer upstream.Close()

		for _, tc := range []struct {
			name string
			body string
		}{
			{"http_buffered", h4ChatBody},
			{"http_streaming", `{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hello"}]}`},
		} {
			t.Run(tc.name, func(t *testing.T) {
				reqLog, _ := h4OpenRequestLog(t)
				billingStore, err := billing.NewStore(reqLog.DB())
				if err != nil {
					t.Fatalf("billing.NewStore: %v", err)
				}
				registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "h1", EndpointURL: upstream.URL}})
				registry.Register(&pool.Provider{
					ProviderID:            "h1",
					AssignedID:            "s1",
					Hostname:              "h1.local",
					ModelID:               "model-a",
					ModelParamsB:          7,
					RAMGB:                 16,
					MaxContextTokens:      20000,
					MaxConcurrency:        1,
					SlotsFree:             1,
					SlotsTotal:            1,
					ThroughputTPSEstimate: 30,
					EndpointURL:           upstream.URL,
					Tier:                  pool.TierPinned,
					InferencePath:         pool.InferencePathHTTPForwarding,
					State:                 pool.StateReady,
					LastHeartbeatAt:       time.Now().UTC(),
					ConnectedAt:           time.Now().UTC(),
					BinaryVersion:         "0.1.0",
				}, nil)
				var observed *requestTerminal
				s := NewServer(
					registry,
					zerolog.Nop(),
					time.Unix(1716768000, 0),
					WithRequestLog(reqLog),
					WithBilling(billingStore, h4Rewards()),
					WithRoutingConfig(config.RoutingConfig{MaxRetries: 0, StickyTTLS: 1800, StickyMaxEntries: 10000}),
				)
				s.terminalObserver = func(rt *requestTerminal) { observed = rt }

				rr := h4PostChat(t, s, []byte(tc.body))

				if observed == nil {
					t.Fatal("terminal arbiter was never evaluated")
				}
				claim, ok := observed.claimedBuyer()
				if !ok {
					t.Fatalf("no buyer terminal claimed although the buyer received status %d", rr.Code)
				}
				if claim.Status != rr.Code {
					t.Fatalf("claimed terminal = %d but the buyer observed %d", claim.Status, rr.Code)
				}
			})
		}
	})
}
