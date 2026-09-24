package billing

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"math"
	"math/big"
	"math/rand"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

// ---- RateTableDigest (SPEC-005-R013: one digest for snapshot, validator, record)

func TestRateTableDigestIsDigestOfStoredSnapshotBytes(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	cfg.RateCard["mlx-community/Qwen3-8B-4bit"] = RateCardEntry{PromptCreditsPerMtok: 13500, CompletionCreditsPerMtok: 27000}
	want, err := RateTableDigest(cfg)
	if err != nil {
		t.Fatal(err)
	}
	bootID, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Unix(100, 0).UTC())
	if err != nil {
		t.Fatal(err)
	}
	reloadID, err := store.ReloadBillingConfigV05(context.Background(), cfg, false, false, 0, "sighup", time.Unix(200, 0).UTC())
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []int64{bootID, reloadID} {
		var stored string
		if err := store.db.QueryRow(`SELECT rate_card_json FROM ledger_config_snapshots WHERE id = ?`, id).Scan(&stored); err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256([]byte(stored))
		if got := hex.EncodeToString(sum[:]); got != want {
			t.Fatalf("snapshot %d rate_card_json sha256=%s, RateTableDigest=%s", id, got, want)
		}
	}
	changed := testRewards()
	changed.RateCard["model-a"] = RateCardEntry{PromptCreditsPerMtok: 1000001, CompletionCreditsPerMtok: 2000000}
	if other, _ := RateTableDigest(changed); other == want {
		t.Fatal("RateTableDigest did not change with a row credit")
	}
}

// ---- RateKeyFor is RateFor plus the matched key

func TestRateKeyForResolvesExactlyLikeRateFor(t *testing.T) {
	table := map[string]RateCardEntry{
		"default":                          {PromptCreditsPerMtok: 1, CompletionCreditsPerMtok: 2},
		"qwen3-8b":                         {PromptCreditsPerMtok: 3, CompletionCreditsPerMtok: 4},
		"meta-llama/llama-3.2-3b-instruct": {PromptCreditsPerMtok: 5, CompletionCreditsPerMtok: 6},
		"Exact-Case":                       {PromptCreditsPerMtok: 7, CompletionCreditsPerMtok: 8},
	}
	cases := map[string]string{
		"qwen3-8b":                                 "qwen3-8b",
		"mlx-community/Qwen3-8B-4bit":              "qwen3-8b",
		"mlx-community/Llama-3.2-3B-Instruct-4bit": "meta-llama/llama-3.2-3b-instruct",
		"Exact-Case":                               "Exact-Case",
		"unknown/model":                            "default",
		"":                                         "default",
		"bad\x00name\x7f":                          "default",
	}
	for name, wantKey := range cases {
		key, entry := RateKeyFor(table, name)
		if key != wantKey || entry != RateFor(table, name) {
			t.Fatalf("RateKeyFor(%q)=%q/%+v want %q/%+v", name, key, entry, wantKey, RateFor(table, name))
		}
	}
	delete(table, "default")
	if key, entry := RateKeyFor(table, "unknown/model"); key != "" || entry != RateFor(table, "unknown/model") {
		t.Fatalf("no default: RateKeyFor=%q/%+v", key, entry)
	}
	if key, entry := RateKeyFor(nil, "qwen3-8b"); key != "" || entry != (RateCardEntry{}) {
		t.Fatalf("nil table: RateKeyFor=%q/%+v", key, entry)
	}
}

// ---- WholesaleGross

func TestWholesaleGrossEqualsComputeCreditsWithinRequestLimits(t *testing.T) {
	rng := rand.New(rand.NewSource(1693))
	for i := 0; i < 20000; i++ {
		prompt := rng.Int63n(maxBillableTokens + 1)
		completion := rng.Int63n(maxBillableTokens + 1)
		rate := RateCardEntry{PromptCreditsPerMtok: rng.Int63n(5_000_000), CompletionCreditsPerMtok: rng.Int63n(5_000_000)}
		multiplier := rng.Int63n(3_000_000)
		if i%7 == 0 {
			multiplier = globalMultiplierDenom
		}
		want := ComputeCredits(&prompt, &completion, nil, UsageProviderReported, FaultNone, rate, multiplier, 9000)
		if want.FaultFlag != FaultNone {
			continue
		}
		got, err := WholesaleGross(big.NewInt(prompt), big.NewInt(completion), rate, multiplier)
		if err != nil || got != want.GrossCredits {
			t.Fatalf("case %d prompt=%d completion=%d rate=%+v mult=%d: WholesaleGross=%d,%v ComputeCredits=%d", i, prompt, completion, rate, multiplier, got, err, want.GrossCredits)
		}
	}
}

