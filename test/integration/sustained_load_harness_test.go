//go:build loadharness

// Sustained-load acceptance harness for #1793 (exit criterion of
// docs/design/money-datastore-1b-tokens-per-day.md §4). It runs the REAL
// coordinator and gateway binaries (built by TestMain), fake providers that
// sign SPEC-015 settlement receipts, and the coordinator in
// verified_model_settlement_mode=enforce, then drives an OPEN-LOOP constant
// arrival rate through the gateway: requests are fired on a fixed schedule
// whether or not earlier ones have finished, and latency is measured from
// the scheduled send time, so a stalled writer shows up as latency and
// failures instead of a silently lower request rate.
//
// Opt-in only: the file carries the `loadharness` build tag, so
// `make test-integration` and CI never compile it. See
// test/integration/LOAD_HARNESS.md for commands, the config overrides used
// and the PASS/FAIL criteria.
package integration

import (
	"bufio"
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

var (
	lhSmoke          = flag.Bool("lh.smoke", false, "short smoke preset: 2m at 5 req/s, 30s burst at 10 req/s (explicit lh.* flags still win)")
	lhRPS            = flag.Float64("lh.rps", 30, "steady arrival rate, requests/s (open loop)")
	lhDuration       = flag.Duration("lh.duration", 24*time.Hour, "total load duration, burst included")
	lhBurstRPS       = flag.Float64("lh.burst-rps", 60, "burst arrival rate, requests/s")
	lhBurstDuration  = flag.Duration("lh.burst-duration", time.Hour, "burst length (0 disables the burst)")
	lhBurstAt        = flag.Duration("lh.burst-at", -1, "burst start offset from load start (default: middle of the run)")
	lhInterval       = flag.Duration("lh.interval", time.Minute, "JSONL record interval")
	lhSample         = flag.Duration("lh.sample", 10*time.Second, "metrics scrape / gauge sample period")
	lhRetentionEvery = flag.Duration("lh.retention-every", 15*time.Minute, "how often the harness starts a settlement-evidence retention pass (0 disables)")
	lhSeedDB         = flag.String("lh.seed-db", "", "SQLite file copied in as the coordinator DB before boot (its -wal and .route-snapshots siblings are copied when present)")
	lhOut            = flag.String("lh.out", "", "output directory for metrics.jsonl, summary.json and child logs (default: a new dir under $TMPDIR)")
	lhProviders      = flag.Int("lh.providers", 8, "fake providers (2 slots each)")
	lhStreamRatio    = flag.Float64("lh.stream-ratio", 0.5, "fraction of requests sent with stream=true")
	lhMaxInflight    = flag.Int("lh.max-inflight", 1024, "in-flight cap; a send that would exceed it is counted as a failure (dropped_inflight_cap)")
	lhCoordLogLevel  = flag.String("lh.coord-log-level", "warn", "coordinator logging.level")
	lhDrain          = flag.Duration("lh.drain", 30*time.Second, "wait after the last send before the final evidence checks")
)

const (
	lhCommitP99LimitMS       = 50.0
	lhPassLimit              = 60 * time.Second
	lhMinSuccessRatio        = 0.999
	lhMinBurstRateRatio      = 0.95
	lhOutboxGrowthTolerance  = 50.0 // rows
	lhLagGrowthToleranceSecs = 30.0 // seconds
)

// lhHotPathComponents are the money_sqlite_* component labels written on the
// buyer request path. Everything else (ledger_recovery, wal_checkpoint,
// journal materialize, reload) is background work.
var lhHotPathComponents = map[string]bool{
	"billing_hot_path":          true,
	"request_log_identity":      true,
	"route_snapshot":            true,
	"route_snapshot_journal":    true,
	"settlement_attempt_output": true,
	"settlement_receipt":        true,
	"settlement_pool_labels":    true,
}

type lhConfig struct {
	RPS            float64       `json:"rps"`
	Duration       time.Duration `json:"-"`
	DurationS      float64       `json:"duration_s"`
	BurstRPS       float64       `json:"burst_rps"`
	BurstDuration  time.Duration `json:"-"`
	BurstDurationS float64       `json:"burst_duration_s"`
	BurstAt        time.Duration `json:"-"`
	BurstAtS       float64       `json:"burst_at_s"`
	Interval       time.Duration `json:"-"`
	Sample         time.Duration `json:"-"`
	RetentionEvery time.Duration `json:"-"`
	RetentionS     float64       `json:"retention_every_s"`
	SeedDB         string        `json:"seed_db,omitempty"`
	Providers      int           `json:"providers"`
	StreamRatio    float64       `json:"stream_ratio"`
	MaxInflight    int           `json:"max_inflight"`
	Smoke          bool          `json:"smoke"`
}

func lhResolveConfig() lhConfig {
	set := map[string]bool{}
	flag.Visit(func(f *flag.Flag) { set[f.Name] = true })
	pick := func(name string, def, smoke any) any {
		if *lhSmoke && !set[name] {
			return smoke
		}
		return def
	}
	c := lhConfig{
		RPS:            pick("lh.rps", *lhRPS, 5.0).(float64),
		Duration:       pick("lh.duration", *lhDuration, 2*time.Minute).(time.Duration),
		BurstRPS:       pick("lh.burst-rps", *lhBurstRPS, 10.0).(float64),
		BurstDuration:  pick("lh.burst-duration", *lhBurstDuration, 30*time.Second).(time.Duration),
		BurstAt:        pick("lh.burst-at", *lhBurstAt, 60*time.Second).(time.Duration),
		Interval:       pick("lh.interval", *lhInterval, 20*time.Second).(time.Duration),
		Sample:         pick("lh.sample", *lhSample, 5*time.Second).(time.Duration),
		RetentionEvery: pick("lh.retention-every", *lhRetentionEvery, 30*time.Second).(time.Duration),
		Providers:      pick("lh.providers", *lhProviders, 2).(int),
		SeedDB:         *lhSeedDB,
		StreamRatio:    *lhStreamRatio,
		MaxInflight:    *lhMaxInflight,
		Smoke:          *lhSmoke,
	}
	if c.BurstAt < 0 {
		c.BurstAt = (c.Duration - c.BurstDuration) / 2
	}
	c.DurationS, c.BurstDurationS, c.BurstAtS, c.RetentionS = c.Duration.Seconds(), c.BurstDuration.Seconds(), c.BurstAt.Seconds(), c.RetentionEvery.Seconds()
	return c
}

func (c lhConfig) phaseAt(elapsed time.Duration) (string, float64) {
	if c.BurstDuration > 0 && elapsed >= c.BurstAt && elapsed < c.BurstAt+c.BurstDuration {
		return "burst", c.BurstRPS
	}
	return "steady", c.RPS
}

// lhPass is one observed background pass (weekly settlement window or
// settlement-evidence retention run).
type lhPass struct {
	Kind      string  `json:"kind"`
	Window    string  `json:"window,omitempty"`
	StartedAt string  `json:"started_at_utc"`
	DurationS float64 `json:"duration_s"`
	// UpperBound marks a settlement window that was already committed when
	// the poller first looked (boot catch-up): its duration is first-seen
	// minus start, so it over-states the pass.
	UpperBound bool   `json:"upper_bound,omitempty"`
	Status     string `json:"status,omitempty"`
	Deleted    int    `json:"deleted_requests,omitempty"`
	Scanned    int64  `json:"scanned_credits,omitempty"`
	Error      string `json:"error,omitempty"`
}

type lhRecord struct {
	TS                     string             `json:"ts_utc"`
	ElapsedS               float64            `json:"elapsed_s"`
	Phase                  string             `json:"phase"`
	TargetRPS              float64            `json:"target_rps"`
	Sent                   int64              `json:"sent"`
	Succeeded              int64              `json:"succeeded"`
	Failed                 map[string]int64   `json:"failed,omitempty"`
	BuyerP50MS             float64            `json:"buyer_p50_ms"`
	BuyerP99MS             float64            `json:"buyer_p99_ms"`
	HotPathWriteFailures   int64              `json:"hot_path_write_failures"`
	CommitCount            int64              `json:"commit_count"`
	CommitP99MS            float64            `json:"commit_p99_ms"`
	CommitP99MSByComponent map[string]float64 `json:"commit_p99_ms_by_component,omitempty"`
	OutboxPending          float64            `json:"outbox_pending"`
	OutboxOldestAgeS       float64            `json:"outbox_oldest_age_s"`
	MaterializerPending    float64            `json:"materializer_pending"`
	MaterializerLagS       float64            `json:"materializer_lag_s"`
	WALCheckpoints         int64              `json:"wal_checkpoints"`
	WALCheckpointP99MS     float64            `json:"wal_checkpoint_p99_ms"`
	LedgerRecoveryTxns     int64              `json:"ledger_recovery_txns"`
	LedgerRecoveryP99MS    float64            `json:"ledger_recovery_p99_ms"`
	SettlementPasses       []lhPass           `json:"settlement_passes,omitempty"`
	RetentionPasses        []lhPass           `json:"retention_passes,omitempty"`
	DBBytes                map[string]int64   `json:"db_bytes"`
	ScrapeError            string             `json:"scrape_error,omitempty"`
}

type lhCriterion struct {
	Name   string `json:"name"`
	Status string `json:"status"`
	Detail string `json:"detail"`
}

type lhPhaseSummary struct {
	Sent         int64            `json:"sent"`
	Succeeded    int64            `json:"succeeded"`
	Failed       map[string]int64 `json:"failed,omitempty"`
	SuccessRatio float64          `json:"success_ratio"`
	TargetRPS    float64          `json:"target_rps"`
	AchievedRPS  float64          `json:"achieved_rps"`
	P50MS        float64          `json:"p50_ms"`
	P99MS        float64          `json:"p99_ms"`
	DurationS    float64          `json:"duration_s"`
}

type lhSummary struct {
	Verdict              string                    `json:"verdict"`
	Config               lhConfig                  `json:"config"`
	StartedAt            string                    `json:"started_at_utc"`
	FinishedAt           string                    `json:"finished_at_utc"`
	OutputDir            string                    `json:"output_dir"`
	Phases               map[string]lhPhaseSummary `json:"phases"`
	HotPathWriteFailures int64                     `json:"hot_path_write_failures"`
	CommitCount          int64                     `json:"commit_count"`
	CommitP99MS          float64                   `json:"commit_p99_ms"`
	SettlementPasses     []lhPass                  `json:"settlement_passes"`
	RetentionPasses      []lhPass                  `json:"retention_passes"`
	Evidence             map[string]any            `json:"evidence"`
	FinalDBBytes         map[string]int64          `json:"final_db_bytes"`
	Criteria             []lhCriterion             `json:"criteria"`
	ConfigOverrides      []string                  `json:"config_overrides"`
}

// lhOverrides documents every coordinator/gateway config change the harness
// makes on top of the integration fixture (summary.json carries it too).
var lhOverrides = []string{
	"coordinator settlement.verified_model_settlement_mode=enforce (fixture settlementEnforceMode)",
	"coordinator settlement.job_enabled=true (weekly settlement catch-up at boot + Monday 00:00 UTC timer, nightly reconcile at 00:00 UTC)",
	"coordinator settlement.min_payout_credits=0 (fixture; every provider gets a payout row)",
	"coordinator billing.retention.enabled=true with production defaults; harness POSTs /admin/ledger/settlement-evidence-retention/run every lh.retention-every (the in-process timer only fires at 03:00 UTC)",
	"coordinator logging.level=lh.coord-log-level (default warn) and child logs to files under the output dir",
	"gateway quotas.account_concurrency=lh.max-inflight, quotas.account_daily_tokens=1e12 (one buyer key carries the whole load)",
	"gateway settlement.reconcile_interval_s=5 (SPEC-022 gateway reconciler)",
	"outbox drain, journal materializer and WAL checkpointer run on their compiled-in cadences (seconds to 30 s); no override exists or is needed",
}

type lhLoad struct {
	mu        sync.Mutex
	cur       lhBucket
	phases    map[string]*lhPhaseAcc
	inflight  atomic.Int64
	scheduled atomic.Int64
}

type lhBucket struct {
	sent, ok int64
	failed   map[string]int64
	lat      []float64
}

type lhPhaseAcc struct {
	sent, ok int64
	failed   map[string]int64
	lat      []float32
	target   float64
}

func (l *lhLoad) sent(phase string, target float64) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.cur.sent++
	p := l.phase(phase)
	p.sent++
	p.target = target
}

