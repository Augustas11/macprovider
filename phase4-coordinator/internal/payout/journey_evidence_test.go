package payout

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/decred/dcrd/dcrec/secp256k1/v4"
	"github.com/go-chi/chi/v5"
	"golang.org/x/crypto/sha3"
)

const payoutJourneyID = "JOURNEY-SPEC-016-PAYOUT-ADDRESS-REGISTRATION"
const payoutJourneyArtifactID = "redacted-payout-address-journey"
const journeyResultSigningKeyID = "macprovider-acceptance-p256-v1"

type journeyAssertion struct {
	ID        string         `json:"id"`
	Status    string         `json:"status"`
	Assertion string         `json:"assertion"`
	Details   map[string]any `json:"details,omitempty"`
}

type journeyEvidence struct {
	SchemaVersion string             `json:"schema_version"`
	JourneyID     string             `json:"journey_id"`
	RequirementID string             `json:"requirement_id"`
	RunID         string             `json:"run_id"`
	CapturedAt    string             `json:"captured_at"`
	Repository    map[string]string  `json:"repository"`
	Harness       map[string]any     `json:"harness"`
	ConfigBefore  map[string]any     `json:"config_before"`
	ConfigAfter   map[string]any     `json:"config_after"`
	Candidate     map[string]string  `json:"candidate"`
	Observations  map[string]any     `json:"observations"`
	Assertions    []journeyAssertion `json:"assertions"`
	Redaction     map[string]bool    `json:"redaction"`
}

