// Package loadmetrics computes fairness + tail-latency + starvation
// diagnostics for load-lane scenarios (17+). It runs additively on top
// of the standard metrics.Aggregate pipeline: reads the same []buyer.Result
// slice and the scenario config, emits load_summary.json into the
// artifact bundle. No mutation of package metrics; if the shared
// aggregator later grows these fields, this package folds in.
//
// Phase-A discipline: every value here is RECORDED, not asserted. The
// four hard invariants (I1-I4) remain the only pass/fail gate; load
// scenarios promote metrics to soft benchmarks after ≥5 clean runs
// establish stability (see BUILD_SPEC LOAD/FAIRNESS §4).
package loadmetrics

import (
	"math"
	"sort"

	"github.com/augstar/macprovider-network-harness/internal/buyer"
	"github.com/augstar/macprovider-network-harness/internal/scenario"
)

// Summary is the top-level load_summary.json object. Fields are
// deliberately shallow so triage can grep them directly.
type Summary struct {
	// WindowSeconds is the scenario wall-clock: EndUTC - StartUTC of the
	// buyer fleet's firing window. Zero when no requests completed.
	WindowSeconds float64 `json:"window_seconds"`

	// RouteDistribution reports per-provider request counts + share of
	// total-successful, sorted by descending share for readability.
	RouteDistribution []RouteEntry `json:"route_distribution"`

	// Fairness collapses the distribution into three headline numbers.
	// Baseline PR reports all three; phase-B triage picks the one the
	// load lane will invariant-gate on after ≥5 clean runs.
	Fairness FairnessMetrics `json:"fairness"`

	// LatencyByPromptClass buckets total-latency histograms by prompt
	// max_tokens class. Baseline scenario 17 uses two buckets — short
	// (max_tokens<=32) and medium (33..512) — but the bucketing is
	// generic so future scenarios can add long.
	LatencyByPromptClass map[string]LatencyBucket `json:"latency_by_prompt_class"`

	// Starvation captures the minimum successful-request count observed
	// across all providers that the rig knows to be Ready. On non-rig
	// runs (RigProviderIDs empty), the floor is over provider IDs that
	// appear at least once in the route distribution — same "any Ready
	// provider" intent, best-effort classification.
	Starvation StarvationFloor `json:"starvation_floor"`
}

// RouteEntry is one provider's slice of the total-successful request
// count. Providers with zero successes are included when they appear
// in ReadyProviderIDs so operators see the starvation shape without
// scrolling into Starvation.
type RouteEntry struct {
	ProviderID string  `json:"provider_id"`
	Requests   int     `json:"requests"`
	Share      float64 `json:"share"`
}

// FairnessMetrics computes three complementary summaries of the route
// distribution. See docstrings for the tradeoffs — beta providers care
// about MaxMinRatio (least fair provider vs most fair); routing-policy
// authors care about Gini; simple ops care about Stddev.
type FairnessMetrics struct {
	// Gini is the Gini coefficient of the per-provider request counts,
	// computed over ReadyProviderIDs (zero-count providers included).
	// 0 = perfectly equal, 1 = one provider took everything. Undefined
	// (reported as 0) when the ready-provider set is empty.
	Gini float64 `json:"gini"`

	// Stddev is the population standard deviation of per-provider
	// request counts over ReadyProviderIDs. Same scale as request count.
	Stddev float64 `json:"stddev"`

	// MaxMinRatio is max(requests) / max(1, min(requests)) over
	// ReadyProviderIDs. Guards against div-by-zero when a Ready provider
	// received zero successes — the ratio then reflects "worst provider
	// got at most 1" which understates the imbalance but keeps the value
	// finite. Companion Starvation.MinRequestsPerReadyProvider carries
	// the raw min so triage can tell.
	MaxMinRatio float64 `json:"max_min_ratio"`

	// ProviderCount is the number of ready providers folded into all
	// three fairness figures. Useful sanity check when reading the JSON.
	ProviderCount int `json:"provider_count"`
}