func (l *lhLoad) phase(name string) *lhPhaseAcc {
	p := l.phases[name]
	if p == nil {
		p = &lhPhaseAcc{failed: map[string]int64{}}
		l.phases[name] = p
	}
	return p
}

func (l *lhLoad) done(phase string, latency time.Duration, failure string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	p := l.phase(phase)
	if failure != "" {
		if l.cur.failed == nil {
			l.cur.failed = map[string]int64{}
		}
		l.cur.failed[failure]++
		p.failed[failure]++
		return
	}
	ms := float64(latency) / float64(time.Millisecond)
	l.cur.ok++
	l.cur.lat = append(l.cur.lat, ms)
	p.ok++
	p.lat = append(p.lat, float32(ms))
}

func (l *lhLoad) takeBucket() lhBucket {
	l.mu.Lock()
	defer l.mu.Unlock()
	b := l.cur
	l.cur = lhBucket{}
	return b
}

func lhPercentile(sorted []float64, q float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	idx := int(math.Ceil(q*float64(len(sorted)))) - 1
	if idx < 0 {
		idx = 0
	}
	return sorted[idx]
}

func lhUUID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// ---- Prometheus text scrape -------------------------------------------------

type lhSampleRow struct {
	name   string
	labels map[string]string
	value  float64
}

