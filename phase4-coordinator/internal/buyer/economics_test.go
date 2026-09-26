package buyer

import (
	"context"
	"database/sql"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/rs/zerolog"
)

// SPEC-005-R013 I2 (C1): request pricing and the served signed rate card
// switch in one economicsMu hold.

type econGen struct {
	name  string
	cfg   config.RewardsConfig
	id    int64
	feeds AutotuneFeeds
}

func econRewards(prompt, completion int64) config.RewardsConfig {
	return config.RewardsConfig{
		GlobalMultiplier: 1.0,
		ProviderShare:    0.90,
		RateCard: map[string]config.RateCardEntry{
			"default": {PromptCreditsPerMtok: 1, CompletionCreditsPerMtok: 1},
			"model-a": {PromptCreditsPerMtok: prompt, CompletionCreditsPerMtok: completion},
		},
	}
}

func econFeeds(name string) AutotuneFeeds {
	return AutotuneFeeds{RateCardJSON: []byte(`{"generation":"` + name + `"}`), RateCardSig: []byte("sig-" + name)}
}

type econHarness struct {
	server *Server
	store  *billing.Store
	db     *sql.DB
	gens   map[string]econGen
	nextIP atomic.Int64
}

// newGen commits a billing generation exactly as a reload does (snapshot
// COMMIT first); publishing it is the caller's step.
func (h *econHarness) newGen(t *testing.T, name string, prompt, completion int64) econGen {
	t.Helper()
	cfg := econRewards(prompt, completion)
	id, err := h.store.ReloadBillingConfigV05(context.Background(), cfg, false, false, 0, "sighup", time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	g := econGen{name: name, cfg: cfg, id: id, feeds: econFeeds(fmt.Sprintf("%s-%d", name, id))}
	h.gens[g.feeds.rateCardMarker()] = g
	return g
}

func (f AutotuneFeeds) rateCardMarker() string { return string(f.RateCardJSON) }

func (h *econHarness) publish(g econGen) {
	h.server.PublishEconomics(g.cfg, g.id, 1.0, &g.feeds)
}

func newEconHarness(t *testing.T, opts ...Option) (*econHarness, econGen) {
	t.Helper()
	reqLog, _ := h4OpenRequestLog(t)
	store, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatal(err)
	}
	h := &econHarness{store: store, db: reqLog.DB(), gens: map[string]econGen{}}
	a := h.newGen(t, "A", 1_000_000, 2_000_000)
	registry := pool.NewRegistry(nil)
	registry.Register(&pool.Provider{
		ProviderID: "p1", AssignedID: "s1", Hostname: "p1.local", ModelID: "model-a", ModelParamsB: 7, RAMGB: 16,
		MaxContextTokens: 20000, MaxConcurrency: 64, SlotsFree: 64, SlotsTotal: 64, ThroughputTPSEstimate: 30,
		Tier: pool.TierProvisional, InferencePath: pool.InferencePathWSTunneled, State: pool.StateReady,
		LastHeartbeatAt: time.Now().UTC(), ConnectedAt: time.Now().UTC(), BinaryVersion: "0.1.0",
	}, nil)
	base := []Option{
		WithRequestLog(reqLog),
		WithBilling(store, a.cfg),
		WithBillingSnapshotID(a.id),
		WithRateCardUSDPerMillionCredits(1.0),
		WithAutotuneFeeds(a.feeds),
		WithRoutingConfig(config.RoutingConfig{MaxRetries: 0, StickyTTLS: 1800, StickyMaxEntries: 10000}),
		WithRelay(h4RelaySuccess(), 5*time.Second),
	}
	h.server = NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), append(base, opts...)...)
	return h, a
}

// pricing is what a request recorded now would be billed at.
func (h *econHarness) pricing() (int64, int64) {
	snap := h.server.economicsSnapshotForModel("model-a")
	return snap.rateEntry.PromptCreditsPerMtok, snap.snapshotID
}

