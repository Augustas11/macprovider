// Package benchmark implements the phase-B network performance suite
// defined in docs/notes/SPEC-NETWORK-BENCHMARK-v0.1.md.
//
// Where phase-A invariants (I1-I4) are pass/fail correctness gates
// ("the network does not lie"), the benchmark invariants (B1-Bn) are
// quantitative performance verdicts:
//
//	B1  TTFT p50 within target
//	B2  Streaming TPS p50 within target
//	B3  Tail ratio (p99/p50) bounded
//	B4  Error rate per 1000 requests bounded
//	B5  Provider slot utilization reasonable
//	B6  Earnings/hr viable at current tier-2 pricing
//	B7  Cold/warm TTFT ratio bounded (scenario 08)
//	B8  Sticky KV-cache reuse retention (scenario 16)
//	B9  Cached-turn latency advantage (scenario 16, record-only)
//	B10 Sustained streaming-TPS retention over a long soak (scenario 15)
//
// Each verdict carries a Status (PASS / WARN / FAIL / SKIP), the
// measured value, the target and bare-min thresholds, and a one-line
// detail string for the artifact bundle. B5 + B6 SKIP when the
// underlying data source is unavailable (no DB snapshot, no pricing
// manifest) — they never falsely PASS.
package benchmark

import (
	"fmt"
	"math"
	"sort"
	"time"

	"github.com/augstar/macprovider-network-harness/internal/buyer"
	"github.com/augstar/macprovider-network-harness/internal/metrics"
	"github.com/augstar/macprovider-network-harness/internal/reconcile"
	"github.com/augstar/macprovider-network-harness/internal/scenario"
)

// Status is the verdict for one B-invariant.
type Status string

const (
	StatusPass Status = "PASS"
	StatusWarn Status = "WARN"
	StatusFail Status = "FAIL"
	StatusSkip Status = "SKIP"
)

// Verdict is one B-invariant's outcome.
type Verdict struct {
	ID      string  `json:"id"`
	Title   string  `json:"title"`
	Status  Status  `json:"status"`
	Value   float64 `json:"value"`
	Target  float64 `json:"target,omitempty"`
	BareMin float64 `json:"bare_min,omitempty"`
	Unit    string  `json:"unit"`
	Detail  string  `json:"detail"`
}

// Histogram is the subset of percentiles benchmark verdicts assert on.
// Distinct from metrics.Histogram because benchmark sources its own
// derivations (e.g. streaming-only TPS rather than wall-time TPS).
type Histogram struct {
	Count int     `json:"count"`
	P50   float64 `json:"p50"`
	P95   float64 `json:"p95"`
	P99   float64 `json:"p99"`
	Mean  float64 `json:"mean"`
	Max   float64 `json:"max"`
}

// BuyerMetrics is the buyer-side cross-section per spec §5.
type BuyerMetrics struct {
	TTFTMs          Histogram      `json:"ttft_ms"`
	StreamingTPS    Histogram      `json:"streaming_tps"`
	WallTimeMs      Histogram      `json:"wall_time_ms"`
	TailRatioP99P50 float64        `json:"tail_ratio_p99_p50"`
	ErrorRatePer1k  float64        `json:"error_rate_per_1k"`
	TotalRequests   int            `json:"total_requests"`
	SuccessCount    int            `json:"success_count"`
	Non2xxBreakdown map[string]int `json:"non_2xx_breakdown"`

	// ColdWarm — populated only when results carry phase tags
	// (cold_warm_pairs pattern). Captures the side-by-side TTFT
	// distributions used by B7. Both Count fields are 0 when phase
	// data is absent.
	ColdWarm ColdWarmMetrics `json:"cold_warm,omitempty"`

	// CacheReuse — populated only when results carry cache-phase tags
	// (sticky_cache pattern). Captures the KV-cache reuse ratios and the
	// cached-vs-uncached latency distributions used by B8 + B9. CachedTurns
	// is 0 when cache-phase data is absent.
	CacheReuse CacheReuseMetrics `json:"cache_reuse,omitempty"`

	// SustainedTPS — the windowed streaming-TPS retention cross-section
	// used by B10. Always computed; the window sample counts are 0 on
	// runs too short/sparse to fill either window, in which case B10 SKIPs.
	SustainedTPS SustainedTPSMetrics `json:"sustained_tps"`
}

// CacheReuseMetrics is the sticky KV-cache reuse cross-section
// (RESEARCH_236 / #376). Reuse* summarize cached_prompt_tokens /
// prompt_tokens across the warm ("cached"-phase) sticky turns that
// carried a usage frame with the cached field present; drives B8. The
// latency histograms split cold ("uncached", first-touch) vs warm
// ("cached") turns; B9 scores the ratio over the reuse-bearing cohort.
type CacheReuseMetrics struct {
	// CachedTurns is the number of successful warm-phase turns seen
	// (whether or not usage was reported). UsageAbsentTurns is the subset
	// whose response omitted the usage/cached field (spec-strict gateway
	// or dropped frame) — those cannot contribute a reuse ratio, and when
	// they are ALL of the cached turns, B8 SKIPs rather than FAILs.
	// AttemptedCachedTurns / AttemptedUncachedTurns count cache-phase turns
	// regardless of outcome, so B8 can distinguish "scenario did not use
	// the sticky_cache pattern" (attempted == 0) from "every request
	// failed" (attempted > 0 but no successful measurement). CachedTurns
	// is the successful subset.
	AttemptedCachedTurns   int `json:"attempted_cached_turns"`
	AttemptedUncachedTurns int `json:"attempted_uncached_turns"`
	CachedTurns            int `json:"cached_turns"`
	UsageAbsentTurns       int `json:"usage_absent_turns"`
	// InvalidTurns counts warm turns whose reported cached_prompt_tokens
	// was semantically impossible (< 0 or > prompt_tokens) — an untrusted
	// provider must not be able to score B8 with a > 1.0 ratio. Invalid
	// samples are excluded from the reuse median and surfaced here.
	InvalidTurns int     `json:"invalid_turns"`
	ReuseCount   int     `json:"reuse_count"`
	ReuseP50     float64 `json:"reuse_p50"`
	ReuseMean    float64 `json:"reuse_mean"`
	ReuseMin     float64 `json:"reuse_min"`

	// Latency histograms feed B9. NOTE: sticky_cache turns are
	// non-streaming (stream:false is required so the terminal usage frame
	// is reliably present), so these are full-response wall times
	// (TotalMillis), NOT time-to-first-token. With a tiny max_tokens the
	// completion is negligible and the wall time is dominated by prefill —
	// which is exactly what prefix-cache reuse accelerates — so the
	// cached-vs-uncached wall-time gap is a valid latency-advantage proxy.
	//
	// UncachedLatencyMs / CachedLatencyMs cover ALL successful turns of
	// each phase (observability). CachedReuseLatencyMs is the subset of
	// warm turns that DEMONSTRABLY reused the cache (a valid, positive
	// cached_prompt_tokens) — B9 scores against THIS population so a fast
	// usage-absent or zero-reuse turn cannot manufacture a latency
	// advantage that the genuinely-reused turns did not earn.
	UncachedLatencyMs    Histogram `json:"uncached_latency_ms"`
	CachedLatencyMs      Histogram `json:"cached_latency_ms"`
	CachedReuseLatencyMs Histogram `json:"cached_reuse_latency_ms"`
	LatencyRatioP50      float64   `json:"latency_ratio_p50"`
}

