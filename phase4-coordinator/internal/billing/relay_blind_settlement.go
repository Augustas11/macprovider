package billing

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/computeintegrity"
)

// SPEC-022 R-13 / SPEC-015 §N.13: the content-free relay-blind settlement
// lane. Its only positive outcome is relay_blind_settled, which is never
// verified and is payable only under the R-7.9 entrypoint, basis, and
// profile binding (payableSettlementOutcomeSQL).
const (
	SettlementOutcomeRelayBlindSettled = "relay_blind_settled"
	// RelayBlindSettlementReceiptVersion is both the §N.13 receipt_version
	// and the verdict receipt_profile of a relay-blind attempt.
	RelayBlindSettlementReceiptVersion = "relay-blind-settlement-v1"
	RelayBlindPrivacyClassNone         = "none"
	RelayBlindPrivacyClassBetaV1       = "operator_constrained_beta_v1"

	relayBlindReceiptMaxEnvelopeBytes = 8192
	relayBlindReceiptMaxTupleBytes    = 4096
	relayBlindReceiptMaxBound         = int64(1<<31 - 1)
)

var (
	relayBlindSettlementTupleKeys = []string{
		"account_scope", "attempt_n", "catalog_body_digest", "catalog_id",
		"expected_catalog_model_hash", "input_token_upper_bound", "issued_at_unix_ms",
		"max_output_tokens", "model_hash", "model_id", "paid_entrypoint", "privacy_class",
		"prompt_hash_basis", "provider_id", "provider_receipt_key_id", "receipt_version",
		"relay_blind_envelope_digest", "relay_blind_execution_auth_digest", "relay_blind_kid",
		"relay_blind_provider_binding_digest", "request_id", "response_body_bytes",
		"response_body_sha256", "route_snapshot_digest", "route_snapshot_mode",
		"route_snapshot_policy_version", "signature_key_alg", "terminal_state",
		"terminal_state_ts_unix_ms", "usage",
	}
	relayBlindSettlementUsageKeys = []string{"input_tokens", "output_tokens"}
	relayBlindDigestPattern       = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)
	relayBlindKIDPattern          = regexp.MustCompile(`^[A-Za-z0-9_-]{22}$`)
)

// RelayBlindDispatchEvidence is the persisted SPEC-041-R005 dispatch row the
// coordinator joins a relay-blind receipt to (R-13.5): the envelope,
// execution-authorization, and provider-binding digests and kid, the
// buyer-declared bounds, the validated input tokens, and the bounded
// completion recorded from the terminal evidence.
type RelayBlindDispatchEvidence struct {
	EnvelopeDigest        string
	ExecutionAuthDigest   string
	ProviderBindingDigest string
	KID                   string
	PrivacyClass          string
	InputTokenUpperBound  int64
	MaxOutputTokens       int64
	ValidatedInputTokens  *int64
	CompletionTokens      *int64
}

// RelayBlindSettlementVerifyInput is everything the R-13.5 verifier compares.
// ResponseBodySHA256 and ResponseBodyBytes are the coordinator's recorded
// digest of the exact response bytes it received (R-3.5); Usage is the
// attempt's recorded ledger usage.
type RelayBlindSettlementVerifyInput struct {
	Envelope                   string
	ProviderReceiptPubkey      []byte
	RouteSnapshot              RouteSnapshot
	AccountScope               string
	RequestID                  string
	AttemptN                   int64
	ProviderID                 string
	TerminalState              string
	TerminalStateTSUnixMS      int64
	ResponseBodySHA256         string
	ResponseBodyBytes          int64
	ResponseDigestAvailable    bool
	Usage                      SettlementUsage
	Dispatch                   *RelayBlindDispatchEvidence
	OverlappingOrDuplicate     bool
	ReceiptReceivedUnixMS      int64
	AlreadyDeadlineQuarantined bool
	TerminalOutcomeFinal       bool
	ComputeIntegrityCapture    *computeintegrity.Capture
}

