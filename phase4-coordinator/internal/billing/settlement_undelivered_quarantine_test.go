package billing

import (
	"context"
	"strings"
	"testing"
	"time"
)

// undeliveredQuarantineFixture writes an enforce route snapshot and its
// provider credit (no attempt output), optionally with a closed verified
// verdict, and returns the route.
func undeliveredQuarantineFixture(t *testing.T, requestID string, verified bool) (*Store, RouteSnapshot) {
	return enforceCreditFixture(t, requestID, verified, true, RouteSnapshotModeEnforce)
}

// enforceCreditFixture writes a provider credit in mode, with or without an
// enforce route snapshot (store pressure skips it), never an attempt output.
func enforceCreditFixture(t *testing.T, requestID string, verified, withSnapshot bool, mode string) (*Store, RouteSnapshot) {
	t.Helper()
	_, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	ts := time.Date(2026, 9, 25, 9, 0, 0, 0, time.UTC)
	snapshotID, err := store.InsertConfigSnapshot(context.Background(), cfg, ts.Add(-time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	route := testRouteSnapshot()
	route.RequestID = requestID
	route.ProviderID = "provider-q"
	route.RouteSnapshotMode = RouteSnapshotModeEnforce
	route.RouteSnapshotPolicyVersion = RouteSnapshotPolicyVersion
	route.RouteDecisionTSUnixMS = ts.UnixMilli()
	route.RequestStartTSUnixMS = ts.UnixMilli()
	route.PendingDeadlineSeconds = 30
	route.AccountScope = "acct_sha256:" + strings.Repeat("6", 64)
	routeDigest := strings.Repeat("0", 64)
	if withSnapshot {
		routeDigest, err = store.InsertRouteSnapshot(context.Background(), route)
		if err != nil {
			t.Fatal(err)
		}
	}
	prompt, completion := int64(20), int64(120)
	input := HotPathInput{
		RequestID: route.RequestID, ProviderAssignedID: "assigned-q", ProviderID: route.ProviderID,
		Model: route.ModelID, Status: 200, TSUtc: ts, PromptTokens: &prompt, CompletionTokens: &completion,
		ConfigSnapshotID: snapshotID, RateEntry: RateFor(cfg.RateCard, route.ModelID), RateCard: cfg.RateCard,
		MultiplierPPM: ParseMultiplierPPM(cfg.GlobalMultiplier), ProviderShareBps: ParseShareBps(cfg.ProviderShare),
		SettlementAccountScopeHash: SettlementAccountScopeHash(route.AccountScope),
		SettlementPolicyMode:       mode, SettlementPolicyVersion: RouteSnapshotPolicyVersion,
	}
	result := ComputeCreditsWithCache(&prompt, nil, &completion, nil, UsageProviderReported, FaultNone, input.RateEntry, input.MultiplierPPM, input.ProviderShareBps)
	if _, err := insertRequestCreditTx(context.Background(), store.db, input, result, "hot_path", ts.Format(time.RFC3339Nano), false, ""); err != nil {
		t.Fatal(err)
	}
	if verified {
		if _, err := store.db.Exec(`
INSERT INTO settlement_receipt_verdicts (
    account_scope_hash, request_id, attempt_n, provider_id,
    receipt_present, receipt_version, receipt_result, settlement_outcome,
    reason, idempotency_status, closed, terminal_state, terminal_state_ts_unix_ms,
    pending_deadline_unix_ms, received_at_unix_ms, route_snapshot_digest,
    route_snapshot_policy_version, route_snapshot_mode, paid_entrypoint,
    spec008_hash_status, provider_reported_model_hash, provider_receipt_key_fingerprint,
    catalog_id, catalog_body_digest, expected_catalog_model_hash, model_id, model_hash,
    receipt_profile, buyer_debit_outcome, provider_settlement_outcome,
    payout_exclusion_outcome, prompt_hash, output_hash, usage_digest,
    receipt_tuple_canonical_sha256, checks_json, verifier_diagnostics_json,
    facts_json, created_at_utc
) VALUES (?, ?, 0, ?, 1, 'spec015-v0.4', 'valid', 'verified',
          'verified_settlement', 'first_terminal', 1, ?, ?, ?, ?, ?, ?, ?, ?,
          ?, ?, ?, ?, ?, ?, ?, NULL, 'spec015-v0.4', 'no_money_movement_step5',
          'no_money_movement_step5', 'excluded_until_spec022_verified',
          ?, ?, ?, NULL, '{}', '{}', NULL, ?)`,
			SettlementAccountScopeHash(route.AccountScope), route.RequestID, route.ProviderID,
			TerminalStateNormalDone, ts.UnixMilli(), ts.Add(30*time.Second).UnixMilli(), ts.UnixMilli(), routeDigest,
			RouteSnapshotPolicyVersion, RouteSnapshotModeEnforce, route.PaidEntrypoint,
			route.Spec008HashStatus, route.ProviderReportedModelHash, route.ProviderReceiptKeyID,
			route.CatalogID, route.CatalogBodyDigest, route.ExpectedCatalogModelHash, route.ModelID,
			route.PromptHash, strings.Repeat("8", 64), strings.Repeat("9", 64), ts.Format(time.RFC3339Nano)); err != nil {
			t.Fatal(err)
		}
	}
	return store, route
}

// Codex CODE HIGH (b): an attempt with a closed verified verdict keeps its
// credit; the quarantine reports it verified and touches nothing.
func TestQuarantineUndeliveredSettlementCreditSparesVerifiedAttempt(t *testing.T) {
	store, route := undeliveredQuarantineFixture(t, "undelivered-verified", true)
	got, err := store.QuarantineUndeliveredSettlementCredit(context.Background(), route.AccountScope, route.RequestID, 0, route.ProviderID, UndeliveredSettlementQuarantineReasons[0])
	if err != nil || got != UndeliveredQuarantineVerified {
		t.Fatalf("result=%v err=%v, want UndeliveredQuarantineVerified", got, err)
	}
	if n := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 1`, route.RequestID); n != 0 {
		t.Fatalf("a verified credit was quarantined (%d rows)", n)
	}
}

// Review R4 LOW-2 at the store: a quarantined undelivered credit with no
// attempt output is reported closed quarantined by the finality lookup.
func TestQuarantinedUndeliveredCreditFinalityIsClosedQuarantined(t *testing.T) {
	store, route := undeliveredQuarantineFixture(t, "undelivered-quarantined", false)
	got, err := store.QuarantineUndeliveredSettlementCredit(context.Background(), route.AccountScope, route.RequestID, 0, route.ProviderID, UndeliveredSettlementQuarantineReasons[0])
	if err != nil || got != UndeliveredQuarantineQuarantined {
		t.Fatalf("result=%v err=%v, want UndeliveredQuarantineQuarantined", got, err)
	}
	hasOutput, verified, err := store.SettlementAttemptEvidence(context.Background(), route.AccountScope, route.RequestID, route.ProviderID)
	if err != nil || hasOutput || verified {
		t.Fatalf("evidence output=%v verified=%v err=%v, want neither", hasOutput, verified, err)
	}
	finality, found, err := store.RequestSettlementFinality(context.Background(), route.AccountScope, route.RequestID, time.Now().UnixMilli())
	if err != nil || !found {
		t.Fatalf("finality found=%v err=%v", found, err)
	}
	if finality.Outcome != SettlementOutcomeQuarantined || !finality.Closed || finality.Reason != UndeliveredSettlementQuarantineReasons[0] {
		t.Fatalf("finality=%+v, want closed quarantined", finality)
	}
}

var enforceCreditFixtureTS = time.Date(2026, 9, 25, 9, 0, 0, 0, time.UTC)

func finalityAt(t *testing.T, store *Store, route RouteSnapshot, at time.Time) (RequestSettlementFinality, bool) {
	t.Helper()
	finality, found, err := store.RequestSettlementFinality(context.Background(), route.AccountScope, route.RequestID, at.UnixMilli())
	if err != nil {
		t.Fatal(err)
	}
	return finality, found
}

// Codex SECURITY / final residual: an enforce credit with no attempt output
// and no verdict (a refund sent after the quarantine failed) is pending until
// the snapshot's pending deadline after the credit, then closed quarantined,
// never a 404.
func TestEnforceCreditWithoutEvidenceClosesAfterSnapshotDeadline(t *testing.T) {
	store, route := enforceCreditFixture(t, "evidence-missing-snapshot", false, true, RouteSnapshotModeEnforce)
	early, found := finalityAt(t, store, route, enforceCreditFixtureTS.Add(10*time.Second))
	if !found || early.Closed || early.Outcome != SettlementOutcomePending || early.PendingDeadlineUnixMS == 0 {
		t.Fatalf("before the deadline: %+v found=%v, want an open pending with a deadline", early, found)
	}
	late, found := finalityAt(t, store, route, enforceCreditFixtureTS.Add(31*time.Second))
	if !found || !late.Closed || late.Outcome != SettlementOutcomeQuarantined || late.Reason != SettlementEvidenceMissingReason || !late.ModeScopeComplete {
		t.Fatalf("after the deadline: %+v found=%v, want closed quarantined %s", late, found, SettlementEvidenceMissingReason)
	}
}

// The same for an enforce credit recorded under store pressure with no route
// snapshot: pending for the grace, then closed quarantined.
func TestEnforceCreditWithoutSnapshotClosesAfterGrace(t *testing.T) {
	store, route := enforceCreditFixture(t, "evidence-missing-no-snapshot", false, false, RouteSnapshotModeEnforce)
	early, found := finalityAt(t, store, route, enforceCreditFixtureTS.Add(time.Minute))
	if !found || early.Closed || early.Outcome != SettlementOutcomePending {
		t.Fatalf("inside the grace: %+v found=%v, want an open pending", early, found)
	}
	late, found := finalityAt(t, store, route, enforceCreditFixtureTS.Add(enforceEvidenceMissingGrace+time.Second))
	if !found || !late.Closed || late.Outcome != SettlementOutcomeQuarantined || late.Reason != SettlementEvidenceMissingReason || !late.ModeScopeComplete {
		t.Fatalf("after the grace: %+v found=%v, want closed quarantined %s", late, found, SettlementEvidenceMissingReason)
	}
}

// Scope: an observe credit without evidence stays out of the rule, and a
// verified attempt is never closed as missing evidence.
func TestEvidenceMissingRuleScope(t *testing.T) {
	store, route := enforceCreditFixture(t, "evidence-missing-observe", false, false, RouteSnapshotModeObserve)
	if _, found := finalityAt(t, store, route, enforceCreditFixtureTS.Add(time.Hour)); found {
		t.Fatal("an observe credit without a snapshot produced finality")
	}
	vstore, vroute := enforceCreditFixture(t, "evidence-missing-verified", true, true, RouteSnapshotModeEnforce)
	ctx := context.Background()
	verdicts, err := vstore.requestSettlementVerdicts(ctx, vroute.AccountScope, vroute.RequestID)
	if err != nil || len(verdicts) != 1 {
		t.Fatalf("verdicts=%v err=%v, want the verified one", verdicts, err)
	}
	missing, err := vstore.requestSettlementAttemptsWithoutVerdict(ctx, vroute.AccountScope, vroute.RequestID, verdicts, enforceCreditFixtureTS.Add(time.Hour).UnixMilli())
	if err != nil || len(missing) != 0 {
		t.Fatalf("missing=%+v err=%v: a verified attempt must not gain an evidence-missing row", missing, err)
	}
	noSnap, err := vstore.requestEnforceCreditsWithoutSnapshot(ctx, vroute.AccountScope, vroute.RequestID, enforceCreditFixtureTS.Add(time.Hour).UnixMilli())
	if err != nil || len(noSnap) != 0 {
		t.Fatalf("no-snapshot rows=%+v err=%v, want none for a snapshotted, verified attempt", noSnap, err)
	}
}
