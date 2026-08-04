package ws_test

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
)

type bootstrapMarkFailingStore struct {
	*auth.Store
}

func (s bootstrapMarkFailingStore) MarkTokenUsed(context.Context, string) error {
	return errors.New("synthetic bootstrap confirmation failure")
}

type stubAutotuneEvidence struct {
	evidence autotune.VerifiedEvidence
	ok       bool
	err      error
}

func (s stubAutotuneEvidence) LatestVerified(context.Context, string, time.Duration) (autotune.VerifiedEvidence, bool, error) {
	return s.evidence, s.ok, s.err
}

type sequencedAutotuneEvidence struct {
	mu        sync.Mutex
	responses []stubAutotuneEvidence
	calls     int
}

func (s *sequencedAutotuneEvidence) LatestVerified(context.Context, string, time.Duration) (autotune.VerifiedEvidence, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.calls >= len(s.responses) {
		return autotune.VerifiedEvidence{}, false, errors.New("unexpected autotune evidence lookup")
	}
	response := s.responses[s.calls]
	s.calls++
	return response.evidence, response.ok, response.err
}

func (s *sequencedAutotuneEvidence) callCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.calls
}

func TestAutotuneHelloGateRejectsOverTierClaim(t *testing.T) {
	catalog := mustAutotuneCatalog(t)
	evidence := autotune.VerifiedEvidence{
		ProbeProtocol:          "spec-023-harmony-stream.v2",
		BinaryVersion:          "0.1.0",
		ExecutableSHA256:       "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
		CandidateCatalogSHA256: catalog.SHA256,
		Benchmarks: []autotune.VerifiedBenchmark{
			{
				ModelKey:               "small",
				ModelID:                "mlx-community/Llama-3.2-3B-Instruct-4bit",
				SustainedTPS:           20,
				TTFTMS:                 1000,
				ArtifactSHA256:         "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a",
				CandidateCatalogSHA256: catalog.SHA256,
				CandidateRowIdentity:   mustAutotuneRowIdentity(t, catalog, "small"),
			},
		},
	}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithAutotuneHelloGate(catalog, stubAutotuneEvidence{evidence: evidence, ok: true}),
	}, func(cfg *config.Config) {
		cfg.Providers = nil
		cfg.ProofOfWeights.RequireAutotuneHelloGate = true
		cfg.ProofOfWeights.AutotuneEvidenceTTLDays = 30
	})
	defer h.HTTP.Close()

	hello := validHello("m4-anon")
	hello["model_id"] = "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
	code, reason := sendHelloExpectClose(t, h.HTTP.URL, hello)
	if code != providerws.CloseInvalidHello || reason != "autotune_model_cap_exceeded" {
		t.Fatalf("code=%d reason=%q", code, reason)
	}
}

func TestAutotuneHelloGateAllowsUnderTierClaim(t *testing.T) {
	catalog := mustAutotuneCatalog(t)
	evidence := autotune.VerifiedEvidence{
		ProbeProtocol:          "spec-023-harmony-stream.v2",
		BinaryVersion:          "0.1.0",
		ExecutableSHA256:       "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
		CandidateCatalogSHA256: catalog.SHA256,
		Benchmarks: []autotune.VerifiedBenchmark{
			{
				ModelKey:               "small",
				ModelID:                "mlx-community/Llama-3.2-3B-Instruct-4bit",
				SustainedTPS:           20,
				TTFTMS:                 1000,
				ArtifactSHA256:         "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a",
				CandidateCatalogSHA256: catalog.SHA256,
				CandidateRowIdentity:   mustAutotuneRowIdentity(t, catalog, "small"),
			},
		},
	}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithAutotuneHelloGate(catalog, stubAutotuneEvidence{evidence: evidence, ok: true}),
	}, func(cfg *config.Config) {
		cfg.Providers = nil
		cfg.ProofOfWeights.RequireAutotuneHelloGate = true
		cfg.ProofOfWeights.AutotuneEvidenceTTLDays = 30
	})
	defer h.HTTP.Close()

	hello := validHello("m4-anon")
	hello["model_id"] = "mlx-community/Llama-3.2-3B-Instruct-4bit"
	addCatalogAdmissionMetadata(t, hello, catalog)
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(hello)); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read ack: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}
	var ack map[string]any
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("ack json: %v", err)
	}
	if ack["type"] != "hello_ack" {
		t.Fatalf("ack type = %v", ack["type"])
	}
	if ack["catalog_compatible"] != true || ack["catalog_release_id"] != catalog.Version || ack["catalog_candidate_sha256"] != catalog.SHA256 {
		t.Fatalf("catalog admission ack = %+v", ack)
	}
	provider, ok := h.Registry.Resolve("m4-anon", ack["assigned_id"].(string))
	if !ok {
		t.Fatal("provider not registered")
	}
	if provider.MaxAdmittedModelKey != "small" {
		t.Fatalf("MaxAdmittedModelKey = %q, want small", provider.MaxAdmittedModelKey)
	}
	if provider.CatalogAdmissionMode != "current" || provider.CatalogReleaseID != catalog.Version || provider.CatalogPolicyVersion != catalog.PolicyVersion || provider.CandidateCatalogSHA256 != catalog.SHA256 || provider.CatalogSignerKeyID != catalog.SignerKeyID || provider.CandidateRowIdentity == "" {
		t.Fatalf("catalog admission evidence = %+v", provider)
	}
	if provider.MaxAdmittedModelID != "mlx-community/Llama-3.2-3B-Instruct-4bit" {
		t.Fatalf("MaxAdmittedModelID = %q", provider.MaxAdmittedModelID)
	}
	if provider.MaxAdmittedMinRAMGB != 4 {
		t.Fatalf("MaxAdmittedMinRAMGB = %d, want 4", provider.MaxAdmittedMinRAMGB)
	}
}

func TestAutotuneHelloGateRejectsEvidenceBinaryVersionMismatch(t *testing.T) {
	catalog := mustAutotuneCatalog(t)
	evidence := autotune.VerifiedEvidence{
		ProbeProtocol:          "spec-023-harmony-stream.v2",
		BinaryVersion:          "0.1.1",
		ExecutableSHA256:       "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
		CandidateCatalogSHA256: catalog.SHA256,
		Benchmarks: []autotune.VerifiedBenchmark{{
			ModelKey:               "small",
			ModelID:                "mlx-community/Llama-3.2-3B-Instruct-4bit",
			SustainedTPS:           20,
			TTFTMS:                 1000,
			ArtifactSHA256:         "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a",
			CandidateCatalogSHA256: catalog.SHA256,
			CandidateRowIdentity:   mustAutotuneRowIdentity(t, catalog, "small"),
		}},
	}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithAutotuneHelloGate(catalog, stubAutotuneEvidence{evidence: evidence, ok: true}),
	}, func(cfg *config.Config) {
		cfg.Providers = nil
		cfg.ProofOfWeights.RequireAutotuneHelloGate = true
		cfg.ProofOfWeights.AutotuneEvidenceTTLDays = 30
	})
	defer h.HTTP.Close()

	hello := validHello("m4-anon")
	hello["model_id"] = "mlx-community/Llama-3.2-3B-Instruct-4bit"
	addCatalogAdmissionMetadata(t, hello, catalog)
	code, reason := sendHelloExpectClose(t, h.HTTP.URL, hello)
	if code != providerws.CloseInvalidHello || reason != "autotune_evidence_binary_version_mismatch" {
		t.Fatalf("code=%d reason=%q", code, reason)
	}
}

func TestAutotuneHelloGateSandboxesMissingEvidence(t *testing.T) {
	catalog := mustAutotuneCatalog(t)
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithAutotuneHelloGate(catalog, stubAutotuneEvidence{ok: false}),
	}, func(cfg *config.Config) {
		cfg.ProofOfWeights.RequireAutotuneHelloGate = true
		cfg.ProofOfWeights.AutotuneEvidenceTTLDays = 30
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	hello := validHello("m4-anon")
	hello["model_id"] = "mlx-community/Llama-3.2-3B-Instruct-4bit"
	addCatalogAdmissionMetadata(t, hello, catalog)
	if err := wsutil.WriteClientText(conn, mustJSON(hello)); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read ack: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op=%v, want text", op)
	}
	var ack map[string]any
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("ack json: %v", err)
	}
	if ack["type"] != "hello_ack" {
		t.Fatalf("ack type=%v", ack["type"])
	}
	provider, ok := h.Registry.Resolve("m4-anon", ack["assigned_id"].(string))
	if !ok {
		t.Fatal("provider not registered")
	}
	if !provider.AdmissionSandboxed || provider.RoutingEligible() || provider.ServingCapable() {
		t.Fatalf("missing evidence provider must be sandboxed and buyer-unroutable: %+v", provider)
	}

	disabled := config.Default().ProofOfWeights
	disabled.RequireAutotuneHelloGate = false
	result := h.Provider.SetProofOfWeightsConfig(disabled)
	afterDisable, ok := h.Registry.Resolve("m4-anon", ack["assigned_id"].(string))
	if !ok {
		t.Fatal("provider disappeared after gate-disable reload")
	}
	if !afterDisable.AdmissionSandboxed || afterDisable.RoutingEligible() || afterDisable.ServingCapable() {
		t.Fatalf("sandbox-only no-credential provider must not auto-promote on gate disable: result=%+v provider=%+v", result, afterDisable)
	}
}

