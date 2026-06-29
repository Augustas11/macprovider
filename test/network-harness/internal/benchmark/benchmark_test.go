package benchmark

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-network-harness/internal/buyer"
	"github.com/augstar/macprovider-network-harness/internal/scenario"
)

// Helpers ---------------------------------------------------------------

func makeResult(ttftMs, totalMs int64, tokens int64, stream bool, provider, model string, status int) buyer.Result {
	start := time.Now().UTC()
	end := start.Add(time.Duration(totalMs) * time.Millisecond)
	r := buyer.Result{
		StartUTC:                 start,
		EndUTC:                   end,
		TTFTMillis:               ttftMs,
		TotalMillis:              totalMs,
		CompletionTokensReceived: tokens,
		HTTPStatus:               status,
		Stream:                   stream,
		RouteProviderID:          provider,
		Model:                    model,
		Outcome:                  "ok",
	}
	if status >= 400 {
		r.Outcome = "http_error"
	}
	if stream && status < 400 {
		r.LastByteUTC = end
	}
	return r
}

func sc(invs ...string) *scenario.Scenario {
	return &scenario.Scenario{
		Name: "test",
		Benchmark: scenario.Benchmark{
			Enabled:       true,
			Invariants:    invs,
			ProviderSlots: 3,
		},
	}
}

// Tests -----------------------------------------------------------------

func TestB1_TTFT_Pass(t *testing.T) {
	// 100 results, all TTFT 300ms — well under 800ms target.
	var results []buyer.Result
	for i := 0; i < 100; i++ {
		results = append(results, makeResult(300, 2000, 64, true, "p1", "m", 200))
	}
	res := Evaluate(sc("B1"), results, nil, nil, nil, "test", 60)
	if got := res.Verdicts[0].Status; got != StatusPass {
		t.Fatalf("B1 expected PASS at p50=300ms, got %s: %s", got, res.Verdicts[0].Detail)
	}
}

func TestB1_TTFT_Warn(t *testing.T) {
	// p50 = 1500ms → over target 800ms, under bare-min 2000ms → WARN.
	var results []buyer.Result
	for i := 0; i < 100; i++ {
		results = append(results, makeResult(1500, 3000, 64, true, "p1", "m", 200))
	}
	res := Evaluate(sc("B1"), results, nil, nil, nil, "test", 60)
	if got := res.Verdicts[0].Status; got != StatusWarn {
		t.Fatalf("B1 expected WARN at p50=1500ms, got %s: %s", got, res.Verdicts[0].Detail)
	}
}

func TestB1_TTFT_Fail(t *testing.T) {
	// p50 = 3000ms → over bare-min 2000ms → FAIL.
	var results []buyer.Result
	for i := 0; i < 100; i++ {
		results = append(results, makeResult(3000, 4000, 64, true, "p1", "m", 200))
	}
	res := Evaluate(sc("B1"), results, nil, nil, nil, "test", 60)
	if got := res.Verdicts[0].Status; got != StatusFail {
		t.Fatalf("B1 expected FAIL at p50=3000ms, got %s: %s", got, res.Verdicts[0].Detail)
	}
}

func TestB1_TTFT_Skip_NoSamples(t *testing.T) {
	// All requests failed → no TTFT samples → SKIP.
	results := []buyer.Result{makeResult(0, 1000, 0, true, "p1", "m", 500)}
	res := Evaluate(sc("B1"), results, nil, nil, nil, "test", 60)
	if got := res.Verdicts[0].Status; got != StatusSkip {
		t.Fatalf("B1 expected SKIP, got %s: %s", got, res.Verdicts[0].Detail)
	}
}

func TestB2_StreamingTPS_Pass(t *testing.T) {
	// 64 tokens over 1.6s post-TTFT = 40 tok/s → over target 30.
	r := makeResult(200, 1800, 64, true, "p1", "m", 200)
	// Adjust LastByteUTC so post-TTFT duration is 1.6s
	r.LastByteUTC = r.StartUTC.Add(200 * time.Millisecond).Add(1600 * time.Millisecond)
	var results []buyer.Result
	for i := 0; i < 30; i++ {
		results = append(results, r)
	}
	res := Evaluate(sc("B2"), results, nil, nil, nil, "test", 60)
	if got := res.Verdicts[0].Status; got != StatusPass {
		t.Fatalf("B2 expected PASS at ~40 tok/s, got %s: %s", got, res.Verdicts[0].Detail)
	}
}

