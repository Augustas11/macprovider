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
	// DriftBasis identifies the algorithm the drift fields below use.
	// Pinned to "per_matched_pair_v2" since issue #226 — earlier artifacts
	// (pre-#229) carry no field and were aggregate-population sums, which
	// false-fired on fallback-heavy runs. Triage tooling that compares
	// `gateway_minus_*` across versions MUST gate on this value.
	DriftBasis string `json:"drift_basis"`

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
	GatewayRowsFallback int `json:"gateway_rows_fallback"`
	GatewayRowsNotOK    int `json:"gateway_rows_not_ok"`

	// Aggregate token sums (over the same window). REFERENCE ONLY — these
	// are NOT drift inputs. Issue #226 surfaced that aggregating across
	// gateway-ok-only rows vs all-harness-ok rows is population-mismatched
	// when most gateway settlements land as SPEC-006 §17.7 fallback
	// outcomes. The drift fields below use per-pair sums instead. Future
	// engineers: do not re-introduce aggregate-sum drift.
	HarnessCompletionTokens         int64 `json:"harness_completion_tokens"`
	GatewayCompletionTokens         int64 `json:"gateway_completion_tokens"`
	GatewayCompletionTokensFallback int64 `json:"gateway_completion_tokens_fallback"`
	CoordinatorCompletionTokens     int64 `json:"coordinator_completion_tokens"`

	// Per-request fuzzy matches. Each harness success is matched against
	// gateway by (model, completion_tokens, ts proximity).
	MatchedSuccesses   []MatchedPair `json:"matched_successes"`
	UnmatchedSuccesses []string      `json:"unmatched_successes"`

	// UnmatchedGatewayOKRows lists gateway settlement rows with outcome="ok"
	// that did NOT match any harness success. These represent either
	// orphan / leaked gateway settlements (real bugs) or concurrent
	// background traffic from other buyers; triage decides. Fallback-
	// outcome leftovers are EXCLUDED here because they're noisy on a
	// live network.
	UnmatchedGatewayOKRows []string `json:"unmatched_gateway_ok_rows,omitempty"`

	// UnmatchedCoordinator2xxRows lists coord request_log rows with
	// 2xx status that did NOT match any harness success. Symmetric with
	// UnmatchedGatewayOKRows on the coordinator side: orphan settlement
	// or concurrent traffic. #229 R5 security HIGH — without this signal,
	// a run with 100 clean matched pairs + 1 extra coord 2xx row leaves
	// every drift signal at zero (the leftover coord row stays invisible).
	UnmatchedCoordinator2xxRows []string `json:"unmatched_coordinator_2xx_rows,omitempty"`

	// MatchedCoordMissing lists matched-pair harness request_ids where the
	// gateway row has outcome="ok" but no coordinator request_log row was
	// found in the window. This is suspicious for "ok" outcomes — a
	// successfully-billed request should leave a coord trail. Fallback
	// outcomes legitimately lack a coord row (provider died mid-stream)
	// and are NOT included here.
	MatchedCoordMissing []string `json:"matched_coord_missing,omitempty"`

	// Drift signals — summed across MATCHED PAIRS only. The fields below
	// supersede aggregate-population subtraction (#226). Positive =
	// gateway has more tokens than its counterpart in the matched pair.
	//
	// NetGatewayMinus* is the signed sum; it can ride on zero when a
	// +N overbill and -N underbill cancel. Triage should NOT use it
	// as the headline pass/fail signal — use PositiveOverbillTokens
	// and OverbilledPairs which preserve per-pair detection.
	NetGatewayMinusCoordinatorTokens int64 `json:"net_gateway_minus_coordinator_tokens"`
	NetGatewayMinusHarnessTokens     int64 `json:"net_gateway_minus_harness_tokens"`

	// Gateway-vs-Harness positive overbill: I1 headline signal for this
	// axis. Sums per-pair (gateway − harness) where gateway > harness.
	// Underbill alone is allowed because gateway-side streaming rounding
	// can legitimately undercount vs the harness's SSE byte timeline.
	// Positive-only means a +N overbill is not hidden behind a −N
	// underbill (#229 R1 CRITICAL).
	GatewayOverbillVsHarnessTokens int64    `json:"gateway_overbill_vs_harness_tokens"`
	OverbilledPairs                []string `json:"overbilled_pairs,omitempty"` // harness request_ids of overbilled pairs

	// Gateway-vs-Coordinator positive overbill: REFERENCE ONLY for triage.
	// Both gateway and coord are settlement systems and MUST agree on
	// per-pair tokens, so I1's headline signal for this axis is the
	// directional-agnostic AbsGatewayCoordinatorMismatchTokens below —
	// NOT this positive-only sum. Kept in the artifact for diagnostic
	// readability (per-axis breakdown of which side has more tokens).
	GatewayOverbillVsCoordinatorTokens int64 `json:"gateway_overbill_vs_coordinator_tokens"`

	// Gateway-vs-Coordinator absolute mismatch: I1 headline signal for
	// this axis. Sum of |gateway − coord| across matched pairs (#229 R2
	// HIGH). Unlike gateway-vs-harness — where streaming rounding makes
	// underbill legit — gateway and coordinator are both settlement
	// systems and MUST agree on per-request token counts. Any direction
	// of mismatch is a money-path ledger inconsistency. I1 fails on
	// non-zero.
	AbsGatewayCoordinatorMismatchTokens int64    `json:"abs_gateway_coordinator_mismatch_tokens"`
	GatewayCoordMismatchedPairs         []string `json:"gateway_coord_mismatched_pairs,omitempty"`

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
	GatewayOutcome              string `json:"gateway_outcome"` // "ok" or SPEC-006 §17.7 fallback name; distinguishes coord-missing severity
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
		switch {
		case g.Outcome == "ok":
			r.GatewayRowsOK++
			r.GatewayCompletionTokens += g.CompletionTokens
		case isSettlementComplete(g.Outcome):
			// Streaming-fallback outcomes: counted for matching but
			// excluded from drift sums because coord has no row and
			// harness undercounts (F-8) — drift would be spurious.
			r.GatewayRowsFallback++
			r.GatewayCompletionTokensFallback += g.CompletionTokens
		default:
			r.GatewayRowsNotOK++
		}
	}

	r.DriftBasis = "per_matched_pair_v2"
	leftoverGw, leftoverCoord := matchByFuzzy(r, results, gwRows, coordRows)
	computePerPairDrift(r)
	collectUnmatchedGatewayOK(r, leftoverGw)
	collectUnmatchedCoord2xx(r, leftoverCoord)

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