type lhScrape []lhSampleRow

func lhScrapeMetrics(client *http.Client, url, operatorKey string) (lhScrape, error) {
	req, _ := http.NewRequest(http.MethodGet, url, nil)
	req.Header.Set("Authorization", "Bearer "+operatorKey)
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, fmt.Errorf("metrics status %d: %s", resp.StatusCode, b)
	}
	var out lhScrape
	sc := bufio.NewScanner(resp.Body)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		row := lhSampleRow{labels: map[string]string{}}
		rest := line
		if i := strings.IndexAny(line, "{ "); i >= 0 && line[i] == '{' {
			row.name = line[:i]
			j := strings.LastIndex(line, "}")
			if j < i {
				continue
			}
			for _, kv := range lhSplitLabels(line[i+1 : j]) {
				k, v, ok := strings.Cut(kv, "=")
				if ok {
					row.labels[k] = strings.Trim(v, `"`)
				}
			}
			rest = strings.TrimSpace(line[j+1:])
		} else if i >= 0 {
			row.name = line[:i]
			rest = strings.TrimSpace(line[i+1:])
		} else {
			continue
		}
		fields := strings.Fields(rest)
		if len(fields) == 0 {
			continue
		}
		v, err := strconv.ParseFloat(fields[0], 64)
		if err != nil {
			continue
		}
		row.value = v
		out = append(out, row)
	}
	return out, sc.Err()
}

func lhSplitLabels(s string) []string {
	var parts []string
	inQuote, start := false, 0
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '\\':
			i++
		case '"':
			inQuote = !inQuote
		case ',':
			if !inQuote {
				parts = append(parts, s[start:i])
				start = i + 1
			}
		}
	}
	if start < len(s) {
		parts = append(parts, s[start:])
	}
	return parts
}

func (s lhScrape) gauge(name string) float64 {
	for _, r := range s {
		if r.name == name {
			return r.value
		}
	}
	return 0
}

func (s lhScrape) sum(name string, match func(map[string]string) bool) float64 {
	var total float64
	for _, r := range s {
		if r.name == name && (match == nil || match(r.labels)) {
			total += r.value
		}
	}
	return total
}

// buckets sums cumulative histogram buckets across matching label sets.
func (s lhScrape) buckets(name string, match func(map[string]string) bool) map[float64]float64 {
	out := map[float64]float64{}
	for _, r := range s {
		if r.name != name+"_bucket" || (match != nil && !match(r.labels)) {
			continue
		}
		le, err := strconv.ParseFloat(r.labels["le"], 64)
		if r.labels["le"] == "+Inf" {
			le, err = math.Inf(1), nil
		}
		if err != nil {
			continue
		}
		out[le] += r.value
	}
	return out
}

func lhBucketDelta(cur, prev map[float64]float64) map[float64]float64 {
	out := make(map[float64]float64, len(cur))
	for le, v := range cur {
		out[le] = v - prev[le]
	}
	return out
}

// lhHistQuantile mirrors PromQL histogram_quantile: linear interpolation
// inside the bucket that crosses rank q*count. Returns seconds.
func lhHistQuantile(q float64, buckets map[float64]float64) float64 {
	les := make([]float64, 0, len(buckets))
	for le := range buckets {
		les = append(les, le)
	}
	sort.Float64s(les)
	if len(les) == 0 {
		return 0
	}
	total := buckets[les[len(les)-1]]
	if total <= 0 {
		return 0
	}
	rank := q * total
	prevLE, prevCount := 0.0, 0.0
	for _, le := range les {
		c := buckets[le]
		if c >= rank {
			if math.IsInf(le, 1) {
				return prevLE
			}
			if c == prevCount {
				return le
			}
			return prevLE + (le-prevLE)*(rank-prevCount)/(c-prevCount)
		}
		prevLE, prevCount = le, c
	}
	return prevLE
}

