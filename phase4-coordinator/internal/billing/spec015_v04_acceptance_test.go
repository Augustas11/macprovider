package billing

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

func TestSPEC015V04AcceptanceCriteria(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	covered := map[int]string{}
	mark := func(ac int, evidence string) {
		if ac < 43 || ac > 71 {
			t.Fatalf("invalid SPEC-015 v0.4 AC marker AC-%d", ac)
		}
		covered[ac] = evidence
	}

	positiveByTerminal := map[string]map[bool]bool{}
	for _, tuple := range fixtures.ReceiptTuples {
		input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
		got := VerifySettlementReceipt(input)
		if got.ReceiptResult != SettlementReceiptResultValid {
			t.Fatalf("%s receipt_result=%s reason=%s, want valid", tuple.ID, got.ReceiptResult, got.Reason)
		}
		terminal := settlementTupleString(t, tuple, "terminal_state")
		delivered := settlementTupleUsageInt(t, tuple, "delivered_output_bytes")
		wantOutcome := SettlementOutcomeVerified
		if terminal != TerminalStateNormalDone && delivered == 0 {
			wantOutcome = SettlementOutcomeZeroSettled
		}
		if got.Outcome != wantOutcome {
			t.Fatalf("%s outcome=%s reason=%s, want %s", tuple.ID, got.Outcome, got.Reason, wantOutcome)
		}
		if got.Facts == nil || got.Facts.ProviderReceiptKeyID != fixtures.ProviderReceiptKeyID {
			t.Fatalf("%s facts key id=%v want %s", tuple.ID, got.Facts, fixtures.ProviderReceiptKeyID)
		}
		if got.Facts.SignatureKeyAlg != "Ed25519" || got.Facts.ReceiptVersion != "4" {
			t.Fatalf("%s facts alg/version=%s/%s, want Ed25519/4", tuple.ID, got.Facts.SignatureKeyAlg, got.Facts.ReceiptVersion)
		}
		if !got.Checks.SignatureVerified || !got.Checks.RouteSnapshotMatched || !got.Checks.PromptHashMatched ||
			!got.Checks.OutputHashMatched || !got.Checks.UsageMatched || !got.Checks.UsageCrossChecked ||
			!got.Checks.NoOverlap || !got.Checks.TerminalStateMatched || !got.Checks.TimestampWindowValid {
			t.Fatalf("%s incomplete verification checks: %#v", tuple.ID, got.Checks)
		}
		if positiveByTerminal[terminal] == nil {
			positiveByTerminal[terminal] = map[bool]bool{}
		}
		positiveByTerminal[terminal][delivered > 0] = true
		mark(44, "positive fixtures require receipt_version 4")
		mark(48, "positive fixtures prove three-way model-hash equality")
		mark(70, "positive fixtures bind the exact ed25519-sha256 receipt key id")
		if terminal == TerminalStateNormalDone && delivered > 0 {
			mark(52, "non-streaming normal_done nonzero tuple verifies")
		}
		if terminal == TerminalStateNormalDone && strings.Contains(tuple.ID, "streaming") {
			mark(53, "streaming normal_done tuple verifies with half-open prefix bytes")
		}
		switch terminal {
		case TerminalStateProviderError:
			mark(54, "provider_error terminal rows verify with zero and nonzero prefixes")
		case TerminalStateBuyerCancel:
			mark(55, "buyer_cancel terminal rows verify with zero and nonzero prefixes")
		case TerminalStateGatewayTimeout:
			mark(56, "gateway_timeout terminal rows verify with zero and nonzero prefixes")
		case TerminalStateUpstreamTransportDisconnect:
			mark(57, "upstream_transport_disconnect terminal rows verify with zero and nonzero prefixes")
		}
	}
	for _, terminal := range []string{
		TerminalStateNormalDone,
		TerminalStateProviderError,
		TerminalStateBuyerCancel,
		TerminalStateGatewayTimeout,
		TerminalStateUpstreamTransportDisconnect,
	} {
		if !positiveByTerminal[terminal][false] || !positiveByTerminal[terminal][true] {
			t.Fatalf("terminal %s coverage=%v, want delivered_output_bytes == 0 and > 0", terminal, positiveByTerminal[terminal])
		}
	}
	mark(71, "all N.7 terminal states covered with delivered_output_bytes == 0 and > 0")

	negativeByFailure := map[string]settlementVerifierTupleFixture{}
	for _, negative := range fixtures.NegativeReceipts {
		negativeByFailure[negative.ExpectedFailure] = negative
		base := settlementReceiptTuplesByID(fixtures)[negative.BaseTupleID]
		input := settlementVerifierInputFromFixture(t, fixtures, base, pubkey)
		input.Header = negative.WireReceipt
		got := VerifySettlementReceipt(input)
		if got.Outcome != SettlementOutcomeQuarantined {
			t.Fatalf("%s outcome=%s reason=%s, want quarantined", negative.ID, got.Outcome, got.Reason)
		}
		if want := publicSettlementFailureReason(negative.ExpectedFailure); want != "" && got.Reason != want {
			t.Fatalf("%s reason=%s want %s", negative.ID, got.Reason, want)
		}
	}
	requireNegativeFailures(t, negativeByFailure, []string{
		"strict_shape_missing_output_hash",
		"strict_shape_extra_top_level_field",
		"legacy_receipt_version",
		"attempt_mismatch",
		"route_snapshot_digest_mismatch",
		"model_hash_mismatch",
		"output_hash_mismatch",
		"usage_delivered_bytes_mismatch",
		"usage_negative_value",
		"usage_null",
		"usage_missing_required_field",
		"usage_extra_field",
		"wrong_key_signature",
	})
	mark(43, "missing and extra strict tuple fields quarantine")
	mark(44, "legacy version fixture is not accepted as v0.4")
	mark(46, "attempt/context mismatch fixtures quarantine")
	mark(47, "route snapshot digest mismatch fixture quarantines")
	mark(48, "model hash mismatch fixture quarantines")
	mark(49, "output hash mismatch fixture quarantines")
	mark(51, "usage shape/value/cross-check fixtures quarantine")
	mark(64, "legacy receipt versions are not settlement-capable")
	assertPhase7ForwardCompatRegression(t)

	base := firstSettlementTupleWithDelivered(t, fixtures, TerminalStateNormalDone, true)
	baseInput := settlementVerifierInputFromFixture(t, fixtures, base, pubkey)
	assertSettlementQuarantine(t, baseInput, "AC-45 null model hash", func(in *SettlementVerifyInput) {
		in.Header = settlementHeaderWithCanonicalMutation(t, in.Header, func(tuple map[string]any) {
			tuple["model_hash"] = nil
		})
	}, "model_hash_invalid")
	mark(45, "model_hash null cannot produce positive settlement")

	for _, tc := range []struct {
		name   string
		reason string
		mutate func(*SettlementVerifyInput)
	}{
		{"account", "account_scope_mismatch", func(in *SettlementVerifyInput) { in.AccountScope = "acct-replay" }},
		{"request", "request_id_mismatch", func(in *SettlementVerifyInput) { in.RequestID = "req-replay" }},
		{"attempt", "attempt_mismatch", func(in *SettlementVerifyInput) { in.AttemptN++ }},
		{"provider", "provider_id_mismatch", func(in *SettlementVerifyInput) { in.ProviderID = "provider-replay" }},
		{"key", "provider_receipt_key_id_mismatch", func(in *SettlementVerifyInput) {
			in.ProviderReceiptKeyID = "ed25519-sha256:" + strings.Repeat("a", 64)
		}},
		{"terminal", "terminal_state_mismatch", func(in *SettlementVerifyInput) { in.TerminalState = TerminalStateProviderError }},
	} {
		assertSettlementQuarantine(t, baseInput, "AC-60 "+tc.name, tc.mutate, tc.reason)
	}
	mark(60, "replay onto different account/request/attempt/provider/key/terminal quarantines")

	assertSettlementQuarantine(t, baseInput, "AC-47 route mode", func(in *SettlementVerifyInput) {
		in.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
	}, "route_snapshot_digest_mismatch")
	assertSettlementQuarantine(t, baseInput, "AC-47 route policy", func(in *SettlementVerifyInput) {
		in.RouteSnapshot.RouteSnapshotPolicyVersion = "spec022-policy-v2"
	}, "route_snapshot_digest_mismatch")
	assertRouteSnapshotMutationCoverage(t, baseInput)

	assertSettlementQuarantine(t, baseInput, "AC-50 canonical hashes unavailable", func(in *SettlementVerifyInput) {
		in.CanonicalHashesAvailable = false
	}, "canonical_hash_unavailable")
	mark(50, "canonical hash unavailable quarantines")

	for _, tc := range []struct {
		name   string
		reason string
		mutate func(*SettlementVerifyInput)
	}{
		{"not-cross-checked", "usage_not_cross_checked", func(in *SettlementVerifyInput) { in.UsageCrossChecked = false }},
		{"byte-estimated", "usage_source_not_settlement_capable", func(in *SettlementVerifyInput) { in.UsageSource = UsageSourceByteEstimated }},
		{"ledger-mismatch", "usage_mismatch", func(in *SettlementVerifyInput) { in.ExpectedUsage.ObservedOutputTokens++ }},
	} {
		assertSettlementQuarantine(t, baseInput, "AC-51 "+tc.name, tc.mutate, tc.reason)
	}

	missing := baseInput
	missing.ReceiptMissing = true
	missing.NowUnixMS = missing.deadlineUnixMS() - 1
	if got := VerifySettlementReceipt(missing); got.Outcome != SettlementOutcomePending {
		t.Fatalf("AC-58 missing before deadline outcome=%s reason=%s, want pending", got.Outcome, got.Reason)
	}
	missing.NowUnixMS = missing.deadlineUnixMS() + 1
	if got := VerifySettlementReceipt(missing); got.Outcome != SettlementOutcomeQuarantined || got.Reason != "missing_receipt_deadline_elapsed" {
		t.Fatalf("AC-58 missing after deadline outcome=%s reason=%s, want quarantine/deadline", got.Outcome, got.Reason)
	}
	mark(58, "missing receipt remains pending until deadline then quarantines")

	assertFailoverFixtureChain(t, fixtures)
	assertNegativeRangeScenariosBlockSettlement(t, fixtures, baseInput, pubkey)
	mark(59, "failover fixtures cover adjacent, overlap, duplicate, and out-of-order ranges through store authorization gates")

	assertSettlementQuarantine(t, baseInput, "AC-61 already terminal", func(in *SettlementVerifyInput) {
		in.TerminalOutcomeFinal = true
	}, "duplicate_receipt_after_terminal")
	mark(61, "already-terminal receipt cannot create a second positive settlement candidate")

	assertSettlementQuarantine(t, baseInput, "AC-62 late receipt", func(in *SettlementVerifyInput) {
		in.ReceiptReceivedUnixMS = in.deadlineUnixMS() + 1
		in.NowUnixMS = in.ReceiptReceivedUnixMS
	}, "receipt_after_deadline")
	assertSettlementQuarantine(t, baseInput, "AC-62 terminal timestamp mismatch", func(in *SettlementVerifyInput) {
		in.TerminalStateTSUnixMS++
	}, "terminal_state_timestamp_mismatch")
	mark(62, "late receipt and terminal timestamp mismatch quarantine")

	futureVersion := baseInput
	futureVersion.Header = settlementHeaderWithCanonicalMutation(t, futureVersion.Header, func(tuple map[string]any) {
		tuple["receipt_version"] = "10"
	})
	if got := VerifySettlementReceipt(futureVersion); got.Outcome != SettlementOutcomeQuarantined || got.ReceiptResult != SettlementReceiptResultInconclusive || got.Reason != "unknown_receipt_version" {
		t.Fatalf("AC-63 outcome=%s/%s reason=%s, want quarantined/inconclusive unknown_receipt_version", got.Outcome, got.ReceiptResult, got.Reason)
	}
	mark(63, "unknown future receipt version is inconclusive and not payable")

	assertSettlementQuarantine(t, baseInput, "AC-69 missing alg", func(in *SettlementVerifyInput) {
		in.Header = settlementHeaderWithCanonicalMutation(t, in.Header, func(tuple map[string]any) {
			delete(tuple, "signature_key_alg")
		})
	}, "tuple_shape_invalid")
	assertSettlementQuarantine(t, baseInput, "AC-69 wrong alg", func(in *SettlementVerifyInput) {
		in.Header = settlementHeaderWithCanonicalMutation(t, in.Header, func(tuple map[string]any) {
			tuple["signature_key_alg"] = "P-256"
		})
	}, "signature_key_alg_invalid")
	mark(69, "missing or non-Ed25519 signature_key_alg quarantines")

	assertSettlementQuarantine(t, baseInput, "AC-70 invalid receipt key id", func(in *SettlementVerifyInput) {
		in.Header = settlementHeaderWithCanonicalMutation(t, in.Header, func(tuple map[string]any) {
			tuple["provider_receipt_key_id"] = strings.Repeat("a", 64)
		})
	}, "provider_receipt_key_id_invalid")

	assertReceiptStateRedactionAndDeadline(t, baseInput, pubkey, fixtures.ProviderReceiptPubkeyB64)
	mark(65, "audit/verdict rows redact raw receipt, raw public key, account scope, bearer, prompts, and outputs")
	mark(66, "verdict schema has no raw receipt/signature/public-key/prompt/output retention columns")
	mark(67, "receipt state exposes pending deadline basis and late receipt non-settlement boundary")
	assertBuyerDisclosureSurfaces(t)
	mark(68, "buyer/product disclosures state the v0.4 model-verification limit")

	missingACs := make([]int, 0)
	for ac := 43; ac <= 71; ac++ {
		if covered[ac] == "" {
			missingACs = append(missingACs, ac)
		}
	}
	if len(missingACs) > 0 {
		t.Fatalf("missing SPEC-015 v0.4 acceptance evidence for ACs: %v", missingACs)
	}
}

