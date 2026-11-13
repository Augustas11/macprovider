package router

import (
	"database/sql"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
)

func TestParseServedPathGrammar(t *testing.T) {
	for _, tc := range []struct {
		value string
		path  string
		rows  int64
		ok    bool
	}{
		{"v=1; path=serial; rows=1", "serial", 1, true},
		{"v=1; path=continuous_batching; rows=3", "continuous_batching", 3, true},
		{"v=1; path=native_mtp; rows=256", "native_mtp", 256, true},
		{"v=1; path=shard_group; rows=12", "shard_group", 12, true},
		{"v=1; path=unknown; rows=unknown", "unknown", 0, true},
		{"v=1; path=unknown; rows=3", "", 0, false},
		{"v=1; path=serial; rows=unknown", "", 0, false},
		{"v=1; path=serial; rows=0", "", 0, false},
		{"v=1; path=serial; rows=257", "", 0, false},
		{"v=1; path=serial; rows=01", "", 0, false},
		{"v=1; path=serial; rows=+1", "", 0, false},
		{"v=1; path=serial; rows=1 ", "", 0, false},
		{"v=1; path=serial; rows=1000", "", 0, false},
		{"v=2; path=serial; rows=1", "", 0, false},
		{"v=1;path=serial;rows=1", "", 0, false},
		{"v=1; path=Serial; rows=1", "", 0, false},
		{"v=1; path=general_mlx; rows=1", "", 0, false},
		{"v=1; rows=1; path=serial", "", 0, false},
		{"", "", 0, false},
	} {
		path, rows, ok := parseServedPath(tc.value)
		if ok != tc.ok || path != tc.path {
			t.Fatalf("%q = %q %v %v, want %q %v", tc.value, path, rows, ok, tc.path, tc.ok)
		}
		if tc.rows == 0 && rows != nil || tc.rows != 0 && (rows == nil || *rows != tc.rows) {
			t.Fatalf("%q rows = %v, want %d", tc.value, rows, tc.rows)
		}
	}
}

// A valid trailer replaces a header value; an invalid one changes nothing.
// The label never enters the timing log attributes.
func servedPathHeaderValue(value string) http.Header {
	h := http.Header{}
	h.Set(servedPathResponseHeader, value)
	return h
}

func TestServedPathObserversTrailerWins(t *testing.T) {
	timing := newGatewayPhaseTiming(fixedNow())
	timing.observeCoordinatorResponse(servedPathHeaderValue("v=1; path=serial; rows=1"), fixedNow())
	timing.observeCoordinatorTrailers(servedPathHeaderValue("v=1; path=bogus; rows=1"))
	if snap := timing.servingSnapshot(); snap.servedPath != "serial" || snap.servedRows == nil || *snap.servedRows != 1 {
		t.Fatalf("after invalid trailer: %q %v", snap.servedPath, snap.servedRows)
	}
	timing.observeCoordinatorTrailers(servedPathHeaderValue("v=1; path=native_mtp; rows=4"))
	if snap := timing.servingSnapshot(); snap.servedPath != "native_mtp" || snap.servedRows == nil || *snap.servedRows != 4 {
		t.Fatalf("after trailer: %q %v", snap.servedPath, snap.servedRows)
	}
	for _, attr := range timing.attrs(fixedNow()) {
		if s, ok := attr.(string); ok && (strings.Contains(s, "served") || strings.Contains(s, "native_mtp")) {
			t.Fatalf("timing log attributes carry the label: %v", timing.attrs(fixedNow()))
		}
	}
	var nilTiming *gatewayPhaseTiming
	nilTiming.observeCoordinatorTrailers(http.Header{})
}

// trailerBody returns one SSE frame per Read and publishes its trailers at
// EOF, as net/http does, so a reader that stops at a terminal event never
// sees them.
type trailerBody struct {
	frames  []string
	trailer http.Header
	values  http.Header
	rest    []byte
}

func (b *trailerBody) Read(p []byte) (int, error) {
	if len(b.rest) == 0 {
		if len(b.frames) == 0 {
			for k, v := range b.values {
				b.trailer[k] = v
			}
			return 0, io.EOF
		}
		b.rest, b.frames = []byte(b.frames[0]), b.frames[1:]
	}
	n := copy(p, b.rest)
	b.rest = b.rest[n:]
	return n, nil
}

func (b *trailerBody) Close() error { return nil }