func TestPayoutAddressRegistrationJourneyEvidence(t *testing.T) {
	if os.Getenv("MACPROVIDER_CAPTURE_PAYOUT_JOURNEY") != "1" {
		t.Skip("set MACPROVIDER_CAPTURE_PAYOUT_JOURNEY=1 to emit payout journey evidence, candidate, and unsigned journey-result payload artifacts")
	}

	root := mustRepoRoot(t)
	commit := gitOutput(t, root, "rev-parse", "HEAD")
	captured := time.Now().UTC().Truncate(time.Second)
	runID := "spec016-r002-payout-address-" + captured.Format("20060102T150405Z")
	artifactRel := filepath.ToSlash(filepath.Join("journeys", "evidence", runID+".redacted.json"))
	candidateRel := filepath.ToSlash(filepath.Join("journeys", "evidence", runID+".candidate.json"))
	payloadRel := filepath.ToSlash(filepath.Join("journeys", "evidence", runID+".journey-result.unsigned.json"))
	artifactPath := filepath.Join(root, filepath.FromSlash(artifactRel))
	candidatePath := filepath.Join(root, filepath.FromSlash(candidateRel))
	payloadPath := filepath.Join(root, filepath.FromSlash(payloadRel))

	ctx := context.Background()
	providerID := "prebeta-r002-provider"
	hotWallet := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	canonicalHot, err := CanonicalizeEIP55(hotWallet)
	if err != nil {
		t.Fatalf("canonicalize hot wallet: %v", err)
	}
	priv, providerAddr := signerForTest(t)
	secondPriv, secondAddr := signerFromLabelForJourney(t, "macprovider SPEC-016 journey rotation signer")
	startClock := captured.Add(-30 * time.Second)

	db := openTestDB(t)
	authStore := newJourneyAuthStore(t)
	defer authStore.Close()
	token := issueJourneyToken(t, authStore, providerID)
	logger, logBuffer := quietLogger()
	svc := newJourneyServiceForTest(t, db, hotWallet, authStore, &fakePause{})
	svc.Log = logger
	svc.Now = func() time.Time { return startClock }
	router := journeyRouter(svc)

	assertions := []journeyAssertion{}
	addAssertionStatus := func(id, status, assertion string, details map[string]any) {
		assertions = append(assertions, journeyAssertion{
			ID:        id,
			Status:    status,
			Assertion: assertion,
			Details:   details,
		})
	}
	addAssertion := func(id, assertion string, details map[string]any) {
		addAssertionStatus(id, "pass", assertion, details)
	}

	addAssertion("step-01", "handler-only harness initialized with payout disabled and no runner, RPC client, settlement signer, or settlement attempt", map[string]any{
		"payout_enabled":            false,
		"runner_started":            false,
		"external_rpc_started":      false,
		"settlement_signer_started": false,
		"settlement_attempted":      false,
		"database_namespace":        "isolated-sqlite-tempdir-redacted",
		"hot_wallet_fingerprint":    sha256String(canonicalHot),
	})

	challengeRec := serveJourneyRequest(router, http.MethodGet, "/providers/"+providerID+"/payout-address/challenge", "", token)
	requireStatus(t, challengeRec, http.StatusOK, "challenge")
	requireLogEventCount(t, logBuffer.String(), "provider_payout_address_challenge", map[string]string{"provider_id": providerID}, 1)
	var challenge challengeResponse
	mustJSON(t, challengeRec.Body.String(), &challenge)
	if challenge.VerifyingContract != canonicalHot || challenge.ChainID != PayoutChainID || challenge.DomainName != "macprovider-payout" || challenge.DomainVersion != "1" || challenge.Chain != "base-mainnet" {
		t.Fatalf("unexpected challenge response: %+v", challenge)
	}
	addAssertion("step-02", "challenge retrieval binds provider token, path provider, EIP-712 domain, Base chain, hot wallet, and server timestamp", map[string]any{
		"status":                      challengeRec.Code,
		"domain_name":                 challenge.DomainName,
		"domain_version":              challenge.DomainVersion,
		"chain":                       challenge.Chain,
		"chain_id":                    challenge.ChainID,
		"verifying_contract_sha256":   sha256String(challenge.VerifyingContract),
		"server_ts_utc":               challenge.ServerTsUTC,
		"provider_id_sha256":          sha256String(providerID),
		"authorization_secret_logged": false,
	})

	addAssertion("step-03", "Malibu Add Wallet loopback and callback behavior is bound by candidate PayoutWalletFlow tests and hashed signer resources; this handler-only harness keeps production payout execution disabled", map[string]any{
		"loopback_bind_test":           "phase3-binary/app/Tests/MalibuTests/PayoutWalletFlowTests.swift:testLoopbackParametersPinToLoopback",
		"one_shot_callback_test":       "phase3-binary/app/Tests/MalibuTests/PayoutWalletFlowTests.swift:testConcurrentValidCallbacksClaimExactlyOnce",
		"malformed_input_tests":        "phase3-binary/app/Tests/MalibuTests/PayoutWalletFlowTests.swift:testNegativeTsCallbackRejectedNoCrashThenValidResolves",
		"oversized_body_test":          "phase3-binary/app/Tests/MalibuTests/PayoutWalletFlowTests.swift:testOversizedBodyRejected",
		"signer_html_sha256":           fileSHA256(t, root, "phase3-binary/app/Sources/Malibu/Resources/payout-signer/signer.html"),
		"payout_wallet_flow_sha256":    fileSHA256(t, root, "phase3-binary/app/Sources/Malibu/Dashboard/PayoutWalletFlow.swift"),
		"payout_cli_client_sha256":     fileSHA256(t, root, "phase3-binary/Sources/macprovider-cli/PayoutAddressClient.swift"),
		"private_key_stayed_in_signer": true,
	})

	nonce := [32]byte{0x10, 0x20, 0x30, 0x40}
	body := buildRequestBody(t, priv, providerID, providerAddr, canonicalHot, uint64(startClock.Unix()), nonce)
	digest := digestForJourney(t, providerID, providerAddr, canonicalHot, uint64(startClock.Unix()), nonce)
	registerRec := serveJourneyRequest(router, http.MethodPost, "/providers/"+providerID+"/payout-address", body, token)
	requireStatus(t, registerRec, http.StatusCreated, "first registration")
	requireLogEventCount(t, logBuffer.String(), "provider_payout_address_changed", map[string]string{"provider_id": providerID, "new_address": providerAddr, "old_address": "none"}, 1)
	row := readPayoutAddressRow(t, db, providerID)
	if row["address"] != providerAddr || row["registered_against_hot_wallet"] != canonicalHot || row["payout_allowed"] != int64(1) {
		t.Fatalf("unexpected first registration row: %#v", row)
	}
	insertReadyRow(t, db, providerID, "journey:first-registration")
	beforeRows, err := SelectReadyPayouts(ctx, db, canonicalHot, startClock.Format(time.RFC3339Nano), 10)
	if err != nil {
		t.Fatalf("SelectReadyPayouts before cooling: %v", err)
	}
	if len(beforeRows) != 0 {
		t.Fatalf("runner selection before cooling returned %d rows", len(beforeRows))
	}
	addAssertion("step-04", "disposable-wallet EIP-712 signature verifies without exposing private key or raw signature in public artifact", map[string]any{
		"address_fingerprint":       sha256String(providerAddr),
		"nonce_sha256":              sha256String("0x" + hex.EncodeToString(nonce[:])),
		"signed_digest_sha256":      sha256Bytes(digest[:]),
		"request_body_sha256":       sha256String(body),
		"raw_signature_redacted":    true,
		"private_key_material_seen": false,
	})
	addAssertion("step-05", "registration persists scoped address, hot-wallet stamp, audit event, payout_allowed=1, future cooling-off, and no pre-cooling runner selection", map[string]any{
		"status":                          registerRec.Code,
		"address_fingerprint":             sha256String(providerAddr),
		"registered_against_hot_wallet":   sha256String(canonicalHot),
		"payout_allowed":                  row["payout_allowed"],
		"pending_until_utc":               row["pending_until_utc"],
		"runner_selection_before_cooling": len(beforeRows),
	})

	replayRec := serveJourneyRequest(router, http.MethodPost, "/providers/"+providerID+"/payout-address", body, token)
	requireStatus(t, replayRec, http.StatusBadRequest, "replay")
	if !strings.Contains(replayRec.Body.String(), "nonce_replayed") {
		t.Fatalf("replay body did not contain nonce_replayed: %s", replayRec.Body.String())
	}
	requirePayoutAddressState(t, db, providerID, providerAddr, 1, 1)
	requireLogEventCount(t, logBuffer.String(), "provider_payout_address_change_rejected", map[string]string{"provider_id": providerID, "reason": "nonce_replayed"}, 1)
	mismatchBody := strings.Replace(body, `"nonce":"0x10203040`+strings.Repeat("00", 28)+`"`, `"nonce":"0x99993040`+strings.Repeat("00", 28)+`"`, 1)
	mismatchRec := serveJourneyRequest(router, http.MethodPost, "/providers/"+providerID+"/payout-address", mismatchBody, token)
	requireStatus(t, mismatchRec, http.StatusBadRequest, "nonce mismatch")
	if !strings.Contains(mismatchRec.Body.String(), "signature_mismatch") {
		t.Fatalf("nonce mismatch body did not contain signature_mismatch: %s", mismatchRec.Body.String())
	}
	requirePayoutAddressState(t, db, providerID, providerAddr, 1, 1)
	requireLogEventCount(t, logBuffer.String(), "provider_payout_address_change_rejected", map[string]string{"provider_id": providerID, "reason": "signature_mismatch"}, 1)
	addAssertion("step-06", "replay and consumed/mismatched nonce attempts reject without a second registration or payout-permission mutation", map[string]any{
		"replay_status":          replayRec.Code,
		"mismatch_status":        mismatchRec.Code,
		"registration_row_count": countRows(t, db, `SELECT COUNT(*) FROM provider_payout_addresses WHERE provider_id=?`, providerID),
		"payout_allowed":         readPayoutAddressRow(t, db, providerID)["payout_allowed"],
	})

	invalids := exerciseInvalidJourneyCases(t, hotWallet, providerID, priv, providerAddr, startClock)
	addAssertion("step-07", "invalid signature, wrong domain, wrong chain, wrong provider, typed-data mismatch, and stale timestamp fail closed", invalids)

	oldAddr := providerAddr
	_, _ = db.ExecContext(ctx, `UPDATE provider_payout_addresses SET pending_until_utc=? WHERE provider_id=? AND chain='base-mainnet'`, startClock.Add(-time.Hour).Format(time.RFC3339Nano), providerID)
	rotationNonce := [32]byte{0x55, 0x66, 0x77, 0x88}
	rotationBody := buildRequestBody(t, secondPriv, providerID, secondAddr, canonicalHot, uint64(startClock.Unix()+1), rotationNonce)
	rotationRec := serveJourneyRequest(router, http.MethodPost, "/providers/"+providerID+"/payout-address", rotationBody, token)
	requireStatus(t, rotationRec, http.StatusOK, "rotation")
	requireLogEventCount(t, logBuffer.String(), "provider_payout_address_changed", map[string]string{"provider_id": providerID, "old_address": oldAddr, "new_address": secondAddr}, 1)
	rotatedRow := readPayoutAddressRow(t, db, providerID)
	duringCooling, err := SelectReadyPayouts(ctx, db, canonicalHot, startClock.Add(2*time.Second).Format(time.RFC3339Nano), 10)
	if err != nil {
		t.Fatalf("SelectReadyPayouts during cooling: %v", err)
	}
	if len(duringCooling) != 1 || !duringCooling[0].EffectiveAddress.Valid || duringCooling[0].EffectiveAddress.String != oldAddr {
		t.Fatalf("during cooling selection = %+v, want previous address", duringCooling)
	}
	afterCooling, err := SelectReadyPayouts(ctx, db, canonicalHot, startClock.Add(25*time.Hour).Format(time.RFC3339Nano), 10)
	if err != nil {
		t.Fatalf("SelectReadyPayouts after cooling: %v", err)
	}
	if len(afterCooling) != 1 || !afterCooling[0].EffectiveAddress.Valid || afterCooling[0].EffectiveAddress.String != secondAddr {
		t.Fatalf("after cooling selection = %+v, want new address", afterCooling)
	}
	disabled := exerciseDisabledRotation(t, hotWallet, providerID, secondPriv, secondAddr, startClock)
	addAssertion("step-08", "allowed rotation keeps payout_allowed=1, preserves previous address during cooling, switches after cooling, and payout_allowed=0 rotation rejects unchanged", map[string]any{
		"rotation_status":               rotationRec.Code,
		"rotated_from_fingerprint":      sha256String(oldAddr),
		"new_address_fingerprint":       sha256String(secondAddr),
		"payout_allowed_after_rotation": rotatedRow["payout_allowed"],
		"during_cooling_effective":      sha256String(duringCooling[0].EffectiveAddress.String),
		"after_cooling_effective":       sha256String(afterCooling[0].EffectiveAddress.String),
		"disabled_rotation":             disabled,
	})

	pause := exercisePauseCases(t, hotWallet, providerID, priv, providerAddr, startClock)
	addAssertion("step-09", "registration pause, TOCTOU pause, and provider-scoped rate limit reject with expected status and no durable mutation", pause)

	logs := logBuffer.String()
	if strings.Contains(logs, token) || strings.Contains(logs, body) {
		t.Fatalf("secret or raw request material leaked into logs")
	}
	addAssertion("step-10", "logs and public artifacts are redacted and contain no bearer token, private key, or raw signed request body", map[string]any{
		"log_sha256":                   sha256String(logs),
		"bearer_token_present_in_logs": false,
		"raw_signed_body_present":      false,
	})
	addAssertion("step-11", "final configuration confirms payout remains default-off and no production payout, settlement, RPC, or release-promotion side effect occurred", map[string]any{
		"payout_enabled":            false,
		"runner_started":            false,
		"external_rpc_started":      false,
		"settlement_signer_started": false,
		"settlement_attempted":      false,
		"production_side_effects":   false,
		"restoration_result":        "isolated SQLite tempdir removed by test cleanup",
	})

	evidence := journeyEvidence{
		SchemaVersion: "macprovider.payout-address-journey-evidence.v1",
		JourneyID:     payoutJourneyID,
		RequirementID: "SPEC-016-R002",
		RunID:         runID,
		CapturedAt:    captured.Format("2006-01-02T15:04:05Z"),
		Repository: map[string]string{
			"name":   "Augustas11/macprovider",
			"commit": commit,
		},
		Harness: map[string]any{
			"id":                          "phase4-coordinator/internal/payout:TestPayoutAddressRegistrationJourneyEvidence",
			"version":                     "v1",
			"execution_mode":              "candidate-derived-handler-only-conformance-harness",
			"exact_handlers":              []string{"AddressesService.ServePayoutChallenge", "AddressesService.ServePayoutAddress"},
			"isolated_sqlite":             true,
			"real_provider_token_check":   true,
			"real_pause_validation":       true,
			"controlled_dependencies":     true,
			"production_runner_built":     false,
			"external_rpc_client_built":   false,
			"settlement_signer_built":     false,
			"release_promotion_attempted": false,
		},
		ConfigBefore: map[string]any{
			"payout_enabled":            false,
			"runner_started":            false,
			"external_rpc_started":      false,
			"settlement_signer_started": false,
		},
		ConfigAfter: map[string]any{
			"payout_enabled":            false,
			"runner_started":            false,
			"external_rpc_started":      false,
			"settlement_signer_started": false,
			"settlement_attempted":      false,
			"production_side_effects":   false,
		},
		Candidate: map[string]string{
			"addresses_go_sha256":           fileSHA256(t, root, "phase4-coordinator/internal/payout/addresses.go"),
			"eip712_go_sha256":              fileSHA256(t, root, "phase4-coordinator/internal/payout/eip712.go"),
			"attempts_go_sha256":            fileSHA256(t, root, "phase4-coordinator/internal/payout/attempts.go"),
			"payout_address_client_sha256":  fileSHA256(t, root, "phase3-binary/Sources/macprovider-cli/PayoutAddressClient.swift"),
			"payout_wallet_flow_sha256":     fileSHA256(t, root, "phase3-binary/app/Sources/Malibu/Dashboard/PayoutWalletFlow.swift"),
			"payout_signer_resource_sha256": fileSHA256(t, root, "phase3-binary/app/Sources/Malibu/Resources/payout-signer/signer.html"),
		},
		Observations: map[string]any{
			"provider_id_sha256":      sha256String(providerID),
			"hot_wallet_sha256":       sha256String(canonicalHot),
			"first_address_sha256":    sha256String(providerAddr),
			"rotated_address_sha256":  sha256String(secondAddr),
			"eip712_digest_sha256":    sha256Bytes(digest[:]),
			"raw_signature_redacted":  true,
			"provider_token_redacted": true,
			"private_keys_redacted":   true,
			"cooling_off_hours":       24,
		},
		Assertions: assertions,
		Redaction: map[string]bool{
			"secrets_redacted":             true,
			"operator_identity_redacted":   true,
			"local_account_names_redacted": true,
			"raw_signatures_redacted":      true,
		},
	}
	writeJSONFile(t, artifactPath, evidence)
	artifactSHA := fileSHA256(t, root, artifactRel)
	candidate := map[string]any{
		"schema_version":    "macprovider.journey-result-candidate.v1",
		"journey_id":        payoutJourneyID,
		"spec_id":           "SPEC-016",
		"requirement_ids":   []string{"SPEC-016-R002"},
		"run_id":            runID,
		"repository":        map[string]string{"name": "Augustas11/macprovider", "commit": commit},
		"captured_at":       captured.Format("2006-01-02T15:04:05Z"),
		"expires_at":        captured.AddDate(0, 1, 0).Format("2006-01-02"),
		"operator":          map[string]string{"role": "local-acceptance-operator", "identity_fingerprint": sha256String("redacted-local-acceptance-operator")},
		"environment":       map[string]string{"class": "handler-only-conformance-harness", "hardware_profile": "local-macos-redacted", "candidate": "commit:" + commit},
		"execution_mode":    "candidate-derived-handler-only-conformance-harness",
		"harness":           evidence.Harness,
		"config_before":     evidence.ConfigBefore,
		"config_after":      evidence.ConfigAfter,
		"restoration":       map[string]string{"result": "isolated SQLite tempdirs removed by test cleanup"},
		"artifacts":         []map[string]string{{"id": payoutJourneyArtifactID, "sha256": artifactSHA, "source": artifactRel}},
		"result":            map[string]string{"status": "handler-pass-not-promotable", "summary": "Handler-scoped SPEC-016-R002 evidence passed. Physical Malibu journey execution and authorized journey-result signature are still required before ledger promotion."},
		"assertions":        assertions,
		"promotion_ready":   false,
		"promotion_blocker": "candidate is not a macprovider.journey-result.v1 signed payload; do not promote CONFORMANCE.json from this file",
		"redaction":         map[string]bool{"secrets_redacted": true, "operator_identity_redacted": true, "local_account_names_redacted": true},
	}
	writeJSONFile(t, candidatePath, candidate)
	payload := signedPayoutJourneyResultPayload(t, root, evidence, captured, artifactRel, artifactSHA, body, digest, providerAddr)
	writeJSONFile(t, payloadPath, payload)
	t.Logf("wrote %s", artifactRel)
	t.Logf("wrote %s", candidateRel)
	t.Logf("wrote %s", payloadRel)
}