func TestB2_StreamingTPS_Warn(t *testing.T) {
	// 64 tokens over 3.2s post-TTFT = 20 tok/s → under target 30, over bare-min 15.
	r := makeResult(200, 3400, 64, true, "p1", "m", 200)
	r.LastByteUTC = r.StartUTC.Add(200 * time.Millisecond).Add(3200 * time.Millisecond)
	var results []buyer.Result
	for i := 0; i < 30; i++ {
		results = append(results, r)
	}
	res := Evaluate(sc("B2"), results, nil, nil, nil, "test", 60)
	if got := res.Verdicts[0].Status; got != StatusWarn {
		t.Fatalf("B2 expected WARN at ~20 tok/s, got %s: %s", got, res.Verdicts[0].Detail)
	}
}

func TestB2_StreamingTPS_Skip_NonStream(t *testing.T) {
	results := []buyer.Result{makeResult(0, 1000, 64, false, "p1", "m", 200)}
	res := Evaluate(sc("B2"), results, nil, nil, nil, "test", 60)
	if got := res.Verdicts[0].Status; got != StatusSkip {
		t.Fatalf("B2 expected SKIP for non-streaming, got %s: %s", got, res.Verdicts[0].Detail)
	}
}

func TestB3_TailRatio_Pass(t *testing.T) {
	// Mostly 300ms TTFT, one 600ms outlier → p99/p50 ≈ 2.0 → PASS.
	var results []buyer.Result
	for i := 0; i < 99; i++ {
		results = append(results, makeResult(300, 1000, 64, true, "p1", "m", 200))
	}
	results = append(results, makeResult(600, 1000, 64, true, "p1", "m", 200))
	res := Evaluate(sc("B3"), results, nil, nil, nil, "test", 60)
	if got := res.Verdicts[0].Status; got != StatusPass {
		t.Fatalf("B3 expected PASS, got %s: %s", got, res.Verdicts[0].Detail)
	}
}

func TestB3_TailRatio_Fail(t *testing.T) {
	// p50=300ms, p99=6000ms, ratio=20 → FAIL (>5).
	// Nearest-rank p99 at n=100 needs ≥2 samples in the top 1% bucket.
	var results []buyer.Result
	for i := 0; i < 98; i++ {
		results = append(results, makeResult(300, 1000, 64, true, "p1", "m", 200))
	}
	for i := 0; i < 2; i++ {
		results = append(results, makeResult(6000, 7000, 64, true, "p1", "m", 200))
	}
	res := Evaluate(sc("B3"), results, nil, nil, nil, "test", 60)
	if got := res.Verdicts[0].Status; got != StatusFail {
		t.Fatalf("B3 expected FAIL at large tail, got %s: %s", got, res.Verdicts[0].Detail)
	}
}

func TestB4_ErrorRate_Pass(t *testing.T) {
	// 1000 reqs, 3 errors → 3/1000 → PASS (≤5).
	var results []buyer.Result
	for i := 0; i < 997; i++ {
		results = append(results, makeResult(300, 1000, 64, true, "p1", "m", 200))
	}
	for i := 0; i < 3; i++ {
		results = append(results, makeResult(0, 0, 0, true, "p1", "m", 503))
	}
	res := Evaluate(sc("B4"), results, nil, nil, nil, "test", 60)
	if got := res.Verdicts[0].Status; got != StatusPass {
		t.Fatalf("B4 expected PASS, got %s: %s", got, res.Verdicts[0].Detail)
	}
}

func TestB4_ErrorRate_Warn(t *testing.T) {
	// 1000 reqs, 15 errors → 15/1000 → WARN (>5, ≤25).
	var results []buyer.Result
	for i := 0; i < 985; i++ {
		results = append(results, makeResult(300, 1000, 64, true, "p1", "m", 200))
	}
	for i := 0; i < 15; i++ {
		results = append(results, makeResult(0, 0, 0, true, "p1", "m", 503))
	}
	res := Evaluate(sc("B4"), results, nil, nil, nil, "test", 60)
	if got := res.Verdicts[0].Status; got != StatusWarn {
		t.Fatalf("B4 expected WARN, got %s: %s", got, res.Verdicts[0].Detail)
	}
}

