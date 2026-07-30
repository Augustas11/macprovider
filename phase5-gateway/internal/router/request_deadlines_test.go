package router

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// ---- unit: the derived streaming ceiling -----------------------------------

// TestStreamCeilingNeverBelowLegacyWall pins the monotonicity invariant that
// makes removing the flat wall safe: whatever max_tokens a buyer asks for, the
// derived ceiling is never SHORTER than coordinator_request_seconds, so #760
// can only let a request live longer than it does today — never cut one that
// survives today.
func TestStreamCeilingNeverBelowLegacyWall(t *testing.T) {
	cfg := config.Default()
	legacy := cfg.CoordinatorTimeout()
	max := time.Duration(cfg.Timeouts.StreamCeilingMaxSeconds) * time.Second

	var previous time.Duration
	for _, maxTokens := range []int64{1, 16, 128, 512, 1024, 4096, 65536, 1 << 40, 1<<63 - 1} {
		got := streamCeiling(maxTokens, cfg)
		if got < legacy {
			t.Fatalf("streamCeiling(max_tokens=%d)=%s is BELOW the legacy wall %s", maxTokens, got, legacy)
		}
		if got > max {
			t.Fatalf("streamCeiling(max_tokens=%d)=%s exceeds stream_ceiling_max_seconds %s", maxTokens, got, max)
		}
		if got < previous {
			t.Fatalf("streamCeiling is not monotonic in max_tokens: %d -> %s after %s", maxTokens, got, previous)
		}
		previous = got
	}

	// The formula itself, on a value that lands strictly between the clamps:
	// floor 60s + 2000 * 250ms = 560s (below the 900s max, above the 300s
	// legacy floor).
	if got, want := streamCeiling(2000, cfg), 560*time.Second; got != want {
		t.Fatalf("streamCeiling(2000)=%s want %s (floor + max_tokens*per_token)", got, want)
	}
	// Below the crossover the legacy floor dominates — that IS the
	// monotonicity guarantee, not a bug.
	if got, want := streamCeiling(512, cfg), legacy; got != want {
		t.Fatalf("streamCeiling(512)=%s want the legacy floor %s", got, want)
	}
	// A legacy wall raised above the derived value floors the result.
	raised := cfg
	raised.Timeouts.CoordinatorRequestSeconds = 600
	if got, want := streamCeiling(1, raised), 600*time.Second; got != want {
		t.Fatalf("streamCeiling with coordinator_request_seconds=600 returned %s want %s", got, want)
	}
}

func TestAdaptiveDecodeIdleTimeoutExtendsSlowModelClasses(t *testing.T) {
	cfg := config.Default()
	cfg.Timeouts.StreamingIdleMS = 500

	if got, want := adaptiveDecodeIdleTimeout("llama", cfg), 500*time.Millisecond; got != want {
		t.Fatalf("unknown model idle timeout=%s want configured %s", got, want)
	}

	unbounded := cfg
	unbounded.Timeouts.StreamingIdleMS = 0
	if got := adaptiveDecodeIdleTimeout("mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit", unbounded); got != 0 {
		t.Fatalf("unbounded 30B idle timeout=%s want no timeout sentinel", got)
	}

	got := adaptiveDecodeIdleTimeout("mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit", cfg)
	if got <= cfg.StreamingIdleTimeout() {
		t.Fatalf("30B idle timeout=%s want greater than configured %s", got, cfg.StreamingIdleTimeout())
	}
	if got > decodeIdleSlowModelMax {
		t.Fatalf("30B idle timeout=%s exceeds cap %s", got, decodeIdleSlowModelMax)
	}
}