func TestProofOfWeightsReloadSandboxesExistingUnverifiedSession(t *testing.T) {
	catalog := mustAutotuneCatalog(t)
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithAutotuneHelloGate(catalog, stubAutotuneEvidence{ok: false}),
	}, func(cfg *config.Config) {
		cfg.ProofOfWeights.RequireAutotuneHelloGate = false
		cfg.ProofOfWeights.AutotuneEvidenceTTLDays = 30
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	hello := validHello("m4-anon")
	hello["model_id"] = "mlx-community/Llama-3.2-3B-Instruct-4bit"
	addCatalogAdmissionMetadata(t, hello, catalog)
	if err := wsutil.WriteClientText(conn, mustJSON(hello)); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, _, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read ack: %v", err)
	}
	var ack map[string]any
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("ack json: %v", err)
	}
	assignedID := ack["assigned_id"].(string)
	before, ok := h.Registry.Resolve("m4-anon", assignedID)
	if !ok || !before.RoutingEligible() {
		t.Fatalf("gate-off provider should start routable: %+v ok=%v", before, ok)
	}

	next := config.Default().ProofOfWeights
	next.RequireAutotuneHelloGate = true
	next.AutotuneEvidenceTTLDays = 30
	result := h.Provider.SetProofOfWeightsConfig(next)
	if result.PreQuarantined != 1 || result.Sandboxed != 1 {
		t.Fatalf("reload result = %+v, want one pre-quarantined sandbox", result)
	}
	after, ok := h.Registry.Resolve("m4-anon", assignedID)
	if !ok {
		t.Fatal("provider disappeared after proof_of_weights reload")
	}
	if !after.AdmissionSandboxed || after.AdmissionEvidenceStale || after.RoutingEligible() || after.ServingCapable() {
		t.Fatalf("hot-enabled gate should sandbox existing unverified session: %+v", after)
	}

	disabled := next
	disabled.RequireAutotuneHelloGate = false
	result = h.Provider.SetProofOfWeightsConfig(disabled)
	if result.ClearedGateExclusions == 0 {
		t.Fatalf("disable reload did not report clearing gate exclusions: %+v", result)
	}
	cleared, ok := h.Registry.Resolve("m4-anon", assignedID)
	if !ok || cleared.AdmissionSandboxed || cleared.AdmissionEvidenceStale || !cleared.RoutingEligible() {
		t.Fatalf("gate disable should restore observe-only routing: %+v ok=%v", cleared, ok)
	}
}

func TestAutotuneHelloGateRechecksEvidenceAfterChallenge(t *testing.T) {
	catalog := mustAutotuneCatalog(t)
	evidence := autotune.VerifiedEvidence{
		ProbeProtocol:          "spec-023-harmony-stream.v2",
		BinaryVersion:          "0.1.0",
		ExecutableSHA256:       "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
		CandidateCatalogSHA256: catalog.SHA256,
		Benchmarks: []autotune.VerifiedBenchmark{{
			ModelKey:               "small",
			ModelID:                "mlx-community/Llama-3.2-3B-Instruct-4bit",
			SustainedTPS:           20,
			TTFTMS:                 1000,
			ArtifactSHA256:         "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a",
			CandidateCatalogSHA256: catalog.SHA256,
			CandidateRowIdentity:   mustAutotuneRowIdentity(t, catalog, "small"),
		}},
	}
	evidenceStore := &sequencedAutotuneEvidence{responses: []stubAutotuneEvidence{
		{evidence: evidence, ok: true},
		{ok: false},
	}}
	tokenStore, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open auth store: %v", err)
	}
	defer tokenStore.Close()
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithAutotuneHelloGate(catalog, evidenceStore),
		providerws.WithTokenIssuer(tokenStore),
	}, func(cfg *config.Config) {
		cfg.Providers = nil
		cfg.ProofOfWeights.RequireAutotuneHelloGate = true
		cfg.ProofOfWeights.AutotuneEvidenceTTLDays = 30
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	initial := validAuthInitialWithFreshKey(t, "m4-anon")
	initial["model_id"] = "mlx-community/Llama-3.2-3B-Instruct-4bit"
	addCatalogAdmissionMetadata(t, initial, catalog)
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write auth initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	writeAuthProof(t, conn, challenge, "m4-anon", nil)

	frame, err := gobwas.ReadFrame(conn)
	if err != nil {
		t.Fatalf("read post-proof response: %v", err)
	}
	if frame.Header.OpCode != gobwas.OpText {
		t.Fatalf("post-proof opcode=%v, want text", frame.Header.OpCode)
	}
	var response providerws.AuthResponse
	if err := json.Unmarshal(frame.Payload, &response); err != nil {
		t.Fatalf("post-proof auth response json: %v", err)
	}
	if response.Status != "accepted" {
		t.Fatalf("post-proof response = %+v", response)
	}
	if got := evidenceStore.callCount(); got != 2 {
		t.Fatalf("autotune evidence lookups=%d, want initial and post-proof checks", got)
	}
	provider, ok := h.Registry.Resolve("m4-anon", response.AssignedID)
	if !ok {
		t.Fatal("post-proof evidence loss did not register provider")
	}
	if !provider.AdmissionSandboxed || provider.RoutingEligible() {
		t.Fatalf("post-proof evidence loss must register sandboxed only: %+v", provider)
	}
	if records := h.Provider.Admission().Records(nil); len(records) != 1 {
		t.Fatalf("post-proof evidence loss must still be admission-rate limited: %+v", records)
	}
	if active, err := tokenStore.HasActiveTokenForProvider(context.Background(), "m4-anon"); err != nil || active {
		t.Fatalf("post-proof sandbox must not mint a provider credential active=%v err=%v", active, err)
	}
}

func TestAutotuneHelloGateV1SandboxKeepsProviderBuyerUnroutable(t *testing.T) {
	catalog := mustAutotuneCatalog(t)
	evidence := autotune.VerifiedEvidence{
		ProbeProtocol:          "spec-023-harmony-stream.v2",
		BinaryVersion:          "0.1.0",
		ExecutableSHA256:       "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
		CandidateCatalogSHA256: catalog.SHA256,
		Benchmarks: []autotune.VerifiedBenchmark{{
			ModelKey:               "small",
			ModelID:                "mlx-community/Llama-3.2-3B-Instruct-4bit",
			SustainedTPS:           20,
			TTFTMS:                 1000,
			ArtifactSHA256:         "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a",
			CandidateCatalogSHA256: catalog.SHA256,
			CandidateRowIdentity:   mustAutotuneRowIdentity(t, catalog, "small"),
		}},
	}
	evidenceStore := &sequencedAutotuneEvidence{responses: []stubAutotuneEvidence{
		{ok: false},
		{evidence: evidence, ok: true},
	}}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithAutotuneHelloGate(catalog, evidenceStore),
	}, func(cfg *config.Config) {
		cfg.Providers = nil
		cfg.Admission.ProvisionalPoolMax = 1
		cfg.Admission.ProvisionalAdmissionRatePerHour = 10
		cfg.ProofOfWeights.RequireAutotuneHelloGate = true
		cfg.ProofOfWeights.AutotuneEvidenceTTLDays = 30
	})
	defer h.HTTP.Close()

	hello := validHello("m4-anon")
	hello["model_id"] = "mlx-community/Llama-3.2-3B-Instruct-4bit"
	addCatalogAdmissionMetadata(t, hello, catalog)
	firstConn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("first dial: %v", err)
	}
	defer firstConn.Close()
	if err := wsutil.WriteClientText(firstConn, mustJSON(hello)); err != nil {
		t.Fatalf("first hello: %v", err)
	}
	firstPayload, firstOp, err := wsutil.ReadServerData(firstConn)
	if err != nil {
		t.Fatalf("first response: %v", err)
	}
	if firstOp != gobwas.OpText {
		t.Fatalf("first response opcode=%v, want text", firstOp)
	}
	var firstAck map[string]any
	if err := json.Unmarshal(firstPayload, &firstAck); err != nil {
		t.Fatalf("first ack json: %v", err)
	}
	firstProvider, ok := h.Registry.Resolve("m4-anon", firstAck["assigned_id"].(string))
	if !ok {
		t.Fatal("first provider not registered")
	}
	if !firstProvider.AdmissionSandboxed || firstProvider.RoutingEligible() {
		t.Fatalf("first provider must be sandboxed and buyer-unroutable: %+v", firstProvider)
	}

	secondConn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("second dial: %v", err)
	}
	defer secondConn.Close()
	secondHello := validHello("m4-anon-b")
	secondHello["model_id"] = "mlx-community/Llama-3.2-3B-Instruct-4bit"
	addCatalogAdmissionMetadata(t, secondHello, catalog)
	if err := wsutil.WriteClientText(secondConn, mustJSON(secondHello)); err != nil {
		t.Fatalf("second hello: %v", err)
	}
	secondFrame, err := gobwas.ReadFrame(secondConn)
	if err != nil {
		t.Fatalf("second response: %v", err)
	}
	if secondFrame.Header.OpCode != gobwas.OpClose {
		t.Fatalf("second response opcode=%v, want close", secondFrame.Header.OpCode)
	}
	closeCode, closeReason := gobwas.ParseCloseFrameData(secondFrame.Payload)
	if closeCode != providerws.CloseProvisionalPoolFull || closeReason == "" {
		t.Fatalf("second close=(%d,%q), want provisional pool full", closeCode, closeReason)
	}
	if got := evidenceStore.callCount(); got != 1 {
		t.Fatalf("autotune evidence lookups=%d, want only the first sandbox before capacity refusal", got)
	}
}

