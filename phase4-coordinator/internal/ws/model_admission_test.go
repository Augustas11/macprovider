package ws_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

func TestModelAdmissionOfferSubmitAndStatusStayNonEarning(t *testing.T) {
	h, bearer, priv := newModelAdmissionHarness(t, "provider-byom-a")
	defer h.HTTP.Close()

	candidateID := stableModelAdmissionCandidateID("a")
	request := signedModelAdmissionOffer(t, "provider-byom-a", candidateID, "ollama:qwen3-8b", priv, nil)
	status, body := postModelAdmissionOffer(t, h.HTTP.URL, bearer, request)
	if status != http.StatusOK {
		t.Fatalf("status=%d body=%s", status, body)
	}
	object := decodeMap(t, body)
	if object["schema"] != "model_admission_status.v1" ||
		object["admission_state"] != "offer_submitted" ||
		object["admission_state_source"] != "coordinator" ||
		object["state_observed_at"] == nil ||
		object["coordinator_event_id"] == nil {
		t.Fatalf("unexpected offer response: %#v", object)
	}
	guidance := object["provider_guidance"].(map[string]any)
	if guidance["next_action"] != "wait_for_coordinator" ||
		guidance["earning_path_class"] != "no_earning_path_in_v0_1" {
		t.Fatalf("unexpected guidance: %#v", guidance)
	}
	allowed := object["allowed_next_states"].([]any)
	if len(allowed) != 7 || allowed[0] != "offer_rejected" {
		t.Fatalf("unexpected allowed transitions: %#v", allowed)
	}
	if _, leaked := object["earning_eligible"]; leaked {
		t.Fatalf("status envelope leaked non-spec economics field: %#v", object)
	}

	status, body = getModelAdmissionStatus(t, h.HTTP.URL, bearer, candidateID)
	if status != http.StatusOK {
		t.Fatalf("status readback=%d body=%s", status, body)
	}
	readback := decodeMap(t, body)
	if readback["admission_state"] != "offer_submitted" ||
		readback["coordinator_event_id"] == nil ||
		readback["provider_id"] != "provider-byom-a" {
		t.Fatalf("unexpected status readback: %#v", readback)
	}
}

func TestModelAdmissionWithdrawalSubmitReplayConflictAndStatus(t *testing.T) {
	h, bearer, priv := newModelAdmissionHarness(t, "provider-byom-a")
	defer h.HTTP.Close()

	candidateID := stableModelAdmissionCandidateID("z")
	offer := signedModelAdmissionOffer(t, "provider-byom-a", candidateID, "ollama:qwen3-8b", priv, nil)
	if status, body := postModelAdmissionOffer(t, h.HTTP.URL, bearer, offer); status != http.StatusOK {
		t.Fatalf("offer status=%d body=%s", status, body)
	}
	withdrawal := signedModelAdmissionWithdrawal(t, "provider-byom-a", candidateID, "ollama:qwen3-8b", priv, map[string]any{
		"idempotency_key": "withdraw_request_replay",
		"nonce":           "withdraw_nonce_replay",
		"reason_code":     "provider_requested",
	})
	status, body := postModelAdmissionWithdrawal(t, h.HTTP.URL, bearer, withdrawal)
	if status != http.StatusOK {
		t.Fatalf("withdraw status=%d body=%s", status, body)
	}
	object := decodeMap(t, body)
	if object["schema"] != "model_admission_withdraw.v1" ||
		object["previous_admission_state"] != "offer_submitted" ||
		object["resulting_admission_state"] != "withdrawn" ||
		object["reason_code"] != "provider_requested" ||
		object["coordinator_event_id"] == "" {
		t.Fatalf("unexpected withdrawal response: %#v", object)
	}
	guidance := object["provider_guidance"].(map[string]any)
	if guidance["next_action"] != "submit_offer" ||
		guidance["transition_reason_code"] != "provider_requested" ||
		guidance["earning_path_class"] != "no_earning_path_in_v0_1" {
		t.Fatalf("unexpected withdrawal guidance: %#v", guidance)
	}
	firstEventID := object["coordinator_event_id"]
	status, body = postModelAdmissionWithdrawal(t, h.HTTP.URL, bearer, withdrawal)
	if status != http.StatusOK {
		t.Fatalf("withdraw replay status=%d body=%s", status, body)
	}
	if decodeMap(t, body)["coordinator_event_id"] != firstEventID {
		t.Fatalf("idempotent withdrawal appended new event: %s", body)
	}
	conflict := signedModelAdmissionWithdrawal(t, "provider-byom-a", candidateID, "ollama:qwen3-8b", priv, map[string]any{
		"idempotency_key": "withdraw_request_replay",
		"nonce":           "withdraw_nonce_replay",
		"reason_code":     "wrong_model",
	})
	if status, _ := postModelAdmissionWithdrawal(t, h.HTTP.URL, bearer, conflict); status != http.StatusConflict {
		t.Fatalf("conflicting withdrawal status=%d, want 409", status)
	}
	status, body = getModelAdmissionStatus(t, h.HTTP.URL, bearer, candidateID)
	if status != http.StatusOK {
		t.Fatalf("withdrawn status readback=%d body=%s", status, body)
	}
	readback := decodeMap(t, body)
	if readback["admission_state"] != "withdrawn" {
		t.Fatalf("withdrawn status readback=%#v", readback)
	}

	sameEvidence := signedModelAdmissionOffer(t, "provider-byom-a", candidateID, "ollama:qwen3-8b", priv, map[string]any{
		"idempotency_key": "request_reoffer_same_evidence",
		"nonce":           "nonce_reoffer_same_evidence",
	})
	if status, _ := postModelAdmissionOffer(t, h.HTTP.URL, bearer, sameEvidence); status != http.StatusConflict {
		t.Fatalf("same-evidence re-offer after withdrawal status=%d, want 409", status)
	}
	freshEvidence := signedModelAdmissionOffer(t, "provider-byom-a", candidateID, "ollama:qwen3-8b", priv, map[string]any{
		"idempotency_key":            "request_reoffer_fresh_evidence",
		"nonce":                      "nonce_reoffer_fresh_evidence",
		"evaluation_digest_sha256":   stringsOf("e", 64),
		"discovery_digest_sha256":    stringsOf("f", 64),
		"requested_disclosure_class": "catalog_binding_requested",
	})
	if status, body := postModelAdmissionOffer(t, h.HTTP.URL, bearer, freshEvidence); status != http.StatusOK {
		t.Fatalf("fresh-evidence re-offer after withdrawal status=%d body=%s", status, body)
	}
}

func TestModelAdmissionWithdrawalRejectsInvalidTransitionAndTupleDrift(t *testing.T) {
	h, bearer, priv := newModelAdmissionHarness(t, "provider-byom-a")
	defer h.HTTP.Close()

	noOffer := signedModelAdmissionWithdrawal(t, "provider-byom-a", stableModelAdmissionCandidateID("d"), "ollama:qwen3-8b", priv, nil)
	if status, _ := postModelAdmissionWithdrawal(t, h.HTTP.URL, bearer, noOffer); status != http.StatusConflict {
		t.Fatalf("withdraw without active offer status=%d, want 409", status)
	}
	candidateID := stableModelAdmissionCandidateID("e")
	offer := signedModelAdmissionOffer(t, "provider-byom-a", candidateID, "ollama:qwen3-8b", priv, nil)
	if status, body := postModelAdmissionOffer(t, h.HTTP.URL, bearer, offer); status != http.StatusOK {
		t.Fatalf("offer status=%d body=%s", status, body)
	}
	drift := signedModelAdmissionWithdrawal(t, "provider-byom-a", candidateID, "ollama:different", priv, map[string]any{
		"idempotency_key": "withdraw_request_drift",
		"nonce":           "withdraw_nonce_drift",
	})
	if status, _ := postModelAdmissionWithdrawal(t, h.HTTP.URL, bearer, drift); status != http.StatusConflict {
		t.Fatalf("tuple-drift withdrawal status=%d, want 409", status)
	}
	unknownField := signedModelAdmissionWithdrawal(t, "provider-byom-a", candidateID, "ollama:qwen3-8b", priv, map[string]any{
		"idempotency_key": "withdraw_request_unknown",
		"nonce":           "withdraw_nonce_unknown",
	})
	unknownField["previous_admission_state"] = "offer_submitted"
	if status, _ := postModelAdmissionWithdrawal(t, h.HTTP.URL, bearer, unknownField); status != http.StatusBadRequest {
		t.Fatalf("client-provided previous state status=%d, want 400", status)
	}
	missingNullableCatalog := signedModelAdmissionWithdrawal(t, "provider-byom-a", candidateID, "ollama:qwen3-8b", priv, map[string]any{
		"idempotency_key": "withdraw_request_missing_catalog",
		"nonce":           "withdraw_nonce_missing_catalog",
	})
	delete(missingNullableCatalog, "catalog_model_key")
	if status, _ := postModelAdmissionWithdrawal(t, h.HTTP.URL, bearer, missingNullableCatalog); status != http.StatusBadRequest {
		t.Fatalf("missing catalog_model_key status=%d, want 400", status)
	}
}