// The served-path value reaches no buyer as a header or trailer on any of
// the three surfaces, a buyer-supplied copy is stripped at ingress, and the
// demand row stores the label. A streamed request reads the coordinator's
// trailers only when it reads to EOF: every surface drains after its
// terminal event when the coordinator declared settlement-finality trailers
// (a gateway that negotiated them), and otherwise stops there and keeps the
// header value, here absent, so the row stores NULL.
func TestServedPathStrippedFromBuyerAndStored(t *testing.T) {
	for _, declared := range []bool{true, false} {
		var mu sync.Mutex
		var injected []string
		frames := []string{
			"data: " + `{"id":"c1","model":"llama","choices":[{"index":0,"delta":{"role":"assistant","content":"The answer is here."}}]}` + "\n\n",
			"data: " + `{"id":"c1","model":"llama","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":5,"total_tokens":8}}` + "\n\n",
			"data: [DONE]\n\n",
		}
		nonStreamBody := `{"id":"c1","object":"chat.completion","model":"llama","choices":[{"index":0,"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4}}`
		client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			mu.Lock()
			injected = append(injected, r.Header.Values(servedPathResponseHeader)...)
			mu.Unlock()
			if r.URL.Path != "/v1/chat/completions" {
				return responseWithBody(http.StatusNotFound, nil, `{}`), nil
			}
			raw, _ := io.ReadAll(r.Body)
			if !strings.Contains(string(raw), `"stream":true`) {
				header := servedPathHeaderValue("v=1; path=serial; rows=1")
				header.Set("Content-Type", "application/json")
				return responseWithBody(http.StatusOK, header, nonStreamBody), nil
			}
			header := http.Header{}
			header.Set("Content-Type", "text/event-stream")
			header.Set(streamingModeResponseHeader, "incremental")
			resp := &http.Response{StatusCode: http.StatusOK, Header: header, Trailer: http.Header{}}
			if declared {
				resp.Trailer[http.CanonicalHeaderKey(settlementOutcomeHeader)] = nil
			}
			resp.Body = &trailerBody{frames: append([]string(nil), frames...), trailer: resp.Trailer, values: servedPathHeaderValue("v=1; path=continuous_batching; rows=3")}
			return resp, nil
		})}
		h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
			cfg.Coordinator.BuyerURL = "http://coordinator.test"
			cfg.Features.ResponsesAPIEnabled = true
			cfg.Features.AnthropicMessagesEnabled = true
		}, WithHTTPClient(client))
		inject := map[string]string{servedPathResponseHeader: "v=1; path=native_mtp; rows=9"}
		streamPath, streamRows := "continuous_batching", int64(3)
		if !declared {
			streamPath, streamRows = "", 0
		}
		for _, tc := range []struct {
			name     string
			post     func(key string) *httptest.ResponseRecorder
			wantPath string
			wantRows int64
		}{
			{"chat_completions_stream", func(key string) *httptest.ResponseRecorder {
				return postChat(t, h, key, `{"model":"llama","stream":true,"max_tokens":64,"messages":[{"role":"user","content":"hi"}]}`, inject)
			}, streamPath, streamRows},
			{"chat_completions", func(key string) *httptest.ResponseRecorder {
				return postChat(t, h, key, `{"model":"llama","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}`, inject)
			}, "serial", 1},
			{"responses_stream", func(key string) *httptest.ResponseRecorder {
				return postResponses(t, h, key, `{"model":"llama","stream":true,"max_output_tokens":64,"input":"hi"}`, inject)
			}, streamPath, streamRows},
			{"messages_stream", func(key string) *httptest.ResponseRecorder {
				return postAnthropicMessages(t, h, key, `{"model":"llama","stream":true,"max_tokens":64,"messages":[{"role":"user","content":"hi"}]}`, inject)
			}, streamPath, streamRows},
		} {
			t.Run(fmt.Sprintf("%s_declared_%v", tc.name, declared), func(t *testing.T) {
				account := fmt.Sprintf("acct_served_%s_%v", tc.name, declared)
				key := createAccountAndKey(t, store, cfg, account)
				resp := tc.post(key)
				result := resp.Result()
				for _, h := range []http.Header{result.Header, result.Trailer} {
					for name := range h {
						if strings.EqualFold(name, servedPathResponseHeader) || strings.Contains(strings.ToLower(name), "served") {
							t.Fatalf("buyer response carries %s", name)
						}
					}
				}
				if strings.Contains(resp.Body.String(), "rows=") || strings.Contains(resp.Body.String(), "served_path") {
					t.Fatalf("buyer body carries the label: %s", resp.Body.String())
				}
				db, err := sql.Open("sqlite", dbPath)
				if err != nil {
					t.Fatal(err)
				}
				defer db.Close()
				var path sql.NullString
				var rows sql.NullInt64
				if err := db.QueryRow(`SELECT served_path, served_rows FROM demand_events WHERE buyer_hash = ? ORDER BY event_id DESC LIMIT 1`,
					demandBuyerHash("test-key-hash-secret", account)).Scan(&path, &rows); err != nil {
					t.Fatalf("demand row (status %d): %v", resp.Code, err)
				}
				if path.String != tc.wantPath || rows.Int64 != tc.wantRows || path.Valid != (tc.wantPath != "") {
					t.Fatalf("stored %v %v, want %q %d", path, rows, tc.wantPath, tc.wantRows)
				}
			})
		}
		if len(injected) != 0 {
			t.Fatalf("buyer-supplied served-path header reached the coordinator: %v", injected)
		}
	}
}

