package router

import (
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync"
)

const (
	retry503RequestIDClassClientSupplied   = "client_supplied"
	retry503RequestIDClassGatewayGenerated = "gateway_generated"
)

var retry503BackoffBucketsMS = []int64{100, 250, 500, 750, 1000}

type retry503Metrics struct {
	mu             sync.Mutex
	recovered      map[string]int64
	exhausted      int64
	backoffBuckets map[string]int64
	backoffCount   int64
	backoffSumMS   int64
}

type retry503MetricsSnapshot struct {
	recovered      map[string]int64
	exhausted      int64
	backoffBuckets map[string]int64
	backoffCount   int64
	backoffSumMS   int64
}

type requestIDClassKey struct{}

func newRetry503Metrics() *retry503Metrics {
	return &retry503Metrics{
		recovered: map[string]int64{
			retry503RequestIDClassClientSupplied:   0,
			retry503RequestIDClassGatewayGenerated: 0,
		},
		backoffBuckets: newRetry503BackoffBucketMap(),
	}
}

func newRetry503BackoffBucketMap() map[string]int64 {
	buckets := make(map[string]int64, len(retry503BackoffBucketsMS)+1)
	for _, le := range retry503BackoffBucketsMS {
		buckets[strconv.FormatInt(le, 10)] = 0
	}
	buckets["+Inf"] = 0
	return buckets
}

func requestIDClass(r *http.Request) string {
	if v, ok := r.Context().Value(requestIDClassKey{}).(string); ok {
		return normalizeRetry503RequestIDClass(v)
	}
	return retry503RequestIDClassGatewayGenerated
}

func normalizeRetry503RequestIDClass(class string) string {
	switch class {
	case retry503RequestIDClassClientSupplied, retry503RequestIDClassGatewayGenerated:
		return class
	default:
		return retry503RequestIDClassGatewayGenerated
	}
}

func (m *retry503Metrics) recordRecovered(requestIDClass string, totalBackoffMS int64) {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.recovered[normalizeRetry503RequestIDClass(requestIDClass)]++
	m.recordBackoffLocked(totalBackoffMS)
}

func (m *retry503Metrics) recordExhausted(totalBackoffMS int64) {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.exhausted++
	m.recordBackoffLocked(totalBackoffMS)
}

func (m *retry503Metrics) recordBackoffLocked(totalBackoffMS int64) {
	if totalBackoffMS < 0 {
		totalBackoffMS = 0
	}
	m.backoffCount++
	m.backoffSumMS += totalBackoffMS
	for _, le := range retry503BackoffBucketsMS {
		if totalBackoffMS <= le {
			m.backoffBuckets[strconv.FormatInt(le, 10)]++
		}
	}
	m.backoffBuckets["+Inf"]++
}

func (m *retry503Metrics) snapshot() retry503MetricsSnapshot {
	if m == nil {
		m = newRetry503Metrics()
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	recovered := make(map[string]int64, len(m.recovered))
	for class, count := range m.recovered {
		recovered[class] = count
	}
	backoffBuckets := newRetry503BackoffBucketMap()
	for le, count := range m.backoffBuckets {
		backoffBuckets[le] = count
	}
	return retry503MetricsSnapshot{
		recovered:      recovered,
		exhausted:      m.exhausted,
		backoffBuckets: backoffBuckets,
		backoffCount:   m.backoffCount,
		backoffSumMS:   m.backoffSumMS,
	}
}

func (m *retry503Metrics) prometheus() string {
	snapshot := m.snapshot()
	var b strings.Builder
	b.WriteString("# HELP gateway_coord_503_retry_recovered_total Coordinator 503 no-provider retry requests recovered before exhaustion.\n")
	b.WriteString("# TYPE gateway_coord_503_retry_recovered_total counter\n")
	for _, class := range []string{retry503RequestIDClassClientSupplied, retry503RequestIDClassGatewayGenerated} {
		fmt.Fprintf(&b, "gateway_coord_503_retry_recovered_total{request_id_class=%q} %d\n", class, snapshot.recovered[class])
	}
	b.WriteString("# HELP gateway_coord_503_retry_exhausted_total Coordinator 503 no-provider retry requests that exhausted all attempts.\n")
	b.WriteString("# TYPE gateway_coord_503_retry_exhausted_total counter\n")
	fmt.Fprintf(&b, "gateway_coord_503_retry_exhausted_total %d\n", snapshot.exhausted)
	b.WriteString("# HELP gateway_coord_503_retry_backoff_ms Total retry backoff spent before recovered or exhausted terminal outcome.\n")
	b.WriteString("# TYPE gateway_coord_503_retry_backoff_ms histogram\n")
	for _, le := range retry503BackoffBucketsMS {
		label := strconv.FormatInt(le, 10)
		fmt.Fprintf(&b, "gateway_coord_503_retry_backoff_ms_bucket{le=%q} %d\n", label, snapshot.backoffBuckets[label])
	}
	fmt.Fprintf(&b, "gateway_coord_503_retry_backoff_ms_bucket{le=%q} %d\n", "+Inf", snapshot.backoffBuckets["+Inf"])
	fmt.Fprintf(&b, "gateway_coord_503_retry_backoff_ms_sum %d\n", snapshot.backoffSumMS)
	fmt.Fprintf(&b, "gateway_coord_503_retry_backoff_ms_count %d\n", snapshot.backoffCount)
	return b.String()
}