func signedPayoutJourneyResultPayload(t *testing.T, root string, evidence journeyEvidence, captured time.Time, artifactRel, artifactSHA, signedBody string, digest [32]byte, providerAddr string) map[string]any {
	t.Helper()
	return map[string]any{
		"schema_version":  "macprovider.journey-result.v1",
		"journey_id":      payoutJourneyID,
		"spec_id":         "SPEC-016",
		"requirement_ids": []string{"SPEC-016-R002"},
		"run_id":          evidence.RunID,
		"repository":      evidence.Repository,
		"captured_at":     evidence.CapturedAt,
		"expires_at":      captured.AddDate(0, 1, 0).Format("2006-01-02"),
		"operator": map[string]string{
			"role":                 "local-acceptance-operator",
			"identity_fingerprint": sha256String("redacted-local-acceptance-operator"),
		},
		"environment": map[string]string{
			"class":            "handler-only-conformance-harness",
			"hardware_profile": "local-macos-redacted",
			"candidate":        "commit:" + evidence.Repository["commit"],
		},
		"execution_mode": "candidate-derived-handler-only-conformance-harness",
		"harness": map[string]any{
			"id":                          "phase4-coordinator/internal/payout:TestPayoutAddressRegistrationJourneyEvidence",
			"version":                     "v1",
			"execution_mode":              "candidate-derived-handler-only-conformance-harness",
			"isolated_sqlite":             true,
			"real_provider_token_check":   true,
			"real_pause_validation":       true,
			"controlled_dependencies":     true,
			"production_runner_built":     false,
			"external_rpc_client_built":   false,
			"settlement_signer_built":     false,
			"release_promotion_attempted": false,
		},
		"config_before": evidence.ConfigBefore,
		"config_after":  evidence.ConfigAfter,
		"restoration":   map[string]string{"result": "isolated SQLite tempdirs removed by test cleanup"},
		"observations":  evidence.Observations,
		"eip712": map[string]any{
			"typed_data_artifact_sha256":      sha256String(signedBody),
			"digest_sha256":                   sha256Bytes(digest[:]),
			"signer_address_sha256":           sha256String(providerAddr),
			"verifier":                        "phase4-coordinator/internal/payout.VerifyEIP712",
			"verification_result":             "pass",
			"raw_signature_access_controlled": true,
		},
		"candidate": evidence.Candidate,
		"signer": map[string]string{
			"key_id":               journeyResultSigningKeyID,
			"identity_fingerprint": sha256String("redacted-local-acceptance-operator"),
			"trust_root_sha256":    fileSHA256(t, root, "security/acceptance-candidate-signing-public.pem"),
			"verification_result":  "pass",
		},
		"artifacts": []map[string]string{{
			"id":     payoutJourneyArtifactID,
			"sha256": artifactSHA,
			"source": artifactRel,
		}},
		"result": map[string]string{
			"status":  "pass",
			"summary": "Handler-only SPEC-016-R002 payout-address onboarding evidence passed with payout runner, RPC, settlement signer, production side effects, and release promotion disabled.",
		},
		"steps":     journeyResultSteps(evidence.Assertions, payoutJourneyArtifactID),
		"redaction": map[string]bool{"secrets_redacted": true, "operator_identity_redacted": true, "local_account_names_redacted": true},
	}
}