func requireNegativeFailures(t *testing.T, got map[string]settlementVerifierTupleFixture, want []string) {
	t.Helper()
	for _, failure := range want {
		if got[failure].ID == "" {
			t.Fatalf("missing negative fixture for %s", failure)
		}
	}
}

func firstSettlementTupleWithDelivered(t *testing.T, fixtures settlementVerifierFixtures, terminal string, nonzero bool) settlementVerifierTupleFixture {
	t.Helper()
	for _, tuple := range fixtures.ReceiptTuples {
		if settlementTupleString(t, tuple, "terminal_state") != terminal {
			continue
		}
		if (settlementTupleUsageInt(t, tuple, "delivered_output_bytes") > 0) == nonzero {
			return tuple
		}
	}
	t.Fatalf("no tuple with terminal_state=%s nonzero=%v", terminal, nonzero)
	return settlementVerifierTupleFixture{}
}

func assertSettlementQuarantine(t *testing.T, input SettlementVerifyInput, name string, mutate func(*SettlementVerifyInput), reason string) {
	t.Helper()
	candidate := input
	mutate(&candidate)
	got := VerifySettlementReceipt(candidate)
	if got.Outcome != SettlementOutcomeQuarantined || got.Reason != reason {
		t.Fatalf("%s outcome=%s reason=%s, want quarantined/%s", name, got.Outcome, got.Reason, reason)
	}
}