func lhIsHotPath(l map[string]string) bool { return lhHotPathComponents[l["component"]] }

// ---- the test ---------------------------------------------------------------

func TestSustainedLoadAcceptance1793(t *testing.T) {
	cfg := lhResolveConfig()
	if dl, ok := t.Deadline(); ok && time.Until(dl) < cfg.Duration+10*time.Minute {
		t.Fatalf("go test -timeout leaves %s but the run needs %s plus setup; pass -timeout 0 (or larger)", time.Until(dl).Round(time.Second), cfg.Duration)
	}
	outDir := *lhOut
	if outDir == "" {
		outDir = filepath.Join(os.TempDir(), "macprovider-loadharness-"+time.Now().UTC().Format("20060102T150405Z"))
	}
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		t.Fatalf("output dir: %v", err)
	}
	childLogDir = outDir
	defer func() { childLogDir = "" }()
	t.Logf("load harness output: %s", outDir)

	s := newScenario(t, scenarioOpts{
		seedAccount:                        true,
		settlementReceiptProvider:          true,
		settlementEnforceMode:              true,
		settlementReconcileIntervalSeconds: 5,
		providerCount:                      cfg.Providers,
		coordinatorConfig: func(s *scenario, m map[string]any) {
			if cfg.SeedDB != "" {
				lhCopySeedDB(s.t, cfg.SeedDB, s.coordinatorDB)
			}
			m["logging"] = map[string]any{"level": *lhCoordLogLevel, "format": "json"}
			m["settlement"].(map[string]any)["job_enabled"] = true
			m["billing"] = map[string]any{"retention": map[string]any{"enabled": true}}
		},
		gatewayConfig: func(_ *scenario, m map[string]any) {
			q := m["quotas"].(map[string]any)
			q["account_concurrency"] = cfg.MaxInflight
			q["account_daily_tokens"] = int64(1e12)
		},
	})

	coordDB, err := sql.Open("sqlite", "file:"+s.coordinatorDB+"?_pragma=busy_timeout(10000)")
	if err != nil {
		t.Fatalf("open coordinator db: %v", err)
	}
	defer coordDB.Close()
	coordDB.SetMaxOpenConns(2)
	var startVerdictID, startCreditID int64
	_ = coordDB.QueryRow(`SELECT COALESCE(MAX(id),0) FROM settlement_receipt_verdicts`).Scan(&startVerdictID)
	_ = coordDB.QueryRow(`SELECT COALESCE(MAX(id),0) FROM ledger_request_credits`).Scan(&startCreditID)

	jsonl, err := os.Create(filepath.Join(outDir, "metrics.jsonl"))
	if err != nil {
		t.Fatalf("create metrics.jsonl: %v", err)
	}
	defer jsonl.Close()
	enc := json.NewEncoder(jsonl)

	adminClient := &http.Client{Timeout: 30 * time.Second}
	metricsURL := s.coordProvURL + "/admin/metrics"
	if _, err := lhScrapeMetrics(adminClient, metricsURL, s.operatorKey); err != nil {
		t.Fatalf("coordinator /admin/metrics unavailable: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var bgWG sync.WaitGroup
	var passMu sync.Mutex
	var pendingSettle, pendingRetention, allSettle, allRetention []lhPass

	// Weekly-settlement window poller. RunSettlement stamps the window's
	// completed_at_utc with the time it acquired BEGIN IMMEDIATE and commits
	// the marker last, so (first time the committed row is visible) minus
	// completed_at_utc is the pass duration to within one poll period.
	bgWG.Add(1)
	go func() {
		defer bgWG.Done()
		seen := map[string]bool{}
		first := true
		tick := time.NewTicker(time.Second)
		defer tick.Stop()
		for {
			rows, err := coordDB.QueryContext(ctx, `SELECT window_start_utc, window_end_utc, completed_at_utc FROM ledger_settlement_windows`)
			if err == nil {
				now := time.Now().UTC()
				for rows.Next() {
					var ws, we, done string
					if rows.Scan(&ws, &we, &done) != nil {
						continue
					}
					key := ws + "|" + we + "|" + done
					if seen[key] {
						continue
					}
					seen[key] = true
					started, perr := time.Parse(time.RFC3339Nano, done)
					if perr != nil || (first && cfg.SeedDB != "" && now.Sub(started) > 10*time.Minute) {
						continue // historical marker carried in by the seed DB
					}
					p := lhPass{Kind: "weekly_settlement", Window: ws + "/" + we, StartedAt: done, DurationS: now.Sub(started).Seconds(), UpperBound: first}
					passMu.Lock()
					pendingSettle = append(pendingSettle, p)
					allSettle = append(allSettle, p)
					passMu.Unlock()
				}
				rows.Close()
				first = false
			}
			select {
			case <-ctx.Done():
				return
			case <-tick.C:
			}
		}
	}()

	// Retention driver: start a pass every RetentionEvery and record every
	// new report (harness-started or the 03:00 UTC timer).
	if cfg.RetentionEvery > 0 {
		bgWG.Add(1)
		go func() {
			defer bgWG.Done()
			lastStarted := ""
			poll := func() {
				var report struct {
					Status          string `json:"status"`
					StartedAtUTC    string `json:"started_at_utc"`
					FinishedAtUTC   string `json:"finished_at_utc"`
					DeletedRequests int    `json:"deleted_requests"`
					ScannedCredits  int64  `json:"scanned_credits"`
					Error           string `json:"error"`
				}
				status, body := lhAdmin(adminClient, http.MethodGet, s.coordProvURL+"/admin/ledger/settlement-evidence-retention?report=last", s.operatorKey)
				if status != http.StatusOK || json.Unmarshal(body, &report) != nil || report.FinishedAtUTC == "" || report.StartedAtUTC == lastStarted {
					return
				}
				lastStarted = report.StartedAtUTC
				st, _ := time.Parse(time.RFC3339Nano, report.StartedAtUTC)
				fin, _ := time.Parse(time.RFC3339Nano, report.FinishedAtUTC)
				p := lhPass{Kind: "evidence_retention", StartedAt: report.StartedAtUTC, DurationS: fin.Sub(st).Seconds(), Status: report.Status, Deleted: report.DeletedRequests, Scanned: report.ScannedCredits, Error: report.Error}
				passMu.Lock()
				pendingRetention = append(pendingRetention, p)
				allRetention = append(allRetention, p)
				passMu.Unlock()
			}
			startRun := func() {
				status, body := lhAdmin(adminClient, http.MethodPost, s.coordProvURL+"/admin/ledger/settlement-evidence-retention/run", s.operatorKey)
				if status != http.StatusAccepted && status != http.StatusConflict {
					passMu.Lock()
					p := lhPass{Kind: "evidence_retention", StartedAt: time.Now().UTC().Format(time.RFC3339Nano), Status: "start_failed", Error: fmt.Sprintf("status %d: %.200s", status, body)}
					pendingRetention = append(pendingRetention, p)
					allRetention = append(allRetention, p)
					passMu.Unlock()
				}
			}
			startRun()
			runTick := time.NewTicker(cfg.RetentionEvery)
			pollTick := time.NewTicker(2 * time.Second)
			defer runTick.Stop()
			defer pollTick.Stop()
			for {
				select {
				case <-ctx.Done():
					poll()
					return
				case <-runTick.C:
					startRun()
				case <-pollTick.C:
					poll()
				}
			}
		}()
	}

	load := &lhLoad{phases: map[string]*lhPhaseAcc{}}
	type gaugeSample struct {
		at                   time.Duration
		phase                string
		outbox, materializer float64
	}
	var gauges []gaugeSample
	var firstScrape, lastScrape lhScrape
	loadStart := time.Now()
	var loadElapsed atomic.Int64

	// Sampler/recorder.
	recorderDone := make(chan struct{})
	go func() {
		defer close(recorderDone)
		prevRecord, _ := lhScrapeMetrics(adminClient, metricsURL, s.operatorKey)
		firstScrape = prevRecord
		lastRecordAt := time.Now()
		tick := time.NewTicker(cfg.Sample)
		defer tick.Stop()
		emit := func(final bool) {
			cur, scrapeErr := lhScrapeMetrics(adminClient, metricsURL, s.operatorKey)
			el := time.Duration(loadElapsed.Load())
			phase, target := cfg.phaseAt(el)
			if scrapeErr == nil {
				lastScrape = cur
				gauges = append(gauges, gaugeSample{
					at: el, phase: phase,
					outbox:       cur.gauge("settlement_receipt_audit_outbox_pending_rows"),
					materializer: cur.gauge("settlement_attempt_output_journal_oldest_pending_age_seconds"),
				})
			}
			if !final && time.Since(lastRecordAt) < cfg.Interval {
				return
			}
			lastRecordAt = time.Now()
			b := load.takeBucket()
			sort.Float64s(b.lat)
			rec := lhRecord{
				TS: time.Now().UTC().Format(time.RFC3339), ElapsedS: el.Seconds(), Phase: phase, TargetRPS: target,
				Sent: b.sent, Succeeded: b.ok, Failed: b.failed,
				BuyerP50MS: lhPercentile(b.lat, 0.50), BuyerP99MS: lhPercentile(b.lat, 0.99),
				DBBytes: lhDBSizes(s),
			}
			if scrapeErr != nil {
				rec.ScrapeError = scrapeErr.Error()
			} else {
				isErr := func(l map[string]string) bool { return lhIsHotPath(l) && l["outcome"] == "error" }
				rec.HotPathWriteFailures = int64(cur.sum("money_sqlite_transaction_duration_seconds_count", isErr) + cur.sum("money_sqlite_write_duration_seconds_count", isErr) -
					prevRecord.sum("money_sqlite_transaction_duration_seconds_count", isErr) - prevRecord.sum("money_sqlite_write_duration_seconds_count", isErr))
				hot := lhBucketDelta(cur.buckets("money_sqlite_transaction_duration_seconds", lhIsHotPath), prevRecord.buckets("money_sqlite_transaction_duration_seconds", lhIsHotPath))
				rec.CommitP99MS = lhHistQuantile(0.99, hot) * 1000
				rec.CommitCount = int64(hot[math.Inf(1)])
				rec.CommitP99MSByComponent = map[string]float64{}
				for comp := range lhHotPathComponents {
					m := func(l map[string]string) bool { return l["component"] == comp }
					d := lhBucketDelta(cur.buckets("money_sqlite_transaction_duration_seconds", m), prevRecord.buckets("money_sqlite_transaction_duration_seconds", m))
					if d[math.Inf(1)] > 0 {
						rec.CommitP99MSByComponent[comp] = lhHistQuantile(0.99, d) * 1000
					}
				}
				rec.OutboxPending = cur.gauge("settlement_receipt_audit_outbox_pending_rows")
				rec.OutboxOldestAgeS = cur.gauge("settlement_receipt_audit_outbox_oldest_pending_age_seconds")
				rec.MaterializerPending = cur.gauge("settlement_attempt_output_journal_pending_rows")
				rec.MaterializerLagS = cur.gauge("settlement_attempt_output_journal_oldest_pending_age_seconds")
				wal := lhBucketDelta(cur.buckets("money_sqlite_wal_checkpoint_duration_seconds", nil), prevRecord.buckets("money_sqlite_wal_checkpoint_duration_seconds", nil))
				rec.WALCheckpoints, rec.WALCheckpointP99MS = int64(wal[math.Inf(1)]), lhHistQuantile(0.99, wal)*1000
				isRecovery := func(l map[string]string) bool { return l["component"] == "ledger_recovery" }
				rcv := lhBucketDelta(cur.buckets("money_sqlite_transaction_duration_seconds", isRecovery), prevRecord.buckets("money_sqlite_transaction_duration_seconds", isRecovery))
				rec.LedgerRecoveryTxns, rec.LedgerRecoveryP99MS = int64(rcv[math.Inf(1)]), lhHistQuantile(0.99, rcv)*1000
				prevRecord = cur
			}
			passMu.Lock()
			rec.SettlementPasses, rec.RetentionPasses = pendingSettle, pendingRetention
			pendingSettle, pendingRetention = nil, nil
			passMu.Unlock()
			if err := enc.Encode(rec); err != nil {
				t.Errorf("write metrics.jsonl: %v", err)
			}
		}
		for {
			select {
			case <-ctx.Done():
				emit(true)
				return
			case <-tick.C:
				emit(false)
			}
		}
	}()

	// Open-loop generator.
	buyer := &http.Client{
		Timeout: 120 * time.Second,
		Transport: &http.Transport{
			MaxIdleConns:        cfg.MaxInflight,
			MaxIdleConnsPerHost: cfg.MaxInflight,
			IdleConnTimeout:     90 * time.Second,
		},
	}
	var reqWG sync.WaitGroup
	var seq int64
	next := loadStart
	for {
		now := time.Now()
		if now.Sub(loadStart) >= cfg.Duration {
			break
		}
		loadElapsed.Store(int64(now.Sub(loadStart)))
		if wait := next.Sub(now); wait > 0 {
			time.Sleep(min(wait, 100*time.Millisecond))
			continue
		}
		scheduledAt := next
		phase, rate := cfg.phaseAt(scheduledAt.Sub(loadStart))
		next = next.Add(time.Duration(float64(time.Second) / rate))
		seq++
		load.sent(phase, rate)
		if load.inflight.Load() >= int64(cfg.MaxInflight) {
			load.done(phase, 0, "dropped_inflight_cap")
			continue
		}
		stream := float64(seq%1000) < cfg.StreamRatio*1000
		load.inflight.Add(1)
		reqWG.Add(1)
		go func(seq int64, phase string, scheduledAt time.Time, stream bool) {
			defer reqWG.Done()
			defer load.inflight.Add(-1)
			load.done(phase, time.Since(scheduledAt), lhSend(buyer, s, seq, stream))
		}(seq, phase, scheduledAt, stream)
	}
	loadEnd := time.Now()
	loadElapsed.Store(int64(loadEnd.Sub(loadStart)))
	reqWG.Wait()
	t.Logf("load finished: %d scheduled sends in %s; draining %s", seq, loadEnd.Sub(loadStart).Round(time.Second), *lhDrain)
	time.Sleep(*lhDrain)
	cancel()
	<-recorderDone
	bgWG.Wait()

	// ---- summary --------------------------------------------------------
	sum := lhSummary{
		Config:           cfg,
		StartedAt:        loadStart.UTC().Format(time.RFC3339),
		FinishedAt:       time.Now().UTC().Format(time.RFC3339),
		OutputDir:        outDir,
		Phases:           map[string]lhPhaseSummary{},
		SettlementPasses: allSettle,
		RetentionPasses:  allRetention,
		FinalDBBytes:     lhDBSizes(s),
		ConfigOverrides:  lhOverrides,
	}
	// The steady phase runs on both sides of the burst, so phase time comes
	// from the schedule rather than first/last send.
	runDur := loadEnd.Sub(loadStart)
	burstDur := max(min(cfg.BurstAt+cfg.BurstDuration, runDur)-cfg.BurstAt, 0)
	if cfg.BurstDuration <= 0 {
		burstDur = 0
	}
	phaseDur := map[string]time.Duration{"burst": burstDur, "steady": runDur - burstDur}
	for name, p := range load.phases {
		lat := make([]float64, len(p.lat))
		for i, v := range p.lat {
			lat[i] = float64(v)
		}
		sort.Float64s(lat)
		dur := phaseDur[name].Seconds()
		ps := lhPhaseSummary{Sent: p.sent, Succeeded: p.ok, Failed: p.failed, TargetRPS: p.target, DurationS: dur, P50MS: lhPercentile(lat, 0.5), P99MS: lhPercentile(lat, 0.99)}
		if p.sent > 0 {
			ps.SuccessRatio = float64(p.ok) / float64(p.sent)
		}
		if dur > 0 {
			ps.AchievedRPS = float64(p.sent) / dur
		}
		sum.Phases[name] = ps
	}
	if firstScrape != nil && lastScrape != nil {
		isErr := func(l map[string]string) bool { return lhIsHotPath(l) && l["outcome"] == "error" }
		sum.HotPathWriteFailures = int64(lastScrape.sum("money_sqlite_transaction_duration_seconds_count", isErr) + lastScrape.sum("money_sqlite_write_duration_seconds_count", isErr) -
			firstScrape.sum("money_sqlite_transaction_duration_seconds_count", isErr) - firstScrape.sum("money_sqlite_write_duration_seconds_count", isErr))
		hot := lhBucketDelta(lastScrape.buckets("money_sqlite_transaction_duration_seconds", lhIsHotPath), firstScrape.buckets("money_sqlite_transaction_duration_seconds", lhIsHotPath))
		sum.CommitCount = int64(hot[math.Inf(1)])
		sum.CommitP99MS = lhHistQuantile(0.99, hot) * 1000
	}
	var okTotal int64
	for _, p := range sum.Phases {
		okTotal += p.Succeeded
	}
	sum.Evidence = lhEvidence(t, coordDB, s, startVerdictID, startCreditID, okTotal)

	crit := func(name string, pass bool, detail string, args ...any) {
		st := "FAIL"
		if pass {
			st = "PASS"
		}
		sum.Criteria = append(sum.Criteria, lhCriterion{Name: name, Status: st, Detail: fmt.Sprintf(detail, args...)})
	}
	scrapeOK := firstScrape != nil && lastScrape != nil
	crit("hot_path_write_failures_zero", scrapeOK && sum.HotPathWriteFailures == 0, "%d hot-path SQLite transaction/write errors (metrics scraped=%v)", sum.HotPathWriteFailures, scrapeOK)
	crit("commit_p99_below_50ms", sum.CommitCount > 0 && sum.CommitP99MS < lhCommitP99LimitMS, "run-wide p99 BEGIN IMMEDIATE->COMMIT over hot-path components = %.2f ms across %d transactions", sum.CommitP99MS, sum.CommitCount)
	outboxPts, lagPts := []float64{}, []float64{}
	warm := cfg.Duration / 10
	for _, g := range gauges {
		if g.phase == "steady" && g.at >= warm {
			outboxPts = append(outboxPts, g.outbox)
			lagPts = append(lagPts, g.materializer)
		}
	}
	ok, d := lhFlat(outboxPts, lhOutboxGrowthTolerance)
	crit("outbox_backlog_flat", ok, "settlement_receipt_audit_outbox_pending_rows: %s", d)
	ok, d = lhFlat(lagPts, lhLagGrowthToleranceSecs)
	crit("materializer_lag_flat", ok, "settlement_attempt_output_journal_oldest_pending_age_seconds: %s", d)
	crit("weekly_settlement_pass_below_60s", lhPassesOK(allSettle), "%s", lhPassDetail(allSettle))
	crit("retention_pass_below_60s", lhPassesOK(allRetention), "%s", lhPassDetail(allRetention))
	if cfg.BurstDuration > 0 {
		b := sum.Phases["burst"]
		crit("burst_holds", b.Sent > 0 && b.SuccessRatio >= lhMinSuccessRatio && b.AchievedRPS >= lhMinBurstRateRatio*b.TargetRPS,
			"burst sent=%d succeeded=%d ratio=%.5f achieved=%.2f/%.2f req/s p99=%.1f ms", b.Sent, b.Succeeded, b.SuccessRatio, b.AchievedRPS, b.TargetRPS, b.P99MS)
	}
	st := sum.Phases["steady"]
	crit("steady_success_ratio", st.Sent > 0 && st.SuccessRatio >= lhMinSuccessRatio, "steady sent=%d succeeded=%d ratio=%.5f achieved=%.2f/%.2f req/s p99=%.1f ms", st.Sent, st.Succeeded, st.SuccessRatio, st.AchievedRPS, st.TargetRPS, st.P99MS)
	lost, _ := sum.Evidence["evidence_loss"].(int64)
	crit("evidence_loss_zero", lost == 0, "succeeded buyer requests without a closed verified verdict + non-verified verdicts = %d (verdicts %v)", lost, sum.Evidence["verdicts_by_outcome"])

	sum.Verdict = "PASS"
	for _, c := range sum.Criteria {
		if c.Status != "PASS" {
			sum.Verdict = "FAIL"
		}
	}
	b, _ := json.MarshalIndent(sum, "", "  ")
	if err := os.WriteFile(filepath.Join(outDir, "summary.json"), b, 0o644); err != nil {
		t.Errorf("write summary.json: %v", err)
	}
	for _, c := range sum.Criteria {
		t.Logf("%-34s %s  %s", c.Name, c.Status, c.Detail)
	}
	t.Logf("VERDICT %s  (metrics: %s, summary: %s)", sum.Verdict, filepath.Join(outDir, "metrics.jsonl"), filepath.Join(outDir, "summary.json"))
	if sum.Verdict != "PASS" {
		t.Errorf("sustained-load acceptance FAILED; see %s", filepath.Join(outDir, "summary.json"))
	}
}

func lhSend(client *http.Client, s *scenario, seq int64, stream bool) string {
	body := fmt.Sprintf(`{"model":%q,"max_tokens":32,"stream":%t,"messages":[{"role":"user","content":"load %d"}]}`, settlementFixtureModelID, stream, seq)
	req, _ := http.NewRequest(http.MethodPost, s.gatewayBaseURL+"/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+s.apiKey)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Request-ID", lhUUID())
	resp, err := client.Do(req)
	if err != nil {
		if strings.Contains(err.Error(), "Timeout") || strings.Contains(err.Error(), "deadline") {
			return "transport_timeout"
		}
		return "transport_error"
	}
	out, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		return "body_read_error"
	}
	if resp.StatusCode != http.StatusOK {
		return "http_" + strconv.Itoa(resp.StatusCode)
	}
	if stream && !strings.Contains(string(out), "[DONE]") {
		return "stream_incomplete"
	}
	if !stream && !strings.Contains(string(out), `"choices"`) {
		return "body_incomplete"
	}
	return ""
}

