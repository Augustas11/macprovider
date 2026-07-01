package verify

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
	fixtures := loadSettlementFixtures(t)
	pubkey := decodeSettlementPubkey(t, fixtures.ProviderReceiptPubkeyB64)

	for _, tuple := range fixtures.ReceiptTuples {
		input := settlementInputFromFixture(t, fixtures, tuple, pubkey)
		got := VerifySettlementReceipt(input)
		wantOutcome := SettlementOutcomeVerified
		if tupleString(t, tuple, "terminal_state") != "normal_done" && tupleUsageInt(t, tuple, "delivered_output_bytes") == 0 {
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

func TestV03VerifierReportsV04WireReceiptUnknownVersion(t *testing.T) {
	fixtures := loadSettlementFixtures(t)
	if len(fixtures.ReceiptTuples) == 0 {
		t.Fatal("missing v0.4 settlement receipt tuples")
	}
	got, err := Verify(VerifyInput{Header: fixtures.ReceiptTuples[0].WireReceipt}, VerifyOpts{})
	if err != nil {
		t.Fatal(err)
	}
	if got.Result != resultInconclusive || got.Reason != reasonUnknownReceiptVersion || got.ReceiptVersion != "4" {
		t.Fatalf("result=%s reason=%s receipt_version=%s, want inconclusive/%s/4", got.Result, got.Reason, got.ReceiptVersion, reasonUnknownReceiptVersion)
	}
	if got.Details == nil || got.Details.Field != "receipt_version" || got.Details.ReceiptVersion != "4" {
		t.Fatalf("details=%#v, want receipt_version=4", got.Details)
	}
}

func TestVerifySettlementReceiptV04NegativeFixturesQuarantine(t *testing.T) {
	fixtures := loadSettlementFixtures(t)
	pubkey := decodeSettlementPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	byID := receiptTuplesByID(fixtures)

	for _, negative := range fixtures.NegativeReceipts {
		base := byID[negative.BaseTupleID]
		if base.ID == "" {
			t.Fatalf("%s base tuple %q missing", negative.ID, negative.BaseTupleID)
		}
		input := settlementInputFromFixture(t, fixtures, base, pubkey)
		input.Header = negative.WireReceipt
		got := VerifySettlementReceipt(input)
		if got.Outcome != SettlementOutcomeQuarantined {
			t.Fatalf("%s outcome=%s reason=%s, want quarantined", negative.ID, got.Outcome, got.Reason)
		}
		if wantReason := publicSettlementFailureReason(negative.ExpectedFailure); wantReason != "" && got.Reason != wantReason {
			t.Fatalf("%s reason=%s want %s", negative.ID, got.Reason, wantReason)
		}
		if got.ReceiptResult == SettlementReceiptResultValid {
			t.Fatalf("%s receipt_result valid unexpectedly, reason=%s", negative.ID, got.Reason)
		}
	}
}

func TestVerifySettlementReceiptMissingAndTrustRootDeadlineMapping(t *testing.T) {
	fixtures := loadSettlementFixtures(t)
	pubkey := decodeSettlementPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	input := settlementInputFromFixture(t, fixtures, fixtures.ReceiptTuples[0], pubkey)

	input.ReceiptMissing = true
	input.NowUnixMS = input.TerminalStateTSUnixMS + input.RouteSnapshot.PendingDeadlineSeconds*1000 - 1
	got := VerifySettlementReceipt(input)
	if got.Outcome != SettlementOutcomePending {
		t.Fatalf("missing before deadline outcome=%s reason=%s, want pending", got.Outcome, got.Reason)
	}

	input.NowUnixMS = input.TerminalStateTSUnixMS + input.RouteSnapshot.PendingDeadlineSeconds*1000 + 1
	got = VerifySettlementReceipt(input)
	if got.Outcome != SettlementOutcomeQuarantined {
		t.Fatalf("missing after deadline outcome=%s reason=%s, want quarantined", got.Outcome, got.Reason)
	}

	input.ReceiptMissing = false
	input.TrustRootInconclusive = true
	input.NowUnixMS = input.TerminalStateTSUnixMS + input.RouteSnapshot.PendingDeadlineSeconds*1000 - 1
	got = VerifySettlementReceipt(input)
	if got.Outcome != SettlementOutcomePending {
		t.Fatalf("trust root inconclusive outcome=%s reason=%s, want pending", got.Outcome, got.Reason)
	}
}

func TestVerifySettlementReceiptRejectsReplayContext(t *testing.T) {
	fixtures := loadSettlementFixtures(t)
	pubkey := decodeSettlementPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	input := settlementInputFromFixture(t, fixtures, fixtures.ReceiptTuples[1], pubkey)

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
	fixtures := loadSettlementFixtures(t)
	pubkey := decodeSettlementPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	input := settlementInputFromFixture(t, fixtures, fixtures.ReceiptTuples[1], pubkey)

	cases := []struct {
		name   string
		reason string
		mutate func(*SettlementVerifyInput)
	}{
		{"usage-not-cross-checked", "usage_not_cross_checked", func(in *SettlementVerifyInput) { in.UsageCrossChecked = false }},
		{"usage-source", "usage_source_not_settlement_capable", func(in *SettlementVerifyInput) { in.UsageSource = "byte_estimated" }},
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

func TestVerifySettlementReceiptRejectsInvalidRouteSnapshot(t *testing.T) {
	fixtures := loadSettlementFixtures(t)
	pubkey := decodeSettlementPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	input := settlementInputFromFixture(t, fixtures, fixtures.ReceiptTuples[1], pubkey)
	input.RouteSnapshot.CatalogExpiresAtUnixMS = 0

	got := VerifySettlementReceipt(input)
	if got.Outcome != SettlementOutcomeQuarantined || got.Reason != "route_snapshot_invalid" {
		t.Fatalf("outcome=%s reason=%s, want quarantined/route_snapshot_invalid", got.Outcome, got.Reason)
	}
}

func TestVerifySettlementReceiptRejectsOverlongPendingDeadline(t *testing.T) {
	fixtures := loadSettlementFixtures(t)
	pubkey := decodeSettlementPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	input := settlementInputFromFixture(t, fixtures, fixtures.ReceiptTuples[1], pubkey)
	input.RouteSnapshot.PendingDeadlineSeconds = maxPendingReceiptDeadlineSeconds + 1

	got := VerifySettlementReceipt(input)
	if got.Outcome != SettlementOutcomeQuarantined || got.Reason != "route_snapshot_invalid" {
		t.Fatalf("outcome=%s reason=%s, want quarantined/route_snapshot_invalid", got.Outcome, got.Reason)
	}
}

func TestSettlementPartialPrefixAllowsZeroBillableTokens(t *testing.T) {
	tuple := v04SettlementTuple{
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
		Usage: v04SettlementUsage{
			BillableInputTokens:  0,
			BillableOutputTokens: 0,
			DeliveredOutputBytes: 7,
			ObservedInputTokens:  8,
			ObservedOutputTokens: 4,
		},
	}
	if reason := tupleUsageChargeability(tuple); reason != "" {
		t.Fatalf("partial prefix with zero billable tokens reason=%s, want accepted", reason)
	}
}

func TestVerifySettlementReceiptUnknownFutureVersionNotPayable(t *testing.T) {
	fixtures := loadSettlementFixtures(t)
	pubkey := decodeSettlementPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	input := settlementInputFromFixture(t, fixtures, fixtures.ReceiptTuples[1], pubkey)
	input.Header = receiptHeaderWithVersion(t, input.Header, "10")

	got := VerifySettlementReceipt(input)
	if got.Outcome != SettlementOutcomeQuarantined || got.ReceiptResult != SettlementReceiptResultInconclusive || got.Reason != "unknown_receipt_version" {
		t.Fatalf("unknown future outcome=%s/%s reason=%s, want quarantined/inconclusive unknown_receipt_version", got.Outcome, got.ReceiptResult, got.Reason)
	}
}

type settlementFixtures struct {
	ProviderReceiptPubkeyB64 string                    `json:"provider_receipt_pubkey_b64"`
	ProviderReceiptKeyID     string                    `json:"provider_receipt_key_id"`
	Objects                  []settlementObjectFixture `json:"objects"`
	ReceiptTuples            []settlementTupleFixture  `json:"receipt_tuples"`
	NegativeReceipts         []settlementTupleFixture  `json:"negative_receipts"`
}

type settlementObjectFixture struct {
	ID                string         `json:"id"`
	Kind              string         `json:"kind"`
	Value             map[string]any `json:"value"`
	ExpectedSHA256Hex string         `json:"expected_sha256_hex"`
}

type settlementTupleFixture struct {
	ID                 string         `json:"id"`
	BaseTupleID        string         `json:"base_tuple_id"`
	RouteSnapshotID    string         `json:"route_snapshot_id"`
	SettlementOutputID string         `json:"settlement_output_id"`
	ExpectedFailure    string         `json:"expected_failure"`
	Value              map[string]any `json:"value"`
	WireReceipt        string         `json:"wire_receipt"`
}

func settlementInputFromFixture(t *testing.T, fixtures settlementFixtures, tuple settlementTupleFixture, pubkey []byte) SettlementVerifyInput {
	t.Helper()
	objects := settlementObjectsByID(fixtures)
	routeObject := objects[tuple.RouteSnapshotID]
	outputObject := objects[tuple.SettlementOutputID]
	if routeObject.ID == "" || outputObject.ID == "" {
		t.Fatalf("%s route/output fixture missing", tuple.ID)
	}
	route := routeSnapshotFromFixture(t, routeObject.Value)
	terminalTS := tupleInt(t, tuple, "terminal_state_ts_unix_ms")
	return SettlementVerifyInput{
		Header:                   tuple.WireReceipt,
		ProviderReceiptPubkey:    pubkey,
		RouteSnapshot:            route,
		AccountScope:             tupleString(t, tuple, "account_scope"),
		RequestID:                tupleString(t, tuple, "request_id"),
		AttemptN:                 tupleInt(t, tuple, "attempt_n"),
		ProviderID:               tupleString(t, tuple, "provider_id"),
		ProviderReceiptKeyID:     tupleString(t, tuple, "provider_receipt_key_id"),
		TerminalState:            tupleString(t, tuple, "terminal_state"),
		TerminalStateTSUnixMS:    terminalTS,
		OutputHash:               outputObject.ExpectedSHA256Hex,
		OutputPrefixStartByte:    tupleInt(t, tuple, "output_prefix_start_byte"),
		OutputPrefixEndByte:      tupleInt(t, tuple, "output_prefix_end_byte"),
		ExpectedUsage:            settlementUsageEvidenceFromTuple(t, tuple),
		UsageSource:              "coordinator_observed",
		UsageCrossChecked:        true,
		ReceiptReceivedUnixMS:    terminalTS + 250,
		NowUnixMS:                terminalTS + 250,
		CanonicalHashesAvailable: true,
	}
}

func routeSnapshotFromFixture(t *testing.T, value map[string]any) SettlementRouteSnapshot {
	t.Helper()
	return SettlementRouteSnapshot{
		AccountScope:                      fixtureString(t, value, "account_scope"),
		RequestID:                         fixtureString(t, value, "request_id"),
		AttemptN:                          fixtureInt(t, value, "attempt_n"),
		ProviderID:                        fixtureString(t, value, "provider_id"),
		ProviderSessionID:                 fixtureNullableString(t, value, "provider_session_id"),
		ProviderGenerationID:              fixtureNullableString(t, value, "provider_generation_id"),
		PaidEntrypoint:                    fixtureString(t, value, "paid_entrypoint"),
		ProviderReceiptKeyID:              fixtureString(t, value, "provider_receipt_key_id"),
		ProviderReceiptKeySource:          fixtureString(t, value, "provider_receipt_key_source"),
		ModelID:                           fixtureString(t, value, "model_id"),
		ProviderReportedModelHash:         fixtureString(t, value, "provider_reported_model_hash"),
		ExpectedCatalogModelHash:          fixtureString(t, value, "expected_catalog_model_hash"),
		CatalogID:                         fixtureString(t, value, "catalog_id"),
		CatalogBodyDigest:                 fixtureString(t, value, "catalog_body_digest"),
		CatalogSignatureKeyID:             fixtureString(t, value, "catalog_signature_key_id"),
		CatalogSignaturePubkeyFingerprint: fixtureString(t, value, "catalog_signature_pubkey_fingerprint"),
		CatalogExpiresAtUnixMS:            fixtureInt(t, value, "catalog_expires_at_unix_ms"),
		Spec008HashStatus:                 fixtureString(t, value, "spec008_hash_status"),
		RouteSnapshotPolicyVersion:        fixtureString(t, value, "route_snapshot_policy_version"),
		RouteSnapshotMode:                 fixtureString(t, value, "route_snapshot_mode"),
		RouteDecisionTSUnixMS:             fixtureInt(t, value, "route_decision_ts_unix_ms"),
		RequestStartTSUnixMS:              fixtureInt(t, value, "request_start_ts_unix_ms"),
		PendingDeadlineSeconds:            fixtureInt(t, value, "pending_deadline_seconds"),
		PromptHashBasis:                   fixtureString(t, value, "prompt_hash_basis"),
		PromptHash:                        fixtureString(t, value, "prompt_hash"),
	}
}

func fixtureNullableString(t *testing.T, value map[string]any, key string) *string {
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

func loadSettlementFixtures(t *testing.T) settlementFixtures {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "testdata", "spec015", "v04_settlement_receipts.json"))
	if err != nil {
		t.Fatalf("read fixtures: %v", err)
	}
	var fixtures settlementFixtures
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&fixtures); err != nil {
		t.Fatalf("decode fixtures: %v", err)
	}
	return fixtures
}

func settlementObjectsByID(fixtures settlementFixtures) map[string]settlementObjectFixture {
	out := make(map[string]settlementObjectFixture, len(fixtures.Objects))
	for _, object := range fixtures.Objects {
		out[object.ID] = object
	}
	return out
}

func receiptTuplesByID(fixtures settlementFixtures) map[string]settlementTupleFixture {
	out := make(map[string]settlementTupleFixture, len(fixtures.ReceiptTuples))
	for _, tuple := range fixtures.ReceiptTuples {
		out[tuple.ID] = tuple
	}
	return out
}

func decodeSettlementPubkey(t *testing.T, raw string) []byte {
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

func tupleString(t *testing.T, tuple settlementTupleFixture, key string) string {
	t.Helper()
	return fixtureString(t, tuple.Value, key)
}

func tupleInt(t *testing.T, tuple settlementTupleFixture, key string) int64 {
	t.Helper()
	return fixtureInt(t, tuple.Value, key)
}

func tupleUsageInt(t *testing.T, tuple settlementTupleFixture, key string) int64 {
	t.Helper()
	usage, ok := tuple.Value["usage"].(map[string]any)
	if !ok {
		t.Fatalf("%s usage=%#v, want object", tuple.ID, tuple.Value["usage"])
	}
	return fixtureInt(t, usage, key)
}

func settlementUsageEvidenceFromTuple(t *testing.T, tuple settlementTupleFixture) SettlementUsageEvidence {
	t.Helper()
	return SettlementUsageEvidence{
		BillableInputTokens:  tupleUsageInt(t, tuple, "billable_input_tokens"),
		BillableOutputTokens: tupleUsageInt(t, tuple, "billable_output_tokens"),
		DeliveredOutputBytes: tupleUsageInt(t, tuple, "delivered_output_bytes"),
		ObservedInputTokens:  tupleUsageInt(t, tuple, "observed_input_tokens"),
		ObservedOutputTokens: tupleUsageInt(t, tuple, "observed_output_tokens"),
	}
}

func settlementUsageDigestFromTuple(t *testing.T, tuple settlementTupleFixture) string {
	t.Helper()
	digest, err := settlementUsageDigest(v04SettlementUsage{
		BillableInputTokens:  tupleUsageInt(t, tuple, "billable_input_tokens"),
		BillableOutputTokens: tupleUsageInt(t, tuple, "billable_output_tokens"),
		DeliveredOutputBytes: tupleUsageInt(t, tuple, "delivered_output_bytes"),
		ObservedInputTokens:  tupleUsageInt(t, tuple, "observed_input_tokens"),
		ObservedOutputTokens: tupleUsageInt(t, tuple, "observed_output_tokens"),
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

func fixtureString(t *testing.T, value map[string]any, key string) string {
	t.Helper()
	got, ok := value[key].(string)
	if !ok {
		t.Fatalf("%s=%#v, want string", key, value[key])
	}
	return got
}

func fixtureInt(t *testing.T, value map[string]any, key string) int64 {
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

func receiptHeaderWithVersion(t *testing.T, header, version string) string {
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

func TestSettlementReceiptKeyIDFixture(t *testing.T) {
	fixtures := loadSettlementFixtures(t)
	pubkey := decodeSettlementPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	sum := sha256.Sum256(pubkey)
	want := "ed25519-sha256:" + hex.EncodeToString(sum[:])
	if got := settlementReceiptKeyID(pubkey); got != want || got != fixtures.ProviderReceiptKeyID {
		t.Fatalf("key id=%s fixture=%s want=%s", got, fixtures.ProviderReceiptKeyID, want)
	}
}