// SustainedTPSMetrics is the sustained-load retention cross-section for
// B10. It windows the per-request *streaming* decode-TPS distribution
// (post-TTFT tokens / decode duration — the same basis as B2, NOT the
// structurally-unreliable non-streaming sustained_tps field) by wall-clock
// start into a first window [runStart, runStart+W) and a final window
// (runEnd-W, runEnd], where runStart/runEnd are the TRUE run bounds (over
// ALL results, including failures) and W = SustainedTPSWindowSeconds, then
// reports retention = final_p50 / first_p50. Anchoring to the real run end
// (not the last successful sample) is what makes a near-end provider
// disconnect SKIP rather than falsely PASS. Runs whose span is < 2W (windows
// would overlap) yield zero-count windows → B10 SKIPs.
type SustainedTPSMetrics struct {
	FirstWindowTPSP50  float64 `json:"first_window_tps_p50"`
	FinalWindowTPSP50  float64 `json:"final_window_tps_p50"`
	Retention          float64 `json:"retention"`
	FirstWindowSamples int     `json:"first_window_samples"`
	FinalWindowSamples int     `json:"final_window_samples"`
}

// ColdWarmMetrics is the cold-vs-warm TTFT cross-section. Cold = first
// request after each idle gap; warm = the immediately-following request.
type ColdWarmMetrics struct {
	ColdTTFTMs Histogram `json:"cold_ttft_ms"`
	WarmTTFTMs Histogram `json:"warm_ttft_ms"`
	RatioP50   float64   `json:"ratio_p50"`
}

// PerProvider is the provider-side cross-section per spec §5.
type PerProvider struct {
	ProviderID       string  `json:"provider_id"`
	RequestsAdmitted int     `json:"requests_admitted"`
	TokensDelivered  int64   `json:"tokens_delivered"`
	BusySeconds      float64 `json:"busy_seconds"`
	SlotUtilPct      float64 `json:"slot_util_pct"`
	EarningsUSDPerHr float64 `json:"earnings_usd_per_hr"`
	SessionDurationS float64 `json:"session_duration_s"`
}

// ProviderAggregate is the cross-fleet rollup.
type ProviderAggregate struct {
	SlotUtilPct      float64 `json:"slot_util_pct"`
	EarningsUSDPerHr float64 `json:"earnings_usd_per_hr"`
	TokensDelivered  int64   `json:"tokens_delivered"`
	ProvidersSeen    int     `json:"providers_seen"`
}

// ProviderMetrics is the per-provider + aggregate rollup.
type ProviderMetrics struct {
	PerProvider []PerProvider     `json:"per_provider"`
	Aggregate   ProviderAggregate `json:"aggregate"`

	// AttributionMissing is true when the gateway did not echo a
	// provider-id header on any successful request, so per-provider
	// breakdown could not be computed. B5/B6 SKIP in that state.
	AttributionMissing bool `json:"attribution_missing"`
}

// Summary is the top-level artifact emitted as benchmark_summary.json.
type Summary struct {
	Scenario        string          `json:"scenario"`
	ScenarioVersion string          `json:"scenario_version"`
	RunID           string          `json:"run_id"`
	DurationSeconds float64         `json:"duration_seconds"`
	BuyerMetrics    BuyerMetrics    `json:"buyer_metrics"`
	ProviderMetrics ProviderMetrics `json:"provider_metrics"`
	PricingSource   string          `json:"pricing_source,omitempty"`
}

// Result bundles the summary with its per-invariant verdicts.
// Emitted as benchmark_verdict.json (verdicts) + benchmark_summary.json
// (summary).
type Result struct {
	Summary  *Summary  `json:"summary"`
	Verdicts []Verdict `json:"verdicts"`
}

// AnyFailed reports whether any non-skipped verdict is FAIL.
func (r *Result) AnyFailed() bool {
	for _, v := range r.Verdicts {
		if v.Status == StatusFail {
			return true
		}
	}
	return false
}

// Thresholds for v0.1 (from spec §3.3). Keeping them as exported
// constants makes future tuning visible and testable.
const (
	TTFTp50TargetMs  = 800.0
	TTFTp50BareMinMs = 2000.0

	StreamingTPSp50Target  = 30.0
	StreamingTPSp50BareMin = 15.0

	TailRatioTarget  = 3.0
	TailRatioBareMin = 5.0

	ErrorRateTargetPer1k  = 5.0
	ErrorRateBareMinPer1k = 25.0

	SlotUtilTargetPct  = 40.0
	SlotUtilBareMinPct = 15.0

	EarningsTargetUSDPerHr  = 1.00
	EarningsBareMinUSDPerHr = 0.30

	// B7 (cold/warm TTFT ratio) thresholds for scenario 08. Cold = first
	// request after an idle gap; warm = immediately-following request.
	// A ratio of 2× means cold TTFT is twice the warm TTFT; "good"
	// networks keep this small because the cold-start penalty visibly
	// hurts buyer-perceived p50 on bursty workloads.
	ColdWarmRatioTarget  = 2.0
	ColdWarmRatioBareMin = 5.0

	// B8 (sticky cache-reuse retention) thresholds for scenario 16.
	// reuse = cached_prompt_tokens / prompt_tokens on the warm
	// ("cached"-phase) sticky turns; the verdict is the median. The floor
	// guards the ~64% turn-2 reuse win measured live on 2026-07-09 with a
	// ~3.9k-token prefix (#376). CacheReuseTarget is deliberately
	// conservative vs that 0.64 so normal jitter doesn't flap the gate;
	// CALIBRATED from the 2026-07-22 scenario-16 prod baseline: the harness
	// measured a median reuse of 0.725 over 7 warm turns on the live pool
	// (corroborating #376's 2026-07-09 ~0.64, range 0.638-0.70).
	//   - PASS  >= CacheReuseTarget (0.60): healthy, within ~17% of the
	//     0.725 baseline.
	//   - WARN  in [0.50, 0.60): reuse degrading — early warning.
	//   - FAIL  <  CacheReuseBareMin (0.50): the calibrated floor is
	//     breached (a ~31%+ drop from baseline) — a provider prefix-cache
	//     regression that must fail LOUD.
	// The 0.50 floor sits below both the median and the #376 low end, so
	// deterministic prefix-cache jitter won't flap it, while a genuine
	// collapse drops through it. Higher is better. A scheduled consumer
	// must treat WARN (and SKIP) as non-green, not just FAIL.
	CacheReuseTarget  = 0.60
	CacheReuseBareMin = 0.50

	// B9 (cached-turn latency advantage, scenario 16) is record-only: it emits
	// the cached-vs-uncached p50 latency ratio for trend visibility and always
	// SKIPs, so it carries no PASS/WARN/FAIL threshold constants.

	// CacheReuseMinSamples is the minimum number of measured warm turns
	// required before B8/B9 emit a PASS/WARN/FAIL verdict. Below this the
	// median is too noisy to trust, so the invariant reports SKIP
	// (inconclusive) rather than risk a false verdict off one or two
	// samples.
	CacheReuseMinSamples = 3

	// B10 (sustained streaming-TPS retention) thresholds for scenario 15
	// (thermal soak). retention = final-window TPS p50 / first-window TPS
	// p50 over a 45–60 min constant-decode soak. A provider that thermally
	// throttles under sustained load sheds decode throughput; retention
	// captures how much it keeps. These bands are PROVISIONAL — they were
	// chosen before any real soak run and MUST be recalibrated from the
	// first lab-Mac campaign (issue #584) before B10 is armed as a gate.
	// Until then scenario 15 leaves sustained_gate_armed=false, which
	// downgrades a would-be FAIL to WARN (see evalB10).
	SustainedTPSRetentionTarget  = 0.85 // PASS ≥ 0.85
	SustainedTPSRetentionBareMin = 0.70 // WARN ≥ 0.70, FAIL < 0.70

	// SustainedTPSWindowSeconds is the width of the first/final comparison
	// windows (5 min each).
	SustainedTPSWindowSeconds = 300.0

	// SustainedTPSMinWindowSamples is the per-window sample floor below
	// which B10 SKIPs rather than emit a low-confidence retention verdict.
	SustainedTPSMinWindowSamples = 8
)

