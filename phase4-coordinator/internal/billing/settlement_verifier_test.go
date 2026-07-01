package billing

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestVerifySettlementReceiptV04Fixtures(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	for _, tuple := range fixtures.ReceiptTuples {
		input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
		got := VerifySettlementReceipt(input)
		wantOutcome := SettlementOutcomeVerified
		if settlementTupleString(t, tuple, "terminal_state") != "normal_done" && settlementTupleUsageInt(t, tuple, "delivered_output_bytes") == 0 {
			wantOutcome = SettlementOutcomeZeroSettled
		}
		if got.Outcome != wantOutcome || got.ReceiptResult != SettlementReceiptResultValid {
			t.Fatalf("%s outcome=%s/%s reason=%s, want %s/%s", tuple.ID, got.Outcome, got.ReceiptResult, got.Reason, wantOutcome, SettlementReceiptResultValid)
		}
		wantUsageDigest := settlementUsageDigestFromTuple(t, tuple)
		if got.Facts == nil || got.Facts.UsageDigest != wantUsageDigest {
			t.Fatalf("%s usage_digest=%v want %s", tuple.ID, got.Facts, wantUsageDigest)
		}
		if !got.Checks.SignatureVerified || !got.Checks.RouteSnapshotMatched || !got.Checks.PromptHashMatched ||
			!got.Checks.OutputHashMatched || !got.Checks.UsageMatched || !got.Checks.UsageCrossChecked ||
			!got.Checks.NoOverlap || !got.Checks.TerminalStateMatched || !got.Checks.TimestampWindowValid {
			t.Fatalf("%s checks not fully satisfied: %#v", tuple.ID, got.Checks)
		}
	}
}

func TestVerifySettlementReceiptV04NegativeFixturesQuarantine(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	byID := settlementReceiptTuplesByID(fixtures)
	for _, negative := range fixtures.NegativeReceipts {
		base := byID[negative.BaseTupleID]
		if base.ID == "" {
			t.Fatalf("%s missing base tuple %q", negative.ID, negative.BaseTupleID)
		}
		input := settlementVerifierInputFromFixture(t, fixtures, base, pubkey)
		input.Header = negative.WireReceipt
		got := VerifySettlementReceipt(input)
		if got.Outcome != SettlementOutcomeQuarantined {
			t.Fatalf("%s outcome=%s reason=%s, want quarantined", negative.ID, got.Outcome, got.Reason)
		}
		if wantReason := publicSettlementFailureReason(negative.ExpectedFailure); wantReason != "" && got.Reason != wantReason {
			t.Fatalf("%s reason=%s want %s", negative.ID, got.Reason, wantReason)
		}
		if got.ReceiptResult == SettlementReceiptResultValid {
			t.Fatalf("%s receipt_result valid unexpectedly", negative.ID)
		}
	}
}

