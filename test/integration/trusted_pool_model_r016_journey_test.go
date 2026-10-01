package integration

import (
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// poolModelJourneyMember makes the journey member a non-creator provider:
// admitted through a provider-owner-signed ProviderPoolDelegationV1 grant
// (ownerKey) and, when attestedAccount is set, named by the creator's
// SPEC-042-R016 pool_attested_members/v1 attestation.
type poolModelJourneyMember struct {
	ownerKey        ed25519.PrivateKey
	attestedAccount string
	// genesisWindow, when set, ends the genesis core's window that long
	// after setup so a test can activate a next core.
	genesisWindow time.Duration
}

// #1816 (SPEC-042-R016, SPEC-042-R006 condition 4, SPEC-022-R012): a
// non-creator member, admitted through a signed delegation, serves the pool
// entry under pool_operator_attested only when the creator's signed core
// attests its owner account for the runtime class. Without the attestation it
// is never bound, selected, or paid; with it the attempt is credited
// pool_operator_attested and the route snapshot binds the member account.
func TestTrustedPoolModelR016NonCreatorMember(t *testing.T) {
	for name, attested := range map[string]bool{"without attestation": false, "with attestation": true} {
		t.Run(name, func(t *testing.T) {
			runR016PoolModelJourney(t, attested)
		})
	}
}

// r016Journey is one started non-creator member journey (see
// startR016PoolModelJourney).
type r016Journey struct {
	s                                        *scenario
	keysDir, poolID, providerID, poolModelID string
	ggufHash, creator, memberAccount         string
	admissionPriv, ownerPriv                 ed25519.PrivateKey
}

func startR016PoolModelJourney(t *testing.T, attested bool, genesisWindow time.Duration) r016Journey {
	requireBins(t)
	keysDir := filepath.Join(t.TempDir(), "pool-keys")
	keygenOut := runTrustPoolCLI(t, nil, "keygen", "--out-dir", keysDir,
		"--manifest-authority-key-id", "journey-manifest-authority-1",
		"--policy-signer-key-id", "journey-policy-signer-1")
	poolID := cliOutputField(t, keygenOut, "pool_id")
	providerID := "prov-member-" + randHex(t, 4)
	creator := "acct_creator_1816"
	memberAccount := "acct_member_1816"
	poolModelID := "pool/" + poolID + "/creator-gguf"
	ggufHash := randHex(t, 32)
	_, admissionPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	_, ownerPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	member := poolModelJourneyMember{ownerKey: ownerPriv, genesisWindow: genesisWindow}
	if attested {
		member.attestedAccount = memberAccount
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
				// The member's provider-owner key verifies its delegation, and
				// its SPEC-003 owner account is the R016 match input.
				"provider_owner_public_keys": map[string]string{providerID: base64.StdEncoding.EncodeToString(ownerPriv.Public().(ed25519.PublicKey))},
				"provider_owner_account_ids": map[string][]string{memberAccount: {providerID}},
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
			setUpPoolModelJourneyPool(t, sc, keysDir, poolID, providerID, creator, poolModelID, ggufHash, member)
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

	return r016Journey{s: s, keysDir: keysDir, poolID: poolID, providerID: providerID, poolModelID: poolModelID,
		ggufHash: ggufHash, creator: creator, memberAccount: memberAccount, admissionPriv: admissionPriv, ownerPriv: ownerPriv}
}

func runR016PoolModelJourney(t *testing.T, attested bool) {
	j := startR016PoolModelJourney(t, attested, 0)
	s, poolID, providerID, poolModelID, ggufHash := j.s, j.poolID, j.providerID, j.poolModelID, j.ggufHash
	creator, memberAccount, admissionPriv := j.creator, j.memberAccount, j.admissionPriv
	status := submitModelAdmissionOffer(t, s.coordProvURL, s.providerToken, providerID, admissionPriv, ggufHash)
	binding, _ := status["pool_binding"].(map[string]any)
	body := `{"model":"` + poolModelID + `","messages":[{"role":"user","content":"hello pool member"}]}`
	code, _, raw := s.chatRequest(map[string]string{
		"Authorization":             "Bearer " + s.apiKey,
		"X-MacProvider-Pool-Select": poolID,
	}, body)
	db, err := sql.Open("sqlite", s.coordinatorDB+"?mode=ro")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	if !attested {
		// Not bound, not selected, never credited pool_operator_attested.
		if status["admission_state"] == "catalog_priced" || binding != nil {
			t.Fatalf("unattested non-creator member bound to the pool: %v", status)
		}
		if code == http.StatusOK {
			t.Fatalf("unattested non-creator member served the pool model: %s", raw)
		}
		var paid int
		if err := db.QueryRow(`SELECT COUNT(*) FROM ledger_request_credits lrc
  LEFT JOIN settlement_attempt_outputs sao
    ON sao.request_id = lrc.request_id AND sao.attempt_n = lrc.attempt_n AND sao.provider_id = lrc.provider_id
 WHERE lrc.provider_id = ? AND (lrc.provider_credits > 0 OR sao.usage_source = 'pool_operator_attested')`, providerID).Scan(&paid); err != nil {
			t.Fatal(err)
		}
		if paid != 0 {
			t.Fatalf("unattested non-creator member has %d paid or attested ledger rows", paid)
		}
		return
	}

	if status["admission_state"] != "catalog_priced" || binding == nil || binding["provider_account_id"] != memberAccount {
		t.Fatalf("attested member offer status = %v", status)
	}
	if code != http.StatusOK {
		t.Fatalf("attested member pool-model request status=%d body=%s", code, raw)
	}
	var snapshotJSON string
	if err := db.QueryRow(`SELECT route_snapshot_json FROM settlement_route_snapshots WHERE pool_id = ? ORDER BY id DESC LIMIT 1`, poolID).Scan(&snapshotJSON); err != nil {
		t.Fatalf("pool route snapshot: %v", err)
	}
	var snapshot map[string]any
	if err := json.Unmarshal([]byte(snapshotJSON), &snapshot); err != nil {
		t.Fatal(err)
	}
	if snapshot["pool_member_account_id"] != memberAccount || snapshot["pool_operator_account_id"] != creator ||
		snapshot["expected_model_hash_source"] != "pool_manifest" {
		t.Fatalf("attested member route snapshot = %v", snapshot)
	}
	deadline := time.Now().Add(20 * time.Second)
	for {
		var usageSource string
		var gross, provider, quarantined int64
		err := db.QueryRow(`SELECT sao.usage_source, lrc.gross_credits, lrc.provider_credits, lrc.quarantined
  FROM ledger_request_credits lrc JOIN settlement_attempt_outputs sao
    ON sao.request_id = lrc.request_id AND sao.attempt_n = lrc.attempt_n AND sao.provider_id = lrc.provider_id
 WHERE lrc.provider_id = ? ORDER BY lrc.id DESC LIMIT 1`, providerID).Scan(&usageSource, &gross, &provider, &quarantined)
		if err == nil && usageSource == "pool_operator_attested" && quarantined == 0 && gross > 0 && provider > 0 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("attested member credit: err=%v usage=%q gross=%d provider=%d quarantined=%d", err, usageSource, gross, provider, quarantined)
		}
		time.Sleep(200 * time.Millisecond)
	}
}

// admitDelegatedPoolMember appends a provider-owner-signed
// ProviderPoolDelegationV1 grant and the delegated member_admitted through
// the operator admin surface.
func admitDelegatedPoolMember(t *testing.T, env map[string]string, ownerKey ed25519.PrivateKey, poolID, creator, providerID, manifestDigest string) {
	t.Helper()
	admitDelegatedPoolMemberAs(t, env, ownerKey, poolID, creator, providerID, manifestDigest, "1")
}

// admitDelegatedPoolMemberAs is admitDelegatedPoolMember with delegation n
// (distinct delegation and operation ids).
func admitDelegatedPoolMemberAs(t *testing.T, env map[string]string, ownerKey ed25519.PrivateKey, poolID, creator, providerID, manifestDigest, n string) {
	t.Helper()
	const environment = "candidate"
	issuedAt := time.Now().UTC().Add(-time.Minute).Truncate(time.Second)
	fields := map[string]any{
		"schema_version":             "provider-pool-delegation-v1",
		"creator_account_id":         creator,
		"pool_id":                    poolID,
		"provider_identity":          providerID,
		"delegation_id":              "journey-delegation-" + n,
		"operation_id":               "journey-delegation-op-" + n,
		"manifest_core_digest":       manifestDigest,
		"environment_network_id":     environment,
		"coordinator_audience":       "macprovider/spec043/coordinator-audience/v1/" + environment,
		"provider_owner_key_id":      "journey-owner-key-1",
		"provider_owner_key_version": "1",
		"provider_owner_public_key":  base64.StdEncoding.EncodeToString(ownerKey.Public().(ed25519.PublicKey)),
		"issued_at":                  issuedAt.Format(time.RFC3339),
		"expires_at":                 issuedAt.Add(24 * time.Hour).Format(time.RFC3339),
		"revocation_semantics":       "owner_revocable",
	}
	canonical, err := spec015CanonicalJSON(fields)
	if err != nil {
		t.Fatalf("canonical delegation: %v", err)
	}
	msg := append([]byte("macprovider/spec043/provider-pool-delegation-sig/v1"), canonical...)
	grant := map[string]any{
		"operation_id":                       "journey-delegation-grant-" + n,
		"timestamp_utc":                      time.Now().UTC().Format(time.RFC3339Nano),
		"event_type":                         "delegation_granted",
		"pool_id":                            poolID,
		"creator_account_id":                 creator,
		"provider_id":                        providerID,
		"delegation_id":                      fields["delegation_id"],
		"delegation_operation_id":            fields["operation_id"],
		"manifest_core_digest":               manifestDigest,
		"environment_network_id":             environment,
		"coordinator_audience":               fields["coordinator_audience"],
		"provider_owner_key_id":              fields["provider_owner_key_id"],
		"provider_owner_key_version":         fields["provider_owner_key_version"],
		"provider_owner_public_key":          fields["provider_owner_public_key"],
		"delegation_issued_at":               fields["issued_at"],
		"delegation_expires_at":              fields["expires_at"],
		"provider_pool_delegation_signature": base64.StdEncoding.EncodeToString(ed25519.Sign(ownerKey, msg)),
	}
	runTrustPoolCLI(t, env, "append-event", "--operation-id", "journey-delegation-grant-"+n, "--input", writeJSONFile(t, "grant.json", grant))
	admit := map[string]any{
		"operation_id":  "journey-admit-delegated-" + n,
		"timestamp_utc": time.Now().UTC().Format(time.RFC3339Nano),
		"event_type":    "member_admitted",
		"pool_id":       poolID,
		"provider_id":   providerID,
		"delegation_id": fields["delegation_id"],
	}
	runTrustPoolCLI(t, env, "append-event", "--operation-id", "journey-admit-delegated-"+n, "--input", writeJSONFile(t, "admit.json", admit))
}

// #1816 VM acceptance A-5: a non-creator member whose owner account is
// attested only by a LATER core binds when that core activates, without a
// new offer: the binding sweep re-evaluates the unbound offer. Re-submitting
// the identical offer is idempotent (the current status, not 409).
func TestTrustedPoolModelR016AttestationInLaterCore(t *testing.T) {
	const genesisWindow = 12 * time.Second
	j := startR016PoolModelJourney(t, false, genesisWindow)
	s := j.s
	status := submitModelAdmissionOffer(t, s.coordProvURL, s.providerToken, j.providerID, j.admissionPriv, j.ggufHash)
	if status["admission_state"] == "catalog_priced" || status["pool_binding"] != nil {
		t.Fatalf("unattested member bound before the attesting core: %v", status)
	}

	// The next core adds the attestation; its window starts when the
	// genesis window ends.
	env := map[string]string{"MACPROVIDER_COORDINATOR_ADMIN_URL": s.coordProvURL, "MACPROVIDER_OPERATOR_KEY": s.operatorKey}
	notBefore := time.Now().UTC().Add(genesisWindow).Truncate(time.Second)
	poolModels := writeJSONFile(t, "pool-models-v2.json", map[string]any{
		"model_entries": []any{map[string]any{
			"pool_model_id":           j.poolModelID,
			"artifact_hash_algorithm": "macprovider.gguf-file.v1",
			"artifact_hash":           j.ggufHash,
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
		"attested_members": []any{map[string]any{"provider_account_id": j.memberAccount, "runtime_classes": []string{"llamacpp_loopback"}}},
	})
	next := filepath.Join(t.TempDir(), "manifest-2.json")
	var lastErr string
	for attempt := 0; ; attempt++ {
		// The genesis window end is truncated to the second at setup; step
		// forward until the signer accepts the boundary.
		out, err := runTrustPoolCLIResult(nil, "sign-manifest", "--identity", filepath.Join(j.keysDir, "pool-identity.json"),
			"--root-issuer-key", filepath.Join(j.keysDir, "root-issuer-key.pem"), "--root-issuer-key-id", "journey-root-1",
			"--policy-signer-key", filepath.Join(j.keysDir, "policy-signer-key.pem"), "--prev", filepath.Join(j.keysDir, "manifest-1.json"),
			"--operation-id", "journey-manifest-2", "--encoding", "2", "--signer-set-version", "1",
			"--settlement-mode", "enforce", "--runtime-allowlist", "llamacpp_loopback", "--pool-models", poolModels,
			"--models", "journey-unused-model", "--min-binary-version", "1.0.0", "--min-attestation-tier", "self_signed",
			"--retention-policy-id", "standard", "--min-eligible-members", "1",
			"--not-before", notBefore.Format(time.RFC3339), "--expires-at", notBefore.Add(24*time.Hour).Format(time.RFC3339),
			"--out", next)
		if err == nil {
			break
		}
		lastErr = out
		if attempt > 5 {
			t.Fatalf("sign the attesting core: %v\n%s", err, lastErr)
		}
		notBefore = notBefore.Add(time.Second)
	}
	runTrustPoolCLI(t, env, "submit-policy", "--operation-id", "journey-manifest-2", "--input", next)
	var v2 struct {
		ManifestCoreDigest string `json:"manifest_core_digest"`
	}
	if raw, err := os.ReadFile(next); err != nil || json.Unmarshal(raw, &v2) != nil {
		t.Fatalf("read the attesting core: %v", err)
	}
	var v1 struct {
		ManifestCoreDigest string `json:"manifest_core_digest"`
	}
	if raw, err := os.ReadFile(filepath.Join(j.keysDir, "manifest-1.json")); err != nil || json.Unmarshal(raw, &v1) != nil {
		t.Fatalf("read the genesis core: %v", err)
	}
	// SPEC-043-R006: a delegation is bound to the active core digest, so the
	// delegated member is a member under the attesting core only once its
	// owner re-delegates for it (runbook section 4).
	time.Sleep(time.Until(notBefore.Add(2 * time.Second)))
	revokeDelegatedPoolMember(t, env, j.ownerPriv, j.poolID, j.creator, j.providerID, v1.ManifestCoreDigest, "1")
	admitDelegatedPoolMemberAs(t, env, j.ownerPriv, j.poolID, j.creator, j.providerID, v2.ManifestCoreDigest, "2")
	redelegated := time.Now()

	db, err := sql.Open("sqlite", "file:"+s.coordinatorDB+"?mode=ro&_pragma=busy_timeout(10000)")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	bound := func() (string, string) {
		var state, reason string
		_ = db.QueryRow(`SELECT state, reason_code FROM model_admission_events WHERE provider_id = ? ORDER BY id DESC LIMIT 1`, j.providerID).Scan(&state, &reason)
		return state, reason
	}
	// A registry refresh (1 s) and a sweep tick (2 s), with slack.
	deadline := redelegated.Add(10 * time.Second)
	for {
		state, reason := bound()
		if state == "catalog_priced" && reason == "pool_manifest_bound" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("member attested by a later core never bound: head %s/%s %s after its re-delegation", state, reason, time.Since(redelegated).Round(time.Second))
		}
		time.Sleep(250 * time.Millisecond)
	}

	// The identical offer again: the current status, not replay_conflict.
	again := submitModelAdmissionOffer(t, s.coordProvURL, s.providerToken, j.providerID, j.admissionPriv, j.ggufHash)
	binding, _ := again["pool_binding"].(map[string]any)
	if again["admission_state"] != "catalog_priced" || binding == nil || binding["provider_account_id"] != j.memberAccount {
		t.Fatalf("re-offer after binding = %v", again)
	}
}

// runTrustPoolCLIResult runs coordinator-cli trust-pool-admin and returns
// its combined output and error instead of failing the test.
func runTrustPoolCLIResult(env map[string]string, args ...string) (string, error) {
	cmd := exec.Command(coordinatorCLIBin, append([]string{"trust-pool-admin"}, args...)...)
	cmd.Env = os.Environ()
	for k, v := range env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// revokeDelegatedPoolMember appends the provider owner's signed revocation of
// delegation n (bound to manifestDigest).
func revokeDelegatedPoolMember(t *testing.T, env map[string]string, ownerKey ed25519.PrivateKey, poolID, creator, providerID, manifestDigest, n string) {
	t.Helper()
	const environment = "candidate"
	fields := map[string]any{
		"schema_version":             "provider-pool-delegation-revocation-v1",
		"creator_account_id":         creator,
		"pool_id":                    poolID,
		"provider_identity":          providerID,
		"delegation_id":              "journey-delegation-" + n,
		"operation_id":               "journey-delegation-revoke-op-" + n,
		"manifest_core_digest":       manifestDigest,
		"environment_network_id":     environment,
		"coordinator_audience":       "macprovider/spec043/coordinator-audience/v1/" + environment,
		"provider_owner_key_id":      "journey-owner-key-1",
		"provider_owner_key_version": "1",
		"revoked_at":                 time.Now().UTC().Truncate(time.Second).Format(time.RFC3339),
		"revocation_semantics":       "owner_revocable",
	}
	canonical, err := spec015CanonicalJSON(fields)
	if err != nil {
		t.Fatalf("canonical revocation: %v", err)
	}
	msg := append([]byte("macprovider/spec043/provider-pool-delegation-revocation-sig/v1"), canonical...)
	revoke := map[string]any{
		"operation_id":               "journey-delegation-revoke-" + n,
		"timestamp_utc":              time.Now().UTC().Format(time.RFC3339Nano),
		"event_type":                 "delegation_revoked",
		"pool_id":                    poolID,
		"creator_account_id":         creator,
		"provider_id":                providerID,
		"delegation_id":              fields["delegation_id"],
		"delegation_operation_id":    fields["operation_id"],
		"manifest_core_digest":       manifestDigest,
		"environment_network_id":     environment,
		"coordinator_audience":       fields["coordinator_audience"],
		"provider_owner_key_id":      fields["provider_owner_key_id"],
		"provider_owner_key_version": fields["provider_owner_key_version"],
		"delegation_revoked_at":      fields["revoked_at"],
		"provider_pool_delegation_revocation_signature": base64.StdEncoding.EncodeToString(ed25519.Sign(ownerKey, msg)),
	}
	runTrustPoolCLI(t, env, "append-event", "--operation-id", "journey-delegation-revoke-"+n, "--input", writeJSONFile(t, "revoke.json", revoke))
}
