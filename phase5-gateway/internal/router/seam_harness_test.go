package router

// Seam-hardening e2e harness — executable regression tests for the buyer↔gateway↔
// coordinator↔provider seam risks documented in audits/seam-hardening/ (scenarios
// H1–H7), driving phase5-gateway as if it were an OpenRouter upstream. The
// "mock-upstream" is a controllable roundTripFunc transport injected via
// WithHTTPClient — it stands in for coordinator.buyer_url with per-scenario injection
// (slow drip, buyer disconnect, usage over-report, id-less retry, etc.).
//
// Each test maps to a finding in audits/seam-hardening/findings.md and carries its
// EXPECTED verdict. Tests whose subject is a confirmed FAIL assert the buggy-today
// behavior (so a fix flips them red); PASS tests certify a real strength.
//
// Run: go test ./internal/router/ -run TestSeam -count=1 -v
//
// Coordinator-side scenarios (H3 breaker attribution, H4 paid-while-timed-out) live in
// phase4-coordinator, not this package — recorded as documented Skips below with their
// exact injection points.

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/settlement/journal"
	"github.com/augstar/macprovider-gateway/internal/storage"
	"github.com/augstar/macprovider-gateway/internal/storage/sqlite"
)

// ---- mock-upstream helpers -------------------------------------------------

// seamStreamingUpstream returns an http.Client whose transport answers the
// gateway's POST {BuyerURL}/v1/chat/completions with a 200 text/event-stream whose
// body is produced by onWrite (via an io.Pipe), letting a scenario inject slow
// drip, mid-stream close, or a final usage chunk. Non-chat paths 404.
func seamStreamingUpstream(onWrite func(pw *io.PipeWriter)) *http.Client {
	return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		pr, pw := io.Pipe()
		go onWrite(pw)
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}},
			Body:       pr,
		}, nil
	})}
}

// seamStreamingUpstreamCtx is like seamStreamingUpstream but passes the upstream
// request context (which the gateway sets to upCtx = the total-wall deadline via
// http.NewRequestWithContext at chat_proxy.go:347) into onWrite. A faithful mock must
// stop writing and close the body when that context fires — exactly what the real
// net/http.Transport does in production when the total wall expires. (A plain
// roundTripFunc pipe does NOT honor ctx, which would let a stream outlive the wall.)
func seamStreamingUpstreamCtx(onWrite func(pw *io.PipeWriter, ctx context.Context)) *http.Client {
	return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		pr, pw := io.Pipe()
		go onWrite(pw, r.Context())
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}},
			Body:       pr,
		}, nil
	})}
}

// seamJSONUpstream returns an http.Client that answers with a fixed non-streaming
// 200 application/json completion (used by the idempotency scenarios).
func seamJSONUpstream(completion string, seen *int) *http.Client {
	return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		if seen != nil {
			*seen++
		}
		return responseWithBody(http.StatusOK,
			http.Header{"Content-Type": []string{"application/json"}}, completion), nil
	})}
}

// billedTokens reads /v1/usage and returns daily_tokens_used.
func billedTokens(t *testing.T, h http.Handler, key string) float64 {
	t.Helper()
	resp := assertStatus(t, h, http.MethodGet, "/v1/usage", key, "", "1.2.3.4", http.StatusOK)
	quota := readQuota(t, resp)
	used, ok := quota["daily_tokens_used"].(float64)
	if !ok {
		t.Fatalf("daily_tokens_used missing/non-numeric in quota=%v", quota)
	}
	return used
}

const seamCompletionJSON = `{"id":"c","object":"chat.completion","created":1,"model":"llama",` +
	`"usage":{"prompt_tokens":8,"completion_tokens":12,"total_tokens":20},` +
	`"choices":[{"index":0,"message":{"role":"assistant","content":"hello"},"finish_reason":"stop"}]}`

