// Package reconcile compares the harness's per-request observations
// against the coordinator's request_log and the gateway's usage_events.
// Drift surfaces in the per-request rows; aggregate counts go in the
// summary. Used by invariant I1.
package reconcile

import (
	"database/sql"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/augstar/macprovider-network-harness/internal/buyer"
	"github.com/augstar/macprovider-network-harness/internal/scenario"

	_ "modernc.org/sqlite"
)

type Result struct {
	WindowStartUTC time.Time `json:"window_start_utc"`
	WindowEndUTC   time.Time `json:"window_end_utc"`

	HarnessRequests int `json:"harness_requests"`
	CoordinatorRows int `json:"coordinator_rows"`
	GatewayRows     int `json:"gateway_rows"`

	// MissingOnCoordinator: harness saw a successful response but no
	// row in request_log within the window. Investigate as a logging
	// gap or a billing-bypass path.
	MissingOnCoordinator []string `json:"missing_on_coordinator"`
	// MissingOnGateway: harness saw a successful response but no
	// usage_events row. Investigate as a billing bypass (charged or not?).
	MissingOnGateway []string `json:"missing_on_gateway"`
	// TokenMismatches: gateway and coordinator disagree on completion
	// tokens for the same request_id. The contract should pin one as
	// authoritative.
	TokenMismatches []Mismatch `json:"token_mismatches"`
	// OrphanRows: rows on either side with no matching harness request.
	// Phase A: report only; could be unrelated concurrent traffic.
	OrphanCoordinatorRows int `json:"orphan_coordinator_rows"`
	OrphanGatewayRows     int `json:"orphan_gateway_rows"`
}

type Mismatch struct {
	RequestID         string `json:"request_id"`
	HarnessTokens     int64  `json:"harness_completion_tokens"`
	CoordinatorTokens int64  `json:"coordinator_completion_tokens"`
	GatewayTokens     int64  `json:"gateway_completion_tokens"`
}

// Run opens both SQLite DBs read-only and reconciles harness results
// against rows whose ts_utc / created_at fall within the run window
// (with a small grace pad to absorb settlement latency). When the
// scenario target uses *_db_ssh, a WAL-consistent snapshot is pulled
// to a local temp file before the query runs; temp files are cleaned
// up on return.
func Run(sc *scenario.Scenario, results []buyer.Result, startUTC, endUTC time.Time) (*Result, error) {
	pad := 5 * time.Second
	winStart := startUTC.Add(-pad)
	winEnd := endUTC.Add(pad)

	r := &Result{
		WindowStartUTC:  winStart,
		WindowEndUTC:    winEnd,
		HarnessRequests: len(results),
	}

	coordPath, cleanupC, err := resolveDB(sc.Target.CoordinatorDBPath, sc.Target.CoordinatorDBSSH, "coordinator")
	if err != nil {
		return r, fmt.Errorf("coordinator snapshot: %w", err)
	}
	defer cleanupC()

	gwPath, cleanupG, err := resolveDB(sc.Target.GatewayDBPath, sc.Target.GatewayDBSSH, "gateway")
	if err != nil {
		return r, fmt.Errorf("gateway snapshot: %w", err)
	}
	defer cleanupG()

	coordRows, err := queryCoordinator(coordPath, winStart, winEnd)
	if err != nil {
		return r, fmt.Errorf("coordinator query: %w", err)
	}
	r.CoordinatorRows = len(coordRows)

	gwRows, err := queryGateway(gwPath, winStart, winEnd)
	if err != nil {
		return r, fmt.Errorf("gateway query: %w", err)
	}
	r.GatewayRows = len(gwRows)

	// Index rows by request_id for join.
	coordByID := map[string]coordRow{}
	for _, c := range coordRows {
		coordByID[c.RequestID] = c
	}
	gwByID := map[string]gwRow{}
	for _, g := range gwRows {
		gwByID[g.RequestID] = g
	}

	seenIDs := map[string]bool{}
	for _, res := range results {
		seenIDs[res.RequestID] = true
		if res.Outcome != "ok" {
			// Non-ok requests may legitimately have no billing entry;
			// I2 handles the orphan-5xx case separately.
			continue
		}
		c, hasC := coordByID[res.RequestID]
		g, hasG := gwByID[res.RequestID]
		if !hasC {
			r.MissingOnCoordinator = append(r.MissingOnCoordinator, res.RequestID)
		}
		if !hasG {
			r.MissingOnGateway = append(r.MissingOnGateway, res.RequestID)
		}
		if hasC && hasG {
			if c.CompletionTokens != g.CompletionTokens ||
				(res.CompletionTokensReceived > 0 && res.CompletionTokensReceived != g.CompletionTokens) {
				r.TokenMismatches = append(r.TokenMismatches, Mismatch{
					RequestID:         res.RequestID,
					HarnessTokens:     res.CompletionTokensReceived,
					CoordinatorTokens: c.CompletionTokens,
					GatewayTokens:     g.CompletionTokens,
				})
			}
		}
	}

	for id := range coordByID {
		if !seenIDs[id] {
			r.OrphanCoordinatorRows++
		}
	}
	for id := range gwByID {
		if !seenIDs[id] {
			r.OrphanGatewayRows++
		}
	}
	return r, nil
}

