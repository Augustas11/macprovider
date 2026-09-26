package integration

import (
	"database/sql"
	"net/http"
	"strings"
	"testing"
	"time"
)

// J8 — wholesale edges (SPEC-005 §11.7) through the real admin endpoint on a
// ledger that holds two real generations (boot A, SIGHUP B). Edge rows are
// planted in the real SQLite request_log / identity tables, the way the
// crash-recovery journey plants rows, each edge under its own account so one
// fail-closed edge does not mask another.
func TestPricingLaneJ8WholesaleEdges(t *testing.T) {
	p := newPricingLane(t, pricingLaneOpts{})
	tableA := p.cardA.table()
	cardB, cardBRaw := p.cardB()
	tableB := cardB.table()
	p.paidRequests(p.apiKey, 2)
	p.installPricing(p.spliceYAML(p.coordYAML, rateCardBlock(cardB)), cardBRaw)
	if ok, logs := p.sighup(rejectMarkersAll...); !ok {
		t.Fatalf("A->B reload rejected:\n%s", strings.Join(logs, "\n"))
	}
	p.paidRequests(p.apiKey, 2)

	var snapA, snapB configSnapshot
	for _, s := range p.snapshots() {
		switch {
		case s.Table.equal(tableA) && snapA.ID == 0:
			snapA = s
		case s.Table.equal(tableB):
			snapB = s
		}
	}
	if snapA.ID == 0 || snapB.ID == 0 {
		t.Fatalf("need both generations: A=%d B=%d", snapA.ID, snapB.ID)
	}
	effA, err := time.Parse(time.RFC3339Nano, snapA.EffectiveAt)
	if err != nil {
		t.Fatalf("snapshot A effective_at %q: %v", snapA.EffectiveAt, err)
	}
	effB, err := time.Parse(time.RFC3339Nano, snapB.EffectiveAt)
	if err != nil {
		t.Fatalf("snapshot B effective_at %q: %v", snapB.EffectiveAt, err)
	}
	if !effA.Before(effB) {
		t.Fatalf("generation A effective %s not before B %s", effA, effB)
	}
	between := effA.Add(time.Duration(effB.Sub(effA)) / 2)
	after := effB.Add(time.Millisecond)

	db := p.openCoordDB()
	defer db.Close()
	type plant struct {
		account, requestID, model string
		attemptN                  sql.NullInt64
		prompt, completion        int64
		ts                        time.Time
		identity                  []int64 // (attempt ordinal, snapshot id) pairs
	}
	seq := 0
	insert := func(pl plant) {
		t.Helper()
		seq++
		pa := "pa-j8-" + pl.requestID
		if _, err := db.Exec(`
INSERT INTO request_log (ts_utc, request_id, account_id, model, provider_assigned_id, prompt_tokens, completion_tokens,
                         total_tokens, latency_ms, routing_ms, status, stream, attempt_n)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, 1, 200, 0, ?)`,
			pl.ts.UTC().Format(time.RFC3339Nano), pl.requestID, pl.account, pl.model, pa,
			pl.prompt, pl.completion, pl.prompt+pl.completion, pl.attemptN); err != nil {
			t.Fatalf("plant request_log: %v", err)
		}
		for i := 0; i+1 < len(pl.identity); i += 2 {
			if _, err := db.Exec(`
INSERT OR IGNORE INTO ledger_provider_identity_snapshots (request_id, attempt_n, provider_assigned_id, provider_id, resolved_from, config_snapshot_id, created_at_utc)
VALUES (?, ?, ?, ?, 'pool_entry', ?, ?)`,
				pl.requestID, pl.identity[i], pa, p.providerID, pl.identity[i+1], pl.ts.UTC().Format(time.RFC3339Nano)); err != nil {
				t.Fatalf("plant identity: %v", err)
			}
		}
	}
	n0 := sql.NullInt64{Int64: 0, Valid: true}
	null := sql.NullInt64{}

	t.Run("model_month_above_10M_tokens_not_zeroed", func(t *testing.T) {
		acct := "acct_j8_big"
		insert(plant{account: acct, requestID: "j8-big-1", model: pricingLlamaKey, attemptN: n0, prompt: 6_000_000, completion: 6_000_000, ts: between, identity: []int64{0, snapA.ID}})
		insert(plant{account: acct, requestID: "j8-big-2", model: pricingLlamaKey, attemptN: n0, prompt: 5_000_000, completion: 5_000_000, ts: between, identity: []int64{0, snapA.ID}})
		insert(plant{account: acct, requestID: "j8-big-3", model: pricingLlamaKey, attemptN: n0, prompt: 4_000_000, completion: 4_000_000, ts: after, identity: []int64{0, snapB.ID}})
		st := p.generateWholesale(acct)
		if st.status != http.StatusOK {
			t.Fatalf("status=%d body=%s", st.status, st.raw)
		}
		line := st.line(t, pricingLlamaKey)
		want := listGross(11_000_000, 11_000_000, tableA[pricingLlamaKey]) + listGross(4_000_000, 4_000_000, tableB[pricingLlamaKey])
		if got := jsonInt(line["gross_credits"]); got != want {
			t.Errorf("gross=%d want %d (per generation, no 10M zeroing): %s", got, want, st.raw)
		}
		if jsonInt(line["usd_micro"]) <= 0 {
			t.Errorf("usd_micro=%v for a paid >10M line", line["usd_micro"])
		}
	})

	t.Run("free_sku_alias_line_is_free", func(t *testing.T) {
		acct := "acct_j8_free"
		insert(plant{account: acct, requestID: "j8-free-1", model: "llama-3.2-3b-instruct-free", attemptN: n0, prompt: 1000, completion: 2000, ts: after, identity: []int64{0, snapB.ID}})
		st := p.generateWholesale(acct)
		if st.status != http.StatusOK {
			t.Fatalf("status=%d body=%s", st.status, st.raw)
		}
		line := st.line(t, "llama-3.2-3b-instruct-free")
		if line["is_free"] != true || jsonInt(line["usd_micro"]) != 0 {
			t.Errorf("free SKU line not free: %v", line)
		}
		if got, want := jsonInt(line["gross_credits"]), listGross(1000, 2000, tableB[pricingLlamaKey]); got != want {
			t.Errorf("free SKU gross=%d want list gross %d at B", got, want)
		}
	})

	t.Run("zero_rate_row_per_generation", func(t *testing.T) {
		acct := "acct_j8_zero"
		insert(plant{account: acct, requestID: "j8-zero-a", model: pricingZeroRateKey, attemptN: n0, prompt: 1000, completion: 1000, ts: between, identity: []int64{0, snapA.ID}})
		insert(plant{account: acct, requestID: "j8-zero-b", model: pricingZeroRateKey, attemptN: n0, prompt: 1000, completion: 1000, ts: after, identity: []int64{0, snapB.ID}})
		st := p.generateWholesale(acct)
		if st.status != http.StatusOK {
			t.Fatalf("status=%d body=%s", st.status, st.raw)
		}
		line := st.line(t, pricingZeroRateKey)
		want := listGross(1000, 1000, tableA[pricingZeroRateKey]) + 0
		if got := jsonInt(line["gross_credits"]); got != want {
			t.Errorf("zero-rate line gross=%d want %d (A row priced, B zero row = 0)", got, want)
		}
	})

	t.Run("legacy_null_attempt_rows_across_change", func(t *testing.T) {
		acct := "acct_j8_legacy"
		// One legacy request, two attempts (NULL attempt_n, id-order ordinals
		// 0 and 1), each identity linked to its own generation.
		insert(plant{account: acct, requestID: "j8-legacy-r", model: pricingLlamaKey, attemptN: null, prompt: 100, completion: 200, ts: between, identity: []int64{0, snapA.ID}})
		insert(plant{account: acct, requestID: "j8-legacy-r", model: pricingLlamaKey, attemptN: null, prompt: 300, completion: 400, ts: after, identity: []int64{1, snapB.ID}})
		// Legacy rows with no identity: priced at the generation in effect at ts.
		insert(plant{account: acct, requestID: "j8-legacy-noid-a", model: pricingLlamaKey, attemptN: null, prompt: 1000, completion: 1000, ts: between})
		insert(plant{account: acct, requestID: "j8-legacy-noid-b", model: pricingLlamaKey, attemptN: null, prompt: 2000, completion: 2000, ts: after})
		st := p.generateWholesale(acct)
		if st.status != http.StatusOK {
			t.Fatalf("status=%d body=%s", st.status, st.raw)
		}
		line := st.line(t, pricingLlamaKey)
		want := listGross(100+1000, 200+1000, tableA[pricingLlamaKey]) + listGross(300+2000, 400+2000, tableB[pricingLlamaKey])
		if got := jsonInt(line["gross_credits"]); got != want {
			t.Errorf("legacy line gross=%d want %d: %s", got, want, st.raw)
		}
	})

	t.Run("both_identity_conflict_fails_closed", func(t *testing.T) {
		acct := "acct_j8_conflict"
		// Two request_log rows of one request both persisting attempt_n=0: the
		// second has id-ordinal 1, so its exact identity (0 -> A) and derived
		// identity (1 -> B) price the llama row differently.
		insert(plant{account: acct, requestID: "j8-conflict", model: pricingLlamaKey, attemptN: n0, prompt: 10, completion: 10, ts: after, identity: []int64{0, snapA.ID, 1, snapB.ID}})
		insert(plant{account: acct, requestID: "j8-conflict", model: pricingLlamaKey, attemptN: n0, prompt: 10, completion: 10, ts: after})
		st := p.generateWholesale(acct)
		if st.status == http.StatusOK {
			t.Fatalf("conflicting generations produced a statement: %s", st.raw)
		}
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM wholesale_period_statements WHERE account_id = ?`, acct).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n != 0 {
			t.Errorf("fail-closed conflict still persisted %d statement row(s)", n)
		}
		t.Logf("conflict statement: status=%d body=%s", st.status, st.raw)
	})

	t.Run("both_identity_same_price_is_not_a_conflict", func(t *testing.T) {
		acct := "acct_j8_conflict_same"
		// Same shape, but the model resolves to `default`, unchanged A -> B.
		insert(plant{account: acct, requestID: "j8-same", model: "unknown-vendor/unknown-model", attemptN: n0, prompt: 10, completion: 10, ts: after, identity: []int64{0, snapA.ID, 1, snapB.ID}})
		insert(plant{account: acct, requestID: "j8-same", model: "unknown-vendor/unknown-model", attemptN: n0, prompt: 10, completion: 10, ts: after})
		st := p.generateWholesale(acct)
		if st.status != http.StatusOK {
			t.Fatalf("status=%d body=%s", st.status, st.raw)
		}
		line := st.line(t, "unknown-vendor/unknown-model")
		if got, want := jsonInt(line["gross_credits"]), listGross(20, 20, tableA["default"]); got != want {
			t.Errorf("gross=%d want %d", got, want)
		}
	})

	t.Run("statement_for_real_traffic_is_stable_across_regeneration", func(t *testing.T) {
		acct := p.requestLogAccount(p.paidRequests(p.apiKey, 1)[0])
		a := p.generateWholesale(acct)
		b := p.generateWholesale(acct)
		if a.status != http.StatusOK || b.status != http.StatusOK || a.comparable(t) != b.comparable(t) {
			t.Errorf("regeneration not stable: %s vs %s", a.raw, b.raw)
		}
	})
}
