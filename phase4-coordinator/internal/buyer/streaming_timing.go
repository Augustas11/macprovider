package buyer

import (
	"fmt"
	"math"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	streamingTimingProviderOpenHeader = "X-MacProvider-Provider-ToolCallOpen-Unix-Ms"
	streamingTimingCoordinatorHeader  = "X-MacProvider-Coordinator-FirstForward-Unix-Ms"
	streamingTimingGatewayByteHeader  = "X-MacProvider-Gateway-FirstByte-Unix-Ms"
	streamingTimingSkewHeader         = "X-MacProvider-NTP-Skew-Ms"
	streamingTimingProviderNowHeader  = "X-MacProvider-Provider-Unix-Ms"
	streamingTimingGatewayNowHeader   = "X-MacProvider-Gateway-Unix-Ms"
	streamingTimingSkewBound          = 100 * time.Millisecond
	defaultStreamingMetricMaxSamples  = 10000
)

// Streaming timing samples are triggered by the provider's
// macprovider_tool_call_open SSE event, emitted when phase3 observes the first
// ModelRuntime.stream .toolCallDelta. The legacy response header remains a
// fallback for older providers.
type streamingTimingCollector struct {
	mu          sync.RWMutex
	records     []streamingTimingRecord
	skippedSkew int
	maxSamples  int
	evictions   int64
}

type streamingTimingRecord struct {
	RequestID               string
	ProviderID              string
	Mode                    string
	ToolCallOpenDetected    time.Time
	FirstForwardedSSEByte   time.Time
	FirstGatewayByte        time.Time
	ProviderGatewaySkew     time.Duration
	SkewCorrectedForwardLag time.Duration
	SkewCorrectedGatewayLag time.Duration
}

func newStreamingTimingCollector() *streamingTimingCollector {
	return newStreamingTimingCollectorWithLimit(defaultStreamingMetricMaxSamples)
}

func newStreamingTimingCollectorWithLimit(maxSamples int) *streamingTimingCollector {
	if maxSamples <= 0 {
		maxSamples = defaultStreamingMetricMaxSamples
	}
	return &streamingTimingCollector{maxSamples: maxSamples}
}

func (c *streamingTimingCollector) observeFromHeaders(requestID, providerID, mode string, headers http.Header, firstForwarded time.Time) {
	c.observeFromHeadersAndProviderOpen(requestID, providerID, mode, headers, firstForwarded, time.Time{})
}

func (c *streamingTimingCollector) observeFromHeadersAndProviderOpen(requestID, providerID, mode string, headers http.Header, firstForwarded, providerOpen time.Time) {
	if c == nil {
		return
	}
	if providerOpen.IsZero() {
		headerOpen, ok := unixMillisHeader(headers, streamingTimingProviderOpenHeader)
		if !ok {
			return
		}
		providerOpen = headerOpen
	}
	gatewayByte, _ := unixMillisHeader(headers, streamingTimingGatewayByteHeader)
	if gatewayByte.IsZero() {
		gatewayByte = firstForwarded
	}
	if coordinatorForward, ok := unixMillisHeader(headers, streamingTimingCoordinatorHeader); ok {
		firstForwarded = coordinatorForward
	}
	providerNow, providerNowOK := unixMillisHeader(headers, streamingTimingProviderNowHeader)
	gatewayNow, gatewayNowOK := unixMillisHeader(headers, streamingTimingGatewayNowHeader)
	skew := time.Duration(0)
	if skewMS, ok := intMillisHeader(headers, streamingTimingSkewHeader); ok {
		skew = time.Duration(skewMS) * time.Millisecond
		if absDuration(skew) > streamingTimingSkewBound {
			c.mu.Lock()
			c.skippedSkew++
			c.mu.Unlock()
			return
		}
	} else if providerNowOK && gatewayNowOK {
		skew = gatewayNow.Sub(providerNow)
		if absDuration(skew) > streamingTimingSkewBound {
			c.mu.Lock()
			c.skippedSkew++
			c.mu.Unlock()
			return
		}
	}
	record := streamingTimingRecord{
		RequestID:               requestID,
		ProviderID:              providerID,
		Mode:                    mode,
		ToolCallOpenDetected:    providerOpen,
		FirstForwardedSSEByte:   firstForwarded,
		FirstGatewayByte:        gatewayByte,
		ProviderGatewaySkew:     skew,
		SkewCorrectedForwardLag: firstForwarded.Sub(providerOpen.Add(skew)),
		SkewCorrectedGatewayLag: gatewayByte.Sub(providerOpen.Add(skew)),
	}
	c.mu.Lock()
	c.records = append(c.records, record)
	if len(c.records) > c.maxSamples {
		drop := len(c.records) - c.maxSamples
		copy(c.records, c.records[drop:])
		c.records = c.records[:c.maxSamples]
		c.evictions += int64(drop)
	}
	c.mu.Unlock()
}

