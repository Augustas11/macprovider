package buyer

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// relayBlindTestReceipt is what an honest SPEC-015 §N.13 provider signs from
// the dispatch's relay_blind_settlement metadata and its own execution facts.
func relayBlindTestReceipt(t *testing.T, key ed25519.PrivateKey, meta *providerws.RelayBlindSettlementMetadata, relayContext providerws.RelayBlindDispatchContext, body, terminal string, terminalTS, issuedAt, input, output int64, mutate func(map[string]any)) string {
	t.Helper()
	sum := sha256.Sum256([]byte(body))
	privacy := billing.RelayBlindPrivacyClassNone
	if relayContext.PrivacyClass != "" {
		privacy = relayContext.PrivacyClass
	}
	tuple := map[string]any{
		"account_scope": meta.AccountScope, "attempt_n": meta.AttemptN, "catalog_body_digest": meta.CatalogBodyDigest,
		"catalog_id": meta.CatalogID, "expected_catalog_model_hash": meta.ExpectedCatalogModelHash,
		"input_token_upper_bound": relayContext.InputTokenUpperBound, "issued_at_unix_ms": issuedAt,
		"max_output_tokens": relayContext.MaxOutputTokens, "model_hash": meta.ExpectedCatalogModelHash, "model_id": meta.ModelID,
		"paid_entrypoint": meta.PaidEntrypoint, "privacy_class": privacy, "prompt_hash_basis": meta.PromptHashBasis,
		"provider_id": meta.ProviderID, "provider_receipt_key_id": meta.ProviderReceiptKeyID,
		"receipt_version": billing.RelayBlindSettlementReceiptVersion, "relay_blind_envelope_digest": meta.RelayBlindEnvelopeDigest,
		"relay_blind_execution_auth_digest": relayContext.ExecutionAuthDigest, "relay_blind_kid": relayContext.KID,
		"relay_blind_provider_binding_digest": relayContext.ProviderBindingDigest, "request_id": meta.RequestID,
		"response_body_bytes": int64(len(body)), "response_body_sha256": hex.EncodeToString(sum[:]),
		"route_snapshot_digest": meta.RouteSnapshotDigest, "route_snapshot_mode": meta.RouteSnapshotMode,
		"route_snapshot_policy_version": meta.RouteSnapshotPolicyVersion, "signature_key_alg": "Ed25519",
		"terminal_state": terminal, "terminal_state_ts_unix_ms": terminalTS,
		"usage": map[string]any{"input_tokens": input, "output_tokens": output},
	}
	if mutate != nil {
		mutate(tuple)
	}
	raw, err := billing.CanonicalJSON(tuple)
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(raw) + "." + base64.StdEncoding.EncodeToString(ed25519.Sign(key, raw))
}

type relayBlindFlowCase struct {
	name        string
	stream      bool
	mutate      func(map[string]any)
	omitReceipt bool
	wantOutcome string
	wantPayable int64
}

