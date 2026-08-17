package billing

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/computeintegrity"
)

const computeIntegrityTestHardwareDigest = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

func TestComputeIntegrityDriftQuarantinesVerifiedSettlementAndExcludesPayout(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	input := computeIntegritySettlementInput(t, fixtures, firstSettlementTupleWithTerminal(t, fixtures, "normal_done"), RouteSnapshotModeEnforce)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	insertSPEC022LedgerCredit(t, store.db, input, 700)
	capture := computeIntegrityCaptureForInput(t, input, computeintegrity.StateQuarantinedDrift)
	if _, err := store.InsertComputeIntegrityCapture(context.Background(), settlementIdentityFromInput(input), capture, true, computeIntegrityTestHardwareDigest); err != nil {
		t.Fatal(err)
	}

	state, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: settlementIdentityFromInput(input),
		Header:                    input.Header,
		ProviderReceiptPubkey:     input.ProviderReceiptPubkey,
		receiptReceivedUnixMS:     input.ReceiptReceivedUnixMS,
	})
	if err != nil {
		t.Fatal(err)
	}
	if state.SettlementOutcome != SettlementOutcomeQuarantined || state.Reason != string(computeintegrity.ReasonDriftQuarantined) || !state.Closed {
		t.Fatalf("state=%#v, want quarantined/%s", state, computeintegrity.ReasonDriftQuarantined)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM spec022_payable_request_credits WHERE request_id=?`, input.RequestID); got != 0 {
		t.Fatalf("payable rows=%d want 0", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready`); got != 0 {
		t.Fatalf("payout rows=%d want 0", got)
	}
}

func TestComputeIntegrityCleanCaptureDoesNotPromoteZeroSettledSPEC022(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	input := computeIntegritySettlementInput(t, fixtures, firstSettlementTupleWithTerminal(t, fixtures, "provider_error"), RouteSnapshotModeEnforce)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	capture := computeIntegrityCaptureForInput(t, input, computeintegrity.StateVerified)
	if _, err := store.InsertComputeIntegrityCapture(context.Background(), settlementIdentityFromInput(input), capture, true, computeIntegrityTestHardwareDigest); err != nil {
		t.Fatal(err)
	}

	state, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: settlementIdentityFromInput(input),
		Header:                    input.Header,
		ProviderReceiptPubkey:     input.ProviderReceiptPubkey,
		receiptReceivedUnixMS:     input.ReceiptReceivedUnixMS,
	})
	if err != nil {
		t.Fatal(err)
	}
	if state.SettlementOutcome != SettlementOutcomeZeroSettled || state.Reason != "verified_zero_settlement" {
		t.Fatalf("state=%#v, want SPEC-022 zero_settled preserved", state)
	}
}

func TestComputeIntegrityCaptureRouteMismatchFailsClosed(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	for _, tc := range []struct {
		name   string
		mutate func(*computeintegrity.Capture)
	}{
		{
			name: "spec022-not-effective-enforce",
			mutate: func(c *computeintegrity.Capture) {
				c.Spec022EffectiveEnforce = false
			},
		},
		{
			name: "provider-id",
			mutate: func(c *computeintegrity.Capture) {
				c.ProviderID = "other-provider"
			},
		},
		{
			name: "model-id",
			mutate: func(c *computeintegrity.Capture) {
				c.ModelID = "other-model"
			},
		},
		{
			name: "target-model-hash",
			mutate: func(c *computeintegrity.Capture) {
				c.TargetModelHash = strings.Repeat("9", 64)
			},
		},
		{
			name: "signed-catalog-digest",
			mutate: func(c *computeintegrity.Capture) {
				c.SignedCatalogDigest = "sha256:" + strings.Repeat("9", 64)
			},
		},
		{
			name: "captured-at",
			mutate: func(c *computeintegrity.Capture) {
				c.CapturedAtUnixMS++
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			input := computeIntegritySettlementInput(t, fixtures, firstSettlementTupleWithTerminal(t, fixtures, "normal_done"), RouteSnapshotModeEnforce)
			_, store := newRequestAndBillingStores(t)
			createSettlementReceiptAuditLog(t, store.db)
			seedSettlementReceiptEvidence(t, store, input)
			capture := computeIntegrityCaptureForInput(t, input, computeintegrity.StateVerified)
			tc.mutate(&capture)
			if _, err := store.InsertComputeIntegrityCapture(context.Background(), settlementIdentityFromInput(input), capture, true, computeIntegrityTestHardwareDigest); err != nil {
				t.Fatal(err)
			}

			state, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
				SettlementReceiptIdentity: settlementIdentityFromInput(input),
				Header:                    input.Header,
				ProviderReceiptPubkey:     input.ProviderReceiptPubkey,
				receiptReceivedUnixMS:     input.ReceiptReceivedUnixMS,
			})
			if err != nil {
				t.Fatal(err)
			}
			if state.SettlementOutcome != SettlementOutcomeQuarantined || state.Reason != string(computeintegrity.ReasonUnreadable) {
				t.Fatalf("state=%#v, want quarantined/%s", state, computeintegrity.ReasonUnreadable)
			}
		})
	}
}