// LatencyBucket is per-class total-latency histogram + count. Fields
// mirror metrics.Histogram to keep the artifact readable, but this
// package deliberately does not import metrics — dependency inversion
// keeps the shared aggregator refactor optional.
type LatencyBucket struct {
	Count int     `json:"count"`
	P50   float64 `json:"p50_ms"`
	P95   float64 `json:"p95_ms"`
	P99   float64 `json:"p99_ms"`
	Mean  float64 `json:"mean_ms"`
	Max   float64 `json:"max_ms"`

	// MaxTokensLower/Upper document the class boundaries (inclusive) so
	// a reader knows what "short_16tok" actually covers.
	MaxTokensLower int `json:"max_tokens_lower"`
	MaxTokensUpper int `json:"max_tokens_upper"`
}

// StarvationFloor answers "did every Ready provider serve ≥N successful
// requests over the window?". A provider that was Ready at start and
// dropped mid-run counts as Ready — the harness cannot observe
// mid-run drop for PR 1, so the field is measured against
// ReadyProviderIDs known at rig-start time.
type StarvationFloor struct {
	MinRequestsPerReadyProvider int      `json:"min_requests_per_ready_provider"`
	MinRequestsProviderID       string   `json:"min_requests_provider_id"`
	WindowSeconds               float64  `json:"window_seconds"`
	ReadyProviderCount          int      `json:"ready_provider_count"`
	ProvidersWithZeroSuccess    []string `json:"providers_with_zero_success"`
	// TODO(PR-2+): account for providers that were Ready at start but
	// disconnected mid-run. Localrig gains a lifecycle event log and
	// this field starts consulting it. For PR 1, "Ready" is a
	// static-at-start snapshot from the rig config.
}

// Class defines one prompt-class bucket for LatencyByPromptClass. The
// label goes into the JSON key; MaxTokensLower/Upper form an inclusive
// range on Prompt.MaxTokens. Ordering of the input slice does not
// matter — Compute picks the first matching class per result.
type Class struct {
	Label          string
	MaxTokensLower int
	MaxTokensUpper int
}

// DefaultClasses matches scenario 17's short/medium split. Long-token
// scenarios in future PRs will pass their own classes.
var DefaultClasses = []Class{
	{Label: "short_16tok", MaxTokensLower: 1, MaxTokensUpper: 32},
	{Label: "medium_200tok", MaxTokensLower: 33, MaxTokensUpper: 512},
}