// AC-022-67/69 end to end in the coordinator: the provider's terminal
// receipt is ingested, the finality tuple carries relay_blind_settled (never
// verified), and only a valid receipt makes the credit payable.
func TestRelayBlindEnforceSettlementFlow(t *testing.T) {
	cases := []relayBlindFlowCase{
		{name: "nonstream settled", wantOutcome: billing.SettlementOutcomeRelayBlindSettled, wantPayable: 1},
		{name: "stream settled", stream: true, wantOutcome: billing.SettlementOutcomeRelayBlindSettled, wantPayable: 1},
		{name: "tampered usage", mutate: func(m map[string]any) {
			m["usage"] = map[string]any{"input_tokens": int64(11), "output_tokens": int64(4)}
		}, wantOutcome: billing.SettlementOutcomeQuarantined},
		{name: "wrong response digest", stream: true, mutate: func(m map[string]any) { m["response_body_sha256"] = strings.Repeat("0", 64) }, wantOutcome: billing.SettlementOutcomeQuarantined},
		{name: "missing receipt", omitReceipt: true, wantOutcome: billing.SettlementOutcomePending},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Now().UTC().Truncate(time.Second)
			var f relayBlindSettlementFixture
			body := `{"choices":[{"message":{"role":"assistant","content":"hi"}}]}`
			if tc.stream {
				body = "data: {\"choices\":[]}\n\ndata: [DONE]\n\n"
			}
			f = newRelayBlindSettlementFixture(t, now, billing.RouteSnapshotModeEnforce, config.RelayBlindSettlementProfileV1, nil,
				func(_ context.Context, _ pool.Provider, requestID string, _ []byte, stream bool, relayContext providerws.RelayBlindDispatchContext) (*providerws.RelayStream, error) {
					chunks := make(chan providerws.InferenceResponseChunk)
					done := make(chan providerws.InferenceResponseEnd, 1)
					validations := make(chan providerws.RelayBlindValidation, 1)
					validations <- relayBlindValidationForContext(relayContext, "validated", 11)
					terminal := relayBlindValidationForContext(relayContext, "terminal", 11)
					terminalTS := now.UnixMilli()
					receipt := ""
					if !tc.omitReceipt {
						receipt = relayBlindTestReceipt(t, f.receiptPrivate, relayContext.Settlement, relayContext, body, billing.TerminalStateNormalDone, terminalTS, terminalTS, 11, 3, tc.mutate)
					}
					go func() {
						half := len(body) / 2
						chunks <- providerws.InferenceResponseChunk{RequestID: requestID, Seq: 0, Data: body[:half]}
						chunks <- providerws.InferenceResponseChunk{RequestID: requestID, Seq: 1, Data: body[half:]}
						close(chunks)
						done <- providerws.InferenceResponseEnd{RequestID: requestID, Status: "complete", TerminalStateTSUnixMS: terminalTS,
							Usage:                json.RawMessage(`{"prompt_tokens":11,"completion_tokens":3,"total_tokens":14}`),
							RelayBlindValidation: &terminal, RelayBlindSettlementReceipt: receipt, Receipt: "v04-must-be-ignored"}
					}()
					return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: make(chan error, 1), Validations: validations}, nil
				})
			result, _, code := relayBlindFixtureExecute(t, f, now, tc.stream)
			if code != http.StatusOK {
				t.Fatalf("chat status=%d", code)
			}
			outcome := result.Header.Get(settlementOutcomeHeader)
			if outcome == "" {
				outcome = result.Trailer.Get(settlementOutcomeHeader)
			}
			if outcome != tc.wantOutcome {
				t.Fatalf("finality outcome=%q want %q (headers=%v trailers=%v)", outcome, tc.wantOutcome, result.Header, result.Trailer)
			}
			if result.Header.Get(internalRequestIDHeader) == "" {
				t.Fatal("relay-blind R-13 response lacks the coordinator internal request id")
			}
			if got := result.Header.Get(relayBlindSettlementCoverageHeader); got != billing.RelayBlindCoverageEnforce {
				t.Fatalf("relay-blind R-13 response coverage marker=%q", got)
			}
			if result.Header.Get("X-MacProvider-Receipt") != "" || strings.Contains(result.Header.Get(settlementReasonHeader), "verified") {
				t.Fatalf("receipt or verified label leaked: %v", result.Header)
			}
			var payable int64
			if err := f.db.QueryRow(`SELECT COUNT(*) FROM spec022_payable_request_credits`).Scan(&payable); err != nil {
				t.Fatal(err)
			}
			if payable != tc.wantPayable {
				t.Fatalf("payable credits=%d want %d", payable, tc.wantPayable)
			}
			var outputHash string
			var canonical *string
			if err := f.db.QueryRow(`SELECT output_hash, settlement_output_canonical_json FROM settlement_attempt_outputs UNION ALL SELECT output_hash, NULL FROM settlement_attempt_output_journal LIMIT 1`).Scan(&outputHash, &canonical); err != nil {
				t.Fatal(err)
			}
			sum := sha256.Sum256([]byte(body))
			if outputHash != hex.EncodeToString(sum[:]) || canonical != nil {
				t.Fatalf("attempt output hash=%s canonical=%v, want the response-body digest and no plaintext output", outputHash, canonical)
			}
			var verified int64
			_ = f.db.QueryRow(`SELECT COUNT(*) FROM settlement_receipt_verdicts WHERE settlement_outcome = 'verified'`).Scan(&verified)
			if verified != 0 {
				t.Fatalf("verified verdicts=%d", verified)
			}
		})
	}
}