func TestModelAdmissionStatusIsScopedByProviderAndCandidate(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	_, bearerA, privA := bindAdmissionIdentityForTest(t, store, "provider-byom-a")
	_, bearerB, _ := bindAdmissionIdentityForTest(t, store, "provider-byom-b")
	h := newProviderHarnessWithServerOptions(t, store, []providerws.Option{
		providerws.WithModelAdmissionStore(providerws.NewMemoryModelAdmissionStore()),
	}, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = true
	})
	defer h.HTTP.Close()

	candidateID := stableModelAdmissionCandidateID("b")
	request := signedModelAdmissionOffer(t, "provider-byom-a", candidateID, "ollama:qwen3-8b", privA, nil)
	if status, body := postModelAdmissionOffer(t, h.HTTP.URL, bearerA, request); status != http.StatusOK {
		t.Fatalf("submit status=%d body=%s", status, body)
	}
	status, body := getModelAdmissionStatus(t, h.HTTP.URL, bearerB, candidateID)
	if status != http.StatusOK {
		t.Fatalf("provider B status=%d body=%s", status, body)
	}
	object := decodeMap(t, body)
	if object["admission_state"] != "not_offered" || object["provider_id"] != "provider-byom-b" {
		t.Fatalf("cross-provider status leaked: %#v", object)
	}
}

func TestModelAdmissionOfferRejectsWrongOrMissingCurrentIdentity(t *testing.T) {
	h, bearer, currentPriv, authStore := newModelAdmissionHarnessWithStore(t, "provider-byom-a")
	defer h.HTTP.Close()
	_, wrongPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	request := signedModelAdmissionOffer(t, "provider-byom-a", stableModelAdmissionCandidateID("c"), "ollama:qwen3-8b", wrongPriv, nil)
	if status, _ := postModelAdmissionOffer(t, h.HTTP.URL, bearer, request); status != http.StatusUnauthorized {
		t.Fatalf("wrong signing key status=%d, want 401", status)
	}
	nextPub, nextPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := authStore.RotateAdmissionIdentity(context.Background(), "provider-byom-a", bearer, currentPriv.Public().(ed25519.PublicKey), nextPub, 1, time.Now().UTC()); err != nil {
		t.Fatalf("rotate admission identity: %v", err)
	}
	request = signedModelAdmissionOffer(t, "provider-byom-a", stableModelAdmissionCandidateID("t"), "ollama:qwen3-8b", currentPriv, nil)
	if status, _ := postModelAdmissionOffer(t, h.HTTP.URL, bearer, request); status != http.StatusUnauthorized {
		t.Fatalf("previous signing key status=%d, want 401", status)
	}

	recoveryPub, recoveryPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	approveModelAdmissionRecoveryAuthorization(t, authStore, "provider-byom-a", nextPub, recoveryPub, 2, time.Now().UTC())
	request = signedModelAdmissionOffer(t, "provider-byom-a", stableModelAdmissionCandidateID("u"), "ollama:qwen3-8b", recoveryPriv, nil)
	if status, _ := postModelAdmissionOffer(t, h.HTTP.URL, bearer, request); status != http.StatusUnauthorized {
		t.Fatalf("recovery-not-current signing key status=%d, want 401", status)
	}
	request = signedModelAdmissionOffer(t, "provider-byom-a", stableModelAdmissionCandidateID("v"), "ollama:qwen3-8b", nextPriv, nil)
	if status, body := postModelAdmissionOffer(t, h.HTTP.URL, bearer, request); status != http.StatusOK {
		t.Fatalf("current rotated signing key status=%d body=%s, want 200", status, body)
	}

	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator-unbound.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	_, unboundBearer, err := store.IssueToken(context.Background(), "provider-unbound", "unbound")
	if err != nil {
		t.Fatal(err)
	}
	h2 := newProviderHarnessWithServerOptions(t, store, nil, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = true
	})
	defer h2.HTTP.Close()
	request = signedModelAdmissionOffer(t, "provider-unbound", stableModelAdmissionCandidateID("d"), "ollama:qwen3-8b", wrongPriv, nil)
	if status, _ := postModelAdmissionOffer(t, h2.HTTP.URL, unboundBearer, request); status != http.StatusUnauthorized {
		t.Fatalf("missing admission identity status=%d, want 401", status)
	}
}

func TestModelAdmissionInvalidOfferAttemptsAreRateLimited(t *testing.T) {
	h, bearer, currentPriv := newModelAdmissionHarness(t, "provider-byom-a")
	defer h.HTTP.Close()
	_, wrongPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	currentDigest := sha256.Sum256(currentPriv.Public().(ed25519.PublicKey))
	request := signedModelAdmissionOffer(t, "provider-byom-a", stableModelAdmissionCandidateID("c"), "ollama:qwen3-8b", wrongPriv, map[string]any{
		"signing_key_digest": hex.EncodeToString(currentDigest[:]),
	})

	for i := 0; i < 256; i++ {
		if status, _ := postModelAdmissionOffer(t, h.HTTP.URL, bearer, request); status != http.StatusUnauthorized {
			t.Fatalf("invalid attempt %d status=%d, want 401 before attempt limit", i, status)
		}
	}
	if status, _ := postModelAdmissionOffer(t, h.HTTP.URL, bearer, request); status != http.StatusTooManyRequests {
		t.Fatalf("invalid attempt after limit status=%d, want 429", status)
	}
}

func TestModelAdmissionOfferRejectsSanctionedProvider(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	_, bearer, priv := bindAdmissionIdentityForTest(t, store, "provider-byom-a")
	h := newProviderHarnessWithServerOptions(t, store, []providerws.Option{
		providerws.WithModelAdmissionStore(providerws.NewMemoryModelAdmissionStore()),
	}, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = true
	})
	defer h.HTTP.Close()
	h.Registry.LoadCanarySanctions([]pool.CanarySanctionSnapshot{{
		ProviderID: "provider-byom-a",
		FailCount:  1,
	}})

	request := signedModelAdmissionOffer(t, "provider-byom-a", stableModelAdmissionCandidateID("e"), "ollama:qwen3-8b", priv, nil)
	if status, _ := postModelAdmissionOffer(t, h.HTTP.URL, bearer, request); status != http.StatusUnauthorized {
		t.Fatalf("sanctioned provider status=%d, want 401", status)
	}

	_, bearerRejected, privRejected := bindAdmissionIdentityForTest(t, store, "provider-byom-rejected")
	h.Provider.Admission().Reject("provider-byom-rejected", "operator rejected provider")
	request = signedModelAdmissionOffer(t, "provider-byom-rejected", stableModelAdmissionCandidateID("q"), "ollama:qwen3-8b", privRejected, nil)
	if status, _ := postModelAdmissionOffer(t, h.HTTP.URL, bearerRejected, request); status != http.StatusUnauthorized {
		t.Fatalf("operator-rejected provider status=%d, want 401", status)
	}
}

func TestModelAdmissionOfferReplayAndConflict(t *testing.T) {
	h, bearer, priv := newModelAdmissionHarness(t, "provider-byom-a")
	defer h.HTTP.Close()
	overrides := map[string]any{
		"idempotency_key": "idem_replay",
		"nonce":           "nonce_replay",
	}
	request := signedModelAdmissionOffer(t, "provider-byom-a", stableModelAdmissionCandidateID("f"), "ollama:qwen3-8b", priv, overrides)
	status, body := postModelAdmissionOffer(t, h.HTTP.URL, bearer, request)
	if status != http.StatusOK {
		t.Fatalf("submit status=%d body=%s", status, body)
	}
	firstEventID := decodeMap(t, body)["coordinator_event_id"]
	status, body = postModelAdmissionOffer(t, h.HTTP.URL, bearer, request)
	if status != http.StatusOK {
		t.Fatalf("replay status=%d body=%s", status, body)
	}
	if decodeMap(t, body)["coordinator_event_id"] != firstEventID {
		t.Fatalf("same payload did not return original event id: %s", body)
	}
	conflict := signedModelAdmissionOffer(t, "provider-byom-a", stableModelAdmissionCandidateID("g"), "ollama:qwen3-8b", priv, overrides)
	if status, _ := postModelAdmissionOffer(t, h.HTTP.URL, bearer, conflict); status != http.StatusConflict {
		t.Fatalf("conflicting replay status=%d, want 409", status)
	}
}

func TestModelAdmissionOfferRejectsSameCandidateTupleDrift(t *testing.T) {
	h, bearer, priv := newModelAdmissionHarness(t, "provider-byom-a")
	defer h.HTTP.Close()
	candidateID := stableModelAdmissionCandidateID("h")
	request := signedModelAdmissionOffer(t, "provider-byom-a", candidateID, "ollama:qwen3-8b", priv, nil)
	if status, body := postModelAdmissionOffer(t, h.HTTP.URL, bearer, request); status != http.StatusOK {
		t.Fatalf("submit status=%d body=%s", status, body)
	}
	drift := signedModelAdmissionOffer(t, "provider-byom-a", candidateID, "ollama:different", priv, map[string]any{
		"nonce":           "nonce_drift",
		"idempotency_key": "request_drift",
	})
	if status, _ := postModelAdmissionOffer(t, h.HTTP.URL, bearer, drift); status != http.StatusConflict {
		t.Fatalf("tuple drift status=%d, want 409", status)
	}
}

