package router

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/relayblind"
	"github.com/augstar/macprovider-gateway/internal/storage"
)

// steppingClock is the server clock for SPEC-006-R028 handler tests. The
// upstream body moves it to a scripted instant as it hands each frame to the
// gateway, so a delta's receipt instant is exactly that frame's offset.
type steppingClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *steppingClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *steppingClock) set(at time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = at
}

type timedFrame struct {
	offset time.Duration
	data   string
}

// steppingBody returns one SSE frame per Read, so the gateway's buffered
// reader never reads ahead of the frame it is classifying.
type steppingBody struct {
	clock  *steppingClock
	start  time.Time
	frames []timedFrame
	next   int
	rest   []byte
}

func (b *steppingBody) Read(p []byte) (int, error) {
	if len(b.rest) == 0 {
		if b.next >= len(b.frames) {
			return 0, io.EOF
		}
		frame := b.frames[b.next]
		b.next++
		b.clock.set(b.start.Add(frame.offset))
		b.rest = []byte("data: " + frame.data + "\n\n")
	}
	n := copy(p, b.rest)
	b.rest = b.rest[n:]
	return n, nil
}

func (b *steppingBody) Close() error { return nil }

const servingTestRouteTrace = "v=1; phase=interactive; basis=measured; evidence=fresh; engine=continuous_batching; latency=low"

type servingRow struct {
	firstReasoning, firstAnswer, outputTPS sql.NullInt64
	streamingMode, servingEngine           string
	completionTokens                       int64
	providerFirstAnswer                    sql.NullInt64
}

func readServingRow(t *testing.T, dbPath, accountID string) servingRow {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	defer db.Close()
	var row servingRow
	err = db.QueryRow(`
		SELECT gw_first_reasoning_ms, gw_first_answer_ms, gw_output_tps_millitokens,
			streaming_mode, serving_engine, completion_tokens, provider_reported_first_answer_ms
		FROM demand_events WHERE buyer_hash = ? ORDER BY event_id DESC LIMIT 1`,
		demandBuyerHash("test-key-hash-secret", accountID)).Scan(&row.firstReasoning, &row.firstAnswer, &row.outputTPS,
		&row.streamingMode, &row.servingEngine, &row.completionTokens, &row.providerFirstAnswer)
	if err != nil {
		t.Fatalf("serving row for %s: %v", accountID, err)
	}
	return row
}

func servingTestHarness(t *testing.T, mode string, frames []timedFrame) (http.Handler, func(string) string, string) {
	t.Helper()
	clock := &steppingClock{now: fixedNow()}
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		header := http.Header{"Content-Type": []string{"text/event-stream"}}
		if mode != "" {
			header.Set(streamingModeResponseHeader, mode)
		}
		header.Set(routeTraceResponseHeader, servingTestRouteTrace)
		return &http.Response{StatusCode: http.StatusOK, Header: header, Body: &steppingBody{clock: clock, start: fixedNow(), frames: frames}}, nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Features.ResponsesAPIEnabled = true
		cfg.Features.AnthropicMessagesEnabled = true
	}, WithHTTPClient(client), WithNow(clock.Now))
	newKey := func(accountID string) string {
		clock.set(fixedNow())
		return createAccountAndKey(t, store, cfg, accountID)
	}
	return h, newKey, dbPath
}

func reasoningThenAnswerFrames() []timedFrame {
	return []timedFrame{
		{0, `{"id":"c1","model":"llama","choices":[{"index":0,"delta":{"role":"assistant"}}]}`},
		{100 * time.Millisecond, `{"id":"c1","model":"llama","choices":[{"index":0,"delta":{"reasoning_content":"Let me think about it."}}]}`},
		{300 * time.Millisecond, `{"id":"c1","model":"llama","choices":[{"index":0,"delta":{"content":"The answer starts here and goes on a bit."}}]}`},
		{500 * time.Millisecond, `{"id":"c1","model":"llama","choices":[{"index":0,"delta":{"content":"It ends here after a few more words, too."}}]}`},
		{600 * time.Millisecond, `{"id":"c1","model":"llama","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":30,"total_tokens":33,"macprovider_first_answer_ms":250}}`},
	}
}