func (h *econHarness) rateCard(t *testing.T, path string) string {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	n := h.nextIP.Add(1)
	req.RemoteAddr = fmt.Sprintf("10.%d.%d.%d:4000", (n>>16)&0xff, (n>>8)&0xff, n&0xff)
	rr := httptest.NewRecorder()
	h.server.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Errorf("%s status=%d body=%s", path, rr.Code, rr.Body.String())
	}
	return rr.Body.String()
}

// assertServing checks that pricing and both rate-card endpoints serve g.
func (h *econHarness) assertServing(t *testing.T, g econGen) {
	t.Helper()
	prompt, id := h.pricing()
	if prompt != g.cfg.RateCard["model-a"].PromptCreditsPerMtok || id != g.id {
		t.Fatalf("pricing=%d/snapshot %d want generation %s (%d/snapshot %d)", prompt, id, g.name, g.cfg.RateCard["model-a"].PromptCreditsPerMtok, g.id)
	}
	if body := h.rateCard(t, "/v1/rate-card"); body != string(g.feeds.RateCardJSON) {
		t.Fatalf("rate card=%s want %s", body, g.feeds.RateCardJSON)
	}
	if sig := h.rateCard(t, "/v1/rate-card.sig"); sig != string(g.feeds.RateCardSig) {
		t.Fatalf("rate card sig=%s want %s", sig, g.feeds.RateCardSig)
	}
}

// chat runs one billed buyer request and returns its credited rate and the
// config_snapshot_id its identity row links.
func (h *econHarness) chat(t *testing.T) (int64, int64) {
	t.Helper()
	rate, snapshot, err := h.chatErr(t)
	if err != nil {
		t.Fatal(err)
	}
	return rate, snapshot
}

// chatErr is chat for use off the test goroutine.
func (h *econHarness) chatErr(t *testing.T) (int64, int64, error) {
	rr := h4PostChat(t, h.server, []byte(h4ChatBody))
	if rr.Code != http.StatusOK {
		return 0, 0, fmt.Errorf("chat status=%d body=%s", rr.Code, rr.Body.String())
	}
	var rate, snapshot int64
	err := h.db.QueryRow(`
SELECT lrc.prompt_rate_per_mtok, lpis.config_snapshot_id
  FROM ledger_request_credits lrc
  JOIN ledger_provider_identity_snapshots lpis
    ON lpis.request_id = lrc.request_id AND lpis.attempt_n = lrc.attempt_n AND lpis.provider_assigned_id = lrc.provider_assigned_id
 ORDER BY lrc.id DESC LIMIT 1`).Scan(&rate, &snapshot)
	return rate, snapshot, err
}

func waitClosed(t *testing.T, ch <-chan struct{}, what string) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(5 * time.Second):
		t.Fatalf("timed out waiting for %s", what)
	}
}

func assertStillBlocked(t *testing.T, ch <-chan struct{}, what string) {
	t.Helper()
	select {
	case <-ch:
		t.Fatalf("%s completed while the economics lock was held", what)
	case <-time.After(150 * time.Millisecond):
	}
}

func TestEconomicsResolutionCannotStraddleAPublication(t *testing.T) {
	h, a := newEconHarness(t)
	b := h.newGen(t, "B", 3_000_000, 5_000_000)
	entered, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	economicsResolveHookForTest = func() {
		once.Do(func() {
			close(entered)
			<-release
		})
	}
	t.Cleanup(func() { economicsResolveHookForTest = nil })

	type result struct{ prompt, id int64 }
	read := make(chan result, 1)
	go func() {
		prompt, id := h.pricing()
		read <- result{prompt, id}
	}()
	waitClosed(t, entered, "reader inside its resolution")
	published := make(chan struct{})
	go func() {
		h.publish(b)
		close(published)
	}()
	assertStillBlocked(t, published, "publication")
	close(release)
	got := <-read
	if got.prompt != a.cfg.RateCard["model-a"].PromptCreditsPerMtok || got.id != a.id {
		t.Fatalf("straddling read=%+v want all of generation A (%d)", got, a.id)
	}
	waitClosed(t, published, "publication")
	h.assertServing(t, b)
}

