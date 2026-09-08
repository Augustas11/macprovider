package router

import (
	"database/sql"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
)

func TestChatRequestRejectsAmbiguousAdmissionFields(t *testing.T) {
	for _, tc := range []struct {
		name   string
		fields string
	}{
		{"token_case_after", `"max_tokens":100000,"Max_tokens":1`},
		{"token_case_before", `"Max_tokens":1,"max_tokens":100000`},
		{"token_uppercase", `"MAX_TOKENS":1`},
		{"token_unicode_fold", `"max_to\u212aens":1`},
		{"token_duplicate", `"max_tokens":100000,"max_tokens":1`},
		{"token_duplicate_null", `"max_tokens":100000,"max_tokens":null`},
		{"token_escaped_duplicate", `"max_tokens":100000,"max_\u0074okens":1`},
		{"stream_case_after", `"stream":true,"Stream":false`},
		{"stream_case_before", `"Stream":false,"stream":true`},
		{"stream_duplicate", `"stream":true,"stream":false`},
		{"stream_unicode_fold", `"\u017ftream":false`},
		{"model_case", `"Model":"other"`},
		{"model_duplicate", `"model":"other"`},
		{"messages_case", `"Messages":[{"role":"user","content":"other"}]`},
		{"messages_duplicate", `"messages":[{"role":"user","content":"other"}]`},
		{"n_case", `"n":2,"N":1`},
		{"n_duplicate", `"n":2,"n":1`},
		{"format_case", `"Response_format":{"type":"json_object"}`},
		{"format_duplicate", `"response_format":{"type":"json_object"},"response_format":null`},
		{"format_type_case", `"response_format":{"type":"json_object","Type":"text"}`},
		{"format_type_duplicate", `"response_format":{"type":"json_object","type":"text"}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body := `{"model":"model-a","messages":[{"role":"user","content":"hi"}],` + tc.fields + `}`
			if _, err := parseChatRequest([]byte(body)); err == nil {
				t.Fatal("ambiguous request was accepted")
			}
		})
	}
}

func TestChatRequestFieldValidationPreservesExtensions(t *testing.T) {
	body := []byte(`{"mo\u0064el":"model-a","messages":[{"role":"user","content":"hi","Extension":true}],"max_tokens":20,"stream":true,"n":1,"Vendor":{"Stream":true,"stream":false},"vendor":1,"vendor":2,"max_completion_tokens":7,"response_format":{"type":"json_schema","json_schema":{"name":"example","schema":{"type":"object","properties":{"Type":{"type":"string"},"type":{"type":"number"}}}}}}`)
	original := string(body)
	req, err := parseChatRequest(body)
	if err != nil {
		t.Fatalf("canonical request with extensions rejected: %v", err)
	}
	if req.Model != "model-a" || req.MaxTokens == nil || *req.MaxTokens != 20 || !req.Stream || !req.hasStructuredOutput() {
		t.Fatalf("unexpected parsed request: %+v", req)
	}
	if string(body) != original {
		t.Fatal("validation mutated the raw body")
	}
}

func TestRequestFieldValidationRejectsMalformedAndOverdeepJSON(t *testing.T) {
	for _, body := range []string{
		`null`, `[]`, `"request"`, `{`, `{"model":}`, `{"model":"a",}`,
		`{"model":"a"} {}`, `{"model":"a"} false`, `{"model":"a"} trailing`,
		`{"extension":` + strings.Repeat(`[`, 10001) + `0` + strings.Repeat(`]`, 10001) + `}`,
	} {
		if _, err := validateRequestFieldNames([]byte(body), "model"); err == nil {
			t.Errorf("accepted malformed or overdeep JSON (bytes=%d)", len(body))
		}
	}
}

func TestResponsesRequestRejectsAmbiguityBeforeTranslation(t *testing.T) {
	for _, fields := range []string{
		`"max_output_tokens":100000,"Max_output_tokens":1`,
		`"Max_output_tokens":1,"max_output_tokens":100000`,
		`"max_output_tokens":100000,"max_output_tokens":1`,
		`"max_output_tokens":100000,"max_output_\u0074okens":1`,
		`"stream":true,"Stream":false`,
		`"stream":true,"stream":false`,
		`"Model":"other"`, `"model":"other"`, `"Input":"other"`,
		`"store":true,"Store":false`,
		`"previous_response_id":"other","Previous_response_id":""`,
		`"background":true,"Background":false`,
		`"text":{},"Text":{}`, `"tools":[],"Tools":[]`,
		`"text":{"format":{"type":"text"},"Format":{"type":"json_object"}}`,
		`"text":{"format":{"type":"text"},"format":{"type":"json_object"}}`,
		`"text":{"format":{"type":"text","Type":"json_object"}}`,
		`"text":{"format":{"type":"text","type":"json_object"}}`,
	} {
		a := responsesAdapter{model: "unchanged", stream: true}
		body := []byte(`{"model":"model-a","input":"hi",` + fields + `}`)
		if translated, err := a.translateRequest(body); err == nil || translated != nil {
			t.Errorf("ambiguous request accepted: %s", fields)
		}
		if a.model != "unchanged" || !a.stream {
			t.Fatal("rejected request mutated adapter state")
		}
	}
}

func TestResponsesRequestFieldValidationPreservesExtensions(t *testing.T) {
	a := responsesAdapter{}
	body := []byte(`{"model":"model-a","input":"hi","max_output_tokens":20,"stream":false,"store":false,"vendor_extension":{"Stream":true,"stream":false},"VendorExtension":1,"VendorExtension":2}`)
	translated, err := a.translateRequest(body)
	if err != nil {
		t.Fatalf("extension rejected: %v", err)
	}
	req, parseErr := parseChatRequest(translated)
	if parseErr != nil || req.MaxTokens == nil || *req.MaxTokens != 20 || req.Stream {
		t.Fatalf("translation changed admission controls: req=%+v err=%v", req, parseErr)
	}
}

func TestInferenceAmbiguousFieldsRejectBeforeDispatchAndReservation(t *testing.T) {
	for _, mode := range []string{"api_key", "demo", "wallet"} {
		t.Run(mode, func(t *testing.T) {
			var dispatches atomic.Int64
			models := walletModelsClient()
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				if r.URL.Path == "/v1/chat/completions" {
					dispatches.Add(1)
					return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`), nil
				}
				return models.Transport.RoundTrip(r)
			})}
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				enableResponsesWithCoordinator(cfg)
				cfg.Features.AnthropicMessagesEnabled = true
				cfg.Quotas.AccountRequestRatePerSecond = 10000
				cfg.Public.BaseURL = "https://api.malibu.test"
				cfg.Auth.WalletSessions.Enabled = true
				cfg.Auth.WalletSessions.BearerHashKeys = map[string]string{"k1": strings.Repeat("b", 32)}
				cfg.Auth.WalletSessions.CurrentBearerHashKeyID = "k1"
				cfg.Auth.WalletSessions.WalletFingerprintSecret = strings.Repeat("f", 32)
			}, WithHTTPClient(client))
			accountID := "acct_ambiguous_" + mode
			key := createAccountAndKey(t, store, cfg, accountID)
			var demo string
			var wallet walletSessionTestClient
			if mode == "demo" {
				demo = issueDemoToken(t, h, "1.2.3.4")
			} else if mode == "wallet" {
				wallet = registerWalletSessionViaAPIWithCaps(t, h, cfg, key, accountID, []string{"model-a"}, 10000, 1000)
			}
			for _, endpoint := range []struct {
				path, input, tokens string
			}{
				{"/v1/chat/completions", `"messages":[{"role":"user","content":"hi"}]`, "max_tokens"},
				{"/v1/responses", `"input":"hi"`, "max_output_tokens"},
				{"/v1/messages", `"messages":[{"role":"user","content":"hi"}]`, "max_tokens"},
			} {
				t.Run(endpoint.path, func(t *testing.T) {
					variant := "M" + endpoint.tokens[1:]
					for _, fields := range []string{
						fmt.Sprintf(`%q:100000,%q:1`, endpoint.tokens, variant),
						fmt.Sprintf(`%q:1,%q:100000`, variant, endpoint.tokens),
						fmt.Sprintf(`%q:100000,%q:1`, endpoint.tokens, endpoint.tokens),
						fmt.Sprintf(`%q:1,"stream":true,"Stream":false`, endpoint.tokens),
						fmt.Sprintf(`%q:1,"Stream":false,"stream":true`, endpoint.tokens),
					} {
						body := []byte(`{"model":"model-a",` + endpoint.input + `,` + fields + `}`)
						req := httptest.NewRequest(http.MethodPost, endpoint.path, strings.NewReader(string(body)))
						req.Header.Set("X-Request-ID", newUUID())
						switch mode {
						case "api_key":
							req.Header.Set("Authorization", "Bearer "+key)
						case "demo":
							req.Header.Set("X-Demo-Token", demo)
							req.Header.Set("X-Real-IP", "1.2.3.4")
						case "wallet":
							req = signedWalletRequest(t, wallet, http.MethodPost, endpoint.path, endpoint.path, newUUID(), body)
						}
						req.Header.Set("Content-Type", "application/json")
						resp := httptest.NewRecorder()
						h.ServeHTTP(resp, req)
						wantStatus := http.StatusBadRequest
						if mode == "demo" && endpoint.path == "/v1/messages" {
							// Messages excludes demo auth before request parsing.
							wantStatus = http.StatusUnauthorized
							assertErrorCode(t, resp.Body.String(), "invalid_demo_token")
						}
						if resp.Code != wantStatus {
							t.Errorf("fields=%s status=%d want %d body=%s", fields, resp.Code, wantStatus, resp.Body.String())
						}
					}
				})
			}
			if got := dispatches.Load(); got != 0 {
				t.Errorf("ambiguous requests caused %d coordinator dispatches", got)
			}
			db, err := sql.Open("sqlite", dbPath)
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			for _, table := range []string{"quota_reservations", "wallet_session_reservations", "wallet_session_replays", "usage_events"} {
				var count int
				if err := db.QueryRow("SELECT COUNT(*) FROM " + table).Scan(&count); err != nil {
					t.Fatal(err)
				}
				if count != 0 {
					t.Errorf("rejected requests mutated %s: %d rows", table, count)
				}
			}
		})
	}
}

func TestChatAdmissionCanonicalExtensionsForwardUnchanged(t *testing.T) {
	body := `{"model":"model-a","messages":[{"role":"user","content":"hi"}],"max_tokens":20,"stream":false,"vendor_extension":{"Stream":true,"stream":false}}`
	var forwarded string
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		raw, err := io.ReadAll(r.Body)
		if err != nil {
			return nil, err
		}
		forwarded = string(raw)
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, enableResponsesWithCoordinator, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_canonical_extensions")
	resp := postChat(t, h, key, body, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if forwarded != body {
		t.Fatalf("raw request changed: got %s want %s", forwarded, body)
	}
}