// The same upstream stream gives the same two first-delta instants on every
// buyer surface: all three read the coordinator's Chat Completions stream.
func TestServingTelemetryFirstDeltasMatchOnEveryBuyerSurface(t *testing.T) {
	h, newKey, dbPath := servingTestHarness(t, "incremental", reasoningThenAnswerFrames())
	surfaces := []struct {
		name string
		post func(key string) int
	}{
		{"chat_completions", func(key string) int {
			return postChat(t, h, key, `{"model":"llama","stream":true,"max_tokens":64,"messages":[{"role":"user","content":"hi"}]}`, nil).Code
		}},
		{"responses", func(key string) int {
			return postResponses(t, h, key, `{"model":"llama","stream":true,"max_output_tokens":64,"input":"hi"}`, nil).Code
		}},
		{"messages", func(key string) int {
			return postAnthropicMessages(t, h, key, `{"model":"llama","stream":true,"max_tokens":64,"messages":[{"role":"user","content":"hi"}]}`, nil).Code
		}},
	}
	for _, surface := range surfaces {
		t.Run(surface.name, func(t *testing.T) {
			account := "acct_serving_" + surface.name
			key := newKey(account)
			if code := surface.post(key); code != http.StatusOK {
				t.Fatalf("status=%d", code)
			}
			row := readServingRow(t, dbPath, account)
			if !row.firstReasoning.Valid || row.firstReasoning.Int64 != 100 {
				t.Fatalf("first reasoning = %+v, want 100", row.firstReasoning)
			}
			if !row.firstAnswer.Valid || row.firstAnswer.Int64 != 300 {
				t.Fatalf("first answer = %+v, want 300", row.firstAnswer)
			}
			// 82 answer bytes -> 21 estimated tokens; (21-1) over 200 ms.
			if !row.outputTPS.Valid || row.outputTPS.Int64 != 100_000 {
				t.Fatalf("output rate = %+v, want 100000 millitokens/s", row.outputTPS)
			}
			if row.streamingMode != "incremental" || row.servingEngine != "continuous_batching" {
				t.Fatalf("labels = %q/%q", row.streamingMode, row.servingEngine)
			}
			if !row.providerFirstAnswer.Valid || row.providerFirstAnswer.Int64 != 250 {
				t.Fatalf("provider first answer label = %+v, want 250", row.providerFirstAnswer)
			}
		})
	}
}

func TestServingTelemetryStreamShapes(t *testing.T) {
	answer := func(offset time.Duration, text string) timedFrame {
		return timedFrame{offset, `{"id":"c1","model":"llama","choices":[{"index":0,"delta":{"content":"` + text + `"}}]}`}
	}
	usage := func(completion int) timedFrame {
		return timedFrame{900 * time.Millisecond, `{"id":"c1","model":"llama","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":` + strconv.Itoa(completion) + `,"total_tokens":` + strconv.Itoa(3+completion) + `}}`}
	}
	cases := []struct {
		name                         string
		mode                         string
		frames                       []timedFrame
		reasoning, answerMS, rateMil int64 // -1 = absent
		completion                   int64
	}{
		{
			// Harmony: completion_tokens counts the final channel only. The
			// rate never reads it, so the estimate is the same basis as for
			// any other family.
			name: "gpt_oss_reasoning_then_content",
			mode: "incremental",
			frames: []timedFrame{
				{50 * time.Millisecond, `{"id":"c1","model":"llama","choices":[{"index":0,"delta":{"reasoning_content":"analysis channel"}}]}`},
				{150 * time.Millisecond, `{"id":"c1","model":"llama","choices":[{"index":0,"delta":{"reasoning_content":" more analysis"}}]}`},
				answer(400*time.Millisecond, "final channel text that is long enough"),
				answer(600*time.Millisecond, "and a second final channel fragment!!"),
				usage(20),
			},
			reasoning: 50, answerMS: 400, rateMil: 90_000, completion: 20,
		},
		{
			name: "think_tags_inside_content",
			mode: "incremental",
			frames: []timedFrame{
				answer(80*time.Millisecond, "<think>pondering"),
				answer(200*time.Millisecond, " still pondering</think>"),
				answer(350*time.Millisecond, "Visible answer text that runs on for a"),
				answer(550*time.Millisecond, " while so the estimate passes eight..."),
				usage(30),
			},
			reasoning: 80, answerMS: 350, rateMil: 90_000, completion: 30,
		},
		{
			name: "tool_call_only",
			mode: "incremental",
			frames: []timedFrame{
				{400 * time.Millisecond, `{"id":"c1","model":"llama","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"lookup","arguments":"{\"city\": \"Paris\", \"days\": 3.0}"}}]}}]}`},
				usage(12),
			},
			reasoning: -1, answerMS: 400, rateMil: -1, completion: 12,
		},
		{
			name:      "buffered_mode",
			mode:      "buffered_tool_selection",
			frames:    reasoningThenAnswerFrames(),
			reasoning: -1, answerMS: -1, rateMil: -1, completion: 30,
		},
		{
			name:      "missing_mode_header",
			mode:      "",
			frames:    reasoningThenAnswerFrames(),
			reasoning: -1, answerMS: -1, rateMil: -1, completion: 30,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h, newKey, dbPath := servingTestHarness(t, tc.mode, tc.frames)
			account := "acct_serving_" + tc.name
			key := newKey(account)
			resp := postChat(t, h, key, `{"model":"llama","stream":true,"max_tokens":64,"messages":[{"role":"user","content":"hi"}]}`, nil)
			if resp.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
			}
			row := readServingRow(t, dbPath, account)
			check := func(name string, got sql.NullInt64, want int64) {
				t.Helper()
				if want < 0 {
					if got.Valid {
						t.Fatalf("%s = %d, want absent", name, got.Int64)
					}
					return
				}
				if !got.Valid || got.Int64 != want {
					t.Fatalf("%s = %+v, want %d", name, got, want)
				}
			}
			check("first reasoning", row.firstReasoning, tc.reasoning)
			check("first answer", row.firstAnswer, tc.answerMS)
			check("output rate", row.outputTPS, tc.rateMil)
			if row.completionTokens != tc.completion {
				t.Fatalf("completion_tokens label = %d, want %d", row.completionTokens, tc.completion)
			}
			if row.streamingMode != tc.mode {
				t.Fatalf("streaming_mode = %q, want %q", row.streamingMode, tc.mode)
			}
		})
	}
}