// cacheReuseCovered reports whether the warm-turn reuse sample is both
// large enough (>= CacheReuseMinSamples) AND complete enough that a strict
// MAJORITY of the INTENDED warm turns actually produced a valid
// measurement. `expectedWarm` is the count the scenario meant to fire
// (derived from the scenario, not from how many results came back), so a
// duration-truncated or survivorship-biased run — where fewer turns were
// dispatched, or most failed/were usage-absent/invalid — is treated as
// incomplete and SKIPs rather than scoring off the surviving few. When
// expectedWarm is unknown (0), fall back to the attempted count.
func cacheReuseCovered(cr CacheReuseMetrics, expectedWarm int) bool {
	if cr.ReuseCount < CacheReuseMinSamples {
		return false
	}
	base := expectedWarm
	if base <= 0 {
		base = cr.AttemptedCachedTurns
	}
	minCovered := base/2 + 1 // strict majority (exactly half does NOT pass)
	if minCovered < CacheReuseMinSamples {
		minCovered = CacheReuseMinSamples
	}
	return cr.ReuseCount >= minCovered
}

// cacheReuseConclusivePositive reports whether the run demonstrates real,
// well-sampled prefix-cache reuse: majority coverage of the intended warm
// turns AND a median at or above the degraded-band floor. B9 (latency)
// requires this so a collapsed-reuse run (median ~0, even with many valid
// 0 samples) cannot PASS on keep-alive/connection-setup latency effects
// alone.
func cacheReuseConclusivePositive(cr CacheReuseMetrics, expectedWarm int) bool {
	return cacheReuseCovered(cr, expectedWarm) && cr.ReuseP50 >= CacheReuseBareMin
}

// Evaluate computes the benchmark summary and per-invariant verdicts.
// pricing is nil when no pricing manifest was loaded; verdicts that
// depend on it (B6) will SKIP.
//
// windowSeconds is the actual wall-clock duration of the run (meta
// EndUTC - StartUTC), used for rate-type derivations. Passing 0
// degrades B5 + B6 to SKIP.
func Evaluate(
	sc *scenario.Scenario,
	results []buyer.Result,
	mSummary *metrics.Summary,
	ledger *reconcile.Result,
	pricing *Pricing,
	runID string,
	windowSeconds float64,
) *Result {
	requested := sc.Benchmark.Invariants
	if len(requested) == 0 {
		return &Result{Summary: nil, Verdicts: nil}
	}

	buyerMetrics := computeBuyerMetrics(results)
	providerMetrics := computeProviderMetrics(results, sc.Benchmark.ProviderSlots, windowSeconds, pricing)

	summary := &Summary{
		Scenario:        sc.Name,
		ScenarioVersion: "v0.1",
		RunID:           runID,
		DurationSeconds: windowSeconds,
		BuyerMetrics:    buyerMetrics,
		ProviderMetrics: providerMetrics,
	}
	if pricing != nil {
		summary.PricingSource = pricing.Source
	}

	verdicts := make([]Verdict, 0, len(requested))
	for _, id := range requested {
		switch id {
		case "B1":
			verdicts = append(verdicts, evalB1(buyerMetrics))
		case "B2":
			verdicts = append(verdicts, evalB2(buyerMetrics, results))
		case "B3":
			verdicts = append(verdicts, evalB3(buyerMetrics))
		case "B4":
			verdicts = append(verdicts, evalB4(buyerMetrics))
		case "B5":
			verdicts = append(verdicts, evalB5(providerMetrics, windowSeconds))
		case "B6":
			verdicts = append(verdicts, evalB6(providerMetrics, pricing, windowSeconds))
		case "B7":
			verdicts = append(verdicts, evalB7(buyerMetrics))
		case "B8":
			verdicts = append(verdicts, evalB8(buyerMetrics, expectedWarmCacheTurns(sc), sc.Benchmark.CacheGateArmed))
		case "B9":
			verdicts = append(verdicts, evalB9(buyerMetrics, expectedWarmCacheTurns(sc)))
		case "B10":
			verdicts = append(verdicts, evalB10(buyerMetrics, sc.Benchmark.SustainedGateArmed))
		default:
			verdicts = append(verdicts, Verdict{
				ID:     id,
				Title:  "unknown",
				Status: StatusSkip,
				Detail: fmt.Sprintf("unknown invariant id %q", id),
			})
		}
	}
	_ = ledger // reserved for future B-invariants that need DB-side data
	return &Result{Summary: summary, Verdicts: verdicts}
}

// expectedWarmCacheTurns is the number of warm ("cached") turns the
// scenario INTENDED to fire, used by B8/B9 to gate coverage against the
// plan rather than against however many results came back — so a
// duration-truncated run (fewer turns dispatched) is caught as
// incomplete. For the sticky_cache pattern each buyer fires
// request_index 0 as the uncached primer and the rest as warm turns.
// Returns 0 for other patterns (coverage falls back to attempted count).
func expectedWarmCacheTurns(sc *scenario.Scenario) int {
	if sc.Buyers.Pattern != "sticky_cache" {
		return 0
	}
	warmPerBuyer := sc.Buyers.RequestsPerBuyer - 1
	if warmPerBuyer < 0 {
		warmPerBuyer = 0
	}
	return sc.Buyers.Count * warmPerBuyer
}

// --- buyer-side compute -----------------------------------------------------

// tpsSample is one streaming-TPS observation tagged with the request's
// wall-clock start, used to window the decode-TPS distribution for B10.
type tpsSample struct {
	start time.Time
	tps   float64
}