type relayBlindSettlementTuple struct {
	AccountScope                    string                    `json:"account_scope"`
	AttemptN                        int64                     `json:"attempt_n"`
	CatalogBodyDigest               string                    `json:"catalog_body_digest"`
	CatalogID                       string                    `json:"catalog_id"`
	ExpectedCatalogModelHash        string                    `json:"expected_catalog_model_hash"`
	InputTokenUpperBound            int64                     `json:"input_token_upper_bound"`
	IssuedAtUnixMS                  int64                     `json:"issued_at_unix_ms"`
	MaxOutputTokens                 int64                     `json:"max_output_tokens"`
	ModelHash                       string                    `json:"model_hash"`
	ModelID                         string                    `json:"model_id"`
	PaidEntrypoint                  string                    `json:"paid_entrypoint"`
	PrivacyClass                    string                    `json:"privacy_class"`
	PromptHashBasis                 string                    `json:"prompt_hash_basis"`
	ProviderID                      string                    `json:"provider_id"`
	ProviderReceiptKeyID            string                    `json:"provider_receipt_key_id"`
	ReceiptVersion                  string                    `json:"receipt_version"`
	RelayBlindEnvelopeDigest        string                    `json:"relay_blind_envelope_digest"`
	RelayBlindExecutionAuthDigest   string                    `json:"relay_blind_execution_auth_digest"`
	RelayBlindKID                   string                    `json:"relay_blind_kid"`
	RelayBlindProviderBindingDigest string                    `json:"relay_blind_provider_binding_digest"`
	RequestID                       string                    `json:"request_id"`
	ResponseBodyBytes               int64                     `json:"response_body_bytes"`
	ResponseBodySHA256              string                    `json:"response_body_sha256"`
	RouteSnapshotDigest             string                    `json:"route_snapshot_digest"`
	RouteSnapshotMode               string                    `json:"route_snapshot_mode"`
	RouteSnapshotPolicyVersion      string                    `json:"route_snapshot_policy_version"`
	SignatureKeyAlg                 string                    `json:"signature_key_alg"`
	TerminalState                   string                    `json:"terminal_state"`
	TerminalStateTSUnixMS           int64                     `json:"terminal_state_ts_unix_ms"`
	Usage                           relayBlindSettlementUsage `json:"usage"`
	canonical                       []byte
}

type relayBlindSettlementUsage struct {
	InputTokens  int64 `json:"input_tokens"`
	OutputTokens int64 `json:"output_tokens"`
}

// RelayBlindSnapshot reports whether a route snapshot belongs to the R-13
// lane: the relay-blind entrypoint or the relay-blind basis.
func RelayBlindSnapshot(route RouteSnapshot) bool {
	return route.PaidEntrypoint == PaidEntrypointRelayBlindChat || route.PromptHashBasis == PromptHashBasisRelayBlindEnvelopeV1
}

// VerifyRelayBlindSettlementReceipt is the SPEC-015 §N.13 / SPEC-022 R-13.5
// verifier. It returns relay_blind_settled only when every check passes, and
// it never returns verified.
func VerifyRelayBlindSettlementReceipt(input RelayBlindSettlementVerifyInput) SettlementVerifyResult {
	return applyComputeIntegrityGate(SettlementVerifyInput{ComputeIntegrityCapture: input.ComputeIntegrityCapture}, verifyRelayBlindSettlementReceipt(input))
}

