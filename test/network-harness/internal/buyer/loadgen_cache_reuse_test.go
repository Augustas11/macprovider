package buyer

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/augstar/macprovider-network-harness/internal/scenario"
)

// jsonServer replies to /v1/chat/completions with a fixed non-streaming body.
func jsonServer(body string) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, body)
	}))
}

// RESEARCH_236 D2: the harness must capture cached_prompt_tokens and
// prompt_tokens from a non-streaming usage frame, and must distinguish a
// genuine 0 (cache cold) from an omitted field so B8 can SKIP not FAIL.

func TestFireOnce_CachedPromptTokens_Present(t *testing.T) {
	srv := jsonServer(`{"choices":[{"message":{"role":"assistant","content":"pong"}}],` +
		`"usage":{"prompt_tokens":3200,"completion_tokens":2,"cached_prompt_tokens":2100}}`)
	defer srv.Close()

	res := fireOnce(context.Background(), http.DefaultClient, validLoadgenScenario(srv.URL), scenario.Prompt{Model: "m", User: "hi"}, 0, 1)
	if res.Outcome != "ok" {
		t.Fatalf("Outcome=%q want ok: %+v", res.Outcome, res)
	}
	if !res.UsagePresent {
		t.Fatalf("UsagePresent=false, want true")
	}
	if !res.CachedPromptTokensPresent {
		t.Fatalf("CachedPromptTokensPresent=false, want true")
	}
	if res.CachedPromptTokens != 2100 {
		t.Fatalf("CachedPromptTokens=%d, want 2100", res.CachedPromptTokens)
	}
	if res.PromptTokensReported != 3200 {
		t.Fatalf("PromptTokensReported=%d, want 3200", res.PromptTokensReported)
	}
}

func TestFireOnce_CachedPromptTokens_GenuineZero(t *testing.T) {
	// A cold turn reports cached_prompt_tokens:0 — this MUST be recorded
	// as present-with-value-0, not confused with an absent field.
	srv := jsonServer(`{"choices":[{"message":{"role":"assistant","content":"pong"}}],` +
		`"usage":{"prompt_tokens":3200,"completion_tokens":2,"cached_prompt_tokens":0}}`)
	defer srv.Close()

	res := fireOnce(context.Background(), http.DefaultClient, validLoadgenScenario(srv.URL), scenario.Prompt{Model: "m", User: "hi"}, 0, 0)
	if res.Outcome != "ok" {
		t.Fatalf("Outcome=%q want ok", res.Outcome)
	}
	if !res.UsagePresent {
		t.Fatalf("UsagePresent=false, want true")
	}
	if !res.CachedPromptTokensPresent {
		t.Fatalf("CachedPromptTokensPresent=false — a genuine 0 must be distinguishable from an absent field")
	}
	if res.CachedPromptTokens != 0 {
		t.Fatalf("CachedPromptTokens=%d, want 0", res.CachedPromptTokens)
	}
}

func TestFireOnce_UsagePresentButNoCachedField(t *testing.T) {
	// A usage frame with prompt/completion but no cached_prompt_tokens
	// (a gateway that hasn't rewritten it): UsagePresent true, but the
	// cached field absent → B8 will not count this turn's reuse.
	srv := jsonServer(`{"choices":[{"message":{"role":"assistant","content":"pong"}}],` +
		`"usage":{"prompt_tokens":3200,"completion_tokens":2}}`)
	defer srv.Close()

	res := fireOnce(context.Background(), http.DefaultClient, validLoadgenScenario(srv.URL), scenario.Prompt{Model: "m", User: "hi"}, 0, 1)
	if !res.UsagePresent {
		t.Fatalf("UsagePresent=false, want true")
	}
	if res.CachedPromptTokensPresent {
		t.Fatalf("CachedPromptTokensPresent=true, want false (no cached_prompt_tokens key)")
	}
	if res.PromptTokensReported != 3200 {
		t.Fatalf("PromptTokensReported=%d, want 3200", res.PromptTokensReported)
	}
}

func TestFireOnce_UsageAbsent_SpecStrictGateway(t *testing.T) {
	// A spec-strict gateway may omit usage entirely. UsagePresent must be
	// false so the B8 invariant SKIPs rather than treating it as 0 reuse.
	srv := jsonServer(`{"choices":[{"message":{"role":"assistant","content":"pong"}}]}`)
	defer srv.Close()

	res := fireOnce(context.Background(), http.DefaultClient, validLoadgenScenario(srv.URL), scenario.Prompt{Model: "m", User: "hi"}, 0, 1)
	if res.Outcome != "ok" {
		t.Fatalf("Outcome=%q want ok", res.Outcome)
	}
	if res.UsagePresent {
		t.Fatalf("UsagePresent=true, want false (no usage frame)")
	}
	if res.CachedPromptTokensPresent {
		t.Fatalf("CachedPromptTokensPresent=true, want false")
	}
}

