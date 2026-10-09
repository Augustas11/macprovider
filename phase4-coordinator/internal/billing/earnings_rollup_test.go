package billing

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"math/rand"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

type rollupCredit struct {
	requestID, provider, ts, model string
	credits                        int64
	quarantined                    bool
	fault                          string
	enforce                        bool
}

func insertRollupCredit(t testing.TB, db *sql.DB, c rollupCredit) int64 {
	t.Helper()
	id, err := insertRollupCreditErr(db, c)
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func insertRollupCreditErr(db *sql.DB, c rollupCredit) (int64, error) {
	fault := c.fault
	if fault == "" {
		fault = "none"
	}
	mode, scope, version := "legacy", sql.NullString{}, sql.NullString{}
	if c.enforce {
		mode = "enforce"
		scope = sql.NullString{String: strings.Repeat("a", 64), Valid: true}
		version = sql.NullString{String: RouteSnapshotPolicyVersion, Valid: true}
	}
	res, err := db.Exec(`
INSERT INTO ledger_request_credits (
    request_id, attempt_n, provider_id, provider_assigned_id, ts_utc, model,
    status, stream, usage_source, prompt_rate_per_mtok, completion_rate_per_mtok,
    global_multiplier_ppm, gross_credits, provider_share_bps, provider_credits,
    fault_flag, recovery_source, created_at_utc, quarantined,
    settlement_policy_mode, settlement_account_scope_hash, settlement_policy_version
) VALUES (?, 0, ?, 'assigned', ?, ?, 200, 0, 'provider_reported', 1, 1, 1000000, ?, 9000, ?, ?, 'hot_path', ?, ?, ?, ?, ?)`,
		c.requestID, c.provider, c.ts, c.model, c.credits, c.credits, fault, c.ts, boolInt(c.quarantined), mode, scope, version)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

func insertRollupResolution(t testing.TB, db *sql.DB, creditID int64, kind, createdAt, maturesAt string) {
	t.Helper()
	if err := insertRollupResolutionErr(db, creditID, kind, createdAt, maturesAt); err != nil {
		t.Fatal(err)
	}
}

func insertRollupResolutionErr(db *sql.DB, creditID int64, kind, createdAt, maturesAt string) error {
	matures := sql.NullString{String: maturesAt, Valid: maturesAt != ""}
	_, err := db.Exec(`
INSERT INTO ledger_quarantine_resolutions(request_credit_id, resolution_kind, operator_id, resolution_reason, created_at_utc, force_credit_matures_at_utc, correction_deadline_at_utc)
VALUES (?, ?, 'op', 'test', ?, ?, ?)`, creditID, kind, createdAt, matures, createdAt)
	return err
}

// viewEarningsReference is an independent reference: the figures read
// straight from spec022_payable_request_credits with the endpoint's original
// filters.
func viewEarningsReference(ctx context.Context, q sqlQueryer, providerID string, win earningsWindows) (providerEarningsFigures, error) {
	rangeSQL, rangeArgs := earningsRangeFilter(win.from, win.to, win.hasRange)
	var firstErr error
	one := func(query string, args ...any) int64 {
		var n sql.NullInt64
		if err := q.QueryRowContext(ctx, query, args...).Scan(&n); err != nil && firstErr == nil {
			firstErr = err
		}
		return n.Int64
	}
	with := func(args ...any) []any { return append(args, rangeArgs...) }
	out := providerEarningsFigures{
		total:   one(`SELECT SUM(provider_credits) FROM spec022_payable_request_credits WHERE provider_id=?`+rangeSQL, with(providerID)...),
		week:    one(`SELECT SUM(provider_credits) FROM spec022_payable_request_credits WHERE provider_id=? AND ts_utc >= ?`+rangeSQL, with(providerID, sqliteTimeText(win.week))...),
		today:   one(`SELECT SUM(provider_credits) FROM spec022_payable_request_credits WHERE provider_id=? AND ts_utc >= ?`+rangeSQL, with(providerID, sqliteTimeText(win.today))...),
		pending: one(`SELECT SUM(provider_credits) FROM spec022_payable_request_credits WHERE provider_id=?`, providerID),
		faults:  one(`SELECT COUNT(*) FROM ledger_request_credits WHERE provider_id=? AND fault_flag != 'none'`+rangeSQL, with(providerID)...),
		models:  []string{},
	}
	if firstErr != nil {
		return out, firstErr
	}
	rows, err := q.QueryContext(ctx, `SELECT DISTINCT model FROM spec022_payable_request_credits WHERE provider_id=?`+rangeSQL+` ORDER BY model`, with(providerID)...)
	if err != nil {
		return out, err
	}
	defer rows.Close()
	for rows.Next() {
		var m string
		if err := rows.Scan(&m); err != nil {
			return out, err
		}
		out.models = append(out.models, m)
	}
	return out, rows.Err()
}

func rollupTestWindows(today time.Time) []earningsWindows {
	week := currentMondayUTC(today)
	day := func(y int, m time.Month, d int) time.Time { return time.Date(y, m, d, 0, 0, 0, 0, time.UTC) }
	base := earningsWindows{week: week, today: today}
	out := []earningsWindows{base}
	for _, r := range [][2]time.Time{
		{today.AddDate(0, 0, -20), today.AddDate(0, 0, 1)},
		{week, today},
		{today, today.AddDate(0, 0, 1)},
		{today.AddDate(0, 0, -1), today},
		{day(2026, 8, 1), day(2026, 8, 31)},
		{week.AddDate(0, 0, -7), week},
	} {
		w := base
		w.from, w.to, w.hasRange = r[0], r[1], true
		out = append(out, w)
	}
	return out
}

// checkRollupMatchesView asserts the rollup path is served and equals the
// reference for every window and provider.
func checkRollupMatchesView(t *testing.T, store *Store, providers []string, wins []earningsWindows) {
	t.Helper()
	ctx := context.Background()
	for _, provider := range providers {
		for i, win := range wins {
			got, ok, err := store.providerEarningsFromRollup(ctx, provider, win)
			if err != nil {
				t.Fatalf("%s window %d: rollup read: %v", provider, i, err)
			}
			if !ok {
				t.Fatalf("%s window %d: rollup path not served", provider, i)
			}
			want, err := viewEarningsReference(ctx, store.db, provider, win)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("%s window %d (%+v): rollup=%+v view=%+v", provider, i, win, got, want)
			}
			legacy, err := (&handler{store: store}).providerEarningsFiguresFromView(ctx, provider, win)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(legacy, want) {
				t.Fatalf("%s window %d: legacy=%+v view=%+v", provider, i, legacy, want)
			}
		}
	}
}

func drainRollup(t *testing.T, store *Store) {
	t.Helper()
	for i := 0; ; i++ {
		if i > 10000 {
			t.Fatal("rollup did not drain")
		}
		pass, err := store.RefreshProviderEarningsRollup(context.Background(), DefaultProviderEarningsRollupLimit)
		if err != nil {
			t.Fatal(err)
		}
		if !pass.More && pass.Recomputed == 0 {
			break
		}
	}
	if n := scalar(t, store.db, `SELECT COUNT(*) FROM provider_earnings_rollup_buckets b, provider_earnings_rollup_state s WHERE b.gen != b.computed_gen OR b.computed_epoch != s.epoch`); n != 0 {
		t.Fatalf("dirty or old-epoch buckets after drain=%d", n)
	}
}

func cachedBucketCount(t *testing.T, store *Store, provider string) int64 {
	t.Helper()
	return scalar(t, store.db, `SELECT COUNT(*) FROM provider_earnings_rollup_buckets b, provider_earnings_rollup_state s WHERE b.provider_id = ? AND b.gen = b.computed_gen AND b.computed_epoch = s.epoch`, provider)
}

func TestEarningsHourKeyMatchesLexicalBoundaries(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	cases := map[string]string{
		"2026-09-16T00:00:00.000000000Z": "2026-09-16T00",
		"2026-09-16T00:00:00Z":           "2026-09-16T00",
		"2026-09-16T00:00:00.5Z":         "2026-09-16T00",
		"2026-09-16T00:00:00+00:00":      "2026-09-15T23",
		"2026-09-16T05:59:59.999999999Z": "2026-09-16T05",
		"2026-01-01T00:00:00+02:00":      "2025-12-31T23",
		"2026-09-16 05:00:00":            "",
		"2026-09-16T24:00:00Z":           "",
		"2026-02-30T05:00:00Z":           "",
		"2026-09-16T7:00:00Z":            "",
		"0000-01-01T00:00:00Z":           "",
		"0001-01-01T01:00:00+00:00":      "0001-01-01T00",
		"2026-09-16":                     "",
		"garbage":                        "",
		"":                               "",
	}
	for ts, want := range cases {
		var got string
		if err := store.db.QueryRow(`SELECT `+earningsHourKeySQL("?1"), ts).Scan(&got); err != nil {
			t.Fatal(err)
		}
		if got != want {
			t.Fatalf("hour key of %q = %q, want %q", ts, got, want)
		}
	}
	// Property: every non-empty key K satisfies boundary(K) <= ts < boundary(K+1h)
	// under byte comparison, which is SQLite's BINARY collation.
	rng := rand.New(rand.NewSource(1925))
	suffixes := []string{":00:00.000000000Z", ":00:00Z", ":59:59.999999999Z", ":00:00+00:00", ":00:00-05:00", ":30", "", ":00:00.000Z", ":0", "Z", " "}
	for i := 0; i < 3000; i++ {
		at := time.Date(2025+rng.Intn(3), time.Month(1+rng.Intn(12)), 1+rng.Intn(31), rng.Intn(24), 0, 0, 0, time.UTC)
		ts := at.Format("2006-01-02T15") + suffixes[rng.Intn(len(suffixes))]
		var key string
		if err := store.db.QueryRow(`SELECT `+earningsHourKeySQL("?1"), ts).Scan(&key); err != nil {
			t.Fatal(err)
		}
		if key == "" {
			continue
		}
		next, err := nextEarningsHour(key)
		if err != nil {
			t.Fatal(err)
		}
		if !(earningsHourBoundary(key) <= ts && ts < earningsHourBoundary(next)) {
			t.Fatalf("ts %q keyed %q outside [%s, %s)", ts, key, earningsHourBoundary(key), earningsHourBoundary(next))
		}
	}
}

func seedRollupFixture(t *testing.T, store *Store) {
	t.Helper()
	db := store.db
	add := func(c rollupCredit) int64 {
		if c.provider == "" {
			c.provider = "p-a"
		}
		c.requestID = fmt.Sprintf("%s-%s-%s", c.provider, c.ts, c.model)
		return insertRollupCredit(t, db, c)
	}
	add(rollupCredit{ts: "2026-09-16T00:00:00.000000000Z", model: "model-b", credits: 11})
	add(rollupCredit{ts: "2026-09-15T23:59:59.999999999Z", model: "model-a", credits: 13})
	add(rollupCredit{ts: "2026-09-16T00:00:00Z", model: "model-a", credits: 17})
	add(rollupCredit{ts: "2026-09-16T00:00:00+00:00", model: "model-c", credits: 19})
	add(rollupCredit{ts: "2026-09-14T00:00:00.000000000Z", model: "model-a", credits: 23})
	add(rollupCredit{ts: "2026-09-13T23:30:00.000000000Z", model: "model-d", credits: 29})
	add(rollupCredit{ts: "2026-08-15T10:00:00.000000000Z", model: "model-e", credits: 31})
	add(rollupCredit{ts: "2026-08-31T00:00:00.000000000Z", model: "model-e", credits: 32})
	add(rollupCredit{ts: "2026-09-16T05:00:00.000000000Z", model: "model-q", credits: 37, quarantined: true})
	voided := add(rollupCredit{ts: "2026-09-15T05:00:00.000000000Z", model: "model-v", credits: 41, quarantined: true})
	insertRollupResolution(t, db, voided, "force_void", "2026-09-15T06:00:00.000000000Z", "")
	matured := add(rollupCredit{ts: "2026-09-14T06:00:00.000000000Z", model: "model-fc", credits: 43, quarantined: true})
	insertRollupResolution(t, db, matured, "force_credit", "2026-09-14T07:00:00.000000000Z", "2026-09-15T07:00:00.000000000Z")
	held := add(rollupCredit{ts: "2026-09-16T07:00:00.000000000Z", model: "model-ff", credits: 47, quarantined: true})
	insertRollupResolution(t, db, held, "force_credit", "2026-09-16T08:00:00.000000000Z", "2999-01-01T00:00:00.000000000Z")
	corrected := add(rollupCredit{ts: "2026-09-15T08:00:00.000000000Z", model: "model-x", credits: 53, quarantined: true})
	insertRollupResolution(t, db, corrected, "force_credit", "2026-09-15T09:00:00.000000000Z", "2026-09-16T09:00:00.000000000Z")
	insertRollupResolution(t, db, corrected, "force_void", "2026-09-15T10:00:00.000000000Z", "")
	add(rollupCredit{ts: "2026-09-16T09:00:00.000000000Z", model: "model-a", credits: 59, fault: "breaker_qualifying"})
	add(rollupCredit{ts: "2026-09-10T03:00:00.000000000Z", model: "model-z", credits: 61, fault: "breaker_qualifying", quarantined: true})
	add(rollupCredit{ts: "2026-09-16T10:00:00.000000000Z", model: "model-enf", credits: 67, enforce: true})
	add(rollupCredit{provider: "p-b", ts: "2026-09-16T01:00:00.000000000Z", model: "model-a", credits: 71})
	add(rollupCredit{provider: "p-b", ts: "2026-09-01T01:00:00.000000000Z", model: "model-b", credits: 73, quarantined: true})
}

// The rollup answers exactly what the view answers on seeded data covering
// quarantine, resolutions (void, matured and held force-credit, corrected),
// enforce rows without evidence, faults, ranges and the week/today edges,
// both before any recompute (all live), after a drain (all cached), and after
// direct writes to every view input with no recompute in between.
func TestProviderEarningsRollupMatchesViewOnSeededData(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	createAuditLogForTest(t, store.db)
	seedRollupFixture(t, store)
	providers := []string{"p-a", "p-b", "p-none"}
	wins := rollupTestWindows(time.Date(2026, 9, 16, 0, 0, 0, 0, time.UTC))
	wins = append(wins, rollupTestWindows(time.Date(2026, 9, 14, 0, 0, 0, 0, time.UTC))...)

	checkRollupMatchesView(t, store, providers, wins)
	if n := cachedBucketCount(t, store, "p-a"); n != 0 {
		t.Fatalf("cached buckets before drain=%d want 0", n)
	}
	drainRollup(t, store)
	if n := cachedBucketCount(t, store, "p-a"); n < 10 {
		t.Fatalf("cached buckets after drain=%d, fixture not served from the cache", n)
	}
	checkRollupMatchesView(t, store, providers, wins)
	want, err := viewEarningsReference(context.Background(), store.db, "p-a", wins[0])
	if err != nil {
		t.Fatal(err)
	}
	if want.total != 11+13+17+19+23+29+31+32+43+59 || want.faults != 2 || len(want.models) != 6 {
		t.Fatalf("fixture lost its payable/non-payable mix: %+v", want)
	}

	mutations := []struct {
		name string
		sql  string
	}{
		{"quarantine a cached row", `UPDATE ledger_request_credits SET quarantined = 1 WHERE model = 'model-d'`},
		{"release a quarantined row", `UPDATE ledger_request_credits SET quarantined = 0 WHERE model = 'model-q'`},
		{"change credits", `UPDATE ledger_request_credits SET provider_credits = provider_credits + 1000 WHERE model = 'model-b' AND provider_id = 'p-a'`},
		{"move a row across midnight", `UPDATE ledger_request_credits SET ts_utc = '2026-09-15T22:00:00.000000000Z' WHERE model = 'model-c'`},
		{"rename a model", `UPDATE ledger_request_credits SET model = 'model-renamed' WHERE model = 'model-e' AND ts_utc LIKE '2026-08-15%'`},
		{"raise a fault", `UPDATE ledger_request_credits SET fault_flag = 'breaker_qualifying' WHERE model = 'model-b' AND provider_id = 'p-a'`},
		{"move a row to another provider", `UPDATE ledger_request_credits SET provider_id = 'p-b' WHERE model = 'model-fc'`},
		{"delete a credit", `DELETE FROM ledger_request_credits WHERE model = 'model-e' AND provider_id = 'p-a'`},
		{"correct a void to credit", `INSERT INTO ledger_quarantine_resolutions(request_credit_id, resolution_kind, operator_id, resolution_reason, created_at_utc, force_credit_matures_at_utc, correction_deadline_at_utc)
SELECT id, 'force_credit', 'op', 'x', '2026-09-15T07:00:00.000000000Z', '2026-09-15T08:00:00.000000000Z', '2026-09-15T07:00:00.000000000Z' FROM ledger_request_credits WHERE model = 'model-v'`},
		{"edit a resolution", `UPDATE ledger_quarantine_resolutions SET force_credit_matures_at_utc = '2000-01-01T00:00:00.000000000Z' WHERE force_credit_matures_at_utc = '2999-01-01T00:00:00.000000000Z'`},
		{"delete a resolution", `DELETE FROM ledger_quarantine_resolutions WHERE resolution_kind = 'force_void' AND created_at_utc = '2026-09-15T10:00:00.000000000Z'`},
		{"insert a new hour", `INSERT INTO ledger_request_credits (request_id, attempt_n, provider_id, ts_utc, model, status, stream, usage_source, prompt_rate_per_mtok, completion_rate_per_mtok, global_multiplier_ppm, gross_credits, provider_share_bps, provider_credits, created_at_utc)
VALUES ('late', 0, 'p-a', '2026-09-16T23:59:59.999999999Z', 'model-late', 200, 0, 'provider_reported', 1, 1, 1, 5, 9000, 5, '2026-09-16T23:59:59.999999999Z')`},
	}
	for _, m := range mutations {
		t.Run(m.name, func(t *testing.T) {
			if _, err := store.db.Exec(m.sql); err != nil {
				t.Fatal(err)
			}
			checkRollupMatchesView(t, store, providers, wins)
			drainRollup(t, store)
			checkRollupMatchesView(t, store, providers, wins)
		})
	}
}

// Settlement stamps settled/settlement_id on every row of a window; that
// cannot change a figure, so it must not dirty a bucket.
func TestProviderEarningsRollupIgnoresSettlementStamping(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	windowStart := time.Date(2026, 7, 1, 0, 0, 0, 0, time.UTC)
	insertCreditWithOperator(t, store.db, "settle-a", "provider-a", windowStart.Add(time.Hour), 600)
	drainRollup(t, store)
	before := scalar(t, store.db, `SELECT SUM(gen) FROM provider_earnings_rollup_buckets`)
	if err := store.RunSettlement(context.Background(), SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, windowStart, windowStart.AddDate(0, 0, 7)); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE settled = 1`); got != 1 {
		t.Fatalf("settled rows=%d want 1", got)
	}
	if after := scalar(t, store.db, `SELECT SUM(gen) FROM provider_earnings_rollup_buckets`); after != before {
		t.Fatalf("settlement stamping bumped bucket generations %d -> %d", before, after)
	}
	checkRollupMatchesView(t, store, []string{"provider-a"}, rollupTestWindows(windowStart))
}

// A held force credit matures with no write at all. The bucket carries the
// maturity instant, stops being trusted once it passes, and the endpoint
// reads it live until the next recompute.
func TestProviderEarningsRollupForceCreditMaturityCrossingNow(t *testing.T) {
	store := quarantineFixture(t)
	id := insertQuarantinedCredit(t, store, "p-mature")
	// The force-credit writer matures the credit hold seconds after store.now.
	holdEnds := time.Now().UTC().Add(4 * time.Second)
	store.now = func() time.Time { return holdEnds.Add(-24 * time.Hour) }
	if w := doForceCredit(t, store, true, id, `{"operator_id":"alice","reason":"manual credit"}`, "application/json"); w.Code != http.StatusOK {
		t.Fatalf("force-credit status=%d body=%s", w.Code, w.Body.String())
	}
	today := time.Now().UTC().Truncate(24 * time.Hour)
	wins := rollupTestWindows(today)
	drainRollup(t, store)
	if n := scalar(t, store.db, `SELECT COUNT(*) FROM provider_earnings_rollup_buckets WHERE provider_id = 'p-mature' AND stale_at_utc IS NOT NULL`); n != 1 {
		t.Fatalf("buckets carrying a maturity=%d want 1", n)
	}
	checkRollupMatchesView(t, store, []string{"p-mature"}, wins)
	got, _, err := store.providerEarningsFromRollup(context.Background(), "p-mature", wins[0])
	if time.Now().After(holdEnds) {
		t.Fatal("fixture too slow: the hold ended before the held read finished")
	}
	if err != nil || got.total != 0 {
		t.Fatalf("held force credit total=%d err=%v want 0", got.total, err)
	}
	time.Sleep(time.Until(holdEnds) + 50*time.Millisecond)
	// No write and no recompute: the stale bucket must be read live.
	checkRollupMatchesView(t, store, []string{"p-mature"}, wins)
	got, _, err = store.providerEarningsFromRollup(context.Background(), "p-mature", wins[0])
	if err != nil || got.total != 1000 {
		t.Fatalf("matured force credit total=%d err=%v want 1000", got.total, err)
	}
	drainRollup(t, store)
	if n := scalar(t, store.db, `SELECT COUNT(*) FROM provider_earnings_rollup_buckets WHERE stale_at_utc IS NOT NULL`); n != 0 {
		t.Fatalf("buckets still carrying a maturity after recompute=%d", n)
	}
	checkRollupMatchesView(t, store, []string{"p-mature"}, wins)
}

// Each production writer that can change payable status, run against a
// drained rollup: the very next read must already match the view (the
// writer marked its bucket), and so must the read after a recompute.
func TestProviderEarningsRollupConsistentAcrossWriters(t *testing.T) {
	// wins is read after fn, which may establish the fixture's timestamps.
	step := func(t *testing.T, store *Store, providers []string, wins *[]earningsWindows, name string, fn func()) {
		t.Helper()
		drainRollup(t, store)
		fn()
		t.Logf("after %s", name)
		checkRollupMatchesView(t, store, providers, *wins)
		drainRollup(t, store)
		checkRollupMatchesView(t, store, providers, *wins)
	}

	t.Run("receipt verdict, attempt output and settlement close", func(t *testing.T) {
		fixtures := loadSettlementVerifierFixtures(t)
		pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
		tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
		input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
		input.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
		input.RouteSnapshot.RouteSnapshotPolicyVersion = RouteSnapshotPolicyVersion
		routeDigest, _, err := input.RouteSnapshot.Digest()
		if err != nil {
			t.Fatal(err)
		}
		input.Header = settlementHeaderWithCanonicalMutationAndTestSignature(t, input.Header, func(tuple map[string]any) {
			tuple["route_snapshot_mode"] = RouteSnapshotModeEnforce
			tuple["route_snapshot_policy_version"] = RouteSnapshotPolicyVersion
			tuple["route_snapshot_digest"] = routeDigest
		})
		_, store := newRequestAndBillingStores(t)
		createSettlementReceiptAuditLog(t, store.db)
		providers := []string{input.ProviderID}
		var wins []earningsWindows
		step(t, store, providers, &wins, "route snapshot and attempt output", func() {
			seedSettlementReceiptEvidence(t, store, input)
		})
		var credits int64
		step(t, store, providers, &wins, "hot-path credit", func() {
			credits = insertSPEC022ReceiptBoundLedgerCredit(t, store.db, input, 100).ProviderCredits
			var ts string
			if err := store.db.QueryRow(`SELECT ts_utc FROM ledger_request_credits WHERE request_id = ?`, input.RequestID).Scan(&ts); err != nil {
				t.Fatal(err)
			}
			at, err := time.Parse(time.RFC3339Nano, ts)
			if err != nil {
				t.Fatal(err)
			}
			wins = rollupTestWindows(at.UTC().Truncate(24 * time.Hour))
		})
		if got, _, _ := store.providerEarningsFromRollup(context.Background(), input.ProviderID, wins[0]); got.total != 0 {
			t.Fatalf("enforce credit payable before its receipt: %+v", got)
		}
		step(t, store, providers, &wins, "verified receipt", func() {
			setSettlementReceiptNow(store, input.ReceiptReceivedUnixMS)
			state, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
				SettlementReceiptIdentity: settlementIdentityFromInput(input),
				Header:                    input.Header,
				ProviderReceiptPubkey:     pubkey,
				receiptReceivedUnixMS:     input.ReceiptReceivedUnixMS,
			})
			if err != nil || state.SettlementOutcome != SettlementOutcomeVerified {
				t.Fatalf("ingest state=%+v err=%v", state, err)
			}
		})
		if got, _, _ := store.providerEarningsFromRollup(context.Background(), input.ProviderID, wins[0]); got.total != credits {
			t.Fatalf("verified credit total=%d want %d", got.total, credits)
		}
		step(t, store, providers, &wins, "settlement close", func() {
			windowStart, windowEnd := settlementWindowForInput(input)
			if err := store.RunSettlement(context.Background(), SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, windowStart, windowEnd); err != nil {
				t.Fatal(err)
			}
		})
	})

	t.Run("undelivered quarantine and expiry sweep", func(t *testing.T) {
		store, route := enforceCreditFixture(t, "rollup-undelivered", false, true, RouteSnapshotModeEnforce)
		providers := []string{route.ProviderID}
		wins := rollupTestWindows(enforceCreditFixtureTS.Truncate(24 * time.Hour))
		step(t, store, providers, &wins, "expiry sweep", func() {
			if _, err := store.SweepExpiredSettlementVerdicts(context.Background(), time.Now().UnixMilli(), DefaultPoolSettlementExpirySweepLimit); err != nil {
				t.Fatal(err)
			}
		})
		step(t, store, providers, &wins, "undelivered quarantine", func() {
			if _, err := store.QuarantineUndeliveredSettlementCredit(context.Background(), route.AccountScope, route.RequestID, 0, route.ProviderID, UndeliveredSettlementQuarantineReasons[0]); err != nil {
				t.Fatal(err)
			}
		})
	})

	t.Run("verified enforce credit", func(t *testing.T) {
		store, route := enforceCreditFixture(t, "rollup-verified", true, true, RouteSnapshotModeEnforce)
		providers := []string{route.ProviderID}
		wins := rollupTestWindows(enforceCreditFixtureTS.Truncate(24 * time.Hour))
		step(t, store, providers, &wins, "seed", func() {})
	})

	t.Run("force void and force credit", func(t *testing.T) {
		store := quarantineFixture(t)
		now := time.Date(2026, 7, 1, 12, 0, 0, 0, time.UTC)
		store.now = func() time.Time { return now }
		voidID := insertQuarantinedCredit(t, store, "p-res")
		creditID := insertQuarantinedCredit(t, store, "p-res")
		wins := rollupTestWindows(time.Now().UTC().Truncate(24 * time.Hour))
		providers := []string{"p-res"}
		step(t, store, providers, &wins, "force void", func() {
			if w := doForceVoid(t, store, true, voidID, `{"operator_id":"alice","reason":"void"}`, "application/json"); w.Code != http.StatusOK {
				t.Fatalf("force-void status=%d body=%s", w.Code, w.Body.String())
			}
		})
		// Hold ends 2026-07-02: already in the past, so payable at once.
		step(t, store, providers, &wins, "force credit", func() {
			if w := doForceCredit(t, store, true, creditID, `{"operator_id":"alice","reason":"credit"}`, "application/json"); w.Code != http.StatusOK {
				t.Fatalf("force-credit status=%d body=%s", w.Code, w.Body.String())
			}
		})
		if got, _, _ := store.providerEarningsFromRollup(context.Background(), "p-res", wins[0]); got.pending != 1000 {
			t.Fatalf("matured force credit pending=%d want 1000", got.pending)
		}
		step(t, store, providers, &wins, "corrective void", func() {
			if w := doForceVoid(t, store, true, creditID, `{"operator_id":"bob","reason":"correct"}`, "application/json"); w.Code != http.StatusOK {
				t.Fatalf("corrective void status=%d body=%s", w.Code, w.Body.String())
			}
		})
		if got, _, _ := store.providerEarningsFromRollup(context.Background(), "p-res", wins[0]); got.pending != 0 {
			t.Fatalf("corrected force credit pending=%d want 0", got.pending)
		}
	})
}

// A write that lands between a recompute's read snapshot and its commit must
// leave the bucket dirty, never cache the pre-write figures.
func TestProviderEarningsRollupRecomputeRejectsMovedGeneration(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	id := insertRollupCredit(t, store.db, rollupCredit{requestID: "r1", provider: "p", ts: "2026-09-16T05:00:00.000000000Z", model: "m", credits: 10})
	fired := false
	store.earningsRollupAfterRead = func(string, string) {
		if !fired {
			fired = true
			if _, err := store.db.Exec(`UPDATE ledger_request_credits SET quarantined = 1 WHERE id = ?`, id); err != nil {
				t.Error(err)
			}
		}
	}
	pass, err := store.RefreshProviderEarningsRollup(context.Background(), 10)
	if err != nil {
		t.Fatal(err)
	}
	if pass.Recomputed != 0 || !fired {
		t.Fatalf("pass=%+v fired=%v; want the raced recompute rejected", pass, fired)
	}
	if n := scalar(t, store.db, `SELECT COUNT(*) FROM provider_earnings_rollup_buckets WHERE gen != computed_gen`); n != 1 {
		t.Fatalf("dirty buckets=%d want 1", n)
	}
	store.earningsRollupAfterRead = nil
	drainRollup(t, store)
	checkRollupMatchesView(t, store, []string{"p"}, rollupTestWindows(time.Date(2026, 9, 16, 0, 0, 0, 0, time.UTC)))
	if got := scalar(t, store.db, `SELECT COALESCE(SUM(payable_credits), 0) FROM provider_earnings_rollup WHERE provider_id = 'p'`); got != 0 {
		t.Fatalf("cached payable credits=%d want 0 after quarantine", got)
	}
}

// Writers, the refresh job and readers run concurrently. Every read compares
// the rollup path with the view inside one read snapshot.
func TestProviderEarningsRollupConcurrentWritersAndJob(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollup.db")
	reqStore, err := requestlog.OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reqStore.Close() })
	store, err := NewStore(reqStore.DB())
	if err != nil {
		t.Fatal(err)
	}
	readDB, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(path))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = readDB.Close() })
	readDB.SetMaxOpenConns(4)
	store.SetReadDB(readDB)

	providers := []string{"c-1", "c-2", "c-3"}
	day := time.Date(2026, 9, 16, 0, 0, 0, 0, time.UTC)
	wins := rollupTestWindows(day)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var wg sync.WaitGroup
	errs := make(chan error, 16)
	var writes, reads, recomputed atomic.Int64

	for w := 0; w < 2; w++ {
		wg.Add(1)
		go func(seed int64) {
			defer wg.Done()
			rng := rand.New(rand.NewSource(seed))
			var ids []int64
			for i := 0; i < 400 && ctx.Err() == nil; i++ {
				var err error
				switch op := rng.Intn(6); {
				case op <= 1 || len(ids) == 0:
					at := day.Add(time.Duration(rng.Intn(72)-48) * time.Hour).Add(time.Duration(rng.Intn(3600)) * time.Second)
					var id int64
					id, err = insertRollupCreditErr(store.db, rollupCredit{
						requestID: fmt.Sprintf("w%d-%d", seed, i), provider: providers[rng.Intn(len(providers))],
						ts: sqliteTimeText(at), model: fmt.Sprintf("m-%d", rng.Intn(3)), credits: int64(1 + rng.Intn(100)),
						quarantined: rng.Intn(3) == 0,
					})
					ids = append(ids, id)
				case op == 2:
					_, err = store.db.Exec(`UPDATE ledger_request_credits SET quarantined = 1 - quarantined WHERE id = ?`, ids[rng.Intn(len(ids))])
				case op == 3:
					kinds := []string{"force_credit", "force_void"}
					matures := []string{"2000-01-01T00:00:00.000000000Z", "2999-01-01T00:00:00.000000000Z"}[rng.Intn(2)]
					err = insertRollupResolutionErr(store.db, ids[rng.Intn(len(ids))], kinds[rng.Intn(2)], sqliteTimeText(time.Now()), matures)
				case op == 4:
					_, err = store.db.Exec(`UPDATE ledger_request_credits SET provider_credits = ? WHERE id = ?`, rng.Intn(100), ids[rng.Intn(len(ids))])
				default:
					_, err = store.db.Exec(`UPDATE ledger_request_credits SET fault_flag = CASE fault_flag WHEN 'none' THEN 'breaker_qualifying' ELSE 'none' END WHERE id = ?`, ids[rng.Intn(len(ids))])
				}
				if err != nil {
					errs <- err
					return
				}
				writes.Add(1)
			}
		}(int64(w + 1))
	}
	jobDone := make(chan struct{})
	go func() {
		defer close(jobDone)
		for ctx.Err() == nil {
			pass, err := store.RefreshProviderEarningsRollup(ctx, 5)
			if err != nil && ctx.Err() == nil {
				errs <- err
				return
			}
			recomputed.Add(int64(pass.Recomputed))
		}
	}()
	readerDone := make(chan struct{})
	go func() {
		defer close(readerDone)
		for i := 0; ctx.Err() == nil; i++ {
			provider, win := providers[i%len(providers)], wins[i%len(wins)]
			tx, err := readDB.BeginTx(ctx, nil)
			if err != nil {
				if ctx.Err() == nil {
					errs <- err
				}
				return
			}
			got, ok, err := store.providerEarningsFromRollupTx(ctx, tx, provider, win)
			if errors.Is(err, errEarningsRollupMaturityRace) {
				err = nil
			} else if err == nil && ok {
				var want providerEarningsFigures
				want, err = viewEarningsReference(ctx, tx, provider, win)
				if err == nil && !reflect.DeepEqual(got, want) {
					err = fmt.Errorf("%s %+v: rollup=%+v view=%+v", provider, win, got, want)
				}
			}
			_ = tx.Rollback()
			if err != nil {
				if ctx.Err() == nil {
					errs <- err
				}
				return
			}
			reads.Add(1)
		}
	}()
	wg.Wait()
	cancel()
	<-jobDone
	<-readerDone
	close(errs)
	for err := range errs {
		if !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
	}
	if reads.Load() == 0 || recomputed.Load() == 0 {
		t.Fatalf("too little overlap: writes=%d reads=%d recomputed=%d", writes.Load(), reads.Load(), recomputed.Load())
	}
	t.Logf("writes=%d reads=%d recomputed=%d", writes.Load(), reads.Load(), recomputed.Load())
	drainRollup(t, store)
	checkRollupMatchesView(t, store, providers, wins)
}

// The backfill marks rows that predate the triggers in batches, persists its
// cursor with each batch, resumes after a restart, and the migration is a
// no-op when nothing changed.
func TestProviderEarningsRollupBackfillIsBatchedAndResumable(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	db := store.db
	// Simulate a pre-#1925 database: no rollup objects, existing history.
	for _, t2 := range providerEarningsRollupTriggers() {
		if _, err := db.Exec(`DROP TRIGGER ` + t2.name); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := db.Exec(`DROP TABLE provider_earnings_rollup_state; DROP TABLE provider_earnings_rollup_buckets; DROP TABLE provider_earnings_rollup;`); err != nil {
		t.Fatal(err)
	}
	day := time.Date(2026, 9, 16, 0, 0, 0, 0, time.UTC)
	const preexisting = 23
	for i := 0; i < preexisting; i++ {
		insertRollupCredit(t, db, rollupCredit{
			requestID: fmt.Sprintf("old-%d", i), provider: []string{"b-1", "b-2"}[i%2],
			ts: sqliteTimeText(day.Add(time.Duration(i*5-40) * time.Hour)), model: "m", credits: int64(i + 1),
			quarantined: i%7 == 0,
		})
	}
	store, err := NewStore(reqStore.DB())
	if err != nil {
		t.Fatal(err)
	}
	store.earningsRollupBackfillBatch = 4
	high := scalar(t, db, `SELECT backfill_high_id FROM provider_earnings_rollup_state`)
	if high != preexisting || scalar(t, db, `SELECT backfill_complete FROM provider_earnings_rollup_state`) != 0 {
		t.Fatalf("after migration high=%d complete=%d", high, scalar(t, db, `SELECT backfill_complete FROM provider_earnings_rollup_state`))
	}
	// A row written after the migration marks itself through its trigger.
	insertRollupCredit(t, db, rollupCredit{requestID: "new", provider: "b-3", ts: sqliteTimeText(day.Add(time.Hour)), model: "m", credits: 5})
	if n := scalar(t, db, `SELECT COUNT(*) FROM provider_earnings_rollup_buckets WHERE provider_id = 'b-3'`); n != 1 {
		t.Fatalf("post-migration row buckets=%d want 1", n)
	}
	wins := rollupTestWindows(day)
	if _, ok, err := store.providerEarningsFromRollup(context.Background(), "b-1", wins[0]); err != nil || ok {
		t.Fatalf("rollup served before backfill completed: ok=%v err=%v", ok, err)
	}
	// First batch, then a restart.
	if _, err := store.RefreshProviderEarningsRollup(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, db, `SELECT backfill_cursor_id FROM provider_earnings_rollup_state`); got != 4 {
		t.Fatalf("cursor after one batch=%d want 4", got)
	}
	epoch := scalar(t, db, `SELECT epoch FROM provider_earnings_rollup_state`)
	store, err = NewStore(reqStore.DB())
	if err != nil {
		t.Fatal(err)
	}
	store.earningsRollupBackfillBatch = 4
	if got := scalar(t, db, `SELECT epoch FROM provider_earnings_rollup_state`); got != epoch {
		t.Fatalf("restart reset the rollup: epoch %d -> %d", epoch, got)
	}
	if got := scalar(t, db, `SELECT backfill_cursor_id FROM provider_earnings_rollup_state`); got != 4 {
		t.Fatalf("cursor after restart=%d want 4", got)
	}
	passes := 1
	for scalar(t, db, `SELECT backfill_complete FROM provider_earnings_rollup_state`) == 0 {
		if passes > 20 {
			t.Fatal("backfill did not complete")
		}
		if _, err := store.RefreshProviderEarningsRollup(context.Background(), 1); err != nil {
			t.Fatal(err)
		}
		passes++
	}
	if passes != (preexisting+3)/4 {
		t.Fatalf("backfill passes=%d want %d batches of 4", passes, (preexisting+3)/4)
	}
	drainRollup(t, store)
	checkRollupMatchesView(t, store, []string{"b-1", "b-2", "b-3"}, wins)
	// Idempotent: one more migration changes nothing.
	buckets := scalar(t, db, `SELECT COUNT(*) FROM provider_earnings_rollup_buckets WHERE gen = computed_gen`)
	if _, err := NewStore(reqStore.DB()); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, db, `SELECT COUNT(*) FROM provider_earnings_rollup_buckets WHERE gen = computed_gen`); got != buckets {
		t.Fatalf("idempotent migration changed cached buckets %d -> %d", buckets, got)
	}
}

// A dropped trigger (a table rebuild) or a changed payable view resets the
// cache; the rollup is not served until the backfill runs again.
func TestProviderEarningsRollupResetsOnTriggerLossOrViewChange(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	insertRollupCredit(t, store.db, rollupCredit{requestID: "r", provider: "p", ts: "2026-09-16T05:00:00.000000000Z", model: "m", credits: 10})
	drainRollup(t, store)
	for _, tc := range []struct {
		name   string
		mutate string
	}{
		{"trigger dropped", `DROP TRIGGER trg_per_srv_update`},
		{"view definition changed", `UPDATE provider_earnings_rollup_state SET fingerprint = 'older-view'`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			epoch := scalar(t, store.db, `SELECT epoch FROM provider_earnings_rollup_state`)
			if _, err := store.db.Exec(tc.mutate); err != nil {
				t.Fatal(err)
			}
			restarted, err := NewStore(reqStore.DB())
			if err != nil {
				t.Fatal(err)
			}
			if got := scalar(t, store.db, `SELECT epoch FROM provider_earnings_rollup_state`); got != epoch+1 {
				t.Fatalf("epoch %d -> %d, want a reset", epoch, got)
			}
			// The reset is an epoch switch: rows stay, none is trusted.
			if n := scalar(t, store.db, `SELECT COUNT(*) FROM provider_earnings_rollup_buckets b, provider_earnings_rollup_state s WHERE b.computed_epoch = s.epoch`); n != 0 {
				t.Fatalf("buckets current after reset=%d", n)
			}
			if n := scalar(t, store.db, `SELECT COUNT(*) FROM provider_earnings_rollup_buckets`); n == 0 {
				t.Fatal("reset deleted cached rows; it must only switch the epoch")
			}
			if n := scalar(t, store.db, `SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'trg_per_%'`); n != int64(len(providerEarningsRollupTriggers())) {
				t.Fatalf("triggers after reset=%d", n)
			}
			if _, ok, _ := restarted.providerEarningsFromRollup(context.Background(), "p", earningsWindows{}); ok {
				t.Fatal("rollup served before the backfill re-ran")
			}
			drainRollup(t, restarted)
			checkRollupMatchesView(t, restarted, []string{"p"}, rollupTestWindows(time.Date(2026, 9, 16, 0, 0, 0, 0, time.UTC)))
		})
	}
}

// Guards the trigger set against a future view change: every ledger column
// the view reads must be in the UPDATE trigger's column list, and every table
// the view reads must carry triggers.
func TestProviderEarningsRollupTriggerCoversViewColumns(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	var viewSQL string
	if err := store.db.QueryRow(`SELECT sql FROM sqlite_master WHERE type='view' AND name='spec022_payable_request_credits'`).Scan(&viewSQL); err != nil {
		t.Fatal(err)
	}
	cols := map[string]bool{}
	for _, c := range earningsRollupLRCColumns {
		cols[c] = true
	}
	for _, m := range regexp.MustCompile(`\blrc\.([a-z_]+)`).FindAllStringSubmatch(viewSQL, -1) {
		if !cols[m[1]] {
			t.Errorf("view reads lrc.%s, missing from earningsRollupLRCColumns", m[1])
		}
	}
	triggered := map[string]bool{}
	for _, tr := range providerEarningsRollupTriggers() {
		m := regexp.MustCompile(` ON ([a-z_]+)`).FindStringSubmatch(tr.ddl)
		triggered[m[1]] = true
	}
	for _, m := range regexp.MustCompile(`(?i)\b(?:FROM|JOIN)\s+([a-z_0-9]+)`).FindAllStringSubmatch(viewSQL, -1) {
		if !triggered[m[1]] {
			t.Errorf("view reads table %s, which has no rollup triggers", m[1])
		}
	}
}

// A provider with a row whose ts_utc does not start with a valid hour is
// served from the full view, with identical figures over HTTP.
func TestProviderEarningsEndpointFallsBackForUnbucketableTimestamps(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	now := time.Now().UTC()
	insertCredit(t, store.db, "provider-a", now.Add(-time.Hour), 500)
	insertRollupCredit(t, store.db, rollupCredit{requestID: "odd", provider: "provider-a", ts: now.Format("2006-01-02 15:04:05"), model: "model-a", credits: 7})
	drainRollup(t, store)
	if _, ok, err := store.providerEarningsFromRollup(context.Background(), "provider-a", earningsWindows{}); err != nil || ok {
		t.Fatalf("rollup served a provider with an unbucketable row: ok=%v err=%v", ok, err)
	}
	handler := store.Handlers("operator", fakeTokens{"good": "provider-a"}, true, 60)
	req := httptest.NewRequest(http.MethodGet, "/providers/provider-a/earnings", nil)
	req.Header.Set("Authorization", "Bearer good")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"total_credits":507`) {
		t.Fatalf("status=%d body=%s; want total 507 from the view", rec.Code, rec.Body.String())
	}
}