func TestModelAdmissionOfferRejectsClosedSchemaAndUnsafeMaterial(t *testing.T) {
	h, bearer, priv := newModelAdmissionHarness(t, "provider-byom-a")
	defer h.HTTP.Close()
	request := signedModelAdmissionOffer(t, "provider-byom-a", stableModelAdmissionCandidateID("i"), "ollama:qwen3-8b", priv, nil)
	request["unexpected"] = true
	if status, _ := postModelAdmissionOffer(t, h.HTTP.URL, bearer, request); status != http.StatusBadRequest {
		t.Fatalf("unknown top-level field status=%d, want 400", status)
	}
	unsafe := signedModelAdmissionOffer(t, "provider-byom-a", stableModelAdmissionCandidateID("j"), "http://127.0.0.1:11434/private?api_key=secret", priv, nil)
	if status, _ := postModelAdmissionOffer(t, h.HTTP.URL, bearer, unsafe); status != http.StatusBadRequest {
		t.Fatalf("unsafe material status=%d, want 400", status)
	}
	for index, servedModelRef := range []string{"ollama:qwen3:8b", "ollama:llama3.2:3b"} {
		request := signedModelAdmissionOffer(t, "provider-byom-a", stableModelAdmissionCandidateID(string(rune('u'+index))), servedModelRef, priv, map[string]any{
			"nonce":           "nonce_valid_" + strings.NewReplacer(":", "_", ".", "_").Replace(servedModelRef),
			"idempotency_key": "request_valid_" + strings.NewReplacer(":", "_", ".", "_").Replace(servedModelRef),
			"cli_version":     "1.8.111",
		})
		if status, body := postModelAdmissionOffer(t, h.HTTP.URL, bearer, request); status != http.StatusOK {
			t.Fatalf("valid served ref %q status=%d body=%s, want 200", servedModelRef, status, body)
		}
	}
	unknownRuntime := signedModelAdmissionOffer(t, "provider-byom-a", stableModelAdmissionCandidateID("w"), "ollama:qwen3-8b", priv, map[string]any{
		"runtime_source":  "unknown_runtime",
		"nonce":           "nonce_unknown_runtime",
		"idempotency_key": "request_unknown_runtime",
	})
	if status, _ := postModelAdmissionOffer(t, h.HTTP.URL, bearer, unknownRuntime); status != http.StatusBadRequest {
		t.Fatalf("unknown runtime status=%d, want 400", status)
	}
	for _, servedModelRef := range []string{
		"localhost:11434",
		"127.0.0.1",
		"[::1]:11434",
		"0x7f000001",
		"2130706433",
		"model.example.com",
		"127.0.0.1.",
		"model.example.com.",
		"ollama:localhost:11434",
		"ollama:127.0.0.1:11434",
		"ollama:::1",
		"ollama:::ffff:127.0.0.1",
		"ollama:0x7f000001",
		"ollama:2130706433",
		"ollama:model.example.com",
		"ollama:model.example.com:11434",
		"ollama:model.example.com.",
		// Endpoint material embedded in a path segment (H1): localhost or a
		// host:port must be rejected wherever it appears, not just leading.
		"ollama:localhost/model",
		"ollama:model/localhost",
		"inference:8080/model",
		"model/inference:8080",
		"ollama:hf.co/user/repo",
		"ollama:model/registry.example.com/x",
	} {
		request := signedModelAdmissionOffer(t, "provider-byom-a", stableModelAdmissionCandidateID("k"), servedModelRef, priv, map[string]any{
			"nonce":           "nonce_unsafe_" + strings.NewReplacer(":", "_", ".", "_", "[", "_", "]", "_").Replace(servedModelRef),
			"idempotency_key": "request_unsafe_" + strings.NewReplacer(":", "_", ".", "_", "[", "_", "]", "_").Replace(servedModelRef),
		})
		if status, _ := postModelAdmissionOffer(t, h.HTTP.URL, bearer, request); status != http.StatusBadRequest {
			t.Fatalf("unsafe %q status=%d, want 400", servedModelRef, status)
		}
	}
	for _, servedModelRef := range []string{"ollama:<script>", "ollama:\"quoted\"", "ollama:'quoted'", "ollama;rm"} {
		request := signedModelAdmissionOffer(t, "provider-byom-a", stableModelAdmissionCandidateID("r"), servedModelRef, priv, map[string]any{
			"nonce":           "nonce_html_" + strings.NewReplacer(":", "_", "<", "_", ">", "_", "\"", "_", "'", "_", ";", "_").Replace(servedModelRef),
			"idempotency_key": "request_html_" + strings.NewReplacer(":", "_", "<", "_", ">", "_", "\"", "_", "'", "_", ";", "_").Replace(servedModelRef),
		})
		if status, _ := postModelAdmissionOffer(t, h.HTTP.URL, bearer, request); status != http.StatusBadRequest {
			t.Fatalf("unsafe %q status=%d, want 400", servedModelRef, status)
		}
	}
	for _, candidateID := range []string{"byom_127.0.0.1", "byom_127:11434", "byom_candidate_a"} {
		request := signedModelAdmissionOffer(t, "provider-byom-a", candidateID, "ollama:qwen3-8b", priv, map[string]any{
			"nonce":           "nonce_candidate_" + strings.NewReplacer(":", "_", ".", "_").Replace(candidateID),
			"idempotency_key": "request_candidate_" + strings.NewReplacer(":", "_", ".", "_").Replace(candidateID),
		})
		if status, _ := postModelAdmissionOffer(t, h.HTTP.URL, bearer, request); status != http.StatusBadRequest {
			t.Fatalf("unsafe candidate %q status=%d, want 400", candidateID, status)
		}
	}
}