func TestB4_ErrorRate_Fail(t *testing.T) {
	// 100 reqs, 50 errors → 500/1000 → FAIL.
	var results []buyer.Result
	for i := 0; i < 50; i++ {
		results = append(results, makeResult(300, 1000, 64, true, "p1", "m", 200))
	}
	for i := 0; i < 50; i++ {
		results = append(results, makeResult(0, 0, 0, true, "p1", "m", 503))
	}
	res := Evaluate(sc("B4"), results, nil, nil, nil, "test", 60)
	if got := res.Verdicts[0].Status; got != StatusFail {
		t.Fatalf("B4 expected FAIL, got %s: %s", got, res.Verdicts[0].Detail)
	}
}

func TestB5_SlotUtil_Skip_NoAttribution(t *testing.T) {
	// No provider id → attribution missing → SKIP.
	results := []buyer.Result{makeResult(300, 1000, 64, true, "", "m", 200)}
	res := Evaluate(sc("B5"), results, nil, nil, nil, "test", 60)
	if got := res.Verdicts[0].Status; got != StatusSkip {
		t.Fatalf("B5 expected SKIP, got %s: %s", got, res.Verdicts[0].Detail)
	}
}

func TestB5_SlotUtil_Pass(t *testing.T) {
	// One provider, slots=3, window=60s, busy=72s (50%). Need a provider id.
	// 12 requests × 6s each = 72s busy → 72/(3*60) = 40% → PASS at target boundary.
	var results []buyer.Result
	for i := 0; i < 12; i++ {
		results = append(results, makeResult(300, 6000, 64, true, "p1", "m", 200))
	}
	res := Evaluate(sc("B5"), results, nil, nil, nil, "test", 60)
	if got := res.Verdicts[0].Status; got != StatusPass {
		t.Fatalf("B5 expected PASS at 40%% util, got %s: %s", got, res.Verdicts[0].Detail)
	}
}

func TestB5_SlotUtil_Warn(t *testing.T) {
	// 6 requests × 6s = 36s busy → 36/(3*60) = 20% → WARN.
	var results []buyer.Result
	for i := 0; i < 6; i++ {
		results = append(results, makeResult(300, 6000, 64, true, "p1", "m", 200))
	}
	res := Evaluate(sc("B5"), results, nil, nil, nil, "test", 60)
	if got := res.Verdicts[0].Status; got != StatusWarn {
		t.Fatalf("B5 expected WARN at 20%% util, got %s: %s", got, res.Verdicts[0].Detail)
	}
}

func TestB6_Earnings_Skip_NoPricing(t *testing.T) {
	results := []buyer.Result{makeResult(300, 1000, 64, true, "p1", "m", 200)}
	res := Evaluate(sc("B6"), results, nil, nil, nil, "test", 60)
	if got := res.Verdicts[0].Status; got != StatusSkip {
		t.Fatalf("B6 expected SKIP without pricing, got %s: %s", got, res.Verdicts[0].Detail)
	}
}

func TestB6_Earnings_Pass(t *testing.T) {
	// Price $5/1k completion tokens, 6 reqs × 64 tokens = 384 tokens × $0.005 = $1.92 over 60s.
	// Earnings/hr = 3600/60 × $1.92 = $115.20/hr → PASS.
	pricing := &Pricing{
		Source:        "test",
		ByModel:       map[string]ModelPrice{"m": {ModelID: "m", CompletionPricePer1k: 5.0}},
		UnknownModels: map[string]int{},
	}
	var results []buyer.Result
	for i := 0; i < 6; i++ {
		results = append(results, makeResult(300, 1000, 64, true, "p1", "m", 200))
	}
	res := Evaluate(sc("B6"), results, nil, nil, pricing, "test", 60)
	if got := res.Verdicts[0].Status; got != StatusPass {
		t.Fatalf("B6 expected PASS at $115/hr, got %s: %s", got, res.Verdicts[0].Detail)
	}
}