// The HTTP response built from the rollup carries the view's figures.
func TestProviderEarningsEndpointServesRollupFigures(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	now := time.Now().UTC()
	insertCredit(t, store.db, "provider-a", now.Add(-time.Millisecond), 500)
	insertCredit(t, store.db, "provider-a", now.AddDate(0, 0, -10), 300)
	insertRollupCredit(t, store.db, rollupCredit{requestID: "f", provider: "provider-a", ts: sqliteTimeText(now.AddDate(0, 0, -2)), model: "model-f", credits: 9, fault: "breaker_qualifying", quarantined: true})
	drainRollup(t, store)
	handler := store.Handlers("operator", fakeTokens{"good": "provider-a"}, true, 60)
	req := httptest.NewRequest(http.MethodGet, "/providers/provider-a/earnings", nil)
	req.Header.Set("Authorization", "Bearer good")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	body := rec.Body.String()
	for _, want := range []string{`"total_credits":800`, `"fault_count":1`, `"models_served":["model-a"]`, `"usdc_today":0.0005`, `"usdc_lifetime":0.0008`, `"usdc_pending":0.0008`} {
		if rec.Code != http.StatusOK || !strings.Contains(body, want) {
			t.Fatalf("status=%d body=%s; missing %s", rec.Code, body, want)
		}
	}
}

