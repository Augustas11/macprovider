package ws_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/providerevents"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

func TestAdminOnboardingRequiresOperatorAuth(t *testing.T) {
	h := newProviderHarnessWithServerOptions(t, nil, nil)
	defer h.HTTP.Close()

	resp, err := http.Get(h.HTTP.URL + "/admin/onboarding")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status=%d want 401", resp.StatusCode)
	}
}

func TestAdminOnboardingUnavailableWithoutAuthStore(t *testing.T) {
	h := newProviderHarnessWithServerOptions(t, nil, nil)
	defer h.HTTP.Close()

	req, err := http.NewRequest(http.MethodGet, h.HTTP.URL+"/admin/onboarding", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer test-operator-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status=%d want 503", resp.StatusCode)
	}
}

func TestAdminOnboardingJoinsInviteBootstrapAndLivePresence(t *testing.T) {
	authStore, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = authStore.Close() })
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	policy := auth.ReferralPolicy{
		RequireForRegistration: true,
		Campaign:               "prebeta_test",
		PolicyVersion:          "v1",
		CurrentKeyID:           "k1",
		HMACKeys:               map[string]string{"k1": strings.Repeat("s", 32)},
		ProviderBaseUses:       2,
	}
	if _, err := authStore.DB().Exec(`
INSERT INTO referral_issuers (
    issuer_id, code_type, key_id, campaign, provider_id,
    base_capacity, bonus_capacity, created_at, first_serving_at
) VALUES ('seedadmin', 'S', ?, ?, NULL, 2, 0, ?, ?)`,
		policy.CurrentKeyID, policy.Campaign, now.Format(time.RFC3339), now.Format(time.RFC3339),
	); err != nil {
		t.Fatal(err)
	}
	code, err := auth.EncodeReferralCode(policy, auth.ReferralTypeSeed, policy.CurrentKeyID, "seedadmin")
	if err != nil {
		t.Fatal(err)
	}

	pendingID := "mp-00000000000000000000000000000091"
	liveID := "mp-00000000000000000000000000000092"
	pendingMint, err := authStore.MintBootstrapToken(ctx, auth.BootstrapMintRequest{
		ProviderID: pendingID, ProviderName: "pending host", SourceIP: "192.0.2.91",
		ReceiptPubkey: bytes.Repeat([]byte{0x91}, 32), Now: now, TTL: time.Hour,
		PerIPLimitPerHour: 8, PerProviderPerHour: 3, GlobalLimitPerHour: 128,
		UnconfirmedIDMax: 64, OutstandingTokenMax: 64, IdentityRetention: 7 * 24 * time.Hour,
		ReferralCode: code, ReferralPolicy: policy,
	})
	if err != nil {
		t.Fatalf("pending mint: %v", err)
	}
	liveMint, err := authStore.MintBootstrapToken(ctx, auth.BootstrapMintRequest{
		ProviderID: liveID, ProviderName: "live host", SourceIP: "192.0.2.92",
		ReceiptPubkey: bytes.Repeat([]byte{0x92}, 32), Now: now, TTL: time.Hour,
		PerIPLimitPerHour: 8, PerProviderPerHour: 3, GlobalLimitPerHour: 128,
		UnconfirmedIDMax: 64, OutstandingTokenMax: 64, IdentityRetention: 7 * 24 * time.Hour,
		ReferralCode: code, ReferralPolicy: policy,
	})
	if err != nil {
		t.Fatalf("live mint: %v", err)
	}
	if err := authStore.MarkTokenUsed(ctx, liveMint.ProviderToken); err != nil {
		t.Fatalf("confirm live: %v", err)
	}

	events := newConnectionEventStore(t)
	if err := events.Record(ctx, providerevents.Event{
		ProviderID:    pendingID,
		Kind:          providerevents.KindAuthRejected,
		Outcome:       providerevents.OutcomeFailure,
		FailureReason: providerevents.ReasonInvalidToken,
		OccurredAt:    now.Add(30 * time.Second),
		Diagnostic:    "Authorization: Bearer mpk_should_redact",
	}); err != nil {
		t.Fatal(err)
	}

	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithGitHubAuthStore(authStore),
		providerws.WithConnectionEventStore(events),
		providerws.WithNow(func() time.Time { return now.Add(time.Minute) }),
	})
	defer h.HTTP.Close()

	if _, ok := h.Registry.Register(&pool.Provider{
		ProviderID:      liveID,
		AssignedID:      "asg-live",
		State:           pool.StateReady,
		LastHeartbeatAt: now.Add(45 * time.Second),
		ConnectedAt:     now.Add(40 * time.Second),
	}, nil); !ok {
		t.Fatal("register live provider failed")
	}

	req, err := http.NewRequest(http.MethodGet, h.HTTP.URL+"/admin/onboarding", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer test-operator-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	if strings.Contains(string(body), code) || strings.Contains(string(body), pendingMint.ProviderToken) ||
		strings.Contains(string(body), liveMint.ProviderToken) || strings.Contains(string(body), "code_digest") ||
		strings.Contains(string(body), "invite_code") || strings.Contains(string(body), "receipt_pubkey") {
		t.Fatalf("response leaked secret material: %s", body)
	}

	var decoded struct {
		Attempts []map[string]any `json:"attempts"`
		Summary  map[string]any   `json:"summary"`
	}
	if err := json.Unmarshal(body, &decoded); err != nil {
		t.Fatalf("decode: %v body=%s", err, body)
	}
	if decoded.Summary["pending"] != float64(1) || decoded.Summary["live"] != float64(1) {
		t.Fatalf("summary=%v", decoded.Summary)
	}
	byID := map[string]map[string]any{}
	for _, attempt := range decoded.Attempts {
		id, _ := attempt["provider_id"].(string)
		byID[id] = attempt
	}
	if byID[pendingID]["onboarding_state"] != "pending" || byID[pendingID]["last_failure_reason"] != providerevents.ReasonInvalidToken {
		t.Fatalf("pending=%v", byID[pendingID])
	}
	if byID[liveID]["onboarding_state"] != "live" || byID[liveID]["presence"] != "connected" {
		t.Fatalf("live=%v", byID[liveID])
	}

	filterReq, err := http.NewRequest(http.MethodGet, h.HTTP.URL+"/admin/onboarding?state=failed_expired", nil)
	if err != nil {
		t.Fatal(err)
	}
	filterReq.Header.Set("Authorization", "Bearer test-operator-key")
	filterResp, err := http.DefaultClient.Do(filterReq)
	if err != nil {
		t.Fatal(err)
	}
	defer filterResp.Body.Close()
	var filtered struct {
		Attempts []map[string]any `json:"attempts"`
		Summary  map[string]any   `json:"summary"`
	}
	if err := json.NewDecoder(filterResp.Body).Decode(&filtered); err != nil {
		t.Fatal(err)
	}
	if len(filtered.Attempts) != 0 {
		t.Fatalf("filtered attempts=%v", filtered.Attempts)
	}
	if filtered.Summary["pending"] != float64(1) {
		t.Fatalf("filter should keep unfiltered summary: %v", filtered.Summary)
	}

	pageReq, err := http.NewRequest(http.MethodGet, h.HTTP.URL+"/admin/onboarding?limit=1", nil)
	if err != nil {
		t.Fatal(err)
	}
	pageReq.Header.Set("Authorization", "Bearer test-operator-key")
	pageResp, err := http.DefaultClient.Do(pageReq)
	if err != nil {
		t.Fatal(err)
	}
	defer pageResp.Body.Close()
	var firstPage struct {
		Attempts    []map[string]any `json:"attempts"`
		NextAfter   string           `json:"next_after"`
		NextAfterTS string           `json:"next_after_ts"`
	}
	if err := json.NewDecoder(pageResp.Body).Decode(&firstPage); err != nil {
		t.Fatal(err)
	}
	if len(firstPage.Attempts) != 1 || firstPage.NextAfter == "" || firstPage.NextAfterTS == "" {
		t.Fatalf("first page=%+v", firstPage)
	}
	secondQuery := url.Values{}
	secondQuery.Set("limit", "1")
	secondQuery.Set("after", firstPage.NextAfter)
	secondQuery.Set("after_ts", firstPage.NextAfterTS)
	secondReq, err := http.NewRequest(http.MethodGet, h.HTTP.URL+"/admin/onboarding?"+secondQuery.Encode(), nil)
	if err != nil {
		t.Fatal(err)
	}
	secondReq.Header.Set("Authorization", "Bearer test-operator-key")
	secondResp, err := http.DefaultClient.Do(secondReq)
	if err != nil {
		t.Fatal(err)
	}
	defer secondResp.Body.Close()
	var secondPage struct {
		Attempts  []map[string]any `json:"attempts"`
		NextAfter string           `json:"next_after"`
	}
	if err := json.NewDecoder(secondResp.Body).Decode(&secondPage); err != nil {
		t.Fatal(err)
	}
	if len(secondPage.Attempts) != 1 {
		t.Fatalf("second page=%+v", secondPage)
	}
	firstID, _ := firstPage.Attempts[0]["provider_id"].(string)
	secondID, _ := secondPage.Attempts[0]["provider_id"].(string)
	if firstID == "" || firstID == secondID {
		t.Fatalf("pages overlapped: %q %q", firstID, secondID)
	}

	incompleteReq, err := http.NewRequest(http.MethodGet, h.HTTP.URL+"/admin/onboarding?after="+url.QueryEscape(firstID), nil)
	if err != nil {
		t.Fatal(err)
	}
	incompleteReq.Header.Set("Authorization", "Bearer test-operator-key")
	incompleteResp, err := http.DefaultClient.Do(incompleteReq)
	if err != nil {
		t.Fatal(err)
	}
	defer incompleteResp.Body.Close()
	if incompleteResp.StatusCode != http.StatusBadRequest {
		t.Fatalf("incomplete cursor status=%d want 400", incompleteResp.StatusCode)
	}
}

func TestAdminOnboardingRejectsGatewayServiceToken(t *testing.T) {
	h := newProviderHarnessWithServerOptions(t, nil, nil, func(cfg *config.Config) {
		cfg.Auth.GatewayServiceToken = "service-secret"
	})
	defer h.HTTP.Close()

	req, err := http.NewRequest(http.MethodGet, h.HTTP.URL+"/admin/onboarding", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer service-secret")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status=%d want 401", resp.StatusCode)
	}
}
