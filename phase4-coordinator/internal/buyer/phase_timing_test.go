package buyer

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

func TestPhaseTimingResponseWriterInjectsHeaders(t *testing.T) {
	start := time.Unix(1_700_000_000, 0)
	state := &forwardState{queueWait: 25 * time.Millisecond}
	state.phaseTiming.init(start)
	state.phaseTiming.markCoordRoutingDone(start.Add(10 * time.Millisecond))
	state.phaseTiming.markProviderDispatchStart(start.Add(20*time.Millisecond), "s1")
	state.phaseTiming.markProviderDispatchDone(start.Add(30 * time.Millisecond))
	state.phaseTiming.markProviderFirstByte(start.Add(80 * time.Millisecond))
	state.phaseTiming.markProviderDone(start.Add(140 * time.Millisecond))

	rr := httptest.NewRecorder()
	tw := &phaseTimingResponseWriter{
		ResponseWriter: rr,
		state:          state,
		now: func() time.Time {
			return start.Add(150 * time.Millisecond)
		},
	}

	tw.WriteHeader(http.StatusOK)

	assertHeader := func(name, want string) {
		t.Helper()
		if got := rr.Header().Get(name); got != want {
			t.Fatalf("%s = %q, want %q", name, got, want)
		}
	}
	assertHeader(phaseTimingCoordRoutingHeader, "10")
	assertHeader(phaseTimingCoordAdmissionHeader, "25")
	assertHeader(phaseTimingProviderDispatchHeader, "10")
	assertHeader(phaseTimingProviderPrefillHeader, "50")
	assertHeader(phaseTimingProviderDecodeHeader, "60")
	assertHeader(phaseTimingCoordinatorTotalHeader, "150")
}

func TestPhaseTimingResponseWriterInjectsOnWriteAndFlush(t *testing.T) {
	start := time.Unix(1_700_000_000, 0)
	state := &forwardState{}
	state.phaseTiming.init(start)
	state.phaseTiming.markCoordRoutingDone(start.Add(10 * time.Millisecond))

	t.Run("write", func(t *testing.T) {
		rr := httptest.NewRecorder()
		tw := &phaseTimingResponseWriter{
			ResponseWriter: rr,
			state:          state,
			now: func() time.Time {
				return start.Add(30 * time.Millisecond)
			},
		}
		if _, err := tw.Write([]byte("ok")); err != nil {
			t.Fatal(err)
		}
		if got, want := rr.Header().Get(phaseTimingCoordRoutingHeader), "10"; got != want {
			t.Fatalf("coord routing header = %q, want %q", got, want)
		}
	})

	t.Run("flush", func(t *testing.T) {
		rr := httptest.NewRecorder()
		tw := &phaseTimingResponseWriter{
			ResponseWriter: rr,
			state:          state,
			now: func() time.Time {
				return start.Add(30 * time.Millisecond)
			},
		}
		tw.Flush()
		if got, want := rr.Header().Get(phaseTimingCoordRoutingHeader), "10"; got != want {
			t.Fatalf("coord routing header = %q, want %q", got, want)
		}
	})
}

func TestWritePhaseTimingTrailersInjectsTerminalFields(t *testing.T) {
	start := time.Unix(1_700_000_000, 0)
	state := &forwardState{}
	state.phaseTiming.init(start)
	state.phaseTiming.markProviderDispatchDone(start.Add(30 * time.Millisecond))
	state.phaseTiming.markProviderFirstByte(start.Add(80 * time.Millisecond))
	state.phaseTiming.markProviderDone(start.Add(240 * time.Millisecond))

	headers := http.Header{}
	writePhaseTimingTrailers(headers, state, start.Add(250*time.Millisecond))

	if got, want := headers.Get(http.TrailerPrefix+phaseTimingProviderDecodeHeader), "160"; got != want {
		t.Fatalf("provider decode trailer = %q, want %q", got, want)
	}
	if got, want := headers.Get(http.TrailerPrefix+phaseTimingCoordinatorTotalHeader), "250"; got != want {
		t.Fatalf("coordinator total trailer = %q, want %q", got, want)
	}
}

