package router

import (
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestGatewayPhaseTimingAttrsIncludeCoordinatorHeaders(t *testing.T) {
	start := time.Unix(1_700_000_000, 0)
	timing := newGatewayPhaseTiming(start)
	timing.markCoordinatorStart(start.Add(15 * time.Millisecond))
	headers := http.Header{}
	headers.Set(phaseTimingCoordRoutingHeader, "10")
	headers.Set(phaseTimingCoordAdmissionHeader, "25")
	headers.Set(phaseTimingProviderDispatchHeader, "7")
	headers.Set(phaseTimingProviderPrefillHeader, "100")
	headers.Set(phaseTimingProviderDecodeHeader, "42")
	headers.Set(phaseTimingCoordinatorTotalHeader, "190")
	timing.observeCoordinatorResponse(headers, start.Add(150*time.Millisecond))

	attrs := attrsMap(timing.attrs(start.Add(210 * time.Millisecond)))

	assertAttr := func(name string, want int64) {
		t.Helper()
		if got := attrs[name]; got != want {
			t.Fatalf("%s = %v, want %v", name, got, want)
		}
	}
	assertAttr("timing_dns_ms", 0)
	assertAttr("timing_tls_ms", 0)
	assertAttr("timing_gateway_queue_ms", 15)
	assertAttr("timing_coord_admission_ms", 25)
	assertAttr("timing_ws_send_ms", 7)
	assertAttr("timing_provider_prefill_ms", 100)
	assertAttr("timing_provider_decode_ms", 42)
	assertAttr("timing_flush_ms", 60)
	assertAttr("timing_coord_routing_ms", 10)
	assertAttr("timing_coord_total_ms", 190)
}

func TestGatewayPhaseTimingTrailersMergeTerminalFields(t *testing.T) {
	start := time.Unix(1_700_000_000, 0)
	timing := newGatewayPhaseTiming(start)
	timing.markCoordinatorStart(start.Add(15 * time.Millisecond))
	headers := http.Header{}
	headers.Set(phaseTimingCoordRoutingHeader, "10")
	headers.Set(phaseTimingCoordAdmissionHeader, "25")
	headers.Set(phaseTimingProviderDispatchHeader, "7")
	headers.Set(phaseTimingProviderPrefillHeader, "100")
	headers.Set(phaseTimingProviderDecodeHeader, "0")
	headers.Set(phaseTimingCoordinatorTotalHeader, "150")
	timing.observeCoordinatorResponse(headers, start.Add(150*time.Millisecond))

	trailers := http.Header{}
	trailers.Set(phaseTimingProviderDecodeHeader, "250")
	trailers.Set(phaseTimingCoordinatorTotalHeader, "400")
	timing.observeCoordinatorTrailers(trailers)

	attrs := attrsMap(timing.attrs(start.Add(410 * time.Millisecond)))
	if got, want := attrs["timing_coord_admission_ms"], int64(25); got != want {
		t.Fatalf("coord admission after trailer merge = %v, want %v", got, want)
	}
	if got, want := attrs["timing_provider_decode_ms"], int64(250); got != want {
		t.Fatalf("provider decode after trailer merge = %v, want %v", got, want)
	}
	if got, want := attrs["timing_coord_total_ms"], int64(400); got != want {
		t.Fatalf("coord total after trailer merge = %v, want %v", got, want)
	}
}

func TestGatewayStreamingCompletionLogConsumesTimingTrailers(t *testing.T) {
	logs := captureRetryLogs(t)
	headers := http.Header{}
	headers.Set("Content-Type", "text/event-stream; charset=utf-8")
	headers.Set(phaseTimingCoordAdmissionHeader, "9")
	headers.Set(phaseTimingProviderDispatchHeader, "11")
	headers.Set(phaseTimingProviderPrefillHeader, "13")
	headers.Set(phaseTimingProviderDecodeHeader, "0")
	headers.Set(phaseTimingCoordinatorTotalHeader, "40")
	trailers := http.Header{}
	trailers.Set(phaseTimingProviderDecodeHeader, "250")
	trailers.Set(phaseTimingCoordinatorTotalHeader, "400")
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     headers.Clone(),
			Body: io.NopCloser(strings.NewReader(
				"data: {\"id\":\"chatcmpl\",\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":4,\"total_tokens\":7},\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n" +
					"data: [DONE]\n\n",
			)),
			Trailer: trailers.Clone(),
		}, nil
	})}
	h, store, _, cfg := newRetryHarness(t, client, nil)
	fullKey := createAccountAndKey(t, store, cfg, "acct_phase_timing_stream")

	resp := postChat(t, h, fullKey, chatBody(true), nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	logText := logs.String()
	if !strings.Contains(logText, `msg="chat completion"`) {
		t.Fatalf("completion log missing:\n%s", logText)
	}
	for _, want := range []string{
		"timing_coord_admission_ms=9",
		"timing_ws_send_ms=11",
		"timing_provider_prefill_ms=13",
		"timing_provider_decode_ms=250",
		"timing_coord_total_ms=400",
	} {
		if !strings.Contains(logText, want) {
			t.Fatalf("completion log missing %q:\n%s", want, logText)
		}
	}
}

func TestGatewayPhaseTimingIgnoresMissingInvalidAndNegativeHeaders(t *testing.T) {
	start := time.Unix(1_700_000_000, 0)
	timing := newGatewayPhaseTiming(start)
	headers := http.Header{}
	headers.Set(phaseTimingCoordAdmissionHeader, "25")
	headers.Set(phaseTimingProviderDecodeHeader, "42")
	timing.observeCoordinatorResponse(headers, start.Add(100*time.Millisecond))

	updates := http.Header{}
	updates.Set(phaseTimingCoordAdmissionHeader, "invalid")
	updates.Set(phaseTimingProviderDecodeHeader, "-1")
	updates.Set(phaseTimingCoordinatorTotalHeader, "400")
	timing.observeCoordinatorTrailers(updates)

	attrs := attrsMap(timing.attrs(start.Add(410 * time.Millisecond)))
	if got, want := attrs["timing_coord_admission_ms"], int64(0); got != want {
		t.Fatalf("invalid coord admission = %v, want %v", got, want)
	}
	if got, want := attrs["timing_provider_prefill_ms"], int64(0); got != want {
		t.Fatalf("missing provider prefill = %v, want %v", got, want)
	}
	if got, want := attrs["timing_provider_decode_ms"], int64(0); got != want {
		t.Fatalf("negative provider decode = %v, want %v", got, want)
	}
	if got, want := attrs["timing_coord_total_ms"], int64(400); got != want {
		t.Fatalf("valid coord total = %v, want %v", got, want)
	}
}

func attrsMap(attrs []any) map[string]int64 {
	out := make(map[string]int64, len(attrs)/2)
	for i := 0; i+1 < len(attrs); i += 2 {
		key, ok := attrs[i].(string)
		if !ok {
			continue
		}
		value, ok := attrs[i+1].(int64)
		if !ok {
			continue
		}
		out[key] = value
	}
	return out
}