func TestAutotuneHelloGateSandboxRejectsTokenlessActiveTokenOwner(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open auth store: %v", err)
	}
	defer store.Close()
	if _, _, err := store.IssueToken(context.Background(), "m4-anon", "M4 test provider"); err != nil {
		t.Fatalf("seed provider token: %v", err)
	}
	catalog := mustAutotuneCatalog(t)
	h := newProviderHarnessWithServerOptions(t, store, []providerws.Option{
		providerws.WithAutotuneHelloGate(catalog, stubAutotuneEvidence{ok: false}),
		providerws.WithTokenIssuer(store),
	}, func(cfg *config.Config) {
		cfg.Providers = nil
		cfg.ProofOfWeights.RequireAutotuneHelloGate = true
		cfg.ProofOfWeights.AutotuneEvidenceTTLDays = 30
	})
	defer h.HTTP.Close()

	hello := validHello("m4-anon")
	hello["model_id"] = "mlx-community/Llama-3.2-3B-Instruct-4bit"
	addCatalogAdmissionMetadata(t, hello, catalog)
	code, reason := sendHelloExpectClose(t, h.HTTP.URL, hello)
	if code != providerws.CloseInvalidToken || reason != "invalid_token" {
		t.Fatalf("close=(%d,%q), want invalid token", code, reason)
	}
	if got := h.Registry.Count(); got != 0 {
		t.Fatalf("tokenless active-token sandbox registered %d providers, want 0", got)
	}
}

func TestAutotuneHelloGateBearerSandboxClearsOnGateDisable(t *testing.T) {
	const providerID = "m4-anon"
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open auth store: %v", err)
	}
	defer store.Close()
	_, bearer, err := store.IssueToken(context.Background(), providerID, "M4 test provider")
	if err != nil {
		t.Fatalf("issue provider token: %v", err)
	}
	catalog := mustAutotuneCatalog(t)
	h := newProviderHarnessWithServerOptions(t, store, []providerws.Option{
		providerws.WithAutotuneHelloGate(catalog, stubAutotuneEvidence{ok: false}),
		providerws.WithTokenIssuer(store),
	}, func(cfg *config.Config) {
		cfg.Providers = nil
		cfg.ProofOfWeights.RequireAutotuneHelloGate = true
		cfg.ProofOfWeights.AutotuneEvidenceTTLDays = 30
	})
	defer h.HTTP.Close()

	conn, _, _, err := bearerDialer(bearer).Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	hello := validHello(providerID)
	hello["model_id"] = "mlx-community/Llama-3.2-3B-Instruct-4bit"
	addCatalogAdmissionMetadata(t, hello, catalog)
	if err := wsutil.WriteClientText(conn, mustJSON(hello)); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read ack: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op=%v, want text", op)
	}
	var ack map[string]any
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("ack json: %v", err)
	}
	if ack["type"] != "hello_ack" {
		t.Fatalf("ack type=%v", ack["type"])
	}
	assignedID, _ := ack["assigned_id"].(string)
	if assignedID == "" {
		t.Fatalf("assigned_id missing from ack: %+v", ack)
	}
	if token, _ := ack["assigned_provider_token"].(string); token != "" {
		t.Fatalf("bearer sandbox minted assigned_provider_token=%q", token)
	}
	provider, ok := h.Registry.Resolve(providerID, assignedID)
	if !ok {
		t.Fatal("provider not registered")
	}
	if !provider.AdmissionSandboxed || provider.AuthState != pool.AuthBearerValidated || provider.RoutingEligible() {
		t.Fatalf("bearer provider must start authenticated but sandboxed: %+v", provider)
	}

	disabled := config.Default().ProofOfWeights
	disabled.RequireAutotuneHelloGate = false
	result := h.Provider.SetProofOfWeightsConfig(disabled)
	afterDisable, ok := h.Registry.Resolve(providerID, assignedID)
	if !ok {
		t.Fatal("provider disappeared after gate-disable reload")
	}
	if result.ClearedGateExclusions == 0 {
		t.Fatalf("disable reload did not report clearing gate exclusions: %+v", result)
	}
	if afterDisable.AdmissionSandboxed || !afterDisable.RoutingEligible() || !afterDisable.ServingCapable() {
		t.Fatalf("bearer-authenticated sandbox should promote on gate disable: result=%+v provider=%+v", result, afterDisable)
	}
}

func TestCredentialBootstrapV1IsRejected(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open auth store: %v", err)
	}
	defer store.Close()
	catalog := mustAutotuneCatalog(t)
	h := newProviderHarnessWithServerOptions(t, store, []providerws.Option{
		providerws.WithAutotuneHelloGate(catalog, stubAutotuneEvidence{ok: false}),
	}, func(cfg *config.Config) {
		cfg.Providers = nil
		cfg.Auth.RequireProviderTokens = true
		cfg.Auth.AllowTokenlessProvisionalBootstrap = true
		cfg.ProofOfWeights.RequireAutotuneHelloGate = true
		cfg.ProofOfWeights.AutotuneEvidenceTTLDays = 30
	})
	defer h.HTTP.Close()

	hello := validHello("credential-only-provider")
	hello["credential_bootstrap"] = true
	code, reason := sendHelloExpectClose(t, h.HTTP.URL, hello)
	if code != providerws.CloseInvalidHello || reason != "credential_bootstrap_requires_v2" {
		t.Fatalf("close=%d reason=%q", code, reason)
	}
	if got := h.Registry.Count(); got != 0 {
		t.Fatalf("credential bootstrap registered %d providers, want 0", got)
	}
}

func TestCredentialBootstrapRejectsPredictableProviderHandle(t *testing.T) {
	store, h := newCredentialBootstrapHarness(t, nil)
	pub, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("receipt keypair: %v", err)
	}
	initial := credentialBootstrapInitial(t, "office-mac", pub)
	code, reason := sendHelloExpectClose(t, h.HTTP.URL, initial)
	if code != providerws.CloseIdentitySignatureRequired || reason != "bootstrap_receipt_identity_required" {
		t.Fatalf("close=%d reason=%q", code, reason)
	}
	if active, err := store.HasActiveTokenForProvider(context.Background(), "office-mac"); err != nil || active {
		t.Fatalf("predictable handle created token: active=%v err=%v", active, err)
	}
}

func TestCredentialBootstrapV2CompletesProofWithoutEvidenceOrPoolRegistration(t *testing.T) {
	const providerID = "mp-00000000000000000000000000000001"
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open auth store: %v", err)
	}
	defer store.Close()
	catalog := mustAutotuneCatalog(t)
	h := newProviderHarnessWithServerOptions(t, store, []providerws.Option{
		providerws.WithAutotuneHelloGate(catalog, stubAutotuneEvidence{ok: false}),
	}, func(cfg *config.Config) {
		cfg.Providers = nil
		cfg.Auth.RequireProviderTokens = true
		cfg.Auth.AllowTokenlessProvisionalBootstrap = true
		cfg.Tier2.RequireEncryptedLeg = true
		cfg.ProofOfWeights.RequireAutotuneHelloGate = true
		cfg.ProofOfWeights.AutotuneEvidenceTTLDays = 30
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	_, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("keypair: %v", err)
	}
	initial := validAuthInitial(providerID, base64.RawURLEncoding.EncodeToString(providerPublicRaw))
	receiptPub, receiptPriv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("receipt keypair: %v", err)
	}
	initial["credential_bootstrap"] = true
	initial["provider_receipt_public_key"] = base64.StdEncoding.EncodeToString(receiptPub)
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	writeAuthProofWithFields(t, conn, challenge, providerID, nil,
		signedCredentialBootstrapProofFields(t, receiptPriv, providerID, challenge, initial))
	response := readAuthResponse(t, conn)
	if response.Status != "accepted" || response.AssignedProviderToken == "" || response.Tier2Session == nil {
		t.Fatalf("bootstrap response = %+v", response)
	}
	mintedProviderID, valid, err := store.ValidateToken(context.Background(), response.AssignedProviderToken)
	if err != nil || !valid || mintedProviderID != providerID {
		t.Fatalf("minted token provider=%q valid=%v err=%v", mintedProviderID, valid, err)
	}
	if got := h.Registry.Count(); got != 0 {
		t.Fatalf("v2 credential bootstrap registered %d providers, want 0", got)
	}
}

