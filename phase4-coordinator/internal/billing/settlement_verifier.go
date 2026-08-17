package billing

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/computeintegrity"
)

const (
	SettlementOutcomePending     = "pending"
	SettlementOutcomeVerified    = "verified"
	SettlementOutcomeQuarantined = "quarantined"
	SettlementOutcomeZeroSettled = "zero_settled"

	SettlementReceiptResultValid        = "valid"
	SettlementReceiptResultInvalid      = "invalid"
	SettlementReceiptResultInconclusive = "inconclusive"

	maxSettlementClockSkewMS int64 = 60000
)

var (
	settlementTerminalStates = map[string]struct{}{
		"normal_done": {}, "provider_error": {}, "buyer_cancel": {},
		"gateway_timeout": {}, "upstream_transport_disconnect": {},
	}
	v04SettlementTupleKeys = []string{
		"account_scope", "attempt_n", "catalog_body_digest", "catalog_id",
		"expected_catalog_model_hash", "issued_at_unix_ms", "model_hash",
		"model_id", "output_hash", "output_prefix_end_byte",
		"output_prefix_start_byte", "prompt_hash", "provider_id",
		"provider_receipt_key_id", "receipt_version", "request_id",
		"route_snapshot_digest", "route_snapshot_mode",
		"route_snapshot_policy_version", "signature_key_alg",
		"terminal_state", "terminal_state_ts_unix_ms", "usage",
	}
	v04SettlementUsageKeys = []string{
		"billable_input_tokens", "billable_output_tokens",
		"delivered_output_bytes", "observed_input_tokens",
		"observed_output_tokens",
	}
)

type SettlementVerifyInput struct {
	Header                     string
	ProviderReceiptPubkey      []byte
	RouteSnapshot              RouteSnapshot
	AccountScope               string
	RequestID                  string
	AttemptN                   int64
	ProviderID                 string
	ProviderReceiptKeyID       string
	TerminalState              string
	TerminalStateTSUnixMS      int64
	OutputHash                 string
	OutputPrefixStartByte      int64
	OutputPrefixEndByte        int64
	ExpectedUsage              SettlementUsage
	UsageSource                string
	UsageCrossChecked          bool
	OverlappingOrDuplicate     bool
	ReceiptReceivedUnixMS      int64
	NowUnixMS                  int64
	ReceiptMissing             bool
	TrustRootInconclusive      bool
	CanonicalHashesAvailable   bool
	AlreadyDeadlineQuarantined bool
	TerminalOutcomeFinal       bool
	ComputeIntegrityCapture    *computeintegrity.Capture
}

type SettlementVerifyResult struct {
	Outcome        string                       `json:"outcome"`
	ReceiptResult  string                       `json:"receipt_result"`
	Reason         string                       `json:"reason"`
	ReceiptVersion string                       `json:"receipt_version,omitempty"`
	Facts          *SettlementReceiptFacts      `json:"facts,omitempty"`
	Checks         SettlementVerificationChecks `json:"checks"`
}

type SettlementReceiptFacts struct {
	AccountScope               string `json:"account_scope,omitempty"`
	RequestID                  string `json:"request_id,omitempty"`
	AttemptN                   int64  `json:"attempt_n,omitempty"`
	ProviderID                 string `json:"provider_id,omitempty"`
	ProviderReceiptKeyID       string `json:"provider_receipt_key_id,omitempty"`
	ReceiptVersion             string `json:"receipt_version,omitempty"`
	ModelID                    string `json:"model_id,omitempty"`
	ModelHash                  string `json:"model_hash,omitempty"`
	ExpectedCatalogModelHash   string `json:"expected_catalog_model_hash,omitempty"`
	CatalogID                  string `json:"catalog_id,omitempty"`
	CatalogBodyDigest          string `json:"catalog_body_digest,omitempty"`
	PromptHash                 string `json:"prompt_hash,omitempty"`
	OutputHash                 string `json:"output_hash,omitempty"`
	OutputPrefixStartByte      int64  `json:"output_prefix_start_byte,omitempty"`
	OutputPrefixEndByte        int64  `json:"output_prefix_end_byte,omitempty"`
	RouteSnapshotDigest        string `json:"route_snapshot_digest,omitempty"`
	RouteSnapshotMode          string `json:"route_snapshot_mode,omitempty"`
	RouteSnapshotPolicyVersion string `json:"route_snapshot_policy_version,omitempty"`
	SignatureKeyAlg            string `json:"signature_key_alg,omitempty"`
	TerminalState              string `json:"terminal_state,omitempty"`
	TerminalStateTSUnixMS      int64  `json:"terminal_state_ts_unix_ms,omitempty"`
	IssuedAtUnixMS             int64  `json:"issued_at_unix_ms,omitempty"`
	UsageDigest                string `json:"usage_digest,omitempty"`
	TupleCanonicalSHA256       string `json:"tuple_canonical_sha256,omitempty"`
}

