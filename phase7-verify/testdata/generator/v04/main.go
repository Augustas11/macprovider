package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/augstar/macprovider/phase7-verify/internal/jcs"
)

const (
	accountScope         = "acct_scope_test_001"
	providerID           = "provider-mac-001"
	modelID              = "mlx-community/Qwen3-32B-4bit"
	promptHash           = "1111111111111111111111111111111111111111111111111111111111111111"
	modelHash            = "2222222222222222222222222222222222222222222222222222222222222222"
	catalogBodyDigest    = "3333333333333333333333333333333333333333333333333333333333333333"
	catalogID            = "catalog-2026-06-30T00:00:00Z"
	catalogSigningKeyID  = "catalog-key-2026-06"
	catalogPubkeyID      = "ed25519-sha256:4444444444444444444444444444444444444444444444444444444444444444"
	routePolicyVersion   = "spec022-policy-v1"
	routeMode            = "observe"
	routeDecisionUnixMS  = int64(1782864000123)
	requestStartUnixMS   = int64(1782864000456)
	terminalStateUnixMS  = int64(1782864001789)
	issuedAtUnixMS       = int64(1782864001999)
	pendingDeadlineSecs  = int64(90)
	providerSessionID    = "session-spec015-v04"
	providerGenerationID = "generation-42"
	paidEntrypoint       = "openai-chat-completions"
	hashStatus           = "verified"
	promptHashBasis      = "coordinator-openai-chat-v1"
	keySource            = "auth_session"
)

var (
	routeSnapshotKeys = []string{
		"account_scope",
		"request_id",
		"attempt_n",
		"provider_id",
		"provider_session_id",
		"provider_generation_id",
		"paid_entrypoint",
		"provider_receipt_key_id",
		"provider_receipt_key_source",
		"model_id",
		"provider_reported_model_hash",
		"expected_catalog_model_hash",
		"catalog_id",
		"catalog_body_digest",
		"catalog_signature_key_id",
		"catalog_signature_pubkey_fingerprint",
		"catalog_expires_at_unix_ms",
		"spec008_hash_status",
		"route_snapshot_policy_version",
		"route_snapshot_mode",
		"route_decision_ts_unix_ms",
		"request_start_ts_unix_ms",
		"pending_deadline_seconds",
		"prompt_hash_basis",
		"prompt_hash",
	}
	settlementOutputKeys = []string{
		"content",
		"finish_reason",
		"output_prefix_end_byte",
		"output_prefix_start_byte",
		"terminal_state",
		"tool_calls",
	}
	usageKeys = []string{
		"billable_input_tokens",
		"billable_output_tokens",
		"delivered_output_bytes",
		"observed_input_tokens",
		"observed_output_tokens",
	}
	receiptTupleKeys = []string{
		"account_scope",
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
		"attempt_n",
		"usage",
	}
)

type rootFixture struct {
	SchemaVersion            string          `json:"schema_version"`
	RegenerateCommand        string          `json:"regenerate_command"`
	ProviderReceiptPubkeyB64 string          `json:"provider_receipt_pubkey_b64"`
	ProviderReceiptKeyID     string          `json:"provider_receipt_key_id"`
	Objects                  []objectFixture `json:"objects"`
	ReceiptTuples            []tupleFixture  `json:"receipt_tuples"`
	NegativeReceipts         []tupleFixture  `json:"negative_receipts"`
	NegativeRangeScenarios   []rangeScenario `json:"negative_range_scenarios"`
}

type objectFixture struct {
	ID                   string         `json:"id"`
	Kind                 string         `json:"kind"`
	Value                map[string]any `json:"value"`
	StrictKeys           []string       `json:"strict_keys"`
	ExpectedCanonicalB64 string         `json:"expected_canonical_b64"`
	ExpectedSHA256Hex    string         `json:"expected_sha256_hex"`
}