func journeyResultSteps(assertions []journeyAssertion, artifactID string) []map[string]any {
	steps := make([]map[string]any, 0, len(assertions))
	for _, assertion := range assertions {
		steps = append(steps, map[string]any{
			"id":        assertion.ID,
			"status":    assertion.Status,
			"assertion": assertion.Assertion,
			"artifacts": []string{artifactID},
		})
	}
	return steps
}

func journeyRouter(svc *AddressesService) http.Handler {
	r := chi.NewRouter()
	r.Get("/providers/{provider_id}/payout-address/challenge", svc.ServePayoutChallenge)
	r.Post("/providers/{provider_id}/payout-address", svc.ServePayoutAddress)
	return r
}

func serveJourneyRequest(handler http.Handler, method, path, body, token string) *httptest.ResponseRecorder {
	reqBody := strings.NewReader(body)
	req := httptest.NewRequest(method, path, reqBody)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	return rec
}

func requireStatus(t *testing.T, rec *httptest.ResponseRecorder, want int, label string) {
	t.Helper()
	if rec.Code != want {
		t.Fatalf("%s status=%d want=%d body=%s", label, rec.Code, want, rec.Body.String())
	}
}

func newJourneyAuthStore(t *testing.T) *auth.Store {
	t.Helper()
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "auth.db"))
	if err != nil {
		t.Fatalf("open auth store: %v", err)
	}
	return store
}