// TestEffectiveStreamCeilingClampsStructuredOutput pins the deliberate
// conservative choice in #760: SPEC-019 v0.2.4 §AC-V2-9 normatively fixes the
// structured-output streaming budget at 300s, so structured streams keep that
// sub-ceiling until the spec is amended (contract_change stays "none").
func TestEffectiveStreamCeilingClampsStructuredOutput(t *testing.T) {
	s := &Server{cfg: config.Default()}
	plain := s.effectiveStreamCeiling(4096, false)
	if plain <= spec019StructuredStreamingCeiling {
		t.Fatalf("precondition: plain ceiling %s must exceed the SPEC-019 bound %s for this test to mean anything",
			plain, spec019StructuredStreamingCeiling)
	}
	if got := s.effectiveStreamCeiling(4096, true); got != spec019StructuredStreamingCeiling {
		t.Fatalf("structured streaming ceiling=%s want the SPEC-019 pinned %s", got, spec019StructuredStreamingCeiling)
	}
	// The sub-ceiling only ever shortens: a small request stays on its own
	// (already shorter) derived ceiling.
	short := config.Default()
	short.Timeouts.StreamCeilingFloorSeconds = 10
	short.Timeouts.StreamCeilingPerTokenMS = 1
	short.Timeouts.CoordinatorRequestSeconds = 10
	shortServer := &Server{cfg: short}
	if got, want := shortServer.effectiveStreamCeiling(16, true), 10016*time.Millisecond; got != want {
		t.Fatalf("structured ceiling=%s want %s (derived value already below the SPEC-019 bound)", got, want)
	}
}

// ---- unit: the cancellation-cause contract ---------------------------------

// TestPhaseDeadlineExceededDistinguishesPlainCancellation guards the silent
// regression #760 could have introduced. The upstream context is now
// cancel-WITH-CAUSE, so ctx.Err() reports context.Canceled even when a phase
// budget expired: every call site had to move off
// errors.Is(ctx.Err(), context.DeadlineExceeded). This test fails if
// phaseDeadlineExceeded ever starts confusing the two.
func TestPhaseDeadlineExceededDistinguishesPlainCancellation(t *testing.T) {
	expired := newRequestDeadlines(context.Background())
	defer expired.Stop()
	expired.armPhase(deadlinePhaseFirstToken, time.Millisecond)
	select {
	case <-expired.Context().Done():
	case <-time.After(2 * time.Second):
		t.Fatal("phase timer never fired")
	}
	if !errors.Is(expired.Context().Err(), context.Canceled) {
		t.Fatalf("ctx.Err()=%v; a cause-cancelled context reports context.Canceled — the legacy DeadlineExceeded check is exactly what this test forbids", expired.Context().Err())
	}
	if errors.Is(expired.Context().Err(), context.DeadlineExceeded) {
		t.Fatal("ctx.Err() reported DeadlineExceeded; the legacy check would have masked the migration")
	}
	phase, ok := phaseDeadlineExceeded(expired.Context())
	if !ok || phase != deadlinePhaseFirstToken {
		t.Fatalf("phaseDeadlineExceeded=(%q,%v) want (%q,true)", phase, ok, deadlinePhaseFirstToken)
	}
	if got := expired.expiredPhase(); got != deadlinePhaseFirstToken {
		t.Fatalf("expiredPhase=%q want %q", got, deadlinePhaseFirstToken)
	}

	// A plain cancel (buyer disconnect, gateway-side abort) is NOT a phase
	// deadline and must not be reported as one.
	plain := newRequestDeadlines(context.Background())
	plain.Cancel()
	if phase, ok := phaseDeadlineExceeded(plain.Context()); ok {
		t.Fatalf("plain cancellation reported phase %q", phase)
	}
	if got := plain.expiredPhase(); got != "" {
		t.Fatalf("expiredPhase=%q want empty for a plain cancellation", got)
	}
	plain.Stop()

	// The ceiling is armed at most once: a second arm must not extend it.
	ceiling := newRequestDeadlines(context.Background())
	defer ceiling.Stop()
	ceiling.armCeiling(50 * time.Millisecond)
	ceiling.armCeiling(time.Hour)
	select {
	case <-ceiling.Context().Done():
	case <-time.After(2 * time.Second):
		t.Fatal("ceiling was re-armed and never fired")
	}
	if got := ceiling.expiredPhase(); got != deadlinePhaseStreamCeiling {
		t.Fatalf("expiredPhase=%q want %q", got, deadlinePhaseStreamCeiling)
	}
}

