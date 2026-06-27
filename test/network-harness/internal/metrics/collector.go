// Package metrics aggregates per-request results into a summary fit
// for the artifact bundle. It does not pass/fail anything — that's the
// invariants package's job. Aggregation is intentionally simple so phase
// A triage can read the JSON directly.
package metrics

import (
	"math"
	"sort"

	"github.com/augstar/macprovider-network-harness/internal/buyer"
)

// Summary is the top-level metrics object embedded in the artifact bundle.
type Summary struct {
	TotalRequests int `json:"total_requests"`
	SuccessCount  int `json:"success_count"`
	HTTPErrors    int `json:"http_errors"`
	Timeouts      int `json:"timeouts"`
	TransportErrs int `json:"transport_errors"`
	ClientAborts  int `json:"client_aborts"`
	SilentHangs   int `json:"silent_hangs"`

	SuccessRate float64 `json:"success_rate"`

	TTFTMillis  Histogram `json:"ttft_ms"`
	TotalMillis Histogram `json:"total_ms"`
	TokensPerSec Histogram `json:"tokens_per_sec"`

	// RouteDistribution: provider_id -> request count. Empty when the
	// gateway doesn't expose provider attribution headers (a gap to
	// triage in phase B).
	RouteDistribution map[string]int `json:"route_distribution"`

	// ErrorTaxonomy: error_code -> count.
	ErrorTaxonomy map[string]int `json:"error_taxonomy"`

	// HTTPStatusCounts: status_code -> count.
	HTTPStatusCounts map[int]int `json:"http_status_counts"`
}

// Histogram captures the percentiles humans actually care about plus
// raw mean for sanity. Computed only over successful requests so a
// timeout doesn't dominate the p99.
type Histogram struct {
	Count int     `json:"count"`
	P50   float64 `json:"p50"`
	P95   float64 `json:"p95"`
	P99   float64 `json:"p99"`
	Mean  float64 `json:"mean"`
	Max   float64 `json:"max"`
}

func Aggregate(results []buyer.Result) *Summary {
	s := &Summary{
		TotalRequests:     len(results),
		RouteDistribution: map[string]int{},
		ErrorTaxonomy:     map[string]int{},
		HTTPStatusCounts:  map[int]int{},
	}

	var ttfts, totals, tps []float64
	for _, r := range results {
		switch r.Outcome {
		case "ok":
			s.SuccessCount++
		case "http_error":
			s.HTTPErrors++
		case "timeout":
			s.Timeouts++
		case "transport_error":
			s.TransportErrs++
		case "client_abort":
			s.ClientAborts++
		case "silent_hang":
			s.SilentHangs++
		}
		if r.HTTPStatus > 0 {
			s.HTTPStatusCounts[r.HTTPStatus]++
		}
		if r.ErrorCode != "" {
			s.ErrorTaxonomy[r.ErrorCode]++
		}
		if r.RouteProviderID != "" {
			s.RouteDistribution[r.RouteProviderID]++
		}
		if r.Outcome == "ok" {
			if r.TTFTMillis > 0 {
				ttfts = append(ttfts, float64(r.TTFTMillis))
			}
			if r.TotalMillis > 0 {
				totals = append(totals, float64(r.TotalMillis))
			}
			if r.CompletionTokensReceived > 0 && r.TotalMillis > 0 {
				sec := float64(r.TotalMillis) / 1000.0
				if sec > 0 {
					tps = append(tps, float64(r.CompletionTokensReceived)/sec)
				}
			}
		}
	}

	if s.TotalRequests > 0 {
		s.SuccessRate = float64(s.SuccessCount) / float64(s.TotalRequests)
	}
	s.TTFTMillis = histogram(ttfts)
	s.TotalMillis = histogram(totals)
	s.TokensPerSec = histogram(tps)
	return s
}

func histogram(xs []float64) Histogram {
	h := Histogram{Count: len(xs)}
	if len(xs) == 0 {
		return h
	}
	sorted := append([]float64(nil), xs...)
	sort.Float64s(sorted)
	sum := 0.0
	for _, v := range sorted {
		sum += v
	}
	h.Mean = sum / float64(len(sorted))
	h.P50 = pct(sorted, 0.50)
	h.P95 = pct(sorted, 0.95)
	h.P99 = pct(sorted, 0.99)
	h.Max = sorted[len(sorted)-1]
	return h
}

// pct returns a nearest-rank percentile. Good enough for phase-A
// reporting and avoids a math/stats dependency.
func pct(sorted []float64, q float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	idx := int(math.Ceil(q*float64(len(sorted)))) - 1
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}
