package billing

import (
	"crypto/ed25519"
	"encoding/base64"
	"strings"
	"testing"
)

type relayBlindVerifierCase struct {
	name   string
	tuple  func(map[string]any)
	input  func(*RelayBlindSettlementVerifyInput)
	reason string
}

// relayBlindSignedInput returns a passing verifier input for the vector
// snapshot whose receipt was built from the mutated tuple and signed with the
// vector key, so each case isolates one R-13.5 check.
func relayBlindSignedInput(t *testing.T, mutate func(map[string]any)) RelayBlindSettlementVerifyInput {
	t.Helper()
	return relayBlindSignedInputWithSnapshot(t, nil, mutate)
}

func relayBlindSignedInputWithSnapshot(t *testing.T, mutateSnapshot func(*RouteSnapshot), mutate func(map[string]any)) RelayBlindSettlementVerifyInput {
	t.Helper()
	key := relayBlindVectorKey()
	keyID, _ := ReceiptKeyID(key.Public().(ed25519.PublicKey))
	snapshot := relayBlindVectorSnapshot(keyID)
	if mutateSnapshot != nil {
		mutateSnapshot(&snapshot)
	}
	digest, _, err := snapshot.Digest()
	if err != nil {
		t.Fatal(err)
	}
	dispatch := relayBlindVectorDispatchRow()
	tuple := relayBlindVectorTuple(digest, keyID, dispatch, relayBlindVectorNonStreamBody, TerminalStateNormalDone, 9, RelayBlindPrivacyClassNone)
	if mutate != nil {
		mutate(tuple)
	}
	_, envelope := relayBlindVectorSign(t, key, relayBlindVectorCanonical(t, tuple))
	file := relayBlindVectorFile{SigningPublicB64: base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey)), ReceiptKeyID: keyID, Dispatch: dispatch, ReceivedAtUnixMS: 1780000005200}
	input := relayBlindVectorInput(t, file, envelope, relayBlindVectorNonStreamBody, TerminalStateNormalDone, 9)
	input.RouteSnapshot = snapshot
	return input
}

