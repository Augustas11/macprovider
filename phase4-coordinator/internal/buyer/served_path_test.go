package buyer

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/augstar/macprovider-coordinator/internal/routing"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

var servedPathGrammar = regexp.MustCompile(`^v=1; path=(serial|continuous_batching|native_mtp|shard_group); rows=([1-9][0-9]{0,2})$|^v=1; path=unknown; rows=unknown$`)

const servedPathCompletion = `{"id":"c","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"Hello world, this is a reply long enough to be a measured service sample for the store."},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":7,"total_tokens":12}}`

func servedPathProfile(family string, slots int) *pool.EngineProfile {
	return &pool.EngineProfile{Version: "engine-profile-v1", EngineFamily: family, CBGrantedSlots: slots, NativeMTPActive: family == "native_mtp", ChipClass: "m4_max", RAMClassGB: 128}
}

func servedPathEnd(raw string) providerws.InferenceResponseEnd {
	end := providerws.InferenceResponseEnd{Type: "inference_response_end", Status: "complete"}
	if raw != "" {
		end.ServedPath = json.RawMessage(raw)
	}
	return end
}

// SPEC-002-R007: the report decodes strictly and is checked against the
// provider's own R006 profile and shard-group advertisement at dispatch.
func TestServedPathValueValidation(t *testing.T) {
	cb := pool.Provider{EngineProfile: servedPathProfile("continuous_batching", 4)}
	mtp := pool.Provider{EngineProfile: servedPathProfile("native_mtp", 8)}
	general := pool.Provider{EngineProfile: servedPathProfile("general_mlx", 0)}
	noProfile := pool.Provider{}
	head := pool.Provider{ShardGroupHeadV1: true}
	verified := servedPathEnd(`{"path":"shard_group","rows":1}`)
	verified.ShardGroupAttestationVerified = true
	unknown := "v=1; path=unknown; rows=unknown"
	for _, tc := range []struct {
		name     string
		provider pool.Provider
		end      providerws.InferenceResponseEnd
		want     string
		reason   string
	}{
		{"absent", cb, servedPathEnd(""), "", ""},
		{"json null", cb, servedPathEnd(`null`), "", ""},
		{"cb", cb, servedPathEnd(`{"path":"continuous_batching","rows":3}`), "v=1; path=continuous_batching; rows=3", ""},
		{"cb at slots", cb, servedPathEnd(`{"rows":4,"path":"continuous_batching"}`), "v=1; path=continuous_batching; rows=4", ""},
		{"serial on cb", cb, servedPathEnd(`{"path":"serial","rows":1}`), "v=1; path=serial; rows=1", ""},
		{"serial on general", general, servedPathEnd(`{"path":"serial","rows":1}`), "v=1; path=serial; rows=1", ""},
		{"mtp", mtp, servedPathEnd(`{"path":"native_mtp","rows":8}`), "v=1; path=native_mtp; rows=8", ""},
		{"cb on mtp", mtp, servedPathEnd(`{"path":"continuous_batching","rows":2}`), "v=1; path=continuous_batching; rows=2", ""},
		{"shard verified", head, verified, "v=1; path=shard_group; rows=1", ""},
		{"unknown member", cb, servedPathEnd(`{"path":"serial","rows":1,"provider_id":"x"}`), unknown, "decode"},
		{"missing rows", cb, servedPathEnd(`{"path":"serial"}`), unknown, "decode"},
		{"missing path", cb, servedPathEnd(`{"rows":1}`), unknown, "decode"},
		{"string rows", cb, servedPathEnd(`{"path":"serial","rows":"1"}`), unknown, "decode"},
		{"fractional rows", cb, servedPathEnd(`{"path":"serial","rows":1.5}`), unknown, "decode"},
		{"zero rows", cb, servedPathEnd(`{"path":"serial","rows":0}`), unknown, "decode"},
		{"negative rows", cb, servedPathEnd(`{"path":"serial","rows":-1}`), unknown, "decode"},
		{"rows above cap", cb, servedPathEnd(`{"path":"continuous_batching","rows":257}`), unknown, "decode"},
		{"huge rows", cb, servedPathEnd(`{"path":"serial","rows":99999999999999999999}`), unknown, "decode"},
		{"path outside enum", cb, servedPathEnd(`{"path":"unknown","rows":1}`), unknown, "decode"},
		{"header injection", cb, servedPathEnd(`{"path":"serial\r\nX-Evil: 1","rows":1}`), unknown, "decode"},
		{"case", cb, servedPathEnd(`{"path":"Serial","rows":1}`), unknown, "decode"},
		{"array", cb, servedPathEnd(`["serial",1]`), unknown, "decode"},
		{"string", cb, servedPathEnd(`"serial"`), unknown, "decode"},
		{"trailing value", cb, servedPathEnd(`{"path":"serial","rows":1}{}`), unknown, "decode"},
		{"oversize", cb, servedPathEnd(`{"path":"serial","rows":1` + strings.Repeat(" ", 120) + `}`), unknown, "decode"},
		{"shard not head", cb, servedPathEnd(`{"path":"shard_group","rows":1}`), unknown, "shard_group"},
		{"head other path", head, servedPathEnd(`{"path":"serial","rows":1}`), unknown, "shard_group"},
		{"shard unverified", head, servedPathEnd(`{"path":"shard_group","rows":1}`), unknown, "shard_group"},
		{"no profile", noProfile, servedPathEnd(`{"path":"serial","rows":1}`), unknown, "profile"},
		{"mtp on cb", cb, servedPathEnd(`{"path":"native_mtp","rows":1}`), unknown, "engine"},
		{"mtp inactive", pool.Provider{EngineProfile: &pool.EngineProfile{Version: "engine-profile-v1", EngineFamily: "native_mtp", CBGrantedSlots: 4}}, servedPathEnd(`{"path":"native_mtp","rows":1}`), unknown, "engine"},
		{"cb on general", general, servedPathEnd(`{"path":"continuous_batching","rows":1}`), unknown, "engine"},
		{"rows above slots", cb, servedPathEnd(`{"path":"continuous_batching","rows":5}`), unknown, "rows"},
		{"serial rows", cb, servedPathEnd(`{"path":"serial","rows":2}`), unknown, "rows"},
		{"cb zero slots", pool.Provider{EngineProfile: servedPathProfile("continuous_batching", 0)}, servedPathEnd(`{"path":"continuous_batching","rows":2}`), unknown, "rows"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			before := servedPathRejectedSnapshot()
			got := servedPathValue(tc.provider, tc.end)
			if got != tc.want {
				t.Fatalf("value = %q, want %q", got, tc.want)
			}
			if got != "" && !servedPathGrammar.MatchString(got) {
				t.Fatalf("value %q breaks the SPEC-002-R007 grammar", got)
			}
			after := servedPathRejectedSnapshot()
			for i, reason := range servedPathRejectReasons {
				delta := after[i] - before[i]
				if want := uint64(0); reason == tc.reason {
					if delta != 1 {
						t.Fatalf("counter %s moved by %d, want 1", reason, delta)
					}
				} else if delta != want {
					t.Fatalf("counter %s moved by %d, want 0", reason, delta)
				}
			}
		})
	}
}

