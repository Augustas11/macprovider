package jcs

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"

	"golang.org/x/text/unicode/norm"
)

var (
	routeSnapshotKeysV04 = []string{
		"account_scope",
		"attempt_n",
		"catalog_body_digest",
		"catalog_expires_at_unix_ms",
		"catalog_id",
		"catalog_signature_key_id",
		"catalog_signature_pubkey_fingerprint",
		"expected_catalog_model_hash",
		"model_id",
		"paid_entrypoint",
		"pending_deadline_seconds",
		"prompt_hash",
		"prompt_hash_basis",
		"provider_generation_id",
		"provider_id",
		"provider_receipt_key_id",
		"provider_receipt_key_source",
		"provider_reported_model_hash",
		"provider_session_id",
		"request_id",
		"request_start_ts_unix_ms",
		"route_decision_ts_unix_ms",
		"route_snapshot_mode",
		"route_snapshot_policy_version",
		"spec008_hash_status",
	}
	settlementOutputKeysV04 = []string{
		"content",
		"finish_reason",
		"output_prefix_end_byte",
		"output_prefix_start_byte",
		"terminal_state",
		"tool_calls",
	}
	usageKeysV04 = []string{
		"billable_input_tokens",
		"billable_output_tokens",
		"delivered_output_bytes",
		"observed_input_tokens",
		"observed_output_tokens",
	}
	receiptTupleKeysV04 = []string{
		"account_scope",
		"attempt_n",
		"catalog_body_digest",
		"catalog_id",
		"expected_catalog_model_hash",
		"issued_at_unix_ms",
		"model_hash",
		"model_id",
		"output_hash",
		"output_prefix_end_byte",
		"output_prefix_start_byte",
		"prompt_hash",
		"provider_id",
		"provider_receipt_key_id",
		"receipt_version",
		"request_id",
		"route_snapshot_digest",
		"route_snapshot_mode",
		"route_snapshot_policy_version",
		"signature_key_alg",
		"terminal_state",
		"terminal_state_ts_unix_ms",
		"usage",
	}
)

func TestV04SettlementFixturesMatchVerifierJCSContract(t *testing.T) {
	fixtures := loadV04Fixtures(t)
	pubkey := decodePubkey(t, fixtures.ProviderReceiptPubkeyB64)
	wantKeyID := "ed25519-sha256:" + sha256Hex(pubkey)
	if fixtures.ProviderReceiptKeyID != wantKeyID {
		t.Fatalf("provider_receipt_key_id = %q, want %q", fixtures.ProviderReceiptKeyID, wantKeyID)
	}
	for _, fixture := range fixtures.Objects {
		canonical, err := Canonicalize(v04JCSValue(fixture.Kind, fixture.Value))
		if err != nil {
			t.Fatalf("%s canonicalize: %v", fixture.ID, err)
		}
		if got := base64.StdEncoding.EncodeToString(canonical); got != fixture.ExpectedCanonicalB64 {
			t.Fatalf("%s canonical b64 = %q, want %q\ncanonical=%s", fixture.ID, got, fixture.ExpectedCanonicalB64, canonical)
		}
		digest, err := sha256HexFromJSON(fixture.Kind, fixture.Value)
		if err != nil {
			t.Fatalf("%s hash: %v", fixture.ID, err)
		}
		if digest != fixture.ExpectedSHA256Hex {
			t.Fatalf("%s sha256 = %q, want %q", fixture.ID, digest, fixture.ExpectedSHA256Hex)
		}
		expectedKeys := expectedKeysForKind(t, fixture.Kind)
		assertFixtureStrictKeys(t, fixture.ID, fixture.StrictKeys, expectedKeys)
		assertStrictKeys(t, fixture.ID, fixture.Value, expectedKeys)
	}
	for _, tuple := range fixtures.ReceiptTuples {
		canonical, err := Canonicalize(v04JCSValue("receipt_tuple_v4", tuple.Value))
		if err != nil {
			t.Fatalf("%s canonicalize: %v", tuple.ID, err)
		}
		if got := base64.StdEncoding.EncodeToString(canonical); got != tuple.ExpectedCanonicalB64 {
			t.Fatalf("%s canonical b64 = %q, want %q", tuple.ID, got, tuple.ExpectedCanonicalB64)
		}
		digest, err := sha256HexFromJSON("receipt_tuple_v4", tuple.Value)
		if err != nil {
			t.Fatalf("%s hash: %v", tuple.ID, err)
		}
		if digest != tuple.ExpectedSHA256Hex {
			t.Fatalf("%s sha256 = %q, want %q", tuple.ID, digest, tuple.ExpectedSHA256Hex)
		}
		assertFixtureStrictKeys(t, tuple.ID, tuple.StrictKeys, receiptTupleKeysV04)
		assertStrictKeys(t, tuple.ID, tuple.Value, receiptTupleKeysV04)
		if tuple.Value["receipt_version"] != "4" {
			t.Fatalf("%s receipt_version = %#v, want 4", tuple.ID, tuple.Value["receipt_version"])
		}
		if tuple.Value["signature_key_alg"] != "Ed25519" {
			t.Fatalf("%s signature_key_alg = %#v, want Ed25519", tuple.ID, tuple.Value["signature_key_alg"])
		}
		if tuple.Value["provider_receipt_key_id"] != wantKeyID {
			t.Fatalf("%s provider_receipt_key_id = %#v, want %s", tuple.ID, tuple.Value["provider_receipt_key_id"], wantKeyID)
		}
		signature := decodeSignature(t, tuple.ID, tuple.SignatureB64)
		if !ed25519.Verify(ed25519.PublicKey(pubkey), canonical, signature) {
			t.Fatalf("%s signature did not verify", tuple.ID)
		}
		parts := strings.Split(tuple.WireReceipt, ".")
		if len(parts) != 2 || parts[0] != tuple.ExpectedCanonicalB64 || parts[1] != tuple.SignatureB64 {
			t.Fatalf("%s wire receipt does not match canonical/signature segments", tuple.ID)
		}
	}
}

