package buyer

import (
	"context"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/rs/zerolog"
)

// settlementLegServer builds a buyer.Server with BOTH a request log and a
// billing store wired, which is what recordRow needs before it will write a
// settlement_attempt_outputs row.
func settlementLegServer(t *testing.T) *Server {
	t.Helper()
	reqLog, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("requestlog.OpenStore: %v", err)
	}
	t.Cleanup(func() { _ = reqLog.Close() })
	store, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	return NewServer(
		pool.NewRegistry(nil),
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		WithRequestLog(reqLog),
		WithBilling(store, config.Default().Rewards),
	)
}

func settlementLegRecorder(s *Server, requestID string) *billingRecorder {
	startedAt := time.Unix(1716768000, 0)
	state := &forwardState{}
	state.phaseTiming.init(startedAt)
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	rec := s.newBillingRecorder(r, state, startedAt, requestID, "", "acct-settlement-leg", requestlog.AuthenticatedAccount{}, false)
	// Stand in for writeRouteSnapshotForAttempt, which stamps the settlement
	// attempt identity at the dispatch boundary.
	rec.settlementAttemptN = 0
	rec.hasSettlementAttemptN = true
	return rec
}

func settlementLegProvider() pool.Provider {
	return pool.Provider{
		ProviderID:    "mp-unsettled-leg",
		AssignedID:    "s-unsettled-leg",
		ModelID:       "model-a",
		ReceiptPubkey: []byte("some-receipt-pubkey"),
	}
}

// insertSettlementLegRouteSnapshot stands in for writeRouteSnapshotForAttempt,
// which needs live catalog material. The receipt-evidence loader reads the
// route snapshot before the attempt output, so tests that need to reach the
// attempt-output lookup must have one on record.
func insertSettlementLegRouteSnapshot(t *testing.T, s *Server, rec *billingRecorder, provider pool.Provider) {
	t.Helper()
	store, _, _ := s.billingState()
	sessionID := "session-a"
	generationID := "generation-a"
	if _, err := store.InsertRouteSnapshot(context.Background(), billing.RouteSnapshot{
		AccountScope:                       accountScopeForSettlement(rec.accountID),
		RequestID:                          rec.requestID,
		AttemptN:                           int64(rec.settlementAttemptN),
		ProviderID:                         provider.ProviderID,
		ProviderSessionID:                  &sessionID,
		ProviderGenerationID:               &generationID,
		PaidEntrypoint:                     "coordinator_buyer_v1_chat_completions",
		ProviderReceiptKeyID:               "ed25519-sha256:" + strings.Repeat("2", 64),
		ProviderReceiptKeySource:           "auth_session",
		ModelID:                            "model-a",
		ProviderReportedModelHash:          strings.Repeat("3", 64),
		ProviderReportedModelHashAlgorithm: modelidentity.SnapshotManifestV1,
		ExpectedCatalogModelHash:           strings.Repeat("3", 64),
		ExpectedCatalogModelHashAlgorithm:  modelidentity.SnapshotManifestV1,
		CatalogID:                          "catalog-a",
		CatalogBodyDigest:                  strings.Repeat("4", 64),
		CatalogSignatureKeyID:              "catalog-key-a",
		CatalogSignaturePubkeyFingerprint:  "ed25519-sha256:" + strings.Repeat("5", 64),
		CatalogExpiresAtUnixMS:             1800000000000,
		Spec008HashStatus:                  "hash_verified",
		RouteSnapshotPolicyVersion:         billing.RouteSnapshotPolicyVersion,
		RouteSnapshotMode:                  billing.RouteSnapshotModeObserve,
		RouteDecisionTSUnixMS:              1716768000100,
		RequestStartTSUnixMS:               1716768000000,
		PendingDeadlineSeconds:             30,
		PromptHashBasis:                    promptHashBasisCoordinatorV1,
		PromptHash:                         strings.Repeat("6", 64),
	}); err != nil {
		t.Fatalf("InsertRouteSnapshot: %v", err)
	}
}

// TestUnsettledQueueFullLegSkipsMissingReceiptRecord is the issue #1578
// regression guard.
//
// A 503 provider queue-full leg is deliberately NOT billed: recordRow's
// `status != http.StatusServiceUnavailable` gate skips both the billing row
// and the settlement_attempt_outputs row, because the provider served zero
// bytes and is owed nothing. The retry paths nonetheless asked the store to
// record a *missing* settlement receipt for that leg, which could only ever
// come back as "settlement attempt output missing" — 40 such warns during the
// 2026-09-18 #1570 live probe, all paired 1:1 with error_queue_full 503 rows.
//
// Worse than log noise: on the streaming retry-exhausted path the error is
// propagated to the buyer as a 500 request_log_failed instead of the real
// stream-forward terminal. An unsettled leg must be a silent no-op here.
func TestUnsettledQueueFullLegSkipsMissingReceiptRecord(t *testing.T) {
	s := settlementLegServer(t)
	rec := settlementLegRecorder(s, "req-queue-full-leg")
	provider := settlementLegProvider()
	// Production writes the route snapshot pre-dispatch, so the 503 leg HAS one
	// and the evidence load reaches the attempt-output lookup — which is why the
	// live coordinator logged "settlement attempt output missing" and not
	// "settlement route snapshot missing".
	insertSettlementLegRouteSnapshot(t, s, rec, provider)

	output := settlementOutputForContent("", nil, nil, billing.TerminalStateProviderError)
	if err := rec.recordRow(provider.AssignedID, provider.ProviderID, provider.RuntimeSource, http.StatusServiceUnavailable, nil, nil, nil, "Provider queue full", "error_queue_full", 0, nil, billing.FaultNone, output); err != nil {
		t.Fatalf("recordRow(503): %v", err)
	}
	if rec.lastRecordedSettlementSubject {
		t.Fatal("a 503 queue-full leg was latched as a settlement subject; it is never billed and never gets an attempt output")
	}

	state, has, err := rec.ingestSettlementReceipt(provider, "")
	if err != nil {
		t.Fatalf("missing-receipt record on an unsettled 503 leg returned %v, want nil (nothing was served, nothing is owed)", err)
	}
	if has {
		t.Fatalf("unsettled leg produced receipt state %+v, want none", state)
	}
}