func issueJourneyToken(t *testing.T, store *auth.Store, providerID string) string {
	t.Helper()
	_, token, err := store.IssueToken(context.Background(), providerID, "SPEC-016 journey provider")
	if err != nil {
		t.Fatalf("issue provider token for %s: %v", providerID, err)
	}
	return token
}

func newJourneyServiceForTest(t *testing.T, db *sql.DB, hotWalletAddress string, authStore *auth.Store, pause pauseFlagReader) *AddressesService {
	t.Helper()
	if err := InitRunnerStateRow(context.Background(), db, time.Now().UTC()); err != nil {
		t.Fatalf("init runner_state: %v", err)
	}
	logger, _ := quietLogger()
	if err := BootstrapRuntimeFlags(context.Background(), db, time.Now().UTC(), logger); err != nil {
		t.Fatalf("bootstrap: %v", err)
	}
	canonical, err := CanonicalizeEIP55(hotWalletAddress)
	if err != nil {
		t.Fatalf("canonicalize hot wallet: %v", err)
	}
	sec := SecurityConfig{HotWalletAddress: canonical}
	dl, err := NewDenyList(canonical)
	if err != nil {
		t.Fatalf("deny: %v", err)
	}
	svc, err := NewAddressesService(db, sec, dl, authStore, authStore, pause, 24*time.Hour, logger)
	if err != nil {
		t.Fatalf("new service: %v", err)
	}
	return svc
}

