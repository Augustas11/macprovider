package ws_test

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/config"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

func TestProviderAuthPolicyExemptionRequestCreatesPendingRow(t *testing.T) {
	now := time.Date(2026, 7, 3, 12, 0, 0, 0, time.UTC)
	store := &fakeAuthPolicyAdminStore{}
	logs := &lockedBuffer{}
	h := newProviderHarnessWithServerOptionsAndLogger(t, nil, []providerws.Option{
		providerws.WithNow(func() time.Time { return now }),
		providerws.WithIdentitySignatureStore(&fakeIdentitySignatureStore{identityPubkey: bytes.Repeat([]byte{0x11}, 32), identityOK: true}),
		providerws.WithProviderAuthPolicyAdminStore(store),
	}, zerolog.New(logs), func(cfg *config.Config) {
		cfg.Auth.OperatorKey = "test-operator-key"
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	resp := postAuthPolicyOperatorJSON(t, h.HTTP.URL+"/admin/provider-auth-policy/exempt", "alice-secret", map[string]string{
		"provider_id":     "p_existing",
		"requested_until": now.Add(6 * 24 * time.Hour).Format(time.RFC3339),
		"reason":          "legacy client remediation",
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusAccepted {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	if !store.requestCalled {
		t.Fatal("request store was not called")
	}
	if store.providerID != "p_existing" || store.requestedBy != "operator:alice" || store.reason != "legacy client remediation" || store.incidentID != "" {
		t.Fatalf("stored request = %#v", store)
	}
	if !store.requestedUntil.Equal(now.Add(6 * 24 * time.Hour)) {
		t.Fatalf("requested_until = %s", store.requestedUntil)
	}
	logBody := logs.String()
	if !strings.Contains(logBody, "exempt_provider_id_requested") || !strings.Contains(logBody, "operator:alice") {
		t.Fatalf("audit log missing request action/actor: %s", logBody)
	}
}

func TestProviderAuthPolicyExemptionRequestRequiresIncidentOverSevenDays(t *testing.T) {
	now := time.Date(2026, 7, 3, 12, 0, 0, 0, time.UTC)
	store := &fakeAuthPolicyAdminStore{}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithNow(func() time.Time { return now }),
		providerws.WithIdentitySignatureStore(&fakeIdentitySignatureStore{identityPubkey: bytes.Repeat([]byte{0x12}, 32), identityOK: true}),
		providerws.WithProviderAuthPolicyAdminStore(store),
	}, func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	resp := postAuthPolicyOperatorJSON(t, h.HTTP.URL+"/admin/provider-auth-policy/exempt", "alice-secret", map[string]string{
		"provider_id":     "p_existing",
		"requested_until": now.Add(8 * 24 * time.Hour).Format(time.RFC3339),
		"reason":          "long remediation",
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	if store.requestCalled {
		t.Fatal("request store called despite missing incident_id")
	}
}

func TestProviderAuthPolicyExemptionRequestRequiresExistingProvider(t *testing.T) {
	now := time.Date(2026, 7, 3, 12, 0, 0, 0, time.UTC)
	store := &fakeAuthPolicyAdminStore{}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithNow(func() time.Time { return now }),
		providerws.WithIdentitySignatureStore(&fakeIdentitySignatureStore{}),
		providerws.WithProviderAuthPolicyAdminStore(store),
	}, func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	resp := postAuthPolicyOperatorJSON(t, h.HTTP.URL+"/admin/provider-auth-policy/exempt", "alice-secret", map[string]string{
		"provider_id":     "p_missing",
		"requested_until": now.Add(24 * time.Hour).Format(time.RFC3339),
		"reason":          "missing provider",
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	if store.requestCalled {
		t.Fatal("request store called for missing provider")
	}
}

func TestProviderAuthPolicyExemptionApproveMapsDualControlToForbidden(t *testing.T) {
	store := &fakeAuthPolicyAdminStore{approveErr: errors.New("dual_control_required")}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithProviderAuthPolicyAdminStore(store),
	}, func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	resp := postAuthPolicyOperatorJSON(t, h.HTTP.URL+"/admin/provider-auth-policy/exempt/4d2644a7-fc82-4750-b43f-2d9f73abc62a/approve", "alice-secret", map[string]string{})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	if !store.approveCalled {
		t.Fatal("approve store was not called")
	}
}

func TestProviderAuthPolicyExemptionApproveCommitsPendingRow(t *testing.T) {
	now := time.Date(2026, 7, 3, 12, 0, 0, 0, time.UTC)
	store := &fakeAuthPolicyAdminStore{
		approveProviderID:     "p_existing",
		approveRequestedBy:    "operator:alice",
		approveRequestedUntil: now.Add(24 * time.Hour),
		approveReason:         "legacy client remediation",
		approveIncidentID:     "INC-1",
	}
	logs := &lockedBuffer{}
	h := newProviderHarnessWithServerOptionsAndLogger(t, nil, []providerws.Option{
		providerws.WithNow(func() time.Time { return now }),
		providerws.WithProviderAuthPolicyAdminStore(store),
	}, zerolog.New(logs), func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	resp := postAuthPolicyOperatorJSON(t, h.HTTP.URL+"/admin/provider-auth-policy/exempt/4d2644a7-fc82-4750-b43f-2d9f73abc62a/approve", "bob-secret", map[string]string{})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	if store.approvedBy != "operator:bob" {
		t.Fatalf("approved_by = %q", store.approvedBy)
	}
	logBody := logs.String()
	if !strings.Contains(logBody, "exempt_provider_id_approved") || !strings.Contains(logBody, "operator:bob") {
		t.Fatalf("audit log missing approval action/actor: %s", logBody)
	}
}

func TestProviderAuthPolicyExemptionRejectsSpoofedBodyActor(t *testing.T) {
	now := time.Date(2026, 7, 3, 12, 0, 0, 0, time.UTC)
	store := &fakeAuthPolicyAdminStore{}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithNow(func() time.Time { return now }),
		providerws.WithIdentitySignatureStore(&fakeIdentitySignatureStore{identityPubkey: bytes.Repeat([]byte{0x13}, 32), identityOK: true}),
		providerws.WithProviderAuthPolicyAdminStore(store),
	}, func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	resp := postAuthPolicyOperatorJSON(t, h.HTTP.URL+"/admin/provider-auth-policy/exempt", "alice-secret", map[string]string{
		"provider_id":     "p_existing",
		"requested_by":    "operator:bob",
		"requested_until": now.Add(24 * time.Hour).Format(time.RFC3339),
		"reason":          "spoof attempt",
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

func TestProviderAuthPolicyExemptionRejectsLegacySharedOperatorKey(t *testing.T) {
	now := time.Date(2026, 7, 3, 12, 0, 0, 0, time.UTC)
	store := &fakeAuthPolicyAdminStore{}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithNow(func() time.Time { return now }),
		providerws.WithIdentitySignatureStore(&fakeIdentitySignatureStore{identityPubkey: bytes.Repeat([]byte{0x14}, 32), identityOK: true}),
		providerws.WithProviderAuthPolicyAdminStore(store),
	}, func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	resp := postAuthPolicyOperatorJSON(t, h.HTTP.URL+"/admin/provider-auth-policy/exempt", "test-operator-key", map[string]string{
		"provider_id":     "p_existing",
		"requested_until": now.Add(24 * time.Hour).Format(time.RFC3339),
		"reason":          "legacy key attempt",
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	if store.requestCalled {
		t.Fatal("request store called despite legacy shared operator key")
	}
}

func TestProviderAuthPolicySeedCutoverSnapshotsActiveCLIProviders(t *testing.T) {
	now := time.Date(2100, 7, 3, 12, 0, 0, 0, time.UTC)
	tokenStore, err := auth.OpenStore(filepath.Join(t.TempDir(), "tokens.db"))
	if err != nil {
		t.Fatalf("open token store: %v", err)
	}
	defer tokenStore.Close()
	if _, _, err := tokenStore.IssueToken(context.Background(), "cli-existing", "CLI existing"); err != nil {
		t.Fatalf("issue token: %v", err)
	}
	store := &fakeAuthPolicyAdminStore{seeded: 3}
	logs := &lockedBuffer{}
	h := newProviderHarnessWithServerOptionsAndLogger(t, nil, []providerws.Option{
		providerws.WithNow(func() time.Time { return now }),
		providerws.WithGitHubAuthStore(tokenStore),
		providerws.WithProviderAuthPolicyAdminStore(store),
	}, zerolog.New(logs), func(cfg *config.Config) {
		cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	})
	defer h.HTTP.Close()

	resp := postAuthPolicyOperatorJSON(t, h.HTTP.URL+"/admin/provider-auth-policy/seed-cutover", "alice-secret", map[string]string{
		"confirm": "spec-026-cutover",
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	if !store.seedCalled {
		t.Fatal("seed store was not called")
	}
	if !store.cutover.Equal(now) {
		t.Fatalf("cutover = %s", store.cutover)
	}
	if len(store.cliProviderIDs) != 1 || store.cliProviderIDs[0] != "cli-existing" {
		t.Fatalf("cliProviderIDs = %#v", store.cliProviderIDs)
	}
	logBody := logs.String()
	if !strings.Contains(logBody, "provider_auth_policy_cutover_seeded") || !strings.Contains(logBody, "operator:alice") {
		t.Fatalf("audit log missing cutover action/actor: %s", logBody)
	}
}

func postAuthPolicyOperatorJSON(t *testing.T, url, token string, body any) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(mustJSON(body)))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	return resp
}

type fakeAuthPolicyAdminStore struct {
	requestCalled  bool
	pendingID      string
	providerID     string
	requestedBy    string
	requestedUntil time.Time
	reason         string
	incidentID     string
	requestErr     error

	approveCalled         bool
	approvedBy            string
	approveErr            error
	approveProviderID     string
	approveRequestedBy    string
	approveRequestedUntil time.Time
	approveReason         string
	approveIncidentID     string

	seedCalled     bool
	cutover        time.Time
	cliProviderIDs []string
	seeded         int64
	seedErr        error
}

func (f *fakeAuthPolicyAdminStore) RequestProviderAuthPolicyExemption(ctx context.Context, pendingID, providerID, requestedBy string, requestedUntil time.Time, reason, incidentID string) error {
	f.requestCalled = true
	f.pendingID = pendingID
	f.providerID = providerID
	f.requestedBy = requestedBy
	f.requestedUntil = requestedUntil
	f.reason = reason
	f.incidentID = incidentID
	return f.requestErr
}

func (f *fakeAuthPolicyAdminStore) ApproveProviderAuthPolicyExemption(ctx context.Context, pendingID, approvedBy string) (providerID, requestedBy string, requestedUntil time.Time, reason, incidentID string, err error) {
	f.approveCalled = true
	f.pendingID = pendingID
	f.approvedBy = approvedBy
	if f.approveErr != nil {
		err = f.approveErr
		return
	}
	return f.approveProviderID, f.approveRequestedBy, f.approveRequestedUntil, f.approveReason, f.approveIncidentID, nil
}

func (f *fakeAuthPolicyAdminStore) SeedProviderAuthPolicyCutover(ctx context.Context, cutover time.Time, cliProviderIDs []string) (int64, error) {
	f.seedCalled = true
	f.cutover = cutover
	f.cliProviderIDs = append([]string(nil), cliProviderIDs...)
	return f.seeded, f.seedErr
}