func servedPathRejectedSnapshot() []uint64 {
	out := make([]uint64, len(servedPathRejectReasons))
	for i := range out {
		out[i] = servedPathRejectedTotal[i].Load()
	}
	return out
}

func TestServedPathMetricsExposition(t *testing.T) {
	var b bytes.Buffer
	writeServedPathMetrics(&b)
	for _, reason := range servedPathRejectReasons {
		if !strings.Contains(b.String(), `macprovider_served_path_rejected_total{reason="`+reason+`"}`) {
			t.Fatalf("exposition misses %s:\n%s", reason, b.String())
		}
	}
}

type servedPathScript struct {
	status     string
	servedPath string
}

// servedPathServer serves two WS providers: p1 general MLX, p2 continuous
// batching with four slots. script maps a provider to its terminal frame.
func servedPathServer(t *testing.T, stream bool, script map[string]servedPathScript) (*Server, *[]string) {
	t.Helper()
	registry := pool.NewRegistry(nil)
	// The objective ranks the higher self-reported throughput first, so p1
	// is the first selection whenever both are eligible.
	for _, p := range []struct {
		id, session string
		tps         float64
	}{{"p1", "s1", 200}, {"p2", "s2", 20}} {
		registry.Register(&pool.Provider{
			ProviderID: p.id, AssignedID: p.session, Hostname: p.id + ".local", ModelID: "model-a",
			ModelParamsB: 7, RAMGB: 16, MaxContextTokens: 20000, MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1,
			ThroughputTPSEstimate: p.tps, Tier: pool.TierPinned, InferencePath: pool.InferencePathWSTunneled,
			State: pool.StateReady, LastHeartbeatAt: time.Now().UTC(), ConnectedAt: time.Now().UTC(), BinaryVersion: "0.2.0",
		}, nil)
	}
	registry.SetEngineProfile("p1", servedPathProfile("general_mlx", 0))
	registry.SetEngineProfile("p2", servedPathProfile("continuous_batching", 4))
	var mu sync.Mutex
	var calls []string
	s := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		WithGatewayServiceToken("gw-token"),
		WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, _ bool) (*providerws.RelayStream, error) {
			mu.Lock()
			calls = append(calls, provider.ProviderID)
			mu.Unlock()
			sc, ok := script[provider.ProviderID]
			if !ok {
				t.Errorf("unexpected dispatch to %s", provider.ProviderID)
			}
			chunks := make(chan providerws.InferenceResponseChunk, 2)
			if sc.status == "complete" {
				if stream {
					chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Data: `data: {"id":"c","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello world, this is a reply"},"finish_reason":null}]}` + "\n\n"}
					chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Data: `data: {"id":"c","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}` + "\n\ndata: [DONE]\n\n"}
				} else {
					chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Data: servedPathCompletion}
				}
			}
			close(chunks)
			done := make(chan providerws.InferenceResponseEnd, 1)
			end := servedPathEnd(sc.servedPath)
			end.RequestID, end.Status, end.ChunksSent = requestID, sc.status, len(chunks)
			if sc.status == "complete" {
				end.Usage = json.RawMessage(`{"prompt_tokens":5,"completion_tokens":7,"total_tokens":12}`)
			}
			go func() {
				time.Sleep(10 * time.Millisecond)
				done <- end
			}()
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: make(chan error, 1)}, nil
		}, 10*time.Second),
	)
	return s, &calls
}

