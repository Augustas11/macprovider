// Package reconcile compares the harness's per-request observations
// against the coordinator's request_log and the gateway's usage_events.
//
// IMPORTANT: gateway and coordinator each generate their OWN request_id
// (verified live 2026-06-27 — gateway returns UUID X to buyer, coord
// writes UUID Y in request_log; X and Y never overlap). Correlation by
// request_id is therefore impossible across the two sides. We instead
// correlate by (model, completion_tokens, ts ± window) and report
// drift at both per-request and aggregate level.
//
// Phase A goals (what I1 actually catches):
//   - "harness success but gateway/coord has no matching row" — billing
//     bypass or settlement gap
//   - "row count or token-sum mismatch between gateway and coord in
//     the window" — money-path drift
//   - "harness saw N tokens but gateway billed M (M > N)" — overcharge
package reconcile

import (
	"database/sql"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"

	"github.com/augstar/macprovider-network-harness/internal/buyer"
	"github.com/augstar/macprovider-network-harness/internal/scenario"

	_ "modernc.org/sqlite"
)

type Result struct {
	WindowStartUTC time.Time `json:"window_start_utc"`
	WindowEndUTC   time.Time `json:"window_end_utc"`

	// Counts in the window
	HarnessRequests     int `json:"harness_requests"`
	HarnessSuccessful   int `json:"harness_successful"`
	HarnessFailed       int `json:"harness_failed"`
	CoordinatorRows     int `json:"coordinator_rows"`
	CoordinatorRows2xx  int `json:"coordinator_rows_2xx"`
	CoordinatorRows5xx  int `json:"coordinator_rows_5xx"`
	GatewayRows         int `json:"gateway_rows"`
	GatewayRowsOK       int `json:"gateway_rows_ok"`
	GatewayRowsNotOK    int `json:"gateway_rows_not_ok"`

	// Aggregate token sums (over the same window). A clean reconcile has
	// HarnessCompletionTokens == GatewayCompletionTokens == CoordinatorCompletionTokens.
	HarnessCompletionTokens     int64 `json:"harness_completion_tokens"`
	GatewayCompletionTokens     int64 `json:"gateway_completion_tokens"`
	CoordinatorCompletionTokens int64 `json:"coordinator_completion_tokens"`

	// Per-request fuzzy matches. Each harness success is matched against
	// gateway by (model, completion_tokens, ts proximity).
	MatchedSuccesses   []MatchedPair `json:"matched_successes"`
	UnmatchedSuccesses []string      `json:"unmatched_successes"`

	// Drift signals (signed differences, positive = side has more).
	GatewayMinusCoordinatorTokens int64 `json:"gateway_minus_coordinator_tokens"`
	GatewayMinusHarnessTokens     int64 `json:"gateway_minus_harness_tokens"`

	// Notes records discoveries that don't fit a drift count but matter
	// for triage — e.g. extra rows attributable to background traffic.
	Notes []string `json:"notes,omitempty"`
}

// MatchedPair records a fuzzy match between a harness request and the
// gateway+coordinator rows it most likely produced. Phase B triage uses
// these to spot patterns (large ts gaps, persistent token drift, etc.).
type MatchedPair struct {
	HarnessRequestID            string `json:"harness_request_id"`
	HarnessCompletionTokens     int64  `json:"harness_completion_tokens"`
	GatewayRequestID            string `json:"gateway_request_id"`
	GatewayCompletionTokens     int64  `json:"gateway_completion_tokens"`
	CoordinatorRequestID        string `json:"coordinator_request_id,omitempty"`
	CoordinatorCompletionTokens int64  `json:"coordinator_completion_tokens"`
	GatewayLagMs                int64  `json:"gateway_lag_ms"`
}

