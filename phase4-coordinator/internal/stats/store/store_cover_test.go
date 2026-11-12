package store

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// fakeResult is what the fake driver returns for a query.
type fakeResult struct {
	cols []string
	rows [][]driver.Value
	err  error
}

type fakeCall struct {
	query string
	args  []driver.Value
}

type fakeDB struct {
	handler func(q string) fakeResult
	calls   []fakeCall
}

var fakeSeq atomic.Int64
var fakeRegistry = map[string]*fakeDB{}

type fakeDriver struct{}

func (fakeDriver) Open(name string) (driver.Conn, error) {
	return &fakeConn{db: fakeRegistry[name]}, nil
}

type fakeConn struct{ db *fakeDB }

func (c *fakeConn) Prepare(q string) (driver.Stmt, error) { return &fakeStmt{c: c, q: q}, nil }
func (c *fakeConn) Close() error                          { return nil }
func (c *fakeConn) Begin() (driver.Tx, error)             { return nil, errors.New("no tx") }

type fakeStmt struct {
	c *fakeConn
	q string
}

func (s *fakeStmt) Close() error  { return nil }
func (s *fakeStmt) NumInput() int { return -1 }
func (s *fakeStmt) Exec([]driver.Value) (driver.Result, error) {
	return nil, errors.New("exec not supported")
}
func (s *fakeStmt) Query(args []driver.Value) (driver.Rows, error) {
	s.c.db.calls = append(s.c.db.calls, fakeCall{query: s.q, args: args})
	r := s.c.db.handler(s.q)
	if r.err != nil {
		return nil, r.err
	}
	return &fakeRows{r: r}, nil
}

type fakeRows struct {
	r fakeResult
	i int
}

func (f *fakeRows) Columns() []string { return f.r.cols }
func (f *fakeRows) Close() error      { return nil }
func (f *fakeRows) Next(dest []driver.Value) error {
	if f.i >= len(f.r.rows) {
		return io.EOF
	}
	copy(dest, f.r.rows[f.i])
	f.i++
	return nil
}

func init() { sql.Register("statsstorefake", fakeDriver{}) }

func newFake(t *testing.T, h func(q string) fakeResult) (*Store, *fakeDB) {
	t.Helper()
	f := &fakeDB{handler: h}
	name := "fake" + strconv.FormatInt(fakeSeq.Add(1), 10)
	fakeRegistry[name] = f
	db, err := sql.Open("statsstorefake", name)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return New(db), f
}

func fixed(r fakeResult) func(string) fakeResult { return func(string) fakeResult { return r } }

var t0 = time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)

// norm collapses whitespace so SQL assertions do not depend on layout.
func norm(q string) string { return strings.Join(strings.Fields(q), " ") }

func mustContainSQL(t *testing.T, q string, frags ...string) {
	t.Helper()
	n := norm(q)
	for _, f := range frags {
		if !strings.Contains(n, f) {
			t.Errorf("query missing %q: %s", f, n)
		}
	}
}

func TestLeaderboardRejectsUnknownWindowAndSort(t *testing.T) {
	s, f := newFake(t, fixed(fakeResult{}))
	ctx := context.Background()
	if _, err := s.Leaderboard(ctx, "1h", "earnings", 5); err == nil || !strings.Contains(err.Error(), "window") {
		t.Fatalf("window err=%v", err)
	}
	if _, err := s.Leaderboard(ctx, "24h", "bogus", 5); err == nil || !strings.Contains(err.Error(), "sort") {
		t.Fatalf("sort err=%v", err)
	}
	if _, err := s.LeaderboardProvider(ctx, "1h", "p"); err == nil {
		t.Fatal("expected unknown-window error")
	}
	if len(f.calls) != 0 {
		t.Fatalf("no query should run on invalid input, got %d", len(f.calls))
	}
}

var lbCols = []string{"provider_id", "pseudonym", "generated_at", "rank_earnings", "rank_tokens", "rank_jobs",
	"e", "ew", "er", "bucket", "tokens", "jobs", "first", "last", "mode", "blocked"}

