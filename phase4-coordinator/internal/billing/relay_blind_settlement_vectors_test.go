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

	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
)

// The SPEC-015 §N.13 shared parity vectors. The Go coordinator verifier and
// the Swift provider builder both consume this one file. Regenerate with
// MACPROVIDER_REGEN_FIXTURES=1 go test ./internal/billing -run '^TestRelayBlindSettlementVectorsGenerate$'
var relayBlindVectorPath = filepath.Join("..", "..", "..", "test", "fixtures", "receipts", "relay-blind-settlement-v1.json")

type relayBlindVectorFile struct {
	Schema              string                   `json:"schema"`
	Profile             string                   `json:"profile"`
	Note                string                   `json:"note"`
	SigningSeedB64      string                   `json:"signing_seed_b64"`
	SigningPublicB64    string                   `json:"signing_public_key_b64"`
	ReceiptKeyID        string                   `json:"provider_receipt_key_id"`
	RouteSnapshot       map[string]any           `json:"route_snapshot"`
	RouteSnapshotDigest string                   `json:"route_snapshot_digest"`
	Dispatch            relayBlindVectorDispatch `json:"dispatch"`
	ReceivedAtUnixMS    int64                    `json:"received_at_unix_ms"`
	Positive            []relayBlindVectorCase   `json:"positive"`
	Negative            []relayBlindVectorCase   `json:"negative"`
}

type relayBlindVectorDispatch struct {
	EnvelopeDigest        string `json:"envelope_digest"`
	ExecutionAuthDigest   string `json:"execution_auth_digest"`
	ProviderBindingDigest string `json:"provider_binding_digest"`
	KID                   string `json:"kid"`
	InputTokenUpperBound  int64  `json:"input_token_upper_bound"`
	MaxOutputTokens       int64  `json:"max_output_tokens"`
	ValidatedInputTokens  int64  `json:"validated_input_tokens"`
}

type relayBlindVectorCase struct {
	ID              string          `json:"id"`
	Stream          bool            `json:"stream"`
	Tuple           json.RawMessage `json:"tuple,omitempty"`
	JCSUTF8         string          `json:"jcs_utf8,omitempty"`
	SignatureB64    string          `json:"signature_b64,omitempty"`
	Envelope        string          `json:"envelope"`
	ExpectedOutcome string          `json:"expected_outcome"`
	ExpectedReason  string          `json:"expected_reason"`
}

func relayBlindVectorKey() ed25519.PrivateKey {
	seed := sha256.Sum256([]byte("macprovider SPEC-015 relay-blind-settlement-v1 parity vector key; tests only"))
	return ed25519.NewKeyFromSeed(seed[:])
}

func relayBlindVectorDigest(label string) string {
	sum := sha256.Sum256([]byte(label))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

func relayBlindVectorSnapshot(keyID string) RouteSnapshot {
	session := "session-vector"
	envelopeHex, _ := relayBlindDigestHex(relayBlindVectorDigest("vector envelope bytes"))
	return RouteSnapshot{
		AccountScope:                       "acct_sha256:" + strings.Repeat("1", 64),
		RequestID:                          "coordinator-request-vector",
		AttemptN:                           0,
		ProviderID:                         "provider-vector",
		ProviderSessionID:                  &session,
		PaidEntrypoint:                     PaidEntrypointRelayBlindChat,
		ProviderReceiptKeyID:               keyID,
		ProviderReceiptKeySource:           "auth_session",
		ModelID:                            "mlx-community/Qwen3-8B-4bit",
		ProviderReportedModelHash:          strings.Repeat("3", 64),
		ProviderReportedModelHashAlgorithm: modelidentity.SnapshotManifestV1,
		ExpectedCatalogModelHash:           strings.Repeat("3", 64),
		ExpectedCatalogModelHashAlgorithm:  modelidentity.SnapshotManifestV1,
		CatalogID:                          "catalog-vector",
		CatalogBodyDigest:                  strings.Repeat("4", 64),
		CatalogSignatureKeyID:              "catalog-key-vector",
		CatalogSignaturePubkeyFingerprint:  "ed25519-sha256:" + strings.Repeat("5", 64),
		CatalogExpiresAtUnixMS:             1880000000000,
		Spec008HashStatus:                  "hash_verified",
		RouteSnapshotPolicyVersion:         RouteSnapshotPolicyVersion,
		RouteSnapshotMode:                  RouteSnapshotModeEnforce,
		RouteDecisionTSUnixMS:              1780000000100,
		RequestStartTSUnixMS:               1780000000000,
		PendingDeadlineSeconds:             300,
		PromptHashBasis:                    PromptHashBasisRelayBlindEnvelopeV1,
		PromptHash:                         envelopeHex,
		RelayBlindProviderBindingDigest:    relayBlindVectorDigest("vector provider binding"),
	}
}

func relayBlindVectorDispatchRow() relayBlindVectorDispatch {
	return relayBlindVectorDispatch{
		EnvelopeDigest:        relayBlindVectorDigest("vector envelope bytes"),
		ExecutionAuthDigest:   relayBlindVectorDigest("vector execution authorization"),
		ProviderBindingDigest: relayBlindVectorDigest("vector provider binding"),
		KID:                   base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x6b}, 16)),
		InputTokenUpperBound:  4096,
		MaxOutputTokens:       512,
		ValidatedInputTokens:  37,
	}
}