func TestEconomicsPublicationSwitchesPricingAndRateCardTogether(t *testing.T) {
	h, a := newEconHarness(t)
	b := h.newGen(t, "B", 3_000_000, 5_000_000)
	h.assertServing(t, a)

	inside, release := make(chan struct{}), make(chan struct{})
	published := make(chan struct{})
	go func() {
		h.server.publishAutotuneFeeds(b.feeds, func() {
			h.server.setBillingConfigLocked(b.cfg, b.id, 1.0)
			close(inside)
			<-release
		})
		close(published)
	}()
	waitClosed(t, inside, "phase 2")
	priced, carded := make(chan struct{}), make(chan struct{})
	var prompt, id int64
	var card string
	go func() {
		prompt, id = h.pricing()
		close(priced)
	}()
	go func() {
		card = h.rateCard(t, "/v1/rate-card")
		close(carded)
	}()
	assertStillBlocked(t, priced, "pricing read")
	assertStillBlocked(t, carded, "rate-card read")
	close(release)
	waitClosed(t, priced, "pricing read")
	waitClosed(t, carded, "rate-card read")
	waitClosed(t, published, "publication")
	if prompt != b.cfg.RateCard["model-a"].PromptCreditsPerMtok || id != b.id || card != string(b.feeds.RateCardJSON) {
		t.Fatalf("reads blocked by phase 2 saw %d/%d/%s, want generation B", prompt, id, card)
	}
	h.assertServing(t, b)
}

// Phase 1 (identity-set build) and the wait for the release write lock — held
// by a release reader stuck in a store call — happen before economicsMu is
// taken: pricing, rate-card reads and billing inserts keep flowing at the
// prior generation. This is the lock order release → economics.
func TestEconomicsReadersNeverWaitForPhaseOneOrTheReleaseLock(t *testing.T) {
	var releaseMu sync.RWMutex
	preparing, finishPreparation := make(chan struct{}), make(chan struct{})
	observer := func(feeds AutotuneFeeds, commit func()) {
		close(preparing)
		<-finishPreparation
		releaseMu.Lock()
		commit()
		releaseMu.Unlock()
	}
	h, a := newEconHarness(t, WithAutotuneFeedsObserver(observer))
	b := h.newGen(t, "B", 3_000_000, 5_000_000)

	published := make(chan struct{})
	go func() {
		h.publish(b)
		close(published)
	}()
	waitClosed(t, preparing, "phase 1")
	h.assertServing(t, a)
	if rate, snapshot := h.chat(t); rate != 1_000_000 || snapshot != a.id {
		t.Fatalf("billing during phase 1 = %d/%d want A", rate, snapshot)
	}

	releaseMu.RLock() // a release reader blocked in a store call
	close(finishPreparation)
	assertStillBlocked(t, published, "publication behind the release reader")
	h.assertServing(t, a)
	if rate, snapshot := h.chat(t); rate != 1_000_000 || snapshot != a.id {
		t.Fatalf("billing while phase 2 waits for the release lock = %d/%d want A", rate, snapshot)
	}
	releaseMu.RUnlock()
	waitClosed(t, published, "publication")
	h.assertServing(t, b)
}

func TestEconomicsBlockedPostPublishSweepDoesNotBlockReaders(t *testing.T) {
	sweeping, finishSweep := make(chan struct{}), make(chan struct{})
	observer := func(feeds AutotuneFeeds, commit func()) {
		commit()
		close(sweeping) // afterReleasePublished runs after every lock is released
		<-finishSweep
	}
	h, _ := newEconHarness(t, WithAutotuneFeedsObserver(observer))
	b := h.newGen(t, "B", 3_000_000, 5_000_000)
	published := make(chan struct{})
	go func() {
		h.publish(b)
		close(published)
	}()
	waitClosed(t, sweeping, "post-publish sweep")
	h.assertServing(t, b)
	if rate, snapshot := h.chat(t); rate != 3_000_000 || snapshot != b.id {
		t.Fatalf("billing during the sweep = %d/%d want B", rate, snapshot)
	}
	close(finishSweep)
	waitClosed(t, published, "publication")
}