func TestV04SettlementOutputPreservesRawToolArguments(t *testing.T) {
	fixtures := loadV04Fixtures(t)
	var found bool
	for _, fixture := range fixtures.Objects {
		if fixture.ID != "settlement_output_streaming_tool_call_nonzero_prefix" {
			continue
		}
		found = true
		canonical, err := Canonicalize(v04JCSValue(fixture.Kind, fixture.Value))
		if err != nil {
			t.Fatalf("%s canonicalize: %v", fixture.ID, err)
		}
		text := string(canonical)
		if !strings.Contains(text, `"content":"Use <tag>& Café."`) {
			t.Fatalf("%s content was not NFC-normalized in canonical bytes: %s", fixture.ID, text)
		}
		if !strings.Contains(text, `"arguments":"{\"query\":\"<tag>& Café\"}"`) {
			t.Fatalf("%s raw tool-call arguments were normalized or rewritten: %s", fixture.ID, text)
		}
	}
	if !found {
		t.Fatal("missing streaming tool-call settlement output fixture")
	}
}

func TestV04SignedTuplesCoverTerminalStateMatrix(t *testing.T) {
	fixtures := loadV04Fixtures(t)
	objectsByID := make(map[string]v04ObjectFixture, len(fixtures.Objects))
	for _, fixture := range fixtures.Objects {
		objectsByID[fixture.ID] = fixture
	}
	seen := make(map[string]bool)
	for _, tuple := range fixtures.ReceiptTuples {
		output := objectsByID[tuple.SettlementOutputID]
		if output.ID == "" {
			t.Fatalf("%s missing output fixture %q", tuple.ID, tuple.SettlementOutputID)
		}
		tupleUsage, ok := tuple.Value["usage"].(map[string]any)
		if !ok {
			t.Fatalf("%s usage = %#v, want object", tuple.ID, tuple.Value["usage"])
		}
		state, ok := tuple.Value["terminal_state"].(string)
		if !ok {
			t.Fatalf("%s terminal_state = %#v, want string", tuple.ID, tuple.Value["terminal_state"])
		}
		delivered := int64Value(t, tuple.ID, "usage.delivered_output_bytes", tupleUsage["delivered_output_bytes"])
		inputTokens := int64Value(t, tuple.ID, "usage.billable_input_tokens", tupleUsage["billable_input_tokens"])
		outputTokens := int64Value(t, tuple.ID, "usage.billable_output_tokens", tupleUsage["billable_output_tokens"])
		observedInputTokens := int64Value(t, tuple.ID, "usage.observed_input_tokens", tupleUsage["observed_input_tokens"])
		observedTokens := int64Value(t, tuple.ID, "usage.observed_output_tokens", tupleUsage["observed_output_tokens"])
		bucket := "nonzero"
		if delivered == 0 {
			bucket = "zero"
		}
		seen[state+":"+bucket] = true

		if state == "normal_done" {
			if inputTokens != observedInputTokens {
				t.Fatalf("%s normal_done billable_input_tokens = %d, observed = %d", tuple.ID, inputTokens, observedInputTokens)
			}
			if outputTokens != observedTokens {
				t.Fatalf("%s normal_done billable_output_tokens = %d, observed = %d", tuple.ID, outputTokens, observedTokens)
			}
		} else if delivered == 0 {
			if inputTokens != 0 || outputTokens != 0 {
				t.Fatalf("%s zero-prefix %s billable tokens input=%d output=%d, want 0/0", tuple.ID, state, inputTokens, outputTokens)
			}
		} else {
			if inputTokens <= 0 || inputTokens > observedInputTokens {
				t.Fatalf("%s nonzero %s billable_input_tokens = %d, observed = %d", tuple.ID, state, inputTokens, observedInputTokens)
			}
			if outputTokens <= 0 || outputTokens > observedTokens {
				t.Fatalf("%s nonzero %s billable_output_tokens = %d, observed = %d", tuple.ID, state, outputTokens, observedTokens)
			}
		}
	}

	required := []string{
		"normal_done:zero",
		"normal_done:nonzero",
		"provider_error:zero",
		"provider_error:nonzero",
		"buyer_cancel:zero",
		"buyer_cancel:nonzero",
		"gateway_timeout:zero",
		"gateway_timeout:nonzero",
		"upstream_transport_disconnect:zero",
		"upstream_transport_disconnect:nonzero",
	}
	for _, key := range required {
		if !seen[key] {
			t.Fatalf("missing signed terminal-state matrix cell %s", key)
		}
	}
}