func TestVerifySettlementReceiptDeadlineAndReplayMapping(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	input := settlementVerifierInputFromFixture(t, fixtures, fixtures.ReceiptTuples[1], pubkey)

	input.ReceiptMissing = true
	input.NowUnixMS = input.deadlineUnixMS() - 1
	if got := VerifySettlementReceipt(input); got.Outcome != SettlementOutcomePending {
		t.Fatalf("missing before deadline outcome=%s reason=%s, want pending", got.Outcome, got.Reason)
	}
	input.NowUnixMS = input.deadlineUnixMS() + 1
	if got := VerifySettlementReceipt(input); got.Outcome != SettlementOutcomeQuarantined {
		t.Fatalf("missing after deadline outcome=%s reason=%s, want quarantined", got.Outcome, got.Reason)
	}

	input = settlementVerifierInputFromFixture(t, fixtures, fixtures.ReceiptTuples[1], pubkey)
	cases := []struct {
		name   string
		reason string
		mutate func(*SettlementVerifyInput)
	}{
		{"account", "account_scope_mismatch", func(in *SettlementVerifyInput) { in.AccountScope = "acct_scope_replay" }},
		{"request", "request_id_mismatch", func(in *SettlementVerifyInput) { in.RequestID = "req_replay" }},
		{"attempt", "attempt_mismatch", func(in *SettlementVerifyInput) { in.AttemptN++ }},
		{"provider", "provider_id_mismatch", func(in *SettlementVerifyInput) { in.ProviderID = "provider-replay" }},
		{"key", "provider_receipt_key_id_mismatch", func(in *SettlementVerifyInput) {
			in.ProviderReceiptKeyID = "ed25519-sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		}},
		{"route-mode", "route_snapshot_digest_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.RouteSnapshotMode = "enforce" }},
		{"route-policy", "route_snapshot_digest_mismatch", func(in *SettlementVerifyInput) { in.RouteSnapshot.RouteSnapshotPolicyVersion = "spec022-policy-v2" }},
		{"terminal", "terminal_state_mismatch", func(in *SettlementVerifyInput) { in.TerminalState = "provider_error" }},
		{"terminal-ts", "terminal_state_timestamp_mismatch", func(in *SettlementVerifyInput) { in.TerminalStateTSUnixMS++ }},
		{"issued-window", "issued_at_window_mismatch", func(in *SettlementVerifyInput) {
			in.ReceiptReceivedUnixMS -= 120000
			in.NowUnixMS = in.ReceiptReceivedUnixMS
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			candidate := input
			tc.mutate(&candidate)
			got := VerifySettlementReceipt(candidate)
			if got.Outcome != SettlementOutcomeQuarantined || got.Reason != tc.reason {
				t.Fatalf("outcome=%s reason=%s, want quarantined/%s", got.Outcome, got.Reason, tc.reason)
			}
		})
	}
}

func TestVerifySettlementReceiptRequiresLedgerUsageAndOutputState(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	input := settlementVerifierInputFromFixture(t, fixtures, fixtures.ReceiptTuples[1], pubkey)

	cases := []struct {
		name   string
		reason string
		mutate func(*SettlementVerifyInput)
	}{
		{"usage-not-cross-checked", "usage_not_cross_checked", func(in *SettlementVerifyInput) { in.UsageCrossChecked = false }},
		{"usage-source", "usage_source_not_settlement_capable", func(in *SettlementVerifyInput) { in.UsageSource = UsageSourceByteEstimated }},
		{"usage-mismatch", "usage_mismatch", func(in *SettlementVerifyInput) { in.ExpectedUsage.ObservedOutputTokens++ }},
		{"overlap", "overlapping_output_prefix", func(in *SettlementVerifyInput) { in.OverlappingOrDuplicate = true }},
		{"terminal-final", "duplicate_receipt_after_terminal", func(in *SettlementVerifyInput) { in.TerminalOutcomeFinal = true }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			candidate := input
			tc.mutate(&candidate)
			got := VerifySettlementReceipt(candidate)
			if got.Outcome != SettlementOutcomeQuarantined || got.Reason != tc.reason {
				t.Fatalf("outcome=%s reason=%s, want quarantined/%s", got.Outcome, got.Reason, tc.reason)
			}
			if tc.reason == "usage_mismatch" {
				wantUsageDigest := settlementUsageDigestFromTuple(t, fixtures.ReceiptTuples[1])
				if got.Facts == nil || got.Facts.UsageDigest != wantUsageDigest {
					t.Fatalf("usage mismatch facts=%#v want digest %s", got.Facts, wantUsageDigest)
				}
				if !got.Checks.SignatureVerified || !got.Checks.RouteSnapshotMatched || !got.Checks.PromptHashMatched ||
					!got.Checks.OutputHashMatched || !got.Checks.TerminalStateMatched || !got.Checks.TimestampWindowValid ||
					!got.Checks.UsageCrossChecked || got.Checks.UsageMatched {
					t.Fatalf("usage mismatch checks=%#v, want all prior gates and cross-check true, usage matched false", got.Checks)
				}
			}
		})
	}
}

func TestVerifySettlementReceiptRejectsByteEstimatedCoordinatorRows(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	input := settlementVerifierInputFromFixture(t, fixtures, fixtures.ReceiptTuples[1], pubkey)
	input.UsageSource = UsageSourceByteEstimated

	got := VerifySettlementReceipt(input)
	if got.Outcome != SettlementOutcomeQuarantined || got.Reason != "usage_source_not_settlement_capable" {
		t.Fatalf("outcome=%s reason=%s, want quarantined/usage_source_not_settlement_capable", got.Outcome, got.Reason)
	}
	if got.Checks.UsageCrossChecked || got.Checks.UsageMatched {
		t.Fatalf("byte-estimated row became settlement-capable: %#v", got.Checks)
	}
}

func TestVerifySettlementReceiptAcceptsCoordinatorObservedAttemptOutputRow(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := fixtures.ReceiptTuples[1]
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	_, store := newRequestAndBillingStores(t)
	usageHash, usageCanonical, err := input.ExpectedUsage.Digest()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`
INSERT INTO settlement_attempt_outputs (
    account_scope, request_id, attempt_n, provider_id, terminal_state, terminal_state_ts_unix_ms,
    output_available, output_prefix_start_byte, output_prefix_end_byte,
    output_hash, usage_hash, usage_canonical_json, usage_source,
    overlapping_or_duplicate, created_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		input.AccountScope, input.RequestID, input.AttemptN, input.ProviderID, input.TerminalState, input.TerminalStateTSUnixMS,
		1, input.OutputPrefixStartByte, input.OutputPrefixEndByte,
		input.OutputHash, usageHash, string(usageCanonical), UsageSourceCoordinatorObserved,
		0, "2026-01-01T00:00:00Z",
	); err != nil {
		t.Fatal(err)
	}

	rowInput := input
	var usageCanonicalJSON string
	var overlap int
	if err := store.db.QueryRow(`
SELECT terminal_state, terminal_state_ts_unix_ms, output_prefix_start_byte,
       output_prefix_end_byte, output_hash, usage_canonical_json, usage_source,
       overlapping_or_duplicate
FROM settlement_attempt_outputs
WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		input.AccountScope, input.RequestID, input.AttemptN, input.ProviderID,
	).Scan(
		&rowInput.TerminalState,
		&rowInput.TerminalStateTSUnixMS,
		&rowInput.OutputPrefixStartByte,
		&rowInput.OutputPrefixEndByte,
		&rowInput.OutputHash,
		&usageCanonicalJSON,
		&rowInput.UsageSource,
		&overlap,
	); err != nil {
		t.Fatal(err)
	}
	var usage settlementUsageV04
	if err := json.Unmarshal([]byte(usageCanonicalJSON), &usage); err != nil {
		t.Fatal(err)
	}
	rowInput.ExpectedUsage = SettlementUsage{
		BillableInputTokens:  usage.BillableInputTokens,
		BillableOutputTokens: usage.BillableOutputTokens,
		DeliveredOutputBytes: usage.DeliveredOutputBytes,
		ObservedInputTokens:  usage.ObservedInputTokens,
		ObservedOutputTokens: usage.ObservedOutputTokens,
	}
	rowInput.OverlappingOrDuplicate = overlap != 0
	rowInput.UsageCrossChecked = rowInput.UsageSource == UsageSourceCoordinatorObserved

	got := VerifySettlementReceipt(rowInput)
	if got.Outcome != SettlementOutcomeVerified || got.ReceiptResult != SettlementReceiptResultValid {
		t.Fatalf("outcome=%s/%s reason=%s, want verified/valid", got.Outcome, got.ReceiptResult, got.Reason)
	}
}

func TestSettlementPartialPrefixAllowsZeroBillableTokens(t *testing.T) {
	tuple := settlementTupleV04{
		TerminalState:              "provider_error",
		OutputPrefixStartByte:      0,
		OutputPrefixEndByte:        7,
		TerminalStateTSUnixMS:      1782864001789,
		IssuedAtUnixMS:             1782864001999,
		ReceiptVersion:             "4",
		ProviderReceiptKeyID:       "ed25519-sha256:" + strings.Repeat("a", 64),
		SignatureKeyAlg:            "Ed25519",
		AccountScope:               "acct",
		RequestID:                  "req",
		ProviderID:                 "provider",
		ModelID:                    "model",
		ModelHash:                  strings.Repeat("1", 64),
		ExpectedCatalogModelHash:   strings.Repeat("1", 64),
		CatalogID:                  "catalog",
		CatalogBodyDigest:          strings.Repeat("2", 64),
		PromptHash:                 strings.Repeat("3", 64),
		OutputHash:                 strings.Repeat("4", 64),
		RouteSnapshotDigest:        strings.Repeat("5", 64),
		RouteSnapshotMode:          "observe",
		RouteSnapshotPolicyVersion: "spec022-policy-v1",
		Usage: settlementUsageV04{
			BillableInputTokens:  0,
			BillableOutputTokens: 0,
			DeliveredOutputBytes: 7,
			ObservedInputTokens:  8,
			ObservedOutputTokens: 4,
		},
	}
	if reason := tupleSettlementUsage(tuple); reason != "" {
		t.Fatalf("partial prefix with zero billable tokens reason=%s, want accepted", reason)
	}
}

func TestVerifySettlementReceiptUnknownFutureVersionNotPayable(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	input := settlementVerifierInputFromFixture(t, fixtures, fixtures.ReceiptTuples[1], pubkey)
	input.Header = settlementHeaderWithVersion(t, input.Header, "10")
	got := VerifySettlementReceipt(input)
	if got.Outcome != SettlementOutcomeQuarantined || got.ReceiptResult != SettlementReceiptResultInconclusive || got.Reason != "unknown_receipt_version" {
		t.Fatalf("unknown future outcome=%s/%s reason=%s, want quarantined/inconclusive unknown_receipt_version", got.Outcome, got.ReceiptResult, got.Reason)
	}
}

func TestSettlementVerifierReceiptKeyIDFixture(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	sum := sha256.Sum256(pubkey)
	want := "ed25519-sha256:" + hex.EncodeToString(sum[:])
	got, err := ReceiptKeyID(pubkey)
	if err != nil {
		t.Fatalf("ReceiptKeyID: %v", err)
	}
	if got != want || got != fixtures.ProviderReceiptKeyID {
		t.Fatalf("key id=%s fixture=%s want=%s", got, fixtures.ProviderReceiptKeyID, want)
	}
}

type settlementVerifierFixtures struct {
	ProviderReceiptPubkeyB64 string                            `json:"provider_receipt_pubkey_b64"`
	ProviderReceiptKeyID     string                            `json:"provider_receipt_key_id"`
	Objects                  []settlementVerifierObjectFixture `json:"objects"`
	ReceiptTuples            []settlementVerifierTupleFixture  `json:"receipt_tuples"`
	NegativeReceipts         []settlementVerifierTupleFixture  `json:"negative_receipts"`
	NegativeRangeScenarios   []settlementVerifierRangeScenario `json:"negative_range_scenarios"`
}

type settlementVerifierObjectFixture struct {
	ID                string         `json:"id"`
	Kind              string         `json:"kind"`
	Value             map[string]any `json:"value"`
	ExpectedSHA256Hex string         `json:"expected_sha256_hex"`
}

type settlementVerifierTupleFixture struct {
	ID                 string         `json:"id"`
	BaseTupleID        string         `json:"base_tuple_id"`
	RouteSnapshotID    string         `json:"route_snapshot_id"`
	SettlementOutputID string         `json:"settlement_output_id"`
	ExpectedFailure    string         `json:"expected_failure"`
	Value              map[string]any `json:"value"`
	WireReceipt        string         `json:"wire_receipt"`
}

type settlementVerifierRangeScenario struct {
	ID              string                           `json:"id"`
	RequestID       string                           `json:"request_id"`
	ExpectedFailure string                           `json:"expected_failure"`
	Ranges          []settlementVerifierRangeFixture `json:"ranges"`
}

type settlementVerifierRangeFixture struct {
	TupleID string `json:"tuple_id"`
	Attempt int64  `json:"attempt_n"`
	Start   int64  `json:"output_prefix_start_byte"`
	End     int64  `json:"output_prefix_end_byte"`
}

func settlementVerifierInputFromFixture(t *testing.T, fixtures settlementVerifierFixtures, tuple settlementVerifierTupleFixture, pubkey []byte) SettlementVerifyInput {
	t.Helper()
	objects := settlementVerifierObjectsByID(fixtures)
	routeObject := objects[tuple.RouteSnapshotID]
	outputObject := objects[tuple.SettlementOutputID]
	if routeObject.ID == "" || outputObject.ID == "" {
		t.Fatalf("%s route/output fixture missing", tuple.ID)
	}
	terminalTS := settlementTupleInt(t, tuple, "terminal_state_ts_unix_ms")
	return SettlementVerifyInput{
		Header:                   tuple.WireReceipt,
		ProviderReceiptPubkey:    pubkey,
		RouteSnapshot:            settlementRouteSnapshotFromFixture(t, routeObject.Value),
		AccountScope:             settlementTupleString(t, tuple, "account_scope"),
		RequestID:                settlementTupleString(t, tuple, "request_id"),
		AttemptN:                 settlementTupleInt(t, tuple, "attempt_n"),
		ProviderID:               settlementTupleString(t, tuple, "provider_id"),
		ProviderReceiptKeyID:     settlementTupleString(t, tuple, "provider_receipt_key_id"),
		TerminalState:            settlementTupleString(t, tuple, "terminal_state"),
		TerminalStateTSUnixMS:    terminalTS,
		OutputHash:               outputObject.ExpectedSHA256Hex,
		OutputPrefixStartByte:    settlementTupleInt(t, tuple, "output_prefix_start_byte"),
		OutputPrefixEndByte:      settlementTupleInt(t, tuple, "output_prefix_end_byte"),
		ExpectedUsage:            settlementUsageFromTuple(t, tuple),
		UsageSource:              UsageSourceCoordinatorObserved,
		UsageCrossChecked:        true,
		ReceiptReceivedUnixMS:    terminalTS + 250,
		NowUnixMS:                terminalTS + 250,
		CanonicalHashesAvailable: true,
	}
}

func settlementRouteSnapshotFromFixture(t *testing.T, value map[string]any) RouteSnapshot {
	t.Helper()
	return RouteSnapshot{
		AccountScope:                      settlementFixtureString(t, value, "account_scope"),
		RequestID:                         settlementFixtureString(t, value, "request_id"),
		AttemptN:                          settlementFixtureInt(t, value, "attempt_n"),
		ProviderID:                        settlementFixtureString(t, value, "provider_id"),
		ProviderSessionID:                 settlementFixtureNullableString(t, value, "provider_session_id"),
		ProviderGenerationID:              settlementFixtureNullableString(t, value, "provider_generation_id"),
		PaidEntrypoint:                    settlementFixtureString(t, value, "paid_entrypoint"),
		ProviderReceiptKeyID:              settlementFixtureString(t, value, "provider_receipt_key_id"),
		ProviderReceiptKeySource:          settlementFixtureString(t, value, "provider_receipt_key_source"),
		ModelID:                           settlementFixtureString(t, value, "model_id"),
		ProviderReportedModelHash:         settlementFixtureString(t, value, "provider_reported_model_hash"),
		ExpectedCatalogModelHash:          settlementFixtureString(t, value, "expected_catalog_model_hash"),
		CatalogID:                         settlementFixtureString(t, value, "catalog_id"),
		CatalogBodyDigest:                 settlementFixtureString(t, value, "catalog_body_digest"),
		CatalogSignatureKeyID:             settlementFixtureString(t, value, "catalog_signature_key_id"),
		CatalogSignaturePubkeyFingerprint: settlementFixtureString(t, value, "catalog_signature_pubkey_fingerprint"),
		CatalogExpiresAtUnixMS:            settlementFixtureInt(t, value, "catalog_expires_at_unix_ms"),
		Spec008HashStatus:                 settlementFixtureString(t, value, "spec008_hash_status"),
		RouteSnapshotPolicyVersion:        settlementFixtureString(t, value, "route_snapshot_policy_version"),
		RouteSnapshotMode:                 settlementFixtureString(t, value, "route_snapshot_mode"),
		RouteDecisionTSUnixMS:             settlementFixtureInt(t, value, "route_decision_ts_unix_ms"),
		RequestStartTSUnixMS:              settlementFixtureInt(t, value, "request_start_ts_unix_ms"),
		PendingDeadlineSeconds:            settlementFixtureInt(t, value, "pending_deadline_seconds"),
		PromptHashBasis:                   settlementFixtureString(t, value, "prompt_hash_basis"),
		PromptHash:                        settlementFixtureString(t, value, "prompt_hash"),
	}
}

func loadSettlementVerifierFixtures(t *testing.T) settlementVerifierFixtures {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "testdata", "spec015", "v04_settlement_receipts.json"))
	if err != nil {
		t.Fatalf("read fixtures: %v", err)
	}
	var fixtures settlementVerifierFixtures
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&fixtures); err != nil {
		t.Fatalf("decode fixtures: %v", err)
	}
	return fixtures
}

