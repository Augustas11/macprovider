package integration

// This companion is selected by the isolated parsed Swift command fixture. It
// consumes public signed inputs; it never constructs an offer or recommendation.
import (
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

var build1CLIManifest = flag.String("build1-cli-manifest", "", "private parsed-CLI fixture manifest")

type build1CLIRequest struct {
	Root               string `json:"root"`
	Inputs             string `json:"inputs"`
	ModelID            string `json:"model_id"`
	CatalogKey         string `json:"catalog_key"`
	ModelHash          string `json:"model_hash"`
	RowIdentity        string `json:"row_identity"`
	AdmissionPublicKey string `json:"admission_public_key"`
}

func TestBuild1CLIServiceBridge(t *testing.T) {
	if *build1CLIManifest == "" {
		t.Skip("companion selected by parsed CLI bootstrap fixture")
	}
	var request build1CLIRequest
	raw, err := os.ReadFile(*build1CLIManifest)
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(raw, &request); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(request.Root)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		t.Fatal("bridge requires private fixture root")
	}
	if filepath.Dir(*build1CLIManifest) != request.Root || filepath.Dir(request.Inputs) != request.Root {
		t.Fatal("bridge manifest is outside fixture root")
	}
	var catalog settlementCatalogFixture
	s := newScenario(t, scenarioOpts{build1ArtifactAdmission: true, externalWebSocketProvider: true, seedAccount: true,
		settlementReceiptProvider: true, settlementEnforceMode: true, settlementReconcileIntervalSeconds: 1,
		pendingDeadlineSeconds: 1, providerID: "build1-cli-fixture", build1Catalog: func(s *scenario, c settlementCatalogFixture) settlementCatalogFixture {
			catalog = build1ImportCLICatalog(t, s, c, request)
			return catalog
		}})
	db, err := sql.Open("sqlite", s.coordinatorDB)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	pub, err := base64.StdEncoding.DecodeString(request.AdmissionPublicKey)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		t.Fatal("invalid public admission identity")
	}
	now := time.Now().UTC().Format(time.RFC3339)
	if _, err = db.Exec(`INSERT INTO provider_bootstrap_identities(provider_id,receipt_pubkey,created_at,confirmed_at,expires_at) VALUES(?,?,?,?,NULL)`, s.providerID, pub, now, now); err != nil {
		t.Fatal(err)
	}
	// Only public identity/auth bootstrap is seeded. Admission, probe, receipt and
	// ledger must be produced by the commands and the real services.
	build1BridgePublish(t, request.Root, "service-ready.json", map[string]any{"coordinator_url": s.coordProvURL, "provider_id": s.providerID, "provider_token": s.providerToken})
	build1BridgeAwait(t, request.Root, "service-connect")
	var pending int
	if err = db.QueryRow(`SELECT count(*) FROM model_admission_events WHERE next_state='offer_submitted'`).Scan(&pending); err != nil {
		t.Fatal(err)
	}
	if pending != 1 {
		t.Fatalf("parsed pending offers=%d want1", pending)
	}
	endpoint, err := url.Parse(s.providerEndpointURL)
	if err != nil {
		t.Fatal(err)
	}
	port, err := strconv.Atoi(endpoint.Port())
	if err != nil {
		t.Fatal(err)
	}
	fp := newFakeProvider(t, s.providerID, port, s.coordProvURL, s.providerToken)
	fp.enableSettlementReceipts(catalog)
	fp.build1 = catalog.build1
	fp.build1IdentityProof = func(initial map[string]any, challengeBytes []byte) (map[string]any, error) {
		var challenge map[string]any
		if err := json.Unmarshal(challengeBytes, &challenge); err != nil {
			return nil, err
		}
		build1BridgePublish(t, request.Root, "service-identity-request.json", map[string]any{"initial": initial, "challenge": challenge})
		build1BridgeAwait(t, request.Root, "service-identity-proof.json")
		return build1ReadJSON(t, filepath.Join(request.Root, "service-identity-proof.json")), nil
	}
	fp.start(s.rootCtx)
	s.fakeProv = fp
	s.fakeProvs = append(s.fakeProvs, fp)
	defer fp.stop()
	s.waitForProviderReady(s.providerID)
	build1BridgePublish(t, request.Root, "service-connected.json", map[string]any{"ready": true})
	build1BridgeAwait(t, request.Root, "service-verify")
	fp.hitMu.Lock()
	probes := fp.probeHits
	fp.hitMu.Unlock()
	if probes != 1 {
		t.Fatalf("parsed retry actual WS probes=%d want1", probes)
	}
	const requestID = "b3333333-3333-4333-8333-333333333333"
	code, _, body := s.chatRequest(map[string]string{"X-Request-ID": requestID}, fmt.Sprintf(`{"model":%q,"max_tokens":32,"messages":[{"role":"user","content":"parsed CLI fixture settlement"}]}`, request.ModelID))
	if code != http.StatusOK {
		t.Fatalf("buyer status%d: %s", code, body)
	}
	usage, reservation := waitForSpec022GatewaySettlement(t, s, requestID)
	if usage.Outcome != "spec022_verified" || reservation.Status != "settled" || reservation.SettledTokens != 20 {
		t.Fatalf("settlement outcome=%s status=%s tokens=%d", usage.Outcome, reservation.Status, reservation.SettledTokens)
	}
	verdicts := s.readSettlementReceiptVerdicts()
	if len(verdicts) != 1 || verdicts[0].ReceiptResult != "valid" || verdicts[0].Closed != 1 {
		t.Fatal("expected one valid closed receipt")
	}
	rows := s.readLedgerCredits()
	if len(rows) != 1 {
		t.Fatalf("ledger rows=%d", len(rows))
	}
	// Exact charge is derived from the authenticated fixture rate; no default
	// authority fallback is used. These fixture rates are integral per token.
	rates := build1ReadJSON(t, filepath.Join(request.Inputs, "rate-card"))["rows"].(map[string]any)[request.CatalogKey].(map[string]any)
	gross := (8*int64(rates["prompt_rate_per_mtok"].(float64)) + 12*int64(rates["completion_rate_per_mtok"].(float64))) * int64(rates["global_multiplier_ppm"].(float64)) / 1000000 / 1000000
	provider := gross * int64(rates["provider_share_bps"].(float64)) / 10000
	if rows[0].GrossCredits != gross || rows[0].ProviderCredits != provider {
		t.Fatalf("exact ledger gross=%d provider=%d want%d/%d", rows[0].GrossCredits, rows[0].ProviderCredits, gross, provider)
	}
	var snapshot string
	if err = db.QueryRow(`SELECT route_snapshot_json FROM settlement_route_snapshots WHERE request_id=?`, verdicts[0].RequestID).Scan(&snapshot); err != nil {
		t.Fatal(err)
	}
	var bound map[string]any
	if err = json.Unmarshal([]byte(snapshot), &bound); err != nil {
		t.Fatal(err)
	}
	for key, expected := range map[string]any{
		"artifact_feed_sha256": catalog.build1.artifactSHA,
		"artifact_id":          "mlx-4bit", "artifact_hash": request.ModelHash,
		"artifact_hash_algorithm":                  snapshotManifestV1,
		"artifact_feed_signer_key_id":              catalog.build1.signer(),
		"candidate_catalog_sha256":                 catalog.autotuneCatalogSHA256,
		"admission_rate_card_sha256":               catalog.rateCardSHA256,
		"admission_rate_card_version":              catalog.rateCardVersion,
		"admission_rate_model_key":                 request.CatalogKey,
		"model_id":                                 request.ModelID,
		"admission_prompt_rate_per_mtok":           rates["prompt_rate_per_mtok"],
		"admission_prompt_cache_hit_rate_per_mtok": rates["prompt_cache_hit_rate_per_mtok"],
		"admission_completion_rate_per_mtok":       rates["completion_rate_per_mtok"],
	} {
		if bound[key] != expected {
			t.Fatalf("immutable snapshot differs at %s", key)
		}
	}
	if bound["catalog_body_digest"] == bound["candidate_catalog_sha256"] {
		t.Fatal("independent Tier2 and candidate evidence conflated")
	}
	s.restartCoordinator()
	var recovered string
	if err = db.QueryRow(`SELECT route_snapshot_json FROM settlement_route_snapshots WHERE request_id=?`, verdicts[0].RequestID).Scan(&recovered); err != nil {
		t.Fatal(err)
	}
	if snapshot != recovered || len(s.readLedgerCredits()) != 1 || s.settledQuotaTokens() != 20 {
		t.Fatal("restart changed immutable snapshot or exact accounting")
	}
	code, _, _ = s.gatewayRequest(http.MethodGet, "/v1/receipts/"+requestID, nil)
	if code != 200 {
		t.Fatalf("receipt readback status%d", code)
	}
	build1BridgePublish(t, request.Root, "service-verified.json", map[string]any{"receipt": "valid", "ledger_rows": 1, "buyer_tokens": 20, "gross_credits": gross, "provider_credits": provider, "ws_probes": probes, "physical_mlx": false})
	build1BridgeAwait(t, request.Root, "service-stop")
}