// AC-022-69 / SPEC-015 §N.13: every binding mismatch, cap overrun, and
// digest mismatch quarantines, and a passing receipt is never verified.
func TestVerifyRelayBlindSettlementReceiptMismatchTable(t *testing.T) {
	if got := VerifyRelayBlindSettlementReceipt(relayBlindSignedInput(t, nil)); got.Outcome != SettlementOutcomeRelayBlindSettled || got.ReceiptResult != SettlementReceiptResultValid {
		t.Fatalf("baseline outcome=%s/%s reason=%s", got.Outcome, got.ReceiptResult, got.Reason)
	}
	// R-3.3 three-way equality: a signed snapshot whose provider-reported
	// hash differs from the catalog hash never settles, whichever the
	// receipt names.
	for _, receiptHash := range []string{strings.Repeat("3", 64), strings.Repeat("7", 64)} {
		input := relayBlindSignedInputWithSnapshot(t, func(r *RouteSnapshot) { r.ProviderReportedModelHash = strings.Repeat("7", 64) },
			func(m map[string]any) { m["model_hash"] = receiptHash })
		if got := VerifyRelayBlindSettlementReceipt(input); got.Outcome != SettlementOutcomeQuarantined || got.Reason != "model_hash_mismatch" {
			t.Fatalf("three-way model hash receipt=%s got %s/%s", receiptHash[:4], got.Outcome, got.Reason)
		}
	}
	otherDigest := relayBlindVectorDigest("some other value")
	cases := []relayBlindVerifierCase{
		{name: "account scope", tuple: func(m map[string]any) { m["account_scope"] = "acct_sha256:" + strings.Repeat("9", 64) }, reason: "account_scope_mismatch"},
		{name: "request id", tuple: func(m map[string]any) { m["request_id"] = "envelope-request-id" }, reason: "request_id_mismatch"},
		{name: "attempt", tuple: func(m map[string]any) { m["attempt_n"] = int64(1) }, reason: "attempt_mismatch"},
		{name: "provider id", tuple: func(m map[string]any) { m["provider_id"] = "provider-other" }, reason: "provider_id_mismatch"},
		{name: "receipt key id", tuple: func(m map[string]any) { m["provider_receipt_key_id"] = "ed25519-sha256:" + strings.Repeat("e", 64) }, reason: "provider_receipt_key_id_mismatch"},
		{name: "snapshot digest", tuple: func(m map[string]any) { m["route_snapshot_digest"] = strings.Repeat("e", 64) }, reason: "route_snapshot_digest_mismatch"},
		{name: "snapshot mode", tuple: func(m map[string]any) { m["route_snapshot_mode"] = RouteSnapshotModeObserve }, reason: "route_snapshot_mode_mismatch"},
		{name: "policy version", tuple: func(m map[string]any) { m["route_snapshot_policy_version"] = "spec022-prereq-v0" }, reason: "route_snapshot_policy_version_mismatch"},
		{name: "model id", tuple: func(m map[string]any) { m["model_id"] = "other-model" }, reason: "model_id_mismatch"},
		{name: "model hash", tuple: func(m map[string]any) { m["model_hash"] = strings.Repeat("7", 64) }, reason: "model_hash_mismatch"},
		{name: "snapshot reported hash differs from catalog", input: func(in *RelayBlindSettlementVerifyInput) {
			in.RouteSnapshot.ProviderReportedModelHash = strings.Repeat("7", 64)
		}, reason: "route_snapshot_digest_mismatch"},
		{name: "expected catalog hash", tuple: func(m map[string]any) { m["expected_catalog_model_hash"] = strings.Repeat("7", 64) }, reason: "expected_catalog_model_hash_mismatch"},
		{name: "catalog id", tuple: func(m map[string]any) { m["catalog_id"] = "catalog-other" }, reason: "catalog_snapshot_mismatch"},
		{name: "catalog digest", tuple: func(m map[string]any) { m["catalog_body_digest"] = strings.Repeat("7", 64) }, reason: "catalog_snapshot_mismatch"},
		{name: "envelope digest vs snapshot", tuple: func(m map[string]any) { m["relay_blind_envelope_digest"] = otherDigest }, reason: "relay_blind_envelope_digest_mismatch"},
		{name: "envelope digest vs dispatch row", input: func(in *RelayBlindSettlementVerifyInput) { in.Dispatch.EnvelopeDigest = otherDigest }, reason: "relay_blind_envelope_digest_mismatch"},
		{name: "execution auth digest", tuple: func(m map[string]any) { m["relay_blind_execution_auth_digest"] = otherDigest }, reason: "relay_blind_execution_auth_digest_mismatch"},
		{name: "provider binding digest", tuple: func(m map[string]any) { m["relay_blind_provider_binding_digest"] = otherDigest }, reason: "relay_blind_provider_binding_digest_mismatch"},
		{name: "kid", tuple: func(m map[string]any) { m["relay_blind_kid"] = strings.Repeat("A", 22) }, reason: "relay_blind_kid_mismatch"},
		{name: "privacy class", tuple: func(m map[string]any) { m["privacy_class"] = RelayBlindPrivacyClassBetaV1 }, reason: "privacy_class_mismatch"},
		{name: "response digest", tuple: func(m map[string]any) { m["response_body_sha256"] = strings.Repeat("8", 64) }, reason: "response_body_digest_mismatch"},
		{name: "response bytes", tuple: func(m map[string]any) { m["response_body_bytes"] = int64(3) }, reason: "response_body_digest_mismatch"},
		{name: "recorded digest differs", input: func(in *RelayBlindSettlementVerifyInput) { in.ResponseBodySHA256 = strings.Repeat("8", 64) }, reason: "response_body_digest_mismatch"},
		{name: "response digest unavailable", input: func(in *RelayBlindSettlementVerifyInput) { in.ResponseDigestAvailable = false }, reason: "response_digest_unavailable"},
		{name: "terminal state", tuple: func(m map[string]any) { m["terminal_state"] = TerminalStateProviderError }, reason: "terminal_state_mismatch"},
		{name: "terminal timestamp", tuple: func(m map[string]any) { m["terminal_state_ts_unix_ms"] = int64(1780000005001) }, reason: "terminal_state_timestamp_mismatch"},
		{name: "issued before request", tuple: func(m map[string]any) { m["issued_at_unix_ms"] = int64(1680000000000) }, reason: "issued_at_window_mismatch"},
		{name: "bound differs from reservation", tuple: func(m map[string]any) { m["input_token_upper_bound"] = int64(4095) }, reason: "usage_bound_mismatch"},
		{name: "input above bound", tuple: func(m map[string]any) {
			m["usage"] = map[string]any{"input_tokens": int64(4097), "output_tokens": int64(9)}
		}, reason: "usage_exceeds_reservation_bound"},
		{name: "output above bound", tuple: func(m map[string]any) {
			m["usage"] = map[string]any{"input_tokens": int64(37), "output_tokens": int64(513)}
		}, reason: "usage_exceeds_reservation_bound"},
		{name: "input differs from validated evidence", tuple: func(m map[string]any) {
			m["usage"] = map[string]any{"input_tokens": int64(38), "output_tokens": int64(9)}
		}, reason: "usage_validated_input_mismatch"},
		{name: "validated evidence missing", input: func(in *RelayBlindSettlementVerifyInput) { in.Dispatch.ValidatedInputTokens = nil }, reason: "usage_validated_input_mismatch"},
		{name: "output differs from terminal completion", tuple: func(m map[string]any) {
			m["usage"] = map[string]any{"input_tokens": int64(37), "output_tokens": int64(10)}
		}, reason: "usage_terminal_completion_mismatch"},
		{name: "ledger usage differs", input: func(in *RelayBlindSettlementVerifyInput) { in.Usage.ObservedOutputTokens = 8 }, reason: "usage_mismatch"},
		{name: "dispatch row unavailable", input: func(in *RelayBlindSettlementVerifyInput) { in.Dispatch = nil }, reason: "relay_blind_dispatch_evidence_unavailable"},
		{name: "overlap", input: func(in *RelayBlindSettlementVerifyInput) { in.OverlappingOrDuplicate = true }, reason: "overlapping_output_prefix"},
		{name: "after deadline", input: func(in *RelayBlindSettlementVerifyInput) { in.ReceiptReceivedUnixMS = 1780000005000 + 301000 }, reason: "receipt_after_deadline"},
		{name: "tampered signature", input: func(in *RelayBlindSettlementVerifyInput) {
			dot := strings.IndexByte(in.Envelope, '.')
			sig, _ := base64.StdEncoding.DecodeString(in.Envelope[dot+1:])
			sig[0] ^= 0xff
			in.Envelope = in.Envelope[:dot+1] + base64.StdEncoding.EncodeToString(sig)
		}, reason: "signature_verify_failed"},
		{name: "other signing key", input: func(in *RelayBlindSettlementVerifyInput) {
			other := ed25519.NewKeyFromSeed(make([]byte, ed25519.SeedSize))
			in.ProviderReceiptPubkey = other.Public().(ed25519.PublicKey)
		}, reason: "provider_receipt_key_id_mismatch"},
		{name: "oversized envelope", input: func(in *RelayBlindSettlementVerifyInput) { in.Envelope = strings.Repeat("A", 8193) }, reason: "receipt_envelope_oversize"},
		{name: "already terminal", input: func(in *RelayBlindSettlementVerifyInput) { in.TerminalOutcomeFinal = true }, reason: "duplicate_receipt_after_terminal"},
		{name: "deadline quarantined", input: func(in *RelayBlindSettlementVerifyInput) { in.AlreadyDeadlineQuarantined = true }, reason: "deadline_quarantined"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			input := relayBlindSignedInput(t, tc.tuple)
			if tc.input != nil {
				tc.input(&input)
			}
			got := VerifyRelayBlindSettlementReceipt(input)
			if got.Outcome != SettlementOutcomeQuarantined || got.Reason != tc.reason {
				t.Fatalf("got %s/%s reason=%s want quarantined/%s", got.Outcome, got.ReceiptResult, got.Reason, tc.reason)
			}
		})
	}
}