type tupleFixture struct {
	ID                   string         `json:"id"`
	BaseTupleID          string         `json:"base_tuple_id,omitempty"`
	ExpectedFailure      string         `json:"expected_failure,omitempty"`
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

type rangeScenario struct {
	ID              string         `json:"id"`
	RequestID       string         `json:"request_id"`
	ExpectedFailure string         `json:"expected_failure"`
	Ranges          []rangeFixture `json:"ranges"`
}

type rangeFixture struct {
	TupleID string `json:"tuple_id"`
	Attempt int64  `json:"attempt_n"`
	Start   int64  `json:"output_prefix_start_byte"`
	End     int64  `json:"output_prefix_end_byte"`
}

func main() {
	out := flag.String("out", "../testdata/spec015", "fixture output directory")
	flag.Parse()

	if err := os.MkdirAll(*out, 0o755); err != nil {
		fatal(err)
	}
	fixture, err := buildFixture()
	if err != nil {
		fatal(err)
	}
	if err := writeJSON(filepath.Join(*out, "v04_settlement_receipts.json"), fixture); err != nil {
		fatal(err)
	}
}

func buildFixture() (rootFixture, error) {
	priv := ed25519.NewKeyFromSeed(bytesRange(32))
	pub := priv.Public().(ed25519.PublicKey)
	pubkeyB64 := base64.StdEncoding.EncodeToString(pub)
	pubkeyID := "ed25519-sha256:" + sha256HexBytes(pub)

	outputSpecs := []struct {
		id            string
		terminalState string
		content       string
		finishReason  any
		start         int64
		end           int64
		toolCalls     any
	}{
		{"settlement_output_non_streaming_normal_done_empty", "normal_done", "", "stop", 0, 0, nil},
		{"settlement_output_non_streaming_normal_done", "normal_done", "Final answer.", "stop", 0, 13, nil},
		{"settlement_output_streaming_done", "normal_done", "Streaming answer.", "stop", 0, 17, nil},
		{"settlement_output_streaming_tool_call_nonzero_prefix", "normal_done", "Use <tag>& Cafe\u0301.", "tool_calls", 13, 30, toolCalls()},
		{"settlement_output_failover_upstream_disconnect_prefix", "upstream_transport_disconnect", "Final answer.", nil, 0, 13, nil},
		{"settlement_output_provider_error_empty", "provider_error", "", nil, 0, 0, nil},
		{"settlement_output_provider_error_prefix", "provider_error", "partial", nil, 0, 7, nil},
		{"settlement_output_buyer_cancel_empty", "buyer_cancel", "", nil, 0, 0, nil},
		{"settlement_output_buyer_cancel_prefix", "buyer_cancel", "cancelled prefix", nil, 0, 16, nil},
		{"settlement_output_gateway_timeout_empty", "gateway_timeout", "", nil, 0, 0, nil},
		{"settlement_output_gateway_timeout_prefix", "gateway_timeout", "timeout prefix", nil, 0, 14, nil},
		{"settlement_output_upstream_disconnect_empty", "upstream_transport_disconnect", "", nil, 0, 0, nil},
		{"settlement_output_upstream_disconnect_prefix", "upstream_transport_disconnect", "disconnect prefix", nil, 0, 17, nil},
		{"settlement_output_parity_edge_cases", "provider_error", "edge \U0001F9EA\u2028\u2029\u0001", nil, 0, 16, nil},
	}

	objects := []objectFixture{}
	outputHashByID := make(map[string]string)
	outputByID := make(map[string]map[string]any)
	for _, spec := range outputSpecs {
		value := settlementOutput(spec.terminalState, spec.content, spec.finishReason, spec.start, spec.end, spec.toolCalls)
		fixture, err := newObjectFixture(spec.id, "settlement_output_v1", value, settlementOutputKeys)
		if err != nil {
			return rootFixture{}, err
		}
		objects = append(objects, fixture)
		outputHashByID[spec.id] = fixture.ExpectedSHA256Hex
		outputByID[spec.id] = value
	}

	usageSpecs := []struct {
		id        string
		input     int64
		output    int64
		delivered int64
		observedI int64
		observedO int64
	}{
		{"usage_normal_empty_billable", 8, 0, 0, 8, 0},
		{"usage_normal_billable", 8, 4, 13, 8, 4},
		{"usage_zero_settled_empty_prefix", 0, 0, 0, 8, 0},
		{"usage_failover_disconnect_prefix_billable", 8, 3, 13, 8, 4},
		{"usage_provider_error_prefix_billable", 8, 1, 7, 8, 4},
		{"usage_gateway_timeout_prefix_billable", 8, 2, 14, 8, 4},
		{"usage_streaming_tool_call_nonzero_prefix", 8, 5, 17, 8, 5},
		{"usage_buyer_cancel_prefix_billable", 8, 2, 16, 8, 4},
		{"usage_upstream_disconnect_prefix_billable", 8, 2, 17, 8, 4},
		{"usage_integer_edge_cases", 0, 0, 0, 9007199254740993, 9223372036854775807},
	}
	usageByID := make(map[string]map[string]any)
	for _, spec := range usageSpecs {
		value := usage(spec.input, spec.output, spec.delivered, spec.observedI, spec.observedO)
		fixture, err := newObjectFixture(spec.id, "usage", value, usageKeys)
		if err != nil {
			return rootFixture{}, err
		}
		objects = append(objects, fixture)
		usageByID[spec.id] = value
	}

	tupleSpecs := []struct {
		id        string
		requestID string
		outputID  string
		usageID   string
		attemptN  int64
	}{
		{"receipt_tuple_v4_normal_done_empty", "req_spec015_v04_normal_empty", "settlement_output_non_streaming_normal_done_empty", "usage_normal_empty_billable", 0},
		{"receipt_tuple_v4_normal_done", "req_spec015_v04_normal_nonzero", "settlement_output_non_streaming_normal_done", "usage_normal_billable", 0},
		{"receipt_tuple_v4_failover_upstream_disconnect_prefix", "req_spec015_v04_chain_0001", "settlement_output_failover_upstream_disconnect_prefix", "usage_failover_disconnect_prefix_billable", 0},
		{"receipt_tuple_v4_provider_error_empty", "req_spec015_v04_provider_error_empty", "settlement_output_provider_error_empty", "usage_zero_settled_empty_prefix", 0},
		{"receipt_tuple_v4_provider_error_prefix", "req_spec015_v04_provider_error_prefix", "settlement_output_provider_error_prefix", "usage_provider_error_prefix_billable", 0},
		{"receipt_tuple_v4_buyer_cancel_empty", "req_spec015_v04_buyer_cancel_empty", "settlement_output_buyer_cancel_empty", "usage_zero_settled_empty_prefix", 0},
		{"receipt_tuple_v4_buyer_cancel_prefix", "req_spec015_v04_buyer_cancel_prefix", "settlement_output_buyer_cancel_prefix", "usage_buyer_cancel_prefix_billable", 0},
		{"receipt_tuple_v4_gateway_timeout_empty", "req_spec015_v04_gateway_timeout_empty", "settlement_output_gateway_timeout_empty", "usage_zero_settled_empty_prefix", 0},
		{"receipt_tuple_v4_gateway_timeout_prefix", "req_spec015_v04_gateway_timeout_prefix", "settlement_output_gateway_timeout_prefix", "usage_gateway_timeout_prefix_billable", 0},
		{"receipt_tuple_v4_upstream_disconnect_empty", "req_spec015_v04_upstream_disconnect_empty", "settlement_output_upstream_disconnect_empty", "usage_zero_settled_empty_prefix", 0},
		{"receipt_tuple_v4_upstream_disconnect_prefix", "req_spec015_v04_upstream_disconnect_prefix", "settlement_output_upstream_disconnect_prefix", "usage_upstream_disconnect_prefix_billable", 0},
		{"receipt_tuple_v4_streaming_tool_call_nonzero_prefix", "req_spec015_v04_chain_0001", "settlement_output_streaming_tool_call_nonzero_prefix", "usage_streaming_tool_call_nonzero_prefix", 1},
	}

	routeObjByTupleID := make(map[string]objectFixture)
	for _, spec := range tupleSpecs {
		route := routeSnapshot(pubkeyID, spec.requestID, spec.attemptN)
		routeID := "route_snapshot_v1_" + strings.TrimPrefix(spec.id, "receipt_tuple_v4_")
		routeObj, err := newObjectFixture(routeID, "route_snapshot_v1", route, routeSnapshotKeys)
		if err != nil {
			return rootFixture{}, err
		}
		objects = append(objects, routeObj)
		routeObjByTupleID[spec.id] = routeObj
	}

	var tuples []tupleFixture
	for _, spec := range tupleSpecs {
		output := outputByID[spec.outputID]
		routeObj := routeObjByTupleID[spec.id]
		tuple := receiptTuple(
			pubkeyID,
			routeObj.ExpectedSHA256Hex,
			outputHashByID[spec.outputID],
			output["terminal_state"].(string),
			output["output_prefix_start_byte"].(int64),
			output["output_prefix_end_byte"].(int64),
			usageByID[spec.usageID],
			spec.requestID,
			spec.attemptN,
		)
		fixture, err := newTupleFixture(spec.id, routeObj.ID, spec.outputID, spec.usageID, tuple, priv)
		if err != nil {
			return rootFixture{}, err
		}
		tuples = append(tuples, fixture)
	}
	negativeReceipts, err := negativeReceiptFixtures(tuples, routeObjByTupleID, priv)
	if err != nil {
		return rootFixture{}, err
	}
	negativeRangeScenarios, err := negativeRangeScenarioFixtures(tuples)
	if err != nil {
		return rootFixture{}, err
	}

	return rootFixture{
		SchemaVersion:            "SPEC-015-v0.4.2-step1",
		RegenerateCommand:        "cd phase7-verify && go run ./testdata/generator/v04 -out ../testdata/spec015",
		ProviderReceiptPubkeyB64: pubkeyB64,
		ProviderReceiptKeyID:     pubkeyID,
		Objects:                  objects,
		ReceiptTuples:            tuples,
		NegativeReceipts:         negativeReceipts,
		NegativeRangeScenarios:   negativeRangeScenarios,
	}, nil
}

func routeSnapshot(pubkeyID, requestID string, attemptN int64) map[string]any {
	return map[string]any{
		"account_scope":                        accountScope,
		"request_id":                           requestID,
		"attempt_n":                            attemptN,
		"provider_id":                          providerID,
		"provider_session_id":                  providerSessionID,
		"provider_generation_id":               providerGenerationID,
		"paid_entrypoint":                      paidEntrypoint,
		"provider_receipt_key_id":              pubkeyID,
		"provider_receipt_key_source":          keySource,
		"model_id":                             modelID,
		"provider_reported_model_hash":         modelHash,
		"expected_catalog_model_hash":          modelHash,
		"catalog_id":                           catalogID,
		"catalog_body_digest":                  catalogBodyDigest,
		"catalog_signature_key_id":             catalogSigningKeyID,
		"catalog_signature_pubkey_fingerprint": catalogPubkeyID,
		"catalog_expires_at_unix_ms":           int64(1782950400000),
		"spec008_hash_status":                  hashStatus,
		"route_snapshot_policy_version":        routePolicyVersion,
		"route_snapshot_mode":                  routeMode,
		"route_decision_ts_unix_ms":            routeDecisionUnixMS,
		"request_start_ts_unix_ms":             requestStartUnixMS,
		"pending_deadline_seconds":             pendingDeadlineSecs,
		"prompt_hash_basis":                    promptHashBasis,
		"prompt_hash":                          promptHash,
	}
}

func settlementOutput(terminalState, content string, finishReason any, start, end int64, toolCalls any) map[string]any {
	return map[string]any{
		"content":                  content,
		"finish_reason":            finishReason,
		"output_prefix_end_byte":   end,
		"output_prefix_start_byte": start,
		"terminal_state":           terminalState,
		"tool_calls":               toolCalls,
	}
}

func usage(input, output, delivered, observedInput, observedOutput int64) map[string]any {
	return map[string]any{
		"billable_input_tokens":  input,
		"billable_output_tokens": output,
		"delivered_output_bytes": delivered,
		"observed_input_tokens":  observedInput,
		"observed_output_tokens": observedOutput,
	}
}

func toolCalls() []any {
	return []any{
		map[string]any{
			"id":   "call_1",
			"type": "function",
			"function": map[string]any{
				"name":      "lookup",
				"arguments": "{\"query\":\"<tag>& Cafe\u0301\"}",
			},
		},
	}
}

func receiptTuple(pubkeyID, routeDigest, outputHash, terminalState string, prefixStart, prefixEnd int64, usage map[string]any, requestID string, attemptN int64) map[string]any {
	return map[string]any{
		"account_scope":                 accountScope,
		"catalog_body_digest":           catalogBodyDigest,
		"catalog_id":                    catalogID,
		"expected_catalog_model_hash":   modelHash,
		"issued_at_unix_ms":             issuedAtUnixMS,
		"model_hash":                    modelHash,
		"model_id":                      modelID,
		"output_hash":                   outputHash,
		"output_prefix_end_byte":        prefixEnd,
		"output_prefix_start_byte":      prefixStart,
		"prompt_hash":                   promptHash,
		"provider_id":                   providerID,
		"provider_receipt_key_id":       pubkeyID,
		"receipt_version":               "4",
		"request_id":                    requestID,
		"route_snapshot_digest":         routeDigest,
		"route_snapshot_mode":           routeMode,
		"route_snapshot_policy_version": routePolicyVersion,
		"signature_key_alg":             "Ed25519",
		"terminal_state":                terminalState,
		"terminal_state_ts_unix_ms":     terminalStateUnixMS,
		"attempt_n":                     attemptN,
		"usage":                         usage,
	}
}

func newObjectFixture(id, kind string, value map[string]any, strictKeys []string) (objectFixture, error) {
	canonical, digest, err := canonicalAndHash(kind, value)
	if err != nil {
		return objectFixture{}, fmt.Errorf("%s: %w", id, err)
	}
	return objectFixture{
		ID:                   id,
		Kind:                 kind,
		Value:                value,
		StrictKeys:           sortedCopy(strictKeys),
		ExpectedCanonicalB64: base64.StdEncoding.EncodeToString(canonical),
		ExpectedSHA256Hex:    digest,
	}, nil
}

func newTupleFixture(id, routeSnapshotID, settlementOutputID, usageID string, value map[string]any, priv ed25519.PrivateKey) (tupleFixture, error) {
	canonical, digest, err := canonicalAndHash("receipt_tuple_v4", value)
	if err != nil {
		return tupleFixture{}, fmt.Errorf("%s: %w", id, err)
	}
	sig := ed25519.Sign(priv, canonical)
	tupleB64 := base64.StdEncoding.EncodeToString(canonical)
	sigB64 := base64.StdEncoding.EncodeToString(sig)
	return tupleFixture{
		ID:                   id,
		RouteSnapshotID:      routeSnapshotID,
		SettlementOutputID:   settlementOutputID,
		UsageID:              usageID,
		Value:                value,
		StrictKeys:           sortedCopy(receiptTupleKeys),
		ExpectedCanonicalB64: tupleB64,
		ExpectedSHA256Hex:    digest,
		SignatureB64:         sigB64,
		WireReceipt:          tupleB64 + "." + sigB64,
	}, nil
}

func negativeReceiptFixtures(tuples []tupleFixture, routeObjByTupleID map[string]objectFixture, priv ed25519.PrivateKey) ([]tupleFixture, error) {
	base, err := tupleByID(tuples, "receipt_tuple_v4_normal_done")
	if err != nil {
		return nil, err
	}
	wrongPriv := ed25519.NewKeyFromSeed(bytesRangeFrom(32, 32))
	specs := []struct {
		id              string
		expectedFailure string
		priv            ed25519.PrivateKey
		mutate          func(map[string]any)
	}{
		{
			id:              "negative_receipt_output_hash_mismatch",
			expectedFailure: "output_hash_mismatch",
			priv:            priv,
			mutate: func(value map[string]any) {
				value["output_hash"] = strings.Repeat("a", 64)
			},
		},
		{
			id:              "negative_receipt_route_snapshot_digest_mismatch",
			expectedFailure: "route_snapshot_digest_mismatch",
			priv:            priv,
			mutate: func(value map[string]any) {
				value["route_snapshot_digest"] = routeObjByTupleID["receipt_tuple_v4_provider_error_empty"].ExpectedSHA256Hex
			},
		},
		{
			id:              "negative_receipt_model_hash_mismatch",
			expectedFailure: "model_hash_mismatch",
			priv:            priv,
			mutate: func(value map[string]any) {
				value["model_hash"] = strings.Repeat("b", 64)
			},
		},
		{
			id:              "negative_receipt_terminal_state_mismatch",
			expectedFailure: "terminal_state_mismatch",
			priv:            priv,
			mutate: func(value map[string]any) {
				value["terminal_state"] = "provider_error"
			},
		},
		{
			id:              "negative_receipt_terminal_state_out_of_enum",
			expectedFailure: "terminal_state_out_of_enum",
			priv:            priv,
			mutate: func(value map[string]any) {
				value["terminal_state"] = "provider_claimed_done"
			},
		},
		{
			id:              "negative_receipt_attempt_mismatch",
			expectedFailure: "attempt_mismatch",
			priv:            priv,
			mutate: func(value map[string]any) {
				value["attempt_n"] = int64(999)
			},
		},
		{
			id:              "negative_receipt_wrong_key_signature",
			expectedFailure: "wrong_key_signature",
			priv:            wrongPriv,
			mutate:          func(map[string]any) {},
		},
		{
			id:              "negative_receipt_legacy_version",
			expectedFailure: "legacy_receipt_version",
			priv:            priv,
			mutate: func(value map[string]any) {
				value["receipt_version"] = "3"
			},
		},
		{
			id:              "negative_receipt_missing_output_hash",
			expectedFailure: "strict_shape_missing_output_hash",
			priv:            priv,
			mutate: func(value map[string]any) {
				delete(value, "output_hash")
			},
		},
		{
			id:              "negative_receipt_usage_delivered_bytes_mismatch",
			expectedFailure: "usage_delivered_bytes_mismatch",
			priv:            priv,
			mutate: func(value map[string]any) {
				usageValue := cloneMap(value["usage"].(map[string]any))
				usageValue["delivered_output_bytes"] = int64(999)
				value["usage"] = usageValue
			},
		},
		{
			id:              "negative_receipt_usage_negative_tokens",
			expectedFailure: "usage_negative_value",
			priv:            priv,
			mutate: func(value map[string]any) {
				usageValue := cloneMap(value["usage"].(map[string]any))
				usageValue["billable_input_tokens"] = int64(-1)
				value["usage"] = usageValue
			},
		},
		{
			id:              "negative_receipt_usage_null",
			expectedFailure: "usage_null",
			priv:            priv,
			mutate: func(value map[string]any) {
				value["usage"] = nil
			},
		},
		{
			id:              "negative_receipt_usage_missing_field",
			expectedFailure: "usage_missing_required_field",
			priv:            priv,
			mutate: func(value map[string]any) {
				usageValue := cloneMap(value["usage"].(map[string]any))
				delete(usageValue, "observed_output_tokens")
				value["usage"] = usageValue
			},
		},
		{
			id:              "negative_receipt_usage_extra_field",
			expectedFailure: "usage_extra_field",
			priv:            priv,
			mutate: func(value map[string]any) {
				usageValue := cloneMap(value["usage"].(map[string]any))
				usageValue["unsettled_extra_tokens"] = int64(1)
				value["usage"] = usageValue
			},
		},
		{
			id:              "negative_receipt_extra_top_level_field",
			expectedFailure: "strict_shape_extra_top_level_field",
			priv:            priv,
			mutate: func(value map[string]any) {
				value["unexpected_settlement_field"] = "must-reject"
			},
		},
	}
	out := make([]tupleFixture, 0, len(specs))
	for _, spec := range specs {
		value := cloneMap(base.Value)
		spec.mutate(value)
		fixture, err := newTupleFixture(spec.id, base.RouteSnapshotID, base.SettlementOutputID, base.UsageID, value, spec.priv)
		if err != nil {
			return nil, err
		}
		fixture.BaseTupleID = base.ID
		fixture.ExpectedFailure = spec.expectedFailure
		out = append(out, fixture)
	}
	return out, nil
}

func negativeRangeScenarioFixtures(tuples []tupleFixture) ([]rangeScenario, error) {
	first, err := tupleByID(tuples, "receipt_tuple_v4_failover_upstream_disconnect_prefix")
	if err != nil {
		return nil, err
	}
	second, err := tupleByID(tuples, "receipt_tuple_v4_streaming_tool_call_nonzero_prefix")
	if err != nil {
		return nil, err
	}
	requestID, ok := first.Value["request_id"].(string)
	if !ok {
		return nil, fmt.Errorf("%s request_id is not a string", first.ID)
	}
	return []rangeScenario{
		{
			ID:              "negative_range_overlap",
			RequestID:       requestID,
			ExpectedFailure: "overlapping_ranges",
			Ranges: []rangeFixture{
				rangeFromTuple(first),
				{TupleID: second.ID, Attempt: int64(1), Start: int64(12), End: int64(30)},
			},
		},
		{
			ID:              "negative_range_duplicate",
			RequestID:       requestID,
			ExpectedFailure: "duplicate_ranges",
			Ranges: []rangeFixture{
				rangeFromTuple(first),
				{TupleID: second.ID, Attempt: int64(1), Start: int64(0), End: int64(13)},
			},
		},
		{
			ID:              "negative_range_out_of_order_by_attempt",
			RequestID:       requestID,
			ExpectedFailure: "out_of_order_ranges",
			Ranges: []rangeFixture{
				{TupleID: first.ID, Attempt: int64(0), Start: int64(13), End: int64(30)},
				{TupleID: second.ID, Attempt: int64(1), Start: int64(0), End: int64(13)},
			},
		},
	}, nil
}

func rangeFromTuple(tuple tupleFixture) rangeFixture {
	return rangeFixture{
		TupleID: tuple.ID,
		Attempt: tuple.Value["attempt_n"].(int64),
		Start:   tuple.Value["output_prefix_start_byte"].(int64),
		End:     tuple.Value["output_prefix_end_byte"].(int64),
	}
}

func tupleByID(tuples []tupleFixture, id string) (tupleFixture, error) {
	for _, tuple := range tuples {
		if tuple.ID == id {
			return tuple, nil
		}
	}
	return tupleFixture{}, fmt.Errorf("missing tuple fixture %q", id)
}

func cloneMap(in map[string]any) map[string]any {
	out := make(map[string]any, len(in))
	for key, value := range in {
		if nested, ok := value.(map[string]any); ok {
			out[key] = cloneMap(nested)
		} else {
			out[key] = value
		}
	}
	return out
}

func canonicalAndHash(kind string, value map[string]any) ([]byte, string, error) {
	canonicalValue := jcsValue(value, kind == "settlement_output_v1", nil)
	canonical, err := jcs.Canonicalize(canonicalValue)
	if err != nil {
		return nil, "", err
	}
	return canonical, sha256HexBytes(canonical), nil
}

func jcsValue(value any, rawToolCallArguments bool, path []string) jcs.Value {
	switch typed := value.(type) {
	case map[string]any:
		object := make(map[string]jcs.Value, len(typed))
		for key, member := range typed {
			childPath := append(append([]string(nil), path...), key)
			if rawToolCallArguments && isToolCallArgumentPath(childPath) {
				if raw, ok := member.(string); ok {
					object[key] = jcs.Value{Kind: jcs.KindRawString, RawString: raw}
					continue
				}
			}
			object[key] = jcsValue(member, rawToolCallArguments, childPath)
		}
		return jcs.Value{Kind: jcs.KindObject, Object: object}
	case []any:
		array := make([]jcs.Value, 0, len(typed))
		for _, item := range typed {
			array = append(array, jcsValue(item, rawToolCallArguments, path))
		}
		return jcs.Value{Kind: jcs.KindArray, Array: array}
	case string:
		return jcs.Value{Kind: jcs.KindString, String: typed}
	case int64:
		return jcs.Value{Kind: jcs.KindInt, Int: typed}
	case bool:
		return jcs.Value{Kind: jcs.KindBool, Bool: typed}
	case nil:
		return jcs.Value{Kind: jcs.KindNull}
	default:
		panic(fmt.Sprintf("unsupported v0.4 fixture value %T", value))
	}
}

func isToolCallArgumentPath(path []string) bool {
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

func sha256HexBytes(raw []byte) string {
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

func sortedCopy(in []string) []string {
	out := append([]string(nil), in...)
	sort.Strings(out)
	return out
}

func bytesRange(n int) []byte {
	return bytesRangeFrom(0, n)
}

func bytesRangeFrom(start, n int) []byte {
	out := make([]byte, n)
	for i := range out {
		out[i] = byte(start + i)
	}
	return out
}

func writeJSON(path string, value any) error {
	var b strings.Builder
	encoder := json.NewEncoder(&b)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(value); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(b.String()), 0o644)
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