func TestCredentialBootstrapBearerV2UsesDurableReceiptIdentityWithoutOptionalStore(t *testing.T) {
	const providerID = "mp-00000000000000000000000000000011"
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open auth store: %v", err)
	}
	defer store.Close()
	h := newProviderHarnessWithServerOptions(t, store, nil, func(cfg *config.Config) {
		cfg.Providers = nil
		cfg.Auth.RequireProviderTokens = true
		cfg.Auth.AllowTokenlessProvisionalBootstrap = true
		cfg.Tier2.RequireEncryptedLeg = true
	})
	defer h.HTTP.Close()

	receiptPub, receiptPriv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("receipt keypair: %v", err)
	}
	mint := completeCredentialBootstrap(t, h.HTTP.URL, providerID, receiptPub, receiptPriv)
	if mint.AssignedProviderToken == "" {
		t.Fatal("bootstrap response omitted bearer")
	}

	_, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("provider keypair: %v", err)
	}
	rotatedReceiptPub, rotatedReceiptPriv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("rotated receipt keypair: %v", err)
	}
	initial := validAuthInitial(providerID, base64.RawURLEncoding.EncodeToString(providerPublicRaw))
	// Receipt publication may rotate independently. The durable bootstrap
	// identity authorizes the complete transcript containing this candidate.
	initial["provider_receipt_public_key"] = base64.StdEncoding.EncodeToString(rotatedReceiptPub)
	conn, _, _, err := bearerDialer(mint.AssignedProviderToken).Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial bearer v2: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write bearer initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	if challenge.BootstrapIdentityPubkey != base64.StdEncoding.EncodeToString(receiptPub) {
		t.Fatalf("bootstrap identity challenge hint=%q, want durable original key", challenge.BootstrapIdentityPubkey)
	}
	fields := signedIdentityProofFields(t, rotatedReceiptPriv, providerID, challenge.AuthAttemptID, initial)
	writeAuthProofWithFields(t, conn, challenge, providerID, nil, fields)
	response := readAuthResponse(t, conn)
	if response.Status != "rejected" || response.Error == nil || response.Error.Code != "identity_signature_required" {
		t.Fatalf("invalid durable-identity proof response=%+v", response)
	}
	code, reason := readCredentialBootstrapClose(t, conn, nil)
	if code != providerws.CloseIdentitySignatureRequired || reason != "identity_signature_required" {
		t.Fatalf("invalid durable-identity proof close=%d reason=%q", code, reason)
	}
	_ = conn.Close()

	initial = validAuthInitialWithFreshKey(t, providerID)
	initial["provider_receipt_public_key"] = base64.StdEncoding.EncodeToString(rotatedReceiptPub)
	conn, _, _, err = bearerDialer(mint.AssignedProviderToken).Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("redial bearer v2: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("rewrite bearer initial: %v", err)
	}
	challenge = readAuthChallenge(t, conn)
	fields = signedIdentityProofFields(t, receiptPriv, providerID, challenge.AuthAttemptID, initial)
	writeAuthProofWithFields(t, conn, challenge, providerID, nil, fields)
	response = readAuthResponse(t, conn)
	if response.Status != "accepted" || response.AssignedID != challenge.AssignedID {
		t.Fatalf("valid durable-identity proof response=%+v", response)
	}

	records, err := store.ListTokens(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 || !records[0].LastUsedAt.Valid {
		t.Fatalf("accepted signed bearer did not confirm bootstrap token: %#v", records)
	}
}

func TestDurableBootstrapBearerCannotDowngradeToV1ButRowlessLegacyRemainsCompatible(t *testing.T) {
	const durableProviderID = "mp-00000000000000000000000000000014"
	const legacyProviderID = "mp-00000000000000000000000000000015"
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open auth store: %v", err)
	}
	defer store.Close()
	h := newProviderHarnessWithServerOptions(t, store, nil, func(cfg *config.Config) {
		cfg.Providers = nil
		cfg.Auth.RequireProviderTokens = true
		cfg.Auth.AllowTokenlessProvisionalBootstrap = true
		cfg.Tier2.RequireEncryptedLeg = false
	})
	defer h.HTTP.Close()

	durablePub, durablePriv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("durable keypair: %v", err)
	}
	mint := completeCredentialBootstrap(t, h.HTTP.URL, durableProviderID, durablePub, durablePriv)
	conn, buffered, _, err := bearerDialer(mint.AssignedProviderToken).Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial durable v1 downgrade: %v", err)
	}
	if err := wsutil.WriteClientText(conn, mustJSON(validHello(durableProviderID))); err != nil {
		t.Fatalf("write durable v1 hello: %v", err)
	}
	code, reason := readCredentialBootstrapClose(t, conn, buffered)
	_ = conn.Close()
	if code != providerws.CloseIdentitySignatureRequired || reason != "bootstrap_identity_requires_v2" {
		t.Fatalf("durable v1 downgrade close=%d reason=%q", code, reason)
	}

	const ordinaryProviderID = "mac"
	_, ordinaryBearer, err := store.IssueToken(context.Background(), ordinaryProviderID, "ordinary durable provider")
	if err != nil {
		t.Fatalf("issue ordinary bearer: %v", err)
	}
	ordinaryPub, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("ordinary keypair: %v", err)
	}
	if err := store.BindAdmissionIdentity(context.Background(), ordinaryProviderID, ordinaryBearer, ordinaryPub, time.Now().UTC()); err != nil {
		t.Fatalf("bind ordinary admission identity: %v", err)
	}
	ordinaryConn, ordinaryBuffered, _, err := bearerDialer(ordinaryBearer).Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial ordinary v1 downgrade: %v", err)
	}
	if err := wsutil.WriteClientText(ordinaryConn, mustJSON(validHello(ordinaryProviderID))); err != nil {
		t.Fatalf("write ordinary v1 hello: %v", err)
	}
	code, reason = readCredentialBootstrapClose(t, ordinaryConn, ordinaryBuffered)
	_ = ordinaryConn.Close()
	if code != providerws.CloseIdentitySignatureRequired || reason != "durable_identity_requires_v2" {
		t.Fatalf("ordinary durable v1 downgrade close=%d reason=%q", code, reason)
	}

	_, legacyBearer, err := store.IssueToken(context.Background(), legacyProviderID, "rowless legacy provider")
	if err != nil {
		t.Fatalf("issue rowless legacy bearer: %v", err)
	}
	if exists, err := store.BootstrapIdentityExists(context.Background(), legacyProviderID); err != nil || exists {
		t.Fatalf("legacy bootstrap identity exists=%v err=%v, want absent", exists, err)
	}
	legacyConn, _, _, err := bearerDialer(legacyBearer).Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial rowless legacy v1: %v", err)
	}
	defer legacyConn.Close()
	if err := wsutil.WriteClientText(legacyConn, mustJSON(validHello(legacyProviderID))); err != nil {
		t.Fatalf("write rowless legacy v1 hello: %v", err)
	}
	payload, op, err := wsutil.ReadServerData(legacyConn)
	if err != nil {
		t.Fatalf("read rowless legacy v1 ack: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("rowless legacy v1 opcode=%v, want text", op)
	}
	var ack providerws.HelloAck
	if err := json.Unmarshal(payload, &ack); err != nil || ack.Type != "hello_ack" {
		t.Fatalf("rowless legacy v1 ack=%+v err=%v", ack, err)
	}
	if _, ok := h.Registry.Resolve(legacyProviderID, ack.AssignedID); !ok {
		t.Fatal("rowless legacy v1 provider not registered")
	}
}

func TestLegacyMPBearerV2WithoutBootstrapRowUsesLivePoolIdentity(t *testing.T) {
	const providerID = "mp-00000000000000000000000000000012"
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open auth store: %v", err)
	}
	defer store.Close()
	_, bearer, err := store.IssueToken(context.Background(), providerID, "legacy mp provider")
	if err != nil {
		t.Fatalf("issue legacy token: %v", err)
	}
	h := newProviderHarnessWithServerOptions(t, store, []providerws.Option{
		providerws.WithIdentitySignatureStore(&fakeIdentitySignatureStore{}),
	}, func(cfg *config.Config) {
		cfg.Providers = nil
		cfg.Auth.RequireProviderTokens = true
		cfg.Tier2.RequireEncryptedLeg = true
	})
	defer h.HTTP.Close()
	receiptPub, receiptPriv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("legacy receipt keypair: %v", err)
	}
	if _, registered := h.Registry.Register(&pool.Provider{
		ProviderID: providerID, AssignedID: "legacy-mp", ReceiptPubkey: receiptPub,
		ReceiptPubkeyPrev: &pool.ReceiptPubkeyPrevious{
			Pubkey: bytes.Repeat([]byte{0x12}, ed25519.PublicKeySize), RotatedAt: time.Now().Add(-time.Hour), ExpiresAt: time.Now().Add(time.Hour),
		},
	}, nil); !registered {
		t.Fatal("register legacy live-pool identity")
	}
	if exists, err := store.BootstrapIdentityExists(context.Background(), providerID); err != nil || exists {
		t.Fatalf("legacy bootstrap identity exists=%v err=%v, want absent", exists, err)
	}
	if live, ok := h.Registry.Resolve(providerID, ""); !ok || !bytes.Equal(live.ReceiptPubkey, receiptPub) {
		t.Fatalf("legacy live-pool identity missing: ok=%v provider=%+v", ok, live)
	}

	conn, _, _, err := bearerDialer(bearer).Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial legacy bearer v2: %v", err)
	}
	defer conn.Close()
	initial := validAuthInitialWithFreshKey(t, providerID)
	initial["provider_receipt_public_key"] = base64.StdEncoding.EncodeToString(receiptPub)
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write legacy initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	if challenge.BootstrapIdentityPubkey != "" {
		t.Fatalf("legacy challenge exposed nonexistent bootstrap hint=%q", challenge.BootstrapIdentityPubkey)
	}
	writeAuthProofWithFields(t, conn, challenge, providerID, nil,
		signedIdentityProofFields(t, receiptPriv, providerID, challenge.AuthAttemptID, initial))
	response := readAuthResponse(t, conn)
	if response.Status != "accepted" {
		if response.Error != nil {
			t.Fatalf("legacy mp bearer response status=%q error=%+v", response.Status, *response.Error)
		}
		t.Fatalf("legacy mp bearer response=%+v", response)
	}
}

