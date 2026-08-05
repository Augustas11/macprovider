package ws_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/onboarding"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"github.com/lib/pq"
	"github.com/rs/zerolog"
)

func TestHardwareTrustApproveRequestCreatesPendingRow(t *testing.T) {
	now := time.Date(2026, 7, 16, 12, 0, 0, 0, time.UTC)
	store := &fakeHardwareTrustAdminStore{
		requestProvID: "mac",
		requestHash:   "hash-abc",
		requestChip:   "apple m4",
		requestMemGB:  32,
	}
	logs := &lockedBuffer{}
	h := newProviderHarnessWithServerOptionsAndLogger(t, nil, []providerws.Option{
		providerws.WithNow(func() time.Time { return now }),
		providerws.WithIdentitySignatureStore(&fakeIdentitySignatureStore{identityPubkey: bytes.Repeat([]byte{0x21}, 32), identityOK: true}),
		providerws.WithHardwareTrustAdminStore(store),
	}, zerolog.New(logs), func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	resp := postAuthPolicyOperatorJSON(t, h.HTTP.URL+"/admin/hardware-trust/approve", "alice-secret", map[string]any{
		"job_id": 7,
		"reason": "operator approved waiting_trust job",
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusAccepted {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	if !store.requestCalled {
		t.Fatal("request store was not called")
	}
	if store.jobID != 7 {
		t.Fatalf("stored job_id = %d, want 7", store.jobID)
	}
	if store.requestedBy != "operator:alice" || store.reason != "operator approved waiting_trust job" {
		t.Fatalf("stored request actor/reason = %#v", store)
	}
	if store.expiresAt != nil {
		t.Fatalf("expiresAt should be nil for permanent trust, got %v", store.expiresAt)
	}
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	// The response echoes the tuple the SQL derived from the job, not any
	// client-supplied value.
	if out["provider_id"] != "mac" || out["hardware_identity_hash"] != "hash-abc" || out["chip_normalized"] != "apple m4" {
		t.Fatalf("request response = %#v", out)
	}
	logBody := logs.String()
	if !strings.Contains(logBody, "hardware_trust_approval_requested") || !strings.Contains(logBody, "operator:alice") {
		t.Fatalf("audit log missing request action/actor: %s", logBody)
	}
}

func TestHardwareTrustApproveRequestRejectsMissingJobID(t *testing.T) {
	store := &fakeHardwareTrustAdminStore{}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithHardwareTrustAdminStore(store),
	}, func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	resp := postAuthPolicyOperatorJSON(t, h.HTTP.URL+"/admin/hardware-trust/approve", "alice-secret", map[string]any{
		"reason": "no job id",
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	if store.requestCalled {
		t.Fatal("request store called despite missing job_id")
	}
}

func TestHardwareTrustApproveRequestRejectsUnknownField(t *testing.T) {
	store := &fakeHardwareTrustAdminStore{}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithHardwareTrustAdminStore(store),
	}, func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	// A misspelled requested_until must 400, not silently create permanent trust.
	resp := postAuthPolicyOperatorJSON(t, h.HTTP.URL+"/admin/hardware-trust/approve", "alice-secret", map[string]any{
		"job_id":         7,
		"reason":         "typo attempt",
		"requested_untl": "2026-08-01T00:00:00Z",
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	if store.requestCalled {
		t.Fatal("request store called despite unknown field")
	}
}

func TestHardwareTrustApproveMapsJobNotWaitingToConflict(t *testing.T) {
	store := &fakeHardwareTrustAdminStore{requestErr: &pq.Error{Code: "P0001", Message: "job not waiting_trust"}}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithHardwareTrustAdminStore(store),
	}, func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	resp := postAuthPolicyOperatorJSON(t, h.HTTP.URL+"/admin/hardware-trust/approve", "alice-secret", map[string]any{
		"job_id": 999,
		"reason": "job already finalized",
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusConflict {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if errObj, _ := out["error"].(map[string]any); errObj["code"] != "hardware_trust_job_not_waiting" {
		t.Fatalf("error = %#v", out["error"])
	}
}

func TestHardwareTrustApproveMapsConnectivityToServiceUnavailable(t *testing.T) {
	// A genuine network-layer failure (a real coordinator-vs-Postgres dial
	// failure surfaces as *net.OpError / net.Error) must surface as 503, not 400
	// or 500. Deterministic non-pq defects now map to 500 (issue #582 FIX 7), so
	// this asserts the connectivity path with a real net error rather than an
	// opaque string.
	store := &fakeHardwareTrustAdminStore{requestErr: &net.OpError{Op: "dial", Net: "tcp", Err: errors.New("connect: connection refused")}}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithHardwareTrustAdminStore(store),
	}, func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	resp := postAuthPolicyOperatorJSON(t, h.HTTP.URL+"/admin/hardware-trust/approve", "alice-secret", map[string]any{
		"job_id": 7,
		"reason": "db down",
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
}

func TestHardwareTrustApproveRejectsSpoofedBodyActor(t *testing.T) {
	now := time.Date(2026, 7, 16, 12, 0, 0, 0, time.UTC)
	store := &fakeHardwareTrustAdminStore{}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithNow(func() time.Time { return now }),
		providerws.WithIdentitySignatureStore(&fakeIdentitySignatureStore{identityPubkey: bytes.Repeat([]byte{0x22}, 32), identityOK: true}),
		providerws.WithHardwareTrustAdminStore(store),
	}, func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	resp := postAuthPolicyOperatorJSON(t, h.HTTP.URL+"/admin/hardware-trust/approve", "alice-secret", map[string]any{
		"job_id":       7,
		"requested_by": "operator:bob",
		"reason":       "spoof attempt",
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	if store.requestCalled {
		t.Fatal("request store called despite spoofed requested_by")
	}
}

func TestHardwareTrustApproveRejectsUnauthorizedOperator(t *testing.T) {
	store := &fakeHardwareTrustAdminStore{}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithHardwareTrustAdminStore(store),
	}, func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	resp := postAuthPolicyOperatorJSON(t, h.HTTP.URL+"/admin/hardware-trust/approve", "unknown-secret", map[string]any{
		"provider_id":            "p_existing",
		"hardware_identity_hash": "hash-abc",
		"chip_normalized":        "apple m4",
		"unified_memory_gb":      32,
		"reason":                 "unauthorized attempt",
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	if store.requestCalled {
		t.Fatal("request store called despite unauthorized operator token")
	}
}

func TestHardwareTrustApproveMapsDualControlToConflict(t *testing.T) {
	store := &fakeHardwareTrustAdminStore{approveErr: &pq.Error{Code: "P0001", Message: "dual_control_required"}}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithHardwareTrustAdminStore(store),
	}, func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	resp := postAuthPolicyOperatorJSON(t, h.HTTP.URL+"/admin/hardware-trust/approve/4d2644a7-fc82-4750-b43f-2d9f73abc62a/approve", "alice-secret", map[string]string{})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusConflict {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	if !store.approveCalled {
		t.Fatal("approve store was not called")
	}
}

// TestHardwareTrustWaitingRoutesStoreErrorThrough503 confirms the waiting-list
// endpoint shares the hardware-trust mapper so a store outage is a 503, not a
// flat 500 (issue #582 FIX G).
func TestHardwareTrustWaitingRoutesStoreErrorThrough503(t *testing.T) {
	store := &fakeHardwareTrustAdminStore{listErr: &net.OpError{Op: "dial", Net: "tcp", Err: errors.New("connect: connection refused")}}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithHardwareTrustAdminStore(store),
	}, func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	resp := getHardwareTrustOperator(t, h.HTTP.URL+"/admin/hardware-trust/waiting", "alice-secret")
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if errObj, _ := out["error"].(map[string]any); errObj["code"] != "hardware_trust_store_unavailable" {
		t.Fatalf("error = %#v", out["error"])
	}
}

func TestHardwareTrustApproveCommitsOperatorAPITrustRow(t *testing.T) {
	now := time.Date(2026, 7, 16, 12, 0, 0, 0, time.UTC)
	store := &fakeHardwareTrustAdminStore{
		approveProviderID: "mac",
		approveHash:       "hash-abc",
		approveChip:       "apple m4",
		approveMemGB:      32,
		approveReason:     "operator approved waiting_trust job",
	}
	logs := &lockedBuffer{}
	h := newProviderHarnessWithServerOptionsAndLogger(t, nil, []providerws.Option{
		providerws.WithNow(func() time.Time { return now }),
		providerws.WithHardwareTrustAdminStore(store),
	}, zerolog.New(logs), func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	resp := postAuthPolicyOperatorJSON(t, h.HTTP.URL+"/admin/hardware-trust/approve/4d2644a7-fc82-4750-b43f-2d9f73abc62a/approve", "bob-secret", map[string]string{})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	if store.approvedBy != "operator:bob" {
		t.Fatalf("approved_by = %q", store.approvedBy)
	}
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if out["source"] != "operator_api" || out["status"] != "committed" || out["provider_id"] != "mac" {
		t.Fatalf("approve response = %#v", out)
	}
	logBody := logs.String()
	if !strings.Contains(logBody, "hardware_trust_approval_approved") || !strings.Contains(logBody, "operator:bob") {
		t.Fatalf("audit log missing approval action/actor: %s", logBody)
	}
}

func TestHardwareTrustWaitingListsParkedJobs(t *testing.T) {
	submitted := time.Date(2026, 7, 16, 11, 0, 0, 0, time.UTC)
	store := &fakeHardwareTrustAdminStore{waiting: []onboarding.WaitingTrustJob{{
		JobID:                7,
		ProviderID:           "mac",
		Chip:                 "Apple M4",
		ChipNormalized:       "apple m4",
		UnifiedMemoryGB:      32,
		HardwareIdentityHash: "hash-abc",
		DecisionReason:       "waiting_trust",
		ChipProfilePresent:   true,
		SubmittedAt:          submitted,
	}}}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithHardwareTrustAdminStore(store),
	}, func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	resp := getHardwareTrustOperator(t, h.HTTP.URL+"/admin/hardware-trust/waiting", "alice-secret")
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	if !store.listCalled {
		t.Fatal("list store was not called")
	}
	var out struct {
		Count        int              `json:"count"`
		WaitingTrust []map[string]any `json:"waiting_trust"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if out.Count != 1 || len(out.WaitingTrust) != 1 {
		t.Fatalf("waiting list = %#v", out)
	}
	if out.WaitingTrust[0]["provider_id"] != "mac" || out.WaitingTrust[0]["hardware_identity_hash"] != "hash-abc" {
		t.Fatalf("waiting job = %#v", out.WaitingTrust[0])
	}
}

func TestHardwareTrustWaitingMarksApprovability(t *testing.T) {
	// FIX 10: the waiting list surfaces ALL waiting_trust jobs but flags each with
	// approvable so operators see chip-profile waits (approvable=false) alongside
	// hardware-identity waits the request endpoint accepts (approvable=true).
	submitted := time.Date(2026, 7, 16, 11, 0, 0, 0, time.UTC)
	store := &fakeHardwareTrustAdminStore{waiting: []onboarding.WaitingTrustJob{
		{
			JobID:                7,
			ProviderID:           "mac",
			HardwareIdentityHash: "hash-abc",
			DecisionReason:       "hardware-verifier.v2:missing_trusted_hardware_identity",
			ChipProfilePresent:   true,
			SubmittedAt:          submitted,
		},
		{
			JobID:                8,
			ProviderID:           "air",
			HardwareIdentityHash: "hash-def",
			DecisionReason:       "hardware-verifier.v2:missing_trusted_chip_profile",
			ChipProfilePresent:   false,
			SubmittedAt:          submitted,
		},
		{
			JobID:                9,
			ProviderID:           "studio",
			HardwareIdentityHash: "",
			DecisionReason:       "hardware-verifier.v2:missing_trusted_hardware_identity",
			ChipProfilePresent:   true,
			SubmittedAt:          submitted,
		},
		{
			JobID:                10,
			ProviderID:           "max",
			HardwareIdentityHash: "hash-ghi",
			DecisionReason:       "hardware-verifier.v2:missing_trusted_hardware_identity",
			ChipProfilePresent:   false,
			SubmittedAt:          submitted,
		},
	}}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithHardwareTrustAdminStore(store),
	}, func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	resp := getHardwareTrustOperator(t, h.HTTP.URL+"/admin/hardware-trust/waiting", "alice-secret")
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	var out struct {
		WaitingTrust []map[string]any `json:"waiting_trust"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if len(out.WaitingTrust) != 4 {
		t.Fatalf("waiting list length = %d, want 4", len(out.WaitingTrust))
	}
	wantApprovable := map[float64]bool{7: true, 8: false, 9: false, 10: false}
	wantChipProfile := map[float64]bool{7: true, 8: false, 9: true, 10: false}
	for _, row := range out.WaitingTrust {
		jobID, _ := row["job_id"].(float64)
		approvable, ok := row["approvable"].(bool)
		if !ok {
			t.Fatalf("row %v missing approvable bool: %#v", jobID, row)
		}
		if approvable != wantApprovable[jobID] {
			t.Fatalf("job %v approvable = %t, want %t", jobID, approvable, wantApprovable[jobID])
		}
		chipProfilePresent, ok := row["chip_profile_present"].(bool)
		if !ok {
			t.Fatalf("row %v missing chip_profile_present bool: %#v", jobID, row)
		}
		if chipProfilePresent != wantChipProfile[jobID] {
			t.Fatalf("job %v chip_profile_present = %t, want %t", jobID, chipProfilePresent, wantChipProfile[jobID])
		}
	}
}

func TestHardwareTrustWaitingClampsLimitAndReturnsCursor(t *testing.T) {
	submitted := time.Date(2026, 7, 16, 11, 0, 0, 0, time.UTC)
	store := &fakeHardwareTrustAdminStore{waiting: []onboarding.WaitingTrustJob{
		{JobID: 11, ProviderID: "mac", SubmittedAt: submitted},
		{JobID: 12, ProviderID: "air", SubmittedAt: submitted},
	}}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithHardwareTrustAdminStore(store),
	}, func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	resp := getHardwareTrustOperator(t, h.HTTP.URL+"/admin/hardware-trust/waiting?after_id=5&limit=99999", "alice-secret")
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	if store.listAfterID != 5 {
		t.Fatalf("after_id passed to store = %d, want 5", store.listAfterID)
	}
	if store.listLimit != onboarding.WaitingTrustJobsPageCap {
		t.Fatalf("limit passed to store = %d, want clamp to %d", store.listLimit, onboarding.WaitingTrustJobsPageCap)
	}
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	// The page did not fill the cap, so no next cursor should be advertised.
	if _, ok := out["next_after_id"]; ok {
		t.Fatalf("unexpected next_after_id on a short page: %#v", out)
	}
}

func TestHardwareTrustWaitingAdvertisesNextCursorOnFullPage(t *testing.T) {
	store := &fakeHardwareTrustAdminStore{waiting: []onboarding.WaitingTrustJob{
		{JobID: 11, ProviderID: "mac"},
		{JobID: 12, ProviderID: "air"},
	}}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithHardwareTrustAdminStore(store),
	}, func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	resp := getHardwareTrustOperator(t, h.HTTP.URL+"/admin/hardware-trust/waiting?limit=2", "alice-secret")
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	if store.listLimit != 2 {
		t.Fatalf("limit passed to store = %d, want 2", store.listLimit)
	}
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if got, ok := out["next_after_id"].(float64); !ok || int64(got) != 12 {
		t.Fatalf("next_after_id = %#v, want 12", out["next_after_id"])
	}
}

func TestHardwareTrustRevokeInactivatesOperatorRoot(t *testing.T) {
	store := &fakeHardwareTrustAdminStore{revokeChip: "apple m4", revokeMemGB: 32}
	logs := &lockedBuffer{}
	h := newProviderHarnessWithServerOptionsAndLogger(t, nil, []providerws.Option{
		providerws.WithHardwareTrustAdminStore(store),
	}, zerolog.New(logs), func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	resp := postAuthPolicyOperatorJSON(t, h.HTTP.URL+"/admin/hardware-trust/revoke", "alice-secret", map[string]any{
		"provider_id":            "mac",
		"hardware_identity_hash": "hash-abc",
		"reason":                 "hardware retired",
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	if !store.revokeCalled {
		t.Fatal("revoke store was not called")
	}
	if store.revokeProvID != "mac" || store.revokeHash != "hash-abc" || store.revokedBy != "operator:alice" {
		t.Fatalf("stored revoke = %#v", store)
	}
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if out["status"] != "revoked" || out["provider_id"] != "mac" {
		t.Fatalf("revoke response = %#v", out)
	}
	if !strings.Contains(logs.String(), "hardware_trust_approval_revoked") {
		t.Fatalf("audit log missing revoke action: %s", logs.String())
	}
}

func TestHardwareTrustApproveReportsOperatorRevocable(t *testing.T) {
	// Terminal structural fix (issue #582): approval always writes the operator_api
	// trust row, so the response reports source=operator_api, operator_revocable=true,
	// the effective expiry, and no inventory-ride note.
	now := time.Date(2026, 7, 16, 12, 0, 0, 0, time.UTC)
	eff := now.Add(48 * time.Hour)
	store := &fakeHardwareTrustAdminStore{
		approveProviderID:      "mac",
		approveHash:            "hash-abc",
		approveChip:            "apple m4",
		approveMemGB:           32,
		approveReason:          "operator approved waiting_trust job",
		approveSource:          "operator_api",
		approveEffectiveExpiry: &eff,
	}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithNow(func() time.Time { return now }),
		providerws.WithHardwareTrustAdminStore(store),
	}, func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	resp := postAuthPolicyOperatorJSON(t, h.HTTP.URL+"/admin/hardware-trust/approve/4d2644a7-fc82-4750-b43f-2d9f73abc62a/approve", "bob-secret", map[string]string{})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if out["source"] != "operator_api" {
		t.Fatalf("source = %v, want operator_api: %#v", out["source"], out)
	}
	if revocable, _ := out["operator_revocable"].(bool); !revocable {
		t.Fatalf("operator_revocable = false, want true: %#v", out)
	}
	if out["effective_expires_at"] != eff.Format(time.RFC3339) {
		t.Fatalf("effective_expires_at = %v, want %s", out["effective_expires_at"], eff.Format(time.RFC3339))
	}
	if _, ok := out["note"]; ok {
		t.Fatalf("operator_api approval must not carry an inventory-ride note: %#v", out)
	}
}

func TestHardwareTrustRevokeEvictsActiveProviderSession(t *testing.T) {
	// FIX 1 (round-8): revoking a provider's trust root must evict its ACTIVE
	// websocket session (reusing the operator-disconnect drain→close path) so it must
	// reconnect and be re-admitted — then rejected by the live-trust admission join.
	// FIX 1 (round-12): eviction fires only when the provider is now FULLY untrusted
	// (revoking the SOLE operator_api root leaves no active trust root of any source).
	store := &fakeHardwareTrustAdminStore{revokeChip: "apple m4", revokeMemGB: 32, revokeNowUntrusted: true}
	logs := &lockedBuffer{}
	h := newProviderHarnessWithServerOptionsAndLogger(t, nil, []providerws.Option{
		providerws.WithHardwareTrustAdminStore(store),
	}, zerolog.New(logs), func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	// assertHelloAck connects provider "m4-anon" into the pool.
	assertHelloAck(t, conn)

	resp := postAuthPolicyOperatorJSON(t, h.HTTP.URL+"/admin/hardware-trust/revoke", "alice-secret", map[string]any{
		"provider_id":            "m4-anon",
		"hardware_identity_hash": "hash-abc",
		"reason":                 "hardware retired",
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}

	// The evicted provider must receive a drain frame, then the connection closes.
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	sawDrain := false
	for {
		payload, op, readErr := wsutil.ReadServerData(conn)
		if readErr != nil {
			break // eviction close frame tore the session down
		}
		if op == gobwas.OpText && strings.Contains(string(payload), `"type":"drain"`) {
			sawDrain = true
		}
	}
	if !sawDrain {
		t.Fatalf("evicted provider never received drain frame; logs=%s", logs.String())
	}
	if !strings.Contains(logs.String(), "hardware_trust_provider_evicted") {
		t.Fatalf("audit log missing eviction action: %s", logs.String())
	}
}

func TestHardwareTrustRevokeKeepsSessionWhenInventoryRootRemains(t *testing.T) {
	// FIX 1 (round-12, issue #582): revoking the operator_api root when an active
	// inventory root still backs the SAME hardware tuple must NOT evict the live
	// session — the provider stays inventory-trusted, so draining/closing it would
	// needlessly interrupt a still-valid session. The store reports
	// nowUntrusted=false and the handler leaves the session connected.
	store := &fakeHardwareTrustAdminStore{revokeChip: "apple m4", revokeMemGB: 32, revokeNowUntrusted: false}
	logs := &lockedBuffer{}
	h := newProviderHarnessWithServerOptionsAndLogger(t, nil, []providerws.Option{
		providerws.WithHardwareTrustAdminStore(store),
	}, zerolog.New(logs), func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	// assertHelloAck connects provider "m4-anon" into the pool.
	assertHelloAck(t, conn)

	resp := postAuthPolicyOperatorJSON(t, h.HTTP.URL+"/admin/hardware-trust/revoke", "alice-secret", map[string]any{
		"provider_id":            "m4-anon",
		"hardware_identity_hash": "hash-abc",
		"reason":                 "operator grant no longer needed",
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	if !store.revokeCalled {
		t.Fatal("revoke store was not called")
	}

	// The still-inventory-trusted provider must NOT receive a drain frame and its
	// session must stay open.
	_ = conn.SetReadDeadline(time.Now().Add(750 * time.Millisecond))
	for {
		payload, op, readErr := wsutil.ReadServerData(conn)
		if readErr != nil {
			break // read deadline elapsed with no eviction: session left connected
		}
		if op == gobwas.OpText && strings.Contains(string(payload), `"type":"drain"`) {
			t.Fatalf("inventory-trusted provider was drained despite remaining trusted; logs=%s", logs.String())
		}
	}
	if strings.Contains(logs.String(), "hardware_trust_provider_evicted") {
		t.Fatalf("session was evicted despite active inventory trust root: %s", logs.String())
	}
	if !strings.Contains(logs.String(), "leaving session connected") {
		t.Fatalf("audit log missing the still-trusted-leave-connected distinction: %s", logs.String())
	}
}

func TestHardwareTrustRevokeMapsRootNotFoundTo404(t *testing.T) {
	store := &fakeHardwareTrustAdminStore{revokeErr: &pq.Error{Code: "P0001", Message: "active operator_api trust root not found"}}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithHardwareTrustAdminStore(store),
	}, func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	resp := postAuthPolicyOperatorJSON(t, h.HTTP.URL+"/admin/hardware-trust/revoke", "alice-secret", map[string]any{
		"provider_id":            "mac",
		"hardware_identity_hash": "hash-none",
		"reason":                 "no such root",
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if errObj, _ := out["error"].(map[string]any); errObj["code"] != "hardware_trust_root_not_found" {
		t.Fatalf("error = %#v", out["error"])
	}
}

func getHardwareTrustOperator(t *testing.T, url, token string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	return resp
}

type fakeHardwareTrustAdminStore struct {
	requestCalled  bool
	pendingID      string
	jobID          int64
	requestedBy    string
	expiresAt      *time.Time
	reason         string
	incidentID     string
	requestErr     error
	requestProvID  string
	requestHash    string
	requestChip    string
	requestMemGB   int
	requestRetProv string

	approveCalled          bool
	approvedBy             string
	approveErr             error
	approveProviderID      string
	approveHash            string
	approveChip            string
	approveMemGB           int
	approveExpires         *time.Time
	approveReason          string
	approveIncidentID      string
	approveSource          string
	approveEffectiveExpiry *time.Time

	revokeCalled       bool
	revokeProvID       string
	revokeHash         string
	revokedBy          string
	revokeReason       string
	revokeChip         string
	revokeMemGB        int
	revokeNowUntrusted bool
	revokeErr          error

	listCalled  bool
	listAfterID int64
	listLimit   int
	waiting     []onboarding.WaitingTrustJob
	listErr     error
}

func (f *fakeHardwareTrustAdminStore) RequestHardwareTrustApproval(ctx context.Context, pendingID string, jobID int64, requestedBy string, expiresAt *time.Time, reason, incidentID string) (providerID, hardwareIdentityHash, chipNormalized string, unifiedMemoryGB int, err error) {
	f.requestCalled = true
	f.pendingID = pendingID
	f.jobID = jobID
	f.requestedBy = requestedBy
	f.expiresAt = expiresAt
	f.reason = reason
	f.incidentID = incidentID
	if f.requestErr != nil {
		err = f.requestErr
		return
	}
	return f.requestProvID, f.requestHash, f.requestChip, f.requestMemGB, nil
}

func (f *fakeHardwareTrustAdminStore) ApproveHardwareTrustApproval(ctx context.Context, pendingID, approvedBy string) (providerID, hardwareIdentityHash, chipNormalized string, unifiedMemoryGB int, expiresAt *time.Time, reason, incidentID, source string, effectiveExpiresAt *time.Time, err error) {
	f.approveCalled = true
	f.pendingID = pendingID
	f.approvedBy = approvedBy
	if f.approveErr != nil {
		err = f.approveErr
		return
	}
	return f.approveProviderID, f.approveHash, f.approveChip, f.approveMemGB, f.approveExpires, f.approveReason, f.approveIncidentID, f.approveSource, f.approveEffectiveExpiry, nil
}

func (f *fakeHardwareTrustAdminStore) RevokeHardwareTrustApproval(ctx context.Context, providerID, hardwareIdentityHash, revokedBy, reason string) (chipNormalized string, unifiedMemoryGB int, nowUntrusted bool, err error) {
	f.revokeCalled = true
	f.revokeProvID = providerID
	f.revokeHash = hardwareIdentityHash
	f.revokedBy = revokedBy
	f.revokeReason = reason
	if f.revokeErr != nil {
		err = f.revokeErr
		return
	}
	return f.revokeChip, f.revokeMemGB, f.revokeNowUntrusted, nil
}

func (f *fakeHardwareTrustAdminStore) ListWaitingTrustJobs(ctx context.Context, afterID int64, limit int) ([]onboarding.WaitingTrustJob, error) {
	f.listCalled = true
	f.listAfterID = afterID
	f.listLimit = limit
	return f.waiting, f.listErr
}
