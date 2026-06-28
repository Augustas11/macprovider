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
	text := collector.prometheusText()
	if !strings.Contains(text, "macprovider_streaming_timing_samples_total 1") {
		t.Fatalf("metrics missing sample count: %s", text)
	}
	if !strings.Contains(text, "macprovider_streaming_forward_lag_p95_ms 1160") {
		t.Fatalf("metrics missing skew-corrected forward p95: %s", text)
	}

	skewed := headers.Clone()
	skewed.Set(streamingTimingGatewayNowHeader, strconvMillis(base.Add(800*time.Millisecond)))
	collector.observeFromHeaders("req-2", "provider-a", streamingModeIncremental, skewed, base.Add(1200*time.Millisecond))
	text = collector.prometheusText()
	if !strings.Contains(text, "macprovider_streaming_timing_samples_total 1") ||
		!strings.Contains(text, "macprovider_streaming_timing_skew_skipped_total 1") {
		t.Fatalf("large-skew sample should be skipped: %s", text)
	}
}

func strconvMillis(t time.Time) string {
	return strconv.FormatInt(t.UnixMilli(), 10)
}