func lbRow(id string) []driver.Value {
	return []driver.Value{id, "ps-" + id, t0, int64(1), int64(2), int64(3), "12.50", "10.00", "2.50", "10-100",
		int64(900), int64(7), t0, nil, "bucketed", true}
}

func TestLeaderboardMapsRowsAndPicksTableAndOrder(t *testing.T) {
	s, f := newFake(t, fixed(fakeResult{cols: lbCols, rows: [][]driver.Value{lbRow("p1")}}))
	got, err := s.Leaderboard(context.Background(), "7d", "tokens", 25)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 {
		t.Fatalf("rows=%d", len(got))
	}
	r := got[0]
	if r.ProviderID != "p1" || r.Pseudonym != "ps-p1" || r.RankEarnings != 1 || r.RankTokens != 2 || r.RankJobs != 3 ||
		r.EarningsTotalUSD != "12.50" || r.EarningsWorkUSD != "10.00" || r.EarningsRewardsUSD != "2.50" ||
		r.Bucket != "10-100" || r.Tokens != 900 || r.Jobs != 7 || !r.FirstSeenAt.Valid || r.LastSeenAt.Valid ||
		r.VisibilityMode != "bucketed" || !r.VisibilityBlocked {
		t.Fatalf("bad row %+v", r)
	}
	q := f.calls[0].query
	if !strings.Contains(q, "FROM stats_leaderboard_7d lb") || !strings.Contains(q, "ORDER BY lb.rank_tokens ASC") {
		t.Fatalf("query did not select 7d/rank_tokens: %s", q)
	}
	mustContainSQL(t, q, "LEFT JOIN provider_visibility pv ON pv.provider_id = lb.provider_id",
		"ORDER BY lb.rank_tokens ASC, lb.provider_id ASC")
	if f.calls[0].args[0] != int64(25) {
		t.Fatalf("limit arg=%v", f.calls[0].args[0])
	}
}

func TestLeaderboardTableAndOrderMapping(t *testing.T) {
	for w, want := range map[string]string{"24h": "stats_leaderboard_24h", "7d": "stats_leaderboard_7d", "30d": "stats_leaderboard_30d", "all": "stats_leaderboard_all"} {
		if got, ok := leaderboardTable(w); !ok || got != want {
			t.Errorf("table(%s)=%q,%v", w, got, ok)
		}
	}
	for s, want := range map[string]string{"earnings": "rank_earnings", "tokens": "rank_tokens", "jobs": "rank_jobs"} {
		if got, ok := leaderboardOrder(s); !ok || got != want {
			t.Errorf("order(%s)=%q,%v", s, got, ok)
		}
	}
}

func TestLeaderboardScanErrorPropagates(t *testing.T) {
	bad := lbRow("p1")
	bad[3] = "not-an-int"
	s, _ := newFake(t, fixed(fakeResult{cols: lbCols, rows: [][]driver.Value{bad}}))
	if _, err := s.Leaderboard(context.Background(), "all", "jobs", 1); err == nil {
		t.Fatal("expected scan error")
	}
}

func TestLeaderboardProviderFoundMissingAndError(t *testing.T) {
	ctx := context.Background()
	s, f := newFake(t, fixed(fakeResult{cols: lbCols, rows: [][]driver.Value{lbRow("p9")}}))
	r, err := s.LeaderboardProvider(ctx, "30d", "p9")
	if err != nil || r == nil || r.ProviderID != "p9" || r.Tokens != 900 {
		t.Fatalf("r=%+v err=%v", r, err)
	}
	if !strings.Contains(f.calls[0].query, "stats_leaderboard_30d") || f.calls[0].args[0] != "p9" {
		t.Fatalf("call=%+v", f.calls[0])
	}

	s, _ = newFake(t, fixed(fakeResult{cols: lbCols}))
	if r, err := s.LeaderboardProvider(ctx, "30d", "nope"); r != nil || err != nil {
		t.Fatalf("missing should be nil,nil got %v %v", r, err)
	}

	s, _ = newFake(t, fixed(fakeResult{err: errors.New("down")}))
	if r, err := s.LeaderboardProvider(ctx, "30d", "x"); r != nil || err == nil {
		t.Fatalf("want error, got %v %v", r, err)
	}
}