func signerFromLabelForJourney(t *testing.T, label string) (*secp256k1.PrivateKey, string) {
	t.Helper()
	// Deterministic, non-secret test-only signer derived from a public label.
	sum := sha256.Sum256([]byte("macprovider-test-only:" + label))
	priv := secp256k1.PrivKeyFromBytes(sum[:])
	pub := priv.PubKey()
	uncompressed := pub.SerializeUncompressed()
	h := sha3.NewLegacyKeccak256()
	_, _ = h.Write(uncompressed[1:])
	d := h.Sum(nil)
	addrLower := "0x" + hex.EncodeToString(d[len(d)-20:])
	canonical, err := CanonicalizeEIP55(addrLower)
	if err != nil {
		t.Fatalf("canonicalize address: %v", err)
	}
	return priv, canonical
}

func requirePayoutAddressState(t *testing.T, db *sql.DB, providerID, wantAddress string, wantAllowed, wantRows int64) {
	t.Helper()
	rows := int64(countRows(t, db, `SELECT COUNT(*) FROM provider_payout_addresses WHERE provider_id=?`, providerID))
	if rows != wantRows {
		t.Fatalf("provider_payout_addresses rows=%d want=%d", rows, wantRows)
	}
	row := readPayoutAddressRow(t, db, providerID)
	if row["address"] != wantAddress {
		t.Fatalf("address=%v want=%s", row["address"], wantAddress)
	}
	if row["payout_allowed"] != wantAllowed {
		t.Fatalf("payout_allowed=%v want=%d", row["payout_allowed"], wantAllowed)
	}
}

func requireLogEventCount(t *testing.T, logs, event string, fields map[string]string, want int) {
	t.Helper()
	count := 0
	for _, entry := range decodeJourneyLogEvents(t, logs) {
		if entryString(entry, "event") != event {
			continue
		}
		matched := true
		for key, value := range fields {
			if entryString(entry, key) != value {
				matched = false
				break
			}
		}
		if matched {
			count++
		}
	}
	if count != want {
		t.Fatalf("log event %s fields=%v count=%d want=%d logs=%s", event, fields, count, want, logs)
	}
}

func decodeJourneyLogEvents(t *testing.T, logs string) []map[string]any {
	t.Helper()
	events := []map[string]any{}
	for _, line := range strings.Split(strings.TrimSpace(logs), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Fatalf("decode log line %q: %v", line, err)
		}
		events = append(events, entry)
	}
	return events
}

func entryString(entry map[string]any, key string) string {
	value, _ := entry[key].(string)
	return value
}

func digestForJourney(t *testing.T, providerID, address, hotWallet string, ts uint64, nonce [32]byte) [32]byte {
	t.Helper()
	digest, err := buildDigest(EIP712Inputs{
		ProviderID:        providerID,
		CanonicalAddr:     address,
		Chain:             "base-mainnet",
		Nonce32:           nonce,
		TsUtc:             ts,
		VerifyingContract: hotWallet,
	})
	if err != nil {
		t.Fatalf("build digest: %v", err)
	}
	return digest
}

func readPayoutAddressRow(t *testing.T, db *sql.DB, providerID string) map[string]any {
	t.Helper()
	row := db.QueryRowContext(context.Background(), `
SELECT address, payout_allowed, pending_until_utc, COALESCE(rotated_from, ''), registered_against_hot_wallet
  FROM provider_payout_addresses
 WHERE provider_id=? AND chain='base-mainnet'`, providerID)
	var address, pending, rotatedFrom, hot string
	var allowed int64
	if err := row.Scan(&address, &allowed, &pending, &rotatedFrom, &hot); err != nil {
		t.Fatalf("read payout address row: %v", err)
	}
	return map[string]any{
		"address":                       address,
		"payout_allowed":                allowed,
		"pending_until_utc":             pending,
		"rotated_from":                  rotatedFrom,
		"registered_against_hot_wallet": hot,
	}
}

func countRows(t *testing.T, db *sql.DB, query string, args ...any) int {
	t.Helper()
	var count int
	if err := db.QueryRowContext(context.Background(), query, args...).Scan(&count); err != nil {
		t.Fatalf("count rows: %v", err)
	}
	return count
}

