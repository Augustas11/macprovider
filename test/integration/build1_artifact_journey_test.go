package integration

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const build1SignerID = "build1-fixture-only"
const build1CandidateID = "byom_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

type build1FeedFixture struct {
	publicKey, artifactPath, artifactSHA string
	signerKeyID, modelID, rowIdentity    string
	rewardRates                          map[string]any
	drainControl                         *build1DrainControl
}

func (f *build1FeedFixture) signer() string {
	if f.signerKeyID != "" {
		return f.signerKeyID
	}
	return build1SignerID
}

func build1SHA(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }
func build1JSON(t *testing.T, v any) []byte {
	t.Helper()
	b, e := json.Marshal(v)
	if e != nil {
		t.Fatal(e)
	}
	return b
}
func build1ReadJSON(t *testing.T, path string) map[string]any {
	t.Helper()
	b, e := os.ReadFile(path)
	if e != nil {
		t.Fatal(e)
	}
	var v map[string]any
	if e = json.Unmarshal(b, &v); e != nil {
		t.Fatal(e)
	}
	return v
}

// All signatures here are disposable transport fixtures. Neither these bytes nor
// the canned provider response establish physical model/reference qualification.
func (s *scenario) writeBuild1Feeds(c settlementCatalogFixture) settlementCatalogFixture {
	t := s.t
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	generated := time.Now().UTC().Add(-time.Minute).Truncate(time.Second).Format(time.RFC3339)
	sign := func(name string, v any) (string, string, string) {
		raw := build1JSON(t, v)
		path := filepath.Join(s.tempDir, name+".json")
		if err := os.WriteFile(path, raw, 0600); err != nil {
			t.Fatal(err)
		}
		sig := build1JSON(t, map[string]string{"key_id": build1SignerID, "alg": "ed25519", "signature": base64.StdEncoding.EncodeToString(ed25519.Sign(priv, raw))})
		if err := os.WriteFile(path+".sig", sig, 0600); err != nil {
			t.Fatal(err)
		}
		return path, path + ".sig", build1SHA(raw)
	}
	candidates := build1ReadJSON(t, c.autotuneCatalogPath)
	candidates["generated_at"] = generated
	candidates["rows"] = map[string]any{staticLlama32CandidateKey: candidates["rows"].(map[string]any)[staticLlama32CandidateKey]}
	c.autotuneCatalogPath, c.autotuneCatalogSigPath, c.autotuneCatalogSHA256 = sign("build1-candidates", candidates)
	demand := build1ReadJSON(t, c.demandRankPath)
	demand["generated_at"] = generated
	c.demandRankPath, c.demandRankSigPath, _ = sign("build1-demand", demand)
	rate := map[string]any{"prompt_rate_per_mtok": 500000, "prompt_cache_hit_rate_per_mtok": 250000, "completion_rate_per_mtok": 1000000, "provider_share_bps": 9000, "global_multiplier_ppm": 1000000}
	defaultRate := map[string]any{"prompt_rate_per_mtok": 1000000, "prompt_cache_hit_rate_per_mtok": 1000000, "completion_rate_per_mtok": 2000000, "provider_share_bps": 9000, "global_multiplier_ppm": 1000000}
	rows := map[string]any{"default": defaultRate, staticLlama32CandidateKey: rate}
	projection := map[string]any{"global_multiplier_ppm": 1000000, "provider_share_bps": 9000, "rows": rows, "usd_per_million_credits": 1}
	c.rateCardVersion = build1SHA(build1JSON(t, projection))
	rates := map[string]any{"version": c.rateCardVersion, "policy_version": c.autotunePolicyVersion, "generated_at": generated, "usd_per_million_credits": 1, "rows": rows}
	c.rateCardPath, c.rateCardSigPath, c.rateCardSHA256 = sign("build1-rate", rates)
	candidate := candidates["rows"].(map[string]any)[staticLlama32CandidateKey].(map[string]any)
	artifact := map[string]any{"allowed_runtime_sources": []string{"mlx_cache"}, "hash": c.modelHash, "hash_algorithm": snapshotManifestV1, "min_ram_gb": candidate["min_ram_gb"], "quantization": "4bit", "runtime_format": "mlx_safetensors", "size_bytes": 123456, "source_ref": map[string]any{"kind": "huggingface_revision", "repo_id": settlementFixtureModelID, "revision": candidate["model_revision"]}, "verification_status": "verified", "verified_at": time.Now().UTC().Format("2006-01-02")}
	artifacts := map[string]any{"version": c.autotuneCatalogVersion, "release_id": c.autotuneCatalogVersion, "policy_version": c.autotunePolicyVersion, "generated_at": generated, "source": "operator_curated_autotune_artifact_catalog", "candidate_catalog_sha256": c.autotuneCatalogSHA256, "models": map[string]any{staticLlama32CandidateKey: map[string]any{"primary_artifact_id": "mlx-4bit", "rate_class": "class-3b", "artifacts": map[string]any{"mlx-4bit": artifact}}}}
	path, _, sha := sign("build1-artifacts", artifacts)
	c.build1 = &build1FeedFixture{publicKey: base64.StdEncoding.EncodeToString(pub), artifactPath: path, artifactSHA: sha}
	return c
}
func configureBuild1Coordinator(cfg map[string]any, c settlementCatalogFixture) {
	cfg["auth"].(map[string]any)["require_provider_tokens"] = true
	autotune := cfg["autotune"].(map[string]any)
	autotune["public_keys"] = map[string]string{c.build1.signer(): c.build1.publicKey}
	autotune["catalog_artifacts_path"] = c.build1.artifactPath
	autotune["catalog_artifacts_sig_path"] = c.build1.artifactPath + ".sig"
	rewards := cfg["rewards"].(map[string]any)
	rewards["rate_card"] = map[string]any{"default": map[string]any{"prompt_credits_per_mtok": 1000000, "completion_credits_per_mtok": 2000000}, staticLlama32CandidateKey: map[string]any{"prompt_credits_per_mtok": 500000, "prompt_cache_hit_credits_per_mtok": 250000, "completion_credits_per_mtok": 1000000}}
	if c.build1.rewardRates != nil {
		rewards["rate_card"] = c.build1.rewardRates
	}
}