// ---- H5 · id-less retry bills once (INV-11) --------------------------------
// EXPECTED: PASS = certifies the P1-1 FIX (issue #762). This test used to be
// TestSeamH5a_IdlessRetryDoubleBills and asserted the buggy-today behavior: an id-less
// buyer retry — which OpenRouter does by default — mints a fresh request_id per attempt,
// so the durable (account_id, request_id) reservation key never matched and each attempt
// reserved + settled independently → one buyer intent, two bills.
//
// #762 fingerprints the raw body (plus tenant / demo token / conversation tag) for
// gateway-minted ids only, and REPLAYS attempt 1's buyer-visible response to an identical
// re-send inside the configured window. The scenario is deliberately unchanged: what
// flipped is the verdict, so the test stays a durable tripwire. A regression that
// re-dispatches an id-less retry — or that bills it twice while still replaying — turns
// this red again.
//
// The replay cache is NOT the money invariant. A cache miss (restart, eviction, oversize
// body, truncated stream) adopts attempt 1's id and falls through to the durable
// duplicate_request_id 409, so "billed once" holds even when the replay does not. See
// TestIdlessDedupe_* in idless_dedupe_test.go for those paths.

func TestSeamH5a_IdlessRetryBillsOnce(t *testing.T) {
	var upstreamHits int
	client := seamJSONUpstream(seamCompletionJSON, &upstreamHits)
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_h5a")

	body := `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
	// No X-Request-ID → each call mints a fresh id → pre-#762, distinct reservations.
	first := postChat(t, h, key, body, nil)
	if first.Code != http.StatusOK {
		t.Fatalf("call 1 status=%d body=%s", first.Code, first.Body.String())
	}
	second := postChat(t, h, key, body, nil)
	if second.Code != http.StatusOK {
		t.Fatalf("call 2 status=%d body=%s", second.Code, second.Body.String())
	}

	if got := second.Header().Get("X-MacProvider-Dedupe"); got != "replay" {
		t.Fatalf("REGRESSION (INV-11): id-less retry was not served as a replay; "+
			"X-MacProvider-Dedupe=%q want %q", got, "replay")
	}
	if upstreamHits != 1 {
		t.Fatalf("REGRESSION (INV-11): id-less retry re-dispatched inference; upstream hit %d times, want 1",
			upstreamHits)
	}
	if first.Body.String() != second.Body.String() {
		t.Fatalf("replay body differs from attempt 1:\n first=%s\nsecond=%s",
			first.Body.String(), second.Body.String())
	}
	used := billedTokens(t, h, key)
	if used != 20 {
		t.Fatalf("REGRESSION (INV-11): id-less retry billed %v tokens, want 20 "+
			"(40 = the pre-#762 double-bill is back)", used)
	}
	t.Logf("PASS (P1-1 FIXED, #762): id-less retry replayed attempt 1's response "+
		"(upstream hits=%d, billed=%v once).", upstreamHits, used)
}

func TestSeamH5b_StableRequestIDBillsOnce(t *testing.T) {
	// Control: a stable UUID X-Request-ID must dedupe — 2nd call 409s, billed once.
	client := seamJSONUpstream(seamCompletionJSON, nil)
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_h5b")

	body := `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
	hdr := map[string]string{"X-Request-ID": "11111111-1111-4111-8111-111111111111"}
	if r := postChat(t, h, key, body, hdr); r.Code != http.StatusOK {
		t.Fatalf("call 1 status=%d body=%s", r.Code, r.Body.String())
	}
	r2 := postChat(t, h, key, body, hdr)
	if r2.Code == http.StatusOK {
		t.Fatalf("call 2 with same X-Request-ID should not re-succeed; body=%s", r2.Body.String())
	}
	used := billedTokens(t, h, key)
	if used != 20 {
		t.Fatalf("stable-id idempotency broken: billed %v want 20 (2nd call code=%d)", used, r2.Code)
	}
	t.Logf("PASS (INV-11 control): stable X-Request-ID deduped — 2nd call code=%d, billed once (%v).",
		r2.Code, used)
}

// ---- H6 · provider over-reports usage → bounded to delivered (INV-7) -------
// EXPECTED: PASS. The gateway rejects a provider completion count that exceeds the
// emitted bytes / max_tokens and downgrades to a byte-estimate (charge bounded by
// delivered: committed <= delivered-to-client <= provider-claimed).