// The recorder resolves pricing before its 6 s write deadline starts: a
// request that waited for a publication still gets the whole budget.
func TestEconomicsWaitDoesNotShortenTheBillingWriteDeadline(t *testing.T) {
	h, _ := newEconHarness(t)
	b := h.newGen(t, "B", 3_000_000, 5_000_000)
	deadlines := make(chan time.Time, 4)
	prev := hotPathWriteContextForTest
	hotPathWriteContextForTest = func(attempt int, ctx context.Context) context.Context {
		if deadline, ok := ctx.Deadline(); ok && attempt == 1 {
			deadlines <- deadline
		}
		return ctx
	}
	t.Cleanup(func() { hotPathWriteContextForTest = prev })

	inside, release := make(chan struct{}), make(chan struct{})
	go h.server.publishAutotuneFeeds(b.feeds, func() {
		h.server.setBillingConfigLocked(b.cfg, b.id, 1.0)
		close(inside)
		<-release
	})
	waitClosed(t, inside, "phase 2")
	type chatResult struct {
		rate, snapshot int64
		err            error
	}
	done := make(chan chatResult, 1)
	go func() {
		rate, snapshot, err := h.chatErr(t)
		done <- chatResult{rate, snapshot, err}
	}()
	time.Sleep(300 * time.Millisecond)
	var rows int
	if err := h.db.QueryRow(`SELECT COUNT(*) FROM request_log`).Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 0 {
		t.Fatalf("request_log rows=%d while pricing is blocked, want 0", rows)
	}
	releasedAt := time.Now()
	close(release)
	got := <-done
	if got.err != nil {
		t.Fatal(got.err)
	}
	if got.rate != 3_000_000 || got.snapshot != b.id {
		t.Fatalf("billed %d/%d want B", got.rate, got.snapshot)
	}
	deadline := <-deadlines
	if deadline.Before(releasedAt.Add(requestLogWriteTimeout)) {
		t.Fatalf("write deadline %s started before pricing resolved at %s (budget %s)", deadline, releasedAt, requestLogWriteTimeout)
	}
}

type blockingResponseWriter struct {
	header  http.Header
	writing chan struct{}
	unblock chan struct{}
	once    sync.Once
}

func (w *blockingResponseWriter) Header() http.Header { return w.header }
func (w *blockingResponseWriter) WriteHeader(int)     {}
func (w *blockingResponseWriter) Write(p []byte) (int, error) {
	w.once.Do(func() { close(w.writing) })
	<-w.unblock
	return len(p), nil
}

func TestEconomicsSlowRateCardClientDoesNotDelayPublication(t *testing.T) {
	h, _ := newEconHarness(t)
	b := h.newGen(t, "B", 3_000_000, 5_000_000)
	for _, path := range []string{"/v1/rate-card", "/v1/rate-card.sig"} {
		w := &blockingResponseWriter{header: http.Header{}, writing: make(chan struct{}), unblock: make(chan struct{})}
		req := httptest.NewRequest(http.MethodGet, path, nil)
		req.RemoteAddr = "192.0.2.77:4000"
		served := make(chan struct{})
		go func() {
			h.server.Handler().ServeHTTP(w, req)
			close(served)
		}()
		waitClosed(t, w.writing, path+" response write")
		published := make(chan struct{})
		go func() {
			h.publish(b)
			close(published)
		}()
		waitClosed(t, published, "publication while "+path+" is writing")
		close(w.unblock)
		waitClosed(t, served, path)
	}
	h.assertServing(t, b)
}