// Run pulls coordinator + gateway SQLite (locally or via SSH snapshot)
// and reconciles harness results against rows in the run window.
func Run(sc *scenario.Scenario, results []buyer.Result, startUTC, endUTC time.Time) (*Result, error) {
	// Generous pad — gateway settlement can lag coord write-back by
	// a few seconds (the inference duration).
	pad := 30 * time.Second
	winStart := startUTC.Add(-pad)
	winEnd := endUTC.Add(pad)

	r := &Result{
		WindowStartUTC:  winStart,
		WindowEndUTC:    winEnd,
		HarnessRequests: len(results),
	}
	for _, res := range results {
		if res.Outcome == "ok" {
			r.HarnessSuccessful++
			r.HarnessCompletionTokens += res.CompletionTokensReceived
		} else {
			r.HarnessFailed++
		}
	}

	coordPath, cleanupC, err := resolveDB(sc.Target.CoordinatorDBPath, sc.Target.CoordinatorDBSSH, sc.Target.DBSudoUser, "coordinator")
	if err != nil {
		return r, fmt.Errorf("coordinator snapshot: %w", err)
	}
	defer cleanupC()

	gwPath, cleanupG, err := resolveDB(sc.Target.GatewayDBPath, sc.Target.GatewayDBSSH, sc.Target.DBSudoUser, "gateway")
	if err != nil {
		return r, fmt.Errorf("gateway snapshot: %w", err)
	}
	defer cleanupG()

	coordRows, err := queryCoordinator(coordPath, winStart, winEnd)
	if err != nil {
		return r, fmt.Errorf("coordinator query: %w", err)
	}
	gwRows, err := queryGateway(gwPath, winStart, winEnd)
	if err != nil {
		return r, fmt.Errorf("gateway query: %w", err)
	}

	r.CoordinatorRows = len(coordRows)
	for _, c := range coordRows {
		if c.Status >= 200 && c.Status < 300 {
			r.CoordinatorRows2xx++
			r.CoordinatorCompletionTokens += c.CompletionTokens
		} else if c.Status >= 500 {
			r.CoordinatorRows5xx++
		}
	}
	r.GatewayRows = len(gwRows)
	for _, g := range gwRows {
		if g.Outcome == "ok" {
			r.GatewayRowsOK++
			r.GatewayCompletionTokens += g.CompletionTokens
		} else {
			r.GatewayRowsNotOK++
		}
	}

	r.GatewayMinusCoordinatorTokens = r.GatewayCompletionTokens - r.CoordinatorCompletionTokens
	r.GatewayMinusHarnessTokens = r.GatewayCompletionTokens - r.HarnessCompletionTokens

	matchByFuzzy(r, results, gwRows, coordRows)

	// Background-traffic note: extra rows beyond the harness's count
	// likely belong to other buyers on the live network. Recorded as a
	// note, not counted as drift, in phase A.
	extraGw := r.GatewayRows - r.HarnessRequests
	if extraGw > 0 {
		r.Notes = append(r.Notes,
			fmt.Sprintf("gateway has %d more rows than harness fired — likely concurrent live traffic", extraGw))
	}
	return r, nil
}