type coordRow struct {
	RequestID        string
	CompletionTokens int64
	Status           int
}

type gwRow struct {
	RequestID        string
	CompletionTokens int64
	Outcome          string
}

func queryCoordinator(path string, start, end time.Time) ([]coordRow, error) {
	db, err := openRO(path)
	if err != nil {
		return nil, err
	}
	defer db.Close()
	rows, err := db.Query(`
		SELECT request_id, COALESCE(completion_tokens, 0), status
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
		if err := rows.Scan(&c.RequestID, &c.CompletionTokens, &c.Status); err != nil {
			return nil, err
		}
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
		SELECT request_id, completion_tokens, outcome
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
		if err := rows.Scan(&g.RequestID, &g.CompletionTokens, &g.Outcome); err != nil {
			return nil, err
		}
		out = append(out, g)
	}
	return out, rows.Err()
}

func openRO(path string) (*sql.DB, error) {
	// Read-only with WAL — coordinator and gateway are still writing
	// during/after the run.
	dsn := fmt.Sprintf("file:%s?mode=ro&_journal_mode=WAL", path)
	return sql.Open("sqlite", dsn)
}

// resolveDB returns a local filesystem path to a queryable SQLite file
// plus a cleanup callback. When `sshSpec` is set (form
// "user@host:/abs/path/to.db"), a WAL-consistent snapshot is pulled
// using sqlite3's VACUUM INTO over SSH and SCP'd down. The returned
// cleanup removes the local temp file and best-effort removes the
// remote snapshot. When `localPath` is set, it's returned as-is and
// cleanup is a no-op. Neither set returns "" and the caller decides.
func resolveDB(localPath, sshSpec, tag string) (string, func(), error) {
	noop := func() {}
	if sshSpec == "" {
		return localPath, noop, nil
	}
	at := strings.Index(sshSpec, "@")
	colon := strings.Index(sshSpec, ":")
	if at < 0 || colon < 0 || colon < at {
		return "", noop, fmt.Errorf("ssh spec must be user@host:/path (got %q)", sshSpec)
	}
	userHost := sshSpec[:colon]
	remotePath := sshSpec[colon+1:]
	if remotePath == "" {
		return "", noop, fmt.Errorf("ssh spec missing remote path: %q", sshSpec)
	}

	localTmp, err := os.CreateTemp("", "harness-"+tag+"-*.db")
	if err != nil {
		return "", noop, err
	}
	localTmp.Close()
	localPathTmp := localTmp.Name()

	remoteSnap := fmt.Sprintf("/tmp/harness-%s-%d.db", tag, os.Getpid())

	// Step 1: VACUUM INTO on the remote side produces a consistent copy.
	backupCmd := fmt.Sprintf("sqlite3 %q \"VACUUM INTO '%s'\"", remotePath, remoteSnap)
	if out, err := runSSH(userHost, backupCmd); err != nil {
		os.Remove(localPathTmp)
		return "", noop, fmt.Errorf("remote sqlite3 backup: %w (output: %s)", err, strings.TrimSpace(out))
	}

	// Step 2: SCP the snapshot down.
	scp := exec.Command("scp", "-q", fmt.Sprintf("%s:%s", userHost, remoteSnap), localPathTmp)
	if out, err := scp.CombinedOutput(); err != nil {
		_, _ = runSSH(userHost, fmt.Sprintf("rm -f %q", remoteSnap))
		os.Remove(localPathTmp)
		return "", noop, fmt.Errorf("scp snapshot: %w (output: %s)", err, strings.TrimSpace(string(out)))
	}

	cleanup := func() {
		_, _ = runSSH(userHost, fmt.Sprintf("rm -f %q", remoteSnap))
		os.Remove(localPathTmp)
	}
	return localPathTmp, cleanup, nil
}

func runSSH(userHost, remoteCmd string) (string, error) {
	cmd := exec.Command("ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", userHost, remoteCmd)
	out, err := cmd.CombinedOutput()
	return string(out), err
}