func TestRetrySQLiteBusyRetriesThenGivesUp(t *testing.T) {
	busy := errors.New("database is locked")
	calls := 0
	var slept []time.Duration
	err := retrySQLiteBusy(context.Background(), "test", time.Minute, func(d time.Duration) { slept = append(slept, d) }, func() error {
		calls++
		if calls < 3 {
			return busy
		}
		return nil
	})
	if err != nil || calls != 3 || len(slept) != 2 {
		t.Fatalf("err=%v calls=%d slept=%v", err, calls, slept)
	}
	err = retrySQLiteBusy(context.Background(), "test", 0, func(time.Duration) {}, func() error { return busy })
	if !errors.Is(err, busy) {
		t.Fatalf("exhausted budget err=%v want wrapped busy", err)
	}
	other := errors.New("no such table")
	if err := retrySQLiteBusy(context.Background(), "test", time.Minute, func(time.Duration) { t.Fatal("slept on a non-busy error") }, func() error { return other }); !errors.Is(err, other) {
		t.Fatalf("non-busy err=%v", err)
	}
}

// REPLACE conflicts delete rows without firing delete triggers (SQLite's
// recursive_triggers is off); the BEFORE triggers must still mark the old
// row's bucket. Covers a changed hour, a changed provider via an explicit id,
// UPDATE OR REPLACE, and replaced related rows (resolution, verdict).
func TestProviderEarningsRollupReplacementWritesMarkOldBuckets(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	if got := scalar(t, store.db, `PRAGMA recursive_triggers`); got != 0 {
		t.Fatalf("recursive_triggers=%d; this test needs the production default (off)", got)
	}
	db := store.db
	day := time.Date(2026, 9, 16, 0, 0, 0, 0, time.UTC)
	wins := rollupTestWindows(day)
	providers := []string{"r-a", "r-b"}
	a := insertRollupCredit(t, db, rollupCredit{requestID: "rep-1", provider: "r-a", ts: "2026-09-16T03:00:00.000000000Z", model: "m", credits: 100})
	b := insertRollupCredit(t, db, rollupCredit{requestID: "rep-2", provider: "r-a", ts: "2026-09-15T03:00:00.000000000Z", model: "m", credits: 200, quarantined: true})
	insertRollupCredit(t, db, rollupCredit{requestID: "rep-3", provider: "r-b", ts: "2026-09-14T03:00:00.000000000Z", model: "m", credits: 300})
	c := insertRollupCredit(t, db, rollupCredit{requestID: "rep-4", provider: "r-b", ts: "2026-09-13T03:00:00.000000000Z", model: "m", credits: 400, quarantined: true})
	insertRollupResolution(t, db, b, "force_credit", "2026-09-15T04:00:00.000000000Z", "2000-01-01T00:00:00.000000000Z")
	lrcCols := `request_id, attempt_n, provider_id, ts_utc, model, status, stream, usage_source, prompt_rate_per_mtok, completion_rate_per_mtok, global_multiplier_ppm, gross_credits, provider_share_bps, provider_credits, created_at_utc`
	for _, tc := range []struct{ name, sql string }{
		{"same key, new hour", `INSERT OR REPLACE INTO ledger_request_credits (` + lrcCols + `) VALUES ('rep-1', 0, 'r-a', '2026-09-10T03:00:00.000000000Z', 'm', 200, 0, 'provider_reported', 1, 1, 1, 7, 9000, 7, '2026-09-10T03:00:00.000000000Z')`},
		{"explicit id, new provider", fmt.Sprintf(`INSERT OR REPLACE INTO ledger_request_credits (id, `+lrcCols+`) VALUES (%d, 'rep-x', 0, 'r-b', '2026-09-16T05:00:00.000000000Z', 'm', 200, 0, 'provider_reported', 1, 1, 1, 9, 9000, 9, '2026-09-16T05:00:00.000000000Z')`, a)},
		{"update or replace onto another key", `UPDATE OR REPLACE ledger_request_credits SET request_id = 'rep-x', provider_id = 'r-b' WHERE request_id = 'rep-3'`},
		{"replaced resolution moves to another credit", fmt.Sprintf(`INSERT OR REPLACE INTO ledger_quarantine_resolutions(id, request_credit_id, resolution_kind, operator_id, resolution_reason, created_at_utc, force_credit_matures_at_utc, correction_deadline_at_utc)
SELECT id, %d, 'force_void', 'op', 'x', created_at_utc, NULL, created_at_utc FROM ledger_quarantine_resolutions WHERE request_credit_id = %d`, c, b)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			drainRollup(t, store)
			if _, err := db.Exec(tc.sql); err != nil {
				t.Fatal(err)
			}
			checkRollupMatchesView(t, store, providers, wins)
			drainRollup(t, store)
			checkRollupMatchesView(t, store, providers, wins)
		})
	}

	t.Run("replaced verdict moves to another attempt", func(t *testing.T) {
		store, route := enforceCreditFixture(t, "rep-verified", true, true, RouteSnapshotModeEnforce)
		ws := rollupTestWindows(enforceCreditFixtureTS.Truncate(24 * time.Hour))
		if _, err := store.db.Exec(`
INSERT INTO settlement_attempt_outputs(account_scope, request_id, attempt_n, provider_id, terminal_state, terminal_state_ts_unix_ms,
    output_prefix_start_byte, output_prefix_end_byte, usage_hash, usage_canonical_json, usage_source, created_at_utc)
VALUES (?, ?, 0, ?, 'normal_done', 1, 0, 1, ?, '{}', 'coordinator_observed', '2026-09-25T09:00:00Z')`,
			route.AccountScope, route.RequestID, route.ProviderID, strings.Repeat("a", 64)); err != nil {
			t.Fatal(err)
		}
		drainRollup(t, store)
		if got, _, _ := store.providerEarningsFromRollup(context.Background(), route.ProviderID, ws[0]); got.total == 0 {
			t.Fatal("fixture: verified credit not payable")
		}
		if _, err := store.db.Exec(`INSERT OR REPLACE INTO settlement_receipt_verdicts SELECT * FROM settlement_receipt_verdicts WHERE request_id = ?`, route.RequestID); err != nil {
			t.Fatal(err)
		}
		if _, err := store.db.Exec(`UPDATE OR REPLACE settlement_receipt_verdicts SET request_id = 'elsewhere' WHERE request_id = ?`, route.RequestID); err != nil {
			t.Fatal(err)
		}
		checkRollupMatchesView(t, store, []string{route.ProviderID}, ws)
		if got, _, _ := store.providerEarningsFromRollup(context.Background(), route.ProviderID, ws[0]); got.total != 0 {
			t.Fatalf("credit still payable after its verdict moved: %+v", got)
		}
	})
}