func settlementHeaderWithCanonicalMutation(t *testing.T, header string, mutate func(map[string]any)) string {
	t.Helper()
	parts := strings.Split(header, ".")
	if len(parts) != 2 {
		t.Fatalf("receipt envelope parts=%d, want 2", len(parts))
	}
	raw, err := base64.StdEncoding.DecodeString(parts[0])
	if err != nil {
		t.Fatalf("decode tuple: %v", err)
	}
	var tuple map[string]any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&tuple); err != nil {
		t.Fatalf("decode tuple JSON: %v", err)
	}
	mutate(tuple)
	canonical, err := CanonicalJSON(tuple)
	if err != nil {
		t.Fatalf("canonicalize mutated tuple: %v", err)
	}
	return base64.StdEncoding.EncodeToString(canonical) + "." + parts[1]
}

func assertFailoverFixtureChain(t *testing.T, fixtures settlementVerifierFixtures) {
	t.Helper()
	var chain []settlementVerifierTupleFixture
	for _, tuple := range fixtures.ReceiptTuples {
		if settlementTupleString(t, tuple, "request_id") == "req_spec015_v04_chain_0001" {
			chain = append(chain, tuple)
		}
	}
	sort.Slice(chain, func(i, j int) bool {
		return settlementTupleInt(t, chain[i], "attempt_n") < settlementTupleInt(t, chain[j], "attempt_n")
	})
	if len(chain) != 2 {
		t.Fatalf("failover chain tuples=%d want 2", len(chain))
	}
	if settlementTupleInt(t, chain[0], "attempt_n") != 0 || settlementTupleInt(t, chain[1], "attempt_n") != 1 {
		t.Fatalf("failover attempts=(%d,%d), want (0,1)", settlementTupleInt(t, chain[0], "attempt_n"), settlementTupleInt(t, chain[1], "attempt_n"))
	}
	if settlementTupleInt(t, chain[0], "output_prefix_end_byte") != settlementTupleInt(t, chain[1], "output_prefix_start_byte") {
		t.Fatalf("failover ranges are not adjacent: [%d,%d) then [%d,%d)",
			settlementTupleInt(t, chain[0], "output_prefix_start_byte"),
			settlementTupleInt(t, chain[0], "output_prefix_end_byte"),
			settlementTupleInt(t, chain[1], "output_prefix_start_byte"),
			settlementTupleInt(t, chain[1], "output_prefix_end_byte"),
		)
	}
}

