package integration

import (
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// blockedArtifactModelKey is the candidate row the lab release blocks: not
// the llama row the settlement fixture's catalog provider serves.
const blockedArtifactModelKey = "google-gemma-4-26b-a4b-it"

// writeLabSignedRelease writes the committed static release re-signed with a
// per-test key (never an operator key) into dir, with the artifact feed.
// With blockedHash set, blockedArtifactModelKey's row is `blocked` and its
// artifact-feed model also lists a GGUF artifact with that hash, the
// candidate-catalog binding updated to match (#1816 VM acceptance GAP D4).
func writeLabSignedRelease(t *testing.T, keys pricingKeyring, dir, blockedHash string) {
	t.Helper()
	repoRoot, err := findRepoRoot()
	if err != nil {
		t.Fatal(err)
	}
	read := func(name string) []byte {
		raw, err := os.ReadFile(filepath.Join(repoRoot, "phase3-binary", "dist", "static", name))
		if err != nil {
			t.Fatalf("read static %s: %v", name, err)
		}
		return raw
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	candidates, artifacts := read("autotune-candidates.json"), read("autotune-artifacts.json")
	if blockedHash != "" {
		var cat map[string]any
		if err := json.Unmarshal(candidates, &cat); err != nil {
			t.Fatal(err)
		}
		cat["rows"].(map[string]any)[blockedArtifactModelKey].(map[string]any)["runtime_status"] = "blocked"
		if candidates, err = json.MarshalIndent(cat, "", "  "); err != nil {
			t.Fatal(err)
		}
		var feed map[string]any
		if err := json.Unmarshal(artifacts, &feed); err != nil {
			t.Fatal(err)
		}
		feed["candidate_catalog_sha256"] = sha256HexBytes(candidates)
		model := feed["models"].(map[string]any)[blockedArtifactModelKey].(map[string]any)
		model["artifacts"].(map[string]any)["gguf-lab-blocked"] = map[string]any{
			"allowed_runtime_sources": []string{"llamacpp_loopback"},
			"hash":                    blockedHash,
			"hash_algorithm":          "macprovider.gguf-file.v1",
			"min_ram_gb":              4,
			"notes":                   "Lab-signed blocked identity (#1816 GAP D4).",
			"quantization":            "q4_k_m",
			"runtime_format":          "gguf",
			"size_bytes":              1024,
			"source_ref":              map[string]any{"kind": "huggingface_revision", "repo_id": "lab/blocked-GGUF", "revision": strings.Repeat("ab", 20), "file_path": "blocked-Q4_K_M.gguf"},
			"verification_status":     "verified",
			"verified_at":             "2026-10-01",
		}
		if artifacts, err = json.MarshalIndent(feed, "", "  "); err != nil {
			t.Fatal(err)
		}
	}
	keys.writeSignedAtomic(t, filepath.Join(dir, "autotune-candidates.json"), candidates)
	keys.writeSignedAtomic(t, filepath.Join(dir, "autotune-artifacts.json"), artifacts)
	for _, name := range []string{"demand-rank.json", "rate-card.json"} {
		keys.writeSignedAtomic(t, filepath.Join(dir, name), read(name))
	}
}

// #1816 VM acceptance GAP (D4, blocked artifact identity): a lab-signed
// catalog release whose blocked row carries the pool entry's artifact
// revokes the existing pool binding (SPEC-042-R015 catalog precedence), and
// a core that still lists the entry is refused.
func TestTrustedPoolModelBlockedArtifactIdentity(t *testing.T) {
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
	keys := newPricingKeyring(t)
	var releaseDir string
	s := newScenario(t, scenarioOpts{
		seedAccount:               true,
		settlementReceiptProvider: true,
		settlementEnforceMode:     true,
		providerID:                providerID,
		captureCoordLogs:          true,
		coordinatorConfig: func(sc *scenario, cfg map[string]any) {
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
			// Release A: the committed release, re-signed by the test key.
			releaseDir = filepath.Join(sc.tempDir, "autotune-lab")
			writeLabSignedRelease(t, keys, releaseDir, "")
			autotune := cfg["autotune"].(map[string]any)
			for _, name := range []string{"rate_card", "demand_rank", "autotune_candidates"} {
				file := strings.ReplaceAll(name, "_", "-") + ".json"
				if name == "autotune_candidates" {
					file = "autotune-candidates.json"
				}
				autotune[name+"_path"] = filepath.Join(releaseDir, file)
				autotune[name+"_sig_path"] = filepath.Join(releaseDir, file+".sig")
			}
			autotune["catalog_artifacts_path"] = filepath.Join(releaseDir, "autotune-artifacts.json")
			autotune["catalog_artifacts_sig_path"] = filepath.Join(releaseDir, "autotune-artifacts.json.sig")
			autotune["public_keys"] = map[string]string{pricingTestKeyID: base64.StdEncoding.EncodeToString(keys.pub)}
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
	if status["admission_state"] != "catalog_priced" || status["pool_binding"] == nil {
		t.Fatalf("pool entry did not bind under release A: %v", status)
	}

	// Release B blocks a catalog row that carries the entry's artifact.
	writeLabSignedRelease(t, keys, releaseDir, ggufHash)
	mark := len(s.coordLogBuf.snapshot())
	if err := s.coordCmd.Process.Signal(syscall.SIGHUP); err != nil {
		t.Fatalf("SIGHUP: %v", err)
	}
	db, err := sql.Open("sqlite", "file:"+s.coordinatorDB+"?mode=ro&_pragma=busy_timeout(10000)")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	deadline := time.Now().Add(20 * time.Second)
	for {
		var state, reason string
		_ = db.QueryRow(`SELECT state, reason_code FROM model_admission_events WHERE provider_id = ? ORDER BY id DESC LIMIT 1`, providerID).Scan(&state, &reason)
		if state == "revoked" && reason == "pool_manifest_entry_revoked" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("blocked artifact did not revoke the pool binding: head %s/%s; coordinator log since SIGHUP:\n%s",
				state, reason, strings.Join(s.coordLogBuf.snapshot()[mark:], "\n"))
		}
		time.Sleep(250 * time.Millisecond)
	}

	// A core that still lists the blocked pair is refused.
	env := map[string]string{"MACPROVIDER_COORDINATOR_ADMIN_URL": s.coordProvURL, "MACPROVIDER_OPERATOR_KEY": s.operatorKey}
	notBefore := time.Now().UTC().Add(25 * time.Hour).Truncate(time.Second)
	poolModels := writeJSONFile(t, "pool-models-blocked.json", map[string]any{
		"model_entries": []any{map[string]any{
			"pool_model_id": poolModelID, "artifact_hash_algorithm": "macprovider.gguf-file.v1", "artifact_hash": ggufHash,
			"allowed_runtime_sources": []string{"llamacpp_loopback"}, "license": "Apache-2.0", "paid_serving_attested": true,
			"pricing":          map[string]any{"prompt_rate_per_mtok": 2000000, "prompt_cache_hit_rate_per_mtok": 200000, "completion_rate_per_mtok": 4000000},
			"disclosure_class": "pool_attested_unverified", "max_context_tokens": 8192,
		}},
		"attested_members": []any{},
	})
	next := filepath.Join(t.TempDir(), "manifest-blocked.json")
	runTrustPoolCLI(t, nil, "sign-manifest", "--identity", filepath.Join(keysDir, "pool-identity.json"),
		"--root-issuer-key", filepath.Join(keysDir, "root-issuer-key.pem"), "--root-issuer-key-id", "journey-root-1",
		"--policy-signer-key", filepath.Join(keysDir, "policy-signer-key.pem"), "--prev", filepath.Join(keysDir, "manifest-1.json"),
		"--operation-id", "journey-manifest-blocked", "--encoding", "2", "--signer-set-version", "1",
		"--settlement-mode", "enforce", "--runtime-allowlist", "llamacpp_loopback", "--pool-models", poolModels,
		"--models", "journey-unused-model", "--min-binary-version", "1.0.0", "--min-attestation-tier", "self_signed",
		"--retention-policy-id", "standard", "--min-eligible-members", "1",
		"--not-before", notBefore.Format(time.RFC3339), "--expires-at", notBefore.Add(24*time.Hour).Format(time.RFC3339),
		"--out", next)
	out, err := runTrustPoolCLIResult(env, "submit-policy", "--operation-id", "journey-manifest-blocked", "--input", next)
	if err == nil {
		t.Fatalf("a core listing a blocked catalog artifact was accepted:\n%s", out)
	}
	if !strings.Contains(out, "catalog") {
		t.Fatalf("blocked-entry refusal does not name the catalog overlap:\n%s", out)
	}
}