func TestV04TupleFixturesBindRouteOutputAndUsage(t *testing.T) {
	fixtures := loadV04Fixtures(t)
	objectsByID := make(map[string]v04ObjectFixture, len(fixtures.Objects))
	for _, fixture := range fixtures.Objects {
		objectsByID[fixture.ID] = fixture
	}

	for _, tuple := range fixtures.ReceiptTuples {
		route := objectsByID[tuple.RouteSnapshotID]
		output := objectsByID[tuple.SettlementOutputID]
		usage := objectsByID[tuple.UsageID]
		if route.ID == "" || output.ID == "" || usage.ID == "" {
			t.Fatalf("%s missing linked fixture route=%q output=%q usage=%q", tuple.ID, tuple.RouteSnapshotID, tuple.SettlementOutputID, tuple.UsageID)
		}
		if got, want := int64Value(t, tuple.ID, "attempt_n", tuple.Value["attempt_n"]), int64Value(t, route.ID, "attempt_n", route.Value["attempt_n"]); got != want {
			t.Fatalf("%s attempt_n = %d, route attempt_n = %d", tuple.ID, got, want)
		}
		assertRouteBoundFields(t, tuple.ID, tuple.Value, route.Value)
		if tuple.Value["route_snapshot_digest"] != route.ExpectedSHA256Hex {
			t.Fatalf("%s route_snapshot_digest = %#v, want %s", tuple.ID, tuple.Value["route_snapshot_digest"], route.ExpectedSHA256Hex)
		}
		if tuple.Value["output_hash"] != output.ExpectedSHA256Hex {
			t.Fatalf("%s output_hash = %#v, want %s", tuple.ID, tuple.Value["output_hash"], output.ExpectedSHA256Hex)
		}
		start := int64Value(t, tuple.ID, "output_prefix_start_byte", tuple.Value["output_prefix_start_byte"])
		end := int64Value(t, tuple.ID, "output_prefix_end_byte", tuple.Value["output_prefix_end_byte"])
		assertPrefixRange(t, tuple.ID, start, end)
		if got := int64Value(t, output.ID, "output_prefix_start_byte", output.Value["output_prefix_start_byte"]); got != start {
			t.Fatalf("%s output prefix start = %d, tuple start = %d", output.ID, got, start)
		}
		if got := int64Value(t, output.ID, "output_prefix_end_byte", output.Value["output_prefix_end_byte"]); got != end {
			t.Fatalf("%s output prefix end = %d, tuple end = %d", output.ID, got, end)
		}
		if tuple.Value["terminal_state"] != output.Value["terminal_state"] {
			t.Fatalf("%s terminal_state = %#v, output terminal_state = %#v", tuple.ID, tuple.Value["terminal_state"], output.Value["terminal_state"])
		}
		tupleUsage, ok := tuple.Value["usage"].(map[string]any)
		if !ok {
			t.Fatalf("%s usage = %#v, want object", tuple.ID, tuple.Value["usage"])
		}
		assertStrictKeys(t, tuple.ID+".usage", tupleUsage, usageKeysV04)
		for _, field := range usageKeysV04 {
			got := int64Value(t, tuple.ID, "usage."+field, tupleUsage[field])
			want := int64Value(t, usage.ID, field, usage.Value[field])
			if got != want {
				t.Fatalf("%s usage.%s = %d, linked usage = %d", tuple.ID, field, got, want)
			}
		}
		delivered := int64Value(t, tuple.ID, "usage.delivered_output_bytes", tupleUsage["delivered_output_bytes"])
		if delivered != end-start {
			t.Fatalf("%s delivered bytes = %d, want prefix delta %d", tuple.ID, delivered, end-start)
		}
		assertCanonicalContentPrefixLength(t, tuple.ID, output, start, end, delivered)
	}
}

