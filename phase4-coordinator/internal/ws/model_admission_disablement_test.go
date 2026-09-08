package ws_test

import (
	"context"
	"net/http"
	"path/filepath"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/config"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// #1248 disablement matrix, "Offer submit" row: a coordinator policy gate must
// reject NEW SPEC-047 offer submissions while preserving readback. The prior
// answer (deploying without WithModelAdmissionStore) lost readback, so it did
// not satisfy the row. These tests pin the switch semantics for both store
// implementations: submit rejected with a closed reason and no event appended,
// status readback and provider withdrawal of existing offers untouched.
func TestModelAdmissionSubmissionsDisabledRejectsSubmitAndPreservesReadback(t *testing.T) {
	for _, storeKind := range []string{"memory", "sqlite"} {
		t.Run(storeKind, func(t *testing.T) {
			authStore, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
			if err != nil {
				t.Fatal(err)
			}
			defer authStore.Close()
			_, bearer, priv := bindAdmissionIdentityForTest(t, authStore, "provider-byom-a")

			var admissions providerws.ModelAdmissionStore
			switch storeKind {
			case "memory":
				admissions = providerws.NewMemoryModelAdmissionStore()
			default:
				sqliteStore, err := providerws.NewSQLiteModelAdmissionStore(authStore.DB())
				if err != nil {
					t.Fatal(err)
				}
				admissions = sqliteStore
			}

			// Default posture: submissions enabled, offer recorded.
			enabled := newModelAdmissionSubmissionsHarness(t, authStore, admissions, false)
			existingCandidate := stableModelAdmissionCandidateID("m")
			offer := signedModelAdmissionOffer(t, "provider-byom-a", existingCandidate, "ollama:qwen3-8b", priv, nil)
			status, body := postModelAdmissionOffer(t, enabled.HTTP.URL, bearer, offer)
			if status != http.StatusOK {
				t.Fatalf("offer under default policy status=%d body=%s, want 200", status, body)
			}
			recordedEventID := decodeMap(t, body)["coordinator_event_id"]
			if recordedEventID == nil {
				t.Fatalf("offer response carried no coordinator_event_id: %s", body)
			}
			enabled.HTTP.Close()

			// Same durable state, submissions switched off.
			disabled := newModelAdmissionSubmissionsHarness(t, authStore, admissions, true)
			defer disabled.HTTP.Close()

			newCandidate := stableModelAdmissionCandidateID("n")
			blocked := signedModelAdmissionOffer(t, "provider-byom-a", newCandidate, "ollama:qwen3-8b-new", priv, map[string]any{
				"idempotency_key": "request_submissions_disabled",
				"nonce":           "nonce_submissions_disabled",
			})
			status, body = postModelAdmissionOffer(t, disabled.HTTP.URL, bearer, blocked)
			if status != http.StatusServiceUnavailable {
				t.Fatalf("offer under disabled policy status=%d body=%s, want 503", status, body)
			}
			rejection := decodeMap(t, body)
			errObject, ok := rejection["error"].(map[string]any)
			if !ok || errObject["code"] != "submissions_disabled" {
				t.Fatalf("unexpected rejection envelope: %s", body)
			}
			if _, leaked := rejection["admission_state"]; leaked {
				t.Fatalf("rejection leaked admission state: %s", body)
			}

			// No event was written for the rejected submission.
			if _, found, err := admissions.LatestModelAdmissionStatus(context.Background(), "provider-byom-a", newCandidate); err != nil || found {
				t.Fatalf("rejected submission appended an event found=%v err=%v", found, err)
			}
			status, body = getModelAdmissionStatus(t, disabled.HTTP.URL, bearer, newCandidate)
			if status != http.StatusOK {
				t.Fatalf("status readback for never-offered candidate=%d body=%s", status, body)
			}
			if object := decodeMap(t, body); object["admission_state"] != "not_offered" || object["coordinator_event_id"] != nil {
				t.Fatalf("never-offered readback mutated by rejected submit: %s", body)
			}

			// Readback of the pre-existing offer is preserved.
			status, body = getModelAdmissionStatus(t, disabled.HTTP.URL, bearer, existingCandidate)
			if status != http.StatusOK {
				t.Fatalf("existing status readback=%d body=%s", status, body)
			}
			readback := decodeMap(t, body)
			if readback["admission_state"] != "offer_submitted" || readback["coordinator_event_id"] != recordedEventID {
				t.Fatalf("existing offer readback changed under disablement: %s", body)
			}

			// Provider withdrawal of the existing offer still works.
			withdrawal := signedModelAdmissionWithdrawal(t, "provider-byom-a", existingCandidate, "ollama:qwen3-8b", priv, map[string]any{
				"idempotency_key": "withdraw_request_submissions_disabled",
				"nonce":           "withdraw_nonce_submissions_disabled",
			})
			status, body = postModelAdmissionWithdrawal(t, disabled.HTTP.URL, bearer, withdrawal)
			if status != http.StatusOK {
				t.Fatalf("withdrawal under disabled policy status=%d body=%s, want 200", status, body)
			}
			if object := decodeMap(t, body); object["resulting_admission_state"] != "withdrawn" ||
				object["previous_admission_state"] != "offer_submitted" {
				t.Fatalf("unexpected withdrawal response under disablement: %s", body)
			}
		})
	}
}

// The switch defaults to enabled: an unset option and an explicit
// WithModelAdmissionSubmissionsDisabled(false) both accept submissions.
func TestModelAdmissionSubmissionsEnabledByDefault(t *testing.T) {
	authStore, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer authStore.Close()
	_, bearer, priv := bindAdmissionIdentityForTest(t, authStore, "provider-byom-a")
	admissions := providerws.NewMemoryModelAdmissionStore()

	unset := newProviderHarnessWithServerOptions(t, authStore, []providerws.Option{
		providerws.WithModelAdmissionStore(admissions),
	}, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = true
	})
	offer := signedModelAdmissionOffer(t, "provider-byom-a", stableModelAdmissionCandidateID("j"), "ollama:qwen3-8b", priv, nil)
	if status, body := postModelAdmissionOffer(t, unset.HTTP.URL, bearer, offer); status != http.StatusOK {
		t.Fatalf("offer with option unset status=%d body=%s, want 200", status, body)
	}
	unset.HTTP.Close()

	explicit := newModelAdmissionSubmissionsHarness(t, authStore, admissions, false)
	defer explicit.HTTP.Close()
	offer = signedModelAdmissionOffer(t, "provider-byom-a", stableModelAdmissionCandidateID("k"), "ollama:qwen3-8b-alt", priv, map[string]any{
		"idempotency_key": "request_submissions_explicit_enabled",
		"nonce":           "nonce_submissions_explicit_enabled",
	})
	if status, body := postModelAdmissionOffer(t, explicit.HTTP.URL, bearer, offer); status != http.StatusOK {
		t.Fatalf("offer with explicit enabled status=%d body=%s, want 200", status, body)
	}
}

func newModelAdmissionSubmissionsHarness(t *testing.T, authStore *auth.Store, admissions providerws.ModelAdmissionStore, disabled bool) providerHarness {
	t.Helper()
	return newProviderHarnessWithServerOptions(t, authStore, []providerws.Option{
		providerws.WithModelAdmissionStore(admissions),
		providerws.WithModelAdmissionSubmissionsDisabled(disabled),
	}, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = true
	})
}