func TestB6_Earnings_Fail(t *testing.T) {
	// Price $0.0001/1k completion tokens, 6 reqs × 64 tokens × $0.0001/1k = ~$0.0000384 over 60s
	// → ~$0.0023/hr → under $0.30 bare-min → FAIL.
	pricing := &Pricing{
		Source:        "test",
		ByModel:       map[string]ModelPrice{"m": {ModelID: "m", CompletionPricePer1k: 0.0001}},
		UnknownModels: map[string]int{},
	}
	var results []buyer.Result
	for i := 0; i < 6; i++ {
		results = append(results, makeResult(300, 1000, 64, true, "p1", "m", 200))
	}
	res := Evaluate(sc("B6"), results, nil, nil, pricing, "test", 60)
	if got := res.Verdicts[0].Status; got != StatusFail {
		t.Fatalf("B6 expected FAIL at $0.002/hr, got %s: %s", got, res.Verdicts[0].Detail)
	}
}

// Pricing loader tests ---------------------------------------------------

func TestLoadPricing_ArrayShape(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "catalog.json")
	contents := `[
		{"model": "qwen3-32b", "price_per_1k_prompt_tokens": 0.001, "price_per_1k_completion_tokens": 0.005},
		{"model": "qwen-coder-7b", "price_per_1k_prompt_tokens": 0.0005, "price_per_1k_completion_tokens": 0.002}
	]`
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	p, err := LoadPricing(path)
	if err != nil {
		t.Fatalf("LoadPricing: %v", err)
	}
	if len(p.ByModel) != 2 {
		t.Fatalf("want 2 models, got %d", len(p.ByModel))
	}
	if p.ByModel["qwen3-32b"].CompletionPricePer1k != 0.005 {
		t.Fatalf("wrong completion price: %+v", p.ByModel["qwen3-32b"])
	}
}

func TestLoadPricing_MapShape(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "catalog.json")
	contents := `{
		"qwen3-32b": {"price_per_1k_prompt_tokens": 0.001, "price_per_1k_completion_tokens": 0.005}
	}`
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	p, err := LoadPricing(path)
	if err != nil {
		t.Fatalf("LoadPricing: %v", err)
	}
	if _, ok := p.ByModel["qwen3-32b"]; !ok {
		t.Fatalf("model missing: %+v", p.ByModel)
	}
}

func TestLoadPricing_WrappedShape(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "catalog.json")
	contents := `{
		"models": [
			{"model_id": "qwen3-32b", "completion_per_1k": 0.005}
		]
	}`
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	p, err := LoadPricing(path)
	if err != nil {
		t.Fatalf("LoadPricing: %v", err)
	}
	if _, ok := p.ByModel["qwen3-32b"]; !ok {
		t.Fatalf("model missing: %+v", p.ByModel)
	}
}

func TestLoadPricing_UnknownModel(t *testing.T) {
	p := &Pricing{
		Source:        "test",
		ByModel:       map[string]ModelPrice{"a": {ModelID: "a", CompletionPricePer1k: 1}},
		UnknownModels: map[string]int{},
	}
	got := p.EarningsFor("unknown", 100, 100)
	if got != 0 {
		t.Fatalf("unknown model should be zero, got %v", got)
	}
	if p.UnknownModels["unknown"] != 1 {
		t.Fatalf("UnknownModels should record the miss: %+v", p.UnknownModels)
	}
}

func TestLoadPricing_EarningsMath(t *testing.T) {
	p := &Pricing{
		Source:        "test",
		ByModel:       map[string]ModelPrice{"m": {ModelID: "m", PromptPricePer1k: 0.001, CompletionPricePer1k: 0.01}},
		UnknownModels: map[string]int{},
	}
	// 500 prompt × $0.001/1k = $0.0005
	// 1000 completion × $0.01/1k = $0.01
	// total = $0.0105
	got := p.EarningsFor("m", 500, 1000)
	want := 0.0105
	if got != want {
		t.Fatalf("earnings math: got %v want %v", got, want)
	}
}

// Compute tests ----------------------------------------------------------