func TestServingDeltaObserverClassification(t *testing.T) {
	start := time.Unix(1_700_000_000, 0)
	cases := []struct {
		name              string
		frames            []string
		reasoning, answer bool
	}{
		{"role_only", []string{`{"choices":[{"delta":{"role":"assistant"}}]}`}, false, false},
		{"empty_content", []string{`{"choices":[{"delta":{"content":""}}]}`}, false, false},
		{"usage_only", []string{`{"choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}`}, false, false},
		{"reasoning", []string{`{"choices":[{"delta":{"reasoning_content":"x"}}]}`}, true, false},
		{"refusal", []string{`{"choices":[{"delta":{"refusal":"no"}}]}`}, false, true},
		{"tool_name_only", []string{`{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"f"}}]}}]}`}, false, true},
		{"legacy_function_call", []string{`{"choices":[{"delta":{"function_call":{"name":"f","arguments":"{}"}}}]}`}, false, true},
		{"think_split_across_frames", []string{`{"choices":[{"delta":{"content":"<thi"}}]}`, `{"choices":[{"delta":{"content":"nk>hidden</think>"}}]}`}, true, false},
		{"think_then_answer_one_frame", []string{`{"choices":[{"delta":{"content":"<think>a</think>b"}}]}`}, true, true},
		{"unknown_container_ignored", []string{`{"choices":[{"delta":{"foo":{"content":"x"}}}]}`}, false, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var o servingDeltaObserver
			for i, frame := range tc.frames {
				o.observe(frame, start.Add(time.Duration(i+1)*time.Millisecond))
			}
			if got := !o.firstReasoningAt.IsZero(); got != tc.reasoning {
				t.Fatalf("reasoning = %v, want %v", got, tc.reasoning)
			}
			if got := !o.firstAnswerAt.IsZero(); got != tc.answer {
				t.Fatalf("answer = %v, want %v", got, tc.answer)
			}
		})
	}
}

// The estimate mirrors the coordinator's SPEC-002-R005 generatedOutputTokens:
// tool names plus canonical compact-JSON arguments, divided by 4, rounded up.
func TestServingAnswerEstimateMirrorsCoordinatorRule(t *testing.T) {
	var o servingDeltaObserver
	at := time.Unix(1_700_000_000, 0)
	o.observe(`{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"lookup","arguments":"{\"city\": \"Pa"}}]}}]}`, at)
	o.observe(`{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ris\", \"days\": 3.0}"}}]}}]}`, at)
	// "lookup" (6) + {"city":"Paris","days":3} (25) = 31 bytes -> 8 tokens.
	if got := o.estimatedAnswerTokens(); got != 8 {
		t.Fatalf("estimate = %d, want 8", got)
	}
	if got := servingCanonicalArgumentsLen(`{"a": 1.50, "b": [1e2]}`); got != int64(len(`{"a":1.5,"b":[100]}`)) {
		t.Fatalf("canonical len = %d", got)
	}
	if got := servingCanonicalArgumentsLen(`not json`); got != 8 {
		t.Fatalf("raw len = %d, want 8", got)
	}
}