func toolCallOpenFromSSELine(line []byte) (time.Time, bool) {
	const prefix = ": macprovider_tool_call_open unix_ms="
	text := strings.TrimSpace(string(line))
	if !strings.HasPrefix(text, prefix) {
		return time.Time{}, false
	}
	s := strings.TrimSpace(strings.TrimPrefix(text, prefix))
	if v, err := strconv.ParseInt(s, 10, 64); err == nil && v > 0 {
		return time.UnixMilli(v).UTC(), true
	}
	return time.Time{}, false
}

func (c *streamingTimingCollector) snapshot() ([]streamingTimingRecord, int) {
	if c == nil {
		return nil, 0
	}
	c.mu.RLock()
	defer c.mu.RUnlock()
	out := append([]streamingTimingRecord(nil), c.records...)
	return out, c.skippedSkew
}

func (c *streamingTimingCollector) evictionsCount() int64 {
	if c == nil {
		return 0
	}
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.evictions
}

func (c *streamingTimingCollector) prometheusText(extraEvictions int64) string {
	records, skipped := c.snapshot()
	var forward []float64
	var gateway []float64
	for _, record := range records {
		forward = append(forward, float64(record.SkewCorrectedForwardLag.Milliseconds()))
		gateway = append(gateway, float64(record.SkewCorrectedGatewayLag.Milliseconds()))
	}
	var b strings.Builder
	fmt.Fprintf(&b, "macprovider_streaming_timing_samples_total %d\n", len(records))
	fmt.Fprintf(&b, "macprovider_streaming_timing_skew_skipped_total %d\n", skipped)
	fmt.Fprintf(&b, "stats_streaming_metrics_evictions_total %d\n", c.evictionsCount()+extraEvictions)
	fmt.Fprintf(&b, "macprovider_streaming_forward_lag_p95_ms %.0f\n", percentile(forward, 0.95))
	fmt.Fprintf(&b, "macprovider_streaming_gateway_lag_p95_ms %.0f\n", percentile(gateway, 0.95))
	for _, bucket := range []float64{1, 5, 10, 25, 50, 100} {
		count := 0
		for _, record := range records {
			if math.Abs(float64(record.ProviderGatewaySkew.Milliseconds())) <= bucket {
				count++
			}
		}
		fmt.Fprintf(&b, "macprovider_streaming_ntp_skew_ms_bucket{le=\"%.0f\"} %d\n", bucket, count)
	}
	fmt.Fprintf(&b, "macprovider_streaming_ntp_skew_ms_bucket{le=\"+Inf\"} %d\n", len(records))
	fmt.Fprintf(&b, "macprovider_streaming_ntp_skew_ms_count %d\n", len(records))
	return b.String()
}

func unixMillisHeader(headers http.Header, key string) (time.Time, bool) {
	raw := headers.Get(key)
	if raw == "" {
		return time.Time{}, false
	}
	ms, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return time.Time{}, false
	}
	return time.UnixMilli(ms).UTC(), true
}

func intMillisHeader(headers http.Header, key string) (int64, bool) {
	raw := headers.Get(key)
	if raw == "" {
		return 0, false
	}
	ms, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return 0, false
	}
	return ms, true
}

func copyTimingHeader(dst, src http.Header, key string) {
	if value := src.Get(key); value != "" {
		dst.Set(key, value)
	}
}

func percentile(values []float64, p float64) float64 {
	if len(values) == 0 {
		return 0
	}
	sort.Float64s(values)
	idx := int(math.Ceil(p*float64(len(values))) - 1)
	if idx < 0 {
		idx = 0
	}
	if idx >= len(values) {
		idx = len(values) - 1
	}
	return values[idx]
}

func absDuration(value time.Duration) time.Duration {
	if value < 0 {
		return -value
	}
	return value
}
