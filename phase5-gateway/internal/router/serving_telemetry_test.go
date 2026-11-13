package router

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"slices"
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
				observeFrame(&o, frame, start.Add(time.Duration(i+1)*time.Millisecond))
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

// The estimate follows the coordinator's SPEC-002-R005 generatedOutputTokens rule:
// tool names plus canonical compact-JSON arguments, divided by 4, rounded up.
func TestServingAnswerEstimateFollowsCoordinatorRule(t *testing.T) {
	var o servingDeltaObserver
	at := time.Unix(1_700_000_000, 0)
	observeFrame(&o, `{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"lookup","arguments":"{\"city\": \"Pa"}}]}}]}`, at)
	observeFrame(&o, `{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ris\", \"days\": 3.0}"}}]}}]}`, at)
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
			observeFrame(&timing.deltas, tc.frame, start.Add(10*time.Millisecond))
			observeFrame(&timing.deltas, tc.frame, start.Add(10*time.Millisecond+tc.window))
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

func observeFrame(o *servingDeltaObserver, data string, at time.Time) {
	choices, ok := parseStreamingChoices(data)
	if !ok {
		return
	}
	o.observe(choices, at)
}

// Relay-blind work writes no demand row, even when the coordinator response
// carries a valid route trace and plaintext-looking frames, and the relay
// path keeps its own timing: the handler's timing_* log fields stay unmarked.
func TestServingTelemetryRelayBlindWritesNoRowAndKeepsLogTiming(t *testing.T) {
	res := privacyReservationFixture(t, true, relayblind.EndpointChatCompletions)
	raw := pilotEnvelopeFixture(t, res)
	digest := sha256.Sum256(raw)
	digestText := base64.RawURLEncoding.EncodeToString(digest[:])
	upstream, _ := privacyCoordinator(t, res, raw, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set(relayBlindValidatedHeader, digestText)
		setPrivacyChatEcho(w, privacyCoordinatorVerifiedAt)
		w.Header().Set(settlementModeHeader, "observe")
		w.Header().Set(streamingModeResponseHeader, "incremental")
		w.Header().Set(routeTraceResponseHeader, servingTestRouteTrace)
		w.Header().Set(phaseTimingProviderPrefillHeader, "137")
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, "data: {\"object\":\"chat.completion.chunk\",\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"think\",\"content\":\"plain answer\"}}]}\n\ndata: {\"object\":\"chat.completion.chunk\",\"model\":\"test-model\",\"choices\":[],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":2,\"total_tokens\":6}}\n\ndata: [DONE]\n\n")
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
	var logs bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&logs, nil)))
	chat := postPrivacy(h, key, "/v1/chat/completions", raw, privacyChatHeaders())
	slog.SetDefault(previous)
	if chat.Code != http.StatusOK {
		t.Fatalf("status %d %s", chat.Code, chat.Body.String())
	}
	if n := demandEventCount(t, dbPath, account); n != 0 {
		t.Fatalf("relay-blind demand rows = %d, want 0", n)
	}
	var line string
	for _, l := range strings.Split(logs.String(), "\n") {
		if strings.Contains(l, `msg="chat completion"`) {
			line = l
		}
	}
	if line == "" || !strings.Contains(line, "timing_provider_prefill_ms=0") {
		t.Fatalf("chat completion log timing changed for relay-blind: %q", line)
	}
}

// dispatchRelayBlindChat suppresses the demand row itself, so a reorder of the
// chat handler that sets the requested model earlier cannot start writing rows.
func TestServingTelemetryRelayBlindDispatchSuppressesDemandRow(t *testing.T) {
	_, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, nil)
	srv := New(cfg, store, fakeOAuth{}, WithNow(fixedNow))
	demand := newDemandTelemetryState(fixedNow(), "req_relay")
	demand.setSubject(usageSubject{AccountID: "acct_relay"}, "test-key-hash-secret")
	demand.setRequest(chatRequest{Model: "llama"}, "", "", 16)
	if _, ok := demand.snapshot(fixedNow(), http.StatusOK); !ok {
		t.Fatal("precondition: a populated demand state writes a row")
	}
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	r = r.WithContext(withDemandTelemetry(r.Context(), demand))
	srv.dispatchRelayBlindChat(httptest.NewRecorder(), r, []byte(`{}`), "acct_relay", nil)
	if _, ok := demand.snapshot(fixedNow(), http.StatusOK); ok {
		t.Fatal("relay-blind dispatch left the demand row enabled")
	}
}