func verifyRelayBlindSettlementReceipt(input RelayBlindSettlementVerifyInput) SettlementVerifyResult {
	if input.AlreadyDeadlineQuarantined {
		return settlementQuarantined("deadline_quarantined", "")
	}
	if input.TerminalOutcomeFinal {
		return settlementQuarantined("duplicate_receipt_after_terminal", "")
	}
	// R-7.10: this verifier never judges a plaintext snapshot.
	if input.RouteSnapshot.PaidEntrypoint != PaidEntrypointRelayBlindChat || input.RouteSnapshot.PromptHashBasis != PromptHashBasisRelayBlindEnvelopeV1 {
		return settlementQuarantined("relay_blind_receipt_on_plaintext_snapshot", RelayBlindSettlementReceiptVersion)
	}
	if len(input.Envelope) > relayBlindReceiptMaxEnvelopeBytes {
		return settlementInvalid("receipt_envelope_oversize", "")
	}
	if input.Dispatch == nil {
		return settlementQuarantined("relay_blind_dispatch_evidence_unavailable", "")
	}
	if !input.ResponseDigestAvailable || !hex64Pattern.MatchString(input.ResponseBodySHA256) || input.ResponseBodyBytes < 0 {
		return settlementQuarantined("response_digest_unavailable", "")
	}
	if input.OverlappingOrDuplicate {
		return settlementQuarantined("overlapping_output_prefix", "")
	}
	routeDigest, _, err := input.RouteSnapshot.Digest()
	if err != nil {
		return settlementQuarantined("route_snapshot_invalid", "")
	}
	if input.ReceiptReceivedUnixMS > input.TerminalStateTSUnixMS+input.RouteSnapshot.PendingDeadlineSeconds*1000 {
		return settlementQuarantined("receipt_after_deadline", "")
	}
	tuple, signature, parsed := parseRelayBlindSettlementReceipt(input.Envelope)
	if parsed.Reason != "" {
		return parsed
	}
	facts := relayBlindSettlementFacts(tuple)
	checks := SettlementVerificationChecks{NoOverlap: true}
	invalid := func(reason string) SettlementVerifyResult {
		return settlementInvalidWithFacts(reason, tuple.ReceiptVersion, facts, checks)
	}
	pinnedKeyID, err := ReceiptKeyID(input.ProviderReceiptPubkey)
	if err != nil || tuple.ProviderReceiptKeyID != pinnedKeyID || tuple.ProviderReceiptKeyID != input.RouteSnapshot.ProviderReceiptKeyID {
		return invalid("provider_receipt_key_id_mismatch")
	}
	if !ed25519.Verify(ed25519.PublicKey(input.ProviderReceiptPubkey), tuple.canonical, signature) {
		return invalid("signature_verify_failed")
	}
	checks.SignatureVerified = true
	route := input.RouteSnapshot
	switch {
	case tuple.AccountScope != input.AccountScope || tuple.AccountScope != route.AccountScope:
		return invalid("account_scope_mismatch")
	case tuple.RequestID != input.RequestID || tuple.RequestID != route.RequestID:
		return invalid("request_id_mismatch")
	case tuple.AttemptN != input.AttemptN || tuple.AttemptN != route.AttemptN:
		return invalid("attempt_mismatch")
	case tuple.ProviderID != input.ProviderID || tuple.ProviderID != route.ProviderID:
		return invalid("provider_id_mismatch")
	case tuple.RouteSnapshotDigest != routeDigest:
		return invalid("route_snapshot_digest_mismatch")
	case tuple.RouteSnapshotMode != route.RouteSnapshotMode:
		return invalid("route_snapshot_mode_mismatch")
	case tuple.RouteSnapshotPolicyVersion != route.RouteSnapshotPolicyVersion:
		return invalid("route_snapshot_policy_version_mismatch")
	case tuple.ModelID != route.ModelID:
		return invalid("model_id_mismatch")
	// R-3.3: receipt.model_hash == provider_reported == expected_catalog.
	case tuple.ModelHash != route.ProviderReportedModelHash || tuple.ModelHash != route.ExpectedCatalogModelHash:
		return invalid("model_hash_mismatch")
	case tuple.ExpectedCatalogModelHash != route.ExpectedCatalogModelHash:
		return invalid("expected_catalog_model_hash_mismatch")
	case tuple.CatalogID != route.CatalogID || tuple.CatalogBodyDigest != route.CatalogBodyDigest:
		return invalid("catalog_snapshot_mismatch")
	}
	checks.RouteSnapshotMatched = true
	dispatch := input.Dispatch
	envelopeHex, err := relayBlindDigestHex(tuple.RelayBlindEnvelopeDigest)
	if err != nil || envelopeHex != route.PromptHash || tuple.RelayBlindEnvelopeDigest != dispatch.EnvelopeDigest {
		return invalid("relay_blind_envelope_digest_mismatch")
	}
	checks.PromptHashMatched = true
	switch {
	case tuple.RelayBlindExecutionAuthDigest != dispatch.ExecutionAuthDigest:
		return invalid("relay_blind_execution_auth_digest_mismatch")
	case tuple.RelayBlindProviderBindingDigest != dispatch.ProviderBindingDigest:
		return invalid("relay_blind_provider_binding_digest_mismatch")
	case tuple.RelayBlindKID != dispatch.KID:
		return invalid("relay_blind_kid_mismatch")
	case tuple.PrivacyClass != dispatch.PrivacyClass:
		return invalid("privacy_class_mismatch")
	}
	if tuple.ResponseBodySHA256 != input.ResponseBodySHA256 || tuple.ResponseBodyBytes != input.ResponseBodyBytes {
		return invalid("response_body_digest_mismatch")
	}
	checks.OutputHashMatched = true
	if tuple.TerminalState != input.TerminalState {
		return invalid("terminal_state_mismatch")
	}
	checks.TerminalStateMatched = true
	if tuple.TerminalStateTSUnixMS != input.TerminalStateTSUnixMS {
		return invalid("terminal_state_timestamp_mismatch")
	}
	if tuple.IssuedAtUnixMS < route.RequestStartTSUnixMS-maxSettlementClockSkewMS ||
		tuple.IssuedAtUnixMS > input.ReceiptReceivedUnixMS+maxSettlementClockSkewMS {
		return invalid("issued_at_window_mismatch")
	}
	checks.TimestampWindowValid = true
	if reason := relayBlindUsageMatches(tuple, input); reason != "" {
		return invalid(reason)
	}
	checks.UsageCrossChecked = true
	checks.UsageMatched = true
	if tuple.TerminalState != TerminalStateNormalDone && tuple.ResponseBodyBytes == 0 {
		return SettlementVerifyResult{Outcome: SettlementOutcomeZeroSettled, ReceiptResult: SettlementReceiptResultValid, Reason: "relay_blind_zero_settlement", ReceiptVersion: tuple.ReceiptVersion, Facts: facts, Checks: checks}
	}
	return SettlementVerifyResult{Outcome: SettlementOutcomeRelayBlindSettled, ReceiptResult: SettlementReceiptResultValid, Reason: "relay_blind_settlement", ReceiptVersion: tuple.ReceiptVersion, Facts: facts, Checks: checks}
}