// matchByFuzzy pairs each harness success with the most likely gateway
// row by (model, completion_tokens, ts proximity) and then with the
// most likely coordinator row by (model, completion_tokens, ts proximity).
// Once a row is consumed by a match, it's removed from the pool so the
// next harness request can't re-match the same DB row.
func matchByFuzzy(r *Result, results []buyer.Result, gwRows []gwRow, coordRows []coordRow) {
	gwPool := make([]gwRow, len(gwRows))
	copy(gwPool, gwRows)
	coordPool := make([]coordRow, len(coordRows))
	copy(coordPool, coordRows)

	// Walk harness successes in the order they completed.
	type harnessIdx struct {
		idx int
		res buyer.Result
	}
	var ordered []harnessIdx
	for i, res := range results {
		if res.Outcome == "ok" {
			ordered = append(ordered, harnessIdx{i, res})
		}
	}
	sort.Slice(ordered, func(i, j int) bool {
		return ordered[i].res.EndUTC.Before(ordered[j].res.EndUTC)
	})

	for _, h := range ordered {
		gwIdx := pickClosestGw(&gwPool, h.res)
		coordIdx := pickClosestCoord(&coordPool, h.res)
		pair := MatchedPair{
			HarnessRequestID:        h.res.RequestID,
			HarnessCompletionTokens: h.res.CompletionTokensReceived,
		}
		if gwIdx >= 0 {
			g := gwPool[gwIdx]
			pair.GatewayRequestID = g.RequestID
			pair.GatewayCompletionTokens = g.CompletionTokens
			pair.GatewayLagMs = g.CreatedAt.Sub(h.res.StartUTC).Milliseconds()
			gwPool = append(gwPool[:gwIdx], gwPool[gwIdx+1:]...)
		} else {
			r.UnmatchedSuccesses = append(r.UnmatchedSuccesses, h.res.RequestID)
			continue
		}
		if coordIdx >= 0 {
			c := coordPool[coordIdx]
			pair.CoordinatorRequestID = c.RequestID
			pair.CoordinatorCompletionTokens = c.CompletionTokens
			coordPool = append(coordPool[:coordIdx], coordPool[coordIdx+1:]...)
		}
		r.MatchedSuccesses = append(r.MatchedSuccesses, pair)
	}
}

func pickClosestGw(pool *[]gwRow, h buyer.Result) int {
	best := -1
	bestScore := int64(-1)
	for i, g := range *pool {
		if g.Outcome != "ok" {
			continue
		}
		// Model is not in usage_events on gateway side (verified live
		// 2026-06-27 — only request_id + tokens + outcome). We match
		// only by (completion_tokens, ts proximity).
		dt := absInt64(g.CreatedAt.Sub(h.EndUTC).Milliseconds())
		if dt > 60_000 {
			continue
		}
		tokenDiff := absInt64(g.CompletionTokens - h.CompletionTokensReceived)
		// Strong preference for exact token match; penalize ts distance.
		score := tokenDiff*100_000 + dt
		if best < 0 || score < bestScore {
			best = i
			bestScore = score
		}
	}
	return best
}

func pickClosestCoord(pool *[]coordRow, h buyer.Result) int {
	best := -1
	bestScore := int64(-1)
	for i, c := range *pool {
		if c.Status < 200 || c.Status >= 300 {
			continue
		}
		if c.Model != "" && h.Model != "" && c.Model != h.Model {
			continue
		}
		dt := absInt64(c.TsUTC.Sub(h.StartUTC).Milliseconds())
		if dt > 60_000 {
			continue
		}
		tokenDiff := absInt64(c.CompletionTokens - h.CompletionTokensReceived)
		score := tokenDiff*100_000 + dt
		if best < 0 || score < bestScore {
			best = i
			bestScore = score
		}
	}
	return best
}

func absInt64(x int64) int64 {
	if x < 0 {
		return -x
	}
	return x
}

type coordRow struct {
	RequestID        string
	Model            string
	CompletionTokens int64
	Status           int
	TsUTC            time.Time
}

type gwRow struct {
	RequestID        string
	CompletionTokens int64
	Outcome          string
	CreatedAt        time.Time
}

func queryCoordinator(path string, start, end time.Time) ([]coordRow, error) {
	db, err := openRO(path)
	if err != nil {
		return nil, err
	}
	defer db.Close()
	rows, err := db.Query(`
		SELECT request_id, model, COALESCE(completion_tokens, 0), status, ts_utc
		FROM request_log
		WHERE ts_utc >= ? AND ts_utc <= ?
	`, start.Format(time.RFC3339Nano), end.Format(time.RFC3339Nano))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []coordRow
	for rows.Next() {
		var c coordRow
		var ts string
		if err := rows.Scan(&c.RequestID, &c.Model, &c.CompletionTokens, &c.Status, &ts); err != nil {
			return nil, err
		}
		c.TsUTC, _ = time.Parse(time.RFC3339Nano, ts)
		out = append(out, c)
	}
	return out, rows.Err()
}