// SPEC-022 R-7.10: the downgrade guards run in both directions. Neither
// verifier returns the other's positive outcome.
func TestRelayBlindCrossProfileDowngradeQuarantines(t *testing.T) {
	t.Run("relay-blind receipt on plaintext snapshot", func(t *testing.T) {
		input := relayBlindSignedInput(t, nil)
		input.RouteSnapshot.PaidEntrypoint = PaidEntrypointCoordinatorBuyerChat
		input.RouteSnapshot.PromptHashBasis = PromptHashBasisCoordinatorV1
		got := VerifyRelayBlindSettlementReceipt(input)
		if got.Outcome != SettlementOutcomeQuarantined || got.Reason != "relay_blind_receipt_on_plaintext_snapshot" {
			t.Fatalf("got %s/%s", got.Outcome, got.Reason)
		}
	})
	t.Run("v0.4 receipt on relay-blind snapshot", func(t *testing.T) {
		input := relayBlindSignedInput(t, nil)
		got := VerifySettlementReceipt(SettlementVerifyInput{
			Header: syntheticRelayBlindV04Header(), ProviderReceiptPubkey: input.ProviderReceiptPubkey, RouteSnapshot: input.RouteSnapshot,
			AccountScope: input.AccountScope, RequestID: input.RequestID, ProviderID: input.ProviderID,
			ProviderReceiptKeyID: input.RouteSnapshot.ProviderReceiptKeyID, TerminalState: TerminalStateNormalDone,
			TerminalStateTSUnixMS: 1780000005000, OutputHash: strings.Repeat("8", 64), OutputPrefixEndByte: 4,
			UsageSource: UsageSourceCoordinatorObserved, UsageCrossChecked: true, CanonicalHashesAvailable: true,
			ReceiptReceivedUnixMS: 1780000005200, NowUnixMS: 1780000005200,
		})
		if got.Outcome != SettlementOutcomeQuarantined || got.Reason != "v04_receipt_on_relay_blind_snapshot" || got.Checks.PromptHashMatched {
			t.Fatalf("got %s/%s checks=%+v", got.Outcome, got.Reason, got.Checks)
		}
	})
	t.Run("missing receipt on relay-blind snapshot stays pending", func(t *testing.T) {
		input := relayBlindSignedInput(t, nil)
		got := VerifySettlementReceipt(SettlementVerifyInput{RouteSnapshot: input.RouteSnapshot, ReceiptMissing: true,
			TerminalStateTSUnixMS: 1780000005000, NowUnixMS: 1780000005200})
		if got.Outcome != SettlementOutcomePending {
			t.Fatalf("got %s/%s", got.Outcome, got.Reason)
		}
		got = VerifySettlementReceipt(SettlementVerifyInput{RouteSnapshot: input.RouteSnapshot, ReceiptMissing: true,
			TerminalStateTSUnixMS: 1780000005000, NowUnixMS: 1780000005000 + 301000})
		if got.Outcome != SettlementOutcomeQuarantined {
			t.Fatalf("after deadline got %s/%s", got.Outcome, got.Reason)
		}
	})
}

func syntheticRelayBlindV04Header() string {
	raw := []byte(`{"receipt_version":"4"}`)
	return base64.StdEncoding.EncodeToString(raw) + "." + base64.StdEncoding.EncodeToString(make([]byte, ed25519.SignatureSize))
}