func TestWholesaleGrossRoundsHalfEvenAndIsUncapped(t *testing.T) {
	one := func(v int64) *big.Int { return big.NewInt(v) }
	rate := RateCardEntry{PromptCreditsPerMtok: 1, CompletionCreditsPerMtok: 0}
	// numerator / 1e12: 0.5 → 0, 1.5 → 2, 2.5 → 2, 2.5000001 → 3.
	for _, c := range []struct {
		prompt, multiplier int64
		want               int64
	}{
		{500_000, 1_000_000, 0},
		{1_500_000, 1_000_000, 2},
		{2_500_000, 1_000_000, 2},
		{2_500_001, 1_000_000, 3},
	} {
		got, err := WholesaleGross(one(c.prompt), one(0), rate, c.multiplier)
		if err != nil || got != c.want {
			t.Fatalf("prompt=%d: got %d,%v want %d", c.prompt, got, err, c.want)
		}
	}
	// Above the per-request 10M cap ComputeCredits zeroes; the aggregate is owed.
	big20M := int64(20_000_000)
	capped := ComputeCredits(&big20M, &big20M, nil, UsageProviderReported, FaultNone, RateCardEntry{PromptCreditsPerMtok: 13500, CompletionCreditsPerMtok: 27000}, globalMultiplierDenom, 9000)
	if capped.GrossCredits != 0 {
		t.Fatalf("precondition: ComputeCredits above cap gross=%d want 0", capped.GrossCredits)
	}
	got, err := WholesaleGross(one(big20M), one(big20M), RateCardEntry{PromptCreditsPerMtok: 13500, CompletionCreditsPerMtok: 27000}, globalMultiplierDenom)
	if err != nil || got != 20*13500+20*27000 {
		t.Fatalf("uncapped gross=%d,%v want %d", got, err, 20*13500+20*27000)
	}
	if _, err := WholesaleGross(one(math.MaxInt64), one(0), RateCardEntry{PromptCreditsPerMtok: math.MaxInt64}, math.MaxInt64); !errors.Is(err, ErrWholesaleGrossOverflow) {
		t.Fatalf("overflow err=%v want ErrWholesaleGrossOverflow", err)
	}
	if _, err := WholesaleGross(one(-1), one(0), rate, globalMultiplierDenom); !errors.Is(err, ErrWholesaleGrossNegative) {
		t.Fatalf("negative err=%v want ErrWholesaleGrossNegative", err)
	}
}

// ---- one attempt-ordinal expression for every reader (hotpath.go documents they must agree)

func TestAttemptOrdinalSQLHasOneDefinitionUsedByEveryReader(t *testing.T) {
	fset := token.NewFileSet()
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	users := map[string]int{}
	for _, name := range files {
		if strings.HasSuffix(name, "_test.go") {
			continue
		}
		raw, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		if name != "attempt_ordinal.go" && strings.Contains(string(raw), "COUNT(*) - 1 FROM request_log") {
			t.Fatalf("%s carries an inline attempt-ordinal copy; use requestLogAttemptOrdinalSQL", name)
		}
		file, err := parser.ParseFile(fset, name, raw, 0)
		if err != nil {
			t.Fatal(err)
		}
		ast.Inspect(file, func(n ast.Node) bool {
			if call, ok := n.(*ast.CallExpr); ok {
				if id, ok := call.Fun.(*ast.Ident); ok && id.Name == "requestLogAttemptOrdinalSQL" {
					users[name]++
				}
			}
			return true
		})
	}
	for name, want := range map[string]int{"recovery.go": 2, "endpoints.go": 1, "wholesale_generation.go": 1} {
		if users[name] != want {
			t.Fatalf("%s uses requestLogAttemptOrdinalSQL %d times, want %d (all users: %v)", name, users[name], want, users)
		}
	}
}

func TestAttemptOrdinalSQLMatchesHotPathDerivationForLegacyNullRows(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	ts := time.Date(2026, 9, 3, 0, 0, 0, 0, time.UTC)
	// Rows of one request (and one of another account) inserted in order; the
	// hot path derives each row's ordinal as COUNT(*)-1 right after insert.
	type insert struct{ account, request string }
	inserts := []insert{{"acct-a", "req-o"}, {"acct-a", "req-o"}, {"acct-b", "req-o"}, {"acct-a", "req-o"}, {"", "req-o"}, {"", "req-o"}}
	want := map[int64]int64{}
	for _, in := range inserts {
		if err := reqStore.Insert(ctx, requestlog.Row{TSUtc: ts, RequestID: in.request, AccountID: in.account, Model: "model-a", Status: 200, BuyerIP: "127.0.0.1"}); err != nil {
			t.Fatal(err)
		}
		var id, count int64
		var account any
		if in.account != "" {
			account = in.account
		}
		if err := store.db.QueryRow(`SELECT MAX(id) FROM request_log`).Scan(&id); err != nil {
			t.Fatal(err)
		}
		if err := store.db.QueryRow(`SELECT COUNT(*) FROM request_log WHERE account_id IS ? AND request_id = ?`, account, in.request).Scan(&count); err != nil {
			t.Fatal(err)
		}
		want[id] = count - 1
	}
	if _, err := store.db.Exec(`UPDATE request_log SET attempt_n = NULL`); err != nil {
		t.Fatal(err)
	}
	rows, err := store.db.Query(`SELECT rl.id, ` + requestLogAttemptOrdinalSQL("rl") + `, ` + requestLogIDOrdinalSQL("rl") + ` FROM request_log rl`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var id, ordinal, idOrdinal int64
		if err := rows.Scan(&id, &ordinal, &idOrdinal); err != nil {
			t.Fatal(err)
		}
		if ordinal != want[id] || idOrdinal != want[id] {
			t.Fatalf("row %d ordinal=%d id_ordinal=%d want hot-path %d", id, ordinal, idOrdinal, want[id])
		}
	}
}

