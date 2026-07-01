package verify

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
	"regexp"
	"sort"
	"strings"

	"github.com/augstar/macprovider/phase7-verify/internal/jcs"
)

const (
	SettlementOutcomePending     = "pending"
	SettlementOutcomeVerified    = "verified"
	SettlementOutcomeQuarantined = "quarantined"
	SettlementOutcomeZeroSettled = "zero_settled"

	SettlementReceiptResultValid        = "valid"
	SettlementReceiptResultInvalid      = "invalid"
	SettlementReceiptResultInconclusive = "inconclusive"
)

const (
	maxSettlementClockSkewMS         int64 = 60000
	maxPendingReceiptDeadlineSeconds int64 = 900
)

var (
	hex64Re                  = regexp.MustCompile(`^[0-9a-f]{64}$`)
	receiptKeyIDRe           = regexp.MustCompile(`^ed25519-sha256:[0-9a-f]{64}$`)
	v04TerminalStates        = map[string]struct{}{"normal_done": {}, "provider_error": {}, "buyer_cancel": {}, "gateway_timeout": {}, "upstream_transport_disconnect": {}}
	v04ReceiptTupleFieldList = []string{
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
	v04UsageFieldList = []string{
		"billable_input_tokens",
		"billable_output_tokens",
		"delivered_output_bytes",
		"observed_input_tokens",
		"observed_output_tokens",
	}
)

type SettlementUsageEvidence struct {
	BillableInputTokens  int64
	BillableOutputTokens int64
	DeliveredOutputBytes int64
	ObservedInputTokens  int64
	ObservedOutputTokens int64
}

type SettlementVerifyInput struct {
	Header                     string
	ProviderReceiptPubkey      []byte
	RouteSnapshot              SettlementRouteSnapshot
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
	ExpectedUsage              SettlementUsageEvidence
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
}

type SettlementResult struct {
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
	SignatureVerified    bool `json:"signature_verified"`
	RouteSnapshotMatched bool `json:"route_snapshot_matched"`
	PromptHashMatched    bool `json:"prompt_hash_matched"`
	OutputHashMatched    bool `json:"output_hash_matched"`
	UsageMatched         bool `json:"usage_matched"`
	UsageCrossChecked    bool `json:"usage_cross_checked"`
	NoOverlap            bool `json:"no_overlap"`
	TerminalStateMatched bool `json:"terminal_state_matched"`
	TimestampWindowValid bool `json:"timestamp_window_valid"`
}

type SettlementRouteSnapshot struct {
	AccountScope                      string
	RequestID                         string
	AttemptN                          int64
	ProviderID                        string
	ProviderSessionID                 *string
	ProviderGenerationID              *string
	PaidEntrypoint                    string
	ProviderReceiptKeyID              string
	ProviderReceiptKeySource          string
	ModelID                           string
	ProviderReportedModelHash         string
	ExpectedCatalogModelHash          string
	CatalogID                         string
	CatalogBodyDigest                 string
	CatalogSignatureKeyID             string
	CatalogSignaturePubkeyFingerprint string
	CatalogExpiresAtUnixMS            int64
	Spec008HashStatus                 string
	RouteSnapshotPolicyVersion        string
	RouteSnapshotMode                 string
	RouteDecisionTSUnixMS             int64
	RequestStartTSUnixMS              int64
	PendingDeadlineSeconds            int64
	PromptHashBasis                   string
	PromptHash                        string
}

func VerifySettlementReceipt(input SettlementVerifyInput) SettlementResult {
	if input.AlreadyDeadlineQuarantined {
		return settlementQuarantined("deadline_quarantined", "")
	}
	if input.TerminalOutcomeFinal {
		return settlementQuarantined("duplicate_receipt_after_terminal", "")
	}
	if input.ReceiptMissing {
		return pendingUntilDeadline(input, "missing_receipt")
	}
	if input.TrustRootInconclusive {
		return pendingUntilDeadline(input, "trust_root_inconclusive")
	}
	if !input.CanonicalHashesAvailable {
		return settlementQuarantined("canonical_hash_unavailable", "")
	}
	if input.OverlappingOrDuplicate {
		return settlementQuarantined("overlapping_output_prefix", "")
	}
	checks := SettlementVerificationChecks{NoOverlap: true}
	routeDigest, err := input.RouteSnapshot.Digest()
	if err != nil {
		return settlementQuarantined("route_snapshot_invalid", "")
	}
	if input.ReceiptReceivedUnixMS > input.deadlineUnixMS() {
		return settlementQuarantined("receipt_after_deadline", "")
	}
	tuple, signature, raw, parseStatus := parseV04SettlementReceipt(input.Header)
	if parseStatus.Reason != "" {
		if parseStatus.Reason == "unknown_receipt_version" {
			parseStatus.Outcome = SettlementOutcomeQuarantined
		}
		return parseStatus
	}
	facts := settlementFacts(tuple, raw)
	if !bytes.Equal(raw, tuple.CanonicalBytes) {
		return settlementInvalidWithFacts("non_canonical_tuple", tuple.ReceiptVersion, facts, checks)
	}
	if tuple.SignatureKeyAlg != "Ed25519" {
		return settlementInvalidWithFacts("signature_key_alg_invalid", tuple.ReceiptVersion, facts, checks)
	}
	if !receiptKeyIDRe.MatchString(tuple.ProviderReceiptKeyID) {
		return settlementInvalidWithFacts("provider_receipt_key_id_invalid", tuple.ReceiptVersion, facts, checks)
	}
	pinnedKeyID := settlementReceiptKeyID(input.ProviderReceiptPubkey)
	if pinnedKeyID == "" || tuple.ProviderReceiptKeyID != pinnedKeyID || tuple.ProviderReceiptKeyID != input.RouteSnapshot.ProviderReceiptKeyID {
		return settlementInvalidWithFacts("provider_receipt_key_id_mismatch", tuple.ReceiptVersion, facts, checks)
	}
	if !ed25519.Verify(ed25519.PublicKey(input.ProviderReceiptPubkey), raw, signature) {
		return settlementInvalidWithFacts("signature_verify_failed", tuple.ReceiptVersion, facts, checks)
	}
	checks.SignatureVerified = true
	if reason := tupleMatchesRouteAndLedger(tuple, input, routeDigest, &checks); reason != "" {
		return settlementInvalidWithFacts(reason, tuple.ReceiptVersion, facts, checks)
	}
	if reason := tupleUsageChargeability(tuple); reason != "" {
		return settlementInvalidWithFacts(reason, tuple.ReceiptVersion, facts, checks)
	}
	if reason := tupleUsageMatchesLedger(tuple.Usage, input, &checks); reason != "" {
		return settlementInvalidWithFacts(reason, tuple.ReceiptVersion, facts, checks)
	}
	if tuple.TerminalState != "normal_done" && tuple.Usage.DeliveredOutputBytes == 0 {
		return SettlementResult{Outcome: SettlementOutcomeZeroSettled, ReceiptResult: SettlementReceiptResultValid, Reason: "verified_zero_settlement", ReceiptVersion: tuple.ReceiptVersion, Facts: facts, Checks: checks}
	}
	return SettlementResult{Outcome: SettlementOutcomeVerified, ReceiptResult: SettlementReceiptResultValid, Reason: "verified_settlement", ReceiptVersion: tuple.ReceiptVersion, Facts: facts, Checks: checks}
}

func (input SettlementVerifyInput) deadlineUnixMS() int64 {
	return input.TerminalStateTSUnixMS + input.RouteSnapshot.PendingDeadlineSeconds*1000
}

func pendingUntilDeadline(input SettlementVerifyInput, reason string) SettlementResult {
	now := input.NowUnixMS
	if now == 0 {
		now = input.ReceiptReceivedUnixMS
	}
	if now > input.deadlineUnixMS() {
		return settlementQuarantined(reason+"_deadline_elapsed", "")
	}
	return SettlementResult{Outcome: SettlementOutcomePending, ReceiptResult: SettlementReceiptResultInconclusive, Reason: reason}
}

func tupleMatchesRouteAndLedger(tuple v04SettlementTuple, input SettlementVerifyInput, routeDigest string, checks *SettlementVerificationChecks) string {
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
	if _, ok := v04TerminalStates[tuple.TerminalState]; !ok {
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

func tupleUsageChargeability(tuple v04SettlementTuple) string {
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

func tupleUsageMatchesLedger(usage v04SettlementUsage, input SettlementVerifyInput, checks *SettlementVerificationChecks) string {
	if !input.UsageCrossChecked {
		return "usage_not_cross_checked"
	}
	if input.UsageSource != "coordinator_observed" {
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

type v04SettlementTuple struct {
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
	Usage                      v04SettlementUsage `json:"usage"`
	CanonicalBytes             []byte             `json:"-"`
}

type v04SettlementUsage struct {
	BillableInputTokens  int64 `json:"billable_input_tokens"`
	BillableOutputTokens int64 `json:"billable_output_tokens"`
	DeliveredOutputBytes int64 `json:"delivered_output_bytes"`
	ObservedInputTokens  int64 `json:"observed_input_tokens"`
	ObservedOutputTokens int64 `json:"observed_output_tokens"`
}

func parseV04SettlementReceipt(header string) (v04SettlementTuple, []byte, []byte, SettlementResult) {
	tupleRaw, signature, err := splitSettlementHeader(header)
	if err != nil {
		return v04SettlementTuple{}, nil, nil, settlementInvalid("receipt_envelope_invalid", "")
	}
	fields, err := decodeRawObject(tupleRaw)
	if err != nil {
		return v04SettlementTuple{}, nil, nil, settlementInvalid("tuple_json_invalid", "")
	}
	rv := rawStringField(fields, "receipt_version")
	switch {
	case rv == "":
		return v04SettlementTuple{}, nil, nil, settlementInvalid("not_settlement_capable", "")
	case rv != "4":
		if rv == "1" || rv == "2" || rv == "3" {
			return v04SettlementTuple{}, nil, nil, settlementInvalid("not_settlement_capable", rv)
		}
		return v04SettlementTuple{}, nil, nil, SettlementResult{Outcome: SettlementOutcomeQuarantined, ReceiptResult: SettlementReceiptResultInconclusive, Reason: "unknown_receipt_version", ReceiptVersion: rv}
	}
	if !sameStringSet(sortedKeys(fields), v04ReceiptTupleFieldList) {
		return v04SettlementTuple{}, nil, nil, settlementInvalid("tuple_shape_invalid", rv)
	}
	usageFields, err := rawObjectField(fields, "usage")
	if err != nil {
		return v04SettlementTuple{}, nil, nil, settlementInvalid("usage_shape_invalid", rv)
	}
	if !sameStringSet(sortedKeys(usageFields), v04UsageFieldList) {
		return v04SettlementTuple{}, nil, nil, settlementInvalid("usage_shape_invalid", rv)
	}
	canonical, err := jcs.CanonicalizeJSON(tupleRaw)
	if err != nil {
		return v04SettlementTuple{}, nil, nil, settlementInvalid("tuple_json_invalid", rv)
	}
	var tuple v04SettlementTuple
	dec := json.NewDecoder(bytes.NewReader(tupleRaw))
	dec.UseNumber()
	dec.DisallowUnknownFields()
	if err := dec.Decode(&tuple); err != nil {
		return v04SettlementTuple{}, nil, nil, settlementInvalid("tuple_type_invalid", rv)
	}
	if err := validateV04TupleScalars(tuple); err != nil {
		return v04SettlementTuple{}, nil, nil, settlementInvalid(err.Error(), rv)
	}
	tuple.CanonicalBytes = canonical
	return tuple, signature, tupleRaw, SettlementResult{}
}

func splitSettlementHeader(header string) ([]byte, []byte, error) {
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

func validateV04TupleScalars(tuple v04SettlementTuple) error {
	stringFields := map[string]string{
		"account_scope":                 tuple.AccountScope,
		"catalog_id":                    tuple.CatalogID,
		"model_id":                      tuple.ModelID,
		"provider_id":                   tuple.ProviderID,
		"request_id":                    tuple.RequestID,
		"route_snapshot_mode":           tuple.RouteSnapshotMode,
		"route_snapshot_policy_version": tuple.RouteSnapshotPolicyVersion,
	}
	for field, value := range stringFields {
		if strings.TrimSpace(value) == "" {
			return fmt.Errorf("%s_missing", field)
		}
	}
	for field, value := range map[string]string{
		"catalog_body_digest":         tuple.CatalogBodyDigest,
		"expected_catalog_model_hash": tuple.ExpectedCatalogModelHash,
		"model_hash":                  tuple.ModelHash,
		"output_hash":                 tuple.OutputHash,
		"prompt_hash":                 tuple.PromptHash,
		"route_snapshot_digest":       tuple.RouteSnapshotDigest,
	} {
		if !hex64Re.MatchString(value) {
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

func decodeRawObject(raw []byte) (map[string]json.RawMessage, error) {
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

func rawStringField(fields map[string]json.RawMessage, key string) string {
	raw, ok := fields[key]
	if !ok {
		return ""
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return ""
	}
	return s
}

func rawObjectField(fields map[string]json.RawMessage, key string) (map[string]json.RawMessage, error) {
	raw, ok := fields[key]
	if !ok {
		return nil, errors.New("missing object")
	}
	return decodeRawObject(raw)
}

func sortedKeys(fields map[string]json.RawMessage) []string {
	keys := make([]string, 0, len(fields))
	for key := range fields {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func sameStringSet(got, want []string) bool {
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

func (r SettlementRouteSnapshot) Digest() (string, error) {
	if err := r.Validate(); err != nil {
		return "", err
	}
	canonical, err := jcs.Canonicalize(routeSnapshotJCSValue(r))
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(canonical)
	return hex.EncodeToString(sum[:]), nil
}

func (r SettlementRouteSnapshot) Validate() error {
	required := map[string]string{
		"account_scope":                        r.AccountScope,
		"request_id":                           r.RequestID,
		"provider_id":                          r.ProviderID,
		"paid_entrypoint":                      r.PaidEntrypoint,
		"provider_receipt_key_id":              r.ProviderReceiptKeyID,
		"provider_receipt_key_source":          r.ProviderReceiptKeySource,
		"model_id":                             r.ModelID,
		"provider_reported_model_hash":         r.ProviderReportedModelHash,
		"expected_catalog_model_hash":          r.ExpectedCatalogModelHash,
		"catalog_id":                           r.CatalogID,
		"catalog_body_digest":                  r.CatalogBodyDigest,
		"catalog_signature_key_id":             r.CatalogSignatureKeyID,
		"catalog_signature_pubkey_fingerprint": r.CatalogSignaturePubkeyFingerprint,
		"spec008_hash_status":                  r.Spec008HashStatus,
		"route_snapshot_policy_version":        r.RouteSnapshotPolicyVersion,
		"route_snapshot_mode":                  r.RouteSnapshotMode,
		"prompt_hash_basis":                    r.PromptHashBasis,
		"prompt_hash":                          r.PromptHash,
	}
	for field, value := range required {
		if strings.TrimSpace(value) == "" {
			return fmt.Errorf("route snapshot missing %s", field)
		}
	}
	if r.AttemptN < 0 {
		return fmt.Errorf("route snapshot attempt_n must be >= 0")
	}
	if !receiptKeyIDRe.MatchString(r.ProviderReceiptKeyID) {
		return fmt.Errorf("route snapshot provider_receipt_key_id invalid")
	}
	switch r.ProviderReceiptKeySource {
	case "auth_session", "rotation_grace", "operator_pin":
	default:
		return fmt.Errorf("route snapshot provider_receipt_key_source invalid")
	}
	for field, value := range map[string]string{
		"provider_reported_model_hash": r.ProviderReportedModelHash,
		"expected_catalog_model_hash":  r.ExpectedCatalogModelHash,
		"catalog_body_digest":          r.CatalogBodyDigest,
		"prompt_hash":                  r.PromptHash,
	} {
		if !hex64Re.MatchString(value) {
			return fmt.Errorf("route snapshot %s must be 64 lowercase hex chars", field)
		}
	}
	if !receiptKeyIDRe.MatchString(r.CatalogSignaturePubkeyFingerprint) {
		return fmt.Errorf("route snapshot catalog_signature_pubkey_fingerprint invalid")
	}
	if r.CatalogExpiresAtUnixMS <= 0 || r.RouteDecisionTSUnixMS <= 0 || r.RequestStartTSUnixMS <= 0 {
		return fmt.Errorf("route snapshot timestamps must be positive")
	}
	if r.PendingDeadlineSeconds <= 0 || r.PendingDeadlineSeconds > maxPendingReceiptDeadlineSeconds {
		return fmt.Errorf("route snapshot pending_deadline_seconds must be between 1 and %d", maxPendingReceiptDeadlineSeconds)
	}
	return nil
}

func routeSnapshotJCSValue(r SettlementRouteSnapshot) jcs.Value {
	return jcs.Value{Kind: jcs.KindObject, Object: map[string]jcs.Value{
		"account_scope":                        {Kind: jcs.KindString, String: r.AccountScope},
		"attempt_n":                            {Kind: jcs.KindInt, Int: r.AttemptN},
		"catalog_body_digest":                  {Kind: jcs.KindString, String: r.CatalogBodyDigest},
		"catalog_expires_at_unix_ms":           {Kind: jcs.KindInt, Int: r.CatalogExpiresAtUnixMS},
		"catalog_id":                           {Kind: jcs.KindString, String: r.CatalogID},
		"catalog_signature_key_id":             {Kind: jcs.KindString, String: r.CatalogSignatureKeyID},
		"catalog_signature_pubkey_fingerprint": {Kind: jcs.KindString, String: r.CatalogSignaturePubkeyFingerprint},
		"expected_catalog_model_hash":          {Kind: jcs.KindString, String: r.ExpectedCatalogModelHash},
		"model_id":                             {Kind: jcs.KindString, String: r.ModelID},
		"paid_entrypoint":                      {Kind: jcs.KindString, String: r.PaidEntrypoint},
		"pending_deadline_seconds":             {Kind: jcs.KindInt, Int: r.PendingDeadlineSeconds},
		"prompt_hash":                          {Kind: jcs.KindString, String: r.PromptHash},
		"prompt_hash_basis":                    {Kind: jcs.KindString, String: r.PromptHashBasis},
		"provider_generation_id":               nullableJCSString(r.ProviderGenerationID),
		"provider_id":                          {Kind: jcs.KindString, String: r.ProviderID},
		"provider_receipt_key_id":              {Kind: jcs.KindString, String: r.ProviderReceiptKeyID},
		"provider_receipt_key_source":          {Kind: jcs.KindString, String: r.ProviderReceiptKeySource},
		"provider_reported_model_hash":         {Kind: jcs.KindString, String: r.ProviderReportedModelHash},
		"provider_session_id":                  nullableJCSString(r.ProviderSessionID),
		"request_id":                           {Kind: jcs.KindString, String: r.RequestID},
		"request_start_ts_unix_ms":             {Kind: jcs.KindInt, Int: r.RequestStartTSUnixMS},
		"route_decision_ts_unix_ms":            {Kind: jcs.KindInt, Int: r.RouteDecisionTSUnixMS},
		"route_snapshot_mode":                  {Kind: jcs.KindString, String: r.RouteSnapshotMode},
		"route_snapshot_policy_version":        {Kind: jcs.KindString, String: r.RouteSnapshotPolicyVersion},
		"spec008_hash_status":                  {Kind: jcs.KindString, String: r.Spec008HashStatus},
	}}
}

func nullableJCSString(v *string) jcs.Value {
	if v == nil {
		return jcs.Value{Kind: jcs.KindNull}
	}
	return jcs.Value{Kind: jcs.KindString, String: *v}
}

func settlementReceiptKeyID(pubkey []byte) string {
	if len(pubkey) != ed25519.PublicKeySize {
		return ""
	}
	sum := sha256.Sum256(pubkey)
	return "ed25519-sha256:" + hex.EncodeToString(sum[:])
}

func settlementFacts(tuple v04SettlementTuple, _ []byte) *SettlementReceiptFacts {
	sum := sha256.Sum256(tuple.CanonicalBytes)
	usageDigest, _ := settlementUsageDigest(tuple.Usage)
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

func settlementUsageDigest(usage v04SettlementUsage) (string, error) {
	return jcs.SHA256Hex(jcs.Value{Kind: jcs.KindObject, Object: map[string]jcs.Value{
		"billable_input_tokens":  {Kind: jcs.KindInt, Int: usage.BillableInputTokens},
		"billable_output_tokens": {Kind: jcs.KindInt, Int: usage.BillableOutputTokens},
		"delivered_output_bytes": {Kind: jcs.KindInt, Int: usage.DeliveredOutputBytes},
		"observed_input_tokens":  {Kind: jcs.KindInt, Int: usage.ObservedInputTokens},
		"observed_output_tokens": {Kind: jcs.KindInt, Int: usage.ObservedOutputTokens},
	}})
}

func settlementInvalid(reason, rv string) SettlementResult {
	return SettlementResult{Outcome: SettlementOutcomeQuarantined, ReceiptResult: SettlementReceiptResultInvalid, Reason: reason, ReceiptVersion: rv}
}

func settlementInvalidWithFacts(reason, rv string, facts *SettlementReceiptFacts, checks SettlementVerificationChecks) SettlementResult {
	out := settlementInvalid(reason, rv)
	out.Facts = facts
	out.Checks = checks
	return out
}

func settlementQuarantined(reason, rv string) SettlementResult {
	return SettlementResult{Outcome: SettlementOutcomeQuarantined, ReceiptResult: SettlementReceiptResultInvalid, Reason: reason, ReceiptVersion: rv}
}
