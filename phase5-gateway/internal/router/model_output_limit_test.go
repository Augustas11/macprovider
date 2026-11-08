package router

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/storage"
	"github.com/augstar/macprovider-gateway/internal/storage/sqlite"
)

type reservationCaptureStore struct {
	*sqlite.Store
	mu        sync.Mutex
	requested []int64
}

func (s *reservationCaptureStore) ReserveQuota(ctx context.Context, req storage.ReservationRequest) (storage.QuotaDecision, error) {
	s.mu.Lock()
	s.requested = append(s.requested, req.RequestedTokens)
	s.mu.Unlock()
	return s.Store.ReserveQuota(ctx, req)
}

func (s *reservationCaptureStore) last(t *testing.T) int64 {
	t.Helper()
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.requested) == 0 {
		t.Fatal("no quota reservation was made")
	}
	return s.requested[len(s.requested)-1]
}

func withGLMOutputOverride(cfg *config.Config) {
	cfg.Coordinator.BuyerURL = "http://coordinator.test"
	cfg.Quotas.AccountDailyTokens = 10_000_000
	cfg.Features.ResponsesAPIEnabled = true
	cfg.Features.AnthropicMessagesEnabled = true
	cfg.Limits.ModelMaxOutputTokens = map[string]int64{"zai-org/glm-5.3-flash": 131072}
}

// SPEC-006 §5.4: a 65536-token request on a model with a 131072 override is
// admitted on every buyer entrypoint, with the quota reservation, forwarded
// output budget and stream ceiling sized for 65536; above the override, and
// on a model without one, the gateway-wide cap still refuses it.
func TestPerModelOutputLimitAdmitsAboveGatewayCap(t *testing.T) {
	var mu sync.Mutex
	var forwarded string
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		mu.Lock()
		forwarded = r.Header.Get(effectiveMaxOutputTokensHeader)
		mu.Unlock()
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"id":"chatcmpl_1","object":"chat.completion","model":"zai-org/glm-5.3-flash","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`), nil
	})}
	_, sqliteStore, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, withGLMOutputOverride)
	store := &reservationCaptureStore{Store: sqliteStore}
	h := New(cfg, store, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(client)).Handler()
	key := createAccountAndKey(t, sqliteStore, cfg, "acct_model_output_limit")

	admitted := []struct {
		name      string
		post      func() *httptest.ResponseRecorder
		promptCap int64
		want      int64
	}{
		{name: "chat alias", want: 65536, post: func() *httptest.ResponseRecorder {
			return postChat(t, h, key, `{"model":"glm-5.3-flash","max_tokens":65536,"messages":[{"role":"user","content":"hi"}]}`, nil)
		}},
		{name: "chat served artifact id", want: 131072, post: func() *httptest.ResponseRecorder {
			return postChat(t, h, key, `{"model":"Jundot/GLM-5.3-Flash-oQ4e-mtp","max_tokens":131072,"messages":[{"role":"user","content":"hi"}]}`, nil)
		}},
		{name: "chat omitted keeps gateway default", want: 32768, post: func() *httptest.ResponseRecorder {
			return postChat(t, h, key, `{"model":"zai-org/glm-5.3-flash","messages":[{"role":"user","content":"hi"}]}`, nil)
		}},
		{name: "responses", want: 65536, post: func() *httptest.ResponseRecorder {
			return postResponses(t, h, key, `{"model":"zai-org/glm-5.3-flash","input":"hi","max_output_tokens":65536,"store":false}`, nil)
		}},
		{name: "anthropic messages", want: 65536, post: func() *httptest.ResponseRecorder {
			return postAnthropicMessages(t, h, key, `{"model":"zai-org/glm-5.3-flash","max_tokens":65536,"messages":[{"role":"user","content":"hi"}]}`, nil)
		}},
	}
	for _, tc := range admitted {
		t.Run(tc.name, func(t *testing.T) {
			resp := tc.post()
			if resp.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
			}
			mu.Lock()
			got := forwarded
			mu.Unlock()
			if got != strconv.FormatInt(tc.want, 10) {
				t.Fatalf("forwarded output budget=%q want %d", got, tc.want)
			}
			// The reservation is prompt cap + output budget, so it scales
			// with the admitted max_tokens.
			if reserved := store.last(t); reserved <= tc.want || reserved > tc.want+4096 {
				t.Fatalf("reserved tokens=%d want prompt cap + %d", reserved, tc.want)
			}
		})
	}

	refused := []struct {
		name string
		post func() *httptest.ResponseRecorder
	}{
		{name: "chat above override", post: func() *httptest.ResponseRecorder {
			return postChat(t, h, key, `{"model":"glm-5.3-flash","max_tokens":131073,"messages":[{"role":"user","content":"hi"}]}`, nil)
		}},
		{name: "chat model without override", post: func() *httptest.ResponseRecorder {
			return postChat(t, h, key, `{"model":"llama","max_tokens":65536,"messages":[{"role":"user","content":"hi"}]}`, nil)
		}},
		{name: "chat sibling model without override", post: func() *httptest.ResponseRecorder {
			return postChat(t, h, key, `{"model":"zai-org/glm-5.3-flash-abliterated","max_tokens":65536,"messages":[{"role":"user","content":"hi"}]}`, nil)
		}},
		{name: "responses above override", post: func() *httptest.ResponseRecorder {
			return postResponses(t, h, key, `{"model":"zai-org/glm-5.3-flash","input":"hi","max_output_tokens":131073,"store":false}`, nil)
		}},
		{name: "anthropic above override", post: func() *httptest.ResponseRecorder {
			return postAnthropicMessages(t, h, key, `{"model":"zai-org/glm-5.3-flash","max_tokens":131073,"messages":[{"role":"user","content":"hi"}]}`, nil)
		}},
	}
	for _, tc := range refused {
		t.Run(tc.name, func(t *testing.T) {
			store.mu.Lock()
			before := len(store.requested)
			store.mu.Unlock()
			resp := tc.post()
			if resp.Code != http.StatusBadRequest {
				t.Fatalf("status=%d want 400 body=%s", resp.Code, resp.Body.String())
			}
			assertErrorCode(t, resp.Body.String(), "max_tokens_exceeded")
			store.mu.Lock()
			after := len(store.requested)
			store.mu.Unlock()
			if after != before {
				t.Fatalf("refused request reserved quota")
			}
		})
	}
}