// relayBlindUsageMatches is SPEC-022 R-3.4.3: provider-signed usage settles
// only within the buyer-declared bounds, equal to the persisted validated
// input tokens and recorded bounded completion, with both bounds equal to the
// reservation and dispatch context, and equal to the recorded ledger usage.
func relayBlindUsageMatches(tuple relayBlindSettlementTuple, input RelayBlindSettlementVerifyInput) string {
	dispatch := input.Dispatch
	if tuple.InputTokenUpperBound != dispatch.InputTokenUpperBound || tuple.MaxOutputTokens != dispatch.MaxOutputTokens {
		return "usage_bound_mismatch"
	}
	if tuple.Usage.InputTokens > tuple.InputTokenUpperBound || tuple.Usage.OutputTokens > tuple.MaxOutputTokens {
		return "usage_exceeds_reservation_bound"
	}
	if dispatch.ValidatedInputTokens == nil || tuple.Usage.InputTokens != *dispatch.ValidatedInputTokens {
		return "usage_validated_input_mismatch"
	}
	if dispatch.CompletionTokens == nil || tuple.Usage.OutputTokens != *dispatch.CompletionTokens {
		return "usage_terminal_completion_mismatch"
	}
	if input.Usage.ObservedInputTokens != tuple.Usage.InputTokens || input.Usage.ObservedOutputTokens != tuple.Usage.OutputTokens {
		return "usage_mismatch"
	}
	return ""
}