func TestComputeIntegrityMissingOrUnreadableCaptureFailsClosed(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	for _, tc := range []struct {
		name string
		mark func(t *testing.T, store *Store, input SettlementVerifyInput)
	}{
		{
			name: "no-capture-row",
			mark: func(t *testing.T, store *Store, input SettlementVerifyInput) {
				t.Helper()
			},
		},
		{
			name: "missing",
			mark: func(t *testing.T, store *Store, input SettlementVerifyInput) {
				t.Helper()
				if err := store.MarkComputeIntegrityCaptureRequired(context.Background(), settlementIdentityFromInput(input), true, computeIntegrityTestHardwareDigest); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "unreadable",
			mark: func(t *testing.T, store *Store, input SettlementVerifyInput) {
				t.Helper()
				_, err := store.db.Exec(`
	INSERT INTO settlement_compute_integrity_captures (
	    account_scope, request_id, attempt_n, provider_id,
	    capture_required, request_sampling_profile_covered, route_snapshot_hardware_class_digest,
	    capture_json, request_start_snapshot_digest, captured_at_unix_ms, created_at_utc
	) VALUES (?, ?, ?, ?, 1, 1, ?, ?, NULL, NULL, strftime('%Y-%m-%dT%H:%M:%fZ','now'))`,
					input.AccountScope, input.RequestID, input.AttemptN, input.ProviderID,
					computeIntegrityTestHardwareDigest, `{"compute_integrity_state":`)
				if err != nil {
					t.Fatal(err)
				}
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			input := computeIntegritySettlementInput(t, fixtures, firstSettlementTupleWithTerminal(t, fixtures, "normal_done"), RouteSnapshotModeEnforce)
			_, store := newRequestAndBillingStores(t)
			createSettlementReceiptAuditLog(t, store.db)
			seedSettlementReceiptEvidence(t, store, input)
			tc.mark(t, store, input)

			state, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
				SettlementReceiptIdentity: settlementIdentityFromInput(input),
				Header:                    input.Header,
				ProviderReceiptPubkey:     input.ProviderReceiptPubkey,
				receiptReceivedUnixMS:     input.ReceiptReceivedUnixMS,
			})
			if err != nil {
				t.Fatal(err)
			}
			if state.SettlementOutcome != SettlementOutcomeQuarantined || state.Reason != string(computeintegrity.ReasonUnreadable) {
				t.Fatalf("state=%#v, want quarantined/%s", state, computeintegrity.ReasonUnreadable)
			}
		})
	}
}

func TestComputeIntegrityCaptureIsImmutable(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	input := computeIntegritySettlementInput(t, fixtures, firstSettlementTupleWithTerminal(t, fixtures, "normal_done"), RouteSnapshotModeEnforce)
	_, store := newRequestAndBillingStores(t)
	seedSettlementReceiptEvidence(t, store, input)
	capture := computeIntegrityCaptureForInput(t, input, computeintegrity.StateVerified)
	if _, err := store.InsertComputeIntegrityCapture(context.Background(), settlementIdentityFromInput(input), capture, true, computeIntegrityTestHardwareDigest); err != nil {
		t.Fatal(err)
	}

	_, err := store.db.Exec(`UPDATE settlement_compute_integrity_captures SET capture_json = capture_json || ' ' WHERE request_id = ?`, input.RequestID)
	if err == nil || !strings.Contains(err.Error(), "settlement compute integrity capture is immutable") {
		t.Fatalf("err=%v, want immutable capture trigger", err)
	}
}