func TestV04ReceiptTupleRangesDoNotOverlapWithinRequest(t *testing.T) {
	fixtures := loadV04Fixtures(t)
	byRequest := make(map[string][]v04TupleFixture)
	for _, tuple := range fixtures.ReceiptTuples {
		requestID, ok := tuple.Value["request_id"].(string)
		if !ok {
			t.Fatalf("%s request_id = %#v, want string", tuple.ID, tuple.Value["request_id"])
		}
		byRequest[requestID] = append(byRequest[requestID], tuple)
	}
	for requestID, tuples := range byRequest {
		sort.Slice(tuples, func(i, j int) bool {
			return int64Value(t, tuples[i].ID, "attempt_n", tuples[i].Value["attempt_n"]) <
				int64Value(t, tuples[j].ID, "attempt_n", tuples[j].Value["attempt_n"])
		})
		for i, tuple := range tuples {
			attempt := int64Value(t, tuple.ID, "attempt_n", tuple.Value["attempt_n"])
			if attempt != int64(i) {
				t.Fatalf("%s attempt sequence mismatch at %s: got %d, want %d", requestID, tuple.ID, attempt, i)
			}
		}
		sort.Slice(tuples, func(i, j int) bool {
			return int64Value(t, tuples[i].ID, "output_prefix_start_byte", tuples[i].Value["output_prefix_start_byte"]) <
				int64Value(t, tuples[j].ID, "output_prefix_start_byte", tuples[j].Value["output_prefix_start_byte"])
		})
		for i := 1; i < len(tuples); i++ {
			prevEnd := int64Value(t, tuples[i-1].ID, "output_prefix_end_byte", tuples[i-1].Value["output_prefix_end_byte"])
			start := int64Value(t, tuples[i].ID, "output_prefix_start_byte", tuples[i].Value["output_prefix_start_byte"])
			if start < prevEnd {
				t.Fatalf("%s has overlapping receipt ranges: %s ends at %d, %s starts at %d", requestID, tuples[i-1].ID, prevEnd, tuples[i].ID, start)
			}
		}
	}
	chain := byRequest["req_spec015_v04_chain_0001"]
	if len(chain) != 2 {
		t.Fatalf("req_spec015_v04_chain_0001 tuple count = %d, want 2", len(chain))
	}
	sort.Slice(chain, func(i, j int) bool {
		return int64Value(t, chain[i].ID, "output_prefix_start_byte", chain[i].Value["output_prefix_start_byte"]) <
			int64Value(t, chain[j].ID, "output_prefix_start_byte", chain[j].Value["output_prefix_start_byte"])
	})
	if end := int64Value(t, chain[0].ID, "output_prefix_end_byte", chain[0].Value["output_prefix_end_byte"]); end != 13 {
		t.Fatalf("chain first end = %d, want 13", end)
	}
	if start := int64Value(t, chain[0].ID, "output_prefix_start_byte", chain[0].Value["output_prefix_start_byte"]); start != 0 {
		t.Fatalf("chain first start = %d, want 0", start)
	}
	if start := int64Value(t, chain[1].ID, "output_prefix_start_byte", chain[1].Value["output_prefix_start_byte"]); start != 13 {
		t.Fatalf("chain second start = %d, want 13", start)
	}
	if end := int64Value(t, chain[1].ID, "output_prefix_end_byte", chain[1].Value["output_prefix_end_byte"]); end != 30 {
		t.Fatalf("chain second end = %d, want 30", end)
	}
	if attempt := int64Value(t, chain[0].ID, "attempt_n", chain[0].Value["attempt_n"]); attempt != 0 {
		t.Fatalf("chain first attempt = %d, want 0", attempt)
	}
	if attempt := int64Value(t, chain[1].ID, "attempt_n", chain[1].Value["attempt_n"]); attempt != 1 {
		t.Fatalf("chain second attempt = %d, want 1", attempt)
	}
	if chain[0].ID != "receipt_tuple_v4_failover_upstream_disconnect_prefix" {
		t.Fatalf("chain first tuple = %s, want receipt_tuple_v4_failover_upstream_disconnect_prefix", chain[0].ID)
	}
	if chain[0].SettlementOutputID != "settlement_output_failover_upstream_disconnect_prefix" {
		t.Fatalf("chain first output = %s, want settlement_output_failover_upstream_disconnect_prefix", chain[0].SettlementOutputID)
	}
	if state := chain[0].Value["terminal_state"]; state != "upstream_transport_disconnect" {
		t.Fatalf("chain first terminal_state = %#v, want upstream_transport_disconnect", state)
	}
	if chain[1].ID != "receipt_tuple_v4_streaming_tool_call_nonzero_prefix" {
		t.Fatalf("chain second tuple = %s, want receipt_tuple_v4_streaming_tool_call_nonzero_prefix", chain[1].ID)
	}
	if chain[1].SettlementOutputID != "settlement_output_streaming_tool_call_nonzero_prefix" {
		t.Fatalf("chain second output = %s, want settlement_output_streaming_tool_call_nonzero_prefix", chain[1].SettlementOutputID)
	}
	if state := chain[1].Value["terminal_state"]; state != "normal_done" {
		t.Fatalf("chain second terminal_state = %#v, want normal_done", state)
	}
}