func TestPhaseTimingStreamingTrailersSurviveHTTPResult(t *testing.T) {
	start := time.Unix(1_700_000_000, 0)
	state := &forwardState{}
	state.phaseTiming.init(start)
	state.phaseTiming.markCoordRoutingDone(start.Add(10 * time.Millisecond))
	state.phaseTiming.markProviderDispatchStart(start.Add(20*time.Millisecond), "s1")
	state.phaseTiming.markProviderDispatchDone(start.Add(30 * time.Millisecond))
	state.phaseTiming.markProviderFirstByte(start.Add(40 * time.Millisecond))

	rr := httptest.NewRecorder()
	tw := &phaseTimingResponseWriter{
		ResponseWriter: rr,
		state:          state,
		now: func() time.Time {
			return start.Add(50 * time.Millisecond)
		},
	}

	tw.WriteHeader(http.StatusOK)
	state.phaseTiming.markProviderDone(start.Add(240 * time.Millisecond))
	writePhaseTimingTrailers(tw.Header(), state, start.Add(260*time.Millisecond))
	if _, err := tw.Write([]byte("data: {}\n\n")); err != nil {
		t.Fatal(err)
	}

	result := rr.Result()
	defer result.Body.Close()
	if got, want := result.Header.Get(phaseTimingProviderDecodeHeader), "0"; got != want {
		t.Fatalf("initial decode header = %q, want %q", got, want)
	}
	if got, want := result.Trailer.Get(phaseTimingProviderDecodeHeader), "200"; got != want {
		t.Fatalf("decode trailer = %q, want %q", got, want)
	}
	if got, want := result.Trailer.Get(phaseTimingCoordinatorTotalHeader), "260"; got != want {
		t.Fatalf("coordinator total trailer = %q, want %q", got, want)
	}
}

func TestForwardStreamingPublishesTerminalPhaseTimingTrailers(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		if flusher, ok := w.(http.Flusher); ok {
			flusher.Flush()
		}
		_, _ = w.Write([]byte("data: {\"id\":\"chatcmpl\",\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n"))
		if flusher, ok := w.(http.Flusher); ok {
			flusher.Flush()
		}
		time.Sleep(20 * time.Millisecond)
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer upstream.Close()

	server := NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Now())
	start := time.Now()
	state := &forwardState{}
	state.phaseTiming.init(start)
	state.phaseTiming.markCoordRoutingDone(start.Add(time.Millisecond))
	rr := httptest.NewRecorder()
	tw := &phaseTimingResponseWriter{
		ResponseWriter: rr,
		state:          state,
		now:            time.Now,
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{}`))
	body := []byte(`{"model":"llama","stream":true,"messages":[{"role":"user","content":"hi"}]}`)
	provider := pool.Provider{
		ProviderID:  "provider-1",
		AssignedID:  "route-1",
		EndpointURL: upstream.URL,
	}

	result, status, _ := server.forwardStreaming(tw, req, "req-1", body, provider, "llama", time.Second, nil, state, 0)

	if result != wsForwardComplete {
		t.Fatalf("result=%q, want %q", result, wsForwardComplete)
	}
	if status != http.StatusOK {
		t.Fatalf("status=%d, want %d body=%s", status, http.StatusOK, rr.Body.String())
	}
	httpResult := rr.Result()
	defer httpResult.Body.Close()
	if got := httpResult.Trailer.Get(phaseTimingProviderDecodeHeader); got == "" || got == "0" {
		t.Fatalf("provider decode trailer = %q, want non-zero", got)
	}
	if got := httpResult.Trailer.Get(phaseTimingCoordinatorTotalHeader); got == "" || got == "0" {
		t.Fatalf("coordinator total trailer = %q, want non-zero", got)
	}
}

func TestForwardStreamingNon200MarksFirstByteOnBodyRead(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadGateway)
		if flusher, ok := w.(http.Flusher); ok {
			flusher.Flush()
		}
		time.Sleep(120 * time.Millisecond)
		_, _ = w.Write([]byte(`{"error":{"code":"provider_failed"}}`))
	}))
	defer upstream.Close()

	server := NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Now())
	start := time.Now()
	state := &forwardState{}
	state.phaseTiming.init(start)
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{}`))
	body := []byte(`{"model":"llama","stream":true,"messages":[{"role":"user","content":"hi"}]}`)
	provider := pool.Provider{
		ProviderID:  "provider-1",
		AssignedID:  "route-1",
		EndpointURL: upstream.URL,
	}

	result, status, _ := server.forwardStreaming(rr, req, "req-1", body, provider, "llama", time.Second, nil, state, 0)

	if result != wsForwardFailed {
		t.Fatalf("result=%q, want %q", result, wsForwardFailed)
	}
	if status != http.StatusBadGateway {
		t.Fatalf("status=%d, want %d", status, http.StatusBadGateway)
	}
	snap := state.phaseTiming.snapshot()
	if got := durationMillisBetween(snap.providerDispatchDone, snap.providerFirstByte); got < 80 {
		t.Fatalf("provider prefill = %d, want at least 80 to prove header arrival was not counted as first byte", got)
	}
}