type SettlementVerificationChecks struct {
	SignatureVerified              bool   `json:"signature_verified"`
	RouteSnapshotMatched           bool   `json:"route_snapshot_matched"`
	PromptHashMatched              bool   `json:"prompt_hash_matched"`
	OutputHashMatched              bool   `json:"output_hash_matched"`
	UsageMatched                   bool   `json:"usage_matched"`
	UsageCrossChecked              bool   `json:"usage_cross_checked"`
	NoOverlap                      bool   `json:"no_overlap"`
	TerminalStateMatched           bool   `json:"terminal_state_matched"`
	TimestampWindowValid           bool   `json:"timestamp_window_valid"`
	ComputeIntegrityGate           bool   `json:"compute_integrity_gate"`
	ComputeIntegrityPayable        bool   `json:"compute_integrity_payable"`
	ComputeIntegrityReason         string `json:"compute_integrity_reason,omitempty"`
	ComputeIntegritySnapshotDigest string `json:"compute_integrity_request_start_snapshot_digest,omitempty"`
}

func VerifySettlementReceipt(input SettlementVerifyInput) SettlementVerifyResult {
	return applyComputeIntegrityGate(input, verifySettlementReceiptSPEC022(input))
}

func verifySettlementReceiptSPEC022(input SettlementVerifyInput) SettlementVerifyResult {
	if input.AlreadyDeadlineQuarantined {
		return settlementQuarantined("deadline_quarantined", "")
	}
	if input.TerminalOutcomeFinal {
		return settlementQuarantined("duplicate_receipt_after_terminal", "")
	}
	if input.ReceiptMissing {
		return pendingUntilSettlementDeadline(input, "missing_receipt")
	}
	if input.TrustRootInconclusive {
		return pendingUntilSettlementDeadline(input, "trust_root_inconclusive")
	}
	if !input.CanonicalHashesAvailable {
		return settlementQuarantined("canonical_hash_unavailable", "")
	}
	if input.OverlappingOrDuplicate {
		return settlementQuarantined("overlapping_output_prefix", "")
	}
	checks := SettlementVerificationChecks{NoOverlap: true}
	routeDigest, _, err := input.RouteSnapshot.Digest()
	if err != nil {
		return settlementQuarantined("route_snapshot_invalid", "")
	}
	if input.ReceiptReceivedUnixMS > input.deadlineUnixMS() {
		return settlementQuarantined("receipt_after_deadline", "")
	}
	tuple, signature, raw, parseResult := parseSettlementReceiptV04(input.Header)
	if parseResult.Reason != "" {
		return parseResult
	}
	facts := settlementFacts(tuple, raw)
	if !bytes.Equal(raw, tuple.CanonicalBytes) {
		return settlementInvalidWithFacts("non_canonical_tuple", tuple.ReceiptVersion, facts, checks)
	}
	if tuple.SignatureKeyAlg != "Ed25519" {
		return settlementInvalidWithFacts("signature_key_alg_invalid", tuple.ReceiptVersion, facts, checks)
	}
	if !receiptKeyIDPattern.MatchString(tuple.ProviderReceiptKeyID) {
		return settlementInvalidWithFacts("provider_receipt_key_id_invalid", tuple.ReceiptVersion, facts, checks)
	}
	pinnedKeyID, err := ReceiptKeyID(input.ProviderReceiptPubkey)
	if err != nil || tuple.ProviderReceiptKeyID != pinnedKeyID || tuple.ProviderReceiptKeyID != input.RouteSnapshot.ProviderReceiptKeyID {
		return settlementInvalidWithFacts("provider_receipt_key_id_mismatch", tuple.ReceiptVersion, facts, checks)
	}
	if !ed25519.Verify(ed25519.PublicKey(input.ProviderReceiptPubkey), raw, signature) {
		return settlementInvalidWithFacts("signature_verify_failed", tuple.ReceiptVersion, facts, checks)
	}
	checks.SignatureVerified = true
	if reason := tupleMatchesSettlementContext(tuple, input, routeDigest, &checks); reason != "" {
		return settlementInvalidWithFacts(reason, tuple.ReceiptVersion, facts, checks)
	}
	if reason := tupleSettlementUsage(tuple); reason != "" {
		return settlementInvalidWithFacts(reason, tuple.ReceiptVersion, facts, checks)
	}
	if reason := tupleUsageMatchesLedger(tuple.Usage, input, &checks); reason != "" {
		return settlementInvalidWithFacts(reason, tuple.ReceiptVersion, facts, checks)
	}
	if tuple.TerminalState != "normal_done" && tuple.Usage.DeliveredOutputBytes == 0 {
		return SettlementVerifyResult{Outcome: SettlementOutcomeZeroSettled, ReceiptResult: SettlementReceiptResultValid, Reason: "verified_zero_settlement", ReceiptVersion: tuple.ReceiptVersion, Facts: facts, Checks: checks}
	}
	return SettlementVerifyResult{Outcome: SettlementOutcomeVerified, ReceiptResult: SettlementReceiptResultValid, Reason: "verified_settlement", ReceiptVersion: tuple.ReceiptVersion, Facts: facts, Checks: checks}
}