// The guard for the replacement triggers: their conflict keys are the
// schema's UNIQUE keys.
func TestProviderEarningsRollupReplaceKeysMatchSchema(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	for _, table := range []string{"ledger_request_credits", "ledger_quarantine_resolutions", "settlement_route_snapshots", "settlement_receipt_verdicts", "settlement_attempt_outputs"} {
		var pk string
		if err := store.db.QueryRow(`SELECT group_concat(name) FROM pragma_table_info(?) WHERE pk > 0`, table).Scan(&pk); err != nil || pk != "id" {
			t.Fatalf("%s primary key=%q err=%v, want id", table, pk, err)
		}
		rows, err := store.db.Query(`SELECT il.name FROM pragma_index_list(?) il WHERE il."unique" = 1`, table)
		if err != nil {
			t.Fatal(err)
		}
		var names []string
		for rows.Next() {
			var n string
			if err := rows.Scan(&n); err != nil {
				t.Fatal(err)
			}
			names = append(names, n)
		}
		rows.Close()
		if table == "ledger_quarantine_resolutions" && len(names) != 0 {
			t.Fatalf("%s has UNIQUE indexes %v the replacement trigger does not cover", table, names)
		}
		for _, n := range names {
			cols := map[string]bool{}
			crow, err := store.db.Query(`SELECT name FROM pragma_index_info(?)`, n)
			if err != nil {
				t.Fatal(err)
			}
			var list []string
			for crow.Next() {
				var c sql.NullString
				if err := crow.Scan(&c); err != nil {
					t.Fatal(err)
				}
				if !c.Valid {
					t.Fatalf("%s.%s is an expression index the replacement trigger does not cover", table, n)
				}
				cols[c.String] = true
				list = append(list, c.String)
			}
			crow.Close()
			if table == "ledger_request_credits" {
				if !reflect.DeepEqual(list, earningsRollupLRCKey) {
					t.Fatalf("%s unique key %v, trigger covers %v", table, list, earningsRollupLRCKey)
				}
				continue
			}
			for _, c := range earningsRollupLRCKey {
				if !cols[c] {
					t.Fatalf("%s unique key %v lacks %s: a key conflict could delete a row of other credits", table, list, c)
				}
			}
		}
	}
}