func TestServingSnapshotRateGates(t *testing.T) {
	start := time.Unix(1_700_000_000, 0)
	text := strings.Repeat("a", 4000) // 1000 tokens
	frame := `{"choices":[{"delta":{"content":"` + text + `"}}]}`
	cases := []struct {
		name   string
		window time.Duration
		frame  string
		want   int64 // -1 absent
	}{
		{"under_50ms_window", 49 * time.Millisecond, frame, -1},
		{"clamped_at_2000_tps", 50 * time.Millisecond, frame, 2_000_000},
		{"under_8_tokens", time.Second, `{"choices":[{"delta":{"content":"tiny"}}]}`, -1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			timing := newGatewayPhaseTiming(start)
			timing.streamingMode = "incremental"
			timing.observeStreamDelta(tc.frame, start.Add(10*time.Millisecond))
			timing.observeStreamDelta(tc.frame, start.Add(10*time.Millisecond+tc.window))
			got := timing.servingSnapshot().outputTPSMilliTokens
			if tc.want < 0 {
				if got != nil {
					t.Fatalf("rate = %d, want absent", *got)
				}
				return
			}
			if got == nil || *got != tc.want {
				t.Fatalf("rate = %v, want %d", got, tc.want)
			}
		})
	}
}

// Relay-blind and privacy-class frames carry no plaintext delta, so nothing is
// classified, and the engine label stays unknown.
func TestServingTelemetryOpaquePrivacyFrameRecordsNothing(t *testing.T) {
	start := time.Unix(1_700_000_000, 0)
	timing := newGatewayPhaseTiming(start)
	timing.observeCoordinatorResponse(http.Header{streamingModeResponseHeader: []string{"incremental"}}, start)
	timing.observeStreamDelta(`{"object":"macprovider.privacy_frame","version":"privacy-response-v1","seq":0,"final":true,"ciphertext":"AAAA"}`, start.Add(time.Second))
	snap := timing.servingSnapshot()
	if snap.firstReasoningMS != nil || snap.firstAnswerMS != nil || snap.outputTPSMilliTokens != nil {
		t.Fatalf("opaque frame produced a quantity: %+v", snap)
	}
	if snap.servingEngine != "unknown" {
		t.Fatalf("engine = %q, want unknown", snap.servingEngine)
	}
}

func TestServingEngineFromRouteTrace(t *testing.T) {
	cases := map[string]string{
		servingTestRouteTrace: "continuous_batching",
		"v=1; phase=interactive; basis=measured; evidence=fresh; engine=native_mtp; latency=low": "native_mtp",
		"v=1; phase=interactive; basis=measured; evidence=fresh; engine=shard; latency=low":      "unknown",
		"": "unknown",
	}
	for value, want := range cases {
		h := http.Header{}
		if value != "" {
			h.Set(routeTraceResponseHeader, value)
		}
		if got := servingEngineFromRouteTrace(h); got != want {
			t.Fatalf("engine(%q) = %q, want %q", value, got, want)
		}
	}
}

func TestProviderTimingLabelsAreBounded(t *testing.T) {
	labels, ok := providerTimingLabelsFromJSON([]byte(`{"usage":{"prompt_tokens":1,"completion_tokens":1,"macprovider_queue_ms":20,"macprovider_first_token_ms":null,"macprovider_first_answer_ms":3600001,"macprovider_decode_ms":-1}}`))
	if !ok {
		t.Fatal("usage not found")
	}
	if labels.queueMS == nil || *labels.queueMS != 20 {
		t.Fatalf("queue = %v, want 20", labels.queueMS)
	}
	if labels.firstTokenMS != nil || labels.firstAnswerMS != nil || labels.decodeMS != nil {
		t.Fatalf("out-of-bound labels stored: %+v", labels)
	}
}