// computePerPairDrift derives drift signals from r.MatchedSuccesses.
// Replaces the earlier aggregate-sum approach which subtracted gateway-
// ok-only token totals from full-harness-ok totals — a population-
// mismatch that produced spurious non-zero drift whenever the gateway
// settled most successful streams as SPEC-006 §17.7 fallback outcomes
// (issue #226 production trip on 2026-06-29).
//
// Emits four drift fields per axis (gateway-vs-harness, gateway-vs-coord):
//
//	NetGateway*-: signed sum of per-pair (gateway - other) deltas.
//	             A +N overbill and -N underbill cancel to 0 here; this
//	             field is for triage reference, NOT the I1 pass/fail
//	             input (3-lane codex audit CRITICAL on PR #229 R1).
//
//	GatewayOverbill*-: sum of POSITIVE-only per-pair deltas; an overbilled
//	                  pair contributes its overbill amount, an underbilled
//	                  pair contributes 0. This is the headline overbill
//	                  signal — does NOT cancel against other pairs.
//
// Also populates OverbilledPairs with harness request IDs of any pair
// where the gateway billed more than the harness observed, so triage
// can drill into the offending requests.
//
// MatchedCoordMissing is populated for pairs whose gateway outcome is
// "ok" but no coord row matched — fallback outcomes legitimately lack
// a coord row (provider died mid-stream) and aren't flagged here.
//
// Unmatched harness successes are NOT counted here — they show up
// independently as r.UnmatchedSuccesses for I1's "missing on gateway"
// signal.
func computePerPairDrift(r *Result) {
	for _, p := range r.MatchedSuccesses {
		// Gateway vs Harness — fold the delta into the headline overbill
		// signal ONLY for gateway "ok" pairs. SPEC-006 §17.7 fallback
		// outcomes (stream_truncated etc.) have a known asymmetry: the
		// gateway records the bytes it actually emitted before the upstream
		// error, while the harness's SSE parser undercounts (F-8). The
		// pre-existing #226 production scenario specifically had fallback
		// gateway tokens >> harness tokens; if we counted those as overbill,
		// I1 would false-fail on exactly the shape this PR is meant to fix
		// (#229 R5 architect HIGH).
		dh := p.GatewayCompletionTokens - p.HarnessCompletionTokens
		r.NetGatewayMinusHarnessTokens += dh
		if dh > 0 && isGatewayOKOutcome(p.GatewayOutcome) {
			r.GatewayOverbillVsHarnessTokens += dh
			r.OverbilledPairs = append(r.OverbilledPairs, p.HarnessRequestID)
		}

		// Gateway vs Coordinator — only when a coord match exists.
		// Coord and gateway are BOTH settlement systems for the same
		// request, so any per-pair token disagreement (in either
		// direction) is a ledger inconsistency that I1 must surface.
		// AbsGatewayCoordinatorMismatchTokens uses |delta| to avoid
		// signed-cancel across pairs (#229 R2 HIGH).
		//
		// When a coord row is missing for a gateway-OK pair (i.e. the
		// gateway settled cleanly but no coord trail), surface separately
		// in MatchedCoordMissing rather than dropping the signal.
		if p.CoordinatorRequestID != "" {
			dc := p.GatewayCompletionTokens - p.CoordinatorCompletionTokens
			r.NetGatewayMinusCoordinatorTokens += dc
			if dc > 0 {
				r.GatewayOverbillVsCoordinatorTokens += dc
			}
			if dc != 0 {
				if dc < 0 {
					r.AbsGatewayCoordinatorMismatchTokens += -dc
				} else {
					r.AbsGatewayCoordinatorMismatchTokens += dc
				}
				r.GatewayCoordMismatchedPairs = append(r.GatewayCoordMismatchedPairs, p.HarnessRequestID)
			}
		} else if isGatewayOKOutcome(p.GatewayOutcome) {
			r.MatchedCoordMissing = append(r.MatchedCoordMissing, p.HarnessRequestID)
		}
	}
}