// Credit A sits in a cached hour, B in a live hour; both mature after the
// read fixed its cutoff and before its live statements. Without the shared
// cutoff the read would count B and not A, a total the view never had.
func TestProviderEarningsRollupMaturityDuringReadIsCoherent(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	db := store.db
	soon := time.Now().UTC().Add(1500 * time.Millisecond)
	a := insertRollupCredit(t, db, rollupCredit{requestID: "a", provider: "p", ts: "2026-09-15T03:00:00.000000000Z", model: "m", credits: 10, quarantined: true})
	insertRollupResolution(t, db, a, "force_credit", "2026-09-15T04:00:00.000000000Z", sqliteTimeText(soon))
	drainRollup(t, store)
	b := insertRollupCredit(t, db, rollupCredit{requestID: "b", provider: "p", ts: "2026-09-16T03:00:00.000000000Z", model: "m", credits: 20, quarantined: true})
	insertRollupResolution(t, db, b, "force_credit", "2026-09-16T04:00:00.000000000Z", sqliteTimeText(soon.Add(100*time.Millisecond)))
	reads := 0
	store.earningsRollupReadHook = func() {
		reads++
		if reads == 1 {
			time.Sleep(time.Until(soon) + 300*time.Millisecond)
		}
	}
	win := rollupTestWindows(time.Date(2026, 9, 16, 0, 0, 0, 0, time.UTC))[0]
	got, ok, err := store.providerEarningsFromRollup(context.Background(), "p", win)
	if err != nil || !ok {
		t.Fatalf("ok=%v err=%v", ok, err)
	}
	if reads != 2 {
		t.Fatalf("reads=%d; want the raced read retried once", reads)
	}
	if got.total != 30 {
		t.Fatalf("total=%d; want 30 (the view after both maturities), never 20", got.total)
	}
}

