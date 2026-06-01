package router

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/storage"
)

func TestAC03_GatewayExplorerRoutesUseSharedAdminBearer(t *testing.T) {
	h, store, _, cfg := newTestHarness(t, fakeOAuth{})
	seedExplorerBuyer(t, store, "acct_gateway_auth", "auth@example.test")

	assertStatus(t, h, http.MethodGet, "/admin/explorer/buyers", "bogus", "", "", http.StatusUnauthorized)
	resp := assertStatus(t, h, http.MethodGet, "/admin/explorer/buyers", cfg.Coordinator.OperatorKey, "", "", http.StatusOK)

	var body struct {
		Items []map[string]any `json:"items"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("explorer buyers json: %v", err)
	}
	if len(body.Items) != 1 || body.Items[0]["account_id"] != "acct_gateway_auth" {
		t.Fatalf("unexpected buyers response: %s", resp.Body.String())
	}
}

func TestAC04_GatewayExplorerRoutesRejectNonAdminBearers(t *testing.T) {
	h, store, _, _ := newTestHarness(t, fakeOAuth{})
	seedExplorerBuyer(t, store, "acct_non_admin", "nonadmin@example.test")

	for _, bearer := range []string{"mp_acct_non_admin", "demo_session_token"} {
		resp := assertStatus(t, h, http.MethodGet, "/admin/explorer/buyers", bearer, "", "", http.StatusUnauthorized)
		assertErrorCode(t, resp.Body.String(), "invalid_operator_token")
	}
}

func TestAC22_BuyerAPIKeyHashHidden(t *testing.T) {
	h, store, _, cfg := newTestHarness(t, fakeOAuth{})
	seedExplorerBuyer(t, store, "acct_hash_hidden", "hash@example.test")

	resp := assertStatus(t, h, http.MethodGet, "/admin/explorer/buyers/acct_hash_hidden", cfg.Coordinator.OperatorKey, "", "", http.StatusOK)
	body := resp.Body.String()
	if !strings.Contains(body, "mp_acct_hash_hidden") {
		t.Fatalf("key prefix missing: %s", body)
	}
	if strings.Contains(body, "acct_hash_hidden_hash") {
		t.Fatalf("full key hash leaked: %s", body)
	}
}

func TestAC29_BuyerEmailFilterSemantics(t *testing.T) {
	h, store, _, cfg := newTestHarness(t, fakeOAuth{})
	seedExplorerBuyer(t, store, "acct_a", "a@x")
	seedExplorerBuyer(t, store, "acct_ab_lower", "ab@x")
	seedExplorerBuyer(t, store, "acct_ab_mixed", "aB@x")

	resp := assertStatus(t, h, http.MethodGet, "/admin/explorer/buyers?email=ab@x", cfg.Coordinator.OperatorKey, "", "", http.StatusOK)
	assertExplorerAccounts(t, resp.Body.Bytes(), "acct_ab_lower")

	resp = assertStatus(t, h, http.MethodGet, "/admin/explorer/buyers?email_prefix=a", cfg.Coordinator.OperatorKey, "", "", http.StatusOK)
	assertExplorerAccounts(t, resp.Body.Bytes(), "acct_a", "acct_ab_lower", "acct_ab_mixed")

	resp = assertStatus(t, h, http.MethodGet, "/admin/explorer/buyers?email_prefix=aB", cfg.Coordinator.OperatorKey, "", "", http.StatusOK)
	assertExplorerAccounts(t, resp.Body.Bytes(), "acct_ab_mixed")

	resp = assertStatus(t, h, http.MethodGet, "/admin/explorer/buyers?email=a@x&email_prefix=a", cfg.Coordinator.OperatorKey, "", "", http.StatusBadRequest)
	assertErrorCode(t, resp.Body.String(), "bad_request")
}

func TestGatewayExplorerMalformedCursorsReturnBadRequest(t *testing.T) {
	h, _, _, cfg := newTestHarness(t, fakeOAuth{})
	for _, path := range []string{
		"/admin/explorer/buyers?cursor=!!",
		"/admin/explorer/sessions?cursor=!!",
		"/admin/explorer/activity?cursor=!!",
	} {
		resp := assertStatus(t, h, http.MethodGet, path, cfg.Coordinator.OperatorKey, "", "", http.StatusBadRequest)
		assertErrorCode(t, resp.Body.String(), "bad_request")
	}
}

func TestGatewayExplorerRejectsOverWideWindows(t *testing.T) {
	h, _, _, cfg := newTestHarness(t, fakeOAuth{})
	resp := assertStatus(t, h, http.MethodGet, "/admin/explorer/activity?window_hours=9999", cfg.Coordinator.OperatorKey, "", "", http.StatusBadRequest)
	assertErrorCode(t, resp.Body.String(), "bad_request")
	from := fixedNow().Add(-32 * 24 * time.Hour).Format(time.RFC3339)
	to := fixedNow().Format(time.RFC3339)
	resp = assertStatus(t, h, http.MethodGet, "/admin/explorer/buyers?from="+from+"&to="+to, cfg.Coordinator.OperatorKey, "", "", http.StatusBadRequest)
	assertErrorCode(t, resp.Body.String(), "bad_request")
}

func TestGatewayExplorerDisabledReturnsNotFound(t *testing.T) {
	h, _, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Explorer.Enabled = false
	})
	assertStatus(t, h, http.MethodGet, "/admin/explorer/buyers", cfg.Coordinator.OperatorKey, "", "", http.StatusNotFound)
}

func TestGatewayExplorerDoesNotAuditUnauthenticatedInternalHeaderProbe(t *testing.T) {
	h, _, dbPath, _ := newTestHarness(t, fakeOAuth{})
	req := httptest.NewRequest(http.MethodGet, "/admin/explorer/buyers", nil)
	req.Header.Set("X-MacProvider-Internal-Conv", "conv:attacker")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if got := countAuditEvents(t, dbPath, "internal_header_injection_stripped"); got != 0 {
		t.Fatalf("explorer audit events=%d want 0", got)
	}
}

func seedExplorerBuyer(t *testing.T, store interface {
	CreateAccount(context.Context, storage.Account) error
	AddAccountIdentity(context.Context, storage.AccountIdentity) error
	CreateAPIKey(context.Context, storage.APIKey) error
}, accountID, email string) {
	t.Helper()
	ctx := context.Background()
	if err := store.CreateAccount(ctx, storage.Account{
		AccountID: accountID, Status: "active", QuotaClass: "default", ConcurrencyClass: "default", CreatedAt: fixedNow(),
	}); err != nil {
		t.Fatalf("CreateAccount(%s): %v", accountID, err)
	}
	if err := store.AddAccountIdentity(ctx, storage.AccountIdentity{
		AccountID: accountID, Provider: "github", ProviderUserID: accountID, Email: email, CreatedAt: fixedNow(),
	}); err != nil {
		t.Fatalf("AddAccountIdentity(%s): %v", accountID, err)
	}
	if err := store.CreateAPIKey(ctx, storage.APIKey{
		KeyID: accountID + "_key", AccountID: accountID, KeyHash: []byte(accountID + "_hash"),
		KeyHashPrefix: "mp_" + accountID, Status: "active", CreatedAt: fixedNow(),
	}); err != nil {
		t.Fatalf("CreateAPIKey(%s): %v", accountID, err)
	}
}

func assertExplorerAccounts(t *testing.T, body []byte, want ...string) {
	t.Helper()
	var decoded struct {
		Items []struct {
			AccountID string `json:"account_id"`
		} `json:"items"`
	}
	if err := json.Unmarshal(body, &decoded); err != nil {
		t.Fatalf("decode buyers: %v", err)
	}
	got := map[string]bool{}
	for _, item := range decoded.Items {
		got[item.AccountID] = true
	}
	if len(got) != len(want) {
		t.Fatalf("accounts=%v want=%v body=%s", got, want, string(body))
	}
	for _, id := range want {
		if !got[id] {
			t.Fatalf("accounts=%v missing %s body=%s", got, id, string(body))
		}
	}
}