func computeBuyerMetrics(results []buyer.Result) BuyerMetrics {
	var ttfts, walls, tps []float64
	var coldTTFTs, warmTTFTs []float64
	var cacheReuse, uncachedLatencies, cachedLatencies, cachedReuseLatencies []float64
	cachedTurns, cacheUsageAbsent, cacheInvalid := 0, 0, 0
	attemptedCached, attemptedUncached := 0, 0
	var tpsSamples []tpsSample
	non2xx := map[string]int{}
	success := 0
	non2xxCount := 0
	// Run temporal bounds are tracked over ALL results (including failed /
	// disconnected ones — their StartUTC/EndUTC are still recorded at
	// dispatch). B10 anchors its first/final windows to this true run span,
	// NOT to the last successful streaming sample. That way a provider that
	// disconnects near the end of a soak (the #584 signature) leaves an empty
	// final window → B10 SKIPs, instead of the window sliding back onto early
	// healthy samples and falsely reporting ~1.0 retention.
	var runStart, runEnd time.Time
	for _, r := range results {
		// Count cache-phase attempts across ALL outcomes (before the
		// non-2xx skip) so B8 can tell "pattern not used" (0 attempts)
		// from "every request failed" (attempts but no measurement).
		switch r.CachePhase {
		case "cached":
			attemptedCached++
		case "uncached":
			attemptedUncached++
		}
		if !r.StartUTC.IsZero() {
			if runStart.IsZero() || r.StartUTC.Before(runStart) {
				runStart = r.StartUTC
			}
			if r.StartUTC.After(runEnd) {
				runEnd = r.StartUTC
			}
		}
		if !r.EndUTC.IsZero() && r.EndUTC.After(runEnd) {
			runEnd = r.EndUTC
		}
		if r.HTTPStatus >= 400 || r.Outcome != "ok" {
			non2xxCount++
			key := fmt.Sprintf("%d", r.HTTPStatus)
			if r.HTTPStatus == 0 {
				key = r.Outcome
				if key == "" {
					key = "unknown"
				}
			}
			non2xx[key]++
			continue
		}
		success++
		if r.TTFTMillis > 0 {
			ttfts = append(ttfts, float64(r.TTFTMillis))
			switch r.Phase {
			case "cold":
				coldTTFTs = append(coldTTFTs, float64(r.TTFTMillis))
			case "warm":
				warmTTFTs = append(warmTTFTs, float64(r.TTFTMillis))
			}
		}
		if r.TotalMillis > 0 {
			walls = append(walls, float64(r.TotalMillis))
		}
		// Sticky KV-cache reuse (B8/B9), sourced from the sticky_cache
		// pattern's cache-phase tags. The reuse ratio only counts warm
		// ("cached") turns that reported the cached field AND whose value
		// is semantically valid (0 <= cached <= prompt); a warm turn with
		// no usage frame is tallied as usage-absent, and an impossible
		// value (cached > prompt or negative — an untrusted provider
		// cannot be allowed to score a > 1.0 ratio) is tallied as invalid.
		// Both are excluded from the median so B8 SKIPs rather than
		// falsely PASSing. The latency split (full-response TotalMillis —
		// these turns are non-streaming) feeds B9.
		switch r.CachePhase {
		case "cached":
			cachedTurns++
			switch {
			case !(r.UsagePresent && r.CachedPromptTokensPresent && r.PromptTokensReported > 0):
				cacheUsageAbsent++
			case r.CachedPromptTokens < 0 || r.CachedPromptTokens > r.PromptTokensReported:
				cacheInvalid++
			default:
				cacheReuse = append(cacheReuse, float64(r.CachedPromptTokens)/float64(r.PromptTokensReported))
				// Latency of a turn that DEMONSTRABLY reused the cache
				// (valid, positive cached tokens) — B9's scoring cohort, so
				// a fast usage-absent/zero-reuse turn cannot manufacture an
				// advantage the reused turns did not earn.
				if r.CachedPromptTokens > 0 && r.TotalMillis > 0 {
					cachedReuseLatencies = append(cachedReuseLatencies, float64(r.TotalMillis))
				}
			}
			if r.TotalMillis > 0 {
				cachedLatencies = append(cachedLatencies, float64(r.TotalMillis))
			}
		case "uncached":
			if r.TotalMillis > 0 {
				uncachedLatencies = append(uncachedLatencies, float64(r.TotalMillis))
			}
		}
		// Streaming TPS = tokens / (last_byte - first_byte). The harness
		// captures LastByteUTC + an effective first-byte timestamp via
		// (StartUTC + TTFTMillis). We approximate first-byte from those
		// because there's no explicit FirstByteUTC field.
		if r.Stream && r.CompletionTokensReceived > 0 && r.TTFTMillis > 0 && !r.LastByteUTC.IsZero() {
			firstByte := r.StartUTC.Add(time.Duration(r.TTFTMillis) * time.Millisecond)
			streamDur := r.LastByteUTC.Sub(firstByte).Seconds()
			if streamDur > 0 {
				v := float64(r.CompletionTokensReceived) / streamDur
				tps = append(tps, v)
				tpsSamples = append(tpsSamples, tpsSample{start: r.StartUTC, tps: v})
			}
		}
	}

	bm := BuyerMetrics{
		TTFTMs:          newHistogram(ttfts),
		StreamingTPS:    newHistogram(tps),
		WallTimeMs:      newHistogram(walls),
		TotalRequests:   len(results),
		SuccessCount:    success,
		Non2xxBreakdown: non2xx,
	}
	if bm.TTFTMs.P50 > 0 {
		bm.TailRatioP99P50 = bm.TTFTMs.P99 / bm.TTFTMs.P50
	}
	if bm.TotalRequests > 0 {
		bm.ErrorRatePer1k = 1000.0 * float64(non2xxCount) / float64(bm.TotalRequests)
	}
	if len(coldTTFTs) > 0 || len(warmTTFTs) > 0 {
		bm.ColdWarm.ColdTTFTMs = newHistogram(coldTTFTs)
		bm.ColdWarm.WarmTTFTMs = newHistogram(warmTTFTs)
		if bm.ColdWarm.WarmTTFTMs.P50 > 0 {
			bm.ColdWarm.RatioP50 = bm.ColdWarm.ColdTTFTMs.P50 / bm.ColdWarm.WarmTTFTMs.P50
		}
	}
	if attemptedCached > 0 || attemptedUncached > 0 {
		cr := CacheReuseMetrics{
			AttemptedCachedTurns:   attemptedCached,
			AttemptedUncachedTurns: attemptedUncached,
			CachedTurns:            cachedTurns,
			UsageAbsentTurns:       cacheUsageAbsent,
			InvalidTurns:           cacheInvalid,
			ReuseCount:             len(cacheReuse),
			UncachedLatencyMs:      newHistogram(uncachedLatencies),
			CachedLatencyMs:        newHistogram(cachedLatencies),
			CachedReuseLatencyMs:   newHistogram(cachedReuseLatencies),
		}
		if len(cacheReuse) > 0 {
			cr.ReuseP50 = percentile(cacheReuse, 0.50)
			sum := 0.0
			cr.ReuseMin = cacheReuse[0]
			for _, x := range cacheReuse {
				sum += x
				if x < cr.ReuseMin {
					cr.ReuseMin = x
				}
			}
			cr.ReuseMean = sum / float64(len(cacheReuse))
		}
		// B9 scores the reuse-bearing cohort against the cold primer.
		if cr.UncachedLatencyMs.P50 > 0 && cr.CachedReuseLatencyMs.Count > 0 {
			cr.LatencyRatioP50 = cr.CachedReuseLatencyMs.P50 / cr.UncachedLatencyMs.P50
		}
		bm.CacheReuse = cr
	}
	bm.SustainedTPS = computeSustainedTPS(tpsSamples, runStart, runEnd)
	return bm
}

