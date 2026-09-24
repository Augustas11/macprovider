package billing

import (
	"context"
	"database/sql"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

type recoveryLoopbackCase struct {
	runtimeSource string
	// recordRuntime false writes the identity row the way pre-runtime_source
	// code did (NULL runtime_source).
	recordRuntime bool
	byteEstimated bool
	snapshot      func(RouteSnapshot) *RouteSnapshot
}

// recoverLoopbackFallbackRow writes what a failed hot path leaves behind (the
// request_log row and provider identity, no ledger credit), optionally the
// attempt's route snapshot, runs ledger recovery, and returns the re-created
// ledger row.
func recoverLoopbackFallbackRow(t *testing.T, tc recoveryLoopbackCase) (gross, provider, quarantined int64, reason string, operatorRows int64) {
	t.Helper()
	reqStore, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	snapshotID, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Unix(100, 0).UTC())
	if err != nil {
		t.Fatal(err)
	}
	ts := time.Unix(200, 0).UTC()
	prompt, completion, estimate := int64(1000), int64(2000), int64(75)
	row := requestlog.Row{
		TSUtc: ts, RequestID: "recover-loopback", Model: "model-a", ProviderAssignedID: "assigned-a",
		PromptTokens: &prompt, CompletionTokens: &completion, Status: 200, BuyerIP: "127.0.0.1",
	}
	input := HotPathInput{
		RequestID: row.RequestID, AttemptN: 0, ProviderAssignedID: row.ProviderAssignedID,
		ProviderID: "provider-a", Model: row.Model, Status: row.Status, Stream: row.Stream,
		TSUtc: row.TSUtc, PromptTokens: &prompt, CompletionTokens: &completion,
		ConfigSnapshotID: snapshotID, RateEntry: RateFor(cfg.RateCard, row.Model),
		MultiplierPPM: ParseMultiplierPPM(cfg.GlobalMultiplier), ProviderShareBps: ParseShareBps(cfg.ProviderShare),
		ProviderRuntimeSource: tc.runtimeSource, PoolOperatorAttested: true,
	}
	if tc.byteEstimated {
		row.CompletionTokens, input.CompletionTokens = nil, nil
		row.EstimatedCompTokens, input.EstimatedCompTokens = &estimate, &estimate
	}
	if err := store.WriteRequestLogWithIdentity(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	if !tc.recordRuntime {
		if _, err := store.db.Exec(`UPDATE ledger_provider_identity_snapshots SET runtime_source = NULL`); err != nil {
			t.Fatal(err)
		}
	}
	if tc.snapshot != nil {
		base := testRouteSnapshot()
		base.AccountScope = AccountScopeForSettlement("")
		base.RequestID = row.RequestID
		base.ProviderID = input.ProviderID
		if snap := tc.snapshot(base); snap != nil {
			if _, err := store.InsertRouteSnapshot(context.Background(), *snap); err != nil {
				t.Fatal(err)
			}
		}
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits`); got != 0 {
		t.Fatalf("fallback left %d ledger rows before recovery", got)
	}
	in := RecoverInput{ScanFrom: ts.Add(-time.Minute), ScanTo: ts.Add(time.Minute), Source: "startup_scan"}
	if err := store.RecoverLedger(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	var reasonNull sql.NullString
	if err := store.db.QueryRow(`SELECT gross_credits, provider_credits, quarantined, quarantine_reason FROM ledger_request_credits WHERE request_id = ?`, row.RequestID).
		Scan(&gross, &provider, &quarantined, &reasonNull); err != nil {
		t.Fatal(err)
	}
	return gross, provider, quarantined, reasonNull.String, scalar(t, store.db, `SELECT COUNT(*) FROM ledger_operator_credits`)
}

func attestedPoolSnapshot(route RouteSnapshot) *RouteSnapshot {
	route.RouteSnapshotMode = RouteSnapshotModeEnforce
	route.PoolID = "pool-abc"
	route.ManifestVersion = 2
	route.ManifestCoreDigest = strings.Repeat("d", 64)
	route.RuntimeSource = "llamacpp_loopback"
	route.PoolGeneration = 7
	route.PoolOperatorAccountID = "creator-a"
	return &route
}

// Recovery re-creating a missing ledger row applies the hot-path loopback
// rule (SPEC-047-R003(iv), SPEC-022-R012): only an attested pool attempt with
// the runtime's reported usage is priced; every other loopback attempt, and
// every attempt that might be loopback without a readable snapshot, is zero
// credit, zero debit, quarantined. Native recovery is unchanged.
func TestRecoverLedger_AppliesLoopbackZeroBillRule(t *testing.T) {
	for name, tc := range map[string]struct {
		recoveryLoopbackCase
		wantPriced bool
	}{
		"native reported usage is priced":                  {recoveryLoopbackCase{runtimeSource: "", recordRuntime: true}, true},
		"native mlx_cache byte estimate is priced":         {recoveryLoopbackCase{runtimeSource: "mlx_cache", recordRuntime: true, byteEstimated: true}, true},
		"loopback on global route is zero":                 {recoveryLoopbackCase{runtimeSource: "llamacpp_loopback", recordRuntime: true, snapshot: func(r RouteSnapshot) *RouteSnapshot { return &r }}, false},
		"loopback byte estimate on pool route is zero":     {recoveryLoopbackCase{runtimeSource: "llamacpp_loopback", recordRuntime: true, byteEstimated: true, snapshot: attestedPoolSnapshot}, false},
		"loopback missing snapshot fails closed":           {recoveryLoopbackCase{runtimeSource: "llamacpp_loopback", recordRuntime: true}, false},
		"loopback snapshot for another runtime is zero":    {recoveryLoopbackCase{runtimeSource: "ollama_loopback", recordRuntime: true, snapshot: attestedPoolSnapshot}, false},
		"unrecorded runtime missing snapshot fails closed": {recoveryLoopbackCase{runtimeSource: "llamacpp_loopback", recordRuntime: false}, false},
		"attested pool usage stays attested":               {recoveryLoopbackCase{runtimeSource: "llamacpp_loopback", recordRuntime: true, snapshot: attestedPoolSnapshot}, true},
	} {
		t.Run(name, func(t *testing.T) {
			gross, provider, quarantined, reason, operatorRows := recoverLoopbackFallbackRow(t, tc.recoveryLoopbackCase)
			if tc.wantPriced {
				if gross == 0 || provider == 0 || quarantined != 0 || operatorRows != 1 {
					t.Fatalf("recovered row gross=%d provider=%d quarantined=%d operator_rows=%d, want priced", gross, provider, quarantined, operatorRows)
				}
				return
			}
			if gross != 0 || provider != 0 || quarantined != 1 || reason != LoopbackRuntimeNotSettlementEligible || operatorRows != 0 {
				t.Fatalf("recovered row gross=%d provider=%d quarantined=%d reason=%q operator_rows=%d, want 0/0 quarantined %s",
					gross, provider, quarantined, reason, operatorRows, LoopbackRuntimeNotSettlementEligible)
			}
		})
	}
}