func parseRelayBlindSettlementReceipt(envelope string) (relayBlindSettlementTuple, []byte, SettlementVerifyResult) {
	tupleRaw, signature, err := splitRelayBlindSettlementEnvelope(envelope)
	if err != nil {
		return relayBlindSettlementTuple{}, nil, settlementInvalid("receipt_envelope_invalid", "")
	}
	if len(tupleRaw) > relayBlindReceiptMaxTupleBytes {
		return relayBlindSettlementTuple{}, nil, settlementInvalid("receipt_tuple_oversize", "")
	}
	fields, err := decodeSettlementRawObject(tupleRaw)
	if err != nil {
		return relayBlindSettlementTuple{}, nil, settlementInvalid("tuple_json_invalid", "")
	}
	rv := settlementRawString(fields, "receipt_version")
	switch rv {
	case RelayBlindSettlementReceiptVersion:
	case "4":
		// R-4.7 / R-7.10: a v0.4 receipt never settles a relay-blind attempt.
		return relayBlindSettlementTuple{}, nil, settlementInvalid("v04_receipt_on_relay_blind_snapshot", rv)
	default:
		return relayBlindSettlementTuple{}, nil, settlementInvalid("not_relay_blind_settlement_profile", rv)
	}
	if !sameSettlementStringSet(sortedSettlementKeys(fields), relayBlindSettlementTupleKeys) {
		return relayBlindSettlementTuple{}, nil, settlementInvalid("tuple_shape_invalid", rv)
	}
	for _, raw := range fields {
		if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
			return relayBlindSettlementTuple{}, nil, settlementInvalid("tuple_null_field", rv)
		}
	}
	usageFields, err := settlementRawObject(fields, "usage")
	if err != nil || !sameSettlementStringSet(sortedSettlementKeys(usageFields), relayBlindSettlementUsageKeys) {
		return relayBlindSettlementTuple{}, nil, settlementInvalid("usage_shape_invalid", rv)
	}
	for _, raw := range usageFields {
		if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
			return relayBlindSettlementTuple{}, nil, settlementInvalid("tuple_null_field", rv)
		}
	}
	var tuple relayBlindSettlementTuple
	dec := json.NewDecoder(bytes.NewReader(tupleRaw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&tuple); err != nil {
		return relayBlindSettlementTuple{}, nil, settlementInvalid("tuple_type_invalid", rv)
	}
	var decoded any
	dec = json.NewDecoder(bytes.NewReader(tupleRaw))
	dec.UseNumber()
	if err := dec.Decode(&decoded); err != nil {
		return relayBlindSettlementTuple{}, nil, settlementInvalid("tuple_json_invalid", rv)
	}
	canonical, err := CanonicalJSON(decoded)
	if err != nil || !bytes.Equal(canonical, tupleRaw) {
		// Also rejects duplicate members: the decoded map keeps one copy.
		return relayBlindSettlementTuple{}, nil, settlementInvalid("non_canonical_tuple", rv)
	}
	tuple.canonical = tupleRaw
	if reason := validateRelayBlindSettlementTuple(tuple); reason != "" {
		return relayBlindSettlementTuple{}, nil, settlementInvalid(reason, rv)
	}
	return tuple, signature, SettlementVerifyResult{}
}

func splitRelayBlindSettlementEnvelope(envelope string) ([]byte, []byte, error) {
	dot := strings.IndexByte(envelope, '.')
	if dot <= 0 || dot == len(envelope)-1 || strings.IndexByte(envelope[dot+1:], '.') >= 0 {
		return nil, nil, errors.New("bad receipt envelope")
	}
	tupleRaw, err := base64.StdEncoding.Strict().DecodeString(envelope[:dot])
	if err != nil || base64.StdEncoding.EncodeToString(tupleRaw) != envelope[:dot] {
		return nil, nil, errors.New("bad tuple encoding")
	}
	signature, err := base64.StdEncoding.Strict().DecodeString(envelope[dot+1:])
	if err != nil || len(signature) != ed25519.SignatureSize || base64.StdEncoding.EncodeToString(signature) != envelope[dot+1:] {
		return nil, nil, errors.New("bad signature encoding")
	}
	return tupleRaw, signature, nil
}