func lhAdmin(client *http.Client, method, url, operatorKey string) (int, []byte) {
	req, _ := http.NewRequest(method, url, nil)
	req.Header.Set("Authorization", "Bearer "+operatorKey)
	resp, err := client.Do(req)
	if err != nil {
		return 0, []byte(err.Error())
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return resp.StatusCode, b
}

// lhFlat reports whether a gauge series is free of monotonic growth: the
// steady-phase samples (after a 10% warm-up) are split into quarters and the
// series fails only when the quarter medians never decrease AND the last
// quarter sits more than tol above the first.
func lhFlat(pts []float64, tol float64) (bool, string) {
	if len(pts) < 4 {
		return false, fmt.Sprintf("not observed: %d steady samples after warm-up (need >= 4)", len(pts))
	}
	q := len(pts) / 4
	med := make([]float64, 4)
	for i := 0; i < 4; i++ {
		end := (i + 1) * q
		if i == 3 {
			end = len(pts)
		}
		part := append([]float64(nil), pts[i*q:end]...)
		sort.Float64s(part)
		med[i] = part[len(part)/2]
	}
	monotonic := med[0] <= med[1] && med[1] <= med[2] && med[2] <= med[3]
	growth := med[3] - med[0]
	maxV := 0.0
	for _, v := range pts {
		maxV = math.Max(maxV, v)
	}
	detail := fmt.Sprintf("quarter medians %.1f/%.1f/%.1f/%.1f growth=%.1f tol=%.0f max=%.1f n=%d", med[0], med[1], med[2], med[3], growth, tol, maxV, len(pts))
	return !(monotonic && growth > tol), detail
}

func lhPassesOK(passes []lhPass) bool {
	if len(passes) == 0 {
		return false
	}
	for _, p := range passes {
		if p.Status == "start_failed" || p.DurationS >= lhPassLimit.Seconds() {
			return false
		}
	}
	return true
}

func lhPassDetail(passes []lhPass) string {
	if len(passes) == 0 {
		return "not observed: no pass ran during the run"
	}
	maxD, upper := 0.0, 0
	statuses := map[string]int{}
	for _, p := range passes {
		maxD = math.Max(maxD, p.DurationS)
		if p.UpperBound {
			upper++
		}
		if p.Status != "" {
			statuses[p.Status]++
		}
	}
	return fmt.Sprintf("%d passes, max %.2f s (limit %.0f s), upper-bound boot passes=%d, statuses=%v", len(passes), maxD, lhPassLimit.Seconds(), upper, statuses)
}

func lhEvidence(t *testing.T, coordDB *sql.DB, s *scenario, startVerdictID, startCreditID, succeeded int64) map[string]any {
	t.Helper()
	ev := map[string]any{}
	byOutcome := map[string]int64{}
	var nonVerified, verifiedReqs int64
	rows, err := coordDB.Query(`SELECT settlement_outcome, closed, COUNT(*) FROM settlement_receipt_verdicts WHERE id > ? GROUP BY 1, 2`, startVerdictID)
	if err != nil {
		t.Errorf("evidence query verdicts: %v", err)
		ev["evidence_loss"] = int64(-1)
		return ev
	}
	for rows.Next() {
		var outcome string
		var closed, n int64
		if rows.Scan(&outcome, &closed, &n) == nil {
			byOutcome[fmt.Sprintf("%s/closed=%d", outcome, closed)] = n
			if outcome != "verified" || closed != 1 {
				nonVerified += n
			}
		}
	}
	rows.Close()
	_ = coordDB.QueryRow(`SELECT COUNT(DISTINCT request_id) FROM settlement_receipt_verdicts WHERE id > ? AND settlement_outcome = 'verified' AND closed = 1`, startVerdictID).Scan(&verifiedReqs)
	var credits, enforceCredits int64
	_ = coordDB.QueryRow(`SELECT COUNT(*), COALESCE(SUM(settlement_policy_mode = 'enforce'), 0) FROM ledger_request_credits WHERE id > ?`, startCreditID).Scan(&credits, &enforceCredits)

	gw, err := sql.Open("sqlite", "file:"+s.gatewayDB+"?_pragma=busy_timeout(10000)")
	usage := map[string]int64{}
	if err == nil {
		defer gw.Close()
		if r, err := gw.Query(`SELECT outcome, COUNT(*) FROM usage_events GROUP BY outcome`); err == nil {
			for r.Next() {
				var o string
				var n int64
				if r.Scan(&o, &n) == nil {
					usage[o] = n
				}
			}
			r.Close()
		}
	}
	missing := succeeded - verifiedReqs
	if missing < 0 {
		missing = 0
	}
	ev["verdicts_by_outcome"] = byOutcome
	ev["verified_requests"] = verifiedReqs
	ev["new_ledger_credits"] = credits
	ev["new_enforce_ledger_credits"] = enforceCredits
	ev["gateway_usage_by_outcome"] = usage
	ev["succeeded_requests_without_verified_verdict"] = missing
	ev["non_verified_verdicts"] = nonVerified
	ev["evidence_loss"] = nonVerified + missing
	return ev
}

func lhDBSizes(s *scenario) map[string]int64 {
	out := map[string]int64{}
	for name, p := range map[string]string{
		"coordinator.db":                     s.coordinatorDB,
		"coordinator.db-wal":                 s.coordinatorDB + "-wal",
		"coordinator.db.route-snapshots":     s.coordinatorDB + ".route-snapshots",
		"coordinator.db.route-snapshots-wal": s.coordinatorDB + ".route-snapshots-wal",
		"gateway.db":                         s.gatewayDB,
		"gateway.db-wal":                     s.gatewayDB + "-wal",
	} {
		if fi, err := os.Stat(p); err == nil {
			out[name] = fi.Size()
		}
	}
	var archive int64
	_ = filepath.Walk(filepath.Join(filepath.Dir(s.coordinatorDB), "retention-archive"), func(_ string, fi os.FileInfo, err error) error {
		if err == nil && !fi.IsDir() {
			archive += fi.Size()
		}
		return nil
	})
	out["retention-archive"] = archive
	return out
}

// lhCopySeedDB copies a production-sized coordinator SQLite file (and its
// -wal / route-snapshot journal siblings when present) into place before the
// fixture migrates it and issues provider tokens.
func lhCopySeedDB(t *testing.T, src, dst string) {
	t.Helper()
	cp := func(from, to string, required bool) {
		in, err := os.Open(from)
		if err != nil {
			if !required && os.IsNotExist(err) {
				return
			}
			t.Fatalf("seed db: %v", err)
		}
		defer in.Close()
		out, err := os.OpenFile(to, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
		if err != nil {
			t.Fatalf("seed db: %v", err)
		}
		if _, err := io.Copy(out, in); err != nil {
			t.Fatalf("seed db copy %s: %v", from, err)
		}
		if err := out.Close(); err != nil {
			t.Fatalf("seed db close %s: %v", to, err)
		}
	}
	cp(src, dst, true)
	cp(src+"-wal", dst+"-wal", false)
	cp(src+".route-snapshots", dst+".route-snapshots", false)
	cp(src+".route-snapshots-wal", dst+".route-snapshots-wal", false)
}