func TestRewardsPopulated(t *testing.T) {
	ctx := context.Background()
	s, f := newFake(t, fixed(fakeResult{cols: []string{"p"}, rows: [][]driver.Value{{true}}}))
	if p, err := s.RewardsPopulated(ctx, "7d"); err != nil || !p {
		t.Fatalf("p=%v err=%v", p, err)
	}
	if f.calls[0].args[0] != "7d" {
		t.Fatalf("window arg=%v", f.calls[0].args[0])
	}
	s, _ = newFake(t, fixed(fakeResult{cols: []string{"p"}}))
	if p, err := s.RewardsPopulated(ctx, "7d"); err != nil || p {
		t.Fatalf("empty ledger must be false,nil got %v %v", p, err)
	}
	s, _ = newFake(t, fixed(fakeResult{err: errors.New("x")}))
	if _, err := s.RewardsPopulated(ctx, "7d"); err == nil {
		t.Fatal("expected error")
	}
}

func TestComponentGeneratedAt(t *testing.T) {
	ctx := context.Background()
	s, _ := newFake(t, fixed(fakeResult{cols: []string{"g"}, rows: [][]driver.Value{{t0}}}))
	if g, err := s.ComponentGeneratedAt(ctx, "rollup"); err != nil || !g.Equal(t0) {
		t.Fatalf("g=%v err=%v", g, err)
	}
	s, _ = newFake(t, fixed(fakeResult{cols: []string{"g"}}))
	if g, err := s.ComponentGeneratedAt(ctx, "rollup"); err != nil || !g.IsZero() {
		t.Fatalf("missing must be zero,nil got %v %v", g, err)
	}
	s, _ = newFake(t, fixed(fakeResult{err: errors.New("x")}))
	if _, err := s.ComponentGeneratedAt(ctx, "rollup"); err == nil {
		t.Fatal("expected error")
	}
}

func TestComponentsHealthMapsNullableColumns(t *testing.T) {
	ctx := context.Background()
	t1 := t0.Add(time.Hour)
	s, _ := newFake(t, fixed(fakeResult{
		cols: []string{"c", "g", "ok", "ee", "em"},
		rows: [][]driver.Value{
			{"a", t0, t1, nil, nil},
			{"b", t0, t1, t0, "bad"},
		},
	}))
	got, err := s.ComponentsHealth(ctx)
	if err != nil || len(got) != 2 {
		t.Fatalf("got=%v err=%v", got, err)
	}
	if !got[0].GeneratedAt.Equal(t0) || !got[0].LastOkAt.Equal(t1) || !got[1].GeneratedAt.Equal(t0) || !got[1].LastOkAt.Equal(t1) {
		t.Fatalf("generated_at/last_ok_at mapping: %+v", got)
	}
	if got[0].LastErrorAt.Valid || got[0].LastErrorMessage.Valid {
		t.Fatalf("a should have null error: %+v", got[0])
	}
	if !got[1].LastErrorAt.Valid || got[1].LastErrorMessage.String != "bad" || got[1].Component != "b" {
		t.Fatalf("b: %+v", got[1])
	}
	s, _ = newFake(t, fixed(fakeResult{err: errors.New("x")}))
	if _, err := s.ComponentsHealth(ctx); err == nil {
		t.Fatal("expected error")
	}
}

