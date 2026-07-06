package buyer

import (
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestStreamingTimingCollectorSkipsLargeSkewAndExportsP95(t *testing.T) {
	collector := newStreamingTimingCollector()
	base := time.UnixMilli(1_800_000_000_000).UTC()
	headers := http.Header{}
	headers.Set(streamingTimingProviderOpenHeader, strconvMillis(base))
	headers.Set(streamingTimingProviderNowHeader, strconvMillis(base.Add(500*time.Millisecond)))
	headers.Set(streamingTimingGatewayNowHeader, strconvMillis(base.Add(540*time.Millisecond)))
	headers.Set(streamingTimingGatewayByteHeader, strconvMillis(base.Add(1300*time.Millisecond)))

	collector.observeFromHeaders("req-1", "provider-a", streamingModeIncremental, headers, base.Add(1200*time.Millisecond))
	text := collector.prometheusText(0)
	if !strings.Contains(text, "macprovider_streaming_timing_samples_total 1") {
		t.Fatalf("metrics missing sample count: %s", text)
	}
	if !strings.Contains(text, "macprovider_streaming_forward_lag_p95_ms 1160") {
		t.Fatalf("metrics missing skew-corrected forward p95: %s", text)
	}

	skewed := headers.Clone()
	skewed.Set(streamingTimingGatewayNowHeader, strconvMillis(base.Add(800*time.Millisecond)))
	collector.observeFromHeaders("req-2", "provider-a", streamingModeIncremental, skewed, base.Add(1200*time.Millisecond))
	text = collector.prometheusText(0)
	if !strings.Contains(text, "macprovider_streaming_timing_samples_total 1") ||
		!strings.Contains(text, "macprovider_streaming_timing_skew_skipped_total 1") {
		t.Fatalf("large-skew sample should be skipped: %s", text)
	}
}

func TestStreamingTimingCollectorBoundsSamples(t *testing.T) {
	collector := newStreamingTimingCollectorWithLimit(3)
	base := time.Unix(1000, 0).UTC()
	headers := http.Header{}
	headers.Set(streamingTimingProviderOpenHeader, strconvMillis(base))
	for i := 0; i < 5; i++ {
		collector.observeFromHeaders(
			"req-"+strconv.Itoa(i),
			"provider-a",
			streamingModeIncremental,
			headers,
			base.Add(time.Duration(i+1)*time.Millisecond),
		)
	}
	records, _ := collector.snapshot()
	if len(records) != 3 {
		t.Fatalf("records len=%d want 3", len(records))
	}
	if records[0].RequestID != "req-2" {
		t.Fatalf("oldest retained request=%q want req-2", records[0].RequestID)
	}
	if got := collector.evictionsCount(); got != 2 {
		t.Fatalf("evictions=%d want 2", got)
	}
	if text := collector.prometheusText(7); !strings.Contains(text, "stats_streaming_metrics_evictions_total 9") {
		t.Fatalf("metrics missing combined eviction count: %s", text)
	}
}

func TestToolCallOpenFromSSELine(t *testing.T) {
	cases := []struct {
		name     string
		line     string
		wantOK   bool
		wantTime int64
	}{
		{"valid", ": macprovider_tool_call_open unix_ms=1751140123456", true, 1751140123456},
		{"valid with trailing whitespace", ": macprovider_tool_call_open unix_ms=1751140123456 ", true, 1751140123456},
		{"old data: JSON form rejected", `data: {"type":"macprovider_tool_call_open","unix_ms":1751140123456}`, false, 0},
		{"missing prefix", "data: ", false, 0},
		{"missing unix_ms", ": macprovider_tool_call_open", false, 0},
		{"non-integer suffix", ": macprovider_tool_call_open unix_ms=abc", false, 0},
		{"empty suffix", ": macprovider_tool_call_open unix_ms=", false, 0},
		{"zero rejected", ": macprovider_tool_call_open unix_ms=0", false, 0},
		{"negative rejected", ": macprovider_tool_call_open unix_ms=-1", false, 0},
		{"unrelated comment", ": some-other-comment", false, 0},
		{"empty line", "", false, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, gotOK := toolCallOpenFromSSELine([]byte(tc.line))
			if gotOK != tc.wantOK {
				t.Fatalf("ok = %v, want %v", gotOK, tc.wantOK)
			}
			if tc.wantOK && got.UnixMilli() != tc.wantTime {
				t.Fatalf("time = %d, want %d", got.UnixMilli(), tc.wantTime)
			}
		})
	}
}

func strconvMillis(t time.Time) string {
	return strconv.FormatInt(t.UnixMilli(), 10)
}
