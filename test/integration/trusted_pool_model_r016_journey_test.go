package integration

import (
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"net/http"
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

func runR016PoolModelJourney(t *testing.T, attested bool) {
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
	member := poolModelJourneyMember{ownerKey: ownerPriv}
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
					"max_prompt_rate_per_mtok":           100000000,
					"min_prompt_cache_hit_rate_per_mtok": 0,
					"max_prompt_cache_hit_rate_per_mtok": 100000000,
					"min_completion_rate_per_mtok":       1,
					"max_completion_rate_per_mtok":       100000000,
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
	const environment = "candidate"
	issuedAt := time.Now().UTC().Add(-time.Minute).Truncate(time.Second)
	fields := map[string]any{
		"schema_version":             "provider-pool-delegation-v1",
		"creator_account_id":         creator,
		"pool_id":                    poolID,
		"provider_identity":          providerID,
		"delegation_id":              "journey-delegation-1",
		"operation_id":               "journey-delegation-op-1",
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
		"operation_id":                       "journey-delegation-grant-1",
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
	runTrustPoolCLI(t, env, "append-event", "--operation-id", "journey-delegation-grant-1", "--input", writeJSONFile(t, "grant.json", grant))
	admit := map[string]any{
		"operation_id":  "journey-admit-delegated-1",
		"timestamp_utc": time.Now().UTC().Format(time.RFC3339Nano),
		"event_type":    "member_admitted",
		"pool_id":       poolID,
		"provider_id":   providerID,
		"delegation_id": fields["delegation_id"],
	}
	runTrustPoolCLI(t, env, "append-event", "--operation-id", "journey-admit-delegated-1", "--input", writeJSONFile(t, "admit.json", admit))
}