// A reset between a recompute's read and its publish must not let the old
// figures become trusted under the new epoch (generation ABA).
func TestProviderEarningsRollupResetBetweenReadAndPublishIsRejected(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	insertRollupCredit(t, store.db, rollupCredit{requestID: "r", provider: "p", ts: "2026-09-16T05:00:00.000000000Z", model: "m", credits: 10})
	fired := false
	store.earningsRollupAfterRead = func(string, string) {
		if fired {
			return
		}
		fired = true
		if _, err := store.db.Exec(`UPDATE provider_earnings_rollup_state SET fingerprint = 'other'`); err != nil {
			t.Error(err)
		}
		if _, err := NewStore(reqStore.DB()); err != nil {
			t.Error(err)
		}
	}
	pass, err := store.RefreshProviderEarningsRollup(context.Background(), 10)
	if err != nil {
		t.Fatal(err)
	}
	if !fired || pass.Recomputed != 0 || pass.Conflicts != 1 {
		t.Fatalf("pass=%+v fired=%v; want the publish rejected", pass, fired)
	}
	if n := cachedBucketCount(t, store, "p"); n != 0 {
		t.Fatalf("buckets trusted under the new epoch=%d", n)
	}
	store.earningsRollupAfterRead = nil
	drainRollup(t, store)
	checkRollupMatchesView(t, store, []string{"p"}, rollupTestWindows(time.Date(2026, 9, 16, 0, 0, 0, 0, time.UTC)))
}