func settlementVerifierObjectsByID(fixtures settlementVerifierFixtures) map[string]settlementVerifierObjectFixture {
	out := make(map[string]settlementVerifierObjectFixture, len(fixtures.Objects))
	for _, object := range fixtures.Objects {
		out[object.ID] = object
	}
	return out
}

func settlementReceiptTuplesByID(fixtures settlementVerifierFixtures) map[string]settlementVerifierTupleFixture {
	out := make(map[string]settlementVerifierTupleFixture, len(fixtures.ReceiptTuples))
	for _, tuple := range fixtures.ReceiptTuples {
		out[tuple.ID] = tuple
	}
	return out
}

func decodeSettlementVerifierPubkey(t *testing.T, raw string) []byte {
	t.Helper()
	pubkey, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		t.Fatalf("decode pubkey: %v", err)
	}
	if len(pubkey) != ed25519.PublicKeySize {
		t.Fatalf("pubkey length=%d want %d", len(pubkey), ed25519.PublicKeySize)
	}
	return pubkey
}

func settlementTupleString(t *testing.T, tuple settlementVerifierTupleFixture, key string) string {
	t.Helper()
	return settlementFixtureString(t, tuple.Value, key)
}

func settlementTupleInt(t *testing.T, tuple settlementVerifierTupleFixture, key string) int64 {
	t.Helper()
	return settlementFixtureInt(t, tuple.Value, key)
}