func (p *fakeProvider) respondBuild1Frame(conn net.Conn, raw []byte) error {
	var req struct {
		Type       string              `json:"type"`
		RequestID  string              `json:"request_id"`
		Body       string              `json:"body"`
		Stream     bool                `json:"stream"`
		Settlement *settlementMetadata `json:"settlement"`
	}
	if err := json.Unmarshal(raw, &req); err != nil {
		return err
	}
	if req.Type == "drain" && p.build1.drainControl != nil {
		control := p.build1.drainControl
		close(control.observed)
		<-control.allowReady
		if err := writeJSONFrame(conn, readyStateUpdate(p.modelID, p.modelHash)); err != nil {
			return err
		}
		close(control.readySent)
		return nil
	}
	if req.Type != "inference_request" {
		return nil
	}
	body, err := p.openBuild1Request(raw)
	if err != nil {
		return err
	}
	var requestBody map[string]any
	if err = json.Unmarshal([]byte(body), &requestBody); err != nil {
		return err
	}
	if requestBody["model"] != p.modelID {
		return fmt.Errorf("WS model binding differs: %v", requestBody["model"])
	}
	p.hitMu.Lock()
	if req.Settlement == nil {
		p.probeHits++
	} else {
		p.hits++
	}
	omit := p.omitSettlementReceipt
	p.hitMu.Unlock()
	content := "hello from fake provider"
	response := fmt.Sprintf(`{"id":"fixture","object":"chat.completion","model":%q,"choices":[{"index":0,"message":{"role":"assistant","content":%q},"finish_reason":"stop"}],"usage":{"prompt_tokens":8,"completion_tokens":12,"total_tokens":20}}`, p.modelID, content)
	if req.Stream {
		return fmt.Errorf("Build1 fixture expects a nonstream request")
	}
	if err := p.writeBuild1Encrypted(conn, "inference_response_chunk", req.RequestID, build1JSON(p.t, map[string]any{"type": "inference_response_chunk_plaintext", "seq": 0, "data": response})); err != nil {
		return err
	}
	end := map[string]any{"type": "inference_response_end", "request_id": req.RequestID, "status": "complete", "chunks_sent": 1, "usage": map[string]any{"prompt_tokens": 8, "completion_tokens": 12, "total_tokens": 20}}
	if req.Settlement != nil && !omit {
		ts := time.Now().UnixMilli()
		receipt, err := p.buildSettlementReceiptHeader(*req.Settlement, content, "stop", 8, 12, ts)
		if err != nil {
			return err
		}
		end["receipt"] = receipt
		end["terminal_state_ts_unix_ms"] = ts
	}
	return p.writeBuild1Encrypted(conn, "inference_response_end", req.RequestID, build1JSON(p.t, end))
}

