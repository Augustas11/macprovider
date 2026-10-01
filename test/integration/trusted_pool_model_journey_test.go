package integration

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// #1816 (SPEC-042-R015, SPEC-047-R011, SPEC-005-R015, SPEC-022-R013,
// SPEC-006-R018): a pool creator signs a pool_model_entries/v1 entry for a
// GGUF that is in no catalog; a creator-owned llama.cpp member offers that
// unmatched hash; the coordinator binds it to the pool under the signed
// manifest actor; a buyer pool-route request for pool/<pool_id>/<slug> is
// served, priced from the entry, and credited pool_operator_attested; the
// same model id on a global route is unknown.
func TestTrustedPoolModelJourney(t *testing.T) {
	requireBins(t)
	keysDir := filepath.Join(t.TempDir(), "pool-keys")
	keygenOut := runTrustPoolCLI(t, nil, "keygen", "--out-dir", keysDir,
		"--manifest-authority-key-id", "journey-manifest-authority-1",
		"--policy-signer-key-id", "journey-policy-signer-1")
	poolID := cliOutputField(t, keygenOut, "pool_id")
	providerID := "prov-pool-" + randHex(t, 4)
	creator := "acct_creator_1816"
	poolModelID := "pool/" + poolID + "/creator-gguf"
	ggufHash := randHex(t, 32)

	_, admissionPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	s := newScenario(t, scenarioOpts{
		seedAccount:               true,
		settlementReceiptProvider: true,
		settlementEnforceMode:     true,
		providerID:                providerID,
		coordinatorConfig: func(_ *scenario, cfg map[string]any) {
			cfg["coordinator"] = map[string]any{"require_gateway_context": true}
			auth := cfg["auth"].(map[string]any)
			auth["require_provider_tokens"] = true
			cfg["trusted_pools"] = map[string]any{
				"enabled":            true,
				"refresh_interval_s": 1,
				"pool_model_pricing_bounds": map[string]any{
					"min_prompt_rate_per_mtok":           1,
					"max_prompt_rate_per_mtok":           100000000,
					"min_prompt_cache_hit_rate_per_mtok": 0,
					"max_prompt_cache_hit_rate_per_mtok": 100000000,
					"min_completion_rate_per_mtok":       1,
					"max_completion_rate_per_mtok":       100000000,
				},
			}
		},
		gatewayConfig: func(sc *scenario, cfg map[string]any) {
			features := cfg["features"].(map[string]any)
			features["trusted_pools"] = map[string]any{
				"enabled":       true,
				"account_pools": map[string][]string{sc.accountID: {poolID}},
			}
		},
		beforeProviders: func(sc *scenario) {
			setUpPoolModelJourneyPool(t, sc, keysDir, poolID, providerID, creator, poolModelID, ggufHash)
		},
		providerSetup: func(fp *fakeProvider) {
			// The creator-owned llama.cpp member serves the uncatalogued
			// GGUF and enrolls its admission identity.
			fp.modelID = "creator-gguf-model"
			fp.modelHash = ggufHash
			fp.modelHashAlgorithm = "macprovider.gguf-file.v1"
			fp.runtimeSource = "llamacpp_loopback"
			fp.trustedPoolV1 = true
			fp.omitCatalogRelease = true
			fp.binaryVersion = "1.9.0"
			fp.admissionPriv = admissionPriv
		},
	})
	providerToken := s.providerToken

	// The member offers the unmatched GGUF hash; the signed pool manifest
	// binds it at offer time.
	status := submitModelAdmissionOffer(t, s.coordProvURL, providerToken, providerID, admissionPriv, ggufHash)
	binding, _ := status["pool_binding"].(map[string]any)
	if status["admission_state"] != "catalog_priced" || binding == nil || binding["pool_model_id"] != poolModelID ||
		binding["binding_scope"] != "pool" || status["catalog_model_key"] != nil {
		t.Fatalf("offer status = %v", status)
	}
	if guidance, _ := status["provider_guidance"].(map[string]any); guidance["earning_path_class"] != "pool_attested_earning" {
		t.Fatalf("provider guidance = %v", status["provider_guidance"])
	}

	body := `{"model":"` + poolModelID + `","messages":[{"role":"user","content":"hello pool model"}]}`
	// Global route: the pool model id is unknown.
	if code, _, raw := s.chatRequest(map[string]string{"Authorization": "Bearer " + s.apiKey}, body); code == http.StatusOK {
		t.Fatalf("global request for a pool model succeeded: %s", raw)
	}
	// Pool route: served, disclosed, priced from the entry, attested.
	code, headers, raw := s.chatRequest(map[string]string{
		"Authorization":             "Bearer " + s.apiKey,
		"X-MacProvider-Pool-Select": poolID,
	}, body)
	if code != http.StatusOK {
		t.Fatalf("pool-model request status=%d body=%s", code, raw)
	}
	if headers.Get("X-MacProvider-Model-Disclosure") != "pool_attested_unverified" || len(headers.Get("X-MacProvider-Pool-Manifest-Core-Digest")) != 64 {
		t.Fatalf("pool-model disclosure headers = %v", headers)
	}
	db, err := sql.Open("sqlite", s.coordinatorDB+"?mode=ro")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var snapshotJSON string
	if err := db.QueryRow(`SELECT route_snapshot_json FROM settlement_route_snapshots WHERE pool_id = ? ORDER BY id DESC LIMIT 1`, poolID).Scan(&snapshotJSON); err != nil {
		t.Fatalf("pool route snapshot: %v", err)
	}
	var snapshot map[string]any
	if err := json.Unmarshal([]byte(snapshotJSON), &snapshot); err != nil {
		t.Fatal(err)
	}
	if snapshot["expected_model_hash_source"] != "pool_manifest" || snapshot["pool_model_id"] != poolModelID ||
		snapshot["expected_catalog_model_hash"] != ggufHash || snapshot["runtime_source"] != "llamacpp_loopback" ||
		snapshot["pool_operator_account_id"] != creator {
		t.Fatalf("pool route snapshot = %v", snapshot)
	}
	deadline := time.Now().Add(20 * time.Second)
	for {
		var usageSource string
		var gross, provider, quarantined, promptRate, completionRate int64
		err := db.QueryRow(`SELECT sao.usage_source, lrc.gross_credits, lrc.provider_credits, lrc.quarantined,
       lrc.prompt_rate_per_mtok, lrc.completion_rate_per_mtok
  FROM ledger_request_credits lrc JOIN settlement_attempt_outputs sao
    ON sao.request_id = lrc.request_id AND sao.attempt_n = lrc.attempt_n AND sao.provider_id = lrc.provider_id
 WHERE lrc.provider_id = ? ORDER BY lrc.id DESC LIMIT 1`, providerID).Scan(&usageSource, &gross, &provider, &quarantined, &promptRate, &completionRate)
		if err == nil && usageSource == "pool_operator_attested" && quarantined == 0 && gross > 0 && provider > 0 &&
			promptRate == 2000000 && completionRate == 4000000 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("pool-model credit: err=%v usage=%q gross=%d provider=%d quarantined=%d rates=%d/%d", err, usageSource, gross, provider, quarantined, promptRate, completionRate)
		}
		time.Sleep(200 * time.Millisecond)
	}
	// The provider's signed receipt settles the attempt with a verified
	// pool label.
	for {
		var outcome, labelStatus sql.NullString
		err := db.QueryRow(`SELECT settlement_outcome, pool_label_status FROM settlement_receipt_verdicts
 WHERE provider_id = ? ORDER BY rowid DESC LIMIT 1`, providerID).Scan(&outcome, &labelStatus)
		if err == nil && outcome.String == "verified" && labelStatus.String == "verified" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("pool-model settlement verdict: err=%v outcome=%q label=%q", err, outcome.String, labelStatus.String)
		}
		time.Sleep(200 * time.Millisecond)
	}
}