// ---- streaming: each phase ends the request on its own clock ---------------

// endlessContentStream emits a content-bearing delta every `every` until the
// upstream request context is cancelled, i.e. a generation that never stalls.
func endlessContentStream(every time.Duration) func(*io.PipeWriter, context.Context) {
	return endlessFrameStream(every, `data: {"id":"c","choices":[{"delta":{"content":"x"}}]}`+"\n\n")
}

func endlessFrameStream(every time.Duration, frame string) func(*io.PipeWriter, context.Context) {
	return func(pw *io.PipeWriter, ctx context.Context) {
		for {
			if _, err := pw.Write([]byte(frame)); err != nil {
				return
			}
			select {
			case <-ctx.Done():
				_ = pw.CloseWithError(ctx.Err())
				return
			case <-time.After(every):
			}
		}
	}
}

// TestStreamCeilingFiresOnEndlessStream is the safety half of #760: removing
// the flat wall must not make a runaway generation unbounded. A stream that
// keeps emitting real content forever is still cut, by the max_tokens-derived
// ceiling, and settles as provider_timeout — not provider_disconnected.
func TestStreamCeilingFiresOnEndlessStream(t *testing.T) {
	client := seamStreamingUpstreamCtx(endlessContentStream(50 * time.Millisecond))
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		// Ceiling = clamp(1s + 20*1ms, >=1s, <=1s) = 1s. The idle timer and
		// the first-token phase are left long so the ceiling is the only
		// clock that can fire.
		cfg.Timeouts.CoordinatorRequestSeconds = 1
		cfg.Timeouts.StreamCeilingFloorSeconds = 1
		cfg.Timeouts.StreamCeilingPerTokenMS = 1
		cfg.Timeouts.StreamCeilingMaxSeconds = 1
		cfg.Timeouts.StreamingIdleMS = 30000
		cfg.Timeouts.FirstTokenSeconds = 300
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_ceiling")

	start := time.Now()
	resp := postChat(t, h, key, `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)
	elapsed := time.Since(start)

	if elapsed > 5*time.Second {
		t.Fatalf("endless stream ran %s — the ceiling did not bound it", elapsed)
	}
	body := resp.Body.String()
	if !strings.Contains(body, `"code":"provider_timeout"`) || !strings.Contains(body, "data: [DONE]") {
		t.Fatalf("want provider_timeout + [DONE] terminal after %s; body=%.400q", elapsed, body)
	}
	if strings.Contains(body, "provider_disconnected") {
		t.Fatalf("ceiling expiry must not surface as a provider disconnect; body=%.400q", body)
	}
	if outcome, _ := usageEventOutcome(t, dbPath, "acct_ceiling"); outcome != "provider_timeout" {
		t.Fatalf("usage outcome=%q want provider_timeout", outcome)
	}
}

// TestHeartbeatOnlyStreamDiesAtProgressIdle is the highest-value guard in
// #760. Dropping the flat wall is only safe because the idle timer became a
// CONTENT-progress budget: a provider that keeps the socket warm with
// role-only / keepalive frames produces bytes forever but no tokens, and under
// the old "any byte resets the timer" rule nothing would have stopped it once
// the wall was gone.
func TestHeartbeatOnlyStreamDiesAtProgressIdle(t *testing.T) {
	// A role-only delta: real SSE traffic, zero generated content.
	// streamingCompletionDeltaBytes excludes role/id/type/name, so this must
	// NOT count as progress.
	client := seamStreamingUpstreamCtx(endlessFrameStream(40*time.Millisecond,
		`data: {"id":"c","choices":[{"delta":{"role":"assistant"}}]}`+"\n\n"))
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Timeouts.StreamingIdleMS = 400
		// Every other clock is left long: only the content-progress budget
		// can end this stream.
		cfg.Timeouts.CoordinatorRequestSeconds = 300
		cfg.Timeouts.FirstTokenSeconds = 300
		cfg.Timeouts.StreamCeilingFloorSeconds = 300
		cfg.Timeouts.StreamCeilingMaxSeconds = 900
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_heartbeat")

	start := time.Now()
	resp := postChat(t, h, key, `{"model":"llama","stream":true,"max_tokens":500,"messages":[{"role":"user","content":"hi"}]}`, nil)
	elapsed := time.Since(start)

	if elapsed > 5*time.Second {
		t.Fatalf("heartbeat-only stream ran %s — byte traffic is still resetting the idle timer, "+
			"so the decode-progress guard cannot catch a wedged provider", elapsed)
	}
	if !strings.Contains(resp.Body.String(), `"code":"provider_timeout"`) {
		t.Fatalf("want provider_timeout terminal after %s; body=%.400q", elapsed, resp.Body.String())
	}
	if outcome, _ := usageEventOutcome(t, dbPath, "acct_heartbeat"); outcome != "provider_timeout" {
		t.Fatalf("usage outcome=%q want provider_timeout", outcome)
	}
}

// TestUnknownDeltaKeyDoesNotCountAsProgress pins the #760 security-lane fix:
// the delta classifier is an ALLOWLIST of generated-output keys, so a provider
// emitting frames with unknown keys (delta:{"foo":"x"}) cannot reset the
// content-progress timer, disarm the first-token phase, or hold a slot to the
// stream ceiling while shipping nothing a client consumes.
func TestUnknownDeltaKeyDoesNotCountAsProgress(t *testing.T) {
	cases := []struct {
		name    string
		account string
		frame   string
	}{
		{"flat_unknown_key", "acct_unknown_delta",
			`data: {"id":"c","choices":[{"delta":{"foo":"x"}}]}` + "\n\n"},
		// R2 bypass class: allowlisted leaf smuggled under an unknown
		// container must not count either.
		{"allowlisted_leaf_under_unknown_container", "acct_nested_delta",
			`data: {"id":"c","choices":[{"delta":{"foo":{"content":"x"}}}]}` + "\n\n"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			client := seamStreamingUpstreamCtx(endlessFrameStream(40*time.Millisecond, tc.frame))
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
				cfg.Timeouts.StreamingIdleMS = 400
				// Every other clock is left long: only the content-progress
				// budget can end this stream.
				cfg.Timeouts.CoordinatorRequestSeconds = 300
				cfg.Timeouts.FirstTokenSeconds = 300
				cfg.Timeouts.StreamCeilingFloorSeconds = 300
				cfg.Timeouts.StreamCeilingMaxSeconds = 900
			}, WithHTTPClient(client))
			key := createAccountAndKey(t, store, cfg, tc.account)

			start := time.Now()
			resp := postChat(t, h, key, `{"model":"llama","stream":true,"max_tokens":500,"messages":[{"role":"user","content":"hi"}]}`, nil)
			elapsed := time.Since(start)

			if elapsed > 5*time.Second {
				t.Fatalf("non-content delta stream ran %s — the classifier is counting "+
					"non-output paths as generated output, so a provider can fabricate progress", elapsed)
			}
			if !strings.Contains(resp.Body.String(), `"code":"provider_timeout"`) {
				t.Fatalf("want provider_timeout terminal after %s; body=%.400q", elapsed, resp.Body.String())
			}
			if outcome, _ := usageEventOutcome(t, dbPath, tc.account); outcome != "provider_timeout" {
				t.Fatalf("usage outcome=%q want provider_timeout", outcome)
			}
		})
	}
}

// TestStructuredTimeoutDuringRetryBackoff pins the #760 code-lane fix: when
// the admission budget expires during retry backoff, doCoordinatorChatWithRetry
// returns its last retryable 503 with err == nil. A structured-streaming buyer
// must still receive the SPEC-019 provider_timeout SSE terminal — not the raw
// JSON 503 pass-through.
func TestStructuredTimeoutDuringRetryBackoff(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusServiceUnavailable, http.Header{"Content-Type": []string{"application/json"}}, noProviderBody()), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Retry503.Enabled = true
		cfg.Retry503.MaxAttempts = 3
		// Backoff (3s) straddles the 1s admission budget: the phase expires
		// while the retry loop sleeps, exercising the stale-resp return path.
		cfg.Retry503.BackoffBaseMs = 3000
		cfg.Retry503.BackoffMaxMs = 3000
		cfg.Timeouts.CoordinatorAdmissionSeconds = 1
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_structured_backoff")

	start := time.Now()
	resp := postChat(t, h, key, structuredStreamingRequestBody(), nil)
	elapsed := time.Since(start)

	body := resp.Body.String()
	if !strings.Contains(body, `"code":"provider_timeout"`) {
		t.Fatalf("structured buyer got a non-timeout terminal after admission expiry in backoff "+
			"(%s); body=%.400q", elapsed, body)
	}
	if strings.Contains(body, "no_provider_available") || strings.Contains(body, "coordinator_unavailable") {
		t.Fatalf("raw JSON 503 passed through to a structured-streaming buyer; body=%.400q", body)
	}
	if outcome, _ := usageEventOutcome(t, dbPath, "acct_structured_backoff"); outcome != "provider_timeout" {
		t.Fatalf("usage outcome=%q want provider_timeout", outcome)
	}
}

// TestDeltaClassifierAllowlist unit-pins which delta keys count as generated
// output for both billing estimation and (since #760) deadline progress.
func TestDeltaClassifierAllowlist(t *testing.T) {
	cases := []struct {
		name string
		data string
		want int64
	}{
		{"content", `{"choices":[{"delta":{"content":"abcd"}}]}`, 4},
		{"reasoning_content", `{"choices":[{"delta":{"reasoning_content":"abc"}}]}`, 3},
		{"refusal", `{"choices":[{"delta":{"refusal":"no"}}]}`, 2},
		{"tool_call_arguments", `{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"f","arguments":"{\"a\":1}"}}]}}]}`, 7},
		{"function_call_arguments", `{"choices":[{"delta":{"function_call":{"name":"f","arguments":"{\"a\":1}"}}}]}`, 7},
		{"unknown_key", `{"choices":[{"delta":{"foo":"xxxxxxxx"}}]}`, 0},
		{"role_only", `{"choices":[{"delta":{"role":"assistant"}}]}`, 0},
		{"nested_unknown", `{"choices":[{"delta":{"metadata":{"blob":"xxxxxxxx"}}}]}`, 0},
		// R2 bypass class: an allowlisted LEAF under an unknown container must
		// not count — the classifier is path-aware, not key-aware.
		{"allowlisted_leaf_under_unknown_container", `{"choices":[{"delta":{"foo":{"content":"xxxxxxxx"}}}]}`, 0},
		{"arguments_under_unknown_container", `{"choices":[{"delta":{"metadata":{"arguments":"xxxxxxxx"}}}]}`, 0},
		{"content_under_unknown_array", `{"choices":[{"delta":{"foo":[{"text":"xxxxxxxx"}]}}]}`, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, _, ok := streamingCompletionDeltaBytes(tc.data)
			if !ok {
				t.Fatalf("classifier rejected valid frame %q", tc.data)
			}
			if got != tc.want {
				t.Fatalf("deltaBytes=%d want %d for %q", got, tc.want, tc.data)
			}
		})
	}
}

// TestContentProgressKeepsStreamAliveAcrossIdleBudget is the control for the
// test above: the same idle budget, but frames that DO carry content. The
// stream must survive well past the budget, proving the timer measures
// progress rather than elapsed time.
func TestContentProgressKeepsStreamAliveAcrossIdleBudget(t *testing.T) {
	client := seamStreamingUpstreamCtx(func(pw *io.PipeWriter, ctx context.Context) {
		for i := 0; i < 10; i++ {
			if _, err := pw.Write([]byte(`data: {"id":"c","choices":[{"delta":{"content":"x"}}]}` + "\n\n")); err != nil {
				return
			}
			select {
			case <-ctx.Done():
				_ = pw.CloseWithError(ctx.Err())
				return
			case <-time.After(100 * time.Millisecond):
			}
		}
		_, _ = pw.Write([]byte(`data: [DONE]` + "\n\n"))
		_ = pw.Close()
	})
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		// 400ms of idle budget, 1s+ of streaming: only per-frame content
		// progress can carry it to [DONE].
		cfg.Timeouts.StreamingIdleMS = 400
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_progress")

	resp := postChat(t, h, key, `{"model":"llama","stream":true,"max_tokens":500,"messages":[{"role":"user","content":"hi"}]}`, nil)
	body := resp.Body.String()
	if !strings.Contains(body, "data: [DONE]") || strings.Contains(body, "provider_timeout") {
		t.Fatalf("a content-progressing stream was cut by the idle budget; body=%.400q", body)
	}
}

func TestSlowThirtyBContentProgressUsesAdaptiveDecodeIdleBudget(t *testing.T) {
	client := seamStreamingUpstreamCtx(func(pw *io.PipeWriter, ctx context.Context) {
		frames := []string{
			`data: {"id":"c","choices":[{"delta":{"content":"slow"}}]}` + "\n\n",
			`data: {"id":"c","choices":[{"delta":{"content":" token"}}]}` + "\n\n",
			`data: [DONE]` + "\n\n",
		}
		for i, frame := range frames {
			if _, err := pw.Write([]byte(frame)); err != nil {
				return
			}
			if i == len(frames)-1 {
				break
			}
			select {
			case <-ctx.Done():
				_ = pw.CloseWithError(ctx.Err())
				return
			case <-time.After(750 * time.Millisecond):
			}
		}
		_ = pw.Close()
	})
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Timeouts.StreamingIdleMS = 500
		cfg.Timeouts.FirstTokenSeconds = 30
		cfg.Timeouts.CoordinatorRequestSeconds = 30
		cfg.Timeouts.StreamCeilingFloorSeconds = 30
		cfg.Timeouts.StreamCeilingMaxSeconds = 60
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_slow_30b")

	resp := postChat(t, h, key, `{"model":"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit","stream":true,"max_tokens":500,"messages":[{"role":"user","content":"hi"}]}`, nil)
	body := resp.Body.String()
	if !strings.Contains(body, "data: [DONE]") || strings.Contains(body, "provider_timeout") {
		t.Fatalf("slow 30B content-progressing stream was cut by decode idle; body=%.400q", body)
	}
}

// TestFirstTokenDeadlineFiresBeforeCeiling covers the gap between "headers
// committed" and "first token": the coordinator accepted the request and then
// produced nothing. The idle timer and the ceiling are both left long, so only
// the first-token phase can end this request.
func TestFirstTokenDeadlineFiresBeforeCeiling(t *testing.T) {
	client := seamStreamingUpstreamCtx(func(pw *io.PipeWriter, ctx context.Context) {
		<-ctx.Done() // headers committed, then silence
		_ = pw.CloseWithError(ctx.Err())
	})
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Timeouts.FirstTokenSeconds = 1
		cfg.Timeouts.StreamingIdleMS = 30000
		cfg.Timeouts.CoordinatorRequestSeconds = 300
		cfg.Timeouts.StreamCeilingFloorSeconds = 300
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_first_token")

	start := time.Now()
	resp := postChat(t, h, key, `{"model":"llama","stream":true,"max_tokens":500,"messages":[{"role":"user","content":"hi"}]}`, nil)
	elapsed := time.Since(start)

	if elapsed > 5*time.Second {
		t.Fatalf("silent post-header stream ran %s — the first-token phase did not fire", elapsed)
	}
	if !strings.Contains(resp.Body.String(), `"code":"provider_timeout"`) {
		t.Fatalf("want provider_timeout terminal after %s; body=%.400q", elapsed, resp.Body.String())
	}
	if strings.Contains(resp.Body.String(), "provider_disconnected") {
		t.Fatalf("first-token expiry must not surface as a provider disconnect; body=%.400q", resp.Body.String())
	}
	if outcome, _ := usageEventOutcome(t, dbPath, "acct_first_token"); outcome != "provider_timeout" {
		t.Fatalf("usage outcome=%q want provider_timeout", outcome)
	}
}

// TestStructuredStreamingTimeoutUsesCause is the regression tripwire for the
// riskiest edit in #760: the two
// errors.Is(upstreamCtx.Err(), context.DeadlineExceeded) checks that used to
// select the SPEC-019 structured-output timeout envelope. Cause-based
// cancellation makes ctx.Err() report context.Canceled, so a missed migration
// would silently downgrade this buyer-visible terminal to
// provider_disconnected / stream_truncated with no compile error.
func TestStructuredStreamingTimeoutUsesCause(t *testing.T) {
	t.Run("mid_stream", func(t *testing.T) {
		client := seamStreamingUpstreamCtx(func(pw *io.PipeWriter, ctx context.Context) {
			// A committed but content-less frame: headers are up, the
			// first-token phase is still armed.
			_, _ = pw.Write([]byte(`data: {"id":"c","choices":[{"delta":{},"finish_reason":null}]}` + "\n\n"))
			<-ctx.Done()
			_ = pw.CloseWithError(ctx.Err())
		})
		h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
			cfg.Coordinator.BuyerURL = "http://coordinator.test"
			cfg.Timeouts.FirstTokenSeconds = 1
			cfg.Timeouts.StreamingIdleMS = 30000
		}, WithHTTPClient(client))
		key := createAccountAndKey(t, store, cfg, "acct_structured_cause_mid")

		resp := postChat(t, h, key, structuredStreamingRequestBody(), nil)
		body := resp.Body.String()
		if !strings.Contains(body, `"code":"provider_timeout"`) || !strings.Contains(body, `"settlement_ran":true`) {
			t.Fatalf("structured mid-stream timeout lost its SPEC-019 envelope; body=%.400q", body)
		}
		if strings.Contains(body, "provider_disconnected") || strings.Contains(body, "stream_truncated") {
			t.Fatalf("structured mid-stream timeout downgraded to a disconnect envelope; body=%.400q", body)
		}
		if outcome, _ := usageEventOutcome(t, dbPath, "acct_structured_cause_mid"); outcome != "provider_timeout" {
			t.Fatalf("usage outcome=%q want provider_timeout", outcome)
		}
	})

	t.Run("pre_header", func(t *testing.T) {
		client := hangingCoordinatorClient()
		h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
			cfg.Coordinator.BuyerURL = "http://coordinator.test"
			cfg.Timeouts.CoordinatorAdmissionSeconds = 1
		}, WithHTTPClient(client))
		key := createAccountAndKey(t, store, cfg, "acct_structured_cause_pre")

		resp := postChat(t, h, key, structuredStreamingRequestBody(), nil)
		body := resp.Body.String()
		if !strings.Contains(body, `"code":"provider_timeout"`) {
			t.Fatalf("structured pre-header timeout lost its SPEC-019 envelope; body=%.400q", body)
		}
		if strings.Contains(body, "coordinator_unavailable") {
			t.Fatalf("structured pre-header timeout fell through to the generic 503; body=%.400q", body)
		}
		if outcome, _ := usageEventOutcome(t, dbPath, "acct_structured_cause_pre"); outcome != "provider_timeout" {
			t.Fatalf("usage outcome=%q want provider_timeout", outcome)
		}
	})
}