// computeSustainedTPS windows the timestamped streaming-TPS samples into a
// first window [runStart, runStart+W) and a final window (runEnd-W, runEnd]
// by wall-clock start, where W = SustainedTPSWindowSeconds and runStart /
// runEnd are the TRUE run bounds (earliest/latest timestamp over ALL results,
// including failures) — NOT the last successful sample. This is the fix for
// the #584 failure mode: if the provider disconnects near run end, the final
// window has no usable streaming samples and B10 SKIPs, rather than sliding
// back onto early healthy samples and falsely PASSing.
//
// The run span must be at least 2W (disjoint windows). A shorter run yields
// zero-count windows, so B10 SKIPs — a run that can't hold a distinct first
// and final 5-min window cannot produce a meaningful retention verdict.
// retention = final_p50 / first_p50. B10 SKIPs below the per-window floor.
func computeSustainedTPS(samples []tpsSample, runStart, runEnd time.Time) SustainedTPSMetrics {
	var st SustainedTPSMetrics
	if len(samples) == 0 || runStart.IsZero() || !runEnd.After(runStart) {
		return st
	}
	w := time.Duration(SustainedTPSWindowSeconds) * time.Second
	// Require disjoint first/final windows: span >= 2W. Otherwise leave both
	// counts 0 so evalB10 SKIPs (can't distinguish first vs final).
	if runEnd.Sub(runStart) < 2*w {
		return st
	}
	firstCutoff := runStart.Add(w) // first window: [runStart, firstCutoff)
	finalCutoff := runEnd.Add(-w)  // final window: (finalCutoff, runEnd]
	var first, final []float64
	for _, s := range samples {
		if !s.start.Before(runStart) && s.start.Before(firstCutoff) {
			first = append(first, s.tps)
		}
		// Final window lower bound is EXCLUSIVE (finalCutoff, runEnd]; a
		// sample exactly at the cutoff belongs to neither window.
		if s.start.After(finalCutoff) && !s.start.After(runEnd) {
			final = append(final, s.tps)
		}
	}
	st.FirstWindowSamples = len(first)
	st.FinalWindowSamples = len(final)
	if len(first) > 0 {
		st.FirstWindowTPSP50 = percentile(first, 0.50)
	}
	if len(final) > 0 {
		st.FinalWindowTPSP50 = percentile(final, 0.50)
	}
	if st.FirstWindowTPSP50 > 0 {
		st.Retention = st.FinalWindowTPSP50 / st.FirstWindowTPSP50
	}
	return st
}

// --- provider-side compute --------------------------------------------------

func computeProviderMetrics(results []buyer.Result, providerSlots int, windowSeconds float64, pricing *Pricing) ProviderMetrics {
	type acc struct {
		Requests  int
		Tokens    int64
		Busy      float64
		Earnings  float64
		FirstSeen time.Time
		LastSeen  time.Time
		PromptTok int64
	}
	perID := map[string]*acc{}
	attributionFound := false
	for _, r := range results {
		if r.Outcome != "ok" {
			continue
		}
		pid := r.RouteProviderID
		if pid == "" {
			continue
		}
		attributionFound = true
		a := perID[pid]
		if a == nil {
			a = &acc{FirstSeen: r.StartUTC, LastSeen: r.EndUTC}
			perID[pid] = a
		}
		a.Requests++
		a.Tokens += r.CompletionTokensReceived
		a.PromptTok += r.PromptTokensReported
		dur := r.EndUTC.Sub(r.StartUTC).Seconds()
		if dur > 0 {
			a.Busy += dur
		}
		if r.StartUTC.Before(a.FirstSeen) {
			a.FirstSeen = r.StartUTC
		}
		if r.EndUTC.After(a.LastSeen) {
			a.LastSeen = r.EndUTC
		}
		if pricing != nil {
			a.Earnings += pricing.EarningsFor(r.Model, r.PromptTokensReported, r.CompletionTokensReceived)
		}
	}

	pm := ProviderMetrics{}
	if !attributionFound {
		pm.AttributionMissing = true
		return pm
	}

	// Stable ordering for the artifact: by descending requests.
	ids := make([]string, 0, len(perID))
	for id := range perID {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool {
		ai, aj := perID[ids[i]], perID[ids[j]]
		if ai.Requests != aj.Requests {
			return ai.Requests > aj.Requests
		}
		return ids[i] < ids[j]
	})

	var totalBusy float64
	var totalEarnings float64
	var totalTokens int64
	for _, id := range ids {
		a := perID[id]
		var utilPct float64
		if windowSeconds > 0 && providerSlots > 0 {
			utilPct = 100.0 * a.Busy / (float64(providerSlots) * windowSeconds)
		}
		var earningsPerHr float64
		if windowSeconds > 0 && a.Earnings > 0 {
			earningsPerHr = 3600.0 * a.Earnings / windowSeconds
		}
		pm.PerProvider = append(pm.PerProvider, PerProvider{
			ProviderID:       id,
			RequestsAdmitted: a.Requests,
			TokensDelivered:  a.Tokens,
			BusySeconds:      a.Busy,
			SlotUtilPct:      utilPct,
			EarningsUSDPerHr: earningsPerHr,
			SessionDurationS: a.LastSeen.Sub(a.FirstSeen).Seconds(),
		})
		totalBusy += a.Busy
		totalEarnings += a.Earnings
		totalTokens += a.Tokens
	}

	if windowSeconds > 0 && providerSlots > 0 && len(perID) > 0 {
		pm.Aggregate.SlotUtilPct = 100.0 * totalBusy / (float64(providerSlots) * windowSeconds * float64(len(perID)))
	}
	if windowSeconds > 0 && totalEarnings > 0 {
		pm.Aggregate.EarningsUSDPerHr = 3600.0 * totalEarnings / windowSeconds
	}
	pm.Aggregate.TokensDelivered = totalTokens
	pm.Aggregate.ProvidersSeen = len(perID)
	return pm
}

// --- B-invariant evaluators -------------------------------------------------

func evalB1(bm BuyerMetrics) Verdict {
	v := Verdict{ID: "B1", Title: "TTFT p50 within target", Unit: "ms",
		Target: TTFTp50TargetMs, BareMin: TTFTp50BareMinMs}
	if bm.TTFTMs.Count == 0 {
		v.Status = StatusSkip
		v.Detail = "no streaming-success samples with TTFT > 0"
		return v
	}
	v.Value = bm.TTFTMs.P50
	switch {
	case v.Value <= TTFTp50TargetMs:
		v.Status = StatusPass
		v.Detail = fmt.Sprintf("TTFT p50 %.0fms ≤ target %.0fms (n=%d)", v.Value, v.Target, bm.TTFTMs.Count)
	case v.Value <= TTFTp50BareMinMs:
		v.Status = StatusWarn
		v.Detail = fmt.Sprintf("TTFT p50 %.0fms over target %.0fms but ≤ bare-min %.0fms (n=%d)", v.Value, v.Target, v.BareMin, bm.TTFTMs.Count)
	default:
		v.Status = StatusFail
		v.Detail = fmt.Sprintf("TTFT p50 %.0fms exceeds bare-min %.0fms (n=%d)", v.Value, v.BareMin, bm.TTFTMs.Count)
	}
	return v
}