// A pass stops at its context deadline between buckets, without error.
func TestProviderEarningsRollupPassHonoursDeadline(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	for i := 0; i < 10; i++ {
		insertRollupCredit(t, store.db, rollupCredit{requestID: fmt.Sprintf("d-%d", i), provider: "p", ts: sqliteTimeText(time.Date(2026, 9, 16, i, 0, 0, 0, time.UTC)), model: "m", credits: 1})
	}
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	store.earningsRollupAfterRead = func(string, string) { time.Sleep(100 * time.Millisecond) }
	start := time.Now()
	pass, err := store.RefreshProviderEarningsRollup(ctx, 10)
	if err != nil {
		t.Fatalf("deadline surfaced as error: %v", err)
	}
	if elapsed := time.Since(start); elapsed > 400*time.Millisecond {
		t.Fatalf("pass ran %s past a 150ms deadline", elapsed)
	}
	if !pass.More || pass.Recomputed >= 10 {
		t.Fatalf("pass=%+v; want an early stop with more work", pass)
	}
}

// Buckets that conflict on every pass must not starve the rest of the scan.
func TestProviderEarningsRollupConflictingBucketsDoNotStarveOthers(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	for i := 0; i < 8; i++ {
		insertRollupCredit(t, store.db, rollupCredit{requestID: fmt.Sprintf("hot-%d", i), provider: "a-hot", ts: sqliteTimeText(time.Date(2026, 9, 16, i, 0, 0, 0, time.UTC)), model: "m", credits: 1})
	}
	insertRollupCredit(t, store.db, rollupCredit{requestID: "cold", provider: "z-cold", ts: "2026-09-16T01:00:00.000000000Z", model: "m", credits: 1})
	// Every recompute of a hot bucket loses to a write.
	store.earningsRollupAfterRead = func(provider, hour string) {
		if provider == "a-hot" {
			if _, err := store.db.Exec(`UPDATE ledger_request_credits SET provider_credits = provider_credits + 1 WHERE provider_id = 'a-hot' AND ts_utc LIKE ? || '%'`, hour); err != nil {
				t.Error(err)
			}
		}
	}
	for i := 0; i < 4 && cachedBucketCount(t, store, "z-cold") == 0; i++ {
		if _, err := store.RefreshProviderEarningsRollup(context.Background(), 5); err != nil {
			t.Fatal(err)
		}
	}
	if cachedBucketCount(t, store, "z-cold") != 1 {
		t.Fatal("a later provider was starved by buckets that always conflict")
	}
}