func TestV04NegativeRangeScenariosFailExpectedChecks(t *testing.T) {
	fixtures := loadV04Fixtures(t)
	if len(fixtures.NegativeRangeScenarios) == 0 {
		t.Fatal("negative_range_scenarios must not be empty")
	}
	for _, scenario := range fixtures.NegativeRangeScenarios {
		switch scenario.ExpectedFailure {
		case "overlapping_ranges":
			if !hasOverlappingRangesByAttempt(scenario.Ranges) {
				t.Fatalf("%s did not contain overlapping ranges", scenario.ID)
			}
		case "duplicate_ranges":
			if !hasDuplicateRanges(scenario.Ranges) {
				t.Fatalf("%s did not contain duplicate ranges", scenario.ID)
			}
		case "out_of_order_ranges":
			if !hasOutOfOrderRangesByAttempt(scenario.Ranges) {
				t.Fatalf("%s did not contain out-of-order ranges by attempt", scenario.ID)
			}
		default:
			t.Fatalf("%s unknown expected_failure %q", scenario.ID, scenario.ExpectedFailure)
		}
	}
}

func TestV04NegativeReceiptFixturesFailExpectedChecks(t *testing.T) {
	fixtures := loadV04Fixtures(t)
	pubkey := decodePubkey(t, fixtures.ProviderReceiptPubkeyB64)
	objectsByID := make(map[string]v04ObjectFixture, len(fixtures.Objects))
	for _, fixture := range fixtures.Objects {
		objectsByID[fixture.ID] = fixture
	}
	tuplesByID := make(map[string]v04TupleFixture, len(fixtures.ReceiptTuples))
	for _, tuple := range fixtures.ReceiptTuples {
		tuplesByID[tuple.ID] = tuple
	}
	if len(fixtures.NegativeReceipts) == 0 {
		t.Fatal("negative_receipts must not be empty")
	}
	for _, negative := range fixtures.NegativeReceipts {
		base := tuplesByID[negative.BaseTupleID]
		if base.ID == "" {
			t.Fatalf("%s missing base tuple %q", negative.ID, negative.BaseTupleID)
		}
		canonical, err := Canonicalize(v04JCSValue("receipt_tuple_v4", negative.Value))
		if err != nil {
			t.Fatalf("%s canonicalize: %v", negative.ID, err)
		}
		if got := base64.StdEncoding.EncodeToString(canonical); got != negative.ExpectedCanonicalB64 {
			t.Fatalf("%s canonical b64 = %q, want %q", negative.ID, got, negative.ExpectedCanonicalB64)
		}
		signature := decodeSignature(t, negative.ID, negative.SignatureB64)
		signatureValid := ed25519.Verify(ed25519.PublicKey(pubkey), canonical, signature)
		switch negative.ExpectedFailure {
		case "output_hash_mismatch":
			output := objectsByID[base.SettlementOutputID]
			if negative.Value["output_hash"] == output.ExpectedSHA256Hex {
				t.Fatalf("%s output_hash unexpectedly matches linked output", negative.ID)
			}
			if !signatureValid {
				t.Fatalf("%s signature should be valid for mismatch vector", negative.ID)
			}
		case "route_snapshot_digest_mismatch":
			route := objectsByID[base.RouteSnapshotID]
			if negative.Value["route_snapshot_digest"] == route.ExpectedSHA256Hex {
				t.Fatalf("%s route_snapshot_digest unexpectedly matches linked route", negative.ID)
			}
			if !signatureValid {
				t.Fatalf("%s signature should be valid for mismatch vector", negative.ID)
			}
		case "model_hash_mismatch":
			route := objectsByID[base.RouteSnapshotID]
			if negative.Value["model_hash"] == route.Value["provider_reported_model_hash"] ||
				negative.Value["model_hash"] == route.Value["expected_catalog_model_hash"] {
				t.Fatalf("%s model_hash unexpectedly matches linked route", negative.ID)
			}
			if !signatureValid {
				t.Fatalf("%s signature should be valid for model-hash mismatch vector", negative.ID)
			}
		case "terminal_state_mismatch":
			output := objectsByID[base.SettlementOutputID]
			if negative.Value["terminal_state"] == output.Value["terminal_state"] {
				t.Fatalf("%s terminal_state unexpectedly matches linked output", negative.ID)
			}
			if !signatureValid {
				t.Fatalf("%s signature should be valid for terminal-state mismatch vector", negative.ID)
			}
		case "terminal_state_out_of_enum":
			if negative.Value["terminal_state"] != "provider_claimed_done" {
				t.Fatalf("%s terminal_state = %#v, want provider_claimed_done", negative.ID, negative.Value["terminal_state"])
			}
			if !signatureValid {
				t.Fatalf("%s signature should be valid for terminal-state enum vector", negative.ID)
			}
		case "attempt_mismatch":
			route := objectsByID[base.RouteSnapshotID]
			if int64Value(t, negative.ID, "attempt_n", negative.Value["attempt_n"]) == int64Value(t, route.ID, "attempt_n", route.Value["attempt_n"]) {
				t.Fatalf("%s attempt_n unexpectedly matches linked route", negative.ID)
			}
			if !signatureValid {
				t.Fatalf("%s signature should be valid for mismatch vector", negative.ID)
			}
		case "wrong_key_signature":
			if signatureValid {
				t.Fatalf("%s signature unexpectedly verifies with fixture pubkey", negative.ID)
			}
		case "legacy_receipt_version":
			if negative.Value["receipt_version"] == "4" {
				t.Fatalf("%s receipt_version unexpectedly equals 4", negative.ID)
			}
			if !signatureValid {
				t.Fatalf("%s signature should be valid for legacy-version vector", negative.ID)
			}
		case "strict_shape_missing_output_hash":
			if _, ok := negative.Value["output_hash"]; ok {
				t.Fatalf("%s output_hash unexpectedly present", negative.ID)
			}
			if !signatureValid {
				t.Fatalf("%s signature should be valid for strict-shape vector", negative.ID)
			}
		case "usage_delivered_bytes_mismatch":
			usage, ok := negative.Value["usage"].(map[string]any)
			if !ok {
				t.Fatalf("%s usage = %#v, want object", negative.ID, negative.Value["usage"])
			}
			start := int64Value(t, negative.ID, "output_prefix_start_byte", negative.Value["output_prefix_start_byte"])
			end := int64Value(t, negative.ID, "output_prefix_end_byte", negative.Value["output_prefix_end_byte"])
			delivered := int64Value(t, negative.ID, "usage.delivered_output_bytes", usage["delivered_output_bytes"])
			if delivered == end-start {
				t.Fatalf("%s delivered_output_bytes unexpectedly matches prefix delta", negative.ID)
			}
			if !signatureValid {
				t.Fatalf("%s signature should be valid for usage mismatch vector", negative.ID)
			}
		case "usage_negative_value":
			usage, ok := negative.Value["usage"].(map[string]any)
			if !ok {
				t.Fatalf("%s usage = %#v, want object", negative.ID, negative.Value["usage"])
			}
			if int64Value(t, negative.ID, "usage.billable_input_tokens", usage["billable_input_tokens"]) >= 0 {
				t.Fatalf("%s billable_input_tokens is not negative", negative.ID)
			}
			if !signatureValid {
				t.Fatalf("%s signature should be valid for negative-usage vector", negative.ID)
			}
		case "usage_null":
			if negative.Value["usage"] != nil {
				t.Fatalf("%s usage = %#v, want null", negative.ID, negative.Value["usage"])
			}
			if !signatureValid {
				t.Fatalf("%s signature should be valid for null-usage vector", negative.ID)
			}
		case "usage_missing_required_field":
			usage, ok := negative.Value["usage"].(map[string]any)
			if !ok {
				t.Fatalf("%s usage = %#v, want object", negative.ID, negative.Value["usage"])
			}
			if _, ok := usage["observed_output_tokens"]; ok {
				t.Fatalf("%s observed_output_tokens unexpectedly present", negative.ID)
			}
			if !signatureValid {
				t.Fatalf("%s signature should be valid for missing-usage-field vector", negative.ID)
			}
		case "usage_extra_field":
			usage, ok := negative.Value["usage"].(map[string]any)
			if !ok {
				t.Fatalf("%s usage = %#v, want object", negative.ID, negative.Value["usage"])
			}
			if _, ok := usage["unsettled_extra_tokens"]; !ok {
				t.Fatalf("%s unsettled_extra_tokens missing", negative.ID)
			}
			if !signatureValid {
				t.Fatalf("%s signature should be valid for extra-usage-field vector", negative.ID)
			}
		case "strict_shape_extra_top_level_field":
			if _, ok := negative.Value["unexpected_settlement_field"]; !ok {
				t.Fatalf("%s unexpected_settlement_field missing", negative.ID)
			}
			if !signatureValid {
				t.Fatalf("%s signature should be valid for top-level extra-field vector", negative.ID)
			}
		default:
			t.Fatalf("%s unknown expected_failure %q", negative.ID, negative.ExpectedFailure)
		}
	}
}