func TestServingWhitespaceAndThinkRules(t *testing.T) {
	start := time.Unix(1_700_000_000, 0)
	content := func(text string) string {
		raw, _ := json.Marshal(text)
		return `{"choices":[{"index":0,"delta":{"content":` + string(raw) + `}}]}`
	}
	cases := []struct {
		name          string
		frames        []string
		reasoningAt   int // frame number (1-based) or 0 = absent
		answerAt      int
		estimateBytes int64
	}{
		{"whitespace_after_think_is_not_answer", []string{content("<think>plan</think>"), content("\n\n"), content("Answer")}, 1, 3, 6},
		{"empty_think_block_is_not_reasoning", []string{content("<think>\n\n</think>\n\n"), content("Hi there")}, 0, 2, 8},
		{"whitespace_after_answer_counts", []string{content("Hello"), content("\n\n"), content("World")}, 0, 1, 12},
		{"unmatched_closer_is_answer", []string{content("text</think>more")}, 0, 1, 16},
		{"reasoning_and_content_one_frame", []string{`{"choices":[{"delta":{"reasoning_content":"r","content":"a"}}]}`}, 1, 1, 1},
		{"whitespace_reasoning_content_is_not_reasoning", []string{`{"choices":[{"delta":{"reasoning_content":"  \n"}}]}`, content("ok")}, 0, 2, 2},
		{"index_only_tool_call_then_arguments", []string{
			`{"choices":[{"delta":{"tool_calls":[{"index":0}]}}]}`,
			`{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{}"}}]}}]}`,
		}, 0, 2, 2},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var o servingDeltaObserver
			at := func(n int) time.Time { return start.Add(time.Duration(n) * time.Millisecond) }
			for i, frame := range tc.frames {
				observeFrame(&o, frame, at(i+1))
			}
			check := func(name string, got time.Time, frame int) {
				t.Helper()
				if frame == 0 {
					if !got.IsZero() {
						t.Fatalf("%s set, want absent", name)
					}
					return
				}
				if !got.Equal(at(frame)) {
					t.Fatalf("%s = %v, want frame %d", name, got, frame)
				}
			}
			check("first reasoning", o.firstReasoningAt, tc.reasoningAt)
			check("first answer", o.firstAnswerAt, tc.answerAt)
			if want := (tc.estimateBytes + 3) / 4; o.estimatedAnswerTokens() != want {
				t.Fatalf("estimate = %d tokens, want %d (%d bytes)", o.estimatedAnswerTokens(), want, tc.estimateBytes)
			}
		})
	}
}

// Adversarial verifier counterexample, scaled down: thousands of distinct
// provider-chosen tool-call indexes with 1-byte arguments. The held map stays
// at the cap and the overflow bytes still count.
func TestServingToolCallKeyCapBoundsHeldState(t *testing.T) {
	var o servingDeltaObserver
	at := time.Unix(1_700_000_000, 0)
	const frames, perFrame = 50, 100
	for f := 0; f < frames; f++ {
		var calls []string
		for i := 0; i < perFrame; i++ {
			calls = append(calls, `{"index":`+strconv.Itoa(f*perFrame+i)+`,"function":{"arguments":"1"}}`)
		}
		observeFrame(&o, `{"choices":[{"delta":{"tool_calls":[`+strings.Join(calls, ",")+`]}}]}`, at)
	}
	if len(o.toolCalls) != servingMaxToolCalls {
		t.Fatalf("held tool calls = %d, want the cap %d", len(o.toolCalls), servingMaxToolCalls)
	}
	if got, want := o.estimatedAnswerTokens(), int64(frames*perFrame/4); got != want {
		t.Fatalf("estimate = %d, want %d (every argument byte counted)", got, want)
	}
}

func TestServingToolNameCountedOncePerCall(t *testing.T) {
	var o servingDeltaObserver
	at := time.Unix(1_700_000_000, 0)
	for i := 0; i < 8; i++ {
		observeFrame(&o, `{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"get_weather","arguments":"a"}}]}}]}`, at)
	}
	// "get_weather" (11) once + arguments "aaaaaaaa" (8, not JSON: raw) = 19
	// bytes -> 5 tokens. Counting the name every time would give 24.
	if got := o.estimatedAnswerTokens(); got != 5 {
		t.Fatalf("estimate = %d, want 5", got)
	}
}

func TestServingHeldArgumentsCapCountsOverflowRaw(t *testing.T) {
	var o servingDeltaObserver
	at := time.Unix(1_700_000_000, 0)
	chunk := strings.Repeat("a", 64<<10)
	for i := 0; i < 20; i++ { // 1.25 MiB of arguments
		observeFrame(&o, `{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"`+chunk+`"}}]}}]}`, at)
	}
	if o.heldArgBytes > servingMaxHeldToolArgumentBytes || o.rawArgBytes == 0 {
		t.Fatalf("held=%d raw=%d, want held within the cap and overflow raw", o.heldArgBytes, o.rawArgBytes)
	}
	if got, want := o.estimatedAnswerTokens(), int64(20*len(chunk)/4); got != want {
		t.Fatalf("estimate = %d, want %d", got, want)
	}
}

