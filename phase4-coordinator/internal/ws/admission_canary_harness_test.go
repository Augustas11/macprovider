package ws

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/rs/zerolog"
)

func TestAdmissionCanaryHarnessEndpointsAreNotMountedByDefault(t *testing.T) {
	t.Parallel()
	s, _, _ := newEncryptedRelayHarness(t)
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	resp := postAdmissionCanaryJSON(t, ts.URL+"/admin/admission-canary/clear-admitted-tuple", "test-operator-key", map[string]any{
		"provider_id": "p1",
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("disabled harness status=%d, want 404", resp.StatusCode)
	}
}

func TestAdmissionCanaryClearAdmittedTupleMutatesOnlyTuple(t *testing.T) {
	t.Parallel()
	cfg := config.Default()
	cfg.Auth.OperatorKey = "test-operator-key"
	cfg.AdmissionCanaryHarness.Enabled = true
	s, provider, _ := newEncryptedRelayHarnessWithConfig(t, cfg, zerolog.Nop(), time.Now())
	provider.MaxAdmittedModelID = "small-model"
	provider.MaxAdmittedMinRAMGB = 8
	provider.CatalogAdmissionMode = "current"
	setAdmittedTupleValues(provider, "hashA", "apple m4 max", 64)
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	resp := postAdmissionCanaryJSON(t, ts.URL+"/admin/admission-canary/clear-admitted-tuple", "test-operator-key", map[string]any{
		"provider_id": provider.ProviderID,
		"assigned_id": provider.AssignedID,
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("clear tuple status=%d", resp.StatusCode)
	}
	var body struct {
		Status string                          `json:"status"`
		Before admissionCanaryProviderSnapshot `json:"before"`
		After  admissionCanaryProviderSnapshot `json:"after"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body.Status != "ok" {
		t.Fatalf("status=%q", body.Status)
	}
	if !body.Before.HasAdmittedTuple || body.After.HasAdmittedTuple {
		t.Fatalf("tuple snapshots before=%+v after=%+v", body.Before, body.After)
	}
	if body.After.AdmissionEvidenceStale || body.After.AdmissionSandboxed || body.After.AdmissionCeilingExcluded {
		t.Fatalf("clear tuple should not set admission flags: %+v", body.After)
	}
	if !body.After.RoutingEligible || !body.After.ServingCapable {
		t.Fatalf("clear tuple should not directly route-exclude before sweep: %+v", body.After)
	}
	snap, ok := s.pool.Resolve(provider.ProviderID, provider.AssignedID)
	if !ok || providerHasAdmittedTuple(snap) {
		t.Fatalf("registry tuple still present: ok=%v snap=%+v", ok, snap)
	}
}

func TestAdmissionCanaryProofOfWeightsHotEnableReturnsFailClosedSnapshots(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 9, 2, 12, 0, 0, 0, time.UTC)
	cfg := config.Default()
	cfg.Auth.OperatorKey = "test-operator-key"
	cfg.AdmissionCanaryHarness.Enabled = true
	cfg.ProofOfWeights.RequireAutotuneHelloGate = false
	cfg.ProofOfWeights.AutotuneEvidenceTTLDays = 30
	s, subject, _ := newEncryptedRelayHarnessWithConfig(t, cfg, zerolog.Nop(), now)
	subject.ModelID = "small-model"
	subject.MaxAdmittedMinRAMGB = 0

	control := spec032ControlProvider("control-r003", "control-r003-s")
	setAdmittedTupleValues(control, "hashC", "apple m4 max", 64)
	spec032AddSessionedProvider(t, s, control, now)
	catalog := admissionCeilingTestCatalog(t)
	s.autotuneCatalog = catalog
	s.autotuneEvidence = spec032MapEvidence{byProvider: map[string]autotune.VerifiedEvidence{
		control.ProviderID: admissionCeilingVerifiedEvidence(t, catalog, "small", "hashC", "apple m4 max", 64),
	}}
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	resp := postAdmissionCanaryJSON(t, ts.URL+"/admin/admission-canary/proof-of-weights", "test-operator-key", map[string]any{
		"require_autotune_hello_gate": true,
		"autotune_evidence_ttl_days":  30,
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("proof-of-weights status=%d", resp.StatusCode)
	}
	var body struct {
		Status string `json:"status"`
		Reload struct {
			PreQuarantined int `json:"pre_quarantined"`
			Revalidated    int `json:"revalidated"`
			Sandboxed      int `json:"sandboxed"`
		} `json:"reload"`
		Before []admissionCanaryProviderSnapshot `json:"before"`
		After  []admissionCanaryProviderSnapshot `json:"after"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body.Status != "ok" || body.Reload.PreQuarantined < 2 || body.Reload.Revalidated < 2 || body.Reload.Sandboxed < 1 {
		t.Fatalf("unexpected reload body: %+v", body)
	}
	subjectAfter, ok := admissionCanaryFindSnapshot(body.After, subject.ProviderID)
	if !ok {
		t.Fatalf("subject snapshot missing: %+v", body.After)
	}
	if !subjectAfter.AdmissionSandboxed || subjectAfter.RoutingEligible || subjectAfter.ServingCapable {
		t.Fatalf("subject must be sandboxed and unroutable: %+v", subjectAfter)
	}
	controlAfter, ok := admissionCanaryFindSnapshot(body.After, control.ProviderID)
	if !ok {
		t.Fatalf("control snapshot missing: %+v", body.After)
	}
	if !controlAfter.RoutingEligible || !controlAfter.ServingCapable || controlAfter.AdmissionEvidenceStale || controlAfter.AdmissionSandboxed {
		t.Fatalf("control must stay buyer-serving after reload: %+v", controlAfter)
	}
}

func postAdmissionCanaryJSON(t *testing.T, url, token string, body any) *http.Response {
	t.Helper()
	data, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(data))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("post request: %v", err)
	}
	return resp
}

func admissionCanaryFindSnapshot(snaps []admissionCanaryProviderSnapshot, providerID string) (admissionCanaryProviderSnapshot, bool) {
	for _, snap := range snaps {
		if snap.ProviderID == providerID {
			return snap, true
		}
	}
	return admissionCanaryProviderSnapshot{}, false
}