func assertRouteBoundFields(t *testing.T, id string, tuple, route map[string]any) {
	t.Helper()
	fieldPairs := map[string]string{
		"account_scope":                 "account_scope",
		"catalog_body_digest":           "catalog_body_digest",
		"catalog_id":                    "catalog_id",
		"expected_catalog_model_hash":   "expected_catalog_model_hash",
		"model_id":                      "model_id",
		"prompt_hash":                   "prompt_hash",
		"provider_id":                   "provider_id",
		"provider_receipt_key_id":       "provider_receipt_key_id",
		"request_id":                    "request_id",
		"route_snapshot_mode":           "route_snapshot_mode",
		"route_snapshot_policy_version": "route_snapshot_policy_version",
	}
	for tupleField, routeField := range fieldPairs {
		if tuple[tupleField] != route[routeField] {
			t.Fatalf("%s %s = %#v, route %s = %#v", id, tupleField, tuple[tupleField], routeField, route[routeField])
		}
	}
	if tuple["model_hash"] != route["provider_reported_model_hash"] {
		t.Fatalf("%s model_hash = %#v, route provider_reported_model_hash = %#v", id, tuple["model_hash"], route["provider_reported_model_hash"])
	}
	if tuple["model_hash"] != route["expected_catalog_model_hash"] {
		t.Fatalf("%s model_hash = %#v, route expected_catalog_model_hash = %#v", id, tuple["model_hash"], route["expected_catalog_model_hash"])
	}
}