func applyComputeIntegrityGate(input SettlementVerifyInput, result SettlementVerifyResult) SettlementVerifyResult {
	if input.ComputeIntegrityCapture == nil {
		return result
	}
	capture := *input.ComputeIntegrityCapture
	var snapshotDigest string
	if !capture.Unreadable {
		var err error
		snapshotDigest, err = computeintegrity.RequestStartSnapshotDigest(capture)
		if err != nil {
			capture.Unreadable = true
		}
	}
	decision := computeintegrity.Evaluate(capture)
	outcome, reason := computeintegrity.ApplyGate(result.Outcome, result.Reason, decision)
	result.Outcome = outcome
	result.Reason = reason
	result.Checks.ComputeIntegrityGate = decision.Applies
	result.Checks.ComputeIntegrityPayable = decision.Payable
	if decision.Reason != "" {
		result.Checks.ComputeIntegrityReason = string(decision.Reason)
	}
	if snapshotDigest != "" {
		result.Checks.ComputeIntegritySnapshotDigest = snapshotDigest
	}
	return result
}

func (input SettlementVerifyInput) deadlineUnixMS() int64 {
	return input.TerminalStateTSUnixMS + input.RouteSnapshot.PendingDeadlineSeconds*1000
}

func pendingUntilSettlementDeadline(input SettlementVerifyInput, reason string) SettlementVerifyResult {
	now := input.NowUnixMS
	if now == 0 {
		now = input.ReceiptReceivedUnixMS
	}
	if now > input.deadlineUnixMS() {
		return settlementQuarantined(reason+"_deadline_elapsed", "")
	}
	return SettlementVerifyResult{Outcome: SettlementOutcomePending, ReceiptResult: SettlementReceiptResultInconclusive, Reason: reason}
}