func settlementTupleUsageInt(t *testing.T, tuple settlementVerifierTupleFixture, key string) int64 {
	t.Helper()
	usage, ok := tuple.Value["usage"].(map[string]any)
	if !ok {
		t.Fatalf("%s usage=%#v, want object", tuple.ID, tuple.Value["usage"])
	}
	return settlementFixtureInt(t, usage, key)
}

func settlementUsageFromTuple(t *testing.T, tuple settlementVerifierTupleFixture) SettlementUsage {
	t.Helper()
	return SettlementUsage{
		BillableInputTokens:  settlementTupleUsageInt(t, tuple, "billable_input_tokens"),
		BillableOutputTokens: settlementTupleUsageInt(t, tuple, "billable_output_tokens"),
		DeliveredOutputBytes: settlementTupleUsageInt(t, tuple, "delivered_output_bytes"),
		ObservedInputTokens:  settlementTupleUsageInt(t, tuple, "observed_input_tokens"),
		ObservedOutputTokens: settlementTupleUsageInt(t, tuple, "observed_output_tokens"),
	}
}

func settlementUsageDigestFromTuple(t *testing.T, tuple settlementVerifierTupleFixture) string {
	t.Helper()
	digest, _, err := CanonicalSHA256Hex(map[string]any{
		"billable_input_tokens":  settlementTupleUsageInt(t, tuple, "billable_input_tokens"),
		"billable_output_tokens": settlementTupleUsageInt(t, tuple, "billable_output_tokens"),
		"delivered_output_bytes": settlementTupleUsageInt(t, tuple, "delivered_output_bytes"),
		"observed_input_tokens":  settlementTupleUsageInt(t, tuple, "observed_input_tokens"),
		"observed_output_tokens": settlementTupleUsageInt(t, tuple, "observed_output_tokens"),
	})
	if err != nil {
		t.Fatalf("usage digest: %v", err)
	}
	return digest
}