func TestModelAdmissionStoreRequiresFreshEvidenceForReEntry(t *testing.T) {
	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	store, err := providerws.NewSQLiteModelAdmissionStore(db.DB())
	if err != nil {
		t.Fatal(err)
	}
	previous := providerws.ModelAdmissionEvent{
		ProviderID:             "provider-byom-a",
		CandidateID:            stableModelAdmissionCandidateID("s"),
		ServedModelRef:         "ollama:qwen3-8b",
		DiscoveryDigestSHA256:  stringsOf("a", 64),
		EvaluationDigestSHA256: stringsOf("b", 64),
		State:                  "withdrawn",
		RequestID:              "request_previous",
		Nonce:                  "nonce_previous",
		PayloadDigestSHA256:    stringsOf("c", 64),
		CreatedAt:              time.Now().UTC(),
	}
	previous = modelAdmissionTransitionForTest(previous, "offer_submitted", "withdrawn")
	if _, err := db.DB().ExecContext(context.Background(), `
INSERT INTO model_admission_events(
    provider_id, candidate_id, served_model_ref, catalog_model_key,
    discovery_digest_sha256, evaluation_digest_sha256, requested_disclosure_class,
    previous_state, state, next_state, actor, coordinator_event_id,
    reason_code, request_id, nonce, payload_digest_sha256,
    signature_digest_sha256, created_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		previous.ProviderID,
		previous.CandidateID,
		previous.ServedModelRef,
		previous.CatalogModelKey,
		previous.DiscoveryDigestSHA256,
		previous.EvaluationDigestSHA256,
		previous.RequestedDisclosureClass,
		previous.PreviousState,
		previous.State,
		previous.NextState,
		previous.Actor,
		previous.CoordinatorEventID,
		previous.ReasonCode,
		previous.RequestID,
		previous.Nonce,
		previous.PayloadDigestSHA256,
		previous.SignatureDigestSHA256,
		previous.CreatedAt.Format(time.RFC3339Nano),
	); err != nil {
		t.Fatal(err)
	}
	fresh := previous
	fresh.State = "offer_submitted"
	fresh.RequestID = "request_fresh"
	fresh.Nonce = "nonce_fresh"
	fresh.PayloadDigestSHA256 = stringsOf("d", 64)
	if _, _, err := store.AppendModelAdmissionOffer(context.Background(), fresh); err == nil {
		t.Fatal("stale evidence re-entry succeeded")
	}
	fresh.DiscoveryDigestSHA256 = stringsOf("e", 64)
	fresh.PayloadDigestSHA256 = stringsOf("f", 64)
	if _, _, err := store.AppendModelAdmissionOffer(context.Background(), fresh); err != nil {
		t.Fatalf("fresh evidence re-entry failed: %v", err)
	}
}

func TestModelAdmissionDecisionStateMachineAndRoutingGate(t *testing.T) {
	store := providerws.NewMemoryModelAdmissionStore()
	offer := providerws.ModelAdmissionEvent{
		ProviderID:               "provider-byom-a",
		CandidateID:              stableModelAdmissionCandidateID("r"),
		ServedModelRef:           "ollama:qwen3-8b",
		CatalogModelKey:          "qwen3-8b",
		DiscoveryDigestSHA256:    stringsOf("a", 64),
		EvaluationDigestSHA256:   stringsOf("b", 64),
		RequestedDisclosureClass: "catalog_binding_requested",
		ReasonCode:               "provider_offer_submitted",
		RequestID:                "request_offer_decision",
		Nonce:                    "nonce_offer_decision",
		PayloadDigestSHA256:      stringsOf("c", 64),
		SignatureDigestSHA256:    stringsOf("d", 64),
		CreatedAt:                time.Unix(1800000020, 0).UTC(),
	}
	submitted, replay, err := store.AppendModelAdmissionOffer(context.Background(), offer)
	if err != nil || replay {
		t.Fatalf("append offer replay=%v err=%v", replay, err)
	}
	if providerws.ModelAdmissionSettlementStateCandidate(submitted) {
		t.Fatal("offer_submitted must not be a settlement-state candidate")
	}

	catalogPriced := submitted
	catalogPriced.State = "catalog_priced"
	catalogPriced.ReasonCode = ""
	catalogPriced.RequestID = "request_catalog_priced"
	catalogPriced.Nonce = "nonce_catalog_priced"
	catalogPriced.PayloadDigestSHA256 = stringsOf("e", 64)
	catalogPriced.CreatedAt = time.Unix(1800000030, 0).UTC()
	catalogPriced = withTrustedCatalogDecisionFields(catalogPriced)
	catalogPriced, err = store.AppendModelAdmissionDecision(context.Background(), catalogPriced)
	if err != nil {
		t.Fatalf("catalog_priced decision failed: %v", err)
	}
	if providerws.ModelAdmissionSettlementStateCandidate(catalogPriced) {
		t.Fatal("catalog_priced must not be a settlement-state candidate")
	}

	settlement := catalogPriced
	settlement.State = "settlement_capable"
	settlement.RequestID = "request_settlement_capable"
	settlement.Nonce = "nonce_settlement_capable"
	settlement.PayloadDigestSHA256 = stringsOf("f", 64)
	settlement.CreatedAt = time.Unix(1800000040, 0).UTC()
	settlement = withTrustedCatalogDecisionFields(settlement)
	settlement, err = store.AppendModelAdmissionDecision(context.Background(), settlement)
	if err != nil {
		t.Fatalf("settlement_capable decision failed: %v", err)
	}
	if !providerws.ModelAdmissionSettlementStateCandidate(settlement) {
		t.Fatal("settlement_capable with catalog binding must pass the preliminary settlement-state predicate")
	}
	matching := providerws.ModelAdmissionPaidRoutingPredicate{
		ProviderID:                        settlement.ProviderID,
		CandidateID:                       settlement.CandidateID,
		ServedModelRef:                    settlement.ServedModelRef,
		CatalogModelKey:                   settlement.CatalogModelKey,
		DiscoveryDigestSHA256:             settlement.DiscoveryDigestSHA256,
		EvaluationDigestSHA256:            settlement.EvaluationDigestSHA256,
		CatalogID:                         settlement.CatalogID,
		CatalogBodyDigest:                 settlement.CatalogBodyDigest,
		CatalogSignatureKeyID:             settlement.CatalogSignatureKeyID,
		CatalogSignaturePubkeyFingerprint: settlement.CatalogSignaturePubkeyFingerprint,
		ExpectedCatalogModelHash:          settlement.ExpectedCatalogModelHash,
		ExpectedCatalogModelHashAlgorithm: settlement.ExpectedCatalogModelHashAlgorithm,
	}
	if !providerws.ModelAdmissionDefaultPaidRoutingEligible(settlement, matching) {
		t.Fatal("settlement_capable with trusted catalog binding must pass default paid-routing predicate")
	}
	untrustedCatalog := matching
	untrustedCatalog.CatalogBodyDigest = ""
	if providerws.ModelAdmissionDefaultPaidRoutingEligible(settlement, untrustedCatalog) {
		t.Fatal("settlement_capable without trusted catalog binding must fail closed")
	}
	untrustedAlgorithm := matching
	untrustedAlgorithm.ExpectedCatalogModelHashAlgorithm = ""
	if providerws.ModelAdmissionDefaultPaidRoutingEligible(settlement, untrustedAlgorithm) {
		t.Fatal("settlement_capable without trusted catalog hash algorithm must fail closed")
	}
	drifted := matching
	drifted.ServedModelRef = "ollama:different"
	if providerws.ModelAdmissionDefaultPaidRoutingEligible(settlement, drifted) {
		t.Fatal("served-model drift must fail closed for default paid routing")
	}
	catalogDrifted := matching
	catalogDrifted.CatalogBodyDigest = stringsOf("6", 64)
	if providerws.ModelAdmissionDefaultPaidRoutingEligible(settlement, catalogDrifted) {
		t.Fatal("catalog body drift must fail closed for default paid routing")
	}
	revocation, drift := providerws.ModelAdmissionRevocationForRuntimeDrift(settlement, drifted, "runtime_identity_drift", time.Unix(1800000050, 0).UTC())
	if !drift {
		t.Fatal("drifted route predicate did not create revocation event")
	}
	if _, drift := providerws.ModelAdmissionRevocationForRuntimeDrift(settlement, catalogDrifted, "catalog_identity_drift", time.Unix(1800000051, 0).UTC()); !drift {
		t.Fatal("catalog identity drift did not create revocation event")
	}
	revoked, err := store.AppendModelAdmissionDecision(context.Background(), revocation)
	if err != nil {
		t.Fatalf("revocation decision failed: %v", err)
	}
	if revoked.State != "revoked" ||
		providerws.ModelAdmissionSettlementStateCandidate(revoked) ||
		providerws.ModelAdmissionDefaultPaidRoutingEligible(revoked, matching) {
		t.Fatalf("revoked state leaked routing eligibility: %+v", revoked)
	}
}

func TestModelAdmissionDecisionRejectsInvalidCatalogAndReasonTransitions(t *testing.T) {
	store := providerws.NewMemoryModelAdmissionStore()
	offer := providerws.ModelAdmissionEvent{
		ProviderID:               "provider-byom-a",
		CandidateID:              stableModelAdmissionCandidateID("v"),
		ServedModelRef:           "ollama:qwen3-8b",
		DiscoveryDigestSHA256:    stringsOf("a", 64),
		EvaluationDigestSHA256:   stringsOf("b", 64),
		RequestedDisclosureClass: "non_earning_provider_asserted",
		ReasonCode:               "provider_offer_submitted",
		RequestID:                "request_offer_invalid_decision",
		Nonce:                    "nonce_offer_invalid_decision",
		PayloadDigestSHA256:      stringsOf("c", 64),
		SignatureDigestSHA256:    stringsOf("d", 64),
		CreatedAt:                time.Unix(1800000060, 0).UTC(),
	}
	submitted, _, err := store.AppendModelAdmissionOffer(context.Background(), offer)
	if err != nil {
		t.Fatalf("append offer: %v", err)
	}
	withoutCatalog := submitted
	withoutCatalog.State = "catalog_priced"
	withoutCatalog.RequestID = "request_no_catalog"
	withoutCatalog.Nonce = "nonce_no_catalog"
	withoutCatalog.PayloadDigestSHA256 = stringsOf("e", 64)
	if _, err := store.AppendModelAdmissionDecision(context.Background(), withoutCatalog); err == nil {
		t.Fatal("catalog_priced transition without catalog binding succeeded")
	}
	withoutTrustedCatalog := submitted
	withoutTrustedCatalog.CatalogModelKey = "qwen3-8b"
	withoutTrustedCatalog.State = "catalog_priced"
	withoutTrustedCatalog.RequestID = "request_no_trusted_catalog"
	withoutTrustedCatalog.Nonce = "nonce_no_trusted_catalog"
	withoutTrustedCatalog.PayloadDigestSHA256 = stringsOf("1", 64)
	if _, err := store.AppendModelAdmissionDecision(context.Background(), withoutTrustedCatalog); err == nil {
		t.Fatal("catalog_priced transition with only provider catalog key succeeded")
	}
	rejectedWithoutReason := submitted
	rejectedWithoutReason.State = "offer_rejected"
	rejectedWithoutReason.RequestID = "request_reject_no_reason"
	rejectedWithoutReason.Nonce = "nonce_reject_no_reason"
	rejectedWithoutReason.PayloadDigestSHA256 = stringsOf("f", 64)
	rejectedWithoutReason.ReasonCode = ""
	if _, err := store.AppendModelAdmissionDecision(context.Background(), rejectedWithoutReason); err == nil {
		t.Fatal("offer_rejected transition without reason succeeded")
	}
}

func TestModelAdmissionStatusGuidanceForRejectedAndDemotion(t *testing.T) {
	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	_, bearer, _ := bindAdmissionIdentityForTest(t, db, "provider-byom-a")
	store, err := providerws.NewSQLiteModelAdmissionStore(db.DB())
	if err != nil {
		t.Fatal(err)
	}
	h := newProviderHarnessWithServerOptions(t, db, []providerws.Option{
		providerws.WithModelAdmissionStore(store),
	}, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = true
	})
	defer h.HTTP.Close()

	rejected := modelAdmissionTransitionForTest(providerws.ModelAdmissionEvent{
		ProviderID:             "provider-byom-a",
		CandidateID:            stableModelAdmissionCandidateID("x"),
		ServedModelRef:         "ollama:qwen3-8b",
		DiscoveryDigestSHA256:  stringsOf("a", 64),
		EvaluationDigestSHA256: stringsOf("b", 64),
		RequestID:              "request_rejected",
		Nonce:                  "nonce_rejected",
		PayloadDigestSHA256:    stringsOf("c", 64),
		CreatedAt:              time.Now().UTC(),
	}, "offer_submitted", "offer_rejected")
	rejected.ReasonCode = "policy_failed"
	insertModelAdmissionEventForTest(t, db, rejected)

	status, body := getModelAdmissionStatus(t, h.HTTP.URL, bearer, rejected.CandidateID)
	if status != http.StatusOK {
		t.Fatalf("rejected status=%d body=%s", status, body)
	}
	object := decodeMap(t, body)
	allowed := object["allowed_next_states"].([]any)
	if len(allowed) != 2 || allowed[0] != "offer_submitted" || allowed[1] != "revoked" {
		t.Fatalf("offer_rejected allowed_next_states=%#v", allowed)
	}
	guidance := object["provider_guidance"].(map[string]any)
	if guidance["transition_reason_code"] != "policy_failed" {
		t.Fatalf("offer_rejected guidance=%#v", guidance)
	}

	demotion := modelAdmissionTransitionForTest(providerws.ModelAdmissionEvent{
		ProviderID:             "provider-byom-a",
		CandidateID:            stableModelAdmissionCandidateID("y"),
		ServedModelRef:         "ollama:qwen3-8b",
		DiscoveryDigestSHA256:  stringsOf("d", 64),
		EvaluationDigestSHA256: stringsOf("e", 64),
		RequestID:              "request_demoted",
		Nonce:                  "nonce_demoted",
		PayloadDigestSHA256:    stringsOf("f", 64),
		CreatedAt:              time.Now().UTC(),
	}, "settlement_capable", "catalog_priced")
	demotion.ReasonCode = "receipt_stale"
	insertModelAdmissionEventForTest(t, db, demotion)

	status, body = getModelAdmissionStatus(t, h.HTTP.URL, bearer, demotion.CandidateID)
	if status != http.StatusOK {
		t.Fatalf("demotion status=%d body=%s", status, body)
	}
	guidance = decodeMap(t, body)["provider_guidance"].(map[string]any)
	if guidance["transition_reason_code"] != "receipt_stale" {
		t.Fatalf("demotion guidance=%#v", guidance)
	}
}

func TestModelAdmissionOfferRejectsSkewedTimestampAndUsesServerTime(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	clock := newLockedTime(time.Date(2026, 8, 28, 12, 0, 0, 123000000, time.UTC))
	_, bearer, priv := bindAdmissionIdentityForTest(t, store, "provider-byom-a")
	h := newProviderHarnessWithServerOptions(t, store, []providerws.Option{
		providerws.WithModelAdmissionStore(providerws.NewMemoryModelAdmissionStore()),
		providerws.WithNow(clock.Now),
	}, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = true
	})
	defer h.HTTP.Close()

	stale := signedModelAdmissionOffer(t, "provider-byom-a", stableModelAdmissionCandidateID("l"), "ollama:qwen3-8b", priv, map[string]any{
		"timestamp": clock.Now().Add(-6 * time.Minute).Format(time.RFC3339Nano),
	})
	if status, _ := postModelAdmissionOffer(t, h.HTTP.URL, bearer, stale); status != http.StatusBadRequest {
		t.Fatalf("stale signed timestamp status=%d, want 400", status)
	}
	future := signedModelAdmissionOffer(t, "provider-byom-a", stableModelAdmissionCandidateID("m"), "ollama:qwen3-8b", priv, map[string]any{
		"timestamp": clock.Now().Add(6 * time.Minute).Format(time.RFC3339Nano),
	})
	if status, _ := postModelAdmissionOffer(t, h.HTTP.URL, bearer, future); status != http.StatusBadRequest {
		t.Fatalf("future signed timestamp status=%d, want 400", status)
	}

	valid := signedModelAdmissionOffer(t, "provider-byom-a", stableModelAdmissionCandidateID("n"), "ollama:qwen3-8b", priv, map[string]any{
		"timestamp": clock.Now().Add(-30 * time.Second).Format(time.RFC3339Nano),
	})
	status, body := postModelAdmissionOffer(t, h.HTTP.URL, bearer, valid)
	if status != http.StatusOK {
		t.Fatalf("valid skew status=%d body=%s", status, body)
	}
	object := decodeMap(t, body)
	if object["state_observed_at"] != clock.Now().UTC().Format(time.RFC3339Nano) {
		t.Fatalf("event timestamp came from payload or wall clock: %#v", object)
	}
}

func TestSQLiteModelAdmissionStorePersistsAppendOnlyStatus(t *testing.T) {
	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	store, err := providerws.NewSQLiteModelAdmissionStore(db.DB())
	if err != nil {
		t.Fatal(err)
	}
	event := providerws.ModelAdmissionEvent{
		ProviderID:               "provider-byom-a",
		CandidateID:              stableModelAdmissionCandidateID("o"),
		ServedModelRef:           "ollama:qwen3-8b",
		DiscoveryDigestSHA256:    stringsOf("a", 64),
		RequestedDisclosureClass: "non_earning_provider_asserted",
		PreviousState:            "not_offered",
		State:                    "offer_submitted",
		NextState:                "offer_submitted",
		Actor:                    "provider",
		CoordinatorEventID:       "event_sqlite",
		ReasonCode:               "provider_offer_submitted",
		RequestID:                "request_sqlite",
		Nonce:                    "nonce_sqlite",
		PayloadDigestSHA256:      stringsOf("b", 64),
		SignatureDigestSHA256:    stringsOf("c", 64),
		CreatedAt:                time.Unix(1800000010, 0).UTC(),
	}
	if _, replay, err := store.AppendModelAdmissionOffer(context.Background(), event); err != nil || replay {
		t.Fatalf("append replay=%v err=%v", replay, err)
	}
	reopened, err := providerws.NewSQLiteModelAdmissionStore(db.DB())
	if err != nil {
		t.Fatal(err)
	}
	readback, found, err := reopened.LatestModelAdmissionStatus(context.Background(), "provider-byom-a", stableModelAdmissionCandidateID("o"))
	if err != nil || !found || readback.RequestID != "request_sqlite" {
		t.Fatalf("readback found=%v event=%+v err=%v", found, readback, err)
	}
	if _, replay, err := reopened.AppendModelAdmissionOffer(context.Background(), event); err != nil || !replay {
		t.Fatalf("idempotent append replay=%v err=%v", replay, err)
	}
	withdrawal := providerws.ModelAdmissionEvent{
		ProviderID:            event.ProviderID,
		CandidateID:           event.CandidateID,
		ServedModelRef:        event.ServedModelRef,
		State:                 "withdrawn",
		ReasonCode:            "runtime_unavailable",
		RequestID:             "request_sqlite_withdraw",
		Nonce:                 "nonce_sqlite_withdraw",
		PayloadDigestSHA256:   stringsOf("d", 64),
		SignatureDigestSHA256: stringsOf("e", 64),
		CreatedAt:             time.Unix(1800000020, 0).UTC(),
	}
	withdrawn, replay, err := reopened.AppendModelAdmissionWithdrawal(context.Background(), withdrawal)
	if err != nil || replay {
		t.Fatalf("withdraw replay=%v err=%v", replay, err)
	}
	if withdrawn.DiscoveryDigestSHA256 != event.DiscoveryDigestSHA256 ||
		withdrawn.RequestedDisclosureClass != event.RequestedDisclosureClass {
		t.Fatalf("withdrawal lost prior evidence: %+v", withdrawn)
	}
	replayed, replay, err := reopened.AppendModelAdmissionWithdrawal(context.Background(), withdrawal)
	if err != nil || !replay || replayed.CoordinatorEventID != withdrawn.CoordinatorEventID {
		t.Fatalf("withdraw replay event=%+v replay=%v err=%v", replayed, replay, err)
	}
	reopenedAgain, err := providerws.NewSQLiteModelAdmissionStore(db.DB())
	if err != nil {
		t.Fatal(err)
	}
	readback, found, err = reopenedAgain.LatestModelAdmissionStatus(context.Background(), event.ProviderID, event.CandidateID)
	if err != nil || !found || readback.State != "withdrawn" || readback.DiscoveryDigestSHA256 != event.DiscoveryDigestSHA256 {
		t.Fatalf("withdraw readback found=%v event=%+v err=%v", found, readback, err)
	}
}

func modelAdmissionDecisionLifecycle(t *testing.T, store providerws.ModelAdmissionStore, tag string) (providerws.ModelAdmissionEvent, providerws.ModelAdmissionEvent) {
	t.Helper()
	offer := providerws.ModelAdmissionEvent{
		ProviderID:               "provider-byom-a",
		CandidateID:              stableModelAdmissionCandidateID(tag),
		ServedModelRef:           "ollama:qwen3-8b",
		CatalogModelKey:          "qwen3-8b",
		DiscoveryDigestSHA256:    stringsOf("a", 64),
		EvaluationDigestSHA256:   stringsOf("b", 64),
		RequestedDisclosureClass: "catalog_binding_requested",
		ReasonCode:               "provider_offer_submitted",
		RequestID:                "request_offer_" + tag,
		Nonce:                    "nonce_offer_" + tag,
		PayloadDigestSHA256:      stringsOf("c", 64),
		SignatureDigestSHA256:    stringsOf("d", 64),
		CreatedAt:                time.Unix(1800000020, 0).UTC(),
	}
	submitted, _, err := store.AppendModelAdmissionOffer(context.Background(), offer)
	if err != nil {
		t.Fatalf("append offer: %v", err)
	}
	catalogPriced := submitted
	catalogPriced.State = "catalog_priced"
	catalogPriced.ReasonCode = ""
	catalogPriced.RequestID = "request_catalog_" + tag
	catalogPriced.Nonce = "nonce_catalog_" + tag
	catalogPriced.PayloadDigestSHA256 = stringsOf("e", 64)
	catalogPriced.CreatedAt = time.Unix(1800000030, 0).UTC()
	firstCatalog, err := store.AppendModelAdmissionDecision(context.Background(), catalogPriced)
	if err != nil {
		t.Fatalf("catalog_priced decision: %v", err)
	}
	settlement := firstCatalog
	settlement.State = "settlement_capable"
	settlement.RequestID = "request_settlement_" + tag
	settlement.Nonce = "nonce_settlement_" + tag
	settlement.PayloadDigestSHA256 = stringsOf("f", 64)
	settlement.CreatedAt = time.Unix(1800000040, 0).UTC()
	if _, err := store.AppendModelAdmissionDecision(context.Background(), settlement); err != nil {
		t.Fatalf("settlement_capable decision: %v", err)
	}
	return catalogPriced, firstCatalog
}

// A coordinator decision replayed after the admission has already advanced to a
// later state must resolve as an idempotent replay, not a transition conflict.
// Regression guard for replay-vs-transition ordering.
func TestModelAdmissionDecisionReplayIsStateOrderIndependent(t *testing.T) {
	store := providerws.NewMemoryModelAdmissionStore()
	catalogPriced, firstCatalog := modelAdmissionDecisionLifecycle(t, store, "rom")

	replayed, err := store.AppendModelAdmissionDecision(context.Background(), catalogPriced)
	if err != nil {
		t.Fatalf("replayed catalog_priced after advancement must be idempotent, got err=%v", err)
	}
	if replayed.CoordinatorEventID != firstCatalog.CoordinatorEventID || replayed.State != "catalog_priced" {
		t.Fatalf("replay did not return the original decision: %+v", replayed)
	}
	latest, found, err := store.LatestModelAdmissionStatus(context.Background(), catalogPriced.ProviderID, catalogPriced.CandidateID)
	if err != nil || !found || latest.State != "settlement_capable" {
		t.Fatalf("latest after replay found=%v state=%q err=%v", found, latest.State, err)
	}
}

func TestSQLiteModelAdmissionDecisionReplayIsStateOrderIndependent(t *testing.T) {
	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	store, err := providerws.NewSQLiteModelAdmissionStore(db.DB())
	if err != nil {
		t.Fatal(err)
	}
	catalogPriced, firstCatalog := modelAdmissionDecisionLifecycle(t, store, "ros")

	replayed, err := store.AppendModelAdmissionDecision(context.Background(), catalogPriced)
	if err != nil {
		t.Fatalf("sqlite replayed catalog_priced after advancement must be idempotent, got err=%v", err)
	}
	if replayed.CoordinatorEventID != firstCatalog.CoordinatorEventID || replayed.State != "catalog_priced" {
		t.Fatalf("sqlite replay did not return the original decision: %+v", replayed)
	}
	latest, found, err := store.LatestModelAdmissionStatus(context.Background(), catalogPriced.ProviderID, catalogPriced.CandidateID)
	if err != nil || !found || latest.State != "settlement_capable" {
		t.Fatalf("sqlite latest after replay found=%v state=%q err=%v", found, latest.State, err)
	}
}

// A coordinator decision submitted WITHOUT explicit replay keys must still be
// idempotent across retries: deterministic key generation reproduces the same
// keys, so a keyless retry after advancement resolves as a replay rather than a
// transition conflict.
func TestModelAdmissionKeylessDecisionReplayIsIdempotent(t *testing.T) {
	store := providerws.NewMemoryModelAdmissionStore()
	offer := providerws.ModelAdmissionEvent{
		ProviderID:               "provider-byom-a",
		CandidateID:              stableModelAdmissionCandidateID("kl"),
		ServedModelRef:           "ollama:qwen3-8b",
		CatalogModelKey:          "qwen3-8b",
		DiscoveryDigestSHA256:    stringsOf("a", 64),
		EvaluationDigestSHA256:   stringsOf("b", 64),
		RequestedDisclosureClass: "catalog_binding_requested",
		ReasonCode:               "provider_offer_submitted",
		RequestID:                "request_offer_kl",
		Nonce:                    "nonce_offer_kl",
		PayloadDigestSHA256:      stringsOf("c", 64),
		SignatureDigestSHA256:    stringsOf("d", 64),
		CreatedAt:                time.Unix(1800000020, 0).UTC(),
	}
	submitted, _, err := store.AppendModelAdmissionOffer(context.Background(), offer)
	if err != nil {
		t.Fatalf("append offer: %v", err)
	}
	catalogPriced := submitted
	catalogPriced.State = "catalog_priced"
	catalogPriced.ReasonCode = ""
	catalogPriced.RequestID = ""
	catalogPriced.Nonce = ""
	catalogPriced.PayloadDigestSHA256 = stringsOf("e", 64)
	catalogPriced.CreatedAt = time.Unix(1800000030, 0).UTC()
	firstCatalog, err := store.AppendModelAdmissionDecision(context.Background(), catalogPriced)
	if err != nil {
		t.Fatalf("keyless catalog_priced decision: %v", err)
	}
	if firstCatalog.RequestID == "" || firstCatalog.Nonce == "" {
		t.Fatalf("store must generate replay keys for a keyless decision: %+v", firstCatalog)
	}
	settlement := firstCatalog
	settlement.State = "settlement_capable"
	settlement.RequestID = ""
	settlement.Nonce = ""
	settlement.PayloadDigestSHA256 = stringsOf("f", 64)
	settlement.CreatedAt = time.Unix(1800000040, 0).UTC()
	if _, err := store.AppendModelAdmissionDecision(context.Background(), settlement); err != nil {
		t.Fatalf("keyless settlement_capable decision: %v", err)
	}
	replayed, err := store.AppendModelAdmissionDecision(context.Background(), catalogPriced)
	if err != nil {
		t.Fatalf("keyless replay after advancement must be idempotent, got err=%v", err)
	}
	if replayed.CoordinatorEventID != firstCatalog.CoordinatorEventID || replayed.State != "catalog_priced" {
		t.Fatalf("keyless replay did not return the original decision: %+v", replayed)
	}
}

// A coordinator decision carrying one prior event's request_id and a different
// prior event's nonce+payload must be rejected as a conflict, not accepted as a
// replay. Guards SQLite/memory parity: the SQLite lookup must check each key
// independently rather than OR-matching the newest row.
func TestSQLiteModelAdmissionCoordinatorReplayRejectsSplitKey(t *testing.T) {
	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	store, err := providerws.NewSQLiteModelAdmissionStore(db.DB())
	if err != nil {
		t.Fatal(err)
	}
	// Lifecycle records catalog_priced (request_catalog_spl, nonce_catalog_spl,
	// payload "e") and settlement_capable (request_settlement_spl,
	// nonce_settlement_spl, payload "f").
	catalogPriced, _ := modelAdmissionDecisionLifecycle(t, store, "spl")

	// Forward: request_id bound to catalog (payload e, differs from supplied f).
	forward := catalogPriced // keeps request_catalog_spl
	forward.Nonce = "nonce_settlement_spl"
	forward.PayloadDigestSHA256 = stringsOf("f", 64)
	if _, err := store.AppendModelAdmissionDecision(context.Background(), forward); err == nil {
		t.Fatal("forward split-key coordinator decision must be rejected as a replay conflict")
	}

	// Reverse: request_id bound to settlement (payload f, matches supplied f), but
	// nonce bound to catalog (payload e). Must still conflict — every supplied key
	// is validated, not just the first match.
	reverse := catalogPriced
	reverse.RequestID = "request_settlement_spl"
	reverse.Nonce = "nonce_catalog_spl"
	reverse.PayloadDigestSHA256 = stringsOf("f", 64)
	if _, err := store.AppendModelAdmissionDecision(context.Background(), reverse); err == nil {
		t.Fatal("reverse split-key coordinator decision must be rejected as a replay conflict")
	}
}

// Memory-store parity for the split-key conflict, both orientations.
func TestModelAdmissionCoordinatorReplayRejectsSplitKey(t *testing.T) {
	store := providerws.NewMemoryModelAdmissionStore()
	catalogPriced, _ := modelAdmissionDecisionLifecycle(t, store, "msk")

	forward := catalogPriced // request_catalog_msk (payload e)
	forward.Nonce = "nonce_settlement_msk"
	forward.PayloadDigestSHA256 = stringsOf("f", 64)
	if _, err := store.AppendModelAdmissionDecision(context.Background(), forward); err == nil {
		t.Fatal("forward split-key coordinator decision must conflict in the memory store")
	}

	reverse := catalogPriced
	reverse.RequestID = "request_settlement_msk"
	reverse.Nonce = "nonce_catalog_msk"
	reverse.PayloadDigestSHA256 = stringsOf("f", 64)
	if _, err := store.AppendModelAdmissionDecision(context.Background(), reverse); err == nil {
		t.Fatal("reverse split-key coordinator decision must conflict in the memory store")
	}
}

// The provider append path (offer/withdrawal) shares the same independent-key
// replay semantics: a provider event mixing one event's request_id with another
// event's nonce must conflict, in both stores.
func TestSQLiteModelAdmissionProviderReplayRejectsSplitKey(t *testing.T) {
	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	store, err := providerws.NewSQLiteModelAdmissionStore(db.DB())
	if err != nil {
		t.Fatal(err)
	}
	offer := providerws.ModelAdmissionEvent{
		ProviderID:               "provider-byom-a",
		CandidateID:              stableModelAdmissionCandidateID("psk"),
		ServedModelRef:           "ollama:qwen3-8b",
		DiscoveryDigestSHA256:    stringsOf("a", 64),
		RequestedDisclosureClass: "non_earning_provider_asserted",
		ReasonCode:               "provider_offer_submitted",
		RequestID:                "request_offer_psk",
		Nonce:                    "nonce_offer_psk",
		PayloadDigestSHA256:      stringsOf("c", 64),
		SignatureDigestSHA256:    stringsOf("d", 64),
		CreatedAt:                time.Unix(1800000010, 0).UTC(),
	}
	if _, _, err := store.AppendModelAdmissionOffer(context.Background(), offer); err != nil {
		t.Fatalf("append offer: %v", err)
	}
	withdrawal := providerws.ModelAdmissionEvent{
		ProviderID:            offer.ProviderID,
		CandidateID:           offer.CandidateID,
		ServedModelRef:        offer.ServedModelRef,
		State:                 "withdrawn",
		ReasonCode:            "runtime_unavailable",
		RequestID:             "request_withdraw_psk",
		Nonce:                 "nonce_withdraw_psk",
		PayloadDigestSHA256:   stringsOf("e", 64),
		SignatureDigestSHA256: stringsOf("f", 64),
		CreatedAt:             time.Unix(1800000020, 0).UTC(),
	}
	if _, _, err := store.AppendModelAdmissionWithdrawal(context.Background(), withdrawal); err != nil {
		t.Fatalf("append withdrawal: %v", err)
	}
	// request_id bound to the offer (payload c), nonce+payload from the withdrawal.
	split := withdrawal
	split.RequestID = "request_offer_psk"
	if _, _, err := store.AppendModelAdmissionWithdrawal(context.Background(), split); err == nil {
		t.Fatal("provider split-key event must be rejected as a replay conflict")
	}
}

// Runtime-drift revocation applies only to settlement_capable candidates — the
// only state that could ever have been paid-routing eligible. Non-settlement and
// terminal states must never manufacture a revocation.
func TestModelAdmissionRuntimeDriftRevocationRequiresSettlementState(t *testing.T) {
	base := providerws.ModelAdmissionEvent{
		ProviderID:             "provider-byom-a",
		CandidateID:            stableModelAdmissionCandidateID("rd"),
		ServedModelRef:         "ollama:qwen3-8b",
		CatalogModelKey:        "qwen3-8b",
		DiscoveryDigestSHA256:  stringsOf("a", 64),
		EvaluationDigestSHA256: stringsOf("b", 64),
		CoordinatorEventID:     "event_rd",
	}
	drifted := providerws.ModelAdmissionPaidRoutingPredicate{
		ProviderID:             base.ProviderID,
		CandidateID:            base.CandidateID,
		ServedModelRef:         "ollama:different",
		CatalogModelKey:        base.CatalogModelKey,
		DiscoveryDigestSHA256:  base.DiscoveryDigestSHA256,
		EvaluationDigestSHA256: base.EvaluationDigestSHA256,
	}
	for _, state := range []string{"offer_submitted", "catalog_priced", "network_admitted_unsettled", "withdrawn", "revoked"} {
		current := base
		current.State = state
		if _, drift := providerws.ModelAdmissionRevocationForRuntimeDrift(current, drifted, "runtime_identity_drift", time.Unix(1800000050, 0).UTC()); drift {
			t.Fatalf("state %q must not produce a runtime-drift revocation", state)
		}
	}
	settlement := base
	settlement.State = "settlement_capable"
	revocation, drift := providerws.ModelAdmissionRevocationForRuntimeDrift(settlement, drifted, "runtime_identity_drift", time.Unix(1800000050, 0).UTC())
	if !drift || revocation.State != "revoked" {
		t.Fatalf("settlement_capable drift must revoke: drift=%v state=%q", drift, revocation.State)
	}
}

func TestSQLiteModelAdmissionStorePersistsRouteStatusLookup(t *testing.T) {
	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	store, err := providerws.NewSQLiteModelAdmissionStore(db.DB())
	if err != nil {
		t.Fatal(err)
	}
	providerID := "provider-byom-a"
	first := providerws.ModelAdmissionEvent{
		ProviderID:               providerID,
		CandidateID:              stableModelAdmissionCandidateID("p"),
		ServedModelRef:           "ollama:qwen3-8b",
		CatalogModelKey:          "model-a",
		DiscoveryDigestSHA256:    stringsOf("a", 64),
		EvaluationDigestSHA256:   stringsOf("b", 64),
		RequestedDisclosureClass: "catalog_binding_requested",
		ReasonCode:               "provider_offer_submitted",
		RequestID:                "sqlite_route_offer",
		Nonce:                    "sqlite_route_nonce",
		PayloadDigestSHA256:      stringsOf("c", 64),
		SignatureDigestSHA256:    stringsOf("d", 64),
		CreatedAt:                time.Unix(1800000100, 0).UTC(),
	}
	if _, replay, err := store.AppendModelAdmissionOffer(context.Background(), first); err != nil || replay {
		t.Fatalf("append first replay=%v err=%v", replay, err)
	}
	catalogPriced := withTrustedCatalogDecisionFields(first)
	catalogPriced.State = "catalog_priced"
	catalogPriced.RequestID = "sqlite_route_catalog_priced"
	catalogPriced.Nonce = "sqlite_route_catalog_priced_nonce"
	catalogPriced.PayloadDigestSHA256 = stringsOf("e", 64)
	catalogPriced.CreatedAt = time.Unix(1800000110, 0).UTC()
	catalogPriced, err = store.AppendModelAdmissionDecision(context.Background(), catalogPriced)
	if err != nil {
		t.Fatalf("catalog_priced decision: %v", err)
	}
	readback, found, err := store.LatestModelAdmissionRouteStatus(context.Background(), providerID, "ollama:qwen3-8b", "model-a")
	if err != nil || !found || readback.State != "catalog_priced" || readback.CoordinatorEventID != catalogPriced.CoordinatorEventID {
		t.Fatalf("route readback found=%v event=%+v err=%v", found, readback, err)
	}

	second := first
	second.CandidateID = stableModelAdmissionCandidateID("q")
	second.ServedModelRef = "ollama:qwen3-8b-alt"
	second.DiscoveryDigestSHA256 = stringsOf("6", 64)
	second.EvaluationDigestSHA256 = stringsOf("7", 64)
	second.RequestID = "sqlite_route_second_offer"
	second.Nonce = "sqlite_route_second_nonce"
	second.PayloadDigestSHA256 = stringsOf("8", 64)
	second.SignatureDigestSHA256 = stringsOf("9", 64)
	second.CreatedAt = time.Unix(1800000120, 0).UTC()
	if _, replay, err := store.AppendModelAdmissionOffer(context.Background(), second); err != nil || replay {
		t.Fatalf("append second replay=%v err=%v", replay, err)
	}
	secondCatalogPriced := withTrustedCatalogDecisionFields(second)
	secondCatalogPriced.State = "catalog_priced"
	secondCatalogPriced.RequestID = "sqlite_route_second_catalog_priced"
	secondCatalogPriced.Nonce = "sqlite_route_second_catalog_priced_nonce"
	secondCatalogPriced.PayloadDigestSHA256 = stringsOf("0", 64)
	secondCatalogPriced.CreatedAt = time.Unix(1800000125, 0).UTC()
	_, err = store.AppendModelAdmissionDecision(context.Background(), secondCatalogPriced)
	if err != nil {
		t.Fatalf("second catalog_priced decision: %v", err)
	}
	settlement := withTrustedCatalogDecisionFields(second)
	settlement.State = "settlement_capable"
	settlement.RequestID = "sqlite_route_second_settlement"
	settlement.Nonce = "sqlite_route_second_settlement_nonce"
	settlement.PayloadDigestSHA256 = stringsOf("1", 64)
	settlement.CreatedAt = time.Unix(1800000130, 0).UTC()
	settlement, err = store.AppendModelAdmissionDecision(context.Background(), settlement)
	if err != nil {
		t.Fatalf("settlement decision: %v", err)
	}
	readback, found, err = store.LatestModelAdmissionRouteStatus(context.Background(), providerID, "", "model-a")
	if err != nil || !found || readback.CandidateID != settlement.CandidateID {
		t.Fatalf("catalog-key route lookup did not return latest admission event found=%v event=%+v err=%v", found, readback, err)
	}
	readback, found, err = store.LatestModelAdmissionRouteStatus(context.Background(), providerID, "ollama:qwen3-8b", "model-a")
	if err != nil || !found || readback.CandidateID != catalogPriced.CandidateID {
		t.Fatalf("exact route lookup did not preserve served-ref boundary found=%v event=%+v err=%v", found, readback, err)
	}
	withdraw := settlement
	withdraw.State = "withdrawn"
	withdraw.ReasonCode = "provider_requested"
	withdraw.RequestID = "sqlite_route_second_withdraw"
	withdraw.Nonce = "sqlite_route_second_withdraw_nonce"
	withdraw.PayloadDigestSHA256 = stringsOf("2", 64)
	withdraw.SignatureDigestSHA256 = stringsOf("3", 64)
	withdraw.CreatedAt = time.Unix(1800000140, 0).UTC()
	withdrawn, replay, err := store.AppendModelAdmissionWithdrawal(context.Background(), withdraw)
	if err != nil || replay {
		t.Fatalf("withdraw replay=%v err=%v", replay, err)
	}
	reopened, err := providerws.NewSQLiteModelAdmissionStore(db.DB())
	if err != nil {
		t.Fatal(err)
	}
	readback, found, err = reopened.LatestModelAdmissionRouteStatus(context.Background(), providerID, "ollama:qwen3-8b-alt", "model-a")
	if err != nil || !found || readback.State != "withdrawn" || readback.CoordinatorEventID != withdrawn.CoordinatorEventID {
		t.Fatalf("withdrawn route readback found=%v event=%+v err=%v", found, readback, err)
	}
}

func newModelAdmissionHarness(t *testing.T, providerID string) (providerHarness, string, ed25519.PrivateKey) {
	t.Helper()
	h, bearer, priv, _ := newModelAdmissionHarnessWithStore(t, providerID)
	return h, bearer, priv
}

func newModelAdmissionHarnessWithStore(t *testing.T, providerID string) (providerHarness, string, ed25519.PrivateKey, *auth.Store) {
	t.Helper()
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	_, bearer, priv := bindAdmissionIdentityForTest(t, store, providerID)
	h := newProviderHarnessWithServerOptions(t, store, []providerws.Option{
		providerws.WithModelAdmissionStore(providerws.NewMemoryModelAdmissionStore()),
	}, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = true
	})
	return h, bearer, priv, store
}

func bindAdmissionIdentityForTest(t *testing.T, store *auth.Store, providerID string) (ed25519.PublicKey, string, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	_, bearer, err := store.IssueToken(context.Background(), providerID, providerID)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.BindAdmissionIdentity(context.Background(), providerID, bearer, pub, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	return pub, bearer, priv
}

func signedModelAdmissionOffer(t *testing.T, providerID, candidateID, servedModelRef string, priv ed25519.PrivateKey, overrides map[string]any) map[string]any {
	t.Helper()
	pubkey := priv.Public().(ed25519.PublicKey)
	pubkeyDigest := sha256.Sum256(pubkey)
	signedFields := map[string]any{
		"signature_domain":         "macprovider.model_admission.offer.v1",
		"provider_id":              providerID,
		"candidate_id":             candidateID,
		"runtime_source":           "ollama_loopback",
		"served_model_ref":         servedModelRef,
		"catalog_model_key":        "",
		"discovery_digest_sha256":  stringsOf("a", 64),
		"evaluation_digest_sha256": stringsOf("b", 64),
		"artifact_hashes":          map[string]any{},
		"advisory_capabilities": map[string]any{
			"chat_completions":              true,
			"streaming":                     nil,
			"tool_call_passthrough":         nil,
			"structured_output_passthrough": nil,
			"json_mode":                     nil,
			"usage_reporting":               nil,
			"max_context_tokens":            2048,
			"quantization":                  nil,
			"family":                        nil,
			"runtime_version":               nil,
		},
		"fit_evidence_source":        "local_discovery",
		"local_readiness":            "ready",
		"requested_disclosure_class": "non_earning_provider_asserted",
		"timestamp":                  time.Now().UTC().Format(time.RFC3339Nano),
		"nonce":                      "nonce_" + candidateID,
		"idempotency_key":            "request_" + candidateID,
		"signing_key_digest":         hex.EncodeToString(pubkeyDigest[:]),
		"cli_version":                "1.8.111",
	}
	for key, value := range overrides {
		signedFields[key] = value
	}
	canonical, err := billing.CanonicalJSON(signedFields)
	if err != nil {
		t.Fatal(err)
	}
	signature := ed25519.Sign(priv, canonical)
	request := map[string]any{"schema": "model_admission_offer_submit.v1"}
	for key, value := range signedFields {
		request[key] = value
	}
	request["signature_algorithm"] = "ed25519"
	request["provider_signature"] = base64.StdEncoding.EncodeToString(signature)
	return request
}

func signedModelAdmissionWithdrawal(t *testing.T, providerID, candidateID, servedModelRef string, priv ed25519.PrivateKey, overrides map[string]any) map[string]any {
	t.Helper()
	pubkey := priv.Public().(ed25519.PublicKey)
	pubkeyDigest := sha256.Sum256(pubkey)
	signedFields := map[string]any{
		"generated_at":       time.Now().UTC().Format(time.RFC3339Nano),
		"cli_version":        "1.8.111",
		"signature_domain":   "macprovider.model_admission.withdraw.v1",
		"provider_id":        providerID,
		"candidate_id":       candidateID,
		"served_model_ref":   servedModelRef,
		"catalog_model_key":  nil,
		"idempotency_key":    "withdraw_request_" + candidateID,
		"nonce":              "withdraw_nonce_" + candidateID,
		"timestamp":          time.Now().UTC().Format(time.RFC3339Nano),
		"reason_code":        "provider_requested",
		"signing_key_digest": hex.EncodeToString(pubkeyDigest[:]),
	}
	for key, value := range overrides {
		signedFields[key] = value
	}
	canonical, err := billing.CanonicalJSON(map[string]any{
		"signature_domain":   signedFields["signature_domain"],
		"provider_id":        signedFields["provider_id"],
		"candidate_id":       signedFields["candidate_id"],
		"served_model_ref":   signedFields["served_model_ref"],
		"catalog_model_key":  signedFields["catalog_model_key"],
		"idempotency_key":    signedFields["idempotency_key"],
		"nonce":              signedFields["nonce"],
		"timestamp":          signedFields["timestamp"],
		"reason_code":        signedFields["reason_code"],
		"signing_key_digest": signedFields["signing_key_digest"],
		"cli_version":        signedFields["cli_version"],
	})
	if err != nil {
		t.Fatal(err)
	}
	signature := ed25519.Sign(priv, canonical)
	request := map[string]any{"schema": "model_admission_withdraw_request.v1"}
	for key, value := range signedFields {
		request[key] = value
	}
	request["signature_algorithm"] = "ed25519"
	request["provider_signature"] = base64.StdEncoding.EncodeToString(signature)
	return request
}

func postModelAdmissionOffer(t *testing.T, baseURL, bearer string, payload map[string]any) (int, string) {
	t.Helper()
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	req, err := http.NewRequest(http.MethodPost, baseURL+"/v1/provider/model-admission/offers", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+bearer)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(out)
}

func postModelAdmissionWithdrawal(t *testing.T, baseURL, bearer string, payload map[string]any) (int, string) {
	t.Helper()
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	req, err := http.NewRequest(http.MethodPost, baseURL+"/v1/provider/model-admission/withdrawals", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+bearer)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(out)
}

func getModelAdmissionStatus(t *testing.T, baseURL, bearer, candidateID string) (int, string) {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, baseURL+"/v1/provider/model-admission/status?candidate_id="+candidateID, nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+bearer)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(out)
}

func decodeMap(t *testing.T, raw string) map[string]any {
	t.Helper()
	var object map[string]any
	if err := json.Unmarshal([]byte(raw), &object); err != nil {
		t.Fatalf("decode %q: %v", raw, err)
	}
	return object
}

func stringsOf(value string, count int) string {
	var b strings.Builder
	for i := 0; i < count; i++ {
		b.WriteString(value)
	}
	return b.String()
}

func stableModelAdmissionCandidateID(value string) string {
	return "byom_" + strings.Repeat(value, 52)
}

func withTrustedCatalogDecisionFields(event providerws.ModelAdmissionEvent) providerws.ModelAdmissionEvent {
	event.CatalogID = "settlement-catalog"
	event.CatalogBodyDigest = stringsOf("3", 64)
	event.CatalogSignatureKeyID = "test-key"
	event.CatalogSignaturePubkeyFingerprint = "ed25519-sha256:" + stringsOf("4", 64)
	event.ExpectedCatalogModelHash = stringsOf("5", 64)
	event.ExpectedCatalogModelHashAlgorithm = modelidentity.SnapshotManifestV1
	return event
}

func insertModelAdmissionEventForTest(t *testing.T, db *auth.Store, event providerws.ModelAdmissionEvent) {
	t.Helper()
	if _, err := db.DB().ExecContext(context.Background(), `
INSERT INTO model_admission_events(
    provider_id, candidate_id, served_model_ref, catalog_model_key,
    catalog_id, catalog_body_digest, catalog_signature_key_id,
    catalog_signature_pubkey_fingerprint, expected_catalog_model_hash,
    expected_catalog_model_hash_algorithm,
    discovery_digest_sha256, evaluation_digest_sha256, requested_disclosure_class,
    previous_state, state, next_state, actor, coordinator_event_id,
    reason_code, request_id, nonce, payload_digest_sha256,
    signature_digest_sha256, created_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		event.ProviderID,
		event.CandidateID,
		event.ServedModelRef,
		event.CatalogModelKey,
		event.CatalogID,
		event.CatalogBodyDigest,
		event.CatalogSignatureKeyID,
		event.CatalogSignaturePubkeyFingerprint,
		event.ExpectedCatalogModelHash,
		event.ExpectedCatalogModelHashAlgorithm,
		event.DiscoveryDigestSHA256,
		event.EvaluationDigestSHA256,
		event.RequestedDisclosureClass,
		event.PreviousState,
		event.State,
		event.NextState,
		event.Actor,
		event.CoordinatorEventID,
		event.ReasonCode,
		event.RequestID,
		event.Nonce,
		event.PayloadDigestSHA256,
		event.SignatureDigestSHA256,
		event.CreatedAt.Format(time.RFC3339Nano),
	); err != nil {
		t.Fatal(err)
	}
}

func approveModelAdmissionRecoveryAuthorization(
	t *testing.T,
	store *auth.Store,
	providerID string,
	current, candidate []byte,
	generation int,
	now time.Time,
) {
	t.Helper()
	currentDigest := sha256.Sum256(current)
	candidateDigest := sha256.Sum256(candidate)
	authorization := auth.AdmissionIdentityRecoveryAuthorization{
		PendingID:                      "recovery-" + hex.EncodeToString(candidateDigest[:8]),
		ProviderID:                     providerID,
		CandidatePublicKeySHA256:       hex.EncodeToString(candidateDigest[:]),
		ExpectedCurrentPublicKeySHA256: hex.EncodeToString(currentDigest[:]),
		ExpectedGeneration:             generation,
		RequestedBy:                    "operator:alice",
		RequestedUntil:                 now.Add(time.Hour),
		Reason:                         "test recovery",
		IncidentID:                     "INC-" + hex.EncodeToString(candidateDigest[:8]),
	}
	if _, err := store.RequestAdmissionIdentityRecovery(context.Background(), authorization, now); err != nil {
		t.Fatalf("request recovery authorization: %v", err)
	}
	if _, err := store.ApproveAdmissionIdentityRecovery(context.Background(), authorization.PendingID, "operator:bob", now); err != nil {
		t.Fatalf("approve recovery authorization: %v", err)
	}
}

func modelAdmissionTransitionForTest(event providerws.ModelAdmissionEvent, previous, next string) providerws.ModelAdmissionEvent {
	event.PreviousState = previous
	event.State = next
	event.NextState = next
	event.Actor = "provider"
	event.ReasonCode = "test_transition"
	event.CoordinatorEventID = stringsOf("1", 64)
	event.SignatureDigestSHA256 = stringsOf("2", 64)
	return event
}

func TestModelAdmissionSignatureDigestFixture(t *testing.T) {
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	request := signedModelAdmissionOffer(t, "provider-byom-a", stableModelAdmissionCandidateID("p"), "ollama:qwen3-8b", priv, nil)
	delete(request, "schema")
	delete(request, "signature_algorithm")
	delete(request, "provider_signature")
	canonical, err := billing.CanonicalJSON(request)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(canonical)
	if hex.EncodeToString(sum[:]) == "" {
		t.Fatal("empty digest")
	}
}