func TestComputeBuyerMetrics_TailRatio(t *testing.T) {
	// 98 × 100ms + 2 × 500ms → p50=100, p99=500, ratio=5.0
	// Two outliers needed to land at p99 under nearest-rank with n=100.
	var results []buyer.Result
	for i := 0; i < 98; i++ {
		results = append(results, makeResult(100, 1000, 64, true, "p1", "m", 200))
	}
	for i := 0; i < 2; i++ {
		results = append(results, makeResult(500, 1000, 64, true, "p1", "m", 200))
	}
	bm := computeBuyerMetrics(results)
	if bm.TTFTMs.P50 != 100 {
		t.Fatalf("p50 want 100, got %v", bm.TTFTMs.P50)
	}
	if bm.TTFTMs.P99 != 500 {
		t.Fatalf("p99 want 500, got %v", bm.TTFTMs.P99)
	}
	if bm.TailRatioP99P50 != 5.0 {
		t.Fatalf("tail ratio want 5.0, got %v", bm.TailRatioP99P50)
	}
}

func TestComputeProviderMetrics_TwoProviders(t *testing.T) {
	results := []buyer.Result{
		makeResult(300, 6000, 100, true, "p1", "m", 200),
		makeResult(300, 6000, 100, true, "p1", "m", 200),
		makeResult(300, 6000, 200, true, "p2", "m", 200),
	}
	pm := computeProviderMetrics(results, 3, 60, nil)
	if pm.AttributionMissing {
		t.Fatal("attribution should be present")
	}
	if len(pm.PerProvider) != 2 {
		t.Fatalf("want 2 providers, got %d", len(pm.PerProvider))
	}
	// p1 first (2 requests) then p2 (1 request)
	if pm.PerProvider[0].ProviderID != "p1" {
		t.Fatalf("sort by request count failed: %+v", pm.PerProvider)
	}
	if pm.PerProvider[0].RequestsAdmitted != 2 {
		t.Fatalf("p1 should have 2 requests, got %d", pm.PerProvider[0].RequestsAdmitted)
	}
	// p1 busy = 12s → 12/(3*60) = 6.67% individual util
	if pm.PerProvider[0].SlotUtilPct < 6.0 || pm.PerProvider[0].SlotUtilPct > 7.0 {
		t.Fatalf("p1 util want ~6.67%%, got %v", pm.PerProvider[0].SlotUtilPct)
	}
	if pm.Aggregate.ProvidersSeen != 2 {
		t.Fatalf("aggregate providers want 2, got %d", pm.Aggregate.ProvidersSeen)
	}
}

func TestEvaluate_NoBenchmark(t *testing.T) {
	sc := &scenario.Scenario{Name: "t", Benchmark: scenario.Benchmark{Enabled: true, Invariants: nil}}
	res := Evaluate(sc, nil, nil, nil, nil, "t", 60)
	if res.Summary != nil || res.Verdicts != nil {
		t.Fatalf("empty invariants list should produce empty result, got %+v", res)
	}
}

// B7 (cold/warm TTFT ratio) tests --------------------------------------

func makePhasedResult(ttftMs int64, phase string) buyer.Result {
	r := makeResult(ttftMs, 1500, 64, true, "p1", "m", 200)
	r.Phase = phase
	return r
}

func TestB7_ColdWarm_Skip_NoPhase(t *testing.T) {
	results := []buyer.Result{makeResult(300, 1000, 64, true, "p1", "m", 200)}
	res := Evaluate(sc("B7"), results, nil, nil, nil, "test", 60)
	if got := res.Verdicts[0].Status; got != StatusSkip {
		t.Fatalf("B7 expected SKIP without phase data, got %s: %s", got, res.Verdicts[0].Detail)
	}
}

func TestB7_ColdWarm_Pass(t *testing.T) {
	// cold p50 = 400, warm p50 = 250 → ratio = 1.6 → PASS (≤2.0)
	var results []buyer.Result
	for i := 0; i < 10; i++ {
		results = append(results, makePhasedResult(400, "cold"))
		results = append(results, makePhasedResult(250, "warm"))
	}
	res := Evaluate(sc("B7"), results, nil, nil, nil, "test", 60)
	if got := res.Verdicts[0].Status; got != StatusPass {
		t.Fatalf("B7 expected PASS at ratio 1.6, got %s: %s", got, res.Verdicts[0].Detail)
	}
}