func TestSeamH6_ProviderOverReportBoundedToDelivered(t *testing.T) {
	sse := `data: {"id":"c","choices":[{"delta":{"content":"ok"}}]}` + "\n\n" +
		// completion_tokens=100000 wildly exceeds max_tokens=20 and the 2 emitted bytes:
		`data: {"id":"c","usage":{"prompt_tokens":8,"completion_tokens":100000,"total_tokens":100008},"choices":[{"delta":{},"finish_reason":"stop"}]}` + "\n\n" +
		`data: [DONE]` + "\n\n"
	client := seamStreamingUpstream(func(pw *io.PipeWriter) {
		_, _ = pw.Write([]byte(sse))
		_ = pw.Close()
	})
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_h6")

	body := `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
	r := postChat(t, h, key, body, map[string]string{"X-Request-ID": "22222222-2222-4222-8222-222222222222"})
	if r.Code != http.StatusOK || !strings.Contains(r.Body.String(), "data: [DONE]") {
		t.Fatalf("stream code=%d body=%s", r.Code, r.Body.String())
	}

	_, source := usageEventOutcome(t, dbPath, "acct_h6")
	used := billedTokens(t, h, key)
	if source == "provider_reported" || used >= 1000 {
		t.Fatalf("INV-7 VIOLATED: provider over-report accepted (source=%s, billed=%v) — "+
			"charge not bounded to delivered", source, used)
	}
	t.Logf("PASS (INV-7): over-report rejected → source=%s, billed bounded to %v (not 100008).",
		source, used)
}

// ---- H2 · buyer disconnect mid-stream (INV-5, INV-7) -----------------------
// EXPECTED: PASS-with-nuance. Streaming buyer-disconnect settles a byte-estimated
// partial (consumer-side outcome), bounded to delivered — never a provider fault.
// (The asymmetry vs non-streaming refund is documented in 02-macprovider-audit.md.)

func TestSeamH2_BuyerDisconnectSettlesConsumerSide(t *testing.T) {
	delivered := make(chan struct{})
	release := make(chan struct{})
	client := seamStreamingUpstream(func(pw *io.PipeWriter) {
		_, _ = pw.Write([]byte(`data: {"id":"c","choices":[{"delta":{"content":"hello"}}]}` + "\n\n"))
		close(delivered)
		<-release // hold the stream open until the test cancels the buyer
		_ = pw.Close()
	})
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_h2")

	body := `{"model":"llama","stream":true,"max_tokens":500,"messages":[{"role":"user","content":"hi"}]}`
	ctx, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body)).WithContext(ctx)
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Request-ID", "33333333-3333-4333-8333-333333333333")
	rec := httptest.NewRecorder()

	done := make(chan struct{})
	go func() { h.ServeHTTP(rec, req); close(done) }()

	select {
	case <-delivered:
	case <-time.After(3 * time.Second):
		close(release)
		t.Fatal("upstream never delivered first chunk")
	}
	cancel()       // buyer disconnects mid-stream
	close(release) // let the upstream goroutine finish
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("handler did not return after buyer cancel")
	}

	outcome, source := usageEventOutcome(t, dbPath, "acct_h2")
	if strings.Contains(outcome, "provider") && strings.Contains(outcome, "error") {
		t.Fatalf("INV-5 VIOLATED: buyer-cancel booked as a provider fault (outcome=%s)", outcome)
	}
	used := billedTokens(t, h, key)
	if used > 100 { // bounded to the one delivered delta, not the 500-token max
		t.Fatalf("INV-7 VIOLATED: buyer-cancel billed %v (> delivered bound)", used)
	}
	t.Logf("PASS (INV-5/INV-7): buyer-disconnect settled consumer-side outcome=%q source=%q "+
		"billed=%v (bounded to delivered). Note: streaming BILLS the estimate while "+
		"non-streaming refunds — asymmetry per 02-macprovider-audit.md.", outcome, source, used)
}

// ---- H1 · progressing stream survives the legacy wall (INV-1, INV-2) -------
// EXPECTED: PASS = certifies the P0-2 FIX (issue #760). This test used to be
// TestSeamH1_FlatWallKillsProgressingStream and asserted the buggy-today behavior:
// one flat total wall (chat_proxy.go:122, CoordinatorTimeout) spanning the whole
// request, cutting a steadily-progressing stream even though it never hit the decode
// idle timer. Per-phase deadlines replaced that wall, so the SAME scenario — legacy
// wall shortened to 1s, a healthy stream emitting for 3s — must now complete cleanly.
//
// The scenario is deliberately unchanged (including seamStreamingUpstreamCtx, which
// honors the upstream request ctx exactly as the real transport does): what flipped
// is the verdict, so the test remains a durable tripwire. A regression that
// reintroduces any request-spanning flat wall — the ctx wall here, or the
// http.Client.Timeout twin in cmd/gateway (see TestCoordinatorClientHasNoBodyTimeout)
// — turns this red again.

func TestSeamH1_ProgressingStreamSurvivesLegacyWall(t *testing.T) {
	client := seamStreamingUpstreamCtx(func(pw *io.PipeWriter, ctx context.Context) {
		// Emit a token every 200ms (well under the 10s idle timer) for up to 3s,
		// i.e. a HEALTHY, steadily-progressing stream. Honor the upstream request
		// context exactly as the real transport does: if it fires, abort the body.
		for i := 0; i < 15; i++ {
			if _, err := pw.Write([]byte(`data: {"id":"c","choices":[{"delta":{"content":"x"}}]}` + "\n\n")); err != nil {
				return
			}
			select {
			case <-ctx.Done(): // a deadline fired mid-stream → transport aborts the body
				_ = pw.CloseWithError(ctx.Err())
				return
			case <-time.After(200 * time.Millisecond):
			}
		}
		_, _ = pw.Write([]byte(`data: [DONE]` + "\n\n"))
		_ = pw.Close()
	})
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		// The legacy flat wall. Post-#760 it only floors the derived streaming
		// ceiling (clamp >= coordinator_request_seconds); it no longer bounds a
		// progressing stream.
		cfg.Timeouts.CoordinatorRequestSeconds = 1
		cfg.Timeouts.CoordinatorHeaderTimeoutSeconds = 1
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_h1")

	body := `{"model":"llama","stream":true,"max_tokens":500,"messages":[{"role":"user","content":"hi"}]}`
	start := time.Now()
	r := postChat(t, h, key, body, map[string]string{"X-Request-ID": "44444444-4444-4444-8444-444444444444"})
	elapsed := time.Since(start)

	if r.Code != http.StatusOK {
		t.Fatalf("stream status=%d want 200; body=%.300q", r.Code, r.Body.String())
	}
	if !strings.Contains(r.Body.String(), "data: [DONE]") {
		t.Fatalf("REGRESSION (INV-1/INV-2): progressing stream did not reach [DONE] after %s "+
			"— a request-spanning flat wall is back. body=%.300q",
			elapsed.Round(10*time.Millisecond), r.Body.String())
	}
	for _, forbidden := range []string{"provider_disconnected", "provider_timeout", "stream_truncated"} {
		if strings.Contains(r.Body.String(), forbidden) {
			t.Fatalf("REGRESSION (INV-1/INV-2): healthy stream emitted a %s terminal after %s; body=%.300q",
				forbidden, elapsed.Round(10*time.Millisecond), r.Body.String())
		}
	}
	// The mock upstream declares no settlement-finality trailer, so a cleanly
	// completed stream settles on the legacy path, which relabels "ok" as
	// "unverified_streaming". Both are clean-completion outcomes; what must
	// never appear is a timeout/truncation outcome.
	outcome, source := usageEventOutcome(t, dbPath, "acct_h1")
	if outcome != "ok" && outcome != "unverified_streaming" {
		t.Fatalf("REGRESSION (INV-1/INV-2): usage outcome=%q source=%q, want a clean-completion "+
			"outcome for a stream that ran to [DONE]", outcome, source)
	}
	t.Logf("PASS (P0-2 FIXED, #760): a progressing stream ran %s past a %s legacy wall and "+
		"completed with [DONE], outcome=%q source=%q.",
		elapsed.Round(10*time.Millisecond), time.Second, outcome, source)
}

// ---- H3 · relay-timeout strikes provider on buyer-cancel (INV-3) -----------
// IMPLEMENTED coordinator-side (this behavior is the coordinator's, not the gateway's):
// phase4-coordinator/internal/buyer/seam_h3_test.go :: TestSeamH3_RelayTimeoutStrikesOnBuyerCancel
// (a real, passing regression test — confirms the provider is struck to Degraded).
func TestSeamH3_RelayTimeoutBuyerCancelGuard(t *testing.T) {
	t.Skip("Implemented in phase4-coordinator/internal/buyer/seam_h3_test.go " +
		"(TestSeamH3_RelayTimeoutStrikesOnBuyerCancel) — that package owns the breaker path " +
		"(server.go:2994). Run: go test ./internal/buyer/ -run TestSeamH3 in phase4-coordinator.")
}

// ---- H4 · paid-while-buyer-told-timeout (INV-6) ----------------------------
// Documented coordinator-side: no arbiter joins the two terminal paths, so it is not
// unit-testable. See phase4-coordinator/internal/buyer/seam_h3_test.go :: TestSeamH4_SingleTerminalWins.
func TestSeamH4_NoPaidWhileTimedOut(t *testing.T) {
	t.Skip("Documented in phase4-coordinator/internal/buyer/seam_h3_test.go " +
		"(TestSeamH4_SingleTerminalWins): billing terminal (billing_recorder.go:220) and the " +
		"buyer 504 terminal (server.go:2996) are independent paths with no latch — an emergent " +
		"cross-path race, testable only once a single-terminal-arbiter actor exists.")
}

// ---- H7 · settlement is crash-durable via the journal (INV-8) --------------
// EXPECTED: PASS = certifies the P1-2 FIX (issue #763). This test used to be
// TestSeamH7_SettlementNotCrashDurable and asserted the buggy-today behavior: on the
// STREAMING after-commit path the buyer has already received a committed 200 stream, and
// when SettleReservation AND the EnsureUsageEvent fallback both failed the gateway logged,
// refunded, and DROPPED the usage row — tokens delivered, nobody billed, nothing to
// reconcile from. (Non-streaming just 500s the buyer, so the committed-success-with-
// dropped-row case is streaming-specific.)
//
// The scenario is deliberately unchanged — same spy, same double failure, same in-band
// outcome (the in-band drop was never the bug; the PERMANENCE was). What flipped is what
// happens next: the settle effect was journaled BEFORE the attempt, so a later process
// re-drives it into a durable bill. The test therefore runs the recovery the production
// loop runs (RecoverSettlementJournal, cmd/gateway startup + ticker) against a SECOND
// Server over the SAME store and the SAME journal directory, with no failure spy — i.e.
// the pathology cleared, exactly as after a restart.
//
// A regression that stops journaling the effect, seals it prematurely, or breaks the
// re-drive ladder turns this red again.
func TestSeamH7_SettlementRecoveredFromJournal(t *testing.T) {
	// Streaming upstream: a provider usage chunk then [DONE] → committed 200, settlement
	// runs after commit via settleAfterCommit.
	client := seamStreamingUpstream(func(pw *io.PipeWriter) {
		_, _ = io.WriteString(pw, `data: {"id":"c","usage":{"prompt_tokens":8,"completion_tokens":12,"total_tokens":20},"choices":[{"delta":{"content":"hi"}}]}`+
			"\n\n"+`data: [DONE]`+"\n\n")
		_ = pw.Close()
	})
	// The harness returns the real *sqlite.Store; wrap it in a settle-failing spy and
	// build a fresh gateway over the SAME store/db (chat_proxy_retry_test.go:503-504 pattern).
	_, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		// The recovery pass below acts on an effect written moments ago; the
		// grace window has its own coverage in
		// TestSettlementJournal_GraceWindowSkipsYoungEntries.
		cfg.Settlement.JournalRecoveryGraceSeconds = 0
	}, WithHTTPClient(client))
	jnl := openTestJournal(t, cfg)
	spy := &settleFailSpyStore{Store: store}
	h := New(cfg, spy, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(client), WithSettlementJournal(jnl)).Handler()
	key := createAccountAndKey(t, store, cfg, "acct_h7")

	body := `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
	resp := postChat(t, h, key, body, map[string]string{"X-Request-ID": "77777777-7777-4777-8777-777777777777"})
	if resp.Code != http.StatusOK {
		t.Fatalf("expected a committed 200 stream despite settle failure; got %d body=%s", resp.Code, resp.Body.String())
	}

	// IN-BAND: unchanged. The double failure still refunds and still writes no usage row
	// in the request's own goroutine — there is nothing left to try in-band.
	got := gatewaySettlementSnapshot(t, dbPath, "acct_h7")
	if got.usageRows != 0 {
		t.Fatalf("in-band usageRows=%d want 0 — the double-failure branch must NOT invent an "+
			"in-band bill; the journal is what makes it recoverable", got.usageRows)
	}
	if got.refundedRows != 1 || got.activeRows != 0 || got.activeReserved != 0 {
		t.Fatalf("expected clean refund after the in-band drop; got %+v (want refunded=1 active=0 reserved=0)", got)
	}

	// THE FIX: the effect is on disk, unsealed, with the full billing payload.
	scan, err := jnl.Scan()
	if err != nil {
		t.Fatalf("journal Scan: %v", err)
	}
	if len(scan.Unsealed) != 1 {
		t.Fatalf("REGRESSION (INV-8): journal holds %d unsealed effects, want exactly 1 — the "+
			"after-commit settle was not armed, so the dropped bill is unrecoverable again", len(scan.Unsealed))
	}
	effect := scan.Unsealed[0]
	if effect.AccountID != "acct_h7" || effect.RequestID != "77777777-7777-4777-8777-777777777777" {
		t.Fatalf("journaled effect identity=%s/%s want acct_h7/7777…", effect.AccountID, effect.RequestID)
	}
	if effect.PromptTokens != 8 || effect.CompletionTokens != 12 || effect.TotalTokens != 20 ||
		effect.TokenSource != "provider_reported" {
		t.Fatalf("journaled payload=%+v want 8/12/20 provider_reported — the record must reproduce "+
			"the usage row the settle would have written", effect)
	}
	if effect.WindowDate != fixedNow().UTC().Format("2006-01-02") {
		t.Fatalf("journaled window_date=%q want the admission-time window %q",
			effect.WindowDate, fixedNow().UTC().Format("2006-01-02"))
	}

	// RECOVERY: a second Server over the SAME store (no spy — the pathology cleared) and
	// the SAME journal directory, running exactly what cmd/gateway runs at startup and on
	// its ticker.
	recovered := New(cfg, store, fakeOAuth{}, WithNow(fixedNow), WithSettlementJournal(jnl))
	summary, err := recovered.RecoverSettlementJournal(context.Background(), 0)
	if err != nil {
		t.Fatalf("RecoverSettlementJournal: %v", err)
	}
	if summary.Recovered != 1 || summary.Quarantined != 0 || summary.Errors != 0 {
		t.Fatalf("recovery summary=%+v want recovered=1 quarantined=0 errors=0", summary)
	}

	after := gatewaySettlementSnapshot(t, dbPath, "acct_h7")
	if after.usageRows != 1 {
		t.Fatalf("REGRESSION (INV-8): after recovery usageRows=%d want 1 — the delivered request is "+
			"still unbilled, which is the whole finding", after.usageRows)
	}
	if used := billedTokens(t, h, key); used != 20 {
		t.Fatalf("recovered bill=%v want 20 (the tokens the buyer actually received)", used)
	}
	if after.refundedRows != 1 {
		t.Fatalf("state=%+v want the original refund to STAND — recovery restores the audit row via the "+
			"§ 17.7 fallback, it does not resurrect the reservation", after)
	}
	sealResult := ""
	for _, rec := range journalRecords(t, jnl.Dir()) {
		if rec.Kind == journal.KindSeal && rec.RequestID == "77777777-7777-4777-8777-777777777777" {
			sealResult = rec.Result
		}
	}
	if sealResult != journal.SealUsageEvent {
		t.Fatalf("seal result=%q want %q", sealResult, journal.SealUsageEvent)
	}

	// IDEMPOTENCE: recovery runs on a ticker, so a second pass is the normal case.
	second, err := recovered.RecoverSettlementJournal(context.Background(), 0)
	if err != nil {
		t.Fatalf("second RecoverSettlementJournal: %v", err)
	}
	if second.Recovered != 0 || second.Scanned != 0 {
		t.Fatalf("second pass summary=%+v want a no-op", second)
	}
	if rows, total := usageTokenTotals(t, dbPath, "acct_h7"); rows != 1 || total != 20 {
		t.Fatalf("DOUBLE BILL on the second recovery pass: rows=%d total=%d", rows, total)
	}
	t.Logf("PASS (P1-2 FIXED, #763): the settlement double-failure still drops the row in-band, but "+
		"the effect journaled before the attempt let a later pass restore it — usageRows=1, billed=20, "+
		"refund intact, seal=%q, second pass a no-op.", sealResult)
}

// settleFailSpyStore forces the settleAfterCommit double-failure branch: SettleReservation
// fails, then the EnsureUsageEvent fallback also fails → the gateway logs, refunds
// (delegated to the real store), and drops the audit row. ReserveQuota + RefundReservation
// are inherited from the embedded *sqlite.Store so the reservation is created then refunded.
type settleFailSpyStore struct {
	*sqlite.Store
}

func (s *settleFailSpyStore) SettleReservation(context.Context, storage.ReservationSettlement) error {
	return errors.New("injected settle failure (H7)")
}

func (s *settleFailSpyStore) EnsureUsageEvent(context.Context, storage.UsageEvent) error {
	return errors.New("injected usage-event fallback failure (H7)")
}