// setUpPoolModelJourneyPool creates, signs, populates, and activates the
// candidate pool through the operator admin surface and the offline signer.
func setUpPoolModelJourneyPool(t *testing.T, s *scenario, keysDir, poolID, providerID, creator, poolModelID, ggufHash string) {
	t.Helper()
	env := map[string]string{
		"MACPROVIDER_COORDINATOR_ADMIN_URL": s.coordProvURL,
		"MACPROVIDER_OPERATOR_KEY":          s.operatorKey,
	}

	// Creator approval, root registration, genesis manifest with the entry.
	approval := map[string]any{
		"creator_account_id":                   creator,
		"approval_record_id":                   "approval-1816",
		"current_approval_version":             "approval-version-1",
		"public_display_name":                  "Pool model journey",
		"legal_support_contact":                "legal@example.test",
		"billing_contact":                      "billing@example.test",
		"emergency_notification_endpoint":      "https://example.test/emergency",
		"acknowledged_max_response_time":       "15m",
		"allowed_product_category":             "design-partner",
		"data_retention_category":              "standard",
		"support_owner":                        "ops",
		"allowed_launch_environment":           "candidate",
		"creator_agreement_id":                 "agreement-1816",
		"creator_agreement_version":            "v1",
		"creator_agreement_expires_at_utc":     time.Now().UTC().Add(30 * 24 * time.Hour).Format(time.RFC3339),
		"creator_agreement_grace_ends_at_utc":  time.Now().UTC().Add(31 * 24 * time.Hour).Format(time.RFC3339),
		"pricing_schedule_id":                  "pricing-1816",
		"pricing_schedule_version":             "v1",
		"prohibited_claim_acknowledgment_hash": sha256HexString("claims"),
		"buyer_disclosure_commitment_hash":     sha256HexString("disclosure"),
		"approval_criteria_hash":               sha256HexString("criteria"),
		"approved_by":                          "operator-a",
		"approved_at_utc":                      time.Now().UTC().Add(-time.Hour).Format(time.RFC3339),
		"status":                               "enabled",
	}
	runTrustPoolCLI(t, env, "upsert-creator", "--operation-id", "journey-creator-1", "--input", writeJSONFile(t, "creator.json", approval))
	nonceOut := runTrustPoolCLI(t, env, "issue-root-nonce", "--operation-id", "journey-nonce-1",
		"--creator-account-id", creator, "--approval-record-id", "approval-1816", "--approval-version", "approval-version-1",
		"--launch-environment", "candidate", "--expires-at", time.Now().UTC().Add(time.Hour).Format(time.RFC3339Nano))
	var nonceResp struct {
		Record struct {
			Nonce        string    `json:"nonce"`
			ExpiresAtUTC time.Time `json:"expires_at_utc"`
		} `json:"root_registration_nonce"`
	}
	decodeCLIJSON(t, nonceOut, &nonceResp)
	nonce := nonceResp.Record
	runTrustPoolCLI(t, env, "create-pool", "--operation-id", "journey-create-1", "--pool-id", poolID,
		"--creator-account-id", creator, "--approval-record-id", "approval-1816")
	custody := writeFile(t, "custody.json", `{"class":"software","description":"integration journey, owner-only temp files"}`+"\n")
	rootEvent := filepath.Join(t.TempDir(), "root.json")
	runTrustPoolCLI(t, nil, "sign-root", "--identity", filepath.Join(keysDir, "pool-identity.json"),
		"--root-issuer-key", filepath.Join(keysDir, "root-issuer-key.pem"), "--root-issuer-key-id", "journey-root-1",
		"--operation-id", "journey-root-1", "--creator-account-id", creator, "--approval-record-id", "approval-1816",
		"--approval-version", "approval-version-1", "--launch-environment", "candidate", "--custody-disclosure", custody,
		"--custody-class", "software", "--display-name", "Pool model journey", "--nonce", nonce.Nonce,
		"--nonce-expiry", nonce.ExpiresAtUTC.UTC().Format(time.RFC3339Nano), "--out", rootEvent)
	runTrustPoolCLI(t, env, "append-event", "--operation-id", "journey-root-1", "--input", rootEvent)
	poolModels := writeJSONFile(t, "pool-models.json", map[string]any{
		"model_entries": []any{map[string]any{
			"pool_model_id":           poolModelID,
			"artifact_hash_algorithm": "macprovider.gguf-file.v1",
			"artifact_hash":           ggufHash,
			"allowed_runtime_sources": []string{"llamacpp_loopback"},
			"license":                 "Apache-2.0",
			"paid_serving_attested":   true,
			"pricing": map[string]any{
				"prompt_rate_per_mtok":           2000000,
				"prompt_cache_hit_rate_per_mtok": 200000,
				"completion_rate_per_mtok":       4000000,
			},
			"disclosure_class":   "pool_attested_unverified",
			"max_context_tokens": 8192,
		}},
		"attested_members": []any{},
	})
	notBefore := time.Now().UTC().Add(-time.Minute).Truncate(time.Second)
	manifestEvent := filepath.Join(t.TempDir(), "manifest.json")
	runTrustPoolCLI(t, nil, "sign-manifest", "--identity", filepath.Join(keysDir, "pool-identity.json"),
		"--root-issuer-key", filepath.Join(keysDir, "root-issuer-key.pem"), "--root-issuer-key-id", "journey-root-1",
		"--manifest-authority-key", filepath.Join(keysDir, "manifest-authority-key.pem"),
		"--policy-signer-key", filepath.Join(keysDir, "policy-signer-key.pem"),
		"--operation-id", "journey-manifest-1", "--encoding", "2", "--signer-set-version", "1",
		"--settlement-mode", "enforce", "--runtime-allowlist", "llamacpp_loopback", "--pool-models", poolModels,
		"--models", "journey-unused-model", "--min-binary-version", "1.0.0", "--min-attestation-tier", "self_signed",
		"--retention-policy-id", "standard", "--min-eligible-members", "1",
		"--not-before", notBefore.Format(time.RFC3339), "--expires-at", notBefore.Add(24*time.Hour).Format(time.RFC3339),
		"--out", manifestEvent)
	runTrustPoolCLI(t, env, "submit-policy", "--operation-id", "journey-manifest-1", "--input", manifestEvent)
	runTrustPoolCLI(t, env, "admit-provider", "--operation-id", "journey-admit-1", "--pool-id", poolID, "--provider-id", providerID)
	runTrustPoolCLI(t, env, "authorize-buyer", "--operation-id", "journey-buyer-1", "--pool-id", poolID, "--buyer-account-id", s.accountID)
	runTrustPoolCLI(t, env, "promote", "--operation-id", "journey-promote-1", "--pool-id", poolID, "--reason", "integration_journey")

	// One trusted-pool refresh so the member and entry are routeable before
	// the provider's hello.
	time.Sleep(2 * time.Second)
}