func TestB7_ColdWarm_Warn(t *testing.T) {
	// cold p50 = 900, warm p50 = 300 → ratio = 3.0 → WARN (>2.0, ≤5.0)
	var results []buyer.Result
	for i := 0; i < 10; i++ {
		results = append(results, makePhasedResult(900, "cold"))
		results = append(results, makePhasedResult(300, "warm"))
	}
	res := Evaluate(sc("B7"), results, nil, nil, nil, "test", 60)
	if got := res.Verdicts[0].Status; got != StatusWarn {
		t.Fatalf("B7 expected WARN at ratio 3.0, got %s: %s", got, res.Verdicts[0].Detail)
	}
}

func TestB7_ColdWarm_Fail(t *testing.T) {
	// cold p50 = 3000, warm p50 = 300 → ratio = 10.0 → FAIL (>5.0)
	var results []buyer.Result
	for i := 0; i < 10; i++ {
		results = append(results, makePhasedResult(3000, "cold"))
		results = append(results, makePhasedResult(300, "warm"))
	}
	res := Evaluate(sc("B7"), results, nil, nil, nil, "test", 60)
	if got := res.Verdicts[0].Status; got != StatusFail {
		t.Fatalf("B7 expected FAIL at ratio 10.0, got %s: %s", got, res.Verdicts[0].Detail)
	}
}

func TestB7_ColdWarm_Skip_OnlyOneSide(t *testing.T) {
	// All cold, no warm → SKIP (ratio undefined)
	var results []buyer.Result
	for i := 0; i < 5; i++ {
		results = append(results, makePhasedResult(400, "cold"))
	}
	res := Evaluate(sc("B7"), results, nil, nil, nil, "test", 60)
	if got := res.Verdicts[0].Status; got != StatusSkip {
		t.Fatalf("B7 expected SKIP with only one phase, got %s: %s", got, res.Verdicts[0].Detail)
	}
}

func TestComputeBuyerMetrics_ColdWarmPopulated(t *testing.T) {
	var results []buyer.Result
	for i := 0; i < 10; i++ {
		results = append(results, makePhasedResult(500, "cold"))
		results = append(results, makePhasedResult(200, "warm"))
	}
	bm := computeBuyerMetrics(results)
	if bm.ColdWarm.ColdTTFTMs.Count != 10 {
		t.Fatalf("want 10 cold samples, got %d", bm.ColdWarm.ColdTTFTMs.Count)
	}
	if bm.ColdWarm.WarmTTFTMs.Count != 10 {
		t.Fatalf("want 10 warm samples, got %d", bm.ColdWarm.WarmTTFTMs.Count)
	}
	if bm.ColdWarm.RatioP50 != 2.5 {
		t.Fatalf("want ratio 2.5, got %v", bm.ColdWarm.RatioP50)
	}
}

// Scenario schema validation for cold_warm_pairs ----------------------

func TestSchema_ColdWarmPairs_Validate(t *testing.T) {
	// requests_per_buyer must be even, ≥2; inter_pair_idle_seconds > 0
	cases := []struct {
		name              string
		reqs              int
		idleSec           int
		wantErr           bool
	}{
		{"valid 10 pairs", 20, 60, false},
		{"odd reqs", 21, 60, true},
		{"zero reqs", 0, 60, true},
		{"zero idle", 20, 0, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := &scenario.Scenario{
				Name: "x",
				Target: scenario.Target{
					GatewayURL: "https://x", BuyerToken: "tk",
				},
				Duration: 60_000_000_000,
				Buyers: scenario.Buyers{
					Count:                1,
					Pattern:              "cold_warm_pairs",
					RequestsPerBuyer:     tc.reqs,
					InterPairIdleSeconds: tc.idleSec,
				},
				Prompts: []scenario.Prompt{{Model: "m", User: "hi"}},
			}
			err := s.Validate()
			if (err != nil) != tc.wantErr {
				t.Fatalf("Validate err=%v, wantErr=%v", err, tc.wantErr)
			}
		})
	}
}