// Compute produces a Summary from the buyer results + scenario config.
// readyProviderIDs is the rig-known Ready set at start-of-fleet; on
// non-rig runs, pass nil and the function falls back to the set of
// provider IDs that appear in the results.
//
// Empty inputs → zero-value Summary; the callers write the JSON either
// way so downstream tools see a stable schema.
func Compute(sc *scenario.Scenario, results []buyer.Result, readyProviderIDs []string, classes []Class) *Summary {
	if len(classes) == 0 {
		classes = DefaultClasses
	}

	sum := &Summary{
		LatencyByPromptClass: map[string]LatencyBucket{},
	}

	// Window: earliest StartUTC to latest EndUTC across all results
	// (successful or not — the window is a scenario property, not a
	// success property).
	if len(results) > 0 {
		startTs := results[0].StartUTC
		endTs := results[0].EndUTC
		for _, r := range results {
			if r.StartUTC.Before(startTs) {
				startTs = r.StartUTC
			}
			if r.EndUTC.After(endTs) {
				endTs = r.EndUTC
			}
		}
		if !endTs.Before(startTs) {
			sum.WindowSeconds = endTs.Sub(startTs).Seconds()
		}
	}

	// Route distribution: only successful requests count. Failed
	// requests carry no reliable provider attribution — a 502 may
	// have never touched a provider at all.
	perProvider := map[string]int{}
	seenInResults := map[string]bool{}
	for _, r := range results {
		if r.RouteProviderID != "" {
			seenInResults[r.RouteProviderID] = true
		}
		if r.Outcome != "ok" {
			continue
		}
		if r.RouteProviderID == "" {
			continue
		}
		perProvider[r.RouteProviderID]++
	}

	// Ready set determination: rig-supplied wins; else fall back to
	// providers seen in results. Non-rig runs miss zero-request
	// providers (they never appeared), which is a known limitation
	// noted in the field's docstring.
	readySet := map[string]struct{}{}
	if len(readyProviderIDs) > 0 {
		for _, id := range readyProviderIDs {
			readySet[id] = struct{}{}
		}
	} else {
		for id := range seenInResults {
			readySet[id] = struct{}{}
		}
	}

	// Emit route entries for the union of (ready set, providers seen
	// in results) so a request that landed on an unexpected provider
	// still shows up. Zero-request Ready providers get share=0.
	displayIDs := map[string]struct{}{}
	for id := range readySet {
		displayIDs[id] = struct{}{}
	}
	for id := range perProvider {
		displayIDs[id] = struct{}{}
	}

	total := 0
	for _, n := range perProvider {
		total += n
	}
	entries := make([]RouteEntry, 0, len(displayIDs))
	for id := range displayIDs {
		n := perProvider[id]
		share := 0.0
		if total > 0 {
			share = float64(n) / float64(total)
		}
		entries = append(entries, RouteEntry{ProviderID: id, Requests: n, Share: share})
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].Requests != entries[j].Requests {
			return entries[i].Requests > entries[j].Requests
		}
		return entries[i].ProviderID < entries[j].ProviderID
	})
	sum.RouteDistribution = entries

	// Fairness: computed over the Ready set only. Empty ready set →
	// zero-value FairnessMetrics; ProviderCount=0 signals "not enough
	// data" to triage without a special-case value.
	readyCounts := make([]int, 0, len(readySet))
	for id := range readySet {
		readyCounts = append(readyCounts, perProvider[id])
	}
	sort.Ints(readyCounts)
	sum.Fairness = FairnessMetrics{
		ProviderCount: len(readyCounts),
		Gini:          gini(readyCounts),
		Stddev:        stddev(readyCounts),
		MaxMinRatio:   maxMinRatio(readyCounts),
	}

	// Latency-by-class: bucket each ok result by its prompt's
	// max_tokens, derived deterministically from the scenario's
	// PromptFor(buyerIdx, reqIdx) so we don't need to store MaxTokens
	// in buyer.Result.
	perClassLatencies := map[string][]float64{}
	classIndex := indexClasses(classes)
	for _, r := range results {
		if r.Outcome != "ok" || r.TotalMillis <= 0 {
			continue
		}
		if sc == nil {
			continue
		}
		p := sc.PromptFor(r.BuyerIndex, r.RequestIndex)
		label, ok := classIndex.match(p.MaxTokens)
		if !ok {
			continue
		}
		perClassLatencies[label] = append(perClassLatencies[label], float64(r.TotalMillis))
	}
	for _, c := range classes {
		xs, ok := perClassLatencies[c.Label]
		if !ok {
			// Emit an empty bucket so schema is stable — future runs
			// diff cleanly against ones that had no short requests.
			sum.LatencyByPromptClass[c.Label] = LatencyBucket{
				MaxTokensLower: c.MaxTokensLower,
				MaxTokensUpper: c.MaxTokensUpper,
			}
			continue
		}
		bucket := histogram(xs)
		bucket.MaxTokensLower = c.MaxTokensLower
		bucket.MaxTokensUpper = c.MaxTokensUpper
		sum.LatencyByPromptClass[c.Label] = bucket
	}

	// Starvation floor. Only meaningful over the Ready set — a
	// provider that isn't in ReadyProviderIDs was never expected to
	// serve. Zero-success Ready providers are captured explicitly.
	starv := StarvationFloor{
		WindowSeconds:      sum.WindowSeconds,
		ReadyProviderCount: len(readySet),
	}
	if len(readySet) > 0 {
		minCount := math.MaxInt
		minID := ""
		zeros := []string{}
		for id := range readySet {
			n := perProvider[id]
			if n < minCount {
				minCount = n
				minID = id
			}
			if n == 0 {
				zeros = append(zeros, id)
			}
		}
		sort.Strings(zeros)
		starv.MinRequestsPerReadyProvider = minCount
		starv.MinRequestsProviderID = minID
		starv.ProvidersWithZeroSuccess = zeros
	}
	sum.Starvation = starv

	return sum
}