func postServedPathChat(s *Server, stream, gateway bool, pin string) *http.Response {
	body := `{"model":"model-a","messages":[{"role":"user","content":"hello"}]` + map[bool]string{true: `,"stream":true}`, false: `}`}[stream]
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader([]byte(body)))
	req.Header.Set("X-MacProvider-Retry", "1")
	if gateway {
		req.Header.Set("Authorization", "Bearer gw-token")
		req.Header.Set("X-MacProvider-Account", "acct_gateway")
	}
	if pin != "" {
		req.Header.Set("X-MacProvider-Provider", pin)
	}
	rr := httptest.NewRecorder()
	s.Handler().ServeHTTP(rr, req)
	return rr.Result()
}

func servedPathValues(resp *http.Response) (header, trailer string) {
	return resp.Header.Get(servedPathHeader), resp.Trailer.Get(servedPathHeader)
}

// A non-streamed response carries the value as a header; an incremental
// stream, committed before the provider finished, as a trailer, as the
// Timing decode value does. The route trace never carries it.
func TestServedPathHeaderAndTrailerFollowTimingRule(t *testing.T) {
	report := `{"path":"continuous_batching","rows":3}`
	want := "v=1; path=continuous_batching; rows=3"
	t.Run("non-streamed header", func(t *testing.T) {
		s, _ := servedPathServer(t, false, map[string]servedPathScript{"p2": {"complete", report}})
		resp := postServedPathChat(s, false, true, "p2")
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d", resp.StatusCode)
		}
		if header, trailer := servedPathValues(resp); header != want || trailer != "" {
			t.Fatalf("header %q trailer %q, want header %q", header, trailer, want)
		}
		if strings.Contains(resp.Header.Get(routeTraceHeader), "rows") {
			t.Fatalf("route trace carries the label: %q", resp.Header.Get(routeTraceHeader))
		}
	})
	t.Run("incremental stream trailer", func(t *testing.T) {
		s, _ := servedPathServer(t, true, map[string]servedPathScript{"p2": {"complete", report}})
		resp := postServedPathChat(s, true, true, "p2")
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d", resp.StatusCode)
		}
		header, trailer := servedPathValues(resp)
		if header != "" || trailer != want {
			t.Fatalf("header %q trailer %q, want trailer %q", header, trailer, want)
		}
		if resp.Trailer.Get(phaseTimingProviderDecodeHeader) == "" {
			t.Fatal("decode timing trailer missing: the served path must follow its rule")
		}
	})
	t.Run("buffered stream trailer", func(t *testing.T) {
		s, _ := servedPathServer(t, true, map[string]servedPathScript{"p2": {"complete", report}})
		state := &forwardState{}
		done := make(chan providerws.InferenceResponseEnd, 1)
		end := servedPathEnd(report)
		end.RequestID = "req-b"
		done <- end
		chunks := make(chan providerws.InferenceResponseChunk, 1)
		chunks <- providerws.InferenceResponseChunk{RequestID: "req-b", Data: `data: {"id":"c","choices":[{"index":0,"delta":{"content":"Hello world, this is a reply"},"finish_reason":"stop"}]}` + "\n\ndata: [DONE]\n\n"}
		close(chunks)
		relay := &providerws.RelayStream{RequestID: "req-b", Chunks: chunks, Done: done, Errors: make(chan error, 1)}
		r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
		r.Header.Set("Authorization", "Bearer gw-token")
		w := httptest.NewRecorder()
		provider := pool.Provider{ProviderID: "p2", AssignedID: "s2", EngineProfile: servedPathProfile("continuous_batching", 4)}
		s.forwardWSStreamingBuffered(w, r, "req-b", provider, relay, streamingModeBufferedKillSwitch, "", state, 1)
		if got := w.Result().Trailer.Get(servedPathHeader); got != want {
			t.Fatalf("buffered trailer = %q, want %q", got, want)
		}
	})
}