func TestServingChoiceIndexesPastBoundShareOneFilter(t *testing.T) {
	var o servingDeltaObserver
	at := time.Unix(1_700_000_000, 0)
	for i := 0; i < 1000; i++ {
		observeFrame(&o, `{"choices":[{"index":`+strconv.Itoa(i)+`,"delta":{"content":"x"}}]}`, at)
	}
	if len(o.thinkFilters) > servingMaxThinkFilters+1 {
		t.Fatalf("think filters = %d, want at most %d", len(o.thinkFilters), servingMaxThinkFilters+1)
	}
}

func TestServingRateMinimumTokenBoundary(t *testing.T) {
	start := time.Unix(1_700_000_000, 0)
	for _, tc := range []struct {
		bytesPerFrame int
		want          int64 // -1 absent
	}{
		{14, -1},   // 28 bytes -> 7 tokens
		{16, 7000}, // 32 bytes -> 8 tokens -> (8-1)/1 s
	} {
		timing := newGatewayPhaseTiming(start)
		timing.streamingMode = "incremental"
		frame := `{"choices":[{"delta":{"content":"` + strings.Repeat("a", tc.bytesPerFrame) + `"}}]}`
		observeFrame(&timing.deltas, frame, start.Add(time.Millisecond))
		observeFrame(&timing.deltas, frame, start.Add(time.Millisecond+time.Second))
		got := timing.servingSnapshot().outputTPSMilliTokens
		if tc.want < 0 && got != nil || tc.want >= 0 && (got == nil || *got != tc.want) {
			t.Fatalf("%d bytes/frame: rate = %v, want %d", tc.bytesPerFrame, got, tc.want)
		}
	}
}

func TestServingRejectsNGreaterThanOneBeforeUpstream(t *testing.T) {
	called := false
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		called = true
		return responseWithBody(http.StatusOK, nil, `{}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_serving_n2")
	resp := postChat(t, h, key, `{"model":"llama","stream":true,"n":2,"max_tokens":8,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusBadRequest || !strings.Contains(resp.Body.String(), "n_must_be_1") || called {
		t.Fatalf("status=%d called=%v body=%s", resp.Code, called, resp.Body.String())
	}
}

func TestServingProviderLabelsNonStreamedAndKeepLastValue(t *testing.T) {
	body := `{"id":"c1","object":"chat.completion","model":"llama","choices":[{"index":0,"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4,"macprovider_first_answer_ms":77}}`
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	account := "acct_serving_nonstream"
	key := createAccountAndKey(t, store, cfg, account)
	if resp := postChat(t, h, key, `{"model":"llama","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}`, nil); resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	row := readServingRow(t, dbPath, account)
	if !row.providerFirstAnswer.Valid || row.providerFirstAnswer.Int64 != 77 || row.firstAnswer.Valid {
		t.Fatalf("non-streamed row = %+v, want provider label 77 and no gateway first answer", row)
	}

	demand := newDemandTelemetryState(fixedNow(), "req")
	first, _ := providerTimingLabelsFromJSON([]byte(`{"usage":{"macprovider_queue_ms":5,"macprovider_decode_ms":9}}`))
	later, _ := providerTimingLabelsFromJSON([]byte(`{"usage":{"macprovider_queue_ms":6}}`))
	demand.setProviderTimingLabels(first)
	demand.setProviderTimingLabels(later)
	if q, d := demand.providerTiming.queueMS, demand.providerTiming.decodeMS; q == nil || *q != 6 || d == nil || *d != 9 {
		t.Fatalf("labels = queue %v decode %v, want 6 and kept 9", q, d)
	}
}

func TestServingVocabulariesMatchStoredChecks(t *testing.T) {
	if !slices.Equal(routeTraceEngineValues, storage.DemandServingEngines) {
		t.Fatalf("route-trace engines %v != stored %v", routeTraceEngineValues, storage.DemandServingEngines)
	}
	if !slices.Equal(streamingModeValues, storage.DemandStreamingModes) {
		t.Fatalf("streaming modes %v != stored %v", streamingModeValues, storage.DemandStreamingModes)
	}
}

func TestAdminDemandLatencyWindowAndMethod(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{})
	do := func(method, path string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, path, nil)
		req.Header.Set("Authorization", "Bearer operator-key")
		resp := httptest.NewRecorder()
		h.ServeHTTP(resp, req)
		return resp
	}
	if resp := do(http.MethodPost, "/admin/demand-latency"); resp.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST status=%d, want 405", resp.Code)
	}
	if resp := do(http.MethodGet, "/admin/demand-latency?window=1h"); resp.Code != http.StatusBadRequest {
		t.Fatalf("bad window status=%d, want 400", resp.Code)
	}
	for _, path := range []string{"/admin/demand-latency", "/admin/demand-latency?window="} {
		resp := do(http.MethodGet, path)
		if resp.Code != http.StatusOK || !strings.Contains(resp.Body.String(), `"window":"24h"`) {
			t.Fatalf("%s status=%d body=%s, want default 24h", path, resp.Code, resp.Body.String())
		}
	}
}