func runTrustPoolCLI(t *testing.T, env map[string]string, args ...string) string {
	t.Helper()
	cmd := exec.Command(coordinatorCLIBin, append([]string{"trust-pool-admin"}, args...)...)
	cmd.Env = os.Environ()
	for k, v := range env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("coordinator-cli trust-pool-admin %s: %v\nstdout=%s\nstderr=%s", args[0], err, stdout.String(), stderr.String())
	}
	return stdout.String()
}

func cliOutputField(t *testing.T, out, key string) string {
	t.Helper()
	for _, line := range strings.Split(out, "\n") {
		if v, ok := strings.CutPrefix(line, key+"="); ok {
			return strings.TrimSpace(v)
		}
	}
	t.Fatalf("output has no %s= line:\n%s", key, out)
	return ""
}

func decodeCLIJSON(t *testing.T, out string, v any) {
	t.Helper()
	start := strings.Index(out, "{")
	if start < 0 || json.Unmarshal([]byte(out[start:]), v) != nil {
		t.Fatalf("cli output is not JSON: %s", out)
	}
}

func writeJSONFile(t *testing.T, name string, v any) string {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return writeFile(t, name, string(raw))
}

func writeFile(t *testing.T, name, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func sha256HexString(v string) string {
	sum := sha256.Sum256([]byte(v))
	return hex.EncodeToString(sum[:])
}

// submitModelAdmissionOffer posts a provider-signed SPEC-047 offer for a
// single GGUF pair and returns the status readback.
func submitModelAdmissionOffer(t *testing.T, coordProvURL, providerToken, providerID string, priv ed25519.PrivateKey, ggufHash string) map[string]any {
	t.Helper()
	pub := priv.Public().(ed25519.PublicKey)
	keyDigest := sha256.Sum256(pub)
	payload := map[string]any{
		"signature_domain":           "macprovider.model_admission.offer.v1",
		"provider_id":                providerID,
		"candidate_id":               "byom_" + strings.Repeat("q", 52),
		"runtime_source":             "llamacpp_loopback",
		"served_model_ref":           "creator-gguf-model",
		"catalog_model_key":          "",
		"discovery_digest_sha256":    sha256HexString("discovery"),
		"evaluation_digest_sha256":   sha256HexString("evaluation"),
		"artifact_hashes":            map[string]any{"macprovider.gguf-file.v1": ggufHash},
		"advisory_capabilities":      map[string]any{"chat_completions": true, "streaming": true, "tool_call_passthrough": nil, "structured_output_passthrough": nil, "json_mode": nil, "usage_reporting": true, "max_context_tokens": 8192, "quantization": nil, "family": nil, "runtime_version": nil},
		"fit_evidence_source":        "local_probe",
		"local_readiness":            "ready",
		"requested_disclosure_class": "non_earning_provider_asserted",
		"timestamp":                  time.Now().UTC().Format(time.RFC3339Nano),
		"nonce":                      "journey_nonce_" + randHex(t, 8),
		"idempotency_key":            "journey_offer_" + randHex(t, 8),
		"signing_key_digest":         hex.EncodeToString(keyDigest[:]),
		"cli_version":                "1.9.0",
	}
	canonical, err := spec015CanonicalJSON(payload)
	if err != nil {
		t.Fatalf("canonical offer: %v", err)
	}
	request := map[string]any{}
	for k, v := range payload {
		request[k] = v
	}
	request["schema"] = "model_admission_offer_submit.v1"
	request["signature_algorithm"] = "ed25519"
	request["provider_signature"] = base64.StdEncoding.EncodeToString(ed25519.Sign(priv, canonical))
	raw, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, coordProvURL+"/v1/provider/model-admission/offers", bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+providerToken)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("offer: %v", err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("offer status=%d body=%s", resp.StatusCode, respBody)
	}
	var status map[string]any
	if err := json.Unmarshal(respBody, &status); err != nil {
		t.Fatalf("offer status json: %v", err)
	}
	return status
}