// Only a request with the gateway's internal bearer gets the value; a
// client calling the coordinator directly never does.
func TestServedPathRequiresGatewayBearer(t *testing.T) {
	for _, stream := range []bool{false, true} {
		s, _ := servedPathServer(t, stream, map[string]servedPathScript{"p2": {"complete", `{"path":"continuous_batching","rows":3}`}})
		resp := postServedPathChat(s, stream, false, "p2")
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("stream=%v status = %d", stream, resp.StatusCode)
		}
		if header, trailer := servedPathValues(resp); header != "" || trailer != "" {
			t.Fatalf("stream=%v direct client got header %q trailer %q", stream, header, trailer)
		}
	}
}

// After a failover the value describes the provider that served, never the
// first selection; a provider that reports nothing yields no value.
func TestServedPathDescribesFailoverProvider(t *testing.T) {
	for _, stream := range []bool{false, true} {
		s, calls := servedPathServer(t, stream, map[string]servedPathScript{
			"p1": {"error_queue_full", `{"path":"serial","rows":1}`},
			"p2": {"complete", `{"path":"continuous_batching","rows":2}`},
		})
		s.maxRetries = 1
		resp := postServedPathChat(s, stream, true, "")
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("stream=%v status = %d", stream, resp.StatusCode)
		}
		header, trailer := servedPathValues(resp)
		got := header + trailer
		if len(*calls) != 2 || (*calls)[0] != "p1" || (*calls)[1] != "p2" {
			t.Fatalf("stream=%v calls = %v, want p2 to serve", stream, *calls)
		}
		if got != "v=1; path=continuous_batching; rows=2" {
			t.Fatalf("stream=%v calls %v value %q, want the serving provider's", stream, *calls, got)
		}
	}
	s, _ := servedPathServer(t, false, map[string]servedPathScript{"p2": {"complete", ""}})
	if header, trailer := servedPathValues(postServedPathChat(s, false, true, "p2")); header != "" || trailer != "" {
		t.Fatalf("no report gave header %q trailer %q", header, trailer)
	}
}