// SPEC-022 R-13.6: a receipt the provider withholds after the attempt was
// recorded (a terminal frame without a receipt, or an uncertain stream end)
// is missing evidence. The attempt is pending until its deadline, then closed
// quarantined: the buyer is refunded and no provider credit is payable.
func TestRelayBlindEnforceWithheldReceiptQuarantinesAtDeadline(t *testing.T) {
	for _, tc := range []struct {
		name         string
		stream       bool
		uncertain    bool
		noValidation bool
	}{
		{name: "terminal without receipt"},
		{name: "stream terminal without receipt", stream: true},
		{name: "stream ends uncertain", stream: true, uncertain: true},
		{name: "validation evidence lost", noValidation: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Now().UTC().Truncate(time.Second)
			body := "data: {\"choices\":[]}\n\ndata: [DONE]\n\n"
			f := newRelayBlindSettlementFixture(t, now, billing.RouteSnapshotModeEnforce, config.RelayBlindSettlementProfileV1, nil,
				func(_ context.Context, _ pool.Provider, requestID string, _ []byte, _ bool, relayContext providerws.RelayBlindDispatchContext) (*providerws.RelayStream, error) {
					chunks := make(chan providerws.InferenceResponseChunk, 1)
					done := make(chan providerws.InferenceResponseEnd, 1)
					errs := make(chan error, 1)
					validations := make(chan providerws.RelayBlindValidation, 1)
					if tc.noValidation {
						errs <- context.DeadlineExceeded
						return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs, Validations: validations}, nil
					}
					validations <- relayBlindValidationForContext(relayContext, "validated", 11)
					terminal := relayBlindValidationForContext(relayContext, "terminal", 11)
					go func() {
						chunks <- providerws.InferenceResponseChunk{RequestID: requestID, Seq: 0, Data: body}
						if tc.uncertain {
							time.Sleep(10 * time.Millisecond)
							errs <- context.DeadlineExceeded
							return
						}
						close(chunks)
						done <- providerws.InferenceResponseEnd{RequestID: requestID, Status: "complete", TerminalStateTSUnixMS: now.UnixMilli(),
							Usage:                json.RawMessage(`{"prompt_tokens":11,"completion_tokens":3,"total_tokens":14}`),
							RelayBlindValidation: &terminal}
					}()
					return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs, Validations: validations}, nil
				})
			result, _, code := relayBlindFixtureExecute(t, f, now, tc.stream)
			if code != http.StatusOK && !tc.uncertain && !tc.noValidation {
				t.Fatalf("chat status=%d", code)
			}
			internalID := result.Header.Get(internalRequestIDHeader)
			if internalID == "" {
				t.Fatal("no coordinator internal request id")
			}
			ctx := context.Background()
			lookup := func(at time.Time) billing.RequestSettlementFinality {
				t.Helper()
				finality, found, err := f.billing.RequestSettlementFinality(ctx, billing.AccountScopeForSettlement("account-a"), internalID, at.UnixMilli())
				if err != nil || !found {
					t.Fatalf("finality found=%v err=%v", found, err)
				}
				return finality
			}
			if pending := lookup(now.Add(time.Second)); pending.Closed || pending.Outcome != billing.SettlementOutcomePending || pending.Mode != billing.RouteSnapshotModeEnforce {
				t.Fatalf("before the deadline finality=%+v, want enforce pending", pending)
			}
			late := now.Add(time.Duration(config.Default().Settlement.PendingDeadlineSeconds)*time.Second + 2*time.Hour)
			closed := lookup(late)
			if !closed.Closed || closed.Outcome != billing.SettlementOutcomeQuarantined || closed.QuarantinedAttempts != 1 ||
				closed.RelayBlindSettledAttempts != 0 || closed.PromptTokens != 0 || closed.CompletionTokens != 0 {
				t.Fatalf("after the deadline finality=%+v, want closed quarantined refund", closed)
			}
			// The terminal classification is durable, not re-derived per lookup.
			var verdicts int64
			if err := f.db.QueryRow(`SELECT COUNT(*) FROM settlement_receipt_verdicts WHERE closed = 1 AND settlement_outcome = 'quarantined'`).Scan(&verdicts); err != nil || verdicts != 1 {
				t.Fatalf("closed quarantined verdicts=%d err=%v", verdicts, err)
			}
			var payable int64
			if err := f.db.QueryRow(`SELECT COUNT(*) FROM spec022_payable_request_credits`).Scan(&payable); err != nil || payable != 0 {
				t.Fatalf("payable credits=%d err=%v", payable, err)
			}
		})
	}
}