func validateRelayBlindSettlementTuple(tuple relayBlindSettlementTuple) string {
	for field, value := range map[string]string{
		"account_scope": tuple.AccountScope, "catalog_id": tuple.CatalogID, "model_id": tuple.ModelID,
		"provider_id": tuple.ProviderID, "request_id": tuple.RequestID,
		"route_snapshot_policy_version": tuple.RouteSnapshotPolicyVersion,
	} {
		if !relayBlindPrintableASCII(value) {
			return field + "_invalid"
		}
	}
	for field, value := range map[string]string{
		"catalog_body_digest": tuple.CatalogBodyDigest, "expected_catalog_model_hash": tuple.ExpectedCatalogModelHash,
		"model_hash": tuple.ModelHash, "response_body_sha256": tuple.ResponseBodySHA256,
		"route_snapshot_digest": tuple.RouteSnapshotDigest,
	} {
		if !hex64Pattern.MatchString(value) {
			return field + "_invalid"
		}
	}
	for field, value := range map[string]string{
		"relay_blind_envelope_digest":         tuple.RelayBlindEnvelopeDigest,
		"relay_blind_execution_auth_digest":   tuple.RelayBlindExecutionAuthDigest,
		"relay_blind_provider_binding_digest": tuple.RelayBlindProviderBindingDigest,
	} {
		if _, err := relayBlindDigestHex(value); err != nil {
			return field + "_invalid"
		}
	}
	if !relayBlindKIDPattern.MatchString(tuple.RelayBlindKID) {
		return "relay_blind_kid_invalid"
	}
	switch {
	case tuple.ReceiptVersion != RelayBlindSettlementReceiptVersion:
		return "receipt_version_invalid"
	case tuple.PaidEntrypoint != PaidEntrypointRelayBlindChat:
		return "paid_entrypoint_invalid"
	case tuple.PromptHashBasis != PromptHashBasisRelayBlindEnvelopeV1:
		return "prompt_hash_basis_invalid"
	case tuple.SignatureKeyAlg != "Ed25519":
		return "signature_key_alg_invalid"
	case !receiptKeyIDPattern.MatchString(tuple.ProviderReceiptKeyID):
		return "provider_receipt_key_id_invalid"
	case tuple.PrivacyClass != RelayBlindPrivacyClassNone && tuple.PrivacyClass != RelayBlindPrivacyClassBetaV1:
		return "privacy_class_invalid"
	case tuple.RouteSnapshotMode != RouteSnapshotModeObserve && tuple.RouteSnapshotMode != RouteSnapshotModeEnforce:
		return "route_snapshot_mode_invalid"
	case !terminalStatePattern.MatchString(tuple.TerminalState):
		return "terminal_state_out_of_enum"
	case tuple.AttemptN < 0:
		return "attempt_n_invalid"
	case tuple.IssuedAtUnixMS <= 0 || tuple.TerminalStateTSUnixMS <= 0:
		return "timestamp_invalid"
	case tuple.InputTokenUpperBound < 1 || tuple.InputTokenUpperBound > relayBlindReceiptMaxBound ||
		tuple.MaxOutputTokens < 1 || tuple.MaxOutputTokens > relayBlindReceiptMaxBound:
		return "usage_bound_invalid"
	case tuple.ResponseBodyBytes < 0 || tuple.Usage.InputTokens < 0 || tuple.Usage.OutputTokens < 0:
		return "usage_negative_value"
	}
	return ""
}

func relayBlindPrintableASCII(value string) bool {
	if len(value) < 1 || len(value) > 256 {
		return false
	}
	for i := 0; i < len(value); i++ {
		if value[i] < 0x20 || value[i] > 0x7e {
			return false
		}
	}
	return true
}

// relayBlindDigestHex decodes a 43-byte canonical unpadded base64url SHA-256
// digest (SPEC-041) to lowercase hex.
func relayBlindDigestHex(value string) (string, error) {
	if !relayBlindDigestPattern.MatchString(value) {
		return "", errors.New("relay-blind digest must be 43-byte base64url")
	}
	raw, err := base64.RawURLEncoding.Strict().DecodeString(value)
	if err != nil || len(raw) != sha256.Size || base64.RawURLEncoding.EncodeToString(raw) != value {
		return "", errors.New("relay-blind digest is not canonical")
	}
	return hex.EncodeToString(raw), nil
}