func TestBeginServedPathAttemptDropsEarlierValue(t *testing.T) {
	h := http.Header{}
	h.Set(servedPathHeader, "v=1; path=serial; rows=1")
	state := &forwardState{servedPath: "v=1; path=serial; rows=1"}
	beginServedPathAttempt(h, state)
	if h.Get(servedPathHeader) != "" || state.servedPath != "" {
		t.Fatalf("header %q state %q survived the next dispatch", h.Get(servedPathHeader), state.servedPath)
	}
}

// SPEC-002-R005: the label never enters routing or the request log. The
// same attempt with and without a report leaves identical performance
// records and an identical request-log attempt.
func TestServedPathLeavesRoutingAndRequestLogUnchanged(t *testing.T) {
	run := func(report string) (routing.PerfEvidence, bool, requestLogAttempt, wsForwardResult) {
		s, _ := servedPathServer(t, false, map[string]servedPathScript{"p1": {"complete", report}})
		reqLog, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
		if err != nil {
			t.Fatalf("requestlog.OpenStore: %v", err)
		}
		t.Cleanup(func() { _ = reqLog.Close() })
		s.reqLog = reqLog
		var tick time.Duration
		s.now = func() time.Time { tick += 10 * time.Millisecond; return phaseTestNow.Add(tick) }
		if resp := postServedPathChat(s, false, true, ""); resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d", resp.StatusCode)
		}
		evidence, found := s.perf.Lookup("p1", "model-a")

		done := make(chan providerws.InferenceResponseEnd, 1)
		end := servedPathEnd(report)
		end.RequestID, end.ChunksSent = "req-n", 1
		end.Usage = json.RawMessage(`{"prompt_tokens":5,"completion_tokens":7,"total_tokens":12}`)
		done <- end
		chunks := make(chan providerws.InferenceResponseChunk, 1)
		chunks <- providerws.InferenceResponseChunk{RequestID: "req-n", Data: servedPathCompletion}
		close(chunks)
		relay := &providerws.RelayStream{RequestID: "req-n", Chunks: chunks, Done: done, Errors: make(chan error, 1)}
		r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
		r.Header.Set("Authorization", "Bearer gw-token")
		provider := pool.Provider{ProviderID: "p1", AssignedID: "s1", EngineProfile: servedPathProfile("general_mlx", 0)}
		result, attempt := s.forwardWSNonStreaming(httptest.NewRecorder(), r, "req-n", provider, relay, nil, nil, &forwardState{}, 1)
		return evidence, found, attempt, result
	}
	e1, f1, a1, r1 := run("")
	e2, f2, a2, r2 := run(`{"path":"serial","rows":1}`)
	if !f1 || !reflect.DeepEqual(e1, e2) || f1 != f2 {
		t.Fatalf("performance record changed: without %+v (%v), with %+v (%v)", e1, f1, e2, f2)
	}
	// The terminal timestamp is the wall clock of each run, not an input.
	for _, a := range []*requestLogAttempt{&a1, &a2} {
		if a.SettlementOutput != nil {
			a.SettlementOutput.TerminalStateTSUnixMS = 0
		}
	}
	if !reflect.DeepEqual(a1, a2) || r1 != r2 {
		t.Fatalf("request-log attempt changed:\nwithout %+v\nwith    %+v", a1, a2)
	}
}

// Relay-blind and privacy-class responses never carry the label: their
// forwarders do not read a served-path report or write the phase-timing
// header and trailer that carry it.
func TestServedPathNeverOnRelayBlindOrPrivacyForwarders(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	checked := 0
	for _, name := range files {
		if strings.HasSuffix(name, "_test.go") || !(strings.HasPrefix(name, "relay_blind") || strings.HasPrefix(name, "privacy")) {
			continue
		}
		raw, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		for _, forbidden := range []string{"noteServedPath", "servedPathHeader", "writePhaseTimingHeaders", "writePhaseTimingTrailers", ".servedPath"} {
			if bytes.Contains(raw, []byte(forbidden)) {
				t.Fatalf("%s references %s", name, forbidden)
			}
		}
		checked++
	}
	if checked == 0 {
		t.Fatal("no relay-blind or privacy forwarder file found")
	}
}