func hasOverlappingRangesByAttempt(ranges []v04RangeFixture) bool {
	ordered := append([]v04RangeFixture(nil), ranges...)
	sort.Slice(ordered, func(i, j int) bool {
		return ordered[i].Attempt < ordered[j].Attempt
	})
	for i := 1; i < len(ordered); i++ {
		if ordered[i].Start < ordered[i-1].End {
			return true
		}
	}
	return false
}

func hasDuplicateRanges(ranges []v04RangeFixture) bool {
	seen := make(map[[2]int64]bool)
	for _, item := range ranges {
		key := [2]int64{item.Start, item.End}
		if seen[key] {
			return true
		}
		seen[key] = true
	}
	return false
}

func hasOutOfOrderRangesByAttempt(ranges []v04RangeFixture) bool {
	ordered := append([]v04RangeFixture(nil), ranges...)
	sort.Slice(ordered, func(i, j int) bool {
		return ordered[i].Attempt < ordered[j].Attempt
	})
	for i := 1; i < len(ordered); i++ {
		if ordered[i].Start < ordered[i-1].Start {
			return true
		}
	}
	return false
}

func assertPrefixRange(t *testing.T, id string, start, end int64) {
	t.Helper()
	if start < 0 || end < 0 || start > end {
		t.Fatalf("%s invalid prefix range [%d,%d)", id, start, end)
	}
}

func assertCanonicalContentPrefixLength(t *testing.T, id string, output v04ObjectFixture, start, end, delivered int64) {
	t.Helper()
	content, ok := output.Value["content"].(string)
	if !ok {
		t.Fatalf("%s content = %#v, want string", output.ID, output.Value["content"])
	}
	contentBytes := int64(len([]byte(norm.NFC.String(content))))
	if delivered != contentBytes {
		t.Fatalf("%s delivered bytes = %d, canonical content bytes = %d", id, delivered, contentBytes)
	}
	if start+delivered != end {
		t.Fatalf("%s start + delivered = %d, end = %d", id, start+delivered, end)
	}
}

type v04Fixtures struct {
	ProviderReceiptPubkeyB64 string             `json:"provider_receipt_pubkey_b64"`
	ProviderReceiptKeyID     string             `json:"provider_receipt_key_id"`
	Objects                  []v04ObjectFixture `json:"objects"`
	ReceiptTuples            []v04TupleFixture  `json:"receipt_tuples"`
	NegativeReceipts         []v04TupleFixture  `json:"negative_receipts"`
	NegativeRangeScenarios   []v04RangeScenario `json:"negative_range_scenarios"`
}

type v04ObjectFixture struct {
	ID                   string         `json:"id"`
	Kind                 string         `json:"kind"`
	Value                map[string]any `json:"value"`
	StrictKeys           []string       `json:"strict_keys"`
	ExpectedCanonicalB64 string         `json:"expected_canonical_b64"`
	ExpectedSHA256Hex    string         `json:"expected_sha256_hex"`
}

type v04TupleFixture struct {
	ID                   string         `json:"id"`
	BaseTupleID          string         `json:"base_tuple_id"`
	ExpectedFailure      string         `json:"expected_failure"`
	RouteSnapshotID      string         `json:"route_snapshot_id"`
	SettlementOutputID   string         `json:"settlement_output_id"`
	UsageID              string         `json:"usage_id"`
	Value                map[string]any `json:"value"`
	StrictKeys           []string       `json:"strict_keys"`
	ExpectedCanonicalB64 string         `json:"expected_canonical_b64"`
	ExpectedSHA256Hex    string         `json:"expected_sha256_hex"`
	SignatureB64         string         `json:"signature_b64"`
	WireReceipt          string         `json:"wire_receipt"`
}

type v04RangeScenario struct {
	ID              string            `json:"id"`
	RequestID       string            `json:"request_id"`
	ExpectedFailure string            `json:"expected_failure"`
	Ranges          []v04RangeFixture `json:"ranges"`
}

type v04RangeFixture struct {
	TupleID string `json:"tuple_id"`
	Attempt int64  `json:"attempt_n"`
	Start   int64  `json:"output_prefix_start_byte"`
	End     int64  `json:"output_prefix_end_byte"`
}