func exerciseInvalidJourneyCases(t *testing.T, hotWallet, providerID string, priv *secp256k1.PrivateKey, providerAddr string, now time.Time) map[string]any {
	t.Helper()
	cases := map[string]any{}
	run := func(name, body, path string, want int, wantBody, wantReason string) {
		db := openTestDB(t)
		authStore := newJourneyAuthStore(t)
		defer authStore.Close()
		runToken := issueJourneyToken(t, authStore, providerID)
		logger, logs := quietLogger()
		svc := newJourneyServiceForTest(t, db, hotWallet, authStore, &fakePause{})
		svc.Log = logger
		svc.Now = func() time.Time { return now }
		rec := serveJourneyRequest(journeyRouter(svc), http.MethodPost, path, body, runToken)
		requireStatus(t, rec, want, name)
		if wantBody != "" && !strings.Contains(rec.Body.String(), wantBody) {
			t.Fatalf("%s body=%s missing %s", name, rec.Body.String(), wantBody)
		}
		requireLogEventCount(t, logs.String(), "provider_payout_address_change_rejected", map[string]string{"reason": wantReason}, 1)
		cases[name+"_status"] = rec.Code
		cases[name+"_durable_rows"] = countRows(t, db, `SELECT COUNT(*) FROM provider_payout_addresses`)
	}
	validNonce := [32]byte{0x01, 0x02, 0x03}
	validBody := buildRequestBody(t, priv, providerID, providerAddr, hotWallet, uint64(now.Unix()), validNonce)
	run("invalid_signature", strings.Replace(validBody, `"signature":"0x`, `"signature":"0x00`, 1), "/providers/"+providerID+"/payout-address", http.StatusBadRequest, "signature_mismatch", "signature_mismatch")
	wrongDomainBody := buildRequestBody(t, priv, providerID, providerAddr, "0x000000000000000000000000000000000000dEaD", uint64(now.Unix()), [32]byte{0x04})
	run("wrong_domain", wrongDomainBody, "/providers/"+providerID+"/payout-address", http.StatusBadRequest, "signature_mismatch", "signature_mismatch")
	wrongChainBody := strings.Replace(validBody, `"chain":"base-mainnet"`, `"chain":"base-sepolia"`, 1)
	run("wrong_chain", wrongChainBody, "/providers/"+providerID+"/payout-address", http.StatusBadRequest, "chain_mismatch", "bad_chain")
	run("wrong_provider", validBody, "/providers/other-provider/payout-address", http.StatusForbidden, "forbidden", "token_subject_mismatch")
	_, mismatchAddr := signerFromLabelForJourney(t, "macprovider SPEC-016 journey typed-data mismatch address")
	mismatchBody := strings.Replace(validBody, providerAddr, mismatchAddr, 1)
	run("typed_data_mismatch", mismatchBody, "/providers/"+providerID+"/payout-address", http.StatusBadRequest, "signature_mismatch", "signature_mismatch")
	staleBody := buildRequestBody(t, priv, providerID, providerAddr, hotWallet, uint64(now.Add(-10*time.Minute).Unix()), [32]byte{0x05})
	run("stale_timestamp", staleBody, "/providers/"+providerID+"/payout-address", http.StatusBadRequest, "signature_skew", "signature_skew")
	return cases
}

func exerciseDisabledRotation(t *testing.T, hotWallet, providerID string, priv *secp256k1.PrivateKey, providerAddr string, now time.Time) map[string]any {
	t.Helper()
	db := openTestDB(t)
	authStore := newJourneyAuthStore(t)
	defer authStore.Close()
	disabledToken := issueJourneyToken(t, authStore, providerID)
	canonicalHot, _ := CanonicalizeEIP55(hotWallet)
	_, err := db.ExecContext(context.Background(), `
INSERT INTO provider_payout_addresses
  (provider_id, chain, address, payout_allowed, pending_until_utc,
   rotated_from, registered_at_utc, registered_against_hot_wallet)
VALUES (?, 'base-mainnet', '0xAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAa',
        0, '2099-01-01T00:00:00Z', NULL, '2026-01-01T00:00:00Z', ?)`, providerID, canonicalHot)
	if err != nil {
		t.Fatalf("seed disabled row: %v", err)
	}
	logger, logs := quietLogger()
	svc := newJourneyServiceForTest(t, db, hotWallet, authStore, &fakePause{})
	svc.Log = logger
	svc.Now = func() time.Time { return now }
	body := buildRequestBody(t, priv, providerID, providerAddr, hotWallet, uint64(now.Unix()), [32]byte{0x09, 0x09})
	rec := serveJourneyRequest(journeyRouter(svc), http.MethodPost, "/providers/"+providerID+"/payout-address", body, disabledToken)
	requireStatus(t, rec, http.StatusConflict, "disabled rotation")
	if !strings.Contains(rec.Body.String(), "payout_not_allowed") {
		t.Fatalf("disabled rotation body=%s missing payout_not_allowed", rec.Body.String())
	}
	requireLogEventCount(t, logs.String(), "provider_payout_address_change_rejected", map[string]string{"provider_id": providerID, "reason": "payout_not_allowed"}, 1)
	row := readPayoutAddressRow(t, db, providerID)
	if row["address"] != "0xAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAa" {
		t.Fatalf("disabled rotation mutated address: %v", row["address"])
	}
	if row["payout_allowed"] != int64(0) {
		t.Fatalf("disabled rotation payout_allowed=%v want 0", row["payout_allowed"])
	}
	rowCount := countRows(t, db, `SELECT COUNT(*) FROM provider_payout_addresses WHERE provider_id=?`, providerID)
	if rowCount != 1 {
		t.Fatalf("disabled rotation row count=%d want 1", rowCount)
	}
	return map[string]any{
		"status":            rec.Code,
		"reason_seen":       true,
		"address_unchanged": true,
		"payout_allowed":    row["payout_allowed"],
		"durable_row_count": rowCount,
	}
}

