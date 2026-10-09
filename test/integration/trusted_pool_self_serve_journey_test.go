package integration

import (
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

// SPEC-043 0.3.0 (#1880): an outside creator self-serves a private Trusted
// Pool end to end through the public gateway with its own account API key.
// Agreement, pool creation, root registration, the signed model manifest,
// admission of its own claimed Mac, the buyer grant, promotion, a paid pool
// request, and the earnings read all happen with ZERO operator calls: the
// operator key is never sent, coordinator-cli runs only its offline signing
// subcommands, and the gateway has no static account_pools mapping.
func TestTrustedPoolSelfServeCreatorJourney(t *testing.T) {
	requireBins(t)
	keysDir := filepath.Join(t.TempDir(), "creator-keys")
	keygenOut := runOfflineCreatorSigner(t, "keygen", "--out-dir", keysDir,
		"--manifest-authority-key-id", "selfserve-manifest-authority-1",
		"--policy-signer-key-id", "selfserve-policy-signer-1")
	poolID := cliOutputField(t, keygenOut, "pool_id")
	providerID := "prov-selfserve-" + randHex(t, 4)
	creatorAccount := "acct_selfserve_" + randHex(t, 4)
	const creatorGitHubID = 88001
	poolModelID := "pool/" + poolID + "/creator-gguf"
	ggufHash := randHex(t, 32)
	var creatorKey string

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
					"max_prompt_rate_per_mtok":           8000000,
					"min_prompt_cache_hit_rate_per_mtok": 0,
					"max_prompt_cache_hit_rate_per_mtok": 8000000,
					"min_completion_rate_per_mtok":       1,
					"max_completion_rate_per_mtok":       8000000,
				},
			}
		},
		gatewayConfig: func(_ *scenario, cfg map[string]any) {
			features := cfg["features"].(map[string]any)
			// No static account_pools: the buyer grant comes only from the
			// creator's own durable authorization.
			features["trusted_pools"] = map[string]any{"enabled": true, "coordinator_authorizes": true}
		},
		beforeProviders: func(sc *scenario) {
			// The creator's own account sign-up (GitHub OAuth) and its own
			// `macprovider-cli claim` of its Mac, recorded as those flows
			// write them. Neither is an operator action.
			creatorKey = seedSelfServeCreatorAccount(t, sc, creatorAccount, creatorGitHubID)
			seedProviderOwnershipClaim(t, sc, providerID, creatorGitHubID)
		},
		providerSetup: func(fp *fakeProvider) {
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
	creator := func(method, path string, body any, idempotencyKey string, want int) map[string]any {
		t.Helper()
		raw := ""
		if body != nil {
			encoded, err := json.Marshal(body)
			if err != nil {
				t.Fatal(err)
			}
			raw = string(encoded)
		}
		headers := map[string]string{"Authorization": "Bearer " + creatorKey}
		if idempotencyKey != "" {
			headers["Idempotency-Key"] = idempotencyKey
		}
		code, _, respBody := s.jsonRequest(method, "/v1/creator/"+path, headers, raw)
		if code != want {
			t.Fatalf("%s /v1/creator/%s status=%d body=%s, want %d", method, path, code, respBody, want)
		}
		var decoded map[string]any
		if err := json.Unmarshal(respBody, &decoded); err != nil {
			t.Fatalf("%s /v1/creator/%s json: %v (%s)", method, path, err, respBody)
		}
		return decoded
	}

	// 1. Click-through Creator Agreement.
	terms := creator(http.MethodGet, "agreement", nil, "", http.StatusOK)["agreement"].(map[string]any)
	approval := creator(http.MethodPost, "agreement", map[string]any{
		"creator_agreement_version":       terms["creator_agreement_version"],
		"accept":                          true,
		"public_display_name":             "Self-serve journey pool",
		"legal_support_contact":           "legal@example.test",
		"billing_contact":                 "billing@example.test",
		"emergency_notification_endpoint": "https://example.test/emergency",
	}, "", http.StatusAccepted)["creator"].(map[string]any)
	if approval["approved_by"] != "self_serve" || approval["allowed_launch_environment"] != "self_serve_private" || approval["creator_account_id"] != creatorAccount {
		t.Fatalf("self-serve approval = %v", approval)
	}
	approvalID := approval["approval_record_id"].(string)
	approvalVersion := approval["current_approval_version"].(string)

	// 2. The creator signs its genesis manifest offline on its own Mac.
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
	manifestEvent := filepath.Join(keysDir, "manifest-1.json")
	runOfflineCreatorSigner(t, "sign-manifest", "--identity", filepath.Join(keysDir, "pool-identity.json"),
		"--root-issuer-key", filepath.Join(keysDir, "root-issuer-key.pem"), "--root-issuer-key-id", "selfserve-root-1",
		"--manifest-authority-key", filepath.Join(keysDir, "manifest-authority-key.pem"),
		"--policy-signer-key", filepath.Join(keysDir, "policy-signer-key.pem"),
		"--operation-id", "selfserve-manifest-1", "--encoding", "2", "--signer-set-version", "1",
		"--settlement-mode", "enforce", "--runtime-allowlist", "llamacpp_loopback", "--pool-models", poolModels,
		"--models", "selfserve-unused-model", "--min-binary-version", "1.0.0", "--min-attestation-tier", "self_signed",
		"--retention-policy-id", "standard", "--min-eligible-members", "1",
		"--not-before", notBefore.Format(time.RFC3339), "--expires-at", notBefore.Add(24*time.Hour).Format(time.RFC3339),
		"--out", manifestEvent)
	manifest := readJSONMap(t, manifestEvent)

	// 3. Pool creation, nonce, signed root registration, manifest.
	creator(http.MethodPost, "events", map[string]any{
		"event_type":         "pool_created",
		"pool_id":            poolID,
		"approval_record_id": approvalID,
		"manifest_snapshot":  manifest["manifest_snapshot"],
	}, "selfserve-create-1", http.StatusAccepted)
	nonce := creator(http.MethodPost, "root-registration-nonces", map[string]any{}, "selfserve-nonce-1", http.StatusCreated)["root_registration_nonce"].(map[string]any)
	if nonce["launch_environment"] != "self_serve_private" {
		t.Fatalf("nonce = %v", nonce)
	}
	custody := writeFile(t, "custody.json", `{"class":"software","description":"self-serve journey, owner-only temp files"}`+"\n")
	rootEvent := filepath.Join(t.TempDir(), "root.json")
	runOfflineCreatorSigner(t, "sign-root", "--identity", filepath.Join(keysDir, "pool-identity.json"),
		"--root-issuer-key", filepath.Join(keysDir, "root-issuer-key.pem"), "--root-issuer-key-id", "selfserve-root-1",
		"--operation-id", "selfserve-root-1", "--creator-account-id", creatorAccount, "--approval-record-id", approvalID,
		"--approval-version", approvalVersion, "--launch-environment", "self_serve_private", "--custody-disclosure", custody,
		"--custody-class", "software", "--display-name", "Self-serve journey pool", "--nonce", nonce["nonce"].(string),
		"--nonce-expiry", nonce["expires_at_utc"].(string), "--out", rootEvent)
	creator(http.MethodPost, "events", readJSONMap(t, rootEvent), "selfserve-root-1", http.StatusAccepted)
	creator(http.MethodPost, "events", manifest, "selfserve-manifest-1", http.StatusAccepted)

	// 4. Admit the creator's own claimed Mac; another Mac is refused.
	owned := creator(http.MethodGet, "providers", nil, "", http.StatusOK)
	providers, _ := owned["providers"].([]any)
	if owned["github_identity_linked"] != true || len(providers) != 1 || providers[0].(map[string]any)["provider_id"] != providerID {
		t.Fatalf("owned providers = %v", owned)
	}
	creator(http.MethodPost, "events", map[string]any{"event_type": "member_admitted", "pool_id": poolID, "provider_id": "prov-not-mine"}, "selfserve-admit-other", http.StatusForbidden)
	creator(http.MethodPost, "events", map[string]any{"event_type": "member_admitted", "pool_id": poolID, "provider_id": providerID}, "selfserve-admit-1", http.StatusAccepted)

	// 5. Before the grant and promotion the buyer cannot select the pool.
	body := `{"model":"` + poolModelID + `","messages":[{"role":"user","content":"hello self-serve pool"}]}`
	if code, _, raw := s.chatRequest(map[string]string{"X-MacProvider-Pool-Select": poolID}, body); code == http.StatusOK {
		t.Fatalf("pool selectable before grant/promotion: %s", raw)
	}
	creator(http.MethodPost, "events", map[string]any{"event_type": "buyer_authorized", "pool_id": poolID, "buyer_account_id": s.accountID}, "selfserve-buyer-1", http.StatusAccepted)
	promoted := creator(http.MethodPost, "pools/"+poolID+"/promote", map[string]any{"reason": "self_serve_launch"}, "selfserve-promote-1", http.StatusAccepted)
	if pool, _ := promoted["pool"].(map[string]any); pool["lifecycle"] != "active" {
		t.Fatalf("promoted pool = %v", promoted)
	}
	time.Sleep(2 * time.Second)

	// 6. The creator restarts its provider so the new hello is admitted in
	// the pool-entry mode (an uncatalogued model is decided at hello), the
	// member offers the creator-signed model, and a buyer request is served
	// and credited on the pool route.
	s.fakeProv.reconnect()
	time.Sleep(time.Second)
	s.waitForProviderReady(providerID)
	status := submitModelAdmissionOffer(t, s.coordProvURL, s.providerToken, providerID, admissionPriv, ggufHash)
	if binding, _ := status["pool_binding"].(map[string]any); binding == nil || binding["pool_model_id"] != poolModelID {
		t.Fatalf("offer status = %v", status)
	}
	var code int
	var headers http.Header
	var raw []byte
	deadline := time.Now().Add(20 * time.Second)
	for {
		code, headers, raw = s.chatRequest(map[string]string{"X-MacProvider-Pool-Select": poolID}, body)
		if code == http.StatusOK || time.Now().After(deadline) {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if code != http.StatusOK || headers.Get("X-MacProvider-Model-Disclosure") != "pool_attested_unverified" {
		t.Fatalf("pool request status=%d headers=%v body=%s", code, headers, raw)
	}
	db, err := sql.Open("sqlite", s.coordinatorDB+"?mode=ro")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var credited int64
	for {
		var outcome sql.NullString
		err := db.QueryRow(`SELECT lrc.provider_credits, srv.settlement_outcome
  FROM ledger_request_credits lrc
  JOIN settlement_route_snapshots srs ON srs.request_id = lrc.request_id AND srs.attempt_n = lrc.attempt_n AND srs.provider_id = lrc.provider_id
  LEFT JOIN settlement_receipt_verdicts srv ON srv.request_id = lrc.request_id AND srv.attempt_n = lrc.attempt_n AND srv.provider_id = lrc.provider_id
 WHERE lrc.provider_id = ? AND srs.pool_id = ? AND lrc.quarantined = 0 ORDER BY lrc.id DESC LIMIT 1`, providerID, poolID).Scan(&credited, &outcome)
		if err == nil && credited > 0 && outcome.String == "verified" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("pool credit: err=%v credits=%d outcome=%q", err, credited, outcome.String)
		}
		time.Sleep(200 * time.Millisecond)
	}

	// 7. The creator reads its earnings through the gateway.
	var earnings map[string]any
	for {
		earnings = creator(http.MethodGet, "earnings?pool_id="+poolID, nil, "", http.StatusOK)["earnings"].(map[string]any)
		if total, _ := earnings["total_provider_credits"].(float64); total > 0 || time.Now().After(deadline) {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}
	if earnings["total_provider_credits"].(float64) != float64(credited) || earnings["split_execution_status"] != "declared_not_executed" ||
		earnings["owned_provider_count"].(float64) != 1 {
		t.Fatalf("creator earnings = %v, want %d payable provider credits", earnings, credited)
	}
	// Another gateway account cannot read this pool's earnings.
	stranger := s.apiKey
	code, _, raw = s.jsonRequest(http.MethodGet, "/v1/creator/earnings?pool_id="+poolID, map[string]string{"Authorization": "Bearer " + stranger}, "")
	if code != http.StatusNotFound {
		t.Fatalf("stranger earnings status=%d body=%s, want 404", code, raw)
	}
}

// runOfflineCreatorSigner runs only coordinator-cli's offline signing
// subcommands (no network, no operator credential), standing in for the
// creator's own `macprovider-cli creator` signer.
func runOfflineCreatorSigner(t *testing.T, args ...string) string {
	t.Helper()
	switch args[0] {
	case "keygen", "sign-root", "sign-manifest":
	default:
		t.Fatalf("%s is not an offline signing subcommand", args[0])
	}
	return runTrustPoolCLI(t, map[string]string{"MACPROVIDER_OPERATOR_KEY": "", "MACPROVIDER_COORDINATOR_ADMIN_URL": ""}, args...)
}

func readJSONMap(t *testing.T, path string) map[string]any {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("%s: %v", path, err)
	}
	return out
}

// seedSelfServeCreatorAccount writes the rows GitHub sign-up creates in the
// gateway DB: an account, its GitHub identity, and one API key.
func seedSelfServeCreatorAccount(t *testing.T, s *scenario, accountID string, githubUserID int) string {
	t.Helper()
	db, err := sql.Open("sqlite", s.gatewayDB)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err := db.Exec(`INSERT INTO accounts(account_id, status, quota_class, concurrency_class, created_at) VALUES(?, 'active', 'default', 'default', ?)`, accountID, now); err != nil {
		t.Fatalf("seed creator account: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO account_identities(account_id, provider, provider_user_id, email, created_at) VALUES(?, 'github', ?, '', ?)`, accountID, strconv.Itoa(githubUserID), now); err != nil {
		t.Fatalf("seed creator identity: %v", err)
	}
	rawKey := make([]byte, 32)
	if _, err := rand.Read(rawKey); err != nil {
		t.Fatal(err)
	}
	fullKey := "mp_" + base64.RawURLEncoding.EncodeToString(rawKey)
	mac := hmac.New(sha256.New, []byte(s.keyHashSecret))
	_, _ = mac.Write([]byte(fullKey))
	if _, err := db.Exec(`INSERT INTO api_keys(key_id, account_id, key_hash, key_hash_prefix, status, created_at) VALUES(?, ?, ?, ?, 'active', ?)`,
		"key_"+randHex(t, 16), accountID, mac.Sum(nil), fullKey[:12], now); err != nil {
		t.Fatalf("seed creator key: %v", err)
	}
	return fullKey
}

// seedProviderOwnershipClaim writes what `macprovider-cli claim` records
// when the creator links its Mac to its GitHub account.
func seedProviderOwnershipClaim(t *testing.T, s *scenario, providerID string, githubUserID int) {
	t.Helper()
	db, err := sql.Open("sqlite", s.coordinatorDB)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`INSERT INTO github_identities(github_user_id, github_login) VALUES(?, ?)`, githubUserID, "selfserve-creator"); err != nil {
		t.Fatalf("seed github identity: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO provider_ownership(provider_id, github_user_id) VALUES(?, ?)`, providerID, githubUserID); err != nil {
		t.Fatalf("seed provider ownership: %v", err)
	}
}