func assertRouteSnapshotMutationCoverage(t *testing.T, input SettlementVerifyInput) {
	t.Helper()
	hexA := strings.Repeat("a", 64)
	hexB := strings.Repeat("b", 64)
	keyB := "ed25519-sha256:" + hexB
	sessionID := "session-mutated"
	generationID := "generation-mutated"
	cases := []struct {
		field  string
		reason string
		mutate func(*SettlementVerifyInput)
	}{
		{"account_scope", "account_scope_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.AccountScope = "acct_scope_mutated" }},
		{"request_id", "request_id_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.RequestID = "req_mutated" }},
		{"attempt_n", "attempt_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.AttemptN++ }},
		{"provider_id", "provider_id_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.ProviderID = "provider-mutated" }},
		{"provider_session_id", "route_snapshot_digest_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.ProviderSessionID = &sessionID }},
		{"provider_generation_id", "route_snapshot_digest_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.ProviderGenerationID = &generationID }},
		{"paid_entrypoint", "route_snapshot_digest_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.PaidEntrypoint = "paid-mutated" }},
		{"provider_receipt_key_id", "provider_receipt_key_id_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.ProviderReceiptKeyID = keyB }},
		{"provider_receipt_key_source", "route_snapshot_digest_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.ProviderReceiptKeySource = "rotation_grace" }},
		{"model_id", "route_snapshot_digest_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.ModelID = "model-mutated" }},
		{"provider_reported_model_hash", "route_snapshot_digest_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.ProviderReportedModelHash = hexA }},
		{"expected_catalog_model_hash", "route_snapshot_digest_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.ExpectedCatalogModelHash = hexA }},
		{"catalog_id", "route_snapshot_digest_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.CatalogID = "catalog-mutated" }},
		{"catalog_body_digest", "route_snapshot_digest_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.CatalogBodyDigest = hexA }},
		{"catalog_signature_key_id", "route_snapshot_digest_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.CatalogSignatureKeyID = "catalog-key-mutated" }},
		{"catalog_signature_pubkey_fingerprint", "route_snapshot_digest_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.CatalogSignaturePubkeyFingerprint = keyB }},
		{"catalog_expires_at_unix_ms", "route_snapshot_digest_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.CatalogExpiresAtUnixMS++ }},
		{"spec008_hash_status", "route_snapshot_digest_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.Spec008HashStatus = "mutated" }},
		{"route_snapshot_policy_version", "route_snapshot_digest_mismatch", func(in *SettlementVerifyInput) {
			in.RouteSnapshot.RouteSnapshotPolicyVersion = "spec022-policy-mutated"
		}},
		{"route_snapshot_mode", "route_snapshot_digest_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce }},
		{"route_decision_ts_unix_ms", "route_snapshot_digest_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.RouteDecisionTSUnixMS++ }},
		{"request_start_ts_unix_ms", "route_snapshot_digest_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.RequestStartTSUnixMS++ }},
		{"pending_deadline_seconds", "route_snapshot_digest_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.PendingDeadlineSeconds++ }},
		{"prompt_hash_basis", "route_snapshot_digest_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.PromptHashBasis = "prompt-basis-mutated" }},
		{"prompt_hash", "route_snapshot_digest_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.PromptHash = hexA }},
	}
	for _, tc := range cases {
		t.Run("route_snapshot_"+tc.field, func(t *testing.T) {
			assertSettlementQuarantine(t, input, "AC-47 "+tc.field, tc.mutate, tc.reason)
		})
	}
}

func assertNegativeRangeScenariosBlockSettlement(t *testing.T, fixtures settlementVerifierFixtures, baseInput SettlementVerifyInput, pubkey []byte) {
	t.Helper()
	want := map[string]string{
		"negative_range_overlap":                 "overlapping_ranges",
		"negative_range_duplicate":               "duplicate_ranges",
		"negative_range_out_of_order_by_attempt": "out_of_order_ranges",
	}
	got := map[string]settlementVerifierRangeScenario{}
	for _, scenario := range fixtures.NegativeRangeScenarios {
		got[scenario.ID] = scenario
	}
	for id, failure := range want {
		scenario := got[id]
		if scenario.ID == "" {
			t.Fatalf("missing negative range scenario %s", id)
		}
		if scenario.ExpectedFailure != failure {
			t.Fatalf("%s expected_failure=%s want %s", id, scenario.ExpectedFailure, failure)
		}
		assertRangeScenarioMarkedBlocked(t, scenario, fixtures, baseInput.AccountScope)
	}
	assertPositiveAuthorizationBlockedByOverlapBackfill(t, baseInput, pubkey)
}

func assertRangeScenarioMarkedBlocked(t *testing.T, scenario settlementVerifierRangeScenario, fixtures settlementVerifierFixtures, accountScope string) {
	t.Helper()
	_, store := newRequestAndBillingStores(t)
	tuples := settlementReceiptTuplesByID(fixtures)
	for i, r := range scenario.Ranges {
		tuple := tuples[r.TupleID]
		if tuple.ID == "" {
			t.Fatalf("%s missing tuple %s", scenario.ID, r.TupleID)
		}
		if r.End < r.Start {
			t.Fatalf("%s invalid range [%d,%d)", scenario.ID, r.Start, r.End)
		}
		content := strings.Repeat("x", int(r.End-r.Start))
		if _, err := store.InsertSettlementAttemptOutput(context.Background(), SettlementAttemptOutput{
			AccountScope: accountScope,
			RequestID:    scenario.RequestID,
			AttemptN:     r.Attempt,
			ProviderID:   fmt.Sprintf("%s-range-%d", settlementTupleString(t, tuple, "provider_id"), i),
			Output: SettlementOutput{
				Content:               content,
				Available:             true,
				OutputPrefixStartByte: r.Start,
				OutputPrefixEndByte:   r.End,
				TerminalState:         settlementTupleString(t, tuple, "terminal_state"),
				TerminalStateTSUnixMS: settlementTupleInt(t, tuple, "terminal_state_ts_unix_ms") + int64(i),
			},
			OutputAvailable:       true,
			TerminalStateTSUnixMS: settlementTupleInt(t, tuple, "terminal_state_ts_unix_ms") + int64(i),
			UsageSource:           UsageSourceCoordinatorObserved,
			Usage: SettlementUsage{
				BillableInputTokens:  1,
				BillableOutputTokens: 1,
				DeliveredOutputBytes: r.End - r.Start,
				ObservedInputTokens:  1,
				ObservedOutputTokens: 1,
			},
		}); err != nil {
			t.Fatalf("%s insert range %d: %v", scenario.ID, i, err)
		}
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_attempt_outputs WHERE overlapping_or_duplicate=1`); got != int64(len(scenario.Ranges)) {
		t.Fatalf("%s overlapping_or_duplicate rows=%d want %d", scenario.ID, got, len(scenario.Ranges))
	}
}

func assertPositiveAuthorizationBlockedByOverlapBackfill(t *testing.T, input SettlementVerifyInput, pubkey []byte) {
	t.Helper()
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	setSettlementReceiptNow(store, input.ReceiptReceivedUnixMS)
	id := SettlementReceiptIdentity{
		AccountScope: input.AccountScope,
		RequestID:    input.RequestID,
		AttemptN:     input.AttemptN,
		ProviderID:   input.ProviderID,
	}
	if _, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: id,
		Header:                    input.Header,
		ProviderReceiptPubkey:     pubkey,
		receiptReceivedUnixMS:     input.ReceiptReceivedUnixMS,
	}); err != nil {
		t.Fatal(err)
	}
	auth, found, err := store.GetSettlementReceiptAuthorization(context.Background(), id)
	if err != nil || !found || !auth.PositiveSettlementCandidate {
		t.Fatalf("initial authorization found=%v err=%v auth=%#v, want positive candidate", found, err, auth)
	}
	if _, err := store.db.Exec(`
UPDATE settlement_attempt_outputs
SET overlapping_or_duplicate = 1
WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		input.AccountScope, input.RequestID, input.AttemptN, input.ProviderID,
	); err != nil {
		t.Fatal(err)
	}
	auth, found, err = store.GetSettlementReceiptAuthorization(context.Background(), id)
	if err != nil || !found || auth.PositiveSettlementCandidate || auth.CandidateBlockedReason != "overlapping_or_duplicate_output" {
		t.Fatalf("overlap authorization found=%v err=%v auth=%#v, want blocked overlapping_or_duplicate_output", found, err, auth)
	}
}

func assertReceiptStateRedactionAndDeadline(t *testing.T, input SettlementVerifyInput, pubkey []byte, pubkeyB64 string) {
	t.Helper()
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	setSettlementReceiptNow(store, input.ReceiptReceivedUnixMS)
	id := SettlementReceiptIdentity{
		AccountScope: input.AccountScope,
		RequestID:    input.RequestID,
		AttemptN:     input.AttemptN,
		ProviderID:   input.ProviderID,
	}
	state, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: id,
		Header:                    input.Header,
		ProviderReceiptPubkey:     pubkey,
		receiptReceivedUnixMS:     input.ReceiptReceivedUnixMS,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !state.Closed || state.PendingDeadlineUnixMS != input.deadlineUnixMS() {
		t.Fatalf("state closed/deadline=%v/%d, want closed deadline %d", state.Closed, state.PendingDeadlineUnixMS, input.deadlineUnixMS())
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits`); got != 0 {
		t.Fatalf("ledger_request_credits rows=%d want 0 before SPEC-022", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready`); got != 0 {
		t.Fatalf("ledger_payout_ready rows=%d want 0 before SPEC-022", got)
	}
	drainSettlementReceiptAuditOutboxToBillingAuditLog(t, store, 2)
	assertSettlementReceiptAuditRedacted(t, store.db, input.Header, pubkeyB64)
	assertSettlementReceiptVerdictSchemaRedacted(t, store.db)
}

func assertPhase7ForwardCompatRegression(t *testing.T) {
	t.Helper()
	path := filepath.Join("..", "..", "..", "scripts", "verify-spec015-v04-step8.sh")
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat Step 8 acceptance target: %v", err)
	}
	if info.IsDir() || info.Mode()&0111 == 0 {
		t.Fatalf("%s must be an executable Step 8 acceptance target", path)
	}
}

func assertBuyerDisclosureSurfaces(t *testing.T) {
	t.Helper()
	want := "v0.4 settlement receipts verify the provider-reported request-start model hash against the route-time catalog snapshot"
	root := filepath.Join("..", "..", "..")
	for _, rel := range []string{
		"specs/SPEC-006-buyer-api.md",
		"phase5-gateway/internal/router/disclosure.go",
		"phase5-gateway/internal/router/templates/docs.md",
		"frontdoor/console/index.html",
	} {
		raw, err := os.ReadFile(filepath.Join(root, rel))
		if err != nil {
			t.Fatalf("read %s: %v", rel, err)
		}
		text := string(raw)
		if !strings.Contains(text, want) || !strings.Contains(text, "do not detect a provider falsifying its own loaded-model hash measurement") {
			t.Fatalf("%s missing v0.4 model-verification limit disclosure", rel)
		}
	}
}