func TestIntakeAndRoutability(t *testing.T) {
	ctx := context.Background()
	s, _ := newFake(t, fixed(fakeResult{cols: []string{"g", "u", "f"}, rows: [][]driver.Value{{t0, []byte(`{"u":1}`), []byte(`{"f":2}`)}}}))
	in, err := s.Intake(ctx)
	if err != nil || in == nil || string(in.UnmatchedModelsJSON) != `{"u":1}` || string(in.FleetRAMJSON) != `{"f":2}` || !in.GeneratedAt.Equal(t0) {
		t.Fatalf("in=%+v err=%v", in, err)
	}
	s, _ = newFake(t, fixed(fakeResult{cols: []string{"g", "u", "f"}}))
	if in, err := s.Intake(ctx); in != nil || err != nil {
		t.Fatalf("empty intake must be nil,nil got %v %v", in, err)
	}
	s, _ = newFake(t, fixed(fakeResult{err: errors.New("x")}))
	if _, err := s.Intake(ctx); err == nil {
		t.Fatal("expected intake error")
	}

	s, _ = newFake(t, fixed(fakeResult{cols: []string{"g", "s", "m", "p"}, rows: [][]driver.Value{{t0, []byte("S"), []byte("M"), []byte("P")}}}))
	rt, err := s.Routability(ctx)
	if err != nil || rt == nil || string(rt.SummaryJSON) != "S" || string(rt.ModelsJSON) != "M" || string(rt.ProvidersJSON) != "P" {
		t.Fatalf("rt=%+v err=%v", rt, err)
	}
	s, _ = newFake(t, fixed(fakeResult{cols: []string{"g", "s", "m", "p"}}))
	if rt, err := s.Routability(ctx); rt != nil || err != nil {
		t.Fatalf("empty routability must be nil,nil got %v %v", rt, err)
	}
	s, _ = newFake(t, fixed(fakeResult{err: errors.New("x")}))
	if _, err := s.Routability(ctx); err == nil {
		t.Fatal("expected routability error")
	}
}

func TestOverviewMapsColumnsAndNoRows(t *testing.T) {
	ctx := context.Background()
	s, _ := newFake(t, fixed(fakeResult{
		cols: make([]string, 15),
		rows: [][]driver.Value{{t0, int64(10), int64(20), int64(30), int64(4), int64(3), int64(500), float64(1.5),
			int64(66), int64(7), int64(8), int64(9), int64(2), int64(40), []byte(`{"x":1}`)}},
	}))
	o, err := s.Overview(ctx)
	if err != nil || o == nil {
		t.Fatalf("o=%v err=%v", o, err)
	}
	if o.TokensIn != 10 || o.TokensOut != 20 || o.Requests != 30 || o.NodesOnline != 4 || o.NodesHardwareAttested != 3 ||
		o.BandwidthGBPerSec != 500 || o.NetworkPowerKW != 1.5 || o.NetworkUtilizationPct != 66 || o.GPUCoresTotal != 7 ||
		o.CPUCoresTotal != 8 || o.UnifiedRAMGBTotal != 9 || o.ModelsServing != 2 ||
		o.IdlePrewarm.PoolPctWithB1Active != 40 || string(o.IdlePrewarm.SkipsByReasonLast1hJSON) != `{"x":1}` {
		t.Fatalf("bad overview %+v", o)
	}
	s, _ = newFake(t, fixed(fakeResult{cols: make([]string, 15)}))
	if o, err := s.Overview(ctx); o != nil || err != nil {
		t.Fatalf("empty overview must be nil,nil got %v %v", o, err)
	}
	s, _ = newFake(t, fixed(fakeResult{err: errors.New("x")}))
	if _, err := s.Overview(ctx); err == nil {
		t.Fatal("expected error")
	}
}