func TestEconomicsForwardAndReversalBillAndServeTheSameGeneration(t *testing.T) {
	h, a := newEconHarness(t)
	b := h.newGen(t, "B", 3_000_000, 5_000_000)
	for _, g := range []econGen{a, b, h.newGen(t, "A-rollback", 1_000_000, 2_000_000)} {
		h.publish(g)
		h.assertServing(t, g)
		if rate, snapshot := h.chat(t); rate != g.cfg.RateCard["model-a"].PromptCreditsPerMtok || snapshot != g.id {
			t.Fatalf("generation %s billed %d/snapshot %d want %d/%d", g.name, rate, snapshot, g.cfg.RateCard["model-a"].PromptCreditsPerMtok, g.id)
		}
	}
}

// Every provider-bound request row links a published snapshot id and is
// priced at exactly that snapshot's table, under concurrent publications.
func TestEconomicsEveryBilledRowLinksAPublishedGeneration(t *testing.T) {
	h, a := newEconHarness(t)
	published := map[int64]econGen{a.id: a}
	var publishedMu sync.Mutex
	stop := make(chan struct{})
	publisherDone := make(chan struct{})
	gens := []econGen{h.newGen(t, "B", 3_000_000, 5_000_000), h.newGen(t, "C", 7_000_000, 11_000_000), h.newGen(t, "A2", 1_000_000, 2_000_000)}
	go func() {
		defer close(publisherDone)
		for i := 0; ; i++ {
			select {
			case <-stop:
				return
			default:
			}
			g := gens[i%len(gens)]
			publishedMu.Lock()
			published[g.id] = g
			publishedMu.Unlock()
			h.publish(g)
		}
	}()
	var wg sync.WaitGroup
	for i := 0; i < 24; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			rr := h4PostChat(t, h.server, []byte(h4ChatBody))
			_, _ = io.Copy(io.Discard, rr.Result().Body)
			card := h.rateCard(t, "/v1/rate-card")
			if _, ok := h.gens[card]; !ok {
				t.Errorf("served rate card %q is not a published generation", card)
			}
		}()
	}
	wg.Wait()
	close(stop)
	<-publisherDone

	rows, err := h.db.Query(`
SELECT lrc.prompt_rate_per_mtok, lrc.completion_rate_per_mtok, lpis.config_snapshot_id
  FROM ledger_request_credits lrc
  LEFT JOIN ledger_provider_identity_snapshots lpis
    ON lpis.request_id = lrc.request_id AND lpis.attempt_n = lrc.attempt_n AND lpis.provider_assigned_id = lrc.provider_assigned_id`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	n := 0
	for rows.Next() {
		var prompt, completion int64
		var snapshot sql.NullInt64
		if err := rows.Scan(&prompt, &completion, &snapshot); err != nil {
			t.Fatal(err)
		}
		n++
		g, ok := published[snapshot.Int64]
		if !snapshot.Valid || !ok {
			t.Fatalf("credited row links snapshot %v, not a published generation", snapshot)
		}
		entry := g.cfg.RateCard["model-a"]
		if prompt != entry.PromptCreditsPerMtok || completion != entry.CompletionCreditsPerMtok {
			t.Fatalf("row linked to %s (%d) priced %d/%d want %d/%d", g.name, g.id, prompt, completion, entry.PromptCreditsPerMtok, entry.CompletionCreditsPerMtok)
		}
	}
	if n == 0 {
		t.Fatal("no credited rows")
	}
}