func build1SignedOffer(t *testing.T, s *scenario, priv ed25519.PrivateKey) map[string]any {
	pub := priv.Public().(ed25519.PublicKey)
	fields := map[string]any{"signature_domain": "macprovider.model_admission.offer.v1", "provider_id": s.providerID, "candidate_id": build1CandidateID, "runtime_source": "mlx_cache", "served_model_ref": settlementFixtureModelID, "catalog_model_key": staticLlama32CandidateKey, "discovery_digest_sha256": strings.Repeat("a", 64), "evaluation_digest_sha256": strings.Repeat("b", 64), "artifact_hashes": map[string]any{}, "advisory_capabilities": map[string]any{"chat_completions": true, "streaming": nil, "tool_call_passthrough": nil, "structured_output_passthrough": nil, "json_mode": nil, "usage_reporting": nil, "max_context_tokens": 2048, "quantization": nil, "family": nil, "runtime_version": nil}, "fit_evidence_source": "local_discovery", "local_readiness": "ready", "requested_disclosure_class": "catalog_binding_requested", "timestamp": time.Now().UTC().Format(time.RFC3339Nano), "nonce": "nonce-build1", "idempotency_key": "request-build1", "signing_key_digest": build1SHA(pub), "cli_version": "1.8.111"}
	canonical, err := spec015CanonicalJSON(fields)
	if err != nil {
		t.Fatal(err)
	}
	fields["schema"] = "model_admission_offer_submit.v1"
	fields["signature_algorithm"] = "ed25519"
	fields["provider_signature"] = base64.StdEncoding.EncodeToString(ed25519.Sign(priv, canonical))
	return fields
}
func build1Post(t *testing.T, s *scenario, payload map[string]any) (int, map[string]any) {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, s.coordProvURL+"/v1/provider/model-admission/offers", bytes.NewReader(build1JSON(t, payload)))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+s.providerToken)
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	if err = json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("offer response %d %s", resp.StatusCode, raw)
	}
	return resp.StatusCode, out
}