func tupleMatchesSettlementContext(tuple settlementTupleV04, input SettlementVerifyInput, routeDigest string, checks *SettlementVerificationChecks) string {
	if tuple.AccountScope != input.AccountScope || tuple.AccountScope != input.RouteSnapshot.AccountScope {
		return "account_scope_mismatch"
	}
	if tuple.RequestID != input.RequestID || tuple.RequestID != input.RouteSnapshot.RequestID {
		return "request_id_mismatch"
	}
	if tuple.AttemptN != input.AttemptN || tuple.AttemptN != input.RouteSnapshot.AttemptN {
		return "attempt_mismatch"
	}
	if tuple.ProviderID != input.ProviderID || tuple.ProviderID != input.RouteSnapshot.ProviderID {
		return "provider_id_mismatch"
	}
	if tuple.ProviderReceiptKeyID != input.ProviderReceiptKeyID {
		return "provider_receipt_key_id_mismatch"
	}
	if tuple.RouteSnapshotDigest != routeDigest {
		return "route_snapshot_digest_mismatch"
	}
	if tuple.RouteSnapshotMode != input.RouteSnapshot.RouteSnapshotMode {
		return "route_snapshot_mode_mismatch"
	}
	if tuple.RouteSnapshotPolicyVersion != input.RouteSnapshot.RouteSnapshotPolicyVersion {
		return "route_snapshot_policy_version_mismatch"
	}
	if tuple.ModelID != input.RouteSnapshot.ModelID {
		return "model_id_mismatch"
	}
	if tuple.ModelHash != input.RouteSnapshot.ProviderReportedModelHash || tuple.ModelHash != input.RouteSnapshot.ExpectedCatalogModelHash {
		return "model_hash_mismatch"
	}
	if tuple.ExpectedCatalogModelHash != input.RouteSnapshot.ExpectedCatalogModelHash {
		return "expected_catalog_model_hash_mismatch"
	}
	if tuple.CatalogID != input.RouteSnapshot.CatalogID || tuple.CatalogBodyDigest != input.RouteSnapshot.CatalogBodyDigest {
		return "catalog_snapshot_mismatch"
	}
	checks.RouteSnapshotMatched = true
	if tuple.PromptHash != input.RouteSnapshot.PromptHash {
		return "prompt_hash_mismatch"
	}
	checks.PromptHashMatched = true
	if tuple.OutputHash != input.OutputHash {
		return "output_hash_mismatch"
	}
	if tuple.OutputPrefixStartByte != input.OutputPrefixStartByte || tuple.OutputPrefixEndByte != input.OutputPrefixEndByte {
		return "output_prefix_mismatch"
	}
	checks.OutputHashMatched = true
	if _, ok := settlementTerminalStates[tuple.TerminalState]; !ok {
		return "terminal_state_out_of_enum"
	}
	if tuple.TerminalState != input.TerminalState {
		return "terminal_state_mismatch"
	}
	checks.TerminalStateMatched = true
	if tuple.TerminalStateTSUnixMS != input.TerminalStateTSUnixMS {
		return "terminal_state_timestamp_mismatch"
	}
	if tuple.IssuedAtUnixMS < input.RouteSnapshot.RequestStartTSUnixMS-maxSettlementClockSkewMS ||
		tuple.IssuedAtUnixMS > input.ReceiptReceivedUnixMS+maxSettlementClockSkewMS {
		return "issued_at_window_mismatch"
	}
	checks.TimestampWindowValid = true
	return ""
}

func tupleSettlementUsage(tuple settlementTupleV04) string {
	if tuple.OutputPrefixStartByte < 0 || tuple.OutputPrefixEndByte < 0 || tuple.OutputPrefixStartByte > tuple.OutputPrefixEndByte {
		return "output_prefix_invalid"
	}
	u := tuple.Usage
	if u.BillableInputTokens < 0 || u.BillableOutputTokens < 0 || u.DeliveredOutputBytes < 0 || u.ObservedInputTokens < 0 || u.ObservedOutputTokens < 0 {
		return "usage_negative_value"
	}
	if u.DeliveredOutputBytes != tuple.OutputPrefixEndByte-tuple.OutputPrefixStartByte {
		return "usage_delivered_bytes_mismatch"
	}
	switch tuple.TerminalState {
	case "normal_done":
		if u.BillableInputTokens != u.ObservedInputTokens || u.BillableOutputTokens != u.ObservedOutputTokens {
			return "usage_observed_mismatch"
		}
	default:
		if u.DeliveredOutputBytes == 0 {
			if u.BillableInputTokens != 0 || u.BillableOutputTokens != 0 {
				return "usage_zero_prefix_billable_tokens"
			}
		} else if u.BillableInputTokens > u.ObservedInputTokens || u.BillableOutputTokens > u.ObservedOutputTokens {
			return "usage_partial_billable_tokens"
		}
	}
	return ""
}