// Resetting a populated cache is an epoch switch (constant work at
// startup); the refresher then rebuilds it and the figures stay exact.
func TestProviderEarningsRollupResetOfPopulatedCache(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	for i := 0; i < 40; i++ {
		insertRollupCredit(t, store.db, rollupCredit{requestID: fmt.Sprintf("pop-%d", i), provider: fmt.Sprintf("p-%d", i%4), ts: sqliteTimeText(time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC).Add(time.Duration(i*7) * time.Hour)), model: "m", credits: int64(i)})
	}
	drainRollup(t, store)
	rollupRows := scalar(t, store.db, `SELECT COUNT(*) FROM provider_earnings_rollup`)
	if _, err := store.db.Exec(`UPDATE provider_earnings_rollup_state SET fingerprint = 'other'`); err != nil {
		t.Fatal(err)
	}
	restarted, err := NewStore(reqStore.DB())
	if err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM provider_earnings_rollup`); got != rollupRows {
		t.Fatalf("reset deleted cache rows %d -> %d; it must not bulk-delete", rollupRows, got)
	}
	providers := []string{"p-0", "p-1", "p-2", "p-3"}
	wins := rollupTestWindows(time.Date(2026, 9, 16, 0, 0, 0, 0, time.UTC))
	drainRollup(t, restarted)
	checkRollupMatchesView(t, restarted, providers, wins)
}