// ---- W1: wholesale statements price every row at its own generation

const wsAccount = "acct_wholesale"

func wsRewards(prompt, completion int64, multiplier float64) RewardsConfig {
	return RewardsConfig{
		GlobalMultiplier: multiplier,
		ProviderShare:    0.90,
		RateCard: map[string]RateCardEntry{
			"default":                          {PromptCreditsPerMtok: 500000, CompletionCreditsPerMtok: 1000000},
			"meta-llama/llama-3.2-3b-instruct": {PromptCreditsPerMtok: prompt, CompletionCreditsPerMtok: completion},
		},
	}
}

// wsSnapshot commits cfg as a billing generation effective at `at`.
func wsSnapshot(t *testing.T, store *Store, cfg RewardsConfig, at time.Time) int64 {
	t.Helper()
	id, err := store.ReloadBillingConfigV05(context.Background(), cfg, false, false, 0, "sighup", at)
	if err != nil {
		t.Fatal(err)
	}
	return id
}

// wsPriced writes one provider-bound request through the hot path, priced at
// generation (cfg, snapshotID) exactly as the buyer recorder would.
func wsPriced(t *testing.T, reqStore *requestlog.Store, store *Store, requestID, model string, ts time.Time, prompt, completion int64, cfg RewardsConfig, snapshotID int64) {
	t.Helper()
	row := requestlog.Row{
		TSUtc: ts, RequestID: requestID, AccountID: wsAccount, Model: model, ProviderAssignedID: "assigned-" + requestID,
		PromptTokens: &prompt, CompletionTokens: &completion, Status: 200, BuyerIP: "127.0.0.1",
	}
	in := HotPathInput{
		RequestID: requestID, ProviderAssignedID: row.ProviderAssignedID, ProviderID: "provider-a", Model: model,
		Status: 200, TSUtc: ts, PromptTokens: &prompt, CompletionTokens: &completion,
		ConfigSnapshotID: snapshotID, RateEntry: RateFor(cfg.RateCard, model),
		MultiplierPPM: ParseMultiplierPPM(cfg.GlobalMultiplier), ProviderShareBps: ParseShareBps(cfg.ProviderShare),
	}
	if err := store.WriteHotPath(context.Background(), reqStore, row, in); err != nil {
		t.Fatal(err)
	}
}

// wsPricedAttempt is wsPriced for an explicit attempt: request_log persists
// rowAttempt and the hot path writes attemptN.
func wsPricedAttempt(t *testing.T, reqStore *requestlog.Store, store *Store, requestID string, rowAttempt, attemptN int, ts time.Time, prompt, completion int64, cfg RewardsConfig, snapshotID int64) {
	t.Helper()
	row := requestlog.Row{
		TSUtc: ts, RequestID: requestID, AccountID: wsAccount, Model: wsModel, ProviderAssignedID: "assigned-" + requestID,
		PromptTokens: &prompt, CompletionTokens: &completion, Status: 200, BuyerIP: "127.0.0.1", AttemptN: &rowAttempt, Retried: 1,
	}
	in := HotPathInput{
		RequestID: requestID, AttemptN: attemptN, ProviderAssignedID: row.ProviderAssignedID, ProviderID: "provider-a", Model: wsModel,
		Status: 200, TSUtc: ts, PromptTokens: &prompt, CompletionTokens: &completion,
		ConfigSnapshotID: snapshotID, RateEntry: RateFor(cfg.RateCard, wsModel),
		MultiplierPPM: ParseMultiplierPPM(cfg.GlobalMultiplier), ProviderShareBps: ParseShareBps(cfg.ProviderShare),
	}
	if err := store.WriteHotPath(context.Background(), reqStore, row, in); err != nil {
		t.Fatal(err)
	}
}

func wsStatement(t *testing.T, store *Store) WholesaleStatement {
	t.Helper()
	stmt, err := store.GenerateWholesaleStatement(context.Background(), wsAccount, "2026-09", true)
	if err != nil {
		t.Fatalf("GenerateWholesaleStatement: %v", err)
	}
	return stmt
}

func wsLine(t *testing.T, stmt WholesaleStatement, model string) WholesaleStatementLineItem {
	t.Helper()
	for _, item := range stmt.LineItems {
		if item.Model == model {
			return item
		}
	}
	t.Fatalf("no line for %q in %+v", model, stmt.LineItems)
	return WholesaleStatementLineItem{}
}