func tupleUsageMatchesLedger(usage settlementUsageV04, input SettlementVerifyInput, checks *SettlementVerificationChecks) string {
	if !input.UsageCrossChecked {
		return "usage_not_cross_checked"
	}
	if input.UsageSource != UsageSourceCoordinatorObserved {
		return "usage_source_not_settlement_capable"
	}
	checks.UsageCrossChecked = true
	expected := input.ExpectedUsage
	if usage.BillableInputTokens != expected.BillableInputTokens ||
		usage.BillableOutputTokens != expected.BillableOutputTokens ||
		usage.DeliveredOutputBytes != expected.DeliveredOutputBytes ||
		usage.ObservedInputTokens != expected.ObservedInputTokens ||
		usage.ObservedOutputTokens != expected.ObservedOutputTokens {
		return "usage_mismatch"
	}
	checks.UsageMatched = true
	return ""
}

type settlementTupleV04 struct {
	AccountScope               string             `json:"account_scope"`
	CatalogBodyDigest          string             `json:"catalog_body_digest"`
	CatalogID                  string             `json:"catalog_id"`
	ExpectedCatalogModelHash   string             `json:"expected_catalog_model_hash"`
	IssuedAtUnixMS             int64              `json:"issued_at_unix_ms"`
	ModelHash                  string             `json:"model_hash"`
	ModelID                    string             `json:"model_id"`
	OutputHash                 string             `json:"output_hash"`
	OutputPrefixEndByte        int64              `json:"output_prefix_end_byte"`
	OutputPrefixStartByte      int64              `json:"output_prefix_start_byte"`
	PromptHash                 string             `json:"prompt_hash"`
	ProviderID                 string             `json:"provider_id"`
	ProviderReceiptKeyID       string             `json:"provider_receipt_key_id"`
	ReceiptVersion             string             `json:"receipt_version"`
	RequestID                  string             `json:"request_id"`
	RouteSnapshotDigest        string             `json:"route_snapshot_digest"`
	RouteSnapshotMode          string             `json:"route_snapshot_mode"`
	RouteSnapshotPolicyVersion string             `json:"route_snapshot_policy_version"`
	SignatureKeyAlg            string             `json:"signature_key_alg"`
	TerminalState              string             `json:"terminal_state"`
	TerminalStateTSUnixMS      int64              `json:"terminal_state_ts_unix_ms"`
	AttemptN                   int64              `json:"attempt_n"`
	Usage                      settlementUsageV04 `json:"usage"`
	CanonicalBytes             []byte             `json:"-"`
}

type settlementUsageV04 struct {
	BillableInputTokens  int64 `json:"billable_input_tokens"`
	BillableOutputTokens int64 `json:"billable_output_tokens"`
	DeliveredOutputBytes int64 `json:"delivered_output_bytes"`
	ObservedInputTokens  int64 `json:"observed_input_tokens"`
	ObservedOutputTokens int64 `json:"observed_output_tokens"`
}