// RESEARCH_236 D1 hard rule #1: the generated sticky prefix must be large
// and deterministic within a run, and distinct across buyers/runs.

func TestStickyCachePrefix_LargeAndDeterministic(t *testing.T) {
	a := stickyCachePrefix(0, 42, 140)
	b := stickyCachePrefix(0, 42, 140)
	if a != b {
		t.Fatalf("same (buyer, salt, lines) must produce identical prefix")
	}
	// ~25 tokens/line * 140 lines ~ 3.5k tokens; assert it's clearly large
	// (a word-count proxy — the real cache granularity is provider-side).
	words := len(strings.Fields(a))
	if words < 1500 {
		t.Fatalf("prefix too small: %d words (want a large ~3-4k-token block)", words)
	}
}

func TestStickyCachePrefix_DistinctPerBuyerAndRun(t *testing.T) {
	base := stickyCachePrefix(0, 42, 140)
	if stickyCachePrefix(1, 42, 140) == base {
		t.Fatalf("different buyers must get distinct prefixes (else cross-buyer cache pollution)")
	}
	if stickyCachePrefix(0, 43, 140) == base {
		t.Fatalf("different runs must get distinct prefixes (else request_index-0 is not cold)")
	}
}

// RESEARCH_236 D1: the sticky_cache pattern tags request_index 0 as the
// cold uncached first-touch and >=1 as warm cached turns, and prepends the
// large prefix so consecutive turns share it.
func TestRun_StickyCachePattern_PhaseTaggingAndPrefix(t *testing.T) {
	var seenUserContent []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		var body struct {
			Messages []struct {
				Role    string `json:"role"`
				Content string `json:"content"`
			} `json:"messages"`
		}
		_ = json.Unmarshal(b, &body)
		for _, m := range body.Messages {
			if m.Role == "user" {
				seenUserContent = append(seenUserContent, m.Content)
			}
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"prompt_tokens":3200,"completion_tokens":2,"cached_prompt_tokens":2000}}`)
	}))
	defer srv.Close()

	sc := validLoadgenScenario(srv.URL)
	sc.Buyers = scenario.Buyers{
		Count:                 1,
		Stream:                false,
		Pattern:               "sticky_cache",
		RequestsPerBuyer:      3,
		IntervalMs:            1,
		StickyConversationKey: "harness-cache-%d",
		CachePrefixLines:      140,
	}
	sc.Duration = 10 * (1000000000) // 10s
	results, err := Run(context.Background(), sc)
	if err != nil {
		t.Fatalf("Run error: %v", err)
	}
	if len(results) != 3 {
		t.Fatalf("got %d results, want 3", len(results))
	}
	byIdx := map[int]Result{}
	for _, r := range results {
		byIdx[r.RequestIndex] = r
	}
	if byIdx[0].CachePhase != "uncached" {
		t.Fatalf("request_index 0 CachePhase=%q, want uncached", byIdx[0].CachePhase)
	}
	if byIdx[1].CachePhase != "cached" || byIdx[2].CachePhase != "cached" {
		t.Fatalf("request_index 1/2 CachePhase=%q/%q, want cached", byIdx[1].CachePhase, byIdx[2].CachePhase)
	}
	if len(seenUserContent) != 3 {
		t.Fatalf("want 3 user prompts, got %d", len(seenUserContent))
	}
	// The large prefix must actually be sent — each user prompt should be
	// well over a plain "hi" (~3k+ token prefix ⇒ many KB).
	for i, s := range seenUserContent {
		if len(s) < 3000 {
			t.Fatalf("prompt %d only %d bytes — large prefix not prepended", i, len(s))
		}
	}
	// CRITICAL (nothing_new fix): consecutive turns must SHARE a long
	// common prefix but NOT be identical — an identical full prompt is
	// rejected by the provider cache as nothing_new (LCP == full prompt)
	// and reports 0 reuse even when the cache works.
	lcp := longestCommonPrefixLen(seenUserContent[0], seenUserContent[1])
	if lcp < 2000 {
		t.Fatalf("consecutive turns share only %d-byte prefix — too little for a prefix-cache hit", lcp)
	}
	for i := 1; i < len(seenUserContent); i++ {
		if seenUserContent[i] == seenUserContent[i-1] {
			t.Fatalf("turn %d prompt is IDENTICAL to turn %d — would trigger nothing_new (0 reuse)", i, i-1)
		}
	}
}

func longestCommonPrefixLen(a, b string) int {
	n := len(a)
	if len(b) < n {
		n = len(b)
	}
	i := 0
	for i < n && a[i] == b[i] {
		i++
	}
	return i
}