func wsGross(t *testing.T, prompt, completion int64, cfg RewardsConfig, model string) int64 {
	t.Helper()
	multiplier := ParseMultiplierPPM(cfg.GlobalMultiplier)
	if multiplier == 0 {
		multiplier = globalMultiplierDenom
	}
	gross, err := WholesaleGross(big.NewInt(prompt), big.NewInt(completion), RateFor(cfg.RateCard, model), multiplier)
	if err != nil {
		t.Fatal(err)
	}
	return gross
}

const wsModel = "mlx-community/Llama-3.2-3B-Instruct-4bit"

func TestWholesaleStatementPricesEachRowAtItsOwnGenerationAcrossForwardAndRollback(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	store.SetWholesalePricing(1.0)
	day := time.Date(2026, 9, 10, 0, 0, 0, 0, time.UTC)
	old := wsRewards(13500, 27000, 1)
	corrected := wsRewards(20000, 40000, 1)
	oldID := wsSnapshot(t, store, old, day)
	wsPriced(t, reqStore, store, "req-old", wsModel, day.Add(time.Hour), 3000, 5000, old, oldID)
	forwardID := wsSnapshot(t, store, corrected, day.Add(2*time.Hour))
	wsPriced(t, reqStore, store, "req-forward", wsModel, day.Add(3*time.Hour), 7000, 11000, corrected, forwardID)
	rolledBackID := wsSnapshot(t, store, old, day.Add(4*time.Hour))
	wsPriced(t, reqStore, store, "req-rolled-back", wsModel, day.Add(5*time.Hour), 13000, 17000, old, rolledBackID)

	line := wsLine(t, wsStatement(t, store), wsModel)
	want := wsGross(t, 3000+13000, 5000+17000, old, wsModel) + wsGross(t, 7000, 11000, corrected, wsModel)
	if line.GrossCredits != want || line.PromptTokens != 23000 || line.CompletionTokens != 33000 || line.RequestCount != 3 {
		t.Fatalf("line=%+v want gross %d over 3 rows", line, want)
	}

	// SPEC-005 §13 / I5: a later price change never re-prices earlier rows.
	wsSnapshot(t, store, wsRewards(99999, 99999, 3), day.Add(6*time.Hour))
	if again := wsLine(t, wsStatement(t, store), wsModel); again.GrossCredits != want {
		t.Fatalf("re-generated after a price change gross=%d want %d", again.GrossCredits, want)
	}
}

func TestWholesaleStatementSplitsIdenticalRowsWithDifferentMultipliers(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	day := time.Date(2026, 9, 11, 0, 0, 0, 0, time.UTC)
	single := wsRewards(13500, 27000, 1)
	double := wsRewards(13500, 27000, 2)
	singleID := wsSnapshot(t, store, single, day)
	wsPriced(t, reqStore, store, "req-x1", wsModel, day.Add(time.Hour), 1_000_001, 3, single, singleID)
	doubleID := wsSnapshot(t, store, double, day.Add(2*time.Hour))
	wsPriced(t, reqStore, store, "req-x2", wsModel, day.Add(3*time.Hour), 1_000_001, 3, double, doubleID)

	line := wsLine(t, wsStatement(t, store), wsModel)
	want := wsGross(t, 1_000_001, 3, single, wsModel) + wsGross(t, 1_000_001, 3, double, wsModel)
	if line.GrossCredits != want {
		t.Fatalf("gross=%d want %d (one group per multiplier)", line.GrossCredits, want)
	}
	if merged := wsGross(t, 2_000_002, 6, single, wsModel); line.GrossCredits == merged {
		t.Fatalf("gross %d equals the single-multiplier merge; groups were not split", merged)
	}
}

func TestWholesaleStatementUnrelatedHUPDoesNotChangeTotals(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	day := time.Date(2026, 9, 12, 0, 0, 0, 0, time.UTC)
	cfg := wsRewards(13500, 27000, 1)
	firstID := wsSnapshot(t, store, cfg, day)
	wsPriced(t, reqStore, store, "req-u1", wsModel, day.Add(time.Hour), 4_999_999, 3, cfg, firstID)
	before := wsStatement(t, store)
	unrelatedID := wsSnapshot(t, store, cfg, day.Add(2*time.Hour))
	wsPriced(t, reqStore, store, "req-u2", wsModel, day.Add(3*time.Hour), 4_999_999, 3, cfg, unrelatedID)
	after := wsLine(t, wsStatement(t, store), wsModel)
	if want := wsGross(t, 2*4_999_999, 6, cfg, wsModel); after.GrossCredits != want {
		t.Fatalf("gross across an unrelated HUP=%d want one-group %d", after.GrossCredits, want)
	}
	if wsLine(t, before, wsModel).GrossCredits != wsGross(t, 4_999_999, 3, cfg, wsModel) {
		t.Fatalf("baseline=%+v", before)
	}
}