func TestBuild1ArtifactAdmissionSettlesThroughRealServices(t *testing.T) {
	s := newScenario(t, scenarioOpts{build1ArtifactAdmission: true, seedAccount: true, settlementReceiptProvider: true, settlementEnforceMode: true, settlementReconcileIntervalSeconds: 1, pendingDeadlineSeconds: 1})
	requireIsolatedCandidate(t, s)
	db, err := sql.Open("sqlite", s.coordinatorDB)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	// Seed only the fixture's public admission credential after transport auth.
	// No positive model admission, probe, snapshot, receipt or ledger is seeded.
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Format(time.RFC3339)
	if _, err = db.Exec(`INSERT INTO provider_bootstrap_identities(provider_id,receipt_pubkey,created_at,confirmed_at,expires_at) VALUES(?,?,?,?,NULL)`, s.providerID, []byte(pub), now, now); err != nil {
		t.Fatal(err)
	}
	offer := build1SignedOffer(t, s, priv)
	tampered := make(map[string]any, len(offer))
	for k, v := range offer {
		tampered[k] = v
	}
	tampered["discovery_digest_sha256"] = strings.Repeat("c", 64)
	badCode, badStatus := build1Post(t, s, tampered)
	if badCode != http.StatusUnauthorized {
		t.Fatalf("signed field substitution status=%d body=%v", badCode, badStatus)
	}
	var seededAdmissions int
	if err = db.QueryRow(`SELECT count(*) FROM model_admission_events`).Scan(&seededAdmissions); err != nil {
		t.Fatal(err)
	}
	if seededAdmissions != 0 {
		t.Fatal("invalid signature created admission")
	}
	code, status := build1Post(t, s, offer)
	if code != 200 || status["admission_state"] != "settlement_capable" {
		t.Fatalf("offer status=%d body=%v", code, status)
	}
	s.fakeProv.hitMu.Lock()
	probes := s.fakeProv.probeHits
	s.fakeProv.hitMu.Unlock()
	if probes != 1 {
		t.Fatalf("actual WS probes=%d want 1", probes)
	}
	const requestID = "b1111111-1111-4111-8111-111111111111"
	code, _, body := s.chatRequest(map[string]string{"X-Request-ID": requestID}, fmt.Sprintf(`{"model":%q,"max_tokens":32,"messages":[{"role":"user","content":"Build1 fixture journey"}]}`, settlementFixtureModelID))
	if code != 200 {
		t.Fatalf("chat %d: %s", code, body)
	}
	usage, reservation := waitForSpec022GatewaySettlement(t, s, requestID)
	if usage.Outcome != "spec022_verified" || reservation.Status != "settled" || reservation.SettledTokens != 20 {
		t.Fatalf("buyer accounting usage=%+v reservation=%+v", usage, reservation)
	}
	verdicts := waitForSettlementVerdicts(t, s, 1)
	if len(verdicts) != 1 || verdicts[0].ReceiptResult != "valid" || verdicts[0].SettlementOutcome != "verified" || verdicts[0].Closed != 1 {
		t.Fatalf("receipt verdicts=%+v", verdicts)
	}
	credits := waitForLedgerCredits(t, s, 1)
	if len(credits) != 1 || credits[0].GrossCredits != 16 || credits[0].ProviderCredits != 14 || credits[0].SettlementPolicyMode != "enforce" {
		t.Fatalf("ledger credits=%+v", credits)
	}
	var snapshotRaw string
	if err = db.QueryRow(`SELECT route_snapshot_json FROM settlement_route_snapshots WHERE request_id=?`, verdicts[0].RequestID).Scan(&snapshotRaw); err != nil {
		t.Fatal(err)
	}
	var snapshot map[string]any
	if err = json.Unmarshal([]byte(snapshotRaw), &snapshot); err != nil {
		t.Fatal(err)
	}
	want := map[string]any{"artifact_feed_sha256": s.fakeProv.build1.artifactSHA, "artifact_id": "mlx-4bit", "artifact_hash": s.modelHash, "artifact_hash_algorithm": snapshotManifestV1, "artifact_feed_signer_key_id": build1SignerID, "candidate_catalog_sha256": s.autotuneCatalogSHA256, "admission_rate_card_sha256": s.rateCardSHA256, "admission_rate_card_version": s.rateCardVersion, "admission_price_unit": "credits_per_million_tokens", "model_id": settlementFixtureModelID, "admission_rate_model_key": staticLlama32CandidateKey, "admission_prompt_rate_per_mtok": float64(500000), "admission_prompt_cache_hit_rate_per_mtok": float64(250000), "admission_completion_rate_per_mtok": float64(1000000), "model_admission_coordinator_event_id": status["coordinator_event_id"]}
	for key, value := range want {
		if snapshot[key] != value {
			t.Fatalf("snapshot %s=%v want %v", key, snapshot[key], value)
		}
	}
	if snapshot["catalog_body_digest"] == snapshot["candidate_catalog_sha256"] {
		t.Fatal("Tier2 and candidate digests conflated")
	}
	code, replay := build1Post(t, s, offer)
	if code != 200 {
		t.Fatalf("offer replay %d: %v", code, replay)
	}
	s.fakeProv.hitMu.Lock()
	probes = s.fakeProv.probeHits
	s.fakeProv.hitMu.Unlock()
	if probes != 1 {
		t.Fatalf("replay reran probe: %d", probes)
	}
	if got := s.readLedgerCredits(); len(got) != 1 {
		t.Fatalf("replay created credits: %+v", got)
	}
	// The snapshot and receipt must survive a real process restart; a replay
	// after recovery cannot remint the settled provider credit or buyer debit.
	s.restartCoordinator()
	var recoveredRaw string
	if err = db.QueryRow(`SELECT route_snapshot_json FROM settlement_route_snapshots WHERE request_id=?`, verdicts[0].RequestID).Scan(&recoveredRaw); err != nil {
		t.Fatal(err)
	}
	if recoveredRaw != snapshotRaw {
		t.Fatal("restart rewrote immutable route snapshot")
	}
	code, replay = build1Post(t, s, offer)
	if code != 200 {
		t.Fatalf("persisted offer replay %d: %v", code, replay)
	}
	if got := s.readLedgerCredits(); len(got) != 1 || got[0].GrossCredits != 16 || got[0].ProviderCredits != 14 {
		t.Fatalf("restart/replay changed ledger: %+v", got)
	}
	if got := s.settledQuotaTokens(); got != 20 {
		t.Fatalf("restart buyer debit=%d want 20", got)
	}
	recoveredVerdicts := s.readSettlementReceiptVerdicts()
	if len(recoveredVerdicts) != 1 || recoveredVerdicts[0].ReceiptResult != "valid" || recoveredVerdicts[0].Closed != 1 {
		t.Fatalf("restart receipt persistence=%+v", recoveredVerdicts)
	}
	code, _, receiptBody := s.gatewayRequest(http.MethodGet, "/v1/receipts/"+requestID, nil)
	if code != 200 {
		t.Fatalf("receipt readback %d: %s", code, receiptBody)
	}
	code, _, body = s.chatRequest(map[string]string{"X-Request-ID": "b2222222-2222-4222-8222-222222222222"}, fmt.Sprintf(`{"model":%q,"max_tokens":32,"messages":[{"role":"user","content":"old session must not route"}]}`, settlementFixtureModelID))
	if code != http.StatusNotFound || !strings.Contains(string(body), `"inference_ran":false`) || !strings.Contains(string(body), `"settlement_ran":false`) {
		t.Fatalf("old session refusal after restart: %d %s", code, body)
	}
	if got := s.readLedgerCredits(); len(got) != 1 {
		t.Fatalf("stale session created credit: %+v", got)
	}
	t.Logf("B1-T07/T09 fixture: real coordinator+gateway SQLite, signed offer, actual WS probe, persisted valid v4 receipt, buyer debit 20 tokens, gross 16/provider 14 credits; physical_MLX=false")
}