func build1BridgePublish(t *testing.T, root, name string, v any) {
	t.Helper()
	b := build1JSON(t, v)
	path := filepath.Join(root, name)
	if err := os.WriteFile(path+".tmp", b, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(path+".tmp", path); err != nil {
		t.Fatal(err)
	}
}
func build1BridgeAwait(t *testing.T, root, name string) {
	t.Helper()
	deadline := time.Now().Add(120 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(filepath.Join(root, name)); err == nil {
			return
		}
		if name != "service-stop" {
			if _, err := os.Stat(filepath.Join(root, "service-stop")); err == nil {
				t.Fatal("fixture ended before bridge stage")
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("bridge stage timeout: %s", name)
}

func build1ImportCLICatalog(t *testing.T, s *scenario, c settlementCatalogFixture, r build1CLIRequest) settlementCatalogFixture {
	candidate := build1ReadJSON(t, filepath.Join(r.Inputs, "autotune-candidates"))
	c.autotuneCatalogPath = filepath.Join(r.Inputs, "autotune-candidates")
	c.autotuneCatalogSigPath = c.autotuneCatalogPath + ".sig"
	bytes, err := os.ReadFile(c.autotuneCatalogPath)
	if err != nil {
		t.Fatal(err)
	}
	c.autotuneCatalogSHA256 = build1SHA(bytes)
	c.autotuneCatalogVersion = candidate["version"].(string)
	c.autotunePolicyVersion = candidate["policy_version"].(string)
	c.modelHash = r.ModelHash
	c.demandRankPath = filepath.Join(r.Inputs, "demand-rank")
	c.demandRankSigPath = c.demandRankPath + ".sig"
	c.rateCardPath = filepath.Join(r.Inputs, "rate-card")
	c.rateCardSigPath = c.rateCardPath + ".sig"
	bytes, err = os.ReadFile(c.rateCardPath)
	if err != nil {
		t.Fatal(err)
	}
	c.rateCardSHA256 = build1SHA(bytes)
	rate := build1ReadJSON(t, c.rateCardPath)
	c.rateCardVersion = rate["version"].(string)
	public, err := os.ReadFile(filepath.Join(r.Inputs, "public-key.base64"))
	if err != nil {
		t.Fatal(err)
	}
	artifactPath := filepath.Join(r.Inputs, "catalog-artifacts")
	bytes, err = os.ReadFile(artifactPath)
	if err != nil {
		t.Fatal(err)
	}
	sig := build1ReadJSON(t, artifactPath+".sig")
	rewards := map[string]any{}
	for key, value := range rate["rows"].(map[string]any) {
		row := value.(map[string]any)
		rewards[key] = map[string]any{"prompt_credits_per_mtok": row["prompt_rate_per_mtok"], "prompt_cache_hit_credits_per_mtok": row["prompt_cache_hit_rate_per_mtok"], "completion_credits_per_mtok": row["completion_rate_per_mtok"]}
	}
	c.build1 = &build1FeedFixture{publicKey: string(public), artifactPath: artifactPath, artifactSHA: build1SHA(bytes), signerKeyID: sig["key_id"].(string), modelID: r.ModelID, rowIdentity: r.RowIdentity, rewardRates: rewards}
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	minRAM := 1
	body := settlementCatalogBody{CatalogID: "build1-cli-fixture-tier2", ExpiresAt: time.Now().UTC().Add(24 * time.Hour).Truncate(time.Second).Format(time.RFC3339), IssuedAt: time.Now().UTC().Add(-time.Hour).Truncate(time.Second).Format(time.RFC3339), Version: 1, Models: []settlementCatalogModel{{ArtifactKind: "mlx_weight_file", HashScope: "primary_weight_file", ModelID: r.ModelID, MinRAMGB: &minRAM, SHA256: r.ModelHash, Source: "deterministic-cli-fixture"}}}
	canonical := build1JSON(t, body)
	file := settlementCatalogFile{CatalogID: body.CatalogID, ExpiresAt: body.ExpiresAt, IssuedAt: body.IssuedAt, Version: 1, Models: body.Models, Signature: settlementCatalogSignature{Alg: "Ed25519", KeyID: "build1-cli-fixture-tier2-key", Sig: base64.RawURLEncoding.EncodeToString(ed25519.Sign(priv, canonical))}}
	c.path = filepath.Join(s.tempDir, "cli-tier2.json")
	if err = os.WriteFile(c.path, build1JSON(t, file), 0600); err != nil {
		t.Fatal(err)
	}
	c.publicKey = base64.RawURLEncoding.EncodeToString(pub)
	c.catalogID = body.CatalogID
	c.catalogKeyID = file.Signature.KeyID
	return c
}