func parseSettlementReceiptV04(header string) (settlementTupleV04, []byte, []byte, SettlementVerifyResult) {
	tupleRaw, signature, err := splitSettlementReceiptEnvelope(header)
	if err != nil {
		return settlementTupleV04{}, nil, nil, settlementInvalid("receipt_envelope_invalid", "")
	}
	fields, err := decodeSettlementRawObject(tupleRaw)
	if err != nil {
		return settlementTupleV04{}, nil, nil, settlementInvalid("tuple_json_invalid", "")
	}
	rv := settlementRawString(fields, "receipt_version")
	switch {
	case rv == "":
		return settlementTupleV04{}, nil, nil, settlementInvalid("not_settlement_capable", "")
	case rv != "4":
		if rv == "1" || rv == "2" || rv == "3" {
			return settlementTupleV04{}, nil, nil, settlementInvalid("not_settlement_capable", rv)
		}
		return settlementTupleV04{}, nil, nil, SettlementVerifyResult{Outcome: SettlementOutcomeQuarantined, ReceiptResult: SettlementReceiptResultInconclusive, Reason: "unknown_receipt_version", ReceiptVersion: rv}
	}
	if !sameSettlementStringSet(sortedSettlementKeys(fields), v04SettlementTupleKeys) {
		return settlementTupleV04{}, nil, nil, settlementInvalid("tuple_shape_invalid", rv)
	}
	usageFields, err := settlementRawObject(fields, "usage")
	if err != nil || !sameSettlementStringSet(sortedSettlementKeys(usageFields), v04SettlementUsageKeys) {
		return settlementTupleV04{}, nil, nil, settlementInvalid("usage_shape_invalid", rv)
	}
	var decoded any
	dec := json.NewDecoder(bytes.NewReader(tupleRaw))
	dec.UseNumber()
	if err := dec.Decode(&decoded); err != nil {
		return settlementTupleV04{}, nil, nil, settlementInvalid("tuple_json_invalid", rv)
	}
	canonical, err := CanonicalJSON(decoded)
	if err != nil {
		return settlementTupleV04{}, nil, nil, settlementInvalid("tuple_json_invalid", rv)
	}
	var tuple settlementTupleV04
	dec = json.NewDecoder(bytes.NewReader(tupleRaw))
	dec.UseNumber()
	dec.DisallowUnknownFields()
	if err := dec.Decode(&tuple); err != nil {
		return settlementTupleV04{}, nil, nil, settlementInvalid("tuple_type_invalid", rv)
	}
	if err := validateSettlementTupleScalars(tuple); err != nil {
		return settlementTupleV04{}, nil, nil, settlementInvalid(err.Error(), rv)
	}
	tuple.CanonicalBytes = canonical
	return tuple, signature, tupleRaw, SettlementVerifyResult{}
}

func splitSettlementReceiptEnvelope(header string) ([]byte, []byte, error) {
	dot := strings.IndexByte(header, '.')
	if dot <= 0 || dot == len(header)-1 || strings.IndexByte(header[dot+1:], '.') >= 0 {
		return nil, nil, errors.New("bad receipt envelope")
	}
	tupleRaw, err := base64.StdEncoding.DecodeString(header[:dot])
	if err != nil {
		return nil, nil, err
	}
	signature, err := base64.StdEncoding.DecodeString(header[dot+1:])
	if err != nil {
		return nil, nil, err
	}
	if len(signature) != ed25519.SignatureSize {
		return nil, nil, errors.New("bad signature length")
	}
	return tupleRaw, signature, nil
}

func validateSettlementTupleScalars(tuple settlementTupleV04) error {
	for field, value := range map[string]string{
		"account_scope": tuple.AccountScope, "catalog_id": tuple.CatalogID,
		"model_id": tuple.ModelID, "provider_id": tuple.ProviderID,
		"request_id": tuple.RequestID, "route_snapshot_mode": tuple.RouteSnapshotMode,
		"route_snapshot_policy_version": tuple.RouteSnapshotPolicyVersion,
	} {
		if strings.TrimSpace(value) == "" {
			return fmt.Errorf("%s_missing", field)
		}
	}
	for field, value := range map[string]string{
		"catalog_body_digest":         tuple.CatalogBodyDigest,
		"expected_catalog_model_hash": tuple.ExpectedCatalogModelHash,
		"model_hash":                  tuple.ModelHash, "output_hash": tuple.OutputHash,
		"prompt_hash": tuple.PromptHash, "route_snapshot_digest": tuple.RouteSnapshotDigest,
	} {
		if !hex64Pattern.MatchString(value) {
			return fmt.Errorf("%s_invalid", field)
		}
	}
	if tuple.ReceiptVersion != "4" {
		return errors.New("receipt_version_invalid")
	}
	if tuple.IssuedAtUnixMS <= 0 || tuple.TerminalStateTSUnixMS <= 0 {
		return errors.New("timestamp_invalid")
	}
	if tuple.AttemptN < 0 || tuple.OutputPrefixStartByte < 0 || tuple.OutputPrefixEndByte < tuple.OutputPrefixStartByte {
		return errors.New("range_invalid")
	}
	return nil
}