func TestAdminDemandLatencyServedPathCellsKeepCells(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{})
	req := httptest.NewRequest(http.MethodGet, "/admin/demand-latency", nil)
	req.Header.Set("Authorization", "Bearer operator-key")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK || !strings.Contains(resp.Body.String(), `"cells":[]`) || !strings.Contains(resp.Body.String(), `"served_path_cells":[]`) {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
}

// Over a real HTTP transport the coordinator writes the value with
// http.TrailerPrefix without declaring it, so net/http fills resp.Trailer
// only at EOF, assigning the map when no trailer was declared at all. The
// value is stored whenever the gateway reads the body to EOF: a
// non-streamed body, and a stream drained because the coordinator declared
// settlement-finality trailers. A stream with no declaration stops at its
// terminal event; when the terminating chunk arrives later it stores NULL.
func TestServedPathUndeclaredTrailerOverRealTransport(t *testing.T) {
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		if strings.Contains(string(raw), `"stream":true`) {
			if strings.Contains(string(raw), "declared") {
				w.Header().Set("Trailer", settlementOutcomeHeader)
			}
			w.Header().Set("Content-Type", "text/event-stream")
			w.Header().Set(streamingModeResponseHeader, "incremental")
			w.WriteHeader(http.StatusOK)
			for _, frame := range []string{
				`data: {"id":"c1","model":"llama","choices":[{"index":0,"delta":{"role":"assistant","content":"The answer is here."}}]}` + "\n\n",
				`data: {"id":"c1","model":"llama","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":5,"total_tokens":8}}` + "\n\n",
				"data: [DONE]\n\n",
			} {
				_, _ = io.WriteString(w, frame)
				w.(http.Flusher).Flush()
			}
			// The terminating chunk and trailers arrive after the gateway has
			// read the terminal event.
			time.Sleep(100 * time.Millisecond)
		} else {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_, _ = io.WriteString(w, `{"id":"c1","object":"chat.completion","model":"llama","choices":[{"index":0,"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4}}`)
			// Flushing commits a chunked body, so the trailer is sent.
			w.(http.Flusher).Flush()
		}
		w.Header().Set(http.TrailerPrefix+servedPathResponseHeader, "v=1; path=native_mtp; rows=2")
	}))
	defer coordinator.Close()
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = coordinator.URL
	}, WithHTTPClient(coordinator.Client()))
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	for _, tc := range []struct {
		name, body string
		wantPath   string
	}{
		{"non_streamed", `{"model":"llama","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}`, "native_mtp"},
		{"streamed_not_drained", `{"model":"llama","stream":true,"max_tokens":64,"messages":[{"role":"user","content":"hi"}]}`, ""},
		{"streamed_drained", `{"model":"llama","stream":true,"max_tokens":64,"messages":[{"role":"user","content":"declared"}]}`, "native_mtp"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			account := "acct_served_real_" + tc.name
			resp := postChat(t, h, createAccountAndKey(t, store, cfg, account), tc.body, nil)
			if resp.Code != http.StatusOK {
				t.Fatalf("status %d body %s", resp.Code, resp.Body.String())
			}
			result := resp.Result()
			if result.Header.Get(servedPathResponseHeader) != "" || result.Trailer.Get(servedPathResponseHeader) != "" {
				t.Fatal("buyer response carries the label")
			}
			var path sql.NullString
			var rows sql.NullInt64
			if err := db.QueryRow(`SELECT served_path, served_rows FROM demand_events WHERE buyer_hash = ? ORDER BY event_id DESC LIMIT 1`,
				demandBuyerHash("test-key-hash-secret", account)).Scan(&path, &rows); err != nil {
				t.Fatalf("demand row: %v", err)
			}
			if path.String != tc.wantPath || path.Valid != (tc.wantPath != "") || (tc.wantPath != "" && rows.Int64 != 2) {
				t.Fatalf("stored %v %v, want %q", path, rows, tc.wantPath)
			}
		})
	}
}

// A relay-blind response never stores a served path, whether the value
// arrives as a header or a trailer.
func TestServedPathSuppressedOnRelayBlind(t *testing.T) {
	timing := newGatewayPhaseTiming(fixedNow())
	timing.observeCoordinatorResponse(servedPathHeaderValue("v=1; path=serial; rows=1"), fixedNow())
	timing.suppressServedPath()
	timing.observeCoordinatorTrailers(servedPathHeaderValue("v=1; path=native_mtp; rows=4"))
	if snap := timing.servingSnapshot(); snap.servedPath != "" || snap.servedRows != nil {
		t.Fatalf("relay-blind timing kept %q %v", snap.servedPath, snap.servedRows)
	}
}