func evalB2(bm BuyerMetrics, results []buyer.Result) Verdict {
	v := Verdict{ID: "B2", Title: "streaming TPS p50 within target", Unit: "tok/s",
		Target: StreamingTPSp50Target, BareMin: StreamingTPSp50BareMin}
	if bm.StreamingTPS.Count == 0 {
		v.Status = StatusSkip
		// Distinguish "no streaming scenario" from "no usable samples".
		anyStream := false
		for _, r := range results {
			if r.Stream {
				anyStream = true
				break
			}
		}
		if !anyStream {
			v.Detail = "scenario is non-streaming — streaming TPS not applicable"
		} else {
			v.Detail = "no streaming-success samples with measurable post-TTFT duration"
		}
		return v
	}
	v.Value = bm.StreamingTPS.P50
	switch {
	case v.Value >= StreamingTPSp50Target:
		v.Status = StatusPass
		v.Detail = fmt.Sprintf("streaming TPS p50 %.1f tok/s ≥ target %.0f tok/s (n=%d)", v.Value, v.Target, bm.StreamingTPS.Count)
	case v.Value >= StreamingTPSp50BareMin:
		v.Status = StatusWarn
		v.Detail = fmt.Sprintf("streaming TPS p50 %.1f tok/s under target %.0f tok/s but ≥ bare-min %.0f tok/s (n=%d)", v.Value, v.Target, v.BareMin, bm.StreamingTPS.Count)
	default:
		v.Status = StatusFail
		v.Detail = fmt.Sprintf("streaming TPS p50 %.1f tok/s under bare-min %.0f tok/s (n=%d)", v.Value, v.BareMin, bm.StreamingTPS.Count)
	}
	return v
}

func evalB3(bm BuyerMetrics) Verdict {
	v := Verdict{ID: "B3", Title: "TTFT tail ratio p99/p50 bounded", Unit: "ratio",
		Target: TailRatioTarget, BareMin: TailRatioBareMin}
	if bm.TTFTMs.Count == 0 || bm.TTFTMs.P50 == 0 {
		v.Status = StatusSkip
		v.Detail = "no TTFT distribution to score"
		return v
	}
	v.Value = bm.TailRatioP99P50
	switch {
	case v.Value <= TailRatioTarget:
		v.Status = StatusPass
		v.Detail = fmt.Sprintf("tail ratio %.2f ≤ target %.1f (p50=%.0fms p99=%.0fms)", v.Value, v.Target, bm.TTFTMs.P50, bm.TTFTMs.P99)
	case v.Value <= TailRatioBareMin:
		v.Status = StatusWarn
		v.Detail = fmt.Sprintf("tail ratio %.2f over target %.1f but ≤ bare-min %.1f", v.Value, v.Target, v.BareMin)
	default:
		v.Status = StatusFail
		v.Detail = fmt.Sprintf("tail ratio %.2f exceeds bare-min %.1f", v.Value, v.BareMin)
	}
	return v
}

func evalB4(bm BuyerMetrics) Verdict {
	v := Verdict{ID: "B4", Title: "error rate per 1000 requests bounded", Unit: "errors/1000",
		Target: ErrorRateTargetPer1k, BareMin: ErrorRateBareMinPer1k}
	if bm.TotalRequests == 0 {
		v.Status = StatusSkip
		v.Detail = "no requests fired"
		return v
	}
	v.Value = bm.ErrorRatePer1k
	switch {
	case v.Value <= ErrorRateTargetPer1k:
		v.Status = StatusPass
		v.Detail = fmt.Sprintf("%.1f errors/1k ≤ target %.0f (%d non-2xx of %d)", v.Value, v.Target, bm.TotalRequests-bm.SuccessCount, bm.TotalRequests)
	case v.Value <= ErrorRateBareMinPer1k:
		v.Status = StatusWarn
		v.Detail = fmt.Sprintf("%.1f errors/1k over target %.0f but ≤ bare-min %.0f — likely scenario-tuning (overload), not network", v.Value, v.Target, v.BareMin)
	default:
		v.Status = StatusFail
		v.Detail = fmt.Sprintf("%.1f errors/1k exceeds bare-min %.0f — scenario re-tuning or real saturation", v.Value, v.BareMin)
	}
	return v
}

func evalB5(pm ProviderMetrics, windowSeconds float64) Verdict {
	v := Verdict{ID: "B5", Title: "provider slot utilization reasonable", Unit: "%",
		Target: SlotUtilTargetPct, BareMin: SlotUtilBareMinPct}
	if pm.AttributionMissing {
		v.Status = StatusSkip
		v.Detail = "gateway did not expose X-Provider-Id headers — per-provider attribution unavailable"
		return v
	}
	if windowSeconds <= 0 {
		v.Status = StatusSkip
		v.Detail = "window duration is zero"
		return v
	}
	v.Value = pm.Aggregate.SlotUtilPct
	switch {
	case v.Value >= SlotUtilTargetPct:
		v.Status = StatusPass
		v.Detail = fmt.Sprintf("aggregate slot util %.1f%% ≥ target %.0f%% across %d providers", v.Value, v.Target, pm.Aggregate.ProvidersSeen)
	case v.Value >= SlotUtilBareMinPct:
		v.Status = StatusWarn
		v.Detail = fmt.Sprintf("aggregate slot util %.1f%% over bare-min %.0f%% but under target %.0f%% (%d providers)", v.Value, v.BareMin, v.Target, pm.Aggregate.ProvidersSeen)
	default:
		v.Status = StatusFail
		v.Detail = fmt.Sprintf("aggregate slot util %.1f%% under bare-min %.0f%% — providers idle most of the window", v.Value, v.BareMin)
	}
	return v
}

func evalB6(pm ProviderMetrics, pricing *Pricing, windowSeconds float64) Verdict {
	v := Verdict{ID: "B6", Title: "earnings/hr viable at current tier-2 pricing", Unit: "USD/hr",
		Target: EarningsTargetUSDPerHr, BareMin: EarningsBareMinUSDPerHr}
	if pricing == nil {
		v.Status = StatusSkip
		v.Detail = "pricing manifest not loaded — set benchmark.pricing_source"
		return v
	}
	if pm.AttributionMissing {
		v.Status = StatusSkip
		v.Detail = "per-provider attribution unavailable (no X-Provider-Id header)"
		return v
	}
	if windowSeconds <= 0 {
		v.Status = StatusSkip
		v.Detail = "window duration is zero"
		return v
	}
	if pm.Aggregate.TokensDelivered == 0 {
		v.Status = StatusSkip
		v.Detail = "no completion tokens delivered in window"
		return v
	}
	// B6 measures per-provider median earnings/hr: a single high-earner
	// shouldn't mask a fleet that's losing money. Take the median across
	// providers seen.
	earnings := make([]float64, 0, len(pm.PerProvider))
	for _, p := range pm.PerProvider {
		earnings = append(earnings, p.EarningsUSDPerHr)
	}
	median := percentile(earnings, 0.50)
	v.Value = median
	switch {
	case v.Value >= EarningsTargetUSDPerHr:
		v.Status = StatusPass
		v.Detail = fmt.Sprintf("per-provider median earnings $%.2f/hr ≥ target $%.2f/hr (%d providers, aggregate $%.2f/hr)", v.Value, v.Target, pm.Aggregate.ProvidersSeen, pm.Aggregate.EarningsUSDPerHr)
	case v.Value >= EarningsBareMinUSDPerHr:
		v.Status = StatusWarn
		v.Detail = fmt.Sprintf("per-provider median earnings $%.2f/hr over bare-min $%.2f/hr but under target $%.2f/hr", v.Value, v.BareMin, v.Target)
	default:
		v.Status = StatusFail
		v.Detail = fmt.Sprintf("per-provider median earnings $%.2f/hr under bare-min $%.2f/hr — not M-series viable at current pricing", v.Value, v.BareMin)
	}
	return v
}