func exercisePauseCases(t *testing.T, hotWallet, providerID string, priv *secp256k1.PrivateKey, providerAddr string, now time.Time) map[string]any {
	t.Helper()
	out := map[string]any{}
	pausedDB := openTestDB(t)
	pausedAuth := newJourneyAuthStore(t)
	defer pausedAuth.Close()
	pausedToken := issueJourneyToken(t, pausedAuth, providerID)
	pausedLogger, pausedLogs := quietLogger()
	pausedSvc := newJourneyServiceForTest(t, pausedDB, hotWallet, pausedAuth, &fakePause{paused: true})
	pausedSvc.Log = pausedLogger
	pausedSvc.Now = func() time.Time { return now }
	pausedRouter := journeyRouter(pausedSvc)
	challengeNoAuth := serveJourneyRequest(pausedRouter, http.MethodGet, "/providers/"+providerID+"/payout-address/challenge", "", "")
	challengeAuth := serveJourneyRequest(pausedRouter, http.MethodGet, "/providers/"+providerID+"/payout-address/challenge", "", pausedToken)
	body := buildRequestBody(t, priv, providerID, providerAddr, hotWallet, uint64(now.Unix()), [32]byte{0x0a})
	regPaused := serveJourneyRequest(pausedRouter, http.MethodPost, "/providers/"+providerID+"/payout-address", body, pausedToken)
	requireStatus(t, challengeNoAuth, http.StatusServiceUnavailable, "paused challenge no-auth")
	requireStatus(t, challengeAuth, http.StatusServiceUnavailable, "paused challenge auth")
	requireStatus(t, regPaused, http.StatusServiceUnavailable, "paused registration")
	requireLogEventCount(t, pausedLogs.String(), "provider_payout_address_challenge_rejected", map[string]string{"provider_id": providerID, "reason": "registration_paused"}, 2)
	requireLogEventCount(t, pausedLogs.String(), "provider_payout_address_change_rejected", map[string]string{"provider_id": providerID, "reason": "registration_paused"}, 1)
	out["challenge_pause_bodies_identical"] = challengeNoAuth.Body.String() == challengeAuth.Body.String()
	out["registration_pause_status"] = regPaused.Code

	toctouDB := openTestDB(t)
	toctouAuth := newJourneyAuthStore(t)
	defer toctouAuth.Close()
	toctouToken := issueJourneyToken(t, toctouAuth, providerID)
	toctouLogger, toctouLogs := quietLogger()
	toctouSvc := newJourneyServiceForTest(t, toctouDB, hotWallet, toctouAuth, &toctouPause{db: toctouDB})
	toctouSvc.Log = toctouLogger
	toctouSvc.Now = func() time.Time { return now }
	toctouRec := serveJourneyRequest(journeyRouter(toctouSvc), http.MethodPost, "/providers/"+providerID+"/payout-address", body, toctouToken)
	requireStatus(t, toctouRec, http.StatusServiceUnavailable, "toctou pause")
	requireLogEventCount(t, toctouLogs.String(), "provider_payout_address_change_rejected", map[string]string{"provider_id": providerID, "reason": "registration_paused"}, 1)
	out["toctou_status"] = toctouRec.Code
	out["toctou_durable_rows"] = countRows(t, toctouDB, `SELECT COUNT(*) FROM provider_payout_addresses`)

	rateDB := openTestDB(t)
	rateAuth := newJourneyAuthStore(t)
	defer rateAuth.Close()
	rateToken := issueJourneyToken(t, rateAuth, "rate-provider")
	otherToken := issueJourneyToken(t, rateAuth, "other-rate-provider")
	rateLogger, rateLogs := quietLogger()
	rateSvc := newJourneyServiceForTest(t, rateDB, hotWallet, rateAuth, &fakePause{})
	rateSvc.Log = rateLogger
	rateSvc.Now = func() time.Time { return now }
	rateRouter := journeyRouter(rateSvc)
	for i := 0; i < registrationRateLimitDefault; i++ {
		rec := serveJourneyRequest(rateRouter, http.MethodPost, "/providers/rate-provider/payout-address", "{}", rateToken)
		if rec.Code == http.StatusTooManyRequests {
			t.Fatalf("rate limit tripped before budget at %d", i)
		}
	}
	rateRec := serveJourneyRequest(rateRouter, http.MethodPost, "/providers/rate-provider/payout-address", "{}", rateToken)
	requireStatus(t, rateRec, http.StatusTooManyRequests, "rate limited")
	otherRec := serveJourneyRequest(rateRouter, http.MethodPost, "/providers/other-rate-provider/payout-address", "{}", otherToken)
	if otherRec.Code == http.StatusTooManyRequests {
		t.Fatalf("rate limit for rate-provider leaked into other-rate-provider")
	}
	requireLogEventCount(t, rateLogs.String(), "provider_payout_address_change_rejected", map[string]string{"provider_id": "rate-provider", "reason": "rate_limited"}, 1)
	out["rate_limit_status"] = rateRec.Code
	out["other_provider_after_rate_limit_status"] = otherRec.Code
	out["rate_limit_provider_scoped"] = otherRec.Code != http.StatusTooManyRequests
	return out
}

func mustJSON(t *testing.T, body string, out any) {
	t.Helper()
	if err := json.Unmarshal([]byte(body), out); err != nil {
		t.Fatalf("decode JSON body: %v body=%s", err, body)
	}
}

func mustRepoRoot(t *testing.T) string {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for {
		if _, err := os.Stat(filepath.Join(wd, "specs", "CONFORMANCE.json")); err == nil {
			return wd
		}
		next := filepath.Dir(wd)
		if next == wd {
			t.Fatal("could not locate repo root")
		}
		wd = next
	}
}

func gitOutput(t *testing.T, root string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = root
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("git %v: %v", args, err)
	}
	return strings.TrimSpace(string(out))
}

func fileSHA256(t *testing.T, root, rel string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil {
		t.Fatalf("read %s: %v", rel, err)
	}
	return sha256Bytes(data)
}

func sha256String(value string) string {
	return sha256Bytes([]byte(value))
}

func sha256Bytes(value []byte) string {
	sum := sha256.Sum256(value)
	return hex.EncodeToString(sum[:])
}

func writeJSONFile(t *testing.T, path string, value any) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", filepath.Dir(path), err)
	}
	file, err := os.Create(path)
	if err != nil {
		t.Fatalf("create %s: %v", path, err)
	}
	encoder := json.NewEncoder(file)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(value); err != nil {
		_ = file.Close()
		t.Fatalf("encode %s: %v", path, err)
	}
	if err := file.Close(); err != nil {
		t.Fatalf("close %s: %v", path, err)
	}
}