// collectUnmatchedGatewayOK lists gateway rows with outcome="ok" that
// matchByFuzzy did NOT consume into a MatchedSuccesses pair. These are
// either orphan gateway settlements (real bugs — gateway billed for a
// request the harness never fired) or concurrent background traffic
// from other buyers. Triage decides. Fallback-outcome leftovers are
// EXCLUDED because they are noisy on a live network where streams can
// truncate without involving the harness.
//
// IMPORTANT: this takes the leftover gwPool returned by matchByFuzzy,
// not the original gwRows. The pool is identity-tracked by slice
// position, NOT by request_id, so we never accidentally mark a duplicate
// (account_id, request_id) row consumed (#229 R3 security HIGH).
func collectUnmatchedGatewayOK(r *Result, leftoverGw []gwRow) {
	for _, g := range leftoverGw {
		if g.Outcome != "ok" {
			continue
		}
		r.UnmatchedGatewayOKRows = append(r.UnmatchedGatewayOKRows, g.RequestID)
	}
}

// collectUnmatchedCoord2xx surfaces coord request_log rows with 2xx
// status that matchByFuzzy did NOT consume. Symmetric with the
// gateway-ok orphan path: a coord row representing a settled request
// with no harness/gateway counterpart is either orphan/leaked or
// concurrent buyer traffic. I1 must fail on these — without this
// signal, a 100-clean-pairs + 1-extra-coord-row run leaves all drift
// fields at zero (#229 R5 security HIGH).
func collectUnmatchedCoord2xx(r *Result, leftoverCoord []coordRow) {
	for _, c := range leftoverCoord {
		if c.Status < 200 || c.Status >= 300 {
			continue
		}
		r.UnmatchedCoordinator2xxRows = append(r.UnmatchedCoordinator2xxRows, c.RequestID)
	}
}