// A relay-blind chat stream writes no demand row today: the relay-blind
// dispatch returns before the row's requested model is set. The serving
// quantities therefore cannot be mislabeled on that path.
func TestServingTelemetryRelayBlindStreamWritesNoDemandRow(t *testing.T) {
	res := privacyReservationFixture(t, true, relayblind.EndpointChatCompletions)
	raw := pilotEnvelopeFixture(t, res)
	digest := sha256.Sum256(raw)
	digestText := base64.RawURLEncoding.EncodeToString(digest[:])
	upstream, _ := privacyCoordinator(t, res, raw, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set(relayBlindValidatedHeader, digestText)
		setPrivacyChatEcho(w, privacyCoordinatorVerifiedAt)
		w.Header().Set(settlementModeHeader, "observe")
		w.Header().Set(streamingModeResponseHeader, "incremental")
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, "data: {\"object\":\"chat.completion.chunk\",\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"plain\"}}]}\n\ndata: {\"object\":\"chat.completion.chunk\",\"model\":\"test-model\",\"choices\":[],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":2,\"total_tokens\":6}}\n\ndata: [DONE]\n\n")
	})
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
		enablePrivacy(c)
		c.Coordinator.BuyerURL = upstream.URL
	})
	account := "privacy-serving-stream"
	key := createAccountAndKey(t, store, cfg, account)
	reserve := postPrivacy(h, key, "/v1/relay-blind/route-reservations", privacyReservationBody(t, res), map[string]string{privacyClassHeader: privacyClassV1})
	if reserve.Code != http.StatusOK {
		t.Fatalf("reserve %d %s", reserve.Code, reserve.Body.String())
	}
	chat := postPrivacy(h, key, "/v1/chat/completions", raw, privacyChatHeaders())
	if chat.Code != http.StatusOK {
		t.Fatalf("status %d %s", chat.Code, chat.Body.String())
	}
	if n := demandEventCount(t, dbPath, account); n != 0 {
		t.Fatalf("relay-blind demand rows = %d, want 0", n)
	}
}

func TestAdminDemandLatencyRequiresOperatorKeyAndNamesNoProviderOrBuyer(t *testing.T) {
	h, store, _, _ := newTestHarness(t, fakeOAuth{})
	for i := int64(1); i <= 5; i++ {
		answer := i * 10
		if err := store.InsertDemandEvent(context.Background(), storage.DemandEvent{
			RequestID: "req_latency_" + strconv.FormatInt(i, 10), BuyerHash: "buyer_secret_hash", TrafficClass: "paid",
			RequestedModel: "llama", ProviderID: "prov_private", TerminalResult: "success",
			StreamingMode: "incremental", ServingEngine: "native_mtp", GatewayFirstAnswerMs: &answer,
			CreatedAt: fixedNow().Add(-time.Minute),
		}); err != nil {
			t.Fatalf("InsertDemandEvent: %v", err)
		}
	}
	get := func(path, bearer string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		if bearer != "" {
			req.Header.Set("Authorization", "Bearer "+bearer)
		}
		resp := httptest.NewRecorder()
		h.ServeHTTP(resp, req)
		return resp
	}
	for _, bearer := range []string{"", "not-the-operator-key"} {
		if resp := get("/admin/demand-latency", bearer); resp.Code != http.StatusUnauthorized {
			t.Fatalf("bearer %q status=%d, want 401", bearer, resp.Code)
		}
	}
	if resp := get("/admin/demand-latency?window=30d", "operator-key"); resp.Code != http.StatusBadRequest {
		t.Fatalf("bad window status=%d, want 400", resp.Code)
	}
	resp := get("/admin/demand-latency?window=24h", "operator-key")
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	body := resp.Body.String()
	if strings.Contains(body, "prov_private") || strings.Contains(body, "buyer_secret_hash") {
		t.Fatalf("operator read leaked provider or buyer: %s", body)
	}
	var out struct {
		Window string                       `json:"window"`
		Cells  []map[string]json.RawMessage `json:"cells"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &out); err != nil {
		t.Fatalf("json: %v", err)
	}
	if out.Window != "24h" || len(out.Cells) != 1 {
		t.Fatalf("response = %s", body)
	}
	var keys []string
	for key := range out.Cells[0] {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	if got, want := strings.Join(keys, ","), "gateway_first_answer_ms,gateway_first_reasoning_ms,gateway_output_rate_millitokens_per_s,model,serving_engine"; got != want {
		t.Fatalf("cell fields = %s, want %s", got, want)
	}
	if got := string(out.Cells[0]["gateway_first_answer_ms"]); got != `{"samples":5,"p50":30,"p95":null}` {
		t.Fatalf("first answer = %s", got)
	}
}