// TestBillableLegRecordsMissingReceiptVerdict pins the other side of the same
// gate: a leg the coordinator DID bill still records a missing-receipt verdict
// when the provider returns no receipt header. The #1578 fix must not widen
// into "never record missing receipts".
func TestBillableLegRecordsMissingReceiptVerdict(t *testing.T) {
	s := settlementLegServer(t)
	rec := settlementLegRecorder(s, "req-billable-leg")
	provider := settlementLegProvider()
	insertSettlementLegRouteSnapshot(t, s, rec, provider)

	prompt, completion := int64(2), int64(1)
	output := settlementOutputForContent("ok", nil, nil, billing.TerminalStateNormalDone)
	if err := rec.recordRow(provider.AssignedID, provider.ProviderID, provider.RuntimeSource, http.StatusOK, &prompt, nil, &completion, "", "", 0, nil, billing.FaultNone, output); err != nil {
		t.Fatalf("recordRow(200): %v", err)
	}
	if !rec.lastRecordedSettlementSubject {
		t.Fatal("a billable 200 leg was not latched as a settlement subject")
	}

	if _, has, err := rec.ingestSettlementReceipt(provider, ""); err != nil || !has {
		t.Fatalf("missing-receipt record on a billable leg: has=%v err=%v, want has=true err=nil", has, err)
	}
}

// TestBillableLegWithAbsentAttemptOutputStaysLoud is the anti-regression guard
// for the #1578 fix itself. The fix must key on "was this leg a settlement
// subject", NOT on "did the attempt-output write succeed". A billable leg whose
// settlement_attempt_outputs write genuinely failed (SQLite contention / route
// snapshot store pressure) is a real evidence gap that makes the request
// non-payable under SPEC-022, so it must still surface an error.
func TestBillableLegWithAbsentAttemptOutputStaysLoud(t *testing.T) {
	s := settlementLegServer(t)
	rec := settlementLegRecorder(s, "req-lost-attempt-output")
	provider := settlementLegProvider()

	insertSettlementLegRouteSnapshot(t, s, rec, provider)
	// Simulate a billable leg whose attempt-output row never landed: latch the
	// settlement subject without any recordRow having written the row.
	rec.lastRecordedSettlementSubject = true

	if _, _, err := rec.ingestSettlementReceipt(provider, ""); err == nil {
		t.Fatal("a billable leg with no settlement attempt output was silently accepted; this evidence gap must stay loud")
	} else if !strings.Contains(err.Error(), "settlement attempt output missing") {
		t.Fatalf("err = %v, want it to carry \"settlement attempt output missing\"", err)
	}
}

// SPEC-047-R003(iv) v0.1.10 (#1694): recordRow carries the serving session's
// hello-time runtime_source into the settlement attempt output, so a leg
// served through a loopback runtime is never coordinator_observed even when
// the provider reported token counts. The native leg above keeps the label.
func TestLoopbackLegIsRecordedByteEstimatedThroughRecordRow(t *testing.T) {
	for source, want := range map[string]string{
		"":                billing.UsageSourceCoordinatorObserved,
		"ollama_loopback": billing.UsageSourceByteEstimated,
	} {
		t.Run("source="+source, func(t *testing.T) {
			s := settlementLegServer(t)
			rec := settlementLegRecorder(s, "req-loopback-leg")
			provider := settlementLegProvider()
			provider.RuntimeSource = source
			insertSettlementLegRouteSnapshot(t, s, rec, provider)

			prompt, completion := int64(2), int64(1)
			output := settlementOutputForContent("ok", nil, nil, billing.TerminalStateNormalDone)
			if err := rec.recordRow(provider.AssignedID, provider.ProviderID, provider.RuntimeSource, http.StatusOK, &prompt, nil, &completion, "", "", 0, nil, billing.FaultNone, output); err != nil {
				t.Fatalf("recordRow(200): %v", err)
			}
			var got string
			if err := s.reqLogStore.DB().QueryRow(`SELECT usage_source FROM settlement_attempt_outputs WHERE request_id = ?`, "req-loopback-leg").Scan(&got); err != nil {
				t.Fatalf("query attempt output: %v", err)
			}
			if got != want {
				t.Fatalf("usage_source=%q want %q", got, want)
			}
		})
	}
}