// relayBlindVectorTuple is the receipt an honest provider signs for one
// attempt of the vector snapshot.
func relayBlindVectorTuple(snapshotDigest, keyID string, dispatch relayBlindVectorDispatch, body string, terminal string, output int64, privacy string) map[string]any {
	sum := sha256.Sum256([]byte(body))
	return map[string]any{
		"account_scope":                       "acct_sha256:" + strings.Repeat("1", 64),
		"attempt_n":                           int64(0),
		"catalog_body_digest":                 strings.Repeat("4", 64),
		"catalog_id":                          "catalog-vector",
		"expected_catalog_model_hash":         strings.Repeat("3", 64),
		"input_token_upper_bound":             dispatch.InputTokenUpperBound,
		"issued_at_unix_ms":                   int64(1780000005100),
		"max_output_tokens":                   dispatch.MaxOutputTokens,
		"model_hash":                          strings.Repeat("3", 64),
		"model_id":                            "mlx-community/Qwen3-8B-4bit",
		"paid_entrypoint":                     PaidEntrypointRelayBlindChat,
		"privacy_class":                       privacy,
		"prompt_hash_basis":                   PromptHashBasisRelayBlindEnvelopeV1,
		"provider_id":                         "provider-vector",
		"provider_receipt_key_id":             keyID,
		"receipt_version":                     RelayBlindSettlementReceiptVersion,
		"relay_blind_envelope_digest":         dispatch.EnvelopeDigest,
		"relay_blind_execution_auth_digest":   dispatch.ExecutionAuthDigest,
		"relay_blind_kid":                     dispatch.KID,
		"relay_blind_provider_binding_digest": dispatch.ProviderBindingDigest,
		"request_id":                          "coordinator-request-vector",
		"response_body_bytes":                 int64(len(body)),
		"response_body_sha256":                hex.EncodeToString(sum[:]),
		"route_snapshot_digest":               snapshotDigest,
		"route_snapshot_mode":                 RouteSnapshotModeEnforce,
		"route_snapshot_policy_version":       RouteSnapshotPolicyVersion,
		"signature_key_alg":                   "Ed25519",
		"terminal_state":                      terminal,
		"terminal_state_ts_unix_ms":           int64(1780000005000),
		"usage":                               map[string]any{"input_tokens": dispatch.ValidatedInputTokens, "output_tokens": output},
	}
}

func relayBlindVectorSign(t *testing.T, key ed25519.PrivateKey, raw []byte) (string, string) {
	t.Helper()
	signature := ed25519.Sign(key, raw)
	return base64.StdEncoding.EncodeToString(signature), base64.StdEncoding.EncodeToString(raw) + "." + base64.StdEncoding.EncodeToString(signature)
}