func TestInactiveBootstrapIdentityNeverFallsBackToLivePool(t *testing.T) {
	const providerID = "mp-00000000000000000000000000000013"
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open auth store: %v", err)
	}
	defer store.Close()
	h := newProviderHarnessWithServerOptions(t, store, []providerws.Option{
		providerws.WithIdentitySignatureStore(&fakeIdentitySignatureStore{}),
	}, func(cfg *config.Config) {
		cfg.Providers = nil
		cfg.Auth.RequireProviderTokens = true
		cfg.Auth.AllowTokenlessProvisionalBootstrap = true
		cfg.Tier2.RequireEncryptedLeg = true
	})
	defer h.HTTP.Close()
	durablePub, durablePriv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("durable keypair: %v", err)
	}
	mint := completeCredentialBootstrap(t, h.HTTP.URL, providerID, durablePub, durablePriv)
	if _, err := store.RevokeToken(context.Background(), mint.AssignedProviderToken[:12]); err != nil {
		t.Fatalf("revoke bootstrap bearer: %v", err)
	}
	poolPub, poolPriv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("pool keypair: %v", err)
	}
	h.Registry.Register(&pool.Provider{
		ProviderID: providerID, AssignedID: "inactive-bootstrap", ReceiptPubkey: poolPub,
		ReceiptPubkeyPrev: &pool.ReceiptPubkeyPrevious{
			Pubkey: bytes.Repeat([]byte{0x13}, ed25519.PublicKeySize), RotatedAt: time.Now().Add(-time.Hour), ExpiresAt: time.Now().Add(time.Hour),
		},
	}, nil)

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial inactive bootstrap identity: %v", err)
	}
	defer conn.Close()
	initial := validAuthInitialWithFreshKey(t, providerID)
	initial["provider_receipt_public_key"] = base64.StdEncoding.EncodeToString(poolPub)
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write inactive bootstrap initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	if challenge.BootstrapIdentityPubkey != "" {
		t.Fatalf("inactive bootstrap challenge hint=%q, want none", challenge.BootstrapIdentityPubkey)
	}
	writeAuthProofWithFields(t, conn, challenge, providerID, nil,
		signedIdentityProofFields(t, poolPriv, providerID, challenge.AuthAttemptID, initial))
	response := readAuthResponse(t, conn)
	if response.Status != "rejected" || response.Error == nil || response.Error.Code != "identity_signature_required" {
		t.Fatalf("inactive bootstrap fallback response=%+v", response)
	}
}

func TestCredentialBootstrapRejectsMissingDifferentAndReplayedReceiptProof(t *testing.T) {
	store, h := newCredentialBootstrapHarness(t, nil)

	t.Run("missing initial receipt key", func(t *testing.T) {
		initial := validAuthInitialWithFreshKey(t, "mp-00000000000000000000000000000009")
		initial["credential_bootstrap"] = true
		conn, br, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
		if err != nil {
			t.Fatalf("dial: %v", err)
		}
		defer conn.Close()
		if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
			t.Fatalf("write initial: %v", err)
		}
		code, reason := readCredentialBootstrapClose(t, conn, br)
		if code != providerws.CloseIdentitySignatureRequired || reason != "bootstrap_receipt_identity_required" {
			t.Fatalf("close=%d reason=%q", code, reason)
		}
	})

	t.Run("missing proof", func(t *testing.T) {
		pub, _, err := ed25519.GenerateKey(nil)
		if err != nil {
			t.Fatalf("keypair: %v", err)
		}
		const providerID = "mp-00000000000000000000000000000002"
		conn, challenge, _ := openCredentialBootstrap(t, h.HTTP.URL, providerID, pub)
		defer conn.Close()
		writeAuthProofWithFields(t, conn, challenge, providerID, nil, map[string]any{
			"credential_bootstrap": true,
		})
		response := readAuthResponse(t, conn)
		if response.Error == nil || response.Error.Code != "bootstrap_identity_proof_required" {
			t.Fatalf("response=%+v", response)
		}
		code, reason := readCredentialBootstrapClose(t, conn, nil)
		if code != providerws.CloseIdentitySignatureRequired || reason != "bootstrap_identity_proof_required" {
			t.Fatalf("close=%d reason=%q", code, reason)
		}
	})

	t.Run("different signing key", func(t *testing.T) {
		pub, _, err := ed25519.GenerateKey(nil)
		if err != nil {
			t.Fatalf("published keypair: %v", err)
		}
		_, attacker, err := ed25519.GenerateKey(nil)
		if err != nil {
			t.Fatalf("attacker keypair: %v", err)
		}
		const providerID = "mp-00000000000000000000000000000003"
		conn, challenge, initial := openCredentialBootstrap(t, h.HTTP.URL, providerID, pub)
		defer conn.Close()
		writeAuthProofWithFields(t, conn, challenge, providerID, nil,
			signedCredentialBootstrapProofFields(t, attacker, providerID, challenge, initial))
		response := readAuthResponse(t, conn)
		if response.Error == nil || response.Error.Code != "bootstrap_identity_proof_required" {
			t.Fatalf("response=%+v", response)
		}
		code, reason := readCredentialBootstrapClose(t, conn, nil)
		if code != providerws.CloseIdentitySignatureRequired || reason != "bootstrap_identity_proof_required" {
			t.Fatalf("close=%d reason=%q", code, reason)
		}
	})

	t.Run("proof replay against fresh challenge", func(t *testing.T) {
		pub, priv, err := ed25519.GenerateKey(nil)
		if err != nil {
			t.Fatalf("keypair: %v", err)
		}
		const providerID = "mp-00000000000000000000000000000004"
		first, firstChallenge, firstInitial := openCredentialBootstrap(t, h.HTTP.URL, providerID, pub)
		replayedFields := signedCredentialBootstrapProofFields(t, priv, providerID, firstChallenge, firstInitial)
		_ = first.Close()

		second, secondChallenge, _ := openCredentialBootstrap(t, h.HTTP.URL, providerID, pub)
		defer second.Close()
		writeAuthProofWithFields(t, second, secondChallenge, providerID, nil, replayedFields)
		response := readAuthResponse(t, second)
		if response.Error == nil || response.Error.Code != "bootstrap_identity_proof_required" {
			t.Fatalf("response=%+v", response)
		}
		code, reason := readCredentialBootstrapClose(t, second, nil)
		if code != providerws.CloseIdentitySignatureRequired || reason != "bootstrap_identity_proof_required" {
			t.Fatalf("close=%d reason=%q", code, reason)
		}
	})

	if got := h.Registry.Count(); got != 0 {
		t.Fatalf("rejected credential bootstraps registered %d providers", got)
	}
	if active, err := store.HasActiveTokenForProvider(context.Background(), "mp-00000000000000000000000000000004"); err != nil || active {
		t.Fatalf("replay created token: active=%v err=%v", active, err)
	}
}

func TestCredentialBootstrapSameKeyRecoversResponseLossButUsedTokenFailsClosed(t *testing.T) {
	const providerID = "mp-00000000000000000000000000000005"
	store, h := newCredentialBootstrapHarness(t, nil)
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("keypair: %v", err)
	}

	first := completeCredentialBootstrap(t, h.HTTP.URL, providerID, pub, priv)
	if first.AssignedProviderToken == "" {
		t.Fatal("first response omitted token")
	}
	// Simulate response/persistence loss: reconnect using only the receipt key.
	second := completeCredentialBootstrap(t, h.HTTP.URL, providerID, pub, priv)
	if second.AssignedProviderToken == "" || second.AssignedProviderToken == first.AssignedProviderToken {
		t.Fatalf("recovery token first=%q second=%q", first.AssignedProviderToken, second.AssignedProviderToken)
	}
	if _, valid, err := store.ValidateToken(context.Background(), first.AssignedProviderToken); err != nil || valid {
		t.Fatalf("replaced token valid=%v err=%v", valid, err)
	}
	if err := store.MarkTokenUsed(context.Background(), second.AssignedProviderToken); err != nil {
		t.Fatalf("mark recovered token used: %v", err)
	}

	conn, challenge, initial := openCredentialBootstrap(t, h.HTTP.URL, providerID, pub)
	defer conn.Close()
	writeAuthProofWithFields(t, conn, challenge, providerID, nil,
		signedCredentialBootstrapProofFields(t, priv, providerID, challenge, initial))
	code, reason := readCredentialBootstrapClose(t, conn, nil)
	if code != providerws.CloseInvalidToken || reason != "bootstrap_token_used" {
		t.Fatalf("used-token recovery close=%d reason=%q", code, reason)
	}
	if _, valid, err := store.ValidateToken(context.Background(), second.AssignedProviderToken); err != nil || !valid {
		t.Fatalf("used token was revoked or replaced: valid=%v err=%v", valid, err)
	}
}