func TestProviderIdlePrewarmAggregatesAndUsesOneHourCutoff(t *testing.T) {
	ctx := context.Background()
	s, f := newFake(t, func(q string) fakeResult {
		if strings.Contains(q, "SELECT event") {
			return fakeResult{cols: []string{"e", "c"}, rows: [][]driver.Value{{"idle_prewarm_started", int64(3)}, {"idle_prewarm_skipped", int64(2)}}}
		}
		return fakeResult{cols: []string{"r", "c"}, rows: [][]driver.Value{{"busy", int64(2)}}}
	})
	before := time.Now().UTC().Add(-time.Hour)
	got, err := s.ProviderIdlePrewarm(ctx, "prov-1")
	if err != nil {
		t.Fatal(err)
	}
	if got.EventsLast1h["idle_prewarm_started"] != 3 || got.EventsLast1h["idle_prewarm_skipped"] != 2 || got.SkipsByReasonLast1h["busy"] != 2 {
		t.Fatalf("got %+v", got)
	}
	if len(f.calls) != 2 {
		t.Fatalf("calls=%d", len(f.calls))
	}
	mustContainSQL(t, f.calls[1].query, "event = 'idle_prewarm_skipped'", "GROUP BY reason")
	for _, c := range f.calls {
		if c.args[0] != "prov-1" {
			t.Fatalf("provider arg=%v", c.args[0])
		}
		cut := c.args[1].(time.Time)
		if cut.Before(before) || cut.After(time.Now().UTC().Add(-time.Hour)) {
			t.Fatalf("cutoff %v not ~1h ago", cut)
		}
	}
}

func TestProviderIdlePrewarmErrorsPerQuery(t *testing.T) {
	ctx := context.Background()
	s, _ := newFake(t, fixed(fakeResult{err: errors.New("x")}))
	if _, err := s.ProviderIdlePrewarm(ctx, "p"); err == nil || !strings.Contains(err.Error(), "events select") {
		t.Fatalf("err=%v", err)
	}
	s, _ = newFake(t, func(q string) fakeResult {
		if strings.Contains(q, "SELECT event") {
			return fakeResult{cols: []string{"e", "c"}}
		}
		return fakeResult{err: errors.New("y")}
	})
	got, err := s.ProviderIdlePrewarm(ctx, "p")
	if err == nil || !strings.Contains(err.Error(), "skips select") || got.EventsLast1h == nil {
		t.Fatalf("got=%+v err=%v", got, err)
	}
}

func TestTimeseriesQueries(t *testing.T) {
	ctx := context.Background()
	s, f := newFake(t, fixed(fakeResult{cols: []string{"b", "r"}, rows: [][]driver.Value{{t0, int64(5)}}}))
	rpm, err := s.RpmTimeseries(ctx)
	if err != nil || len(rpm) != 1 || rpm[0].Value != 5 || !rpm[0].Bucket.Equal(t0) {
		t.Fatalf("rpm=%+v err=%v", rpm, err)
	}
	mustContainSQL(t, f.calls[0].query, "ORDER BY bucket_start")
	s, f = newFake(t, fixed(fakeResult{cols: []string{"b", "i", "o"}, rows: [][]driver.Value{{t0, int64(6), int64(7)}}}))
	tpm, err := s.TpmTimeseries(ctx)
	if err != nil || len(tpm) != 1 || tpm[0].InTok != 6 || tpm[0].OutTok != 7 || tpm[0].Value != 0 {
		t.Fatalf("tpm=%+v err=%v", tpm, err)
	}
	mustContainSQL(t, f.calls[0].query, "ORDER BY bucket_start")
	s, f = newFake(t, fixed(fakeResult{cols: []string{"b", "r", "i", "o"}, rows: [][]driver.Value{{t0, int64(5), int64(6), int64(7)}}}))
	d, err := s.DailyTimeseries(ctx)
	if err != nil || len(d) != 1 || d[0].Value != 5 || d[0].InTok != 6 || d[0].OutTok != 7 {
		t.Fatalf("daily=%+v err=%v", d, err)
	}
	mustContainSQL(t, f.calls[0].query, "ORDER BY day_start")
	s, _ = newFake(t, fixed(fakeResult{err: errors.New("x")}))
	if _, err := s.RpmTimeseries(ctx); err == nil {
		t.Fatal("rpm err")
	}
	if _, err := s.TpmTimeseries(ctx); err == nil {
		t.Fatal("tpm err")
	}
	if _, err := s.DailyTimeseries(ctx); err == nil {
		t.Fatal("daily err")
	}
}
