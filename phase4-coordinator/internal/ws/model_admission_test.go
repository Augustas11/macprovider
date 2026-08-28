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
	settlement, err = store.AppendModelAdmissionDecision(context.Background(), settlement)
	if err != nil {
		t.Fatalf("settlement_capable decision failed: %v", err)
	}
	if !providerws.ModelAdmissionSettlementStateCandidate(settlement) {
		t.Fatal("settlement_capable with catalog binding must pass the preliminary settlement-state predicate")
	}
	matching := providerws.ModelAdmissionPaidRoutingPredicate{
		ProviderID:             settlement.ProviderID,
		CandidateID:            settlement.CandidateID,
		ServedModelRef:         settlement.ServedModelRef,
		CatalogModelKey:        settlement.CatalogModelKey,
		DiscoveryDigestSHA256:  settlement.DiscoveryDigestSHA256,
		EvaluationDigestSHA256: settlement.EvaluationDigestSHA256,
	}
	if providerws.ModelAdmissionDefaultPaidRoutingEligible(settlement, matching) {
		t.Fatal("settlement_capable remains default paid-routing excluded until SPEC-022/catalog authority is wired")
	}
	drifted := matching
	drifted.ServedModelRef = "ollama:different"
	if providerws.ModelAdmissionDefaultPaidRoutingEligible(settlement, drifted) {
		t.Fatal("served-model drift must fail closed for default paid routing")
	}
	revocation, drift := providerws.ModelAdmissionRevocationForRuntimeDrift(settlement, drifted, "runtime_identity_drift", time.Unix(1800000050, 0).UTC())
	if !drift {
		t.Fatal("drifted route predicate did not create revocation event")
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

func insertModelAdmissionEventForTest(t *testing.T, db *auth.Store, event providerws.ModelAdmissionEvent) {
	t.Helper()
	if _, err := db.DB().ExecContext(context.Background(), `
INSERT INTO model_admission_events(
    provider_id, candidate_id, served_model_ref, catalog_model_key,
    discovery_digest_sha256, evaluation_digest_sha256, requested_disclosure_class,
    previous_state, state, next_state, actor, coordinator_event_id,
    reason_code, request_id, nonce, payload_digest_sha256,
    signature_digest_sha256, created_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		event.ProviderID,
		event.CandidateID,
		event.ServedModelRef,
		event.CatalogModelKey,
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