func loadV04Fixtures(t *testing.T) v04Fixtures {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "testdata", "spec015", "v04_settlement_receipts.json"))
	if err != nil {
		t.Fatalf("read fixtures: %v", err)
	}
	var fixtures v04Fixtures
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := decoder.Decode(&fixtures); err != nil {
		t.Fatalf("parse fixtures: %v", err)
	}
	return fixtures
}

func sha256HexFromJSON(kind string, value map[string]any) (string, error) {
	canonical, err := Canonicalize(v04JCSValue(kind, value))
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(canonical)
	return hex.EncodeToString(sum[:]), nil
}

func v04JCSValue(kind string, value any) Value {
	return v04JCSValueAt(value, kind == "settlement_output_v1", nil)
}

func v04JCSValueAt(value any, rawToolCallArguments bool, path []string) Value {
	switch typed := value.(type) {
	case map[string]any:
		object := make(map[string]Value, len(typed))
		for key, member := range typed {
			childPath := append(append([]string(nil), path...), key)
			if rawToolCallArguments && isV04ToolCallArgumentPath(childPath) {
				if raw, ok := member.(string); ok {
					object[key] = Value{Kind: KindRawString, RawString: raw}
					continue
				}
			}
			object[key] = v04JCSValueAt(member, rawToolCallArguments, childPath)
		}
		return Value{Kind: KindObject, Object: object}
	case []any:
		array := make([]Value, 0, len(typed))
		for _, item := range typed {
			array = append(array, v04JCSValueAt(item, rawToolCallArguments, path))
		}
		return Value{Kind: KindArray, Array: array}
	case string:
		return Value{Kind: KindString, String: typed}
	case json.Number:
		out, err := strconv.ParseInt(typed.String(), 10, 64)
		if err != nil {
			panic(err)
		}
		return Value{Kind: KindInt, Int: out}
	case bool:
		return Value{Kind: KindBool, Bool: typed}
	case nil:
		return Value{Kind: KindNull}
	default:
		panic(fmt.Sprintf("unsupported v0.4 fixture value %T", value))
	}
}

func isV04ToolCallArgumentPath(path []string) bool {
	if len(path) < 3 {
		return false
	}
	if path[len(path)-2] != "function" || path[len(path)-1] != "arguments" {
		return false
	}
	for _, segment := range path[:len(path)-2] {
		if segment == "tool_calls" {
			return true
		}
	}
	return false
}

func sha256Hex(raw []byte) string {
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

func assertStrictKeys(t *testing.T, id string, value map[string]any, want []string) {
	t.Helper()
	got := make([]string, 0, len(value))
	for key := range value {
		got = append(got, key)
	}
	wantSorted := sortedCopy(want)
	sort.Strings(got)
	if strings.Join(got, "\x00") != strings.Join(wantSorted, "\x00") {
		t.Fatalf("%s strict keys = %#v, want %#v", id, got, wantSorted)
	}
}

func assertFixtureStrictKeys(t *testing.T, id string, fixtureKeys, want []string) {
	t.Helper()
	got := sortedCopy(fixtureKeys)
	wantSorted := sortedCopy(want)
	if strings.Join(got, "\x00") != strings.Join(wantSorted, "\x00") {
		t.Fatalf("%s fixture strict_keys = %#v, want %#v", id, got, wantSorted)
	}
}

func expectedKeysForKind(t *testing.T, kind string) []string {
	t.Helper()
	switch kind {
	case "route_snapshot_v1":
		return routeSnapshotKeysV04
	case "settlement_output_v1":
		return settlementOutputKeysV04
	case "usage":
		return usageKeysV04
	default:
		t.Fatalf("unknown fixture kind %q", kind)
		return nil
	}
}

func int64Value(t *testing.T, id, field string, value any) int64 {
	t.Helper()
	number, ok := value.(json.Number)
	if !ok {
		t.Fatalf("%s %s = %#v, want json.Number", id, field, value)
	}
	out, err := strconv.ParseInt(number.String(), 10, 64)
	if err != nil {
		t.Fatalf("%s %s parse: %v", id, field, err)
	}
	return out
}

func sortedCopy(in []string) []string {
	out := append([]string(nil), in...)
	sort.Strings(out)
	return out
}

func decodePubkey(t *testing.T, raw string) []byte {
	t.Helper()
	pubkey, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		t.Fatalf("decode pubkey: %v", err)
	}
	if len(pubkey) != ed25519.PublicKeySize {
		t.Fatalf("pubkey length = %d, want %d", len(pubkey), ed25519.PublicKeySize)
	}
	return pubkey
}

func decodeSignature(t *testing.T, id, raw string) []byte {
	t.Helper()
	signature, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		t.Fatalf("%s decode signature: %v", id, err)
	}
	if len(signature) != ed25519.SignatureSize {
		t.Fatalf("%s signature length = %d, want %d", id, len(signature), ed25519.SignatureSize)
	}
	return signature
}