// evalB7 scores the TTFT cold/warm ratio. Cold p50 should not exceed
// warm p50 by more than 2× (target) or 5× (bare-min). SKIP when phase
// data is missing — e.g. when the scenario didn't use the cold_warm_pairs
// pattern.
func evalB7(bm BuyerMetrics) Verdict {
	v := Verdict{ID: "B7", Title: "TTFT cold/warm ratio bounded", Unit: "ratio",
		Target: ColdWarmRatioTarget, BareMin: ColdWarmRatioBareMin}
	cold := bm.ColdWarm.ColdTTFTMs
	warm := bm.ColdWarm.WarmTTFTMs
	if cold.Count == 0 && warm.Count == 0 {
		v.Status = StatusSkip
		v.Detail = "no phase-tagged results — scenario did not use cold_warm_pairs pattern"
		return v
	}
	if cold.Count == 0 || warm.Count == 0 || warm.P50 == 0 {
		v.Status = StatusSkip
		v.Detail = fmt.Sprintf("incomplete cold/warm sample (cold=%d warm=%d) — cannot compute ratio", cold.Count, warm.Count)
		return v
	}
	v.Value = bm.ColdWarm.RatioP50
	switch {
	case v.Value <= ColdWarmRatioTarget:
		v.Status = StatusPass
		v.Detail = fmt.Sprintf("cold/warm p50 ratio %.2f ≤ target %.1f (cold p50=%.0fms warm p50=%.0fms, n_cold=%d n_warm=%d)", v.Value, v.Target, cold.P50, warm.P50, cold.Count, warm.Count)
	case v.Value <= ColdWarmRatioBareMin:
		v.Status = StatusWarn
		v.Detail = fmt.Sprintf("cold/warm p50 ratio %.2f over target %.1f but ≤ bare-min %.1f (cold p50=%.0fms warm p50=%.0fms)", v.Value, v.Target, v.BareMin, cold.P50, warm.P50)
	default:
		v.Status = StatusFail
		v.Detail = fmt.Sprintf("cold/warm p50 ratio %.2f exceeds bare-min %.1f — cold-start penalty hurts buyer-perceived latency", v.Value, v.BareMin)
	}
	return v
}

// evalB8 scores sticky KV-cache reuse retention (RESEARCH_236 / #376).
// reuse = cached_prompt_tokens / prompt_tokens on the warm ("cached"-
// phase) sticky turns; the verdict is the median.
//
// It SKIPs — never FAILs — in every "cannot conclude" case, so a
// spec-strict gateway, an all-failed run, or a thin sample is not
// mistaken for a regression:
//   - no cache-phase turns attempted → scenario didn't use the pattern.
//   - attempted but no successful turn → the run failed (pool/network),
//     not a cache regression.
//   - usage/cache fields absent on every measured turn → gateway omitted
//     usage (hard rule #2).
//   - the uncached first-touch never succeeded (cache never warmed).
//   - fewer than CacheReuseMinSamples valid measurements, OR a partial
//     run where fewer than a strict majority of the INTENDED warm turns
//     produced a valid measurement (survivorship bias / duration
//     truncation, judged against the scenario's planned count) →
//     inconclusive.
//   - gate not armed (Benchmark.CacheGateArmed=false) → the scenario has
//     opted out of scoring (e.g. no positive baseline captured yet);
//     report the measured value but do not PASS/WARN/FAIL. Scenario 16
//     arms the gate from the 2026-07-22 baseline (median reuse 0.725).
//
// When conclusive and armed: PASS at/above the target, WARN in the
// degraded band down to the floor, FAIL below the floor (reuse collapsed),
// FAIL below (reuse collapsed). Higher reuse is better.
func evalB8(bm BuyerMetrics, expectedWarm int, gateArmed bool) Verdict {
	v := Verdict{ID: "B8", Title: "sticky cache-reuse retention", Unit: "ratio",
		Target: CacheReuseTarget, BareMin: CacheReuseBareMin}
	cr := bm.CacheReuse
	if cr.AttemptedCachedTurns == 0 {
		v.Status = StatusSkip
		v.Detail = "no cache-phase turns — scenario did not use the sticky_cache pattern"
		return v
	}
	// The uncached first-touch is what warms the provider prefix cache; if
	// it never succeeded, the "warm" turns are not actually warm and any
	// reuse figure is meaningless. Require a successful primer.
	if cr.UncachedLatencyMs.Count == 0 {
		v.Status = StatusSkip
		v.Detail = fmt.Sprintf("uncached first-touch never succeeded (%d attempted) — prefix cache was never warmed; cannot assess reuse", cr.AttemptedUncachedTurns)
		return v
	}
	if cr.CachedTurns == 0 {
		v.Status = StatusSkip
		v.Detail = fmt.Sprintf("all %d attempted cached turns failed (no successful response) — run/pool failure, not a cache regression", cr.AttemptedCachedTurns)
		return v
	}
	if cr.ReuseCount == 0 {
		v.Status = StatusSkip
		v.Detail = fmt.Sprintf("no valid reuse measurement on %d cached turns (%d usage-absent, %d invalid) — gateway omitted usage or reported impossible values; cannot measure reuse", cr.CachedTurns, cr.UsageAbsentTurns, cr.InvalidTurns)
		return v
	}
	if cr.ReuseCount < CacheReuseMinSamples {
		v.Value = cr.ReuseP50
		v.Status = StatusSkip
		v.Detail = fmt.Sprintf("only %d valid reuse samples (< %d) — inconclusive; median so far %.3f", cr.ReuseCount, CacheReuseMinSamples, cr.ReuseP50)
		return v
	}
	if !cacheReuseCovered(cr, expectedWarm) {
		planned := expectedWarm
		if planned <= 0 {
			planned = cr.AttemptedCachedTurns
		}
		v.Value = cr.ReuseP50
		v.Status = StatusSkip
		v.Detail = fmt.Sprintf("partial run — only %d valid measurements of %d intended warm turns (%d attempted, %d usage-absent, %d invalid); no strict majority, too incomplete to score", cr.ReuseCount, planned, cr.AttemptedCachedTurns, cr.UsageAbsentTurns, cr.InvalidTurns)
		return v
	}
	if !gateArmed {
		v.Value = cr.ReuseP50
		v.Status = StatusSkip
		v.Detail = fmt.Sprintf("gate not armed — median reuse %.3f measured over %d turns; recording only (set cache_gate_armed to score)", cr.ReuseP50, cr.ReuseCount)
		return v
	}
	v.Value = cr.ReuseP50
	switch {
	case v.Value >= CacheReuseTarget:
		v.Status = StatusPass
		v.Detail = fmt.Sprintf("median cache reuse %.3f ≥ target %.2f (n=%d cached turns, %d measured, min=%.3f mean=%.3f, %d usage-absent, %d invalid)", v.Value, v.Target, cr.CachedTurns, cr.ReuseCount, cr.ReuseMin, cr.ReuseMean, cr.UsageAbsentTurns, cr.InvalidTurns)
	case v.Value >= CacheReuseBareMin:
		v.Status = StatusWarn
		v.Detail = fmt.Sprintf("median cache reuse %.3f over floor %.2f but under target %.2f — reuse degrading, treat as non-green (n=%d measured of %d cached)", v.Value, v.BareMin, v.Target, cr.ReuseCount, cr.CachedTurns)
	default:
		v.Status = StatusFail
		v.Detail = fmt.Sprintf("median cache reuse %.3f below the calibrated floor %.2f — sticky prefix-cache reuse has collapsed (provider prefix-cache regression)", v.Value, v.BareMin)
	}
	return v
}