func TestPhaseTimingFinalAttemptSnapshotDoesNotMixPriorDispatch(t *testing.T) {
	start := time.Unix(1_700_000_000, 0)
	state := &forwardState{queueWait: 7 * time.Millisecond}
	state.phaseTiming.init(start)
	state.phaseTiming.markCoordRoutingDone(start.Add(10 * time.Millisecond))
	state.phaseTiming.markProviderDispatchStart(start.Add(20*time.Millisecond), "s1")
	state.phaseTiming.markProviderDispatchDone(start.Add(30 * time.Millisecond))
	state.phaseTiming.markProviderFirstByte(start.Add(50 * time.Millisecond))
	state.phaseTiming.markProviderDone(start.Add(60 * time.Millisecond))

	state.phaseTiming.markCoordRoutingDone(start.Add(100 * time.Millisecond))
	state.phaseTiming.markProviderDispatchStart(start.Add(110*time.Millisecond), "s2")
	state.phaseTiming.markProviderDispatchDone(start.Add(115 * time.Millisecond))
	state.phaseTiming.markProviderFirstByte(start.Add(150 * time.Millisecond))
	state.phaseTiming.markProviderDone(start.Add(210 * time.Millisecond))

	headers := http.Header{}
	writePhaseTimingHeaders(headers, state, start.Add(220*time.Millisecond))

	assertHeader := func(name, want string) {
		t.Helper()
		if got := headers.Get(name); got != want {
			t.Fatalf("%s = %q, want %q", name, got, want)
		}
	}
	assertHeader(phaseTimingCoordRoutingHeader, "100")
	assertHeader(phaseTimingProviderDispatchHeader, "5")
	assertHeader(phaseTimingProviderPrefillHeader, "35")
	assertHeader(phaseTimingProviderDecodeHeader, "60")
}

func TestPhaseTimingRequestLogDurationsAreNullable(t *testing.T) {
	start := time.Unix(1_700_000_000, 0)
	state := &forwardState{}
	state.phaseTiming.init(start)
	state.phaseTiming.markProviderDispatchStart(start.Add(10*time.Millisecond), "s1")
	state.phaseTiming.markProviderDispatchDone(start.Add(20 * time.Millisecond))

	snap := state.phaseTiming.snapshot()
	if got := snap.requestLogTTFTMs(); got != nil {
		t.Fatalf("TTFT = %v, want nil before provider first byte", *got)
	}
	if got := snap.requestLogDecodeMs(); got != nil {
		t.Fatalf("decode = %v, want nil before provider done", *got)
	}

	state.phaseTiming.markProviderFirstByte(start.Add(75 * time.Millisecond))
	state.phaseTiming.markProviderDone(start.Add(130 * time.Millisecond))
	snap = state.phaseTiming.snapshot()
	if got := snap.requestLogTTFTMs(); got == nil || *got != 55 {
		t.Fatalf("TTFT = %v, want 55", got)
	}
	if got := snap.requestLogDecodeMs(); got == nil || *got != 55 {
		t.Fatalf("decode = %v, want 55", got)
	}
}

func TestPhaseTimingNowFallsBackWhenClockUnset(t *testing.T) {
	before := time.Now()
	got := phaseTimingNow(&Server{})
	after := time.Now()
	if got.Before(before) || got.After(after.Add(50*time.Millisecond)) {
		t.Fatalf("fallback time %v outside expected range [%v, %v]", got, before, after)
	}
}

func TestFirstByteTimingReaderMarksOnlyAfterBytes(t *testing.T) {
	marks := 0
	reader := &firstByteTimingReader{
		r: bytes.NewBufferString("abc"),
		mark: func() {
			marks++
		},
	}

	buf := make([]byte, 2)
	n, err := reader.Read(buf)
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 || marks != 1 {
		t.Fatalf("first read n=%d marks=%d, want n=2 marks=1", n, marks)
	}
	n, err = reader.Read(buf)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 || marks != 1 {
		t.Fatalf("second read n=%d marks=%d, want n=1 marks=1", n, marks)
	}

	empty := &firstByteTimingReader{
		r: bytes.NewBufferString(""),
		mark: func() {
			marks++
		},
	}
	n, err = empty.Read(buf)
	if err != io.EOF {
		t.Fatalf("empty read err=%v, want EOF", err)
	}
	if n != 0 || marks != 1 {
		t.Fatalf("empty read n=%d marks=%d, want n=0 marks=1", n, marks)
	}
}