func decodeSettlementRawObject(raw []byte) (map[string]json.RawMessage, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var out map[string]json.RawMessage
	if err := dec.Decode(&out); err != nil {
		return nil, err
	}
	var extra any
	if err := dec.Decode(&extra); err != io.EOF {
		return nil, errors.New("trailing JSON")
	}
	return out, nil
}

func settlementRawString(fields map[string]json.RawMessage, key string) string {
	var out string
	if raw, ok := fields[key]; ok {
		_ = json.Unmarshal(raw, &out)
	}
	return out
}

func settlementRawObject(fields map[string]json.RawMessage, key string) (map[string]json.RawMessage, error) {
	raw, ok := fields[key]
	if !ok {
		return nil, errors.New("missing object")
	}
	return decodeSettlementRawObject(raw)
}

func sortedSettlementKeys(fields map[string]json.RawMessage) []string {
	keys := make([]string, 0, len(fields))
	for key := range fields {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func sameSettlementStringSet(got, want []string) bool {
	if len(got) != len(want) {
		return false
	}
	wantCopy := append([]string(nil), want...)
	sort.Strings(wantCopy)
	for i := range got {
		if got[i] != wantCopy[i] {
			return false
		}
	}
	return true
}

func settlementFacts(tuple settlementTupleV04, _ []byte) *SettlementReceiptFacts {
	sum := sha256.Sum256(tuple.CanonicalBytes)
	usageDigest, _, _ := CanonicalSHA256Hex(map[string]any{
		"billable_input_tokens":  tuple.Usage.BillableInputTokens,
		"billable_output_tokens": tuple.Usage.BillableOutputTokens,
		"delivered_output_bytes": tuple.Usage.DeliveredOutputBytes,
		"observed_input_tokens":  tuple.Usage.ObservedInputTokens,
		"observed_output_tokens": tuple.Usage.ObservedOutputTokens,
	})
	return &SettlementReceiptFacts{
		AccountScope:               tuple.AccountScope,
		RequestID:                  tuple.RequestID,
		AttemptN:                   tuple.AttemptN,
		ProviderID:                 tuple.ProviderID,
		ProviderReceiptKeyID:       tuple.ProviderReceiptKeyID,
		ReceiptVersion:             tuple.ReceiptVersion,
		ModelID:                    tuple.ModelID,
		ModelHash:                  tuple.ModelHash,
		ExpectedCatalogModelHash:   tuple.ExpectedCatalogModelHash,
		CatalogID:                  tuple.CatalogID,
		CatalogBodyDigest:          tuple.CatalogBodyDigest,
		PromptHash:                 tuple.PromptHash,
		OutputHash:                 tuple.OutputHash,
		OutputPrefixStartByte:      tuple.OutputPrefixStartByte,
		OutputPrefixEndByte:        tuple.OutputPrefixEndByte,
		RouteSnapshotDigest:        tuple.RouteSnapshotDigest,
		RouteSnapshotMode:          tuple.RouteSnapshotMode,
		RouteSnapshotPolicyVersion: tuple.RouteSnapshotPolicyVersion,
		SignatureKeyAlg:            tuple.SignatureKeyAlg,
		TerminalState:              tuple.TerminalState,
		TerminalStateTSUnixMS:      tuple.TerminalStateTSUnixMS,
		IssuedAtUnixMS:             tuple.IssuedAtUnixMS,
		UsageDigest:                usageDigest,
		TupleCanonicalSHA256:       hex.EncodeToString(sum[:]),
	}
}

func settlementInvalid(reason, rv string) SettlementVerifyResult {
	return SettlementVerifyResult{Outcome: SettlementOutcomeQuarantined, ReceiptResult: SettlementReceiptResultInvalid, Reason: reason, ReceiptVersion: rv}
}

func settlementInvalidWithFacts(reason, rv string, facts *SettlementReceiptFacts, checks SettlementVerificationChecks) SettlementVerifyResult {
	out := settlementInvalid(reason, rv)
	out.Facts = facts
	out.Checks = checks
	return out
}

func settlementQuarantined(reason, rv string) SettlementVerifyResult {
	return SettlementVerifyResult{Outcome: SettlementOutcomeQuarantined, ReceiptResult: SettlementReceiptResultInvalid, Reason: reason, ReceiptVersion: rv}
}
