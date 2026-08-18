package router

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
)

func TestBuyerReceiptRetrievalAuthAndRedaction(t *testing.T) {
	var lastAccount, lastRequest, lastOperator string
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/internal/settlement/receipts" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		lastAccount = r.URL.Query().Get("account_id")
		lastRequest = r.URL.Query().Get("request_id")
		lastOperator = r.URL.Query().Get("operator")
		switch lastRequest {
		case "req-missing":
			w.WriteHeader(http.StatusNotFound)
			return
		case "req-foreign":
			w.WriteHeader(http.StatusForbidden)
			return
		case "req-owned":
			writeJSON(w, http.StatusOK, map[string]any{
				"schema_version":              "macprovider.buyer-receipt-view.v1",
				"request_id":                  "req-owned",
				"surface":                     "metadata",
				"pending_quarantined_visible": true,
				"attempts": []map[string]any{{
					"attempt_n":          0,
					"settlement_outcome": "pending",
					"receipt_result":     "inconclusive",
					"closed":             false,
					"prompt_hash":        strings.Repeat("a", 64),
					"output_hash":        strings.Repeat("b", 64),
				}},
			})
			return
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer coordinator.Close()

	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.OperatorURL = coordinator.URL
	}, WithHTTPClient(coordinator.Client()))
	ownerKey := createAccountAndKey(t, store, cfg, "acct_owner")
	strangerKey := createAccountAndKey(t, store, cfg, "acct_stranger")

	resp := assertStatus(t, h, http.MethodGet, "/v1/receipts/req-owned", ownerKey, "", "1.2.3.4", http.StatusOK)
	if lastAccount != "acct_owner" || lastRequest != "req-owned" || lastOperator != "" {
		t.Fatalf("coordinator query account=%q request=%q operator=%q", lastAccount, lastRequest, lastOperator)
	}
	var body map[string]any
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body["surface"] != "metadata" || body["request_id"] != "req-owned" {
		t.Fatalf("body=%v", body)
	}
	if !strings.Contains(resp.Header().Get("Cache-Control"), "no-store") {
		t.Fatalf("Cache-Control=%q want no-store", resp.Header().Get("Cache-Control"))
	}
	vary := strings.ToLower(strings.Join(resp.Header().Values("Vary"), ","))
	for _, needle := range []string{"authorization", "x-api-key", "x-demo-token"} {
		if !strings.Contains(vary, needle) {
			t.Fatalf("Vary=%q missing %q", resp.Header().Get("Vary"), needle)
		}
	}
	raw := strings.ToLower(resp.Body.String())
	for _, needle := range []string{"raw_prompt", "raw_output", "x-macprovider-receipt", `"prompt":`} {
		if strings.Contains(raw, needle) {
			t.Fatalf("response leaked %q: %s", needle, resp.Body.String())
		}
	}

	assertStatus(t, h, http.MethodGet, "/v1/receipts/req-foreign", strangerKey, "", "1.2.3.4", http.StatusForbidden)
	assertStatus(t, h, http.MethodGet, "/v1/receipts/req-missing", ownerKey, "", "1.2.3.4", http.StatusNotFound)
	assertStatus(t, h, http.MethodGet, "/v1/receipts/req-owned", "", "", "1.2.3.4", http.StatusUnauthorized)

	req := httptest.NewRequest(http.MethodGet, "/v1/receipts/req-owned", nil)
	req.Header.Set("Authorization", "Bearer "+cfg.Coordinator.OperatorKey)
	opResp := httptest.NewRecorder()
	h.ServeHTTP(opResp, req)
	if opResp.Code != http.StatusOK {
		t.Fatalf("operator status=%d body=%s", opResp.Code, opResp.Body.String())
	}
	if lastOperator != "1" {
		t.Fatalf("operator query flag=%q", lastOperator)
	}

	demoReq := httptest.NewRequest(http.MethodPost, "/auth/demo-session", nil)
	demoReq.Header.Set("X-Real-IP", "1.2.3.4")
	demoResp := httptest.NewRecorder()
	h.ServeHTTP(demoResp, demoReq)
	if demoResp.Code != http.StatusCreated {
		t.Fatalf("demo session status=%d body=%s", demoResp.Code, demoResp.Body.String())
	}
	var demoBody struct {
		DemoToken string `json:"demo_token"`
	}
	if err := json.Unmarshal(demoResp.Body.Bytes(), &demoBody); err != nil {
		t.Fatal(err)
	}
	assertStatus(t, h, http.MethodGet, "/v1/receipts/req-owned", "", demoBody.DemoToken, "1.2.3.4", http.StatusForbidden)
}