// matchByFuzzy pairs each harness success with the most likely gateway
// row by (model, completion_tokens, ts proximity) and then with the
// most likely coordinator row by (model, completion_tokens, ts proximity).
// Once a row is consumed by a match, it's removed from the pool so the
// next harness request can't re-match the same DB row.
//
// Returns the leftover gateway pool — rows that did NOT consume into a
// match. Callers use this to detect orphan/leaked settlement rows
// directly from row identity, NOT from request_id (which the gateway
// schema does not guarantee globally unique under the composite PK
// `(account_id, request_id)`; #229 R3 security HIGH).
func matchByFuzzy(r *Result, results []buyer.Result, gwRows []gwRow, coordRows []coordRow) ([]gwRow, []coordRow) {
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
		pair := MatchedPair{
			HarnessRequestID:        h.res.RequestID,
			HarnessCompletionTokens: h.res.CompletionTokensReceived,
		}
		if gwIdx >= 0 {
			g := gwPool[gwIdx]
			pair.GatewayRequestID = g.RequestID
			pair.GatewayCompletionTokens = g.CompletionTokens
			pair.GatewayOutcome = g.Outcome
			pair.GatewayLagMs = g.CreatedAt.Sub(h.res.StartUTC).Milliseconds()
			gwPool = append(gwPool[:gwIdx], gwPool[gwIdx+1:]...)
		} else {
			r.UnmatchedSuccesses = append(r.UnmatchedSuccesses, h.res.RequestID)
			continue
		}
		// Only attempt a coord match when the gateway settled as "ok".
		// SPEC-006 §17.7 fallback outcomes (stream_truncated, etc.)
		// legitimately lack a coord row (provider died mid-stream), so
		// pulling one in would (a) consume a coord row that a later
		// real "ok" pair needs, and (b) misattribute a token mismatch
		// to a fallback pair where coord disagreement is expected.
		// This avoids the false I1 failure mode flagged on PR #229 R4.
		if isGatewayOKOutcome(pair.GatewayOutcome) {
			if coordIdx := pickClosestCoord(&coordPool, h.res); coordIdx >= 0 {
				c := coordPool[coordIdx]
				pair.CoordinatorRequestID = c.RequestID
				pair.CoordinatorCompletionTokens = c.CompletionTokens
				coordPool = append(coordPool[:coordIdx], coordPool[coordIdx+1:]...)
			}
		}
		r.MatchedSuccesses = append(r.MatchedSuccesses, pair)
	}
	return gwPool, coordPool
}

func pickClosestGw(pool *[]gwRow, h buyer.Result) int {
	best := -1
	bestScore := int64(-1)
	for i, g := range *pool {
		if !isSettlementComplete(g.Outcome) {
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

// isGatewayOKOutcome reports whether a gateway outcome value represents
// a clean SPEC-006 streaming completion that SHOULD have a corresponding
// coord row. Centralizing this in one place — symmetric with
// isSettlementComplete — keeps the drift logic from going out of sync
// when SPEC-006 §17.7 adds new fallback outcome names (#229 R2 architect
// MEDIUM).
func isGatewayOKOutcome(outcome string) bool {
	return outcome == "ok"
}

// isSettlementComplete returns true for any gateway outcome value that
// represents a complete settlement event from a money-path perspective.
// "ok" is the canonical happy-path value; the rest are SPEC-006 § 17.7
// streaming-fallback outcomes — the gateway still writes a usage_events
// row with bytes emitted so far, so the audit trail is complete. From
// the reconciler's point of view, any of these rows is a valid match
// for a harness-success result (the harness saw a 200 + a terminator
// signal, the gateway recorded the settlement row).
//
// Source enumeration: phase5-gateway/internal/router/chat_proxy.go
// settleAfterCommit() / settleBeforeResponse() call sites.
func isSettlementComplete(outcome string) bool {
	switch outcome {
	case "ok",
		"stream_truncated",
		"stream_malformed",
		"stream_output_exceeded",
		"upstream_error":
		return true
	}
	return false
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