func TestCredentialBootstrapBearerIsConfirmedOnlyAfterAcceptedBoundHello(t *testing.T) {
	const providerID = "mp-0000000000000000000000000000000a"
	store, h := newCredentialBootstrapHarness(t, func(cfg *config.Config) {
		cfg.Tier2.RequireEncryptedLeg = false
	})
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("keypair: %v", err)
	}
	first := completeCredentialBootstrap(t, h.HTTP.URL, providerID, pub, priv)

	// Bearer validation succeeds, but the hello binds a different provider ID.
	// The rejected session must not consume or permanently confirm the token.
	conn, br, _, err := bearerDialer(first.AssignedProviderToken).Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial rejected session: %v", err)
	}
	if err := wsutil.WriteClientText(conn, mustJSON(validHello("mp-0000000000000000000000000000000b"))); err != nil {
		t.Fatalf("write mismatched hello: %v", err)
	}
	code, reason := readCredentialBootstrapClose(t, conn, br)
	_ = conn.Close()
	if code != providerws.CloseInvalidToken || reason != "invalid_token" {
		t.Fatalf("mismatched hello close=%d reason=%q", code, reason)
	}
	records, err := store.ListTokens(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 || records[0].LastUsedAt.Valid {
		t.Fatalf("rejected hello consumed bootstrap token: %#v", records)
	}

	// Same-key recovery is still available because the rejected bearer did not
	// cross the admission boundary.
	second := completeCredentialBootstrap(t, h.HTTP.URL, providerID, pub, priv)
	if second.AssignedProviderToken == first.AssignedProviderToken {
		t.Fatal("response-loss recovery did not rotate the unused token")
	}

	// A provider-ID-bound v2 proof crosses the confirmation boundary before its
	// auth_response; observing acceptance therefore proves ownership is permanent.
	accepted, _, _, err := bearerDialer(second.AssignedProviderToken).Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial accepted session: %v", err)
	}
	acceptedInitial := validAuthInitialWithFreshKey(t, providerID)
	acceptedInitial["provider_receipt_public_key"] = base64.StdEncoding.EncodeToString(pub)
	if err := wsutil.WriteClientText(accepted, mustJSON(acceptedInitial)); err != nil {
		t.Fatalf("write accepted initial: %v", err)
	}
	acceptedChallenge := readAuthChallenge(t, accepted)
	writeAuthProofWithFields(t, accepted, acceptedChallenge, providerID, nil,
		signedIdentityProofFields(t, priv, providerID, acceptedChallenge.AuthAttemptID, acceptedInitial))
	acceptedResponse := readAuthResponse(t, accepted)
	if acceptedResponse.Status != "accepted" || acceptedResponse.AssignedID != acceptedChallenge.AssignedID {
		t.Fatalf("accepted durable bearer response=%+v", acceptedResponse)
	}
	_ = accepted.Close()

	probe, challenge, initial := openCredentialBootstrap(t, h.HTTP.URL, providerID, pub)
	defer probe.Close()
	writeAuthProofWithFields(t, probe, challenge, providerID, nil,
		signedCredentialBootstrapProofFields(t, priv, providerID, challenge, initial))
	code, reason = readCredentialBootstrapClose(t, probe, nil)
	if code != providerws.CloseInvalidToken || reason != "bootstrap_token_used" {
		t.Fatalf("confirmed-token recovery close=%d reason=%q", code, reason)
	}
}

func TestCredentialBootstrapConfirmationFailureNeverRegistersOrAccepts(t *testing.T) {
	const providerID = "mp-0000000000000000000000000000000c"
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open auth store: %v", err)
	}
	defer store.Close()
	failing := bootstrapMarkFailingStore{Store: store}
	h := newProviderHarnessWithServerOptions(t, failing, nil, func(cfg *config.Config) {
		cfg.Providers = nil
		cfg.Auth.RequireProviderTokens = true
		cfg.Auth.AllowTokenlessProvisionalBootstrap = true
		cfg.Tier2.RequireEncryptedLeg = false
	})
	defer h.HTTP.Close()
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("keypair: %v", err)
	}
	mint := completeCredentialBootstrap(t, h.HTTP.URL, providerID, pub, priv)

	conn, _, _, err := bearerDialer(mint.AssignedProviderToken).Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	initial := validAuthInitialWithFreshKey(t, providerID)
	initial["provider_receipt_public_key"] = base64.StdEncoding.EncodeToString(pub)
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	writeAuthProofWithFields(t, conn, challenge, providerID, nil,
		signedIdentityProofFields(t, priv, providerID, challenge.AuthAttemptID, initial))
	code, reason := readCredentialBootstrapClose(t, conn, nil)
	if code != providerws.CloseInvalidToken || reason != "invalid_token" {
		t.Fatalf("confirmation failure close=%d reason=%q", code, reason)
	}
	if got := h.Registry.Count(); got != 0 {
		t.Fatalf("confirmation failure registered %d providers", got)
	}
	records, err := store.ListTokens(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 || records[0].LastUsedAt.Valid {
		t.Fatalf("confirmation failure consumed bootstrap token: %#v", records)
	}
}

func TestCredentialBootstrapRejectsBearerPinnedAndBoundDifferentKey(t *testing.T) {
	t.Run("bearer", func(t *testing.T) {
		store, h := newCredentialBootstrapHarness(t, nil)
		const providerID = "mp-00000000000000000000000000000006"
		_, bearer, err := store.IssueToken(context.Background(), providerID, "bootstrap-bearer")
		if err != nil {
			t.Fatalf("issue bearer: %v", err)
		}
		pub, _, err := ed25519.GenerateKey(nil)
		if err != nil {
			t.Fatalf("keypair: %v", err)
		}
		initial := credentialBootstrapInitial(t, providerID, pub)
		conn, br, _, err := bearerDialer(bearer).Dial(context.Background(), wsURL(h.HTTP.URL))
		if err != nil {
			t.Fatalf("dial: %v", err)
		}
		defer conn.Close()
		if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
			t.Fatalf("write initial: %v", err)
		}
		code, reason := readCredentialBootstrapClose(t, conn, br)
		if code != providerws.CloseInvalidToken || reason != "invalid_token" {
			t.Fatalf("close=%d reason=%q", code, reason)
		}
	})

	t.Run("pinned", func(t *testing.T) {
		const providerID = "mp-00000000000000000000000000000008"
		_, h := newCredentialBootstrapHarness(t, func(cfg *config.Config) {
			cfg.Providers = []config.ProviderConfig{{
				ProviderID:  providerID,
				EndpointURL: "https://m4.streamvc.live",
				DisplayName: "M4 test provider",
			}}
		})
		pub, _, err := ed25519.GenerateKey(nil)
		if err != nil {
			t.Fatalf("keypair: %v", err)
		}
		initial := credentialBootstrapInitial(t, providerID, pub)
		code, reason := sendHelloExpectClose(t, h.HTTP.URL, initial)
		if code != providerws.CloseInvalidToken || reason != "invalid_token" {
			t.Fatalf("close=%d reason=%q", code, reason)
		}
	})

	t.Run("bound different key", func(t *testing.T) {
		_, h := newCredentialBootstrapHarness(t, nil)
		const providerID = "mp-00000000000000000000000000000007"
		firstPub, firstPriv, err := ed25519.GenerateKey(nil)
		if err != nil {
			t.Fatalf("first keypair: %v", err)
		}
		_ = completeCredentialBootstrap(t, h.HTTP.URL, providerID, firstPub, firstPriv)
		secondPub, secondPriv, err := ed25519.GenerateKey(nil)
		if err != nil {
			t.Fatalf("second keypair: %v", err)
		}
		conn, challenge, initial := openCredentialBootstrap(t, h.HTTP.URL, providerID, secondPub)
		defer conn.Close()
		writeAuthProofWithFields(t, conn, challenge, providerID, nil,
			signedCredentialBootstrapProofFields(t, secondPriv, providerID, challenge, initial))
		code, reason := readCredentialBootstrapClose(t, conn, nil)
		if code != providerws.CloseInvalidToken || reason != "bootstrap_identity_mismatch" {
			t.Fatalf("close=%d reason=%q", code, reason)
		}
	})
}

func newCredentialBootstrapHarness(t *testing.T, mutate func(*config.Config)) (*auth.Store, providerHarness) {
	t.Helper()
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open auth store: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	h := newProviderHarnessWithServerOptions(t, store, nil, func(cfg *config.Config) {
		cfg.Providers = nil
		cfg.Auth.RequireProviderTokens = true
		cfg.Auth.AllowTokenlessProvisionalBootstrap = true
		cfg.Tier2.RequireEncryptedLeg = true
		if mutate != nil {
			mutate(cfg)
		}
	})
	t.Cleanup(h.HTTP.Close)
	return store, h
}

func credentialBootstrapInitial(t *testing.T, providerID string, receiptPub ed25519.PublicKey) map[string]any {
	t.Helper()
	initial := validAuthInitialWithFreshKey(t, providerID)
	initial["credential_bootstrap"] = true
	initial["provider_receipt_public_key"] = base64.StdEncoding.EncodeToString(receiptPub)
	return initial
}

func openCredentialBootstrap(t *testing.T, serverURL, providerID string, receiptPub ed25519.PublicKey) (net.Conn, providerws.AuthChallenge, map[string]any) {
	t.Helper()
	initial := credentialBootstrapInitial(t, providerID, receiptPub)
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(serverURL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		_ = conn.Close()
		t.Fatalf("write initial: %v", err)
	}
	return conn, readAuthChallenge(t, conn), initial
}

func completeCredentialBootstrap(t *testing.T, serverURL, providerID string, receiptPub ed25519.PublicKey, receiptPriv ed25519.PrivateKey) providerws.AuthResponse {
	t.Helper()
	conn, challenge, initial := openCredentialBootstrap(t, serverURL, providerID, receiptPub)
	defer conn.Close()
	writeAuthProofWithFields(t, conn, challenge, providerID, nil,
		signedCredentialBootstrapProofFields(t, receiptPriv, providerID, challenge, initial))
	response := readAuthResponse(t, conn)
	if response.Status != "accepted" {
		t.Fatalf("bootstrap response=%+v", response)
	}
	return response
}

func readCredentialBootstrapClose(t *testing.T, conn net.Conn, buffered *bufio.Reader) (gobwas.StatusCode, string) {
	t.Helper()
	var source io.Reader = conn
	if buffered != nil {
		source = buffered
	}
	frame, err := gobwas.ReadFrame(source)
	if err != nil {
		t.Fatalf("read credential bootstrap close: %v", err)
	}
	if frame.Header.OpCode != gobwas.OpClose {
		t.Fatalf("credential bootstrap opcode=%v, want close", frame.Header.OpCode)
	}
	return gobwas.ParseCloseFrameData(frame.Payload)
}