func TestWholesaleStatementLegacyNullAttemptRowUsesItsLinkedGeneration(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	day := time.Date(2026, 9, 13, 0, 0, 0, 0, time.UTC)
	old := wsRewards(13500, 27000, 1)
	oldID := wsSnapshot(t, store, old, day)
	// Priced at the old generation, but its timestamp falls after the HUP.
	wsPriced(t, reqStore, store, "req-legacy", wsModel, day.Add(3*time.Hour), 3000, 5000, old, oldID)
	wsSnapshot(t, store, wsRewards(20000, 40000, 1), day.Add(time.Hour))
	if _, err := store.db.Exec(`UPDATE request_log SET attempt_n = NULL WHERE request_id = 'req-legacy'`); err != nil {
		t.Fatal(err)
	}
	if got, want := wsLine(t, wsStatement(t, store), wsModel).GrossCredits, wsGross(t, 3000, 5000, old, wsModel); got != want {
		t.Fatalf("legacy NULL-attempt row gross=%d want linked generation %d", got, want)
	}
}

func TestWholesaleStatementUnlinkedRowUsesSnapshotAtTimestampAndFailsClosedWithoutOne(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	day := time.Date(2026, 9, 14, 0, 0, 0, 0, time.UTC)
	cfg := wsRewards(13500, 27000, 1)
	prompt, completion := int64(3000), int64(5000)
	if err := reqStore.Insert(context.Background(), requestlog.Row{TSUtc: day.Add(time.Hour), RequestID: "req-unlinked", AccountID: wsAccount, Model: wsModel, PromptTokens: &prompt, CompletionTokens: &completion, Status: 200, BuyerIP: "127.0.0.1"}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.GenerateWholesaleStatement(context.Background(), wsAccount, "2026-09", true); !errors.Is(err, ErrWholesaleNoGeneration) {
		t.Fatalf("no generation err=%v want ErrWholesaleNoGeneration", err)
	}
	wsSnapshot(t, store, cfg, day)
	wsSnapshot(t, store, wsRewards(20000, 40000, 1), day.Add(2*time.Hour))
	if got, want := wsLine(t, wsStatement(t, store), wsModel).GrossCredits, wsGross(t, prompt, completion, cfg, wsModel); got != want {
		t.Fatalf("unlinked row gross=%d want snapshot-at-ts %d", got, want)
	}
}

// Two attempts of one request priced across a price change: each attempt
// bills at its own generation and the statement succeeds.
func TestWholesaleStatementAttemptsAcrossAPriceChangeUseTheirOwnGenerations(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	day := time.Date(2026, 9, 15, 0, 0, 0, 0, time.UTC)
	first := wsRewards(13500, 27000, 1)
	second := wsRewards(20000, 40000, 1)
	firstID := wsSnapshot(t, store, first, day)
	wsPriced(t, reqStore, store, "req-two-attempts", wsModel, day.Add(time.Hour), 3000, 5000, first, firstID)
	secondID := wsSnapshot(t, store, second, day.Add(2*time.Hour))
	// The retry persists request_log attempt 1 and its identity at attempt 1.
	wsPricedAttempt(t, reqStore, store, "req-two-attempts", 1, 1, day.Add(3*time.Hour), 7000, 11000, second, secondID)
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_provider_identity_snapshots WHERE request_id = 'req-two-attempts'`); got != 2 {
		t.Fatalf("precondition: identities=%d want 2", got)
	}
	want := wsGross(t, 3000, 5000, first, wsModel) + wsGross(t, 7000, 11000, second, wsModel)
	if got := wsLine(t, wsStatement(t, store), wsModel).GrossCredits; got != want {
		t.Fatalf("gross=%d want each attempt at its own generation %d", got, want)
	}
}

// The exact-ordinal and id-derived-ordinal identities are resolved
// independently (SPEC-005 §11.7): a NULL config_snapshot_id is absent, one
// non-null id prices the row, two non-null ids must agree on (rate row,
// multiplier) or the statement fails closed.
func TestWholesaleStatementAmbiguousAttemptIdentityResolution(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	day := time.Date(2026, 9, 15, 0, 0, 0, 0, time.UTC)
	first := wsRewards(13500, 27000, 1)
	second := wsRewards(20000, 40000, 1)
	firstID := wsSnapshot(t, store, first, day)
	// Row 1: request_log only (no provider identity), priced at ts_utc (first).
	prompt1, completion1 := int64(1000), int64(2000)
	if err := reqStore.Insert(context.Background(), requestlog.Row{
		TSUtc: day.Add(time.Hour), RequestID: "req-amb", AccountID: wsAccount, Model: wsModel, ProviderAssignedID: "assigned-req-amb",
		PromptTokens: &prompt1, CompletionTokens: &completion1, Status: 200, BuyerIP: "127.0.0.1",
	}); err != nil {
		t.Fatal(err)
	}
	secondID := wsSnapshot(t, store, second, day.Add(2*time.Hour))
	// Row 2: the hot path re-derives its identity at id ordinal 1 (ambiguous,
	// zero credit) while a writer-supplied request_log ordinal says 0.
	wsPriced(t, reqStore, store, "req-amb", wsModel, day.Add(3*time.Hour), 3000, 5000, second, secondID)
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_provider_identity_snapshots WHERE request_id = 'req-amb' AND attempt_n = 1 AND config_snapshot_id = ?`, secondID); got != 1 {
		t.Fatalf("precondition: identity at the re-derived ordinal=%d want 1", got)
	}
	if _, err := store.db.Exec(`UPDATE request_log SET attempt_n = 0 WHERE request_id = 'req-amb'`); err != nil {
		t.Fatal(err)
	}
	derivedWant := wsGross(t, prompt1, completion1, first, wsModel) + wsGross(t, 3000, 5000, second, wsModel)
	if got := wsLine(t, wsStatement(t, store), wsModel).GrossCredits; got != derivedWant {
		t.Fatalf("derived-ordinal-only gross=%d want %d", got, derivedWant)
	}

	// An exact-key identity with a NULL config_snapshot_id is absent: row 2
	// still prices at the derived identity, row 1 at its ts_utc snapshot.
	in := HotPathInput{RequestID: "req-amb", AttemptN: 0, ProviderAssignedID: "assigned-req-amb", ProviderID: "provider-a"}
	if err := insertProviderIdentitySnapshotTx(context.Background(), store.db, in, day.Format(time.RFC3339Nano)); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_provider_identity_snapshots WHERE request_id = 'req-amb' AND attempt_n = 0 AND config_snapshot_id IS NULL`); got != 1 {
		t.Fatalf("precondition: NULL-snapshot exact identity=%d want 1", got)
	}
	if got := wsLine(t, wsStatement(t, store), wsModel).GrossCredits; got != derivedWant {
		t.Fatalf("exact-null + derived gross=%d want derived %d", got, derivedWant)
	}

	// Both non-null and pricing the row identically: the statement succeeds.
	// A later snapshot with second's prices stands in for the exact identity.
	samePriceID := wsSnapshot(t, store, second, day.Add(4*time.Hour))
	if _, err := store.db.Exec(`UPDATE ledger_provider_identity_snapshots SET config_snapshot_id = ? WHERE request_id = 'req-amb' AND attempt_n = 0`, samePriceID); err != nil {
		t.Fatal(err)
	}
	// Row 1 now links the exact identity too, so it prices at second.
	sameWant := wsGross(t, prompt1+3000, completion1+5000, second, wsModel)
	if got := wsLine(t, wsStatement(t, store), wsModel).GrossCredits; got != sameWant {
		t.Fatalf("both-linked same-price gross=%d want %d", got, sameWant)
	}

	// Both non-null and pricing the row differently: fail closed, no line.
	if _, err := store.db.Exec(`UPDATE ledger_provider_identity_snapshots SET config_snapshot_id = ? WHERE request_id = 'req-amb' AND attempt_n = 0`, firstID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.GenerateWholesaleStatement(context.Background(), wsAccount, "2026-09", true); !errors.Is(err, ErrWholesaleConflictingGenerations) {
		t.Fatalf("conflicting generations err=%v want ErrWholesaleConflictingGenerations", err)
	}
}

// A normal multi-attempt request whose persisted ordinals equal their id
// ordinals, priced across a price change, never consults a derived identity:
// each attempt bills at its own generation and no conflict is reported.
func TestWholesaleStatementNormalAttemptsAcrossAPriceChangeDoNotConflict(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	day := time.Date(2026, 9, 15, 0, 0, 0, 0, time.UTC)
	first := wsRewards(13500, 27000, 1)
	second := wsRewards(20000, 40000, 1)
	firstID := wsSnapshot(t, store, first, day)
	wsPricedAttempt(t, reqStore, store, "req-normal", 0, 0, day.Add(time.Hour), 3000, 5000, first, firstID)
	secondID := wsSnapshot(t, store, second, day.Add(2*time.Hour))
	wsPricedAttempt(t, reqStore, store, "req-normal", 1, 1, day.Add(3*time.Hour), 7000, 11000, second, secondID)
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM request_log rl WHERE rl.request_id = 'req-normal' AND `+requestLogAttemptOrdinalSQL("rl")+` = `+requestLogIDOrdinalSQL("rl")); got != 2 {
		t.Fatalf("precondition: rows with persisted ordinal == id ordinal=%d want 2", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_provider_identity_snapshots WHERE request_id = 'req-normal' AND config_snapshot_id IS NOT NULL`); got != 2 {
		t.Fatalf("precondition: linked identities=%d want 2", got)
	}
	want := wsGross(t, 3000, 5000, first, wsModel) + wsGross(t, 7000, 11000, second, wsModel)
	if got := wsLine(t, wsStatement(t, store), wsModel).GrossCredits; got != want {
		t.Fatalf("gross=%d want each attempt at its own generation %d", got, want)
	}
}

func TestWholesaleStatementFreeAliasIsZeroUSDWithCredits(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	store.SetWholesalePricing(2.0)
	day := time.Date(2026, 9, 16, 0, 0, 0, 0, time.UTC)
	cfg := wsRewards(13500, 27000, 1)
	id := wsSnapshot(t, store, cfg, day)
	free := wsModel + "-free"
	wsPriced(t, reqStore, store, "req-free", free, day.Add(time.Hour), 3000, 5000, cfg, id)
	wsPriced(t, reqStore, store, "req-paid", wsModel, day.Add(time.Hour), 3000, 5000, cfg, id)
	stmt := wsStatement(t, store)
	freeLine, paidLine := wsLine(t, stmt, free), wsLine(t, stmt, wsModel)
	if !freeLine.IsFree || freeLine.USDMicro != 0 || freeLine.GrossCredits != paidLine.GrossCredits || freeLine.GrossCredits == 0 {
		t.Fatalf("free=%+v paid=%+v", freeLine, paidLine)
	}
	if stmt.USDMicro != creditsToUSDMicro(paidLine.GrossCredits, 2.0) {
		t.Fatalf("statement usd_micro=%d want paid-only %d", stmt.USDMicro, creditsToUSDMicro(paidLine.GrossCredits, 2.0))
	}
}

// With one generation and totals within the per-request limits the statement
// is byte-identical to the pre-W1 formula (ComputeCredits over the model's
// summed tokens at the current table).
func TestWholesaleStatementSingleGenerationMatchesPreviousFormula(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	store.SetWholesalePricing(1.25)
	day := time.Date(2026, 9, 17, 0, 0, 0, 0, time.UTC)
	cfg := wsRewards(13500, 27000, 1.1)
	cfg.RateCard["qwen3-8b"] = RateCardEntry{PromptCreditsPerMtok: 7777, CompletionCreditsPerMtok: 9999}
	id := wsSnapshot(t, store, cfg, day)
	tokens := map[string][][2]int64{
		wsModel:                       {{123457, 98765}, {1, 3}, {4_000_000, 2_000_000}},
		"mlx-community/Qwen3-8B-4bit": {{55555, 44444}},
		"unknown/served-model":        {{1000, 2000}, {3, 5}},
	}
	n := 0
	for model, rows := range tokens {
		for _, r := range rows {
			n++
			wsPriced(t, reqStore, store, "req-regression-"+strconv.Itoa(n), model, day.Add(time.Duration(n)*time.Minute), r[0], r[1], cfg, id)
		}
	}
	stmt := wsStatement(t, store)
	for model, rows := range tokens {
		var prompt, completion int64
		for _, r := range rows {
			prompt += r[0]
			completion += r[1]
		}
		legacy := ComputeCredits(&prompt, &completion, nil, UsageProviderReported, FaultNone, RateFor(cfg.RateCard, model), ParseMultiplierPPM(cfg.GlobalMultiplier), ParseShareBps(cfg.ProviderShare))
		line := wsLine(t, stmt, model)
		if line.GrossCredits != legacy.GrossCredits || line.USDMicro != creditsToUSDMicro(legacy.GrossCredits, 1.25) || line.PromptTokens != prompt || line.CompletionTokens != completion {
			t.Fatalf("%s line=%+v want gross %d (pre-W1 formula)", model, line, legacy.GrossCredits)
		}
	}
}

// Above the per-request 10M cap the pre-W1 aggregate zeroed the model-month.
// W1 bills it; splitting it across generations only moves per-group rounding.
func TestWholesaleStatementAboveRequestCapIsBilledUnsplitAndSplit(t *testing.T) {
	type row struct{ prompt, completion int64 }
	rows := []row{{4_000_001, 3_000_003}, {4_000_001, 3_000_003}, {4_000_001, 3_000_003}}
	cfg := wsRewards(13501, 27001, 1)
	cfgRestamp := wsRewards(13501, 27001, 1)
	cfgRestamp.RateCard["unrelated/model"] = RateCardEntry{PromptCreditsPerMtok: 1, CompletionCreditsPerMtok: 1}
	unsplitWant := wsGross(t, 12_000_003, 9_000_009, cfg, wsModel)
	for _, tc := range []struct {
		name   string
		layout []RewardsConfig // generation of each row
	}{
		{"unsplit", []RewardsConfig{cfg, cfg, cfg}},
		{"forward-HUP", []RewardsConfig{cfg, cfgRestamp, cfgRestamp}},
		{"rollback", []RewardsConfig{cfg, cfgRestamp, cfg}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reqStore, store := newRequestAndBillingStores(t)
			day := time.Date(2026, 9, 18, 0, 0, 0, 0, time.UTC)
			for i, gen := range tc.layout {
				id := wsSnapshot(t, store, gen, day.Add(time.Duration(2*i)*time.Hour))
				wsPriced(t, reqStore, store, "req-cap-"+strconv.Itoa(i), wsModel, day.Add(time.Duration(2*i+1)*time.Hour), rows[i].prompt, rows[i].completion, gen, id)
			}
			line := wsLine(t, wsStatement(t, store), wsModel)
			if line.GrossCredits == 0 || line.PromptTokens != 12_000_003 || line.CompletionTokens != 9_000_009 {
				t.Fatalf("line=%+v", line)
			}
			// Same list price in every generation: one group per distinct
			// (row, multiplier), so the gross equals the unsplit gross.
			if line.GrossCredits != unsplitWant {
				diff := line.GrossCredits - unsplitWant
				if diff < -int64(len(rows)) || diff > int64(len(rows)) {
					t.Fatalf("gross=%d unsplit=%d beyond per-group rounding", line.GrossCredits, unsplitWant)
				}
			}
		})
	}
}

func TestWholesaleStatementGrossOverflowFailsClosed(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	day := time.Date(2026, 9, 19, 0, 0, 0, 0, time.UTC)
	cfg := wsRewards(math.MaxInt64/4, math.MaxInt64/4, 1)
	id := wsSnapshot(t, store, cfg, day)
	// ComputeCredits' per-request overflow guard zero-credits this row; the
	// statement must refuse rather than bill zero or wrap.
	wsPriced(t, reqStore, store, "req-overflow", wsModel, day.Add(time.Hour), 9_000_000, 9_000_000, cfg, id)
	if _, err := store.GenerateWholesaleStatement(context.Background(), wsAccount, "2026-09", true); !errors.Is(err, ErrWholesaleGrossOverflow) {
		t.Fatalf("err=%v want ErrWholesaleGrossOverflow", err)
	}
}

// The statement bills the persisted request_log token columns: a provider
// report above the independent prompt bound, and a relay-blind row whose
// usage the recorder clamped, are billed at the bounded values.
func TestWholesaleStatementBillsPersistedBoundedTokens(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	day := time.Date(2026, 9, 20, 0, 0, 0, 0, time.UTC)
	cfg := wsRewards(13500, 27000, 1)
	id := wsSnapshot(t, store, cfg, day)
	reported, completion, bound := int64(900_000), int64(10), int64(1_000)
	row := requestlog.Row{
		TSUtc: day.Add(time.Hour), RequestID: "req-bounded", AccountID: wsAccount, Model: wsModel, ProviderAssignedID: "assigned-bounded",
		PromptTokens: &reported, CompletionTokens: &completion, Status: 200, BuyerIP: "127.0.0.1",
	}
	in := HotPathInput{
		RequestID: row.RequestID, ProviderAssignedID: row.ProviderAssignedID, ProviderID: "provider-a", Model: wsModel,
		Status: 200, TSUtc: row.TSUtc, PromptTokens: &reported, PromptTokenUpperBound: &bound, CompletionTokens: &completion,
		ConfigSnapshotID: id, RateEntry: RateFor(cfg.RateCard, wsModel),
		MultiplierPPM: ParseMultiplierPPM(cfg.GlobalMultiplier), ProviderShareBps: ParseShareBps(cfg.ProviderShare),
	}
	if err := store.WriteHotPath(context.Background(), reqStore, row, in); err != nil {
		t.Fatal(err)
	}
	// Relay-blind: the recorder clamps usage to the envelope caps before the
	// row is written; the statement sees only those persisted columns.
	relayPrompt, relayCompletion := int64(64), int64(32)
	relayRow := requestlog.Row{
		TSUtc: day.Add(2 * time.Hour), RequestID: "req-relay-blind", AccountID: wsAccount, Model: wsModel, ProviderAssignedID: "assigned-relay",
		PromptTokens: &relayPrompt, CompletionTokens: &relayCompletion, Status: 200, BuyerIP: "127.0.0.1",
		RequestedPrivacyMode: "relay_blind_required", EffectivePrivacyOutcome: "relay_blind_satisfied",
		PositiveVerificationExcluded: true, RewardsExcluded: true,
	}
	relayIn := HotPathInput{
		RequestID: relayRow.RequestID, ProviderAssignedID: relayRow.ProviderAssignedID, ProviderID: "provider-a", Model: wsModel,
		Status: 200, TSUtc: relayRow.TSUtc, PromptTokens: &relayPrompt, CompletionTokens: &relayCompletion,
		ConfigSnapshotID: id, RateEntry: RateFor(cfg.RateCard, wsModel),
		MultiplierPPM: ParseMultiplierPPM(cfg.GlobalMultiplier), ProviderShareBps: ParseShareBps(cfg.ProviderShare),
		RequestedPrivacyMode: "relay_blind_required", EffectivePrivacyOutcome: "relay_blind_satisfied",
		PositiveVerificationExcluded: true, RewardsExcluded: true,
	}
	if err := store.WriteHotPath(context.Background(), reqStore, relayRow, relayIn); err != nil {
		t.Fatal(err)
	}
	line := wsLine(t, wsStatement(t, store), wsModel)
	if line.PromptTokens != bound+relayPrompt || line.CompletionTokens != completion+relayCompletion {
		t.Fatalf("line tokens=%d/%d want persisted %d/%d", line.PromptTokens, line.CompletionTokens, bound+relayPrompt, completion+relayCompletion)
	}
	if want := wsGross(t, bound+relayPrompt, completion+relayCompletion, cfg, wsModel); line.GrossCredits != want {
		t.Fatalf("gross=%d want %d", line.GrossCredits, want)
	}
}