func relayBlindVectorCanonical(t *testing.T, tuple map[string]any) []byte {
	t.Helper()
	raw, err := CanonicalJSON(tuple)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

const (
	relayBlindVectorNonStreamBody = `{"id":"chatcmpl-vector","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"vector"},"finish_reason":"stop"}]}`
	relayBlindVectorStreamBody    = "data: {\"choices\":[{\"delta\":{\"content\":\"vec\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"tor\"}}]}\n\ndata: [DONE]\n\n"
)

func buildRelayBlindVectors(t *testing.T) relayBlindVectorFile {
	t.Helper()
	key := relayBlindVectorKey()
	public := key.Public().(ed25519.PublicKey)
	keyID, _ := ReceiptKeyID(public)
	snapshot := relayBlindVectorSnapshot(keyID)
	digest, _, err := snapshot.Digest()
	if err != nil {
		t.Fatal(err)
	}
	var snapshotValue map[string]any
	rendered, _ := json.Marshal(snapshot.Value())
	_ = json.Unmarshal(rendered, &snapshotValue)
	dispatch := relayBlindVectorDispatchRow()
	out := relayBlindVectorFile{
		Schema:  "macprovider.spec015.relay-blind-settlement-v1.vectors.v1",
		Profile: RelayBlindSettlementReceiptVersion,
		Note: "Test-only key derived as SHA-256 of a fixed label. Envelope = base64std(JCS(T)) + '.' + base64std(Ed25519(JCS(T))), " +
			"standard padded base64. Go signs with deterministic RFC 8032 Ed25519; a hedged signer must match jcs_utf8 byte for byte and verify, not reproduce, signature_b64.",
		SigningSeedB64:      base64.StdEncoding.EncodeToString(key.Seed()),
		SigningPublicB64:    base64.StdEncoding.EncodeToString(public),
		ReceiptKeyID:        keyID,
		RouteSnapshot:       snapshotValue,
		RouteSnapshotDigest: digest,
		Dispatch:            dispatch,
		ReceivedAtUnixMS:    1780000005200,
	}
	positive := func(id string, stream bool, body, terminal string, output int64, privacy, outcome, reason string) {
		tuple := relayBlindVectorTuple(digest, keyID, dispatch, body, terminal, output, privacy)
		raw := relayBlindVectorCanonical(t, tuple)
		signature, envelope := relayBlindVectorSign(t, key, raw)
		out.Positive = append(out.Positive, relayBlindVectorCase{ID: id, Stream: stream, Tuple: raw, JCSUTF8: string(raw), SignatureB64: signature, Envelope: envelope, ExpectedOutcome: outcome, ExpectedReason: reason})
	}
	positive("nonstream_normal_done", false, relayBlindVectorNonStreamBody, TerminalStateNormalDone, 9, RelayBlindPrivacyClassNone, SettlementOutcomeRelayBlindSettled, "relay_blind_settlement")
	positive("stream_normal_done", true, relayBlindVectorStreamBody, TerminalStateNormalDone, 2, RelayBlindPrivacyClassNone, SettlementOutcomeRelayBlindSettled, "relay_blind_settlement")
	positive("stream_privacy_normal_done", true, relayBlindVectorStreamBody, TerminalStateNormalDone, 2, RelayBlindPrivacyClassBetaV1, SettlementOutcomeRelayBlindSettled, "relay_blind_settlement")
	positive("stream_provider_error_zero_bytes", true, "", TerminalStateProviderError, 0, RelayBlindPrivacyClassNone, SettlementOutcomeZeroSettled, "relay_blind_zero_settlement")

	negative := func(id string, mutate func(map[string]any), rawOverride func([]byte) []byte, reason string) {
		tuple := relayBlindVectorTuple(digest, keyID, dispatch, relayBlindVectorNonStreamBody, TerminalStateNormalDone, 9, RelayBlindPrivacyClassNone)
		if mutate != nil {
			mutate(tuple)
		}
		raw := relayBlindVectorCanonical(t, tuple)
		if rawOverride != nil {
			raw = rawOverride(raw)
		}
		_, envelope := relayBlindVectorSign(t, key, raw)
		out.Negative = append(out.Negative, relayBlindVectorCase{ID: id, Envelope: envelope, ExpectedOutcome: SettlementOutcomeQuarantined, ExpectedReason: reason})
	}
	negative("wrong_receipt_version", func(m map[string]any) { m["receipt_version"] = "relay-blind-settlement-v2" }, nil, "not_relay_blind_settlement_profile")
	negative("v04_receipt_version", func(m map[string]any) { m["receipt_version"] = "4" }, nil, "v04_receipt_on_relay_blind_snapshot")
	negative("wrong_entrypoint", func(m map[string]any) { m["paid_entrypoint"] = PaidEntrypointCoordinatorBuyerChat }, nil, "paid_entrypoint_invalid")
	negative("wrong_basis", func(m map[string]any) { m["prompt_hash_basis"] = PromptHashBasisCoordinatorV1 }, nil, "prompt_hash_basis_invalid")
	negative("extra_field", func(m map[string]any) { m["prompt_hash"] = strings.Repeat("6", 64) }, nil, "tuple_shape_invalid")
	negative("missing_field", func(m map[string]any) { delete(m, "relay_blind_kid") }, nil, "tuple_shape_invalid")
	negative("null_field", func(m map[string]any) { m["model_hash"] = nil }, nil, "tuple_null_field")
	negative("non_canonical_whitespace", nil, func(raw []byte) []byte { return append([]byte(" "), raw...) }, "non_canonical_tuple")
	negative("duplicate_member", nil, func(raw []byte) []byte {
		return append([]byte(`{"account_scope":"x",`), raw[1:]...)
	}, "non_canonical_tuple")
	negative("non_integer_number", nil, func(raw []byte) []byte {
		return bytes.Replace(raw, []byte(`"attempt_n":0`), []byte(`"attempt_n":0.5`), 1)
	}, "tuple_type_invalid")
	negative("oversized_tuple", func(m map[string]any) { m["catalog_id"] = strings.Repeat("c", 4100) }, nil, "receipt_tuple_oversize")
	negative("usage_above_input_bound", func(m map[string]any) {
		m["usage"] = map[string]any{"input_tokens": dispatch.InputTokenUpperBound + 1, "output_tokens": int64(9)}
	}, nil, "usage_exceeds_reservation_bound")
	negative("usage_above_output_bound", func(m map[string]any) {
		m["usage"] = map[string]any{"input_tokens": dispatch.ValidatedInputTokens, "output_tokens": dispatch.MaxOutputTokens + 1}
	}, nil, "usage_exceeds_reservation_bound")
	negative("v04_tuple", nil, func([]byte) []byte {
		return []byte(`{"account_scope":"acct","attempt_n":0,"receipt_version":"4"}`)
	}, "v04_receipt_on_relay_blind_snapshot")
	return out
}

func TestRelayBlindSettlementVectorsGenerate(t *testing.T) {
	if os.Getenv("MACPROVIDER_REGEN_FIXTURES") != "1" {
		t.Skip("set MACPROVIDER_REGEN_FIXTURES=1 to regenerate the shared vectors")
	}
	raw, err := json.MarshalIndent(buildRelayBlindVectors(t), "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(relayBlindVectorPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(relayBlindVectorPath, append(raw, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
}

func loadRelayBlindVectors(t *testing.T) relayBlindVectorFile {
	t.Helper()
	raw, err := os.ReadFile(relayBlindVectorPath)
	if err != nil {
		t.Fatalf("read shared vectors: %v", err)
	}
	var file relayBlindVectorFile
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatal(err)
	}
	want, _ := json.MarshalIndent(buildRelayBlindVectors(t), "", "  ")
	if !bytes.Equal(bytes.TrimSpace(raw), want) {
		t.Fatal("shared vectors are stale; regenerate with MACPROVIDER_REGEN_FIXTURES=1")
	}
	return file
}

func relayBlindVectorInput(t *testing.T, file relayBlindVectorFile, envelope string, body string, terminal string, output int64) RelayBlindSettlementVerifyInput {
	t.Helper()
	public, _ := base64.StdEncoding.DecodeString(file.SigningPublicB64)
	snapshot := relayBlindVectorSnapshot(file.ReceiptKeyID)
	sum := sha256.Sum256([]byte(body))
	validated, completion := file.Dispatch.ValidatedInputTokens, output
	return RelayBlindSettlementVerifyInput{
		Envelope: envelope, ProviderReceiptPubkey: public, RouteSnapshot: snapshot,
		AccountScope: snapshot.AccountScope, RequestID: snapshot.RequestID, AttemptN: snapshot.AttemptN, ProviderID: snapshot.ProviderID,
		TerminalState: terminal, TerminalStateTSUnixMS: 1780000005000,
		ResponseBodySHA256: hex.EncodeToString(sum[:]), ResponseBodyBytes: int64(len(body)), ResponseDigestAvailable: true,
		Usage: SettlementUsage{ObservedInputTokens: validated, ObservedOutputTokens: output, BillableInputTokens: validated, BillableOutputTokens: output},
		Dispatch: &RelayBlindDispatchEvidence{
			EnvelopeDigest: file.Dispatch.EnvelopeDigest, ExecutionAuthDigest: file.Dispatch.ExecutionAuthDigest,
			ProviderBindingDigest: file.Dispatch.ProviderBindingDigest, KID: file.Dispatch.KID, PrivacyClass: RelayBlindPrivacyClassNone,
			InputTokenUpperBound: file.Dispatch.InputTokenUpperBound, MaxOutputTokens: file.Dispatch.MaxOutputTokens,
			ValidatedInputTokens: &validated, CompletionTokens: &completion,
		},
		ReceiptReceivedUnixMS: file.ReceivedAtUnixMS,
	}
}

// SPEC-015 §N.13 item 7: every shared vector passes the Go verifier exactly.
func TestRelayBlindSettlementSharedVectors(t *testing.T) {
	file := loadRelayBlindVectors(t)
	if len(file.Positive) < 2 || len(file.Negative) < 10 {
		t.Fatalf("vector file too small: %d positive, %d negative", len(file.Positive), len(file.Negative))
	}
	for _, vector := range file.Positive {
		t.Run(vector.ID, func(t *testing.T) {
			body, terminal, output := relayBlindVectorNonStreamBody, TerminalStateNormalDone, int64(9)
			privacy := RelayBlindPrivacyClassNone
			switch vector.ID {
			case "stream_normal_done":
				body, output = relayBlindVectorStreamBody, 2
			case "stream_privacy_normal_done":
				body, output, privacy = relayBlindVectorStreamBody, 2, RelayBlindPrivacyClassBetaV1
			case "stream_provider_error_zero_bytes":
				body, terminal, output = "", TerminalStateProviderError, 0
			}
			input := relayBlindVectorInput(t, file, vector.Envelope, body, terminal, output)
			input.Dispatch.PrivacyClass = privacy
			got := VerifyRelayBlindSettlementReceipt(input)
			if got.Outcome != vector.ExpectedOutcome || got.Reason != vector.ExpectedReason || got.ReceiptResult != SettlementReceiptResultValid {
				t.Fatalf("got %s/%s/%s want %s/%s", got.Outcome, got.ReceiptResult, got.Reason, vector.ExpectedOutcome, vector.ExpectedReason)
			}
			if got.Outcome == SettlementOutcomeVerified {
				t.Fatal("relay-blind receipt reported verified")
			}
			var tuple any
			dec := json.NewDecoder(bytes.NewReader(vector.Tuple))
			dec.UseNumber()
			if err := dec.Decode(&tuple); err != nil {
				t.Fatal(err)
			}
			canonical, err := CanonicalJSON(tuple)
			if err != nil || string(canonical) != vector.JCSUTF8 || !strings.HasPrefix(vector.Envelope, base64.StdEncoding.EncodeToString(canonical)+".") {
				t.Fatal("vector tuple, jcs_utf8, and envelope disagree")
			}
		})
	}
	for _, vector := range file.Negative {
		t.Run(vector.ID, func(t *testing.T) {
			got := VerifyRelayBlindSettlementReceipt(relayBlindVectorInput(t, file, vector.Envelope, relayBlindVectorNonStreamBody, TerminalStateNormalDone, 9))
			if got.Outcome != SettlementOutcomeQuarantined || got.Reason != vector.ExpectedReason {
				t.Fatalf("got %s/%s want quarantined/%s", got.Outcome, got.Reason, vector.ExpectedReason)
			}
		})
	}
}