func TestComputeIntegrityObserveRouteDoesNotChangeMoneyOutcome(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	input := computeIntegritySettlementInput(t, fixtures, firstSettlementTupleWithTerminal(t, fixtures, "normal_done"), RouteSnapshotModeObserve)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	capture := computeIntegrityCaptureForInput(t, input, computeintegrity.StateQuarantinedDrift)
	capture.Spec022EffectiveEnforce = false
	if _, err := store.InsertComputeIntegrityCapture(context.Background(), settlementIdentityFromInput(input), capture, true, computeIntegrityTestHardwareDigest); err != nil {
		t.Fatal(err)
	}

	state, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: settlementIdentityFromInput(input),
		Header:                    input.Header,
		ProviderReceiptPubkey:     input.ProviderReceiptPubkey,
		receiptReceivedUnixMS:     input.ReceiptReceivedUnixMS,
	})
	if err != nil {
		t.Fatal(err)
	}
	if state.SettlementOutcome != SettlementOutcomeVerified || state.Reason != "verified_settlement" {
		t.Fatalf("state=%#v, want SPEC-036 dormant on observe route", state)
	}
}

func computeIntegritySettlementInput(t *testing.T, fixtures settlementVerifierFixtures, tuple settlementVerifierTupleFixture, routeMode string) SettlementVerifyInput {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pub)
	keyID, err := ReceiptKeyID(pub)
	if err != nil {
		t.Fatal(err)
	}
	input.ProviderReceiptKeyID = keyID
	input.RouteSnapshot.ProviderReceiptKeyID = keyID
	input.RouteSnapshot.ProviderReceiptKeySource = "auth_session"
	input.RouteSnapshot.RouteSnapshotMode = routeMode
	if routeMode == RouteSnapshotModeEnforce {
		input.RouteSnapshot.ComputeIntegrityCaptureRequired = true
		input.RouteSnapshot.ComputeIntegritySamplingCovered = true
		input.RouteSnapshot.ComputeIntegrityHardwareDigest = computeIntegrityTestHardwareDigest
	}
	input.ProviderReceiptPubkey = pub
	input.Header = signedSettlementReceiptForInputWithKey(t, input, priv)
	return input
}

func signedSettlementReceiptForInputWithKey(t *testing.T, input SettlementVerifyInput, priv ed25519.PrivateKey) string {
	t.Helper()
	routeDigest, _, err := input.RouteSnapshot.Digest()
	if err != nil {
		t.Fatal(err)
	}
	tuple := map[string]any{
		"account_scope":                 input.AccountScope,
		"attempt_n":                     input.AttemptN,
		"catalog_body_digest":           input.RouteSnapshot.CatalogBodyDigest,
		"catalog_id":                    input.RouteSnapshot.CatalogID,
		"expected_catalog_model_hash":   input.RouteSnapshot.ExpectedCatalogModelHash,
		"issued_at_unix_ms":             input.TerminalStateTSUnixMS,
		"model_hash":                    input.RouteSnapshot.ProviderReportedModelHash,
		"model_id":                      input.RouteSnapshot.ModelID,
		"output_hash":                   input.OutputHash,
		"output_prefix_end_byte":        input.OutputPrefixEndByte,
		"output_prefix_start_byte":      input.OutputPrefixStartByte,
		"prompt_hash":                   input.RouteSnapshot.PromptHash,
		"provider_id":                   input.ProviderID,
		"provider_receipt_key_id":       input.ProviderReceiptKeyID,
		"receipt_version":               "4",
		"request_id":                    input.RequestID,
		"route_snapshot_digest":         routeDigest,
		"route_snapshot_mode":           input.RouteSnapshot.RouteSnapshotMode,
		"route_snapshot_policy_version": input.RouteSnapshot.RouteSnapshotPolicyVersion,
		"signature_key_alg":             "Ed25519",
		"terminal_state":                input.TerminalState,
		"terminal_state_ts_unix_ms":     input.TerminalStateTSUnixMS,
		"usage": map[string]any{
			"billable_input_tokens":  input.ExpectedUsage.BillableInputTokens,
			"billable_output_tokens": input.ExpectedUsage.BillableOutputTokens,
			"delivered_output_bytes": input.ExpectedUsage.DeliveredOutputBytes,
			"observed_input_tokens":  input.ExpectedUsage.ObservedInputTokens,
			"observed_output_tokens": input.ExpectedUsage.ObservedOutputTokens,
		},
	}
	canonical, err := CanonicalJSON(tuple)
	if err != nil {
		t.Fatal(err)
	}
	sig := ed25519.Sign(priv, canonical)
	return base64.StdEncoding.EncodeToString(canonical) + "." + base64.StdEncoding.EncodeToString(sig)
}

