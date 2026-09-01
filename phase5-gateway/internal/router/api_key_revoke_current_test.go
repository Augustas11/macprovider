package router

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/auth"
)

type revokeResponse struct {
	Status         string `json:"status"`
	KeyID          string `json:"key_id"`
	RevokedCurrent bool   `json:"revoked_current"`
	APIKey         string `json:"api_key"`
	KeyHash        string `json:"key_hash"`
	KeyHashHex     string `json:"key_hash_hex"`
}

func TestRevokeCurrentKeyReportsRevokedCurrent(t *testing.T) {
	h, store, _, cfg := newTestHarness(t, fakeOAuth{}, WithHTTPClient(modelsOKClient()))
	fullKey := createAccountAndKey(t, store, cfg, "acct_self_revoke")
	km := auth.NewKeyManager(cfg.Auth.KeyPrefix, cfg.Auth.KeyHash, cfg.Auth.KeyHashSecret)
	validation, err := km.Validate(context.Background(), store, fullKey)
	if err != nil {
		t.Fatalf("Validate: %v", err)
	}

	resp := postRevoke(t, h, fullKey, validation.KeyID)
	if resp.Code != http.StatusOK {
		t.Fatalf("revoke status=%d", resp.Code)
	}
	assertNoStore(t, resp.Header())
	body := decodeRevoke(t, resp)
	if body.Status != "revoked" {
		t.Fatalf("status=%q want revoked", body.Status)
	}
	if body.KeyID != validation.KeyID {
		t.Fatalf("key_id mismatch")
	}
	if !body.RevokedCurrent {
		t.Fatal("revoked_current=false want true")
	}
	assertNoSecretMaterial(t, resp.Body.String(), fullKey, hex.EncodeToString(km.Hash(fullKey)))

	usage := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusForbidden)
	assertErrorCode(t, usage.Body.String(), "api_key_revoked")
	assertNoSecretMaterial(t, usage.Body.String(), fullKey)
}

func TestRevokeOtherAccountKeyLeavesBearerValid(t *testing.T) {
	h, store, _, cfg := newTestHarness(t, fakeOAuth{}, WithHTTPClient(modelsOKClient()))
	currentKey := createAccountAndKey(t, store, cfg, "acct_other_revoke")
	km := auth.NewKeyManager(cfg.Auth.KeyPrefix, cfg.Auth.KeyHash, cfg.Auth.KeyHashSecret)
	otherKey, otherSummary, err := km.Issue(context.Background(), store, "acct_other_revoke")
	if err != nil {
		t.Fatalf("Issue second key: %v", err)
	}

	resp := postRevoke(t, h, currentKey, otherSummary.KeyID)
	if resp.Code != http.StatusOK {
		t.Fatalf("revoke status=%d", resp.Code)
	}
	body := decodeRevoke(t, resp)
	if body.Status != "revoked" {
		t.Fatalf("status=%q want revoked", body.Status)
	}
	if body.KeyID != otherSummary.KeyID {
		t.Fatalf("key_id mismatch")
	}
	if body.RevokedCurrent {
		t.Fatal("revoked_current=true want false")
	}
	assertNoSecretMaterial(t, resp.Body.String(), currentKey, otherKey, hex.EncodeToString(km.Hash(currentKey)), hex.EncodeToString(km.Hash(otherKey)))

	assertStatus(t, h, http.MethodGet, "/v1/usage", currentKey, "", "1.2.3.4", http.StatusOK)
	revokedUsage := assertStatus(t, h, http.MethodGet, "/v1/usage", otherKey, "", "1.2.3.4", http.StatusForbidden)
	assertErrorCode(t, revokedUsage.Body.String(), "api_key_revoked")
}

func TestRevokeUnknownAndCrossAccountKeyChangesNoState(t *testing.T) {
	h, store, _, cfg := newTestHarness(t, fakeOAuth{}, WithHTTPClient(modelsOKClient()))
	keyA := createAccountAndKey(t, store, cfg, "acct_revoke_guard_a")
	keyB := createAccountAndKey(t, store, cfg, "acct_revoke_guard_b")
	km := auth.NewKeyManager(cfg.Auth.KeyPrefix, cfg.Auth.KeyHash, cfg.Auth.KeyHashSecret)
	validationB, err := km.Validate(context.Background(), store, keyB)
	if err != nil {
		t.Fatalf("Validate B: %v", err)
	}

	missing := postRevoke(t, h, keyA, "key_does_not_exist")
	if missing.Code != http.StatusNotFound {
		t.Fatalf("missing revoke status=%d", missing.Code)
	}
	assertErrorCode(t, missing.Body.String(), "api_key_not_found")

	cross := postRevoke(t, h, keyA, validationB.KeyID)
	if cross.Code != http.StatusNotFound {
		t.Fatalf("cross revoke status=%d", cross.Code)
	}
	assertErrorCode(t, cross.Body.String(), "api_key_not_found")
	if strings.Contains(cross.Body.String(), `"revoked_current"`) {
		t.Fatal("error response must not include revoked_current")
	}

	assertStatus(t, h, http.MethodGet, "/v1/usage", keyA, "", "1.2.3.4", http.StatusOK)
	assertStatus(t, h, http.MethodGet, "/v1/usage", keyB, "", "1.2.3.4", http.StatusOK)
	assertNoSecretMaterial(t, missing.Body.String()+cross.Body.String(), keyA, keyB)
}

func postRevoke(t *testing.T, h http.Handler, bearer, keyID string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/auth/api-keys/"+keyID+"/revoke", nil)
	req.Header.Set("Authorization", "Bearer "+bearer)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	return resp
}

func decodeRevoke(t *testing.T, resp *httptest.ResponseRecorder) revokeResponse {
	t.Helper()
	var body revokeResponse
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("revoke json: %v", err)
	}
	if body.APIKey != "" || body.KeyHash != "" || body.KeyHashHex != "" {
		t.Fatal("revoke response included secret key material fields")
	}
	return body
}

func assertNoSecretMaterial(t *testing.T, haystack string, secrets ...string) {
	t.Helper()
	for _, secret := range secrets {
		if secret != "" && strings.Contains(haystack, secret) {
			t.Fatal("response leaked secret key material")
		}
	}
}
