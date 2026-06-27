// Package reconcile compares the harness's per-request observations
// against the coordinator's request_log and the gateway's usage_events.
// Drift surfaces in the per-request rows; aggregate counts go in the
// summary. Used by invariant I1.
package reconcile

import (
	"database/sql"
	"fmt"
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
// (with a small grace pad to absorb settlement latency).
func Run(sc *scenario.Scenario, results []buyer.Result, startUTC, endUTC time.Time) (*Result, error) {
	pad := 5 * time.Second
	winStart := startUTC.Add(-pad)
	winEnd := endUTC.Add(pad)

	r := &Result{
		WindowStartUTC:  winStart,
		WindowEndUTC:    winEnd,
		HarnessRequests: len(results),
	}

	coordRows, err := queryCoordinator(sc.Target.CoordinatorDBPath, winStart, winEnd)
	if err != nil {
		return r, fmt.Errorf("coordinator query: %w", err)
	}
	r.CoordinatorRows = len(coordRows)

	gwRows, err := queryGateway(sc.Target.GatewayDBPath, winStart, winEnd)
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