// #1095 moved with the resolution: the served alias bills its normalized row.
func TestEconomicsSnapshotResolvesServedAliasToNormalizedRow(t *testing.T) {
	cfg := econRewards(1, 1)
	cfg.RateCard["qwen3-8b"] = config.RateCardEntry{PromptCreditsPerMtok: 13500, CompletionCreditsPerMtok: 27000}
	s := NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Unix(1716768000, 0), WithBilling(nil, cfg), WithBillingSnapshotID(7))
	snap := s.economicsSnapshotForModel("mlx-community/Qwen3-8B-4bit")
	if snap.rateEntry != cfg.RateCard["qwen3-8b"] || snap.snapshotID != 7 || snap.multiplierPPM != 1_000_000 || snap.providerShareBps != 9000 {
		t.Fatalf("snapshot=%+v", snap)
	}
}

// Rule: economics readers take nothing but economicsMu, billingMu and
// autotuneFeedsMu, so they can never wait behind a ws release reader (and ws
// cannot call into buyer: buyer imports ws). A reader that grows a call
// outside this allowlist must be re-reviewed against the lock order.
func TestEconomicsReadersOnlyTakeEconomicsBillingAndFeedLocks(t *testing.T) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "economics.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	allowed := map[string]bool{
		"RLock": true, "RUnlock": true, "billingState": true, "autotuneFeedsSnapshot": true,
		"recommendationRateCardState": true, "RateFor": true, "ParseMultiplierPPM": true, "ParseShareBps": true,
		"RateTableDigest": true, "Sum256": true, "EncodeToString": true, "rateCardEnabled": true,
		"autotuneCandidatesEnabled": true, "hook": true,
	}
	readers := map[string]bool{"economicsSnapshotForModel": false, "rateCardServeSnapshot": false, "AppliedEconomics": false}
	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok {
			continue
		}
		if _, isReader := readers[fn.Name.Name]; !isReader {
			continue
		}
		readers[fn.Name.Name] = true
		ast.Inspect(fn.Body, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			var name string
			switch f := call.Fun.(type) {
			case *ast.Ident:
				name = f.Name
			case *ast.SelectorExpr:
				name = f.Sel.Name
			}
			if !allowed[name] {
				t.Errorf("%s calls %s: not on the economics-reader allowlist", fn.Name.Name, name)
			}
			return true
		})
	}
	for name, seen := range readers {
		if !seen {
			t.Errorf("economics reader %s not found", name)
		}
	}
}

// The reader never falls back to a later RateFor: the hot path bills the
// entry resolved here even if the request's model would resolve differently
// against the table in force at write time.
func TestHotPathBillsTheResolvedEntryWithoutReResolving(t *testing.T) {
	reqLog, _ := h4OpenRequestLog(t)
	store, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatal(err)
	}
	prompt, completion := int64(10), int64(10)
	row := requestlog.Row{TSUtc: time.Now().UTC(), RequestID: "req-resolved", Model: "model-a", ProviderAssignedID: "s1", PromptTokens: &prompt, CompletionTokens: &completion, Status: 200, BuyerIP: "127.0.0.1"}
	resolved := config.RateCardEntry{PromptCreditsPerMtok: 111, CompletionCreditsPerMtok: 222}
	in := billing.HotPathInput{
		RequestID: row.RequestID, ProviderAssignedID: "s1", ProviderID: "p1", Model: "model-a", Status: 200, TSUtc: row.TSUtc,
		PromptTokens: &prompt, CompletionTokens: &completion, RateEntry: resolved,
		RateCard:      map[string]config.RateCardEntry{"model-a": {PromptCreditsPerMtok: 999, CompletionCreditsPerMtok: 999}},
		MultiplierPPM: 1_000_000, ProviderShareBps: 9000,
	}
	if err := store.WriteHotPath(context.Background(), reqLog, row, in); err != nil {
		t.Fatal(err)
	}
	var p, c int64
	if err := reqLog.DB().QueryRow(`SELECT prompt_rate_per_mtok, completion_rate_per_mtok FROM ledger_request_credits WHERE request_id = ?`, row.RequestID).Scan(&p, &c); err != nil {
		t.Fatal(err)
	}
	if p != 111 || c != 222 {
		t.Fatalf("hot path billed %d/%d, want the resolved entry 111/222", p, c)
	}
}