// The stream ceiling (#760) is derived from the admitted max_tokens, so a
// 65536-token request gets a longer bound than a 32768-token one until the
// configured stream_ceiling_max_seconds clamps both.
func TestStreamCeilingScalesWithPerModelOutputLimit(t *testing.T) {
	cfg := config.Default()
	if got, want := streamCeiling(65536, cfg), time.Duration(cfg.Timeouts.StreamCeilingMaxSeconds)*time.Second; got != want {
		t.Fatalf("default streamCeiling(65536)=%s want the configured maximum %s", got, want)
	}
	cfg.Timeouts.StreamCeilingMaxSeconds = 100000
	got := streamCeiling(65536, cfg)
	want := time.Duration(cfg.Timeouts.StreamCeilingFloorSeconds)*time.Second + 65536*time.Duration(cfg.Timeouts.StreamCeilingPerTokenMS)*time.Millisecond
	if got != want {
		t.Fatalf("streamCeiling(65536)=%s want floor + 65536*per_token = %s", got, want)
	}
	if shorter := streamCeiling(32768, cfg); shorter >= got {
		t.Fatalf("streamCeiling(32768)=%s not below streamCeiling(65536)=%s", shorter, got)
	}
}

// SPEC-006 §5.3: /v1/models advertises the effective output limit at top
// level and in capabilities.
func TestModelsAdvertisesMaxOutputTokens(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"object":"list","data":[
			{"id":"zai-org/glm-5.3-flash","object":"model","owned_by":"macprovider","aliases":["glm-5.3-flash"],"capabilities":{"tools":true,"reasoning":true,"response_format":true,"vision":false,"context_length":200000,"tool_choice":["auto"]}},
			{"id":"llama","object":"model","owned_by":"macprovider"}
		]}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, withGLMOutputOverride, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_models_output_limit")

	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	req.Header.Set("Authorization", "Bearer "+key)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	var body struct {
		Data []struct {
			ID              string `json:"id"`
			MaxOutputTokens int64  `json:"max_output_tokens"`
			Capabilities    *struct {
				MaxOutputTokens int64 `json:"max_output_tokens"`
			} `json:"capabilities"`
		} `json:"data"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	got := map[string]int64{}
	for _, entry := range body.Data {
		got[entry.ID] = entry.MaxOutputTokens
		if entry.ID == "zai-org/glm-5.3-flash" {
			if entry.Capabilities == nil || entry.Capabilities.MaxOutputTokens != 131072 {
				t.Fatalf("GLM capabilities=%+v want max_output_tokens 131072", entry.Capabilities)
			}
		}
	}
	if got["zai-org/glm-5.3-flash"] != 131072 || got["llama"] != 32768 {
		t.Fatalf("max_output_tokens=%v want GLM 131072, llama 32768", got)
	}
}