// gini computes the standard Gini coefficient on a non-negative int
// slice, sorted ascending. Formula: (Σ (2i - n - 1) x_i) / (n Σ x_i)
// where i is 1-indexed. Zero-total distributions return 0 (no
// inequality to measure).
func gini(sortedAsc []int) float64 {
	n := len(sortedAsc)
	if n == 0 {
		return 0
	}
	sum := 0.0
	for _, x := range sortedAsc {
		sum += float64(x)
	}
	if sum == 0 {
		return 0
	}
	weighted := 0.0
	for i, x := range sortedAsc {
		weighted += float64(2*(i+1)-n-1) * float64(x)
	}
	return weighted / (float64(n) * sum)
}

// stddev computes population stddev over int counts. Zero-length input
// → 0.
func stddev(xs []int) float64 {
	if len(xs) == 0 {
		return 0
	}
	mean := 0.0
	for _, x := range xs {
		mean += float64(x)
	}
	mean /= float64(len(xs))
	sq := 0.0
	for _, x := range xs {
		d := float64(x) - mean
		sq += d * d
	}
	return math.Sqrt(sq / float64(len(xs)))
}

// maxMinRatio returns max / max(1, min). Zero-length or all-zero →
// 0. The max(1, min) floor is documented in FairnessMetrics doc — it
// hides raw-zero starvation, so triage should always read
// Starvation.ProvidersWithZeroSuccess alongside this figure.
func maxMinRatio(xs []int) float64 {
	if len(xs) == 0 {
		return 0
	}
	mn, mx := xs[0], xs[0]
	for _, x := range xs {
		if x < mn {
			mn = x
		}
		if x > mx {
			mx = x
		}
	}
	if mx == 0 {
		return 0
	}
	denom := mn
	if denom < 1 {
		denom = 1
	}
	return float64(mx) / float64(denom)
}

// histogram computes the same p50/p95/p99/mean/max shape as
// metrics.Histogram, over a slice of latencies (ms). Nearest-rank per
// existing convention.
func histogram(xs []float64) LatencyBucket {
	if len(xs) == 0 {
		return LatencyBucket{}
	}
	sorted := append([]float64(nil), xs...)
	sort.Float64s(sorted)
	sum := 0.0
	for _, v := range sorted {
		sum += v
	}
	return LatencyBucket{
		Count: len(sorted),
		P50:   pct(sorted, 0.50),
		P95:   pct(sorted, 0.95),
		P99:   pct(sorted, 0.99),
		Mean:  sum / float64(len(sorted)),
		Max:   sorted[len(sorted)-1],
	}
}

func pct(sortedAsc []float64, q float64) float64 {
	if len(sortedAsc) == 0 {
		return 0
	}
	idx := int(math.Ceil(q*float64(len(sortedAsc)))) - 1
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sortedAsc) {
		idx = len(sortedAsc) - 1
	}
	return sortedAsc[idx]
}

// classIndex accelerates prompt-max_tokens → class-label lookup. Built
// once per Compute call.
type classIndex struct {
	classes []Class
}

func indexClasses(cs []Class) classIndex {
	out := make([]Class, len(cs))
	copy(out, cs)
	return classIndex{classes: out}
}

func (ci classIndex) match(maxTokens int) (string, bool) {
	if maxTokens <= 0 {
		return "", false
	}
	for _, c := range ci.classes {
		if maxTokens >= c.MaxTokensLower && maxTokens <= c.MaxTokensUpper {
			return c.Label, true
		}
	}
	return "", false
}