func TestAutotuneCatalogAdmissionRejectsPartialAndMismatchedMetadata(t *testing.T) {
	catalog := mustAutotuneCatalog(t)
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithAutotuneHelloGate(catalog, stubAutotuneEvidence{ok: false}),
	}, func(*config.Config) {})
	defer h.HTTP.Close()

	tests := map[string]func(map[string]any){
		"partial": func(hello map[string]any) { hello["catalog_release_id"] = catalog.Version },
		"release": func(hello map[string]any) {
			addCatalogAdmissionMetadata(t, hello, catalog)
			hello["catalog_release_id"] = "other"
		},
		"policy": func(hello map[string]any) {
			addCatalogAdmissionMetadata(t, hello, catalog)
			hello["catalog_policy_version"] = "other"
		},
		"digest": func(hello map[string]any) {
			addCatalogAdmissionMetadata(t, hello, catalog)
			hello["catalog_candidate_sha256"] = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		},
		"signer": func(hello map[string]any) {
			addCatalogAdmissionMetadata(t, hello, catalog)
			hello["catalog_signer_key_id"] = "other"
		},
		"row": func(hello map[string]any) {
			addCatalogAdmissionMetadata(t, hello, catalog)
			hello["catalog_row_identity"] = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		},
	}
	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			hello := validHello("m4-anon")
			hello["model_id"] = "mlx-community/Llama-3.2-3B-Instruct-4bit"
			mutate(hello)
			code, reason := sendHelloExpectClose(t, h.HTTP.URL, hello)
			if code != providerws.CloseInvalidHello || reason != "catalog_incompatible" {
				t.Fatalf("code=%d reason=%q", code, reason)
			}
		})
	}
}

func TestAutotuneCatalogAdmissionWorksWithDefaultDisabledEvidenceGate(t *testing.T) {
	catalog := mustAutotuneCatalog(t)
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithAutotuneCatalog(catalog),
	}, func(cfg *config.Config) {
		if cfg.ProofOfWeights.RequireAutotuneHelloGate {
			t.Fatal("test requires the default-disabled evidence gate")
		}
	})
	defer h.HTTP.Close()

	hello := validHello("m4-anon")
	hello["model_id"] = "mlx-community/Llama-3.2-3B-Instruct-4bit"
	addCatalogAdmissionMetadata(t, hello, catalog)
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(hello)); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, _, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read ack: %v", err)
	}
	var ack map[string]any
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("ack json: %v", err)
	}
	if ack["type"] != "hello_ack" || ack["catalog_compatible"] != true || ack["catalog_release_id"] != catalog.Version {
		t.Fatalf("catalog admission ack = %+v", ack)
	}
}

func TestAutotuneAdmissionCapObservedWhenEvidenceGateDisabled(t *testing.T) {
	catalog := mustAutotuneCatalog(t)
	evidence := autotune.VerifiedEvidence{
		ProbeProtocol:          "spec-023-harmony-stream.v2",
		BinaryVersion:          "0.1.0",
		ExecutableSHA256:       "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
		CandidateCatalogSHA256: catalog.SHA256,
		Benchmarks: []autotune.VerifiedBenchmark{
			{
				ModelKey:               "small",
				ModelID:                "mlx-community/Llama-3.2-3B-Instruct-4bit",
				SustainedTPS:           20,
				TTFTMS:                 1000,
				ArtifactSHA256:         "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a",
				CandidateCatalogSHA256: catalog.SHA256,
				CandidateRowIdentity:   mustAutotuneRowIdentity(t, catalog, "small"),
			},
		},
	}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithAutotuneHelloGate(catalog, stubAutotuneEvidence{evidence: evidence, ok: true}),
	}, func(cfg *config.Config) {
		if cfg.ProofOfWeights.RequireAutotuneHelloGate {
			t.Fatal("test requires the default-disabled evidence gate")
		}
	})
	defer h.HTTP.Close()

	hello := validHello("m4-anon")
	hello["model_id"] = "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
	addCatalogAdmissionMetadata(t, hello, catalog)
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(hello)); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, _, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read ack: %v", err)
	}
	var ack map[string]any
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("ack json: %v", err)
	}
	if ack["type"] != "hello_ack" {
		t.Fatalf("ack type = %v", ack["type"])
	}
	provider, ok := h.Registry.Resolve("m4-anon", ack["assigned_id"].(string))
	if !ok {
		t.Fatal("provider not registered")
	}
	if provider.MaxAdmittedModelKey != "small" || provider.MaxAdmittedMinRAMGB != 4 {
		t.Fatalf("observed admission cap = key %q ram %d, want small/4", provider.MaxAdmittedModelKey, provider.MaxAdmittedMinRAMGB)
	}
	if provider.AdmissionCeilingExcluded || !provider.RoutingEligible() {
		t.Fatalf("gate-off admission cap observation must remain routing-observe-only: %+v", provider)
	}
}

func TestAutotuneAdmissionCapV2GateOffUsesSingleObserveLookup(t *testing.T) {
	catalog := mustAutotuneCatalog(t)
	evidence := autotune.VerifiedEvidence{
		ProbeProtocol:          "spec-023-harmony-stream.v2",
		BinaryVersion:          "0.1.0",
		ExecutableSHA256:       "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
		CandidateCatalogSHA256: catalog.SHA256,
		Benchmarks: []autotune.VerifiedBenchmark{
			{
				ModelKey:               "small",
				ModelID:                "mlx-community/Llama-3.2-3B-Instruct-4bit",
				SustainedTPS:           20,
				TTFTMS:                 1000,
				ArtifactSHA256:         "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a",
				CandidateCatalogSHA256: catalog.SHA256,
				CandidateRowIdentity:   mustAutotuneRowIdentity(t, catalog, "small"),
			},
		},
	}
	store := &sequencedAutotuneEvidence{responses: []stubAutotuneEvidence{{evidence: evidence, ok: true}}}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithAutotuneHelloGate(catalog, store),
	}, func(cfg *config.Config) {
		if cfg.ProofOfWeights.RequireAutotuneHelloGate {
			t.Fatal("test requires the default-disabled evidence gate")
		}
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	initial := validAuthInitialWithFreshKey(t, "m4-anon")
	initial["model_id"] = "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
	addCatalogAdmissionMetadata(t, initial, catalog)
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write auth initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	writeAuthProof(t, conn, challenge, "m4-anon", nil)
	response := readAuthResponse(t, conn)
	if response.Status != "accepted" || response.AssignedID != challenge.AssignedID {
		t.Fatalf("auth response = %+v", response)
	}
	provider, ok := h.Registry.Resolve("m4-anon", response.AssignedID)
	if !ok {
		t.Fatal("provider not registered")
	}
	if provider.MaxAdmittedModelKey != "small" || provider.MaxAdmittedMinRAMGB != 4 {
		t.Fatalf("observed admission cap = key %q ram %d, want small/4", provider.MaxAdmittedModelKey, provider.MaxAdmittedMinRAMGB)
	}
	if provider.AdmissionCeilingExcluded || !provider.RoutingEligible() {
		t.Fatalf("gate-off v2 admission cap observation must remain routing-observe-only: %+v", provider)
	}
	if got := store.callCount(); got != 1 {
		t.Fatalf("evidence lookups = %d, want 1", got)
	}
}

func TestAutotuneCatalogAdmissionLegacyBridgeIsExplicitlyEnforced(t *testing.T) {
	catalog := mustAutotuneCatalog(t)
	tests := []struct {
		name             string
		enforced         bool
		bridgeDeadline   time.Time
		wantMode         string
		wantBuyerServing bool
	}{
		{
			name:             "bridge permits metadata-free provider during rollout",
			bridgeDeadline:   time.Now().Add(time.Hour),
			wantMode:         "legacy_bridge",
			wantBuyerServing: true,
		},
		{
			name:           "expired bridge excludes metadata-free provider",
			bridgeDeadline: time.Now().Add(-time.Minute),
			wantMode:       "legacy",
		},
		{
			name:     "strict enforcement excludes metadata-free provider",
			enforced: true,
			wantMode: "legacy",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
				providerws.WithAutotuneCatalog(catalog),
				providerws.WithAutotuneCatalogEnforcement(tt.enforced, tt.bridgeDeadline),
			}, func(*config.Config) {})
			defer h.HTTP.Close()

			conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
			if err != nil {
				t.Fatalf("dial: %v", err)
			}
			defer conn.Close()
			if err := wsutil.WriteClientText(conn, mustJSON(validHello("m4-anon"))); err != nil {
				t.Fatalf("write hello: %v", err)
			}
			payload, _, err := wsutil.ReadServerData(conn)
			if err != nil {
				t.Fatalf("read ack: %v", err)
			}
			var ack map[string]any
			if err := json.Unmarshal(payload, &ack); err != nil {
				t.Fatalf("ack json: %v", err)
			}
			provider, ok := h.Registry.Resolve("m4-anon", ack["assigned_id"].(string))
			if !ok {
				t.Fatal("metadata-free provider not registered")
			}
			if provider.CatalogAdmissionMode != tt.wantMode {
				t.Fatalf("CatalogAdmissionMode = %q, want %q", provider.CatalogAdmissionMode, tt.wantMode)
			}
			if got := provider.ServingCapable(); got != tt.wantBuyerServing {
				t.Fatalf("ServingCapable() = %v, want %v", got, tt.wantBuyerServing)
			}
			if got := provider.RoutingEligible(); got != tt.wantBuyerServing {
				t.Fatalf("RoutingEligible() = %v, want %v", got, tt.wantBuyerServing)
			}
		})
	}
}