func publicSettlementFailureReason(expected string) string {
	switch expected {
	case "wrong_key_signature":
		return "signature_verify_failed"
	case "legacy_receipt_version":
		return "not_settlement_capable"
	case "strict_shape_missing_output_hash", "strict_shape_extra_top_level_field":
		return "tuple_shape_invalid"
	case "usage_null", "usage_missing_required_field", "usage_extra_field":
		return "usage_shape_invalid"
	default:
		return expected
	}
}

func settlementFixtureString(t *testing.T, value map[string]any, key string) string {
	t.Helper()
	got, ok := value[key].(string)
	if !ok {
		t.Fatalf("%s=%#v, want string", key, value[key])
	}
	return got
}

func settlementFixtureNullableString(t *testing.T, value map[string]any, key string) *string {
	t.Helper()
	raw, ok := value[key]
	if !ok {
		t.Fatalf("%s missing", key)
	}
	if raw == nil {
		return nil
	}
	s, ok := raw.(string)
	if !ok {
		t.Fatalf("%s=%#v, want string or null", key, raw)
	}
	return &s
}

func settlementFixtureInt(t *testing.T, value map[string]any, key string) int64 {
	t.Helper()
	number, ok := value[key].(json.Number)
	if !ok {
		t.Fatalf("%s=%#v, want json.Number", key, value[key])
	}
	out, err := number.Int64()
	if err != nil {
		t.Fatalf("%s parse: %v", key, err)
	}
	return out
}

func settlementHeaderWithVersion(t *testing.T, header, version string) string {
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
	tuple["receipt_version"] = version
	changed, err := json.Marshal(tuple)
	if err != nil {
		t.Fatalf("marshal changed tuple: %v", err)
	}
	return base64.StdEncoding.EncodeToString(changed) + "." + parts[1]
}
