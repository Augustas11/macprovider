package integration

import (
	"fmt"
	"net/http"
	"regexp"
	"strings"
	"testing"
	"time"
)

var integrationRouteTraceGrammar = regexp.MustCompile(`^v=1; phase=(interactive|long_input|throughput); basis=(measured|explore|fallback|pinned); evidence=(fresh|none); engine=(general_mlx|continuous_batching|native_mtp|unknown); latency=(low|medium|high|unknown)$`)

// TestPhaseAwareRoutingPrefersMeasuredFastProvider is the SPEC-002-R005/R006
// /R007 and SPEC-006-R019/R020 journey through the real gateway and
// coordinator with two fake providers of different speeds. With no evidence
// the coordinator falls back to today's order; once both providers have
// coordinator-measured TTFT, interactive traffic goes to the faster one.
func TestPhaseAwareRoutingPrefersMeasuredFastProvider(t *testing.T) {
	s := newScenario(t, scenarioOpts{
		seedAccount:      true,
		providerCount:    2,
		captureCoordLogs: true,
		coordinatorConfig: func(_ *scenario, cfg map[string]any) {
			// Equal fake providers tie on the objective, so the existing
			// random tiebreak spreads the warm-up traffic over both.
			cfg["routing"].(map[string]any)["tiebreak_randomize"] = true
		},
		providerSetup: func(fp *fakeProvider) {
			// Interactive scoring weighs decode rate as much as TTFT. An
			// equal, always-measurable decode phase keeps that half equal for
			// both providers; otherwise a runner stall gave one provider the
			// only decode sample and outranked the TTFT difference.
			fp.streamDecodeDelay = 50 * time.Millisecond
			fp.streamFirstByteDelay = 20 * time.Millisecond
			if strings.HasSuffix(fp.providerID, "-1") {
				fp.streamFirstByteDelay = 400 * time.Millisecond
			}
		},
	})
	if len(s.fakeProvs) != 2 {
		t.Fatalf("want 2 fake providers, got %d", len(s.fakeProvs))
	}
	fast, slow := s.fakeProvs[0], s.fakeProvs[1]
	if fast.streamFirstByteDelay >= slow.streamFirstByteDelay {
		t.Fatalf("provider order: fast=%s slow=%s", fast.providerID, slow.providerID)
	}
	body := `{"model":"llama-3.2-3b-instruct","stream":true,"max_tokens":32,"messages":[{"role":"user","content":"hi"}]}`
	n := 0
	send := func(extra map[string]string) (int, http.Header, string) {
		n++
		headers := map[string]string{"X-Request-ID": fmt.Sprintf("22222222-2222-4222-8222-%012d", n)}
		for k, v := range extra {
			headers[k] = v
		}
		status, h, respBody := s.chatRequest(headers, body)
		return status, h, string(respBody)
	}

	// No evidence yet: today's selection, disclosed as such.
	status, h, respBody := send(nil)
	if status != http.StatusOK {
		t.Fatalf("first chat status=%d body=%s", status, respBody)
	}
	trace := h.Get("X-MacProvider-Route-Trace")
	if !integrationRouteTraceGrammar.MatchString(trace) || !strings.Contains(trace, "basis=fallback; evidence=none") {
		t.Fatalf("first trace = %q", trace)
	}
	if strings.Contains(trace, fast.providerID) || strings.Contains(trace, slow.providerID) {
		t.Fatalf("trace names a provider: %q", trace)
	}
	if h.Get("X-MacProvider-Privacy-Mode") != "pool" || h.Get("X-MacProvider-Privacy-Mode-Disclosure") == "" {
		t.Fatalf("privacy disclosure: %q / %q", h.Get("X-MacProvider-Privacy-Mode"), h.Get("X-MacProvider-Privacy-Mode-Disclosure"))
	}

	// Warm up until the coordinator has three measured samples of each.
	for i := 0; i < 80 && (fast.Hits() < 3 || slow.Hits() < 3); i++ {
		if status, _, respBody := send(nil); status != http.StatusOK {
			t.Fatalf("warm-up chat status=%d body=%s", status, respBody)
		}
	}
	if fast.Hits() < 3 || slow.Hits() < 3 {
		t.Fatalf("warm-up did not reach both providers: fast=%d slow=%d", fast.Hits(), slow.Hits())
	}

	// Both measured: interactive traffic goes to the low-TTFT provider.
	fastBefore, slowBefore := fast.Hits(), slow.Hits()
	const measured = 10
	for i := 0; i < measured; i++ {
		status, h, respBody := send(nil)
		if status != http.StatusOK {
			t.Fatalf("measured chat status=%d body=%s", status, respBody)
		}
		trace := h.Get("X-MacProvider-Route-Trace")
		if !strings.Contains(trace, "phase=interactive; basis=measured; evidence=fresh") {
			t.Fatalf("measured trace = %q", trace)
		}
	}
	if got := fast.Hits() - fastBefore; got != measured || slow.Hits() != slowBefore {
		t.Fatalf("measured routing: fast got %d of %d, slow got %d", got, measured, slow.Hits()-slowBefore)
	}
	line := s.coordLogBuf.awaitContains(time.Now().Add(3*time.Second), `"event":"route_trace"`, `"basis":"measured"`, `"provider_id":"`+fast.providerID+`"`, `"privacy_mode":"pool"`)
	if line == "" {
		t.Fatalf("no operator route_trace line for the measured choice")
	}

	// SPEC-006-R019: an unsatisfiable privacy mode fails closed before dispatch.
	hitsBefore := fast.Hits() + slow.Hits()
	for mode, code := range map[string]string{
		"owned_provider":       "privacy_mode_unsatisfied",
		"relay_blind_required": "privacy_mode_unsatisfied",
		"local_only":           "invalid_privacy_mode",
	} {
		status, _, respBody := send(map[string]string{"X-MacProvider-Privacy-Mode": mode})
		if status != http.StatusBadRequest || !strings.Contains(respBody, code) {
			t.Fatalf("mode %s: status=%d body=%s", mode, status, respBody)
		}
	}
	if fast.Hits()+slow.Hits() != hitsBefore {
		t.Fatal("a refused privacy mode reached a provider")
	}
}
