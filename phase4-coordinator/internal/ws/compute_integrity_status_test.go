package ws_test

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/computeintegrity"
	"github.com/augstar/macprovider-coordinator/internal/config"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

type fakeComputeIntegrityStatusSource struct {
	statuses map[string][]computeintegrity.StatusSnapshot
}

func (f fakeComputeIntegrityStatusSource) ComputeIntegrityStatus(_ context.Context, providerID string) ([]computeintegrity.StatusSnapshot, error) {
	return append([]computeintegrity.StatusSnapshot(nil), f.statuses[providerID]...), nil
}

type fakeComputeIntegrityTokens map[string]string

func (f fakeComputeIntegrityTokens) ValidateToken(_ context.Context, raw string) (string, bool, error) {
	providerID, ok := f[raw]
	return providerID, ok, nil
}

func (f fakeComputeIntegrityTokens) MarkTokenUsed(context.Context, string) error { return nil }

func (f fakeComputeIntegrityTokens) ValidateAndMarkTokenUsed(ctx context.Context, raw string) (string, bool, error) {
	return f.ValidateToken(ctx, raw)
}

func (f fakeComputeIntegrityTokens) ValidateTokenReadOnly(ctx context.Context, raw string) (string, bool, error) {
	return f.ValidateToken(ctx, raw)
}

type readOnlyOnlyComputeIntegrityTokens struct {
	readOnlyCalls int
	mutatingCalls int
	providerID    string
}

func (f *readOnlyOnlyComputeIntegrityTokens) ValidateToken(context.Context, string) (string, bool, error) {
	f.mutatingCalls++
	return "", false, errors.New("mutating validator must not be called")
}

func (f *readOnlyOnlyComputeIntegrityTokens) MarkTokenUsed(context.Context, string) error {
	return nil
}

func (f *readOnlyOnlyComputeIntegrityTokens) ValidateAndMarkTokenUsed(context.Context, string) (string, bool, error) {
	f.mutatingCalls++
	return "", false, errors.New("mutating validator must not be called")
}

func (f *readOnlyOnlyComputeIntegrityTokens) ValidateTokenReadOnly(context.Context, string) (string, bool, error) {
	f.readOnlyCalls++
	return f.providerID, true, nil
}

func TestComputeIntegrityStatusOperatorAndProviderEndpoints(t *testing.T) {
	source := fakeComputeIntegrityStatusSource{
		statuses: map[string][]computeintegrity.StatusSnapshot{
			"provider-a": {{
				Type:                  computeintegrity.StatusType,
				SchemaVersion:         computeintegrity.StatusSchema,
				ProviderID:            "provider-a",
				PolicyMode:            computeintegrity.ModeWarnOnly,
				State:                 computeintegrity.StateWarn,
				SettlementEffect:      "telemetry_only",
				ProviderReadiness:     "warn",
				ProviderStatusMessage: "compute-integrity warn state is readiness telemetry only",
				Disclosure:            computeintegrity.StatusCopyV1,
				Evidence: computeintegrity.StatusEvidenceDigests{
					ReferenceEventDigests: []string{"sha256:ref-a"},
					LatestCanaryDigests:   []string{"sha256:canary-a"},
				},
			}},
		},
	}
	h := newProviderHarnessWithServerOptions(t, fakeComputeIntegrityTokens{"good": "provider-a"}, []providerws.Option{
		providerws.WithComputeIntegrityStatusSource(source),
	}, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = true
	})
	defer h.HTTP.Close()

	operatorReq, err := http.NewRequest(http.MethodGet, h.HTTP.URL+"/admin/compute-integrity/provider-a", nil)
	if err != nil {
		t.Fatalf("operator request: %v", err)
	}
	operatorReq.Header.Set("Authorization", "Bearer test-operator-key")
	operatorResp, err := http.DefaultClient.Do(operatorReq)
	if err != nil {
		t.Fatalf("operator GET: %v", err)
	}
	defer operatorResp.Body.Close()
	if operatorResp.StatusCode != http.StatusOK {
		t.Fatalf("operator status=%d", operatorResp.StatusCode)
	}
	var operatorBody struct {
		ProviderID string                            `json:"provider_id"`
		Statuses   []computeintegrity.StatusSnapshot `json:"statuses"`
		Disclosure string                            `json:"disclosure"`
	}
	if err := json.NewDecoder(operatorResp.Body).Decode(&operatorBody); err != nil {
		t.Fatalf("decode operator body: %v", err)
	}
	if operatorBody.ProviderID != "provider-a" || len(operatorBody.Statuses) != 1 {
		t.Fatalf("operator body = %#v", operatorBody)
	}
	if operatorBody.Statuses[0].ProviderReadiness != "warn" || operatorBody.Statuses[0].Evidence.ReferenceEventDigests[0] != "sha256:ref-a" {
		t.Fatalf("operator status missing telemetry: %#v", operatorBody.Statuses[0])
	}

	providerReq, err := http.NewRequest(http.MethodGet, h.HTTP.URL+"/v1/provider/compute-integrity", nil)
	if err != nil {
		t.Fatalf("provider request: %v", err)
	}
	providerReq.Header.Set("Authorization", "Bearer good")
	providerResp, err := http.DefaultClient.Do(providerReq)
	if err != nil {
		t.Fatalf("provider GET: %v", err)
	}
	defer providerResp.Body.Close()
	if providerResp.StatusCode != http.StatusOK {
		t.Fatalf("provider status=%d", providerResp.StatusCode)
	}
	var providerBody struct {
		ProviderID string                            `json:"provider_id"`
		Statuses   []computeintegrity.StatusSnapshot `json:"statuses"`
		Disclosure string                            `json:"disclosure"`
	}
	if err := json.NewDecoder(providerResp.Body).Decode(&providerBody); err != nil {
		t.Fatalf("decode provider body: %v", err)
	}
	if providerBody.ProviderID != "provider-a" || len(providerBody.Statuses) != 1 {
		t.Fatalf("provider body = %#v", providerBody)
	}
	if providerBody.Statuses[0].ProviderStatusMessage == "" || providerBody.Disclosure != computeintegrity.StatusCopyV1 {
		t.Fatalf("provider response missing status message/disclosure: %#v", providerBody.Statuses[0])
	}
}