func queryGateway(path string, start, end time.Time) ([]gwRow, error) {
	db, err := openRO(path)
	if err != nil {
		return nil, err
	}
	defer db.Close()
	rows, err := db.Query(`
		SELECT request_id, completion_tokens, outcome, created_at
		FROM usage_events
		WHERE created_at >= ? AND created_at <= ?
	`, start.Format(time.RFC3339Nano), end.Format(time.RFC3339Nano))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []gwRow
	for rows.Next() {
		var g gwRow
		var ts string
		if err := rows.Scan(&g.RequestID, &g.CompletionTokens, &g.Outcome, &ts); err != nil {
			return nil, err
		}
		g.CreatedAt, _ = time.Parse(time.RFC3339Nano, ts)
		out = append(out, g)
	}
	return out, rows.Err()
}

func openRO(path string) (*sql.DB, error) {
	dsn := fmt.Sprintf("file:%s?mode=ro&_journal_mode=WAL", path)
	return sql.Open("sqlite", dsn)
}

// resolveDB returns a local filesystem path to a queryable SQLite file
// plus a cleanup callback. When `sshSpec` is set, the harness SCPs the
// .db file plus its sibling .db-wal and .db-shm files via `ssh ... cat`
// (no sqlite3 required on the remote host) and lets SQLite's WAL recovery
// on open produce a consistent snapshot. Mild race (WAL changes between
// the three reads) is acceptable for phase-A reporting.
//
// `sudoUser`, when set, wraps `cat` in `sudo -n -u <user>`.
func resolveDB(localPath, sshSpec, sudoUser, tag string) (string, func(), error) {
	noop := func() {}
	if sshSpec == "" {
		return localPath, noop, nil
	}
	colon := strings.Index(sshSpec, ":")
	if colon < 0 {
		return "", noop, fmt.Errorf("ssh spec must be [user@]host:/path (got %q)", sshSpec)
	}
	userHost := sshSpec[:colon]
	remotePath := sshSpec[colon+1:]
	if userHost == "" || remotePath == "" {
		return "", noop, fmt.Errorf("ssh spec missing host or remote path: %q", sshSpec)
	}

	tmpDir, err := os.MkdirTemp("", "harness-"+tag+"-*")
	if err != nil {
		return "", noop, err
	}
	baseName := lastPathSegment(remotePath)
	if baseName == "" {
		os.RemoveAll(tmpDir)
		return "", noop, fmt.Errorf("ssh spec remote path has no filename: %q", remotePath)
	}
	localDB := tmpDir + "/" + baseName
	cleanup := func() { os.RemoveAll(tmpDir) }

	if err := sshCat(userHost, sudoUser, remotePath, localDB); err != nil {
		cleanup()
		return "", noop, fmt.Errorf("fetch main db: %w", err)
	}
	for _, sfx := range []string{"-wal", "-shm"} {
		_ = sshCat(userHost, sudoUser, remotePath+sfx, localDB+sfx)
	}
	return localDB, cleanup, nil
}

func sshCat(userHost, sudoUser, remotePath, localPath string) error {
	remoteCmd := fmt.Sprintf("cat %q", remotePath)
	if sudoUser != "" {
		remoteCmd = fmt.Sprintf("sudo -n -u %s %s", sudoUser, remoteCmd)
	}
	cmd := exec.Command("ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", userHost, remoteCmd)
	out, err := os.Create(localPath)
	if err != nil {
		return err
	}
	defer out.Close()
	cmd.Stdout = out
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%w (stderr: %s)", err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

func lastPathSegment(p string) string {
	for i := len(p) - 1; i >= 0; i-- {
		if p[i] == '/' {
			return p[i+1:]
		}
	}
	return p
}