// evalB10 scores sustained streaming-TPS retention over a long soak
// (scenario 15). retention = final-window TPS p50 / first-window TPS p50.
// A provider that thermally throttles under constant decode load sheds
// throughput, driving retention below 1.0. SKIP when either window has
// fewer than SustainedTPSMinWindowSamples samples (run too short/sparse).
//
// gateArmed gates blocking: the B10 thresholds are provisional until a
// real lab soak calibrates them (issue #584), so when gateArmed is false
// a would-be FAIL is reported as WARN with a "[provisional/unarmed]"
// marker — the retention is still measured and surfaced, it just cannot
// block a run. When gateArmed is true B10 fails hard below the bare-min.
func evalB10(bm BuyerMetrics, gateArmed bool) Verdict {
	v := Verdict{ID: "B10", Title: "sustained streaming-TPS retention", Unit: "ratio",
		Target: SustainedTPSRetentionTarget, BareMin: SustainedTPSRetentionBareMin}
	st := bm.SustainedTPS
	if st.FirstWindowSamples < SustainedTPSMinWindowSamples || st.FinalWindowSamples < SustainedTPSMinWindowSamples {
		v.Status = StatusSkip
		v.Detail = fmt.Sprintf("insufficient windowed streaming samples (first=%d final=%d, need >=%d each) — soak too short or too sparse for a retention verdict",
			st.FirstWindowSamples, st.FinalWindowSamples, SustainedTPSMinWindowSamples)
		return v
	}
	if st.FirstWindowTPSP50 <= 0 {
		v.Status = StatusSkip
		v.Detail = "first-window streaming TPS p50 is zero — cannot compute retention"
		return v
	}
	v.Value = st.Retention
	armSuffix := ""
	if !gateArmed {
		armSuffix = " [provisional/unarmed — thresholds not yet lab-calibrated, #584]"
	}
	switch {
	case v.Value >= SustainedTPSRetentionTarget:
		v.Status = StatusPass
		v.Detail = fmt.Sprintf("retention %.2f >= target %.2f (first p50=%.1f tok/s n=%d, final p50=%.1f tok/s n=%d)%s",
			v.Value, v.Target, st.FirstWindowTPSP50, st.FirstWindowSamples, st.FinalWindowTPSP50, st.FinalWindowSamples, armSuffix)
	case v.Value >= SustainedTPSRetentionBareMin:
		v.Status = StatusWarn
		v.Detail = fmt.Sprintf("retention %.2f under target %.2f but >= bare-min %.2f — throughput sagging under sustained load (first p50=%.1f final p50=%.1f)%s",
			v.Value, v.Target, v.BareMin, st.FirstWindowTPSP50, st.FinalWindowTPSP50, armSuffix)
	default:
		if gateArmed {
			v.Status = StatusFail
			v.Detail = fmt.Sprintf("retention %.2f under bare-min %.2f — sustained-load throughput collapse (first p50=%.1f tok/s, final p50=%.1f tok/s); this is the #584 degradation signature",
				v.Value, v.BareMin, st.FirstWindowTPSP50, st.FinalWindowTPSP50)
		} else {
			v.Status = StatusWarn
			v.Detail = fmt.Sprintf("retention %.2f below bare-min %.2f (would FAIL if gate armed) — sustained-load throughput collapse (first p50=%.1f tok/s, final p50=%.1f tok/s)%s",
				v.Value, v.BareMin, st.FirstWindowTPSP50, st.FinalWindowTPSP50, armSuffix)
		}
	}
	return v
}

// evalB9 RECORDS the cached-turn LATENCY advantage (RESEARCH_236) but is
// deliberately record-only: it always SKIPs, never PASS/WARN/FAIL. ratio =
// reuse-bearing cached_latency_p50 / uncached_latency_p50 over the
// non-streaming full-response wall times (with a tiny max_tokens the wall
// time is prefill-dominated, which is what prefix-cache reuse
// accelerates). NOT time-to-first-token: sticky_cache turns are
// non-streaming, so no TTFT is observable.
//
// Why record-only (not armed like B8): the single-buyer sequential
// pattern produces exactly ONE cold control per run, and that lone cold
// turn also pays one-time TLS/connection setup the keep-alive warm turns
// do not — a confound that biases the ratio and cannot be averaged out
// with one sample. Arming B9 as a real latency gate needs a redesign
// (multiple independent cold controls with transport pre-warmed). Until
// then B9 emits the measured ratio for trend/observability only, so B8
// (reuse retention) can be armed independently without B9's confound
// gating a run. The value is still gated behind conclusive positive reuse
// so a collapsed/thin/truncated run reports no ratio at all.
func evalB9(bm BuyerMetrics, expectedWarm int) Verdict {
	// B9 is record-only (always SKIP) — no Target/BareMin so the artifact
	// carries no gate-shaped fields that could mislead a downstream consumer.
	v := Verdict{ID: "B9", Title: "cached-turn latency advantage (record-only)", Unit: "ratio"}
	cr := bm.CacheReuse
	un := cr.UncachedLatencyMs
	// B9 records over the REUSE-BEARING cohort (warm turns with valid,
	// positive cached tokens), not every successful warm turn — a fast
	// usage-absent or zero-reuse turn must not manufacture an advantage.
	ca := cr.CachedReuseLatencyMs
	v.Status = StatusSkip
	if cr.AttemptedCachedTurns == 0 && cr.AttemptedUncachedTurns == 0 {
		v.Detail = "no cache-phase turns — scenario did not use the sticky_cache pattern"
		return v
	}
	if !cacheReuseConclusivePositive(cr, expectedWarm) {
		v.Value = cr.LatencyRatioP50
		v.Detail = fmt.Sprintf("record-only: no conclusive positive cache reuse (median %.3f over %d valid of %d attempted warm turns) — latency gap not attributable to cache reuse", cr.ReuseP50, cr.ReuseCount, cr.AttemptedCachedTurns)
		return v
	}
	if un.Count == 0 || ca.Count == 0 || un.P50 == 0 {
		v.Detail = fmt.Sprintf("record-only: incomplete latency sample (uncached=%d reuse-bearing cached=%d)", un.Count, ca.Count)
		return v
	}
	v.Value = cr.LatencyRatioP50
	v.Detail = fmt.Sprintf("record-only: reuse-bearing cached/uncached latency p50 ratio %.2f (cached p50=%.0fms uncached p50=%.0fms, n_cached=%d n_uncached=%d) — not a gate; single cold control has connection-setup bias, arming needs a multi-cold-control redesign", v.Value, ca.P50, un.P50, ca.Count, un.Count)
	return v
}

// --- helpers ---------------------------------------------------------------

func newHistogram(xs []float64) Histogram {
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
	h.P50 = percentile(sorted, 0.50)
	h.P95 = percentile(sorted, 0.95)
	h.P99 = percentile(sorted, 0.99)
	h.Max = sorted[len(sorted)-1]
	return h
}

// percentile returns the nearest-rank percentile from a sorted-or-unsorted
// slice (sorts if not already sorted). q is in [0,1].
func percentile(xs []float64, q float64) float64 {
	if len(xs) == 0 {
		return 0
	}
	// Detect already-sorted to avoid double work in newHistogram.
	sorted := xs
	if !sort.Float64sAreSorted(xs) {
		sorted = append([]float64(nil), xs...)
		sort.Float64s(sorted)
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