func TestComputeIntegrityProviderEndpointRequiresTokenAndSource(t *testing.T) {
	h := newProviderHarnessWithServerOptions(t, fakeComputeIntegrityTokens{"good": "provider-a"}, nil, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = true
	})
	defer h.HTTP.Close()

	req, err := http.NewRequest(http.MethodGet, h.HTTP.URL+"/v1/provider/compute-integrity", nil)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer good")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status=%d want 503", resp.StatusCode)
	}

	source := fakeComputeIntegrityStatusSource{statuses: map[string][]computeintegrity.StatusSnapshot{}}
	h2 := newProviderHarnessWithServerOptions(t, fakeComputeIntegrityTokens{"good": "provider-a"}, []providerws.Option{
		providerws.WithComputeIntegrityStatusSource(source),
	}, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = true
	})
	defer h2.HTTP.Close()
	unauth, err := http.Get(h2.HTTP.URL + "/v1/provider/compute-integrity")
	if err != nil {
		t.Fatalf("unauth GET: %v", err)
	}
	defer unauth.Body.Close()
	if unauth.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauth status=%d want 401", unauth.StatusCode)
	}
}

func TestComputeIntegrityProviderEndpointUsesReadOnlyTokenValidation(t *testing.T) {
	tokens := &readOnlyOnlyComputeIntegrityTokens{providerID: "provider-a"}
	h := newProviderHarnessWithServerOptions(t, tokens, []providerws.Option{
		providerws.WithComputeIntegrityStatusSource(fakeComputeIntegrityStatusSource{
			statuses: map[string][]computeintegrity.StatusSnapshot{
				"provider-a": {{ProviderID: "provider-a"}},
			},
		}),
	}, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = true
	})
	defer h.HTTP.Close()

	req, err := http.NewRequest(http.MethodGet, h.HTTP.URL+"/v1/provider/compute-integrity", nil)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer good")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("provider GET: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d", resp.StatusCode)
	}
	if tokens.readOnlyCalls != 1 {
		t.Fatalf("read-only validation calls=%d, want 1", tokens.readOnlyCalls)
	}
	if tokens.mutatingCalls != 0 {
		t.Fatalf("mutating validation calls=%d, want 0", tokens.mutatingCalls)
	}
}

func TestComputeIntegrityProviderEndpointRejectsMismatchedProviderStatus(t *testing.T) {
	source := fakeComputeIntegrityStatusSource{
		statuses: map[string][]computeintegrity.StatusSnapshot{
			"provider-a": {{ProviderID: "provider-b"}},
		},
	}
	h := newProviderHarnessWithServerOptions(t, fakeComputeIntegrityTokens{"good": "provider-a"}, []providerws.Option{
		providerws.WithComputeIntegrityStatusSource(source),
	}, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = true
	})
	defer h.HTTP.Close()

	req, err := http.NewRequest(http.MethodGet, h.HTTP.URL+"/v1/provider/compute-integrity", nil)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer good")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("provider GET: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusInternalServerError {
		t.Fatalf("status=%d want 500", resp.StatusCode)
	}
}