func computeIntegrityCaptureForInput(t *testing.T, input SettlementVerifyInput, state computeintegrity.State) computeintegrity.Capture {
	t.Helper()
	routeDigest, _, err := input.RouteSnapshot.Digest()
	if err != nil {
		t.Fatal(err)
	}
	return computeintegrity.Capture{
		StableProviderIdentity:           "stable-" + input.ProviderID,
		ProviderID:                       input.ProviderID,
		AssignedID:                       "assigned-" + input.ProviderID,
		ModelID:                          input.RouteSnapshot.ModelID,
		TargetModelHash:                  input.RouteSnapshot.ProviderReportedModelHash,
		TokenizerIdentity:                "tokenizer-v1",
		SamplerStage:                     computeintegrity.SamplerStagePostSampler,
		SamplingProfile:                  "temp-0.7",
		CorpusVersion:                    "corpus-v1",
		ThresholdVersion:                 "threshold-v1",
		HardwareRuntimeClass:             "m3-max",
		TargetGeneration:                 1,
		SamplingProfileCoverageMode:      computeintegrity.CoveragePerProfile,
		RequestSamplingProfileCovered:    true,
		HardwareRuntimeClassDigest:       computeIntegrityTestHardwareDigest,
		RouteSnapshotHardwareClassDigest: computeIntegrityTestHardwareDigest,
		Spec022PolicyVersion:             input.RouteSnapshot.RouteSnapshotPolicyVersion,
		Spec022PolicyMode:                input.RouteSnapshot.RouteSnapshotMode,
		Spec022EffectiveEnforce:          input.RouteSnapshot.RouteSnapshotMode == RouteSnapshotModeEnforce,
		Spec022CoverageDigest:            "sha256:" + strings.Repeat("a", 64),
		Spec022RouteSnapshotDigest:       routeDigest,
		ComputeIntegrityPolicyVersion:    "ci-v1",
		ComputeIntegrityPolicyMode:       computeintegrity.ModeEnforce,
		ComputeIntegrityPolicyDigest:     "sha256:" + strings.Repeat("b", 64),
		State:                            state,
		AdjudicationOrigin:               computeintegrity.OriginEnforcePreserved,
		ReferenceSetAdmissibilityStatus:  computeintegrity.AdmissibilityAdmissible,
		ReferenceSetAdmissibilityDigest:  "sha256:" + strings.Repeat("d", 64),
		ReferenceFaultCheckVersion:       "ref-fault-v1",
		ReferenceSetID:                   "refset-v1",
		ReferenceEventDigests:            []string{"sha256:ref-a", "sha256:ref-b"},
		ReferenceQuorumCount:             2,
		BreakerFieldsPresent:             true,
		CircuitBreakerActive:             false,
		WindowID:                         "window-v1",
		SignedCatalogDigest:              "sha256:" + input.RouteSnapshot.CatalogBodyDigest,
		CapturedAtUnixMS:                 input.RouteSnapshot.RequestStartTSUnixMS,
	}
}