func TestAutotuneCatalogAdmissionDeadlineExpiresConnectedBridgeSession(t *testing.T) {
	catalog := mustAutotuneCatalog(t)
	deadline := time.Now().Add(time.Second)
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithAutotuneCatalog(catalog),
		providerws.WithAutotuneCatalogEnforcement(false, deadline),
	}, func(*config.Config) {})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(validHello("bridge-expiry"))); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, _, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read ack: %v", err)
	}
	var ack map[string]any
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("ack json: %v", err)
	}
	assignedID, _ := ack["assigned_id"].(string)
	provider, ok := h.Registry.Resolve("bridge-expiry", assignedID)
	if !ok || provider.CatalogAdmissionMode != "legacy_bridge" {
		t.Fatalf("initial bridge provider = (%v, %q), want registered legacy_bridge", ok, provider.CatalogAdmissionMode)
	}

	testDeadline := time.Now().Add(3 * time.Second)
	for {
		provider, ok = h.Registry.Resolve("bridge-expiry", assignedID)
		if ok && provider.CatalogAdmissionMode == "legacy" {
			break
		}
		if time.Now().After(testDeadline) {
			t.Fatalf("connected bridge session did not expire: provider=(%v, %q)", ok, provider.CatalogAdmissionMode)
		}
		time.Sleep(10 * time.Millisecond)
	}
	if provider.RoutingEligible() || provider.ServingCapable() {
		t.Fatal("deadline-expired connected session must lose buyer routing and serving capacity")
	}
}

func TestAutotuneCatalogAdmissionAcceptsRecognizedPreviousReleaseWithStableRow(t *testing.T) {
	current := mustAutotuneCatalog(t)
	previous, err := autotune.ParseCatalog(bytes.Replace(current.RawJSON, []byte(`"version":"test"`), []byte(`"version":"previous"`), 1))
	if err != nil {
		t.Fatalf("ParseCatalog(previous): %v", err)
	}
	previous.SignerKeyID = current.SignerKeyID
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithAutotuneCatalog(current, previous),
	}, func(*config.Config) {})
	defer h.HTTP.Close()

	hello := validHello("m4-anon")
	hello["model_id"] = "mlx-community/Llama-3.2-3B-Instruct-4bit"
	addCatalogAdmissionMetadata(t, hello, previous)
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(hello)); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, _, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read ack: %v", err)
	}
	var ack map[string]any
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("ack json: %v", err)
	}
	if ack["catalog_compatible"] != true || ack["catalog_release_id"] != current.Version {
		t.Fatalf("previous release compatibility ack = %+v", ack)
	}
	provider, ok := h.Registry.Resolve("m4-anon", ack["assigned_id"].(string))
	if !ok {
		t.Fatal("previous-release provider not registered")
	}
	if provider.CatalogAdmissionMode != "previous" || provider.CatalogReleaseID != previous.Version || provider.CandidateCatalogSHA256 != previous.SHA256 || provider.CandidateRowIdentity == "" {
		t.Fatalf("previous-release catalog admission evidence = %+v", provider)
	}
}

func TestAutotuneCatalogAdmissionRejectsPreviousReleaseWithChangedSelectedRow(t *testing.T) {
	current := mustAutotuneCatalog(t)
	previousBytes := bytes.Replace(current.RawJSON, []byte(`"version":"test"`), []byte(`"version":"previous"`), 1)
	previousBytes = bytes.Replace(previousBytes, []byte(`"min_ram_gb":4`), []byte(`"min_ram_gb":5`), 1)
	previous, err := autotune.ParseCatalog(previousBytes)
	if err != nil {
		t.Fatalf("ParseCatalog(previous): %v", err)
	}
	previous.SignerKeyID = current.SignerKeyID
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithAutotuneCatalog(current, previous),
	}, func(*config.Config) {})
	defer h.HTTP.Close()
	hello := validHello("m4-anon")
	hello["model_id"] = "mlx-community/Llama-3.2-3B-Instruct-4bit"
	addCatalogAdmissionMetadata(t, hello, previous)
	code, reason := sendHelloExpectClose(t, h.HTTP.URL, hello)
	if code != providerws.CloseInvalidHello || reason != "catalog_incompatible" {
		t.Fatalf("code=%d reason=%q", code, reason)
	}
}

func TestAutotuneCatalogAdmissionRejectsPreviousReleaseWithChangedSelectedRowPolicy(t *testing.T) {
	for _, tc := range []struct {
		name   string
		policy string
	}{
		{name: "draft candidates", policy: `,"draft_candidates":[{"draft_model":"mlx-community/draft","draft_model_artifact_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]`},
		{name: "workload profiles", policy: `,"workload_profiles":{"short_chat":{"8gb":{"status":"no_winner"}}}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			current := mustAutotuneCatalog(t)
			previousBytes := bytes.Replace(current.RawJSON, []byte(`"version":"test"`), []byte(`"version":"previous"`), 1)
			previousBytes = bytes.Replace(previousBytes, []byte(`"runtime_status":"recommendable"}`), []byte(`"runtime_status":"recommendable"`+tc.policy+`}`), 1)
			previous, err := autotune.ParseCatalog(previousBytes)
			if err != nil {
				t.Fatalf("ParseCatalog(previous): %v", err)
			}
			previous.SignerKeyID = current.SignerKeyID
			h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
				providerws.WithAutotuneCatalog(current, previous),
			}, func(*config.Config) {})
			defer h.HTTP.Close()
			hello := validHello("m4-anon")
			hello["model_id"] = "mlx-community/Llama-3.2-3B-Instruct-4bit"
			addCatalogAdmissionMetadata(t, hello, previous)
			code, reason := sendHelloExpectClose(t, h.HTTP.URL, hello)
			if code != providerws.CloseInvalidHello || reason != "catalog_incompatible" {
				t.Fatalf("code=%d reason=%q", code, reason)
			}
		})
	}
}

func TestAutotuneCatalogAdmissionRejectsPermanentlyTombstonedPreviousRelease(t *testing.T) {
	current := mustAutotuneCatalog(t)
	previousBytes := bytes.Replace(
		current.RawJSON,
		[]byte(`"version":"test"`),
		[]byte(`"version":"published-2026-07-07-p2-qwen3-8b"`),
		1,
	)
	previous, err := autotune.ParseCatalog(previousBytes)
	if err != nil {
		t.Fatalf("ParseCatalog(previous): %v", err)
	}
	previous.SignerKeyID = current.SignerKeyID
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithAutotuneCatalog(current, previous),
	}, func(*config.Config) {})
	defer h.HTTP.Close()
	hello := validHello("m4-anon")
	hello["model_id"] = "mlx-community/Llama-3.2-3B-Instruct-4bit"
	addCatalogAdmissionMetadata(t, hello, previous)
	code, reason := sendHelloExpectClose(t, h.HTTP.URL, hello)
	if code != providerws.CloseInvalidHello || reason != "catalog_incompatible" {
		t.Fatalf("code=%d reason=%q", code, reason)
	}
}

func TestAutotuneCatalogAdmissionV2ExactReleaseIsAcknowledged(t *testing.T) {
	catalog := mustAutotuneCatalog(t)
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithAutotuneCatalog(catalog),
	}, func(*config.Config) {})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	initial := validAuthInitialWithFreshKey(t, "m4-anon")
	initial["model_id"] = "mlx-community/Llama-3.2-3B-Instruct-4bit"
	addCatalogAdmissionMetadata(t, initial, catalog)
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write auth initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	writeAuthProof(t, conn, challenge, "m4-anon", nil)
	response := readAuthResponse(t, conn)
	if response.Status != "accepted" || !response.CatalogCompatible || response.CatalogReleaseID != catalog.Version || response.CandidateCatalogSHA256 != catalog.SHA256 {
		t.Fatalf("auth response = %+v", response)
	}
}

func mustAutotuneCatalog(t *testing.T) *autotune.Catalog {
	t.Helper()
	catalog, err := autotune.ParseCatalog([]byte(`{
		"version":"test",
		"generated_at":"2026-07-08T00:00:00Z",
		"source":"operator_curated_autotune_candidate_catalog",
		"policy_version":"autotune-policy-v1",
		"rows":{
			"small":{"model_id":"mlx-community/Llama-3.2-3B-Instruct-4bit","model_revision":"7f0dc925e0d0afb0322d96f9255cfddf2ba5636e","model_sha256":"3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a","min_ram_gb":4,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":15,"max_4k_ttft_ms":2500},"runtime_status":"recommendable"},
			"large":{"model_id":"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit","model_revision":"6e302ea604ad9ab206367e2c501d1571023e7b6d","model_sha256":"10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0","min_ram_gb":28,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":20,"max_4k_ttft_ms":3000},"runtime_status":"recommendable"}
		}
	}`))
	if err != nil {
		t.Fatalf("ParseCatalog: %v", err)
	}
	catalog.SignerKeyID = "test-key"
	return catalog
}

func addCatalogAdmissionMetadata(t *testing.T, message map[string]any, catalog *autotune.Catalog) {
	t.Helper()
	modelID, _ := message["model_id"].(string)
	key, _, ok := catalog.HighestClaimedTier(modelID)
	if !ok {
		t.Fatalf("catalog row for %q", modelID)
	}
	rowIdentity, ok := catalog.RowIdentity(key)
	if !ok {
		t.Fatalf("catalog row identity for %q", key)
	}
	message["catalog_release_id"] = catalog.Version
	message["catalog_policy_version"] = catalog.PolicyVersion
	message["catalog_candidate_sha256"] = catalog.SHA256
	message["catalog_signer_key_id"] = catalog.SignerKeyID
	message["catalog_row_identity"] = rowIdentity
}

func mustAutotuneRowIdentity(t *testing.T, catalog *autotune.Catalog, key string) string {
	t.Helper()
	rowIdentity, ok := catalog.RowIdentity(key)
	if !ok {
		t.Fatalf("catalog row identity for %q", key)
	}
	return rowIdentity
}