func relayBlindSettlementFacts(tuple relayBlindSettlementTuple) *SettlementReceiptFacts {
	sum := sha256.Sum256(tuple.canonical)
	usageDigest, _, _ := CanonicalSHA256Hex(map[string]any{
		"input_tokens":  tuple.Usage.InputTokens,
		"output_tokens": tuple.Usage.OutputTokens,
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
		OutputHash:                 tuple.ResponseBodySHA256,
		OutputPrefixEndByte:        tuple.ResponseBodyBytes,
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

// RelayBlindSettlementReceiptIngestionInput carries one §N.13 envelope and the
// persisted dispatch row it must join (R-13.5).
type RelayBlindSettlementReceiptIngestionInput struct {
	SettlementReceiptIdentity
	Envelope              string
	ProviderReceiptPubkey []byte
	Dispatch              *RelayBlindDispatchEvidence
	receiptReceivedUnixMS int64
}

// WithReceivedAt keeps the first observation through recovery retries.
func (in RelayBlindSettlementReceiptIngestionInput) WithReceivedAt(unixMS int64) RelayBlindSettlementReceiptIngestionInput {
	if unixMS > 0 {
		in.receiptReceivedUnixMS = unixMS
	}
	return in
}

// IngestRelayBlindSettlementReceipt verifies a SPEC-015 §N.13 receipt against
// the attempt's persisted route snapshot, attempt output, and dispatch row,
// and records the verdict with the same terminal and audit rules as v0.4.
func (s *Store) IngestRelayBlindSettlementReceipt(ctx context.Context, input RelayBlindSettlementReceiptIngestionInput) (SettlementReceiptState, error) {
	if err := input.SettlementReceiptIdentity.validate(); err != nil {
		return SettlementReceiptState{}, err
	}
	if input.Envelope == "" {
		return SettlementReceiptState{}, fmt.Errorf("relay-blind settlement receipt is required")
	}
	if len(input.ProviderReceiptPubkey) == 0 {
		return SettlementReceiptState{}, fmt.Errorf("provider receipt pubkey is required")
	}
	receivedAt := input.receiptReceivedUnixMS
	if receivedAt == 0 {
		receivedAt = s.nowUTC().UnixMilli()
	}
	return s.applySettlementReceiptVerdict(ctx, input.SettlementReceiptIdentity, true, receivedAt, func(evidence settlementEvidence, alreadyTerminal bool) SettlementVerifyResult {
		return VerifyRelayBlindSettlementReceipt(RelayBlindSettlementVerifyInput{
			Envelope:                input.Envelope,
			ProviderReceiptPubkey:   input.ProviderReceiptPubkey,
			RouteSnapshot:           evidence.route,
			AccountScope:            input.AccountScope,
			RequestID:               input.RequestID,
			AttemptN:                input.AttemptN,
			ProviderID:              input.ProviderID,
			TerminalState:           evidence.attempt.TerminalState,
			TerminalStateTSUnixMS:   evidence.attempt.TerminalStateTSUnixMS,
			ResponseBodySHA256:      evidence.attempt.OutputHash,
			ResponseBodyBytes:       evidence.attempt.OutputPrefixEndByte - evidence.attempt.OutputPrefixStartByte,
			ResponseDigestAvailable: evidence.attempt.OutputAvailable && evidence.attempt.OutputHash != "",
			Usage:                   evidence.attempt.Usage,
			Dispatch:                input.Dispatch,
			OverlappingOrDuplicate:  evidence.attempt.OverlappingOrDuplicate,
			ReceiptReceivedUnixMS:   receivedAt,
			TerminalOutcomeFinal:    alreadyTerminal,
			ComputeIntegrityCapture: evidence.computeIntegrityCapture,
		})
	})
}

// payableSettlementOutcomeSQL is the SPEC-022 R-7.9 outcome predicate every
// money-movement query shares: verified, or relay_blind_settled bound to the
// relay-blind entrypoint and basis on the snapshot and to the relay-blind
// profile on the verdict. Positive settlement never rests on the outcome
// string alone. srv and srs are the verdict and route-snapshot aliases.
func payableSettlementOutcomeSQL(srv, srs string) string {
	return "(" + srv + ".settlement_outcome = '" + SettlementOutcomeVerified + "' OR (" +
		srv + ".settlement_outcome = '" + SettlementOutcomeRelayBlindSettled + "'" +
		" AND " + srv + ".receipt_profile = '" + RelayBlindSettlementReceiptVersion + "'" +
		" AND " + srv + ".receipt_version = '" + RelayBlindSettlementReceiptVersion + "'" +
		" AND " + srv + ".paid_entrypoint = '" + PaidEntrypointRelayBlindChat + "'" +
		" AND " + srs + ".paid_entrypoint = '" + PaidEntrypointRelayBlindChat + "'" +
		" AND " + srs + ".prompt_hash_basis = '" + PromptHashBasisRelayBlindEnvelopeV1 + "'))"
}

// relayBlindSettledBound reports the R-7.9 binding for one verdict row read
// in Go (the finality lookup).
func relayBlindSettledBound(receiptProfile, receiptVersion, verdictEntrypoint, snapshotEntrypoint, snapshotBasis string) bool {
	return receiptProfile == RelayBlindSettlementReceiptVersion && receiptVersion == RelayBlindSettlementReceiptVersion &&
		verdictEntrypoint == PaidEntrypointRelayBlindChat && snapshotEntrypoint == PaidEntrypointRelayBlindChat &&
		snapshotBasis == PromptHashBasisRelayBlindEnvelopeV1
}
