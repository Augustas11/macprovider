// Package reconcile compares the harness's per-request observations
// against the coordinator's request_log and the gateway's usage_events.
//
// Cross-service request_id semantics:
//   - Gateway's usage_events.request_id is the gateway-issued PK.
//     The gateway echoes it back to the buyer via the X-Request-Id
//     response header, so the harness records it as
//     buyer.Result.RequestID (loadgen.go:199).
//   - Coordinator's request_log.request_id is INTERNAL and not
//     correlatable across services. The gateway-issued id is
//     persisted on coord side as
//     request_log.external_request_id (phase4-coordinator/internal/
//     requestlog/store.go:38-46).
//
// matchPairs uses exact id correlation when available:
//   - gateway: buyer.Result.RequestID == gateway.usage_events.request_id
//   - coord:   buyer.Result.RequestID == coord.request_log.external_request_id
//
// Falls back to fuzzy (completion_tokens, ts ± window) match when no
// exact-id candidate is found, or when an exact-id hit is ambiguous
// (multiple candidates from the gateway's composite
// `(account_id, request_id)` PK; #229 R3).
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

// SnapshotForwardPad is the canonical forward pad applied to the
// reconciler's SQL snapshot window AND the runner's pre-snapshot
// quiesce sleep (cmd/harness/main.go). They MUST share the same
// value: the runner sleeps long enough for settlements to land, and
// the snapshot extends to the same horizon so those settlements are
// in the pulled rows. Exported so cmd/harness can reference it
// directly instead of redeclaring.
const SnapshotForwardPad = 90 * time.Second

// matchWindow is the per-request temporal tolerance applied by the
// FUZZY matching path as a defense against accidental
// token+timestamp false-positives across the run. Exact-ID matches
// have their own wider tolerance (exactMatchSettleWindow) because
// the request_id + account consensus already discriminate strongly,
// and gateway settlements can lag the harness's observation by tens
// of seconds (live v0.3 max: 76s).
const matchWindow = 60 * time.Second
const matchWindowMs = int64(matchWindow / time.Millisecond)

// exactMatchSettleWindow is the temporal tolerance applied when a
// row matches a harness result by request_id AND passes the account-
// consensus guard. Sized to compose with SnapshotForwardPad so any
// row inside the snapshot is also matchable. Without this split a
// 76s-late gateway settlement would be pulled into the snapshot but
// rejected by the matcher's tighter 60s window, surfacing as a
// false-positive UnmatchedSuccesses signal (#243 R3 finding).
const exactMatchSettleWindow = SnapshotForwardPad
const exactMatchSettleWindowMs = int64(exactMatchSettleWindow / time.Millisecond)

// Match-method labels persisted on MatchedPair. Kept as private
// typed-string consts so tests and future helpers can reference them
// without retyping the literal.
const (
	methodExactID = "exact_id"
	methodFuzzy   = "fuzzy_token_ts"
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

	// HarnessAccountID is the account_id consensus from the first
	// exact-id gateway hit. The harness is one buyer = one account, but
	// the gateway/coord DBs contain rows for every buyer; the consensus
	// pins the matcher to that account and prevents a foreign-account
	// row from consuming a match by id collision alone. Empty when no
	// row carried a non-empty account_id (legacy snapshot).
	HarnessAccountID string `json:"harness_account_id,omitempty"`

	// Schema flags from the snapshot's PRAGMA table_info probe.
	// When true, queryGateway / queryCoordinator confirmed the
	// column exists, so the matcher must treat per-row blanks as
	// missing data rather than "legacy noop". When false, the column
	// is absent from the whole snapshot (pre-migration) — the matcher
	// relaxes the account constraint to maintain rollout compatibility.
	GatewayHasAccountID bool `json:"gateway_has_account_id,omitempty"`
	CoordHasAccountID   bool `json:"coord_has_account_id,omitempty"`

	// ReconcileError records a fatal error during reconciliation when
	// the harness configured DBs but couldn't reach them or query them.
	// I1 hard-fails when this is non-empty even if every other drift
	// signal is zero — the audit pipeline must not silently pass when
	// it didn't actually reconcile. Distinct from `Notes`, which is
	// soft-signal triage detail.
	ReconcileError string `json:"reconcile_error,omitempty"`

	// AmbiguousExactGatewayIDs holds harness request_ids where the
	// gateway exact-id pool returned ≥2 candidates after window +
	// account filters. Treated as a HARD I1 signal — the matcher does
	// NOT fall back to unrestricted fuzzy on ambiguity. Either the
	// gateway echoed a colliding id (PK collision across accounts) or
	// the snapshot somehow contains two settled rows for the same id;
	// both demand triage rather than silent attribution.
	AmbiguousExactGatewayIDs []string `json:"ambiguous_exact_gateway_ids,omitempty"`
	AmbiguousExactCoordIDs   []string `json:"ambiguous_exact_coord_ids,omitempty"`

	// Notes records discoveries that don't fit a drift count but matter
	// for triage — e.g. extra rows attributable to background traffic.
	Notes []string `json:"notes,omitempty"`
}

// MatchedPair records a matched pair (harness ↔ gateway[, coord]).
// matchPairs tries exact-id correlation first and falls back to a
// token+ts fuzzy heuristic; GatewayMatchMethod / CoordinatorMatchMethod
// record which path produced each side. Phase B triage uses these to
// spot patterns (a run dominated by fuzzy matches signals a
// header-propagation issue; a `gateway_lag_ms` outlier on a fuzzy match
// signals attribution drift).
type MatchedPair struct {
	HarnessRequestID            string `json:"harness_request_id"`
	HarnessCompletionTokens     int64  `json:"harness_completion_tokens"`
	GatewayRequestID            string `json:"gateway_request_id"`
	GatewayAccountID            string `json:"gateway_account_id,omitempty"`
	GatewayCompletionTokens     int64  `json:"gateway_completion_tokens"`
	GatewayOutcome              string `json:"gateway_outcome"`                // "ok" or SPEC-006 §17.7 fallback name; distinguishes coord-missing severity
	GatewayMatchMethod          string `json:"gateway_match_method,omitempty"` // "exact_id" | "fuzzy_token_ts"
	CoordinatorRequestID        string `json:"coordinator_request_id,omitempty"`
	CoordinatorAccountID        string `json:"coordinator_account_id,omitempty"`
	CoordinatorCompletionTokens int64  `json:"coordinator_completion_tokens"`
	CoordinatorMatchMethod      string `json:"coordinator_match_method,omitempty"` // "exact_id" | "fuzzy_token_ts"
	GatewayLagMs                int64  `json:"gateway_lag_ms"`

	// HarnessSawSSEErrorEvent carries through buyer.Result.SawSSEErrorEvent:
	// true when the last DISPATCHED SSE event in the buyer's stream before
	// `[DONE]` or EOF was a STANDALONE OpenAI-style terminal `error`
	// envelope (no `choices`, no `usage` tokens) — the shape SPEC-006
	// §17.7.1 pins for every in-scope fallback path. "Dispatched" is
	// precise per the HTML5/SSE model: only a blank-line-terminated
	// event counts (#232 R8 SEC HIGH — closes the leading-`[DONE]`
	// undispatched-event class). Used by
	// the fallback-overbill corroboration check at computePerPairDrift to
	// close the trust gap #232 raised:
	//
	//   - gateway "ok"              → never suppressed (clean settlement).
	//   - fallback + SSE error seen → suppressed (gateway claim AND buyer
	//                                 experience agree on truncation; the
	//                                 F-8 SSE-undercount asymmetry the R5
	//                                 fix targeted).
	//   - fallback + no SSE error   → flagged (gateway claims truncation
	//                                 but the buyer never saw an error
	//                                 envelope; the gateway-mislabel /
	//                                 trust-gap signal).
	//
	// Anchor choice rationale (#232 R1 SEC HIGH): an earlier draft used
	// SawTerminator (whether the buyer saw `data: [DONE]`). That was
	// wrong both ways: the gateway's legit fallback paths emit the error
	// envelope FOLLOWED by `[DONE]`, so SawTerminator=true on every real
	// truncation, and a buggy gateway can deliver a clean-looking 200
	// stream WITHOUT `[DONE]` and label the row fallback to evade the
	// check. The SSE error envelope is the actual buyer-side proof of
	// truncation — the gateway cannot fake it without telling the buyer
	// the stream failed.
	HarnessSawSSEErrorEvent bool `json:"harness_saw_sse_error_event"`

	// HarnessSSEErrorCode carries the `error.code` value from the
	// terminal SSE error envelope, when one was observed. Empty when
	// HarnessSawSSEErrorEvent is false. Triage uses this to cross-check
	// the buyer-visible code against the gateway's `outcome` column —
	// a mismatch (e.g. buyer saw `provider_disconnected` but gateway
	// settled `stream_truncated`) is not currently an I1 signal but is
	// useful evidence in `ledger_reconcile.json`. (#232 R2 ARCH LOW.)
	HarnessSSEErrorCode string `json:"harness_sse_error_code,omitempty"`
}

// snapshotWindow returns the SQL query bounds for a reconcile run.
// Forward-only pad: gateway settlement happens AFTER the harness
// observes the response, so the upper bound extends `endUTC` forward
// to catch settlement lag (inference duration + async settle path).
// The lower bound stays at `startUTC` — gateway can never CAUSALLY
// settle before the harness sends. Backward pad pre-fix pulled tail
// rows from a prior scenario's window into the next scenario's
// reconcile, surfacing already-matched rows as false-positive
// orphans (#243).
//
// The forward pad is sized to v0.3 baseline live data (gateway
// settlement lag 26–76s) plus headroom, and matches the runner's
// pre-snapshot quiesce sleep at cmd/harness/main.go so all
// settlements for this scenario have landed before the snapshot is
// pulled. Quiesce + forward-pad composition closes the late-
// settlement leak fully (was issue #248, fixed inline here).
//
// Clock-skew on the lower bound: a gateway whose clock trails the
// harness can write `created_at < startUTC` for a row the harness
// owns, dropping it from the time-window query. Run() handles this
// via a separate by-ID recovery pass (queryGatewayByIDs /
// queryCoordinatorByIDs) for harness-owned request IDs, bypassing
// the time bound entirely. So the lower bound's wall-clock vs
// causal divergence is moot for harness-owned rows.
func snapshotWindow(startUTC, endUTC time.Time) (time.Time, time.Time) {
	return startUTC, endUTC.Add(SnapshotForwardPad)
}

// Run pulls coordinator + gateway SQLite (locally or via SSH snapshot)
// and reconciles harness results against rows in the run window.
func Run(sc *scenario.Scenario, results []buyer.Result, startUTC, endUTC time.Time) (*Result, error) {
	winStart, winEnd := snapshotWindow(startUTC, endUTC)

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

	coordRows, coordHasAcct, err := queryCoordinator(coordPath, winStart, winEnd)
	if err != nil {
		return r, fmt.Errorf("coordinator query: %w", err)
	}
	gwRows, gwHasAcct, err := queryGateway(gwPath, winStart, winEnd)
	if err != nil {
		return r, fmt.Errorf("gateway query: %w", err)
	}

	// ID-recovery pass for harness-owned request IDs whose timestamps
	// landed outside the forward-only snapshot window. Surfaced by the
	// 3-lane codex audit on #243 (security/code HIGH-1): a gateway/coord
	// clock skewed slightly behind the harness's startUTC would drop
	// legitimate rows from the time-window query. By-ID recovery is
	// safe to merge directly — these rows can never be cross-scenario
	// orphans (the harness issued the ID this scenario).
	harnessIDs := harnessRequestIDs(results)
	if len(harnessIDs) > 0 {
		extraGw, err := queryGatewayByIDs(gwPath, harnessIDs)
		if err != nil {
			return r, fmt.Errorf("gateway id-recovery: %w", err)
		}
		gwRows = mergeGwByID(gwRows, extraGw)
		extraCoord, err := queryCoordinatorByIDs(coordPath, harnessIDs)
		if err != nil {
			return r, fmt.Errorf("coordinator id-recovery: %w", err)
		}
		coordRows = mergeCoordByID(coordRows, extraCoord)
	}
	r.GatewayHasAccountID = gwHasAcct
	r.CoordHasAccountID = coordHasAcct

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
	leftoverGw, leftoverCoord := matchPairs(r, results, gwRows, coordRows)
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
		// signal for gateway "ok" pairs OR for fallback pairs where the
		// buyer did NOT see the gateway's SSE error envelope (#232).
		//
		// SPEC-006 §17.7 fallback outcomes (stream_truncated etc.) have a
		// known asymmetry: the gateway records the bytes it actually emitted
		// before the upstream error, while the harness's SSE parser
		// undercounts (F-8). The #229 R5 fix suppressed fallback pairs to
		// stop false-failing I1 on the production #226 shape. But suppressing
		// every fallback pair makes the gateway outcome label a trust gate:
		// a buggy or attacker-controlled gateway that labels a real overbill
		// as `stream_truncated` would hide it from I1 (#229 R6 security HIGH,
		// tracked as #232).
		//
		// Resolution (#232): use the buyer's own observation as a
		// corroboration check. fallbackOverbillSuppressed() returns true
		// only when the buyer ALSO saw the gateway's terminal SSE error
		// envelope (writeSSEError on every fallback path). If the gateway
		// claims a fallback but the buyer never received an error envelope,
		// the truncation is uncorroborated and the overbill is fed into I1
		// — flagging exactly the trust-gap scenario the audit raised. See
		// the helper docstring for why SawTerminator alone was the wrong
		// anchor (#232 R1 SEC HIGH).
		dh := p.GatewayCompletionTokens - p.HarnessCompletionTokens
		r.NetGatewayMinusHarnessTokens += dh
		if dh > 0 && !fallbackOverbillSuppressed(p) {
			r.GatewayOverbillVsHarnessTokens += dh
			r.OverbilledPairs = append(r.OverbilledPairs, p.HarnessRequestID)
		}

		// Gateway vs Coordinator — only when a coord match exists.
		// For gateway "ok" pairs, coord and gateway are BOTH settlement
		// systems for the same request, so any per-pair token disagreement
		// (in either direction) is a ledger inconsistency that I1 must
		// surface. AbsGatewayCoordinatorMismatchTokens uses |delta| to
		// avoid signed-cancel across pairs (#229 R2 HIGH).
		//
		// Fallback pairs keep contributing to the signed net for triage,
		// but are excluded from overbill/mismatch signals for the same
		// fallback-unit asymmetry described on the gateway-vs-harness axis
		// above: gateway counts emitted bytes before truncation, while coord
		// can record the provider's full reported usage. Counting that as
		// drift false-fails I1 in the #285 reproduction.
		//
		// #232: same buyer-corroboration check applies here. The coord
		// axis uses the buyer's view as the trust anchor — if the buyer
		// did NOT receive the gateway's terminal SSE error envelope
		// (HarnessSawSSEErrorEvent=false), the gateway claiming a
		// fallback outcome is uncorroborated and the drift signals fire.
		//
		// When a coord row is missing for a gateway-OK pair (i.e. the
		// gateway settled cleanly but no coord trail), surface separately
		// in MatchedCoordMissing rather than dropping the signal.
		if p.CoordinatorRequestID != "" {
			dc := p.GatewayCompletionTokens - p.CoordinatorCompletionTokens
			r.NetGatewayMinusCoordinatorTokens += dc
			if dc > 0 && !fallbackOverbillSuppressed(p) {
				r.GatewayOverbillVsCoordinatorTokens += dc
			}
			if dc != 0 && !fallbackOverbillSuppressed(p) {
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

// fallbackOverbillSuppressed returns true when the per-pair drift should
// be excluded from I1's overbill/mismatch signals because the pair is a
// SPEC-006 §17.7 streaming-fallback outcome AND the buyer independently
// corroborated the truncation by seeing the gateway's terminal SSE error
// envelope (#232 R1 SEC HIGH: SawTerminator alone was the wrong anchor —
// real truncation paths emit error + `[DONE]` so SawTerminator is always
// true on legitimate fallbacks, and a malicious gateway can omit `[DONE]`
// on a clean stream to forge the negative).
//
//   - Gateway outcome "ok" → never suppressed; clean settlement, drift
//     is real.
//   - Gateway outcome fallback + buyer saw SSE error envelope with a
//     corroborating code (per SPEC-006 §17.7.1 default equality OR a
//     named-mapping exception) → suppressed. The gateway's fallback
//     claim is corroborated by the buyer; F-8 SSE-undercount asymmetry
//     is expected; do not false-fail I1 on the production #226 shape
//     (#229 R5 architect HIGH). Unlisted mismatches (e.g. buyer
//     `provider_timeout` against outcome `stream_truncated`) do NOT
//     suppress — see sseErrorCorroboratesOutcome (#232 R6 SEC + ARCH
//     convergent HIGH; ARCH R7 LOW comment tightening).
//   - Gateway outcome fallback + buyer DID NOT see SSE error envelope →
//     NOT suppressed. The gateway labeled the pair as a fallback but never
//     told the buyer the stream failed via the OpenAI-style error
//     envelope. The truncation claim is uncorroborated and the drift is
//     fed into I1 — flagging exactly the trust-gap shape #229 R6 security
//     HIGH (tracked as #232) raised.
//
// The SSE error envelope is what the gateway must emit for the buyer to
// see a non-clean stream completion (writeSSEError in chat_proxy.go).
// The narrowed corroboration invariant (#232 R3 + R4): the gateway
// cannot satisfy this check unless the buyer-visible final pre-
// `[DONE]`/EOF data frame is a standalone error envelope on a column-0
// line. Post-`[DONE]` envelopes (invisible to OpenAI clients) and
// leading-whitespace forged envelopes (dropped by strict SSE field
// parsing) cannot satisfy it.
func fallbackOverbillSuppressed(p MatchedPair) bool {
	if isGatewayOKOutcome(p.GatewayOutcome) {
		return false
	}
	if !p.HarnessSawSSEErrorEvent {
		return false
	}
	// #232 R6 SEC + ARCH convergent HIGH — enforce the SPEC-006 §17.7.1
	// code/outcome mapping clause. The harness MUST refuse to suppress
	// unless the buyer-visible `error.code` agrees with the gateway's
	// `usage_events.outcome` (either by default equality OR by a named
	// mapping exception). An unlisted mismatch (e.g. buyer code
	// `provider_timeout` against outcome `stream_truncated`) is
	// uncorroborated by SPEC; suppressing it would re-open the trust
	// gap #232 is closing.
	return sseErrorCorroboratesOutcome(p.HarnessSSEErrorCode, p.GatewayOutcome)
}

// sseErrorCorroboratesOutcome implements the SPEC-006 §17.7.1 code/
// outcome mapping check. It returns true when the buyer-visible
// `error.code` agrees with the gateway's `usage_events.outcome`, either
// because they are byte-identical (the default rule) or because the
// pair is on the named-mapping-exception list. Any unlisted mismatch
// returns false.
//
// Empty `code` returns false defensively — the parser only sets
// HarnessSSEErrorCode when a standalone envelope was dispatched, so an
// empty code alongside HarnessSawSSEErrorEvent=true would be a parser
// bug; refuse to suppress.
//
// Future named-mapping exceptions added to SPEC-006 §17.7.1 MUST also
// be added here as additional case branches.
func sseErrorCorroboratesOutcome(code, outcome string) bool {
	if code == "" {
		return false
	}
	if code == outcome {
		return true
	}
	// Named mapping exception per SPEC-006 §17.7.1:
	if code == "provider_disconnected" && outcome == "stream_truncated" {
		return true
	}
	return false
}

// collectUnmatchedGatewayOK lists gateway rows with outcome="ok" that
// matchPairs did NOT consume into a MatchedSuccesses pair. These are
// either orphan gateway settlements (real bugs — gateway billed for a
// request the harness never fired) or concurrent background traffic
// from other buyers. Triage decides. Fallback-outcome leftovers are
// EXCLUDED because they are noisy on a live network where streams can
// truncate without involving the harness.
//
// IMPORTANT: this takes the leftover gwPool returned by matchPairs,
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
// status that matchPairs did NOT consume. Symmetric with the
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

// matchPairs pairs each harness success with the gateway row (and
// where applicable a coordinator row) it actually produced. Strategy
// per side, in order:
//  1. exact id — gateway request_id == harness id, or coord
//     external_request_id == harness id. Requires a single
//     settlement-complete candidate inside the per-request 60s window
//     and matching account_id (when schema has the column).
//  2. fuzzy (token+ts) — the legacy heuristic, used ONLY when exact-id
//     yields zero candidates (exactPickNone).
//
// Ambiguity (≥2 surviving exact-id candidates) is NOT a fuzzy
// fallback — it's a hard signal recorded in r.AmbiguousExactGatewayIDs
// / r.AmbiguousExactCoordIDs, and the harness row is left unmatched.
// Without this gate, R2 fuzzy fallback could still pick an unrelated
// row by token+ts coincidence (R2 audit security HIGH).
//
// Each MatchedPair records which strategy ran for each side
// (GatewayMatchMethod / CoordinatorMatchMethod). Once a row is consumed
// by a match, it's removed from the pool so the next harness request
// can't re-match the same row.
//
// Returns the leftover gateway and coordinator pools — rows that did
// NOT consume into a match. Callers use the leftover pools to detect
// orphan/leaked settlement rows via slice identity, NOT request_id
// (gateway PK is composite `(account_id, request_id)`; #229 R3
// security HIGH).
func matchPairs(r *Result, results []buyer.Result, gwRows []gwRow, coordRows []coordRow) ([]gwRow, []coordRow) {
	gwPool := make([]gwRow, len(gwRows))
	copy(gwPool, gwRows)
	coordPool := make([]coordRow, len(coordRows))
	copy(coordPool, coordRows)

	// Walk harness successes in the order they completed. We sort once
	// and reuse the ordering across both passes to keep pair attribution
	// deterministic.
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

	// Two-pass matching: exact-only first to establish consensus,
	// fuzzy second over deferred items.
	deferredResults := make([]buyer.Result, 0, len(ordered))
	for _, h := range ordered {
		deferredResults = append(deferredResults, h.res)
	}
	stillDeferred := matchExactPass(r, deferredResults, &gwPool, &coordPool)
	matchFuzzyPass(r, stillDeferred, &gwPool, &coordPool)
	return gwPool, coordPool
}

// exactPickStatus distinguishes "no exact candidate" from "ambiguous"
// so the caller can decide between fuzzy fallback and skipping the row
// with a hard signal.
type exactPickStatus int

const (
	// exactPickNone — no exact-id candidate survived the filters.
	// Caller should fall back to fuzzy.
	exactPickNone exactPickStatus = iota
	// exactPickFound — exactly one candidate survived. Use it.
	exactPickFound
	// exactPickAmbiguous — ≥2 candidates survived (same id, same
	// window, same account constraint). Caller MUST NOT fuzzy-pick;
	// emit ambiguity signal and leave the row unmatched.
	exactPickAmbiguous
)

// matchExactPass is pass 1 of matchPairs: walk every harness success
// and try ONLY pickExactGw / pickExactCoord. Successful exact-id hits
// build MatchedPairs immediately and pin r.HarnessAccountID. Ambiguity
// surfaces as a hard signal and marks the row unmatched. Items with no
// exact-id candidate are returned for pass 2 to fuzzy-fallback.
//
// Pass 1 deliberately avoids fuzzy because, on a modern account-aware
// snapshot, fuzzy without consensus could consume a foreign-account
// row by token-proximity coincidence and pin consensus to the wrong
// account (R5 audit code/architect HIGH).
func matchExactPass(r *Result, ordered []buyer.Result, gwPool *[]gwRow, coordPool *[]coordRow) []buyer.Result {
	var deferred []buyer.Result
	for _, h := range ordered {
		gwIdx, gwStatus := pickExactGwByRequestID(gwPool, h, r.HarnessAccountID, r.GatewayHasAccountID)
		if gwStatus == exactPickAmbiguous {
			r.AmbiguousExactGatewayIDs = append(r.AmbiguousExactGatewayIDs, h.RequestID)
			r.UnmatchedSuccesses = append(r.UnmatchedSuccesses, h.RequestID)
			continue
		}
		if gwStatus != exactPickFound {
			deferred = append(deferred, h)
			continue
		}
		g := (*gwPool)[gwIdx]
		pair := MatchedPair{
			HarnessRequestID:        h.RequestID,
			HarnessCompletionTokens: h.CompletionTokensReceived,
			HarnessSawSSEErrorEvent: h.SawSSEErrorEvent,
			HarnessSSEErrorCode:     h.SSEErrorCode,
			GatewayMatchMethod:      methodExactID,
			GatewayRequestID:        g.RequestID,
			GatewayAccountID:        g.AccountID,
			GatewayCompletionTokens: g.CompletionTokens,
			GatewayOutcome:          g.Outcome,
			GatewayLagMs:            g.CreatedAt.Sub(h.StartUTC).Milliseconds(),
		}
		*gwPool = append((*gwPool)[:gwIdx], (*gwPool)[gwIdx+1:]...)
		// Pin consensus from the first exact-id hit with a non-empty
		// account_id. Legacy snapshots (account_id absent) leave it
		// empty — the schema flag in rowAccountIDMatches makes that a
		// noop on the constraint.
		if r.HarnessAccountID == "" && g.AccountID != "" {
			r.HarnessAccountID = g.AccountID
		}
		attachCoord(r, &pair, h, coordPool, true /* exactOnly: pass 1 also gates coord to exact-id */)
		r.MatchedSuccesses = append(r.MatchedSuccesses, pair)
	}
	return deferred
}

// matchFuzzyPass is pass 2 of matchPairs: walk items that pass 1
// deferred and try the fuzzy heuristic. Consensus (r.HarnessAccountID)
// is now whatever pass 1 established. pickClosestGw / pickClosestCoord
// enforce account equality through rowAccountIDMatches, AND refuse to
// match entirely on a modern snapshot with no consensus (every
// deferred item then surfaces in UnmatchedSuccesses).
func matchFuzzyPass(r *Result, deferred []buyer.Result, gwPool *[]gwRow, coordPool *[]coordRow) {
	for _, h := range deferred {
		gwIdx := pickClosestGw(gwPool, h, r.HarnessAccountID, r.GatewayHasAccountID)
		if gwIdx < 0 {
			r.UnmatchedSuccesses = append(r.UnmatchedSuccesses, h.RequestID)
			continue
		}
		g := (*gwPool)[gwIdx]
		pair := MatchedPair{
			HarnessRequestID:        h.RequestID,
			HarnessCompletionTokens: h.CompletionTokensReceived,
			HarnessSawSSEErrorEvent: h.SawSSEErrorEvent,
			HarnessSSEErrorCode:     h.SSEErrorCode,
			GatewayMatchMethod:      methodFuzzy,
			GatewayRequestID:        g.RequestID,
			GatewayAccountID:        g.AccountID,
			GatewayCompletionTokens: g.CompletionTokens,
			GatewayOutcome:          g.Outcome,
			GatewayLagMs:            g.CreatedAt.Sub(h.StartUTC).Milliseconds(),
		}
		*gwPool = append((*gwPool)[:gwIdx], (*gwPool)[gwIdx+1:]...)
		attachCoord(r, &pair, h, coordPool, false /* allow fuzzy on coord */)
		r.MatchedSuccesses = append(r.MatchedSuccesses, pair)
	}
}

// attachCoord populates the coord side of a pair from the coordPool
// when the gateway settlement is complete. Fallback outcomes can have
// exact coord rows (e.g. stream_truncated via finish_reason=length,
// issue #285), but still legitimately lack coord rows when the provider
// died mid-stream. On pass 1 (exactOnly), only the exact-id picker runs;
// on pass 2, fuzzy fallback remains restricted to gateway "ok" pairs so
// fallback rows cannot steal unrelated coord rows by token proximity.
func attachCoord(r *Result, pair *MatchedPair, h buyer.Result, coordPool *[]coordRow, exactOnly bool) {
	if !isSettlementComplete(pair.GatewayOutcome) {
		return
	}
	coordIdx, coordStatus := pickExactCoordByRequestID(coordPool, h, r.HarnessAccountID, r.CoordHasAccountID)
	if coordStatus == exactPickAmbiguous {
		r.AmbiguousExactCoordIDs = append(r.AmbiguousExactCoordIDs, h.RequestID)
		// Leave coord fields empty — computePerPairDrift will surface in MatchedCoordMissing.
		return
	}
	if coordStatus == exactPickFound {
		c := (*coordPool)[coordIdx]
		pair.CoordinatorRequestID = c.RequestID
		pair.CoordinatorAccountID = c.AccountID
		pair.CoordinatorCompletionTokens = c.CompletionTokens
		pair.CoordinatorMatchMethod = methodExactID
		*coordPool = append((*coordPool)[:coordIdx], (*coordPool)[coordIdx+1:]...)
		return
	}
	if exactOnly {
		return
	}
	if !isGatewayOKOutcome(pair.GatewayOutcome) {
		return
	}
	if fuzzyIdx := pickClosestCoord(coordPool, h, r.HarnessAccountID, r.CoordHasAccountID); fuzzyIdx >= 0 {
		c := (*coordPool)[fuzzyIdx]
		pair.CoordinatorRequestID = c.RequestID
		pair.CoordinatorAccountID = c.AccountID
		pair.CoordinatorCompletionTokens = c.CompletionTokens
		pair.CoordinatorMatchMethod = methodFuzzy
		*coordPool = append((*coordPool)[:fuzzyIdx], (*coordPool)[fuzzyIdx+1:]...)
	}
}

// rowAccountIDMatches centralizes the schema-aware account check used
// by every picker. Logic, in priority order:
//  1. schema lacks the column → legacy snapshot, constraint is a
//     global noop (rollout compatibility). Accept regardless of
//     consensus state.
//  2. schema has the column but the row value is empty (NULL/blank)
//     → unconditionally REJECT, EVEN ON BOOTSTRAP (no consensus yet).
//     We cannot prove this row belongs to the harness's buyer; the
//     first match would otherwise pin consensus to a phantom account
//     and corrupt every subsequent match (R4 audit security HIGH).
//  3. consensus not yet pinned → accept (the first non-empty row's
//     account_id becomes the consensus in matchPairs).
//  4. consensus pinned → require equality with the row's account_id.
//
// This shape ensures that on modern (account_id-present) snapshots, an
// attacker cannot bootstrap consensus through a NULL-account row.
func rowAccountIDMatches(rowAcct, requireAccountID string, schemaHasAccountID bool) bool {
	if !schemaHasAccountID {
		return true
	}
	if rowAcct == "" {
		return false
	}
	if requireAccountID == "" {
		return true
	}
	return rowAcct == requireAccountID
}

// pickExactGwByRequestID returns (idx, status) for the gateway pool.
// A candidate must:
//   - have a non-empty harness id,
//   - be settlement-complete,
//   - carry the harness's RequestID,
//   - fall inside the per-request matchWindow (defense against stale /
//     cross-window id collisions even when the SQL snapshot is wider),
//   - have a matching account_id when the harness's account consensus
//     is established (defense against cross-account id collisions on a
//     shared gateway; gateway PK is composite (account_id, request_id)
//     per ISS-196).
//
// One survivor → exactPickFound.  Two or more → exactPickAmbiguous
// (caller must NOT fall back to unrestricted fuzzy).  None →
// exactPickNone (caller falls back to fuzzy).
func pickExactGwByRequestID(pool *[]gwRow, h buyer.Result, requireAccountID string, schemaHasAccountID bool) (int, exactPickStatus) {
	if h.RequestID == "" {
		return -1, exactPickNone
	}
	hit := -1
	for i, g := range *pool {
		if !isSettlementComplete(g.Outcome) {
			continue
		}
		if g.RequestID != h.RequestID {
			continue
		}
		if absInt64(g.CreatedAt.Sub(h.EndUTC).Milliseconds()) > exactMatchSettleWindowMs {
			continue
		}
		if !rowAccountIDMatches(g.AccountID, requireAccountID, schemaHasAccountID) {
			continue
		}
		if hit >= 0 {
			return -1, exactPickAmbiguous
		}
		hit = i
	}
	if hit < 0 {
		return -1, exactPickNone
	}
	return hit, exactPickFound
}

// pickExactCoordByRequestID is the coord-side analog. The id join is on
// external_request_id (NOT internal request_id); account_id is
// enforced symmetrically.
func pickExactCoordByRequestID(pool *[]coordRow, h buyer.Result, requireAccountID string, schemaHasAccountID bool) (int, exactPickStatus) {
	if h.RequestID == "" {
		return -1, exactPickNone
	}
	hit := -1
	for i, c := range *pool {
		if c.Status < 200 || c.Status >= 300 {
			continue
		}
		if c.ExternalRequestID != h.RequestID {
			continue
		}
		if absInt64(c.TsUTC.Sub(h.StartUTC).Milliseconds()) > exactMatchSettleWindowMs {
			continue
		}
		if !rowAccountIDMatches(c.AccountID, requireAccountID, schemaHasAccountID) {
			continue
		}
		if hit >= 0 {
			return -1, exactPickAmbiguous
		}
		hit = i
	}
	if hit < 0 {
		return -1, exactPickNone
	}
	return hit, exactPickFound
}

// pickClosestGw is the fuzzy fallback when exact-id yielded
// exactPickNone. It enforces the same window + account constraints as
// the exact picker so cross-account/cross-window rows can't sneak in
// via the heuristic.
//
// On a modern (account_id-aware) snapshot with no consensus pinned,
// pickClosestGw refuses to match — a token+ts heuristic without
// account anchoring could otherwise consume a foreign-account row
// and corrupt every downstream pair (R5 audit code/architect HIGH).
// Items refused here surface in UnmatchedSuccesses upstream.
func pickClosestGw(pool *[]gwRow, h buyer.Result, requireAccountID string, schemaHasAccountID bool) int {
	if schemaHasAccountID && requireAccountID == "" {
		return -1
	}
	best := -1
	bestScore := int64(-1)
	for i, g := range *pool {
		if !isSettlementComplete(g.Outcome) {
			continue
		}
		if !rowAccountIDMatches(g.AccountID, requireAccountID, schemaHasAccountID) {
			continue
		}
		// Model is not in usage_events on gateway side (verified live
		// 2026-06-27 — only request_id + tokens + outcome). We match
		// only by (completion_tokens, ts proximity).
		dt := absInt64(g.CreatedAt.Sub(h.EndUTC).Milliseconds())
		if dt > matchWindowMs {
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

// pickClosestCoord is the coord fuzzy fallback, with the same
// account + window constraints as pickClosestGw — including the
// modern-schema-no-consensus refuse.
func pickClosestCoord(pool *[]coordRow, h buyer.Result, requireAccountID string, schemaHasAccountID bool) int {
	if schemaHasAccountID && requireAccountID == "" {
		return -1
	}
	best := -1
	bestScore := int64(-1)
	for i, c := range *pool {
		if c.Status < 200 || c.Status >= 300 {
			continue
		}
		if !rowAccountIDMatches(c.AccountID, requireAccountID, schemaHasAccountID) {
			continue
		}
		if c.Model != "" && h.Model != "" && c.Model != h.Model {
			continue
		}
		dt := absInt64(c.TsUTC.Sub(h.StartUTC).Milliseconds())
		if dt > matchWindowMs {
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
//
// `provider_timeout` was added in #232 R5 ARCH MED — SPEC-019 v0.2.4 §10
// gateway wall-clock timeout writes `usage_events.outcome=provider_timeout`
// for structured streaming; prior to this addition the reconciler treated
// those rows as incomplete and surfaced them as unmatched.
func isSettlementComplete(outcome string) bool {
	switch outcome {
	case "ok",
		"stream_truncated",
		"stream_malformed",
		"stream_output_exceeded",
		"upstream_error",
		"provider_timeout",
		// `client_disconnect` and `invalid_provider_usage` are gateway-
		// settled outcomes for non-success paths (client-disconnect
		// surface vs malformed-provider-usage detection). Adding both
		// keeps the reconciler from surfacing these rows as
		// unmatched/incomplete. (#232 R6 CODE LOW.)
		"client_disconnect",
		"invalid_provider_usage":
		return true
	}
	return false
}

type coordRow struct {
	// RequestID is the coordinator's internal id; it is NEVER equal to
	// the inbound X-Request-ID and is unsafe to join across services
	// (phase4-coordinator/internal/requestlog/store.go:34-46). For
	// cross-service correlation use ExternalRequestID, the
	// gateway-issued id that the coord echoes from
	// X-Request-ID on the inbound request.
	RequestID         string
	ExternalRequestID string
	// AccountID is the buyer's stable account identifier. Per SPEC-002
	// the reconciliation join key is (account_id, external_request_id);
	// matching on external_request_id alone can hit a cross-account row
	// on a shared gateway/coord. Empty string means the source DB
	// pre-dates the column (legacy snapshot) — the matcher treats that
	// as a noop on the account constraint.
	AccountID        string
	Model            string
	CompletionTokens int64
	Status           int
	TsUTC            time.Time
}

type gwRow struct {
	RequestID string
	// AccountID is the buyer's stable account identifier. usage_events
	// PK is composite (account_id, request_id); matching on request_id
	// alone can hit a cross-account row on a shared gateway. Empty
	// string means the snapshot pre-dates the column (legacy / partial
	// migration), in which case the matcher treats it as a noop.
	AccountID        string
	CompletionTokens int64
	Outcome          string
	CreatedAt        time.Time
}

// queryCoordinator returns coordinator rows + a schema flag reporting
// whether the request_log.account_id column exists in this snapshot.
// Callers thread the flag through the matcher: column present → blank
// per-row account_ids are real data (NULL = unknown buyer; matcher
// skips), column absent → constraint is a global noop.
func queryCoordinator(path string, start, end time.Time) ([]coordRow, bool, error) {
	db, err := openRO(path)
	if err != nil {
		return nil, false, err
	}
	defer db.Close()
	// SELECT external_request_id and account_id when the columns exist.
	// Schema flags are returned to the matcher so it can distinguish
	// "column absent globally" (legacy snapshot → relax constraint)
	// from "column present but this row's value is NULL/blank"
	// (real missing data → matcher must NOT cross-account-match).
	hasExt, err := columnExists(db, "request_log", "external_request_id")
	if err != nil {
		return nil, false, fmt.Errorf("probe request_log.external_request_id: %w", err)
	}
	hasAcct, err := columnExists(db, "request_log", "account_id")
	if err != nil {
		return nil, false, fmt.Errorf("probe request_log.account_id: %w", err)
	}
	extExpr := "''"
	if hasExt {
		extExpr = "COALESCE(external_request_id, '')"
	}
	acctExpr := "''"
	if hasAcct {
		acctExpr = "COALESCE(account_id, '')"
	}
	rows, err := db.Query(fmt.Sprintf(`
		SELECT request_id, %s, %s, model, COALESCE(completion_tokens, 0), status, ts_utc
		FROM request_log
		WHERE ts_utc >= ? AND ts_utc <= ?
	`, extExpr, acctExpr), start.Format(time.RFC3339Nano), end.Format(time.RFC3339Nano))
	if err != nil {
		return nil, false, err
	}
	defer rows.Close()
	var out []coordRow
	for rows.Next() {
		var c coordRow
		var ts string
		if err := rows.Scan(&c.RequestID, &c.ExternalRequestID, &c.AccountID, &c.Model, &c.CompletionTokens, &c.Status, &ts); err != nil {
			return nil, false, err
		}
		c.TsUTC, _ = time.Parse(time.RFC3339Nano, ts)
		out = append(out, c)
	}
	return out, hasAcct, rows.Err()
}

// columnExists reports whether a column exists on a table via
// PRAGMA table_info, used by the reconcile queries to stay
// backward-compatible with older coord/gateway schemas that lack
// account_id and/or external_request_id (added by ALTER TABLE
// migrations).
func columnExists(db *sql.DB, table, column string) (bool, error) {
	rows, err := db.Query(fmt.Sprintf("PRAGMA table_info(%s)", table))
	if err != nil {
		return false, err
	}
	defer rows.Close()
	for rows.Next() {
		var (
			cid     int
			name    string
			typ     string
			notnull int
			dflt    sql.NullString
			pk      int
		)
		if err := rows.Scan(&cid, &name, &typ, &notnull, &dflt, &pk); err != nil {
			return false, err
		}
		if name == column {
			return true, nil
		}
	}
	return false, rows.Err()
}

// queryGateway returns gateway usage_events rows + a schema flag
// reporting whether the usage_events.account_id column exists in the
// snapshot. Same shape as queryCoordinator.
func queryGateway(path string, start, end time.Time) ([]gwRow, bool, error) {
	db, err := openRO(path)
	if err != nil {
		return nil, false, err
	}
	defer db.Close()
	// SELECT account_id alongside request_id when the column exists.
	// usage_events PK is composite (account_id, request_id) per
	// ISS-196; older snapshots pre-date the migration. Same
	// schema-tolerance shape as queryCoordinator.
	hasAcct, err := columnExists(db, "usage_events", "account_id")
	if err != nil {
		return nil, false, fmt.Errorf("probe usage_events.account_id: %w", err)
	}
	acctExpr := "''"
	if hasAcct {
		acctExpr = "COALESCE(account_id, '')"
	}
	rows, err := db.Query(fmt.Sprintf(`
		SELECT request_id, %s, completion_tokens, outcome, created_at
		FROM usage_events
		WHERE created_at >= ? AND created_at <= ?
	`, acctExpr), start.Format(time.RFC3339Nano), end.Format(time.RFC3339Nano))
	if err != nil {
		return nil, false, err
	}
	defer rows.Close()
	var out []gwRow
	for rows.Next() {
		var g gwRow
		var ts string
		if err := rows.Scan(&g.RequestID, &g.AccountID, &g.CompletionTokens, &g.Outcome, &ts); err != nil {
			return nil, false, err
		}
		g.CreatedAt, _ = time.Parse(time.RFC3339Nano, ts)
		out = append(out, g)
	}
	return out, hasAcct, rows.Err()
}

// harnessRequestIDs extracts the unique non-empty request IDs the
// harness recorded from gateway responses. Used by the by-ID recovery
// pass to bypass the forward-only snapshot window for rows the harness
// definitively owns (clock-skew mitigation; see snapshotWindow).
func harnessRequestIDs(results []buyer.Result) []string {
	if len(results) == 0 {
		return nil
	}
	seen := make(map[string]bool, len(results))
	out := make([]string, 0, len(results))
	for _, res := range results {
		if res.RequestID == "" || seen[res.RequestID] {
			continue
		}
		seen[res.RequestID] = true
		out = append(out, res.RequestID)
	}
	return out
}

// queryGatewayByIDs returns gateway rows whose request_id is in the
// supplied set, regardless of created_at. Companion to queryGateway
// for the by-ID recovery pass.
func queryGatewayByIDs(path string, ids []string) ([]gwRow, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	db, err := openRO(path)
	if err != nil {
		return nil, err
	}
	defer db.Close()
	hasAcct, err := columnExists(db, "usage_events", "account_id")
	if err != nil {
		return nil, fmt.Errorf("probe usage_events.account_id: %w", err)
	}
	acctExpr := "''"
	if hasAcct {
		acctExpr = "COALESCE(account_id, '')"
	}
	placeholders, args := inClause(ids)
	rows, err := db.Query(fmt.Sprintf(`
		SELECT request_id, %s, completion_tokens, outcome, created_at
		FROM usage_events
		WHERE request_id IN (%s)
	`, acctExpr, placeholders), args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []gwRow
	for rows.Next() {
		var g gwRow
		var ts string
		if err := rows.Scan(&g.RequestID, &g.AccountID, &g.CompletionTokens, &g.Outcome, &ts); err != nil {
			return nil, err
		}
		g.CreatedAt, _ = time.Parse(time.RFC3339Nano, ts)
		out = append(out, g)
	}
	return out, rows.Err()
}

// queryCoordinatorByIDs returns coord rows whose external_request_id
// is in the supplied set, regardless of ts_utc. Companion to
// queryCoordinator for the by-ID recovery pass. Returns no rows when
// the coord schema pre-dates external_request_id (legacy snapshot,
// no cross-service id to filter on).
func queryCoordinatorByIDs(path string, ids []string) ([]coordRow, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	db, err := openRO(path)
	if err != nil {
		return nil, err
	}
	defer db.Close()
	hasExt, err := columnExists(db, "request_log", "external_request_id")
	if err != nil {
		return nil, fmt.Errorf("probe request_log.external_request_id: %w", err)
	}
	if !hasExt {
		return nil, nil
	}
	hasAcct, err := columnExists(db, "request_log", "account_id")
	if err != nil {
		return nil, fmt.Errorf("probe request_log.account_id: %w", err)
	}
	acctExpr := "''"
	if hasAcct {
		acctExpr = "COALESCE(account_id, '')"
	}
	placeholders, args := inClause(ids)
	rows, err := db.Query(fmt.Sprintf(`
		SELECT request_id, COALESCE(external_request_id, ''), %s, model, COALESCE(completion_tokens, 0), status, ts_utc
		FROM request_log
		WHERE external_request_id IN (%s)
	`, acctExpr, placeholders), args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []coordRow
	for rows.Next() {
		var c coordRow
		var ts string
		if err := rows.Scan(&c.RequestID, &c.ExternalRequestID, &c.AccountID, &c.Model, &c.CompletionTokens, &c.Status, &ts); err != nil {
			return nil, err
		}
		c.TsUTC, _ = time.Parse(time.RFC3339Nano, ts)
		out = append(out, c)
	}
	return out, rows.Err()
}

// inClause builds a `?, ?, ?` placeholder list and the matching args
// slice for an `IN (...)` SQL clause. Caller guarantees ids is non-
// empty (queryGatewayByIDs / queryCoordinatorByIDs short-circuit).
func inClause(ids []string) (string, []any) {
	placeholders := strings.Repeat("?,", len(ids))
	placeholders = placeholders[:len(placeholders)-1]
	args := make([]any, len(ids))
	for i, id := range ids {
		args[i] = id
	}
	return placeholders, args
}

// mergeGwByID appends rows from b that are not already present in a,
// keyed on (account_id, request_id) — gateway's composite PK shape.
// Falls back to request_id alone when account_id is empty (legacy
// snapshot). Stable order: existing a-rows kept in place, novel
// b-rows appended.
func mergeGwByID(a, b []gwRow) []gwRow {
	if len(b) == 0 {
		return a
	}
	seen := make(map[string]bool, len(a)+len(b))
	for _, r := range a {
		seen[r.AccountID+"|"+r.RequestID] = true
	}
	for _, r := range b {
		k := r.AccountID + "|" + r.RequestID
		if seen[k] {
			continue
		}
		seen[k] = true
		a = append(a, r)
	}
	return a
}

// mergeCoordByID appends rows from b that are not already present in
// a, keyed on the coord-internal request_id (the PK of request_log).
func mergeCoordByID(a, b []coordRow) []coordRow {
	if len(b) == 0 {
		return a
	}
	seen := make(map[string]bool, len(a)+len(b))
	for _, r := range a {
		seen[r.RequestID] = true
	}
	for _, r := range b {
		if seen[r.RequestID] {
			continue
		}
		seen[r.RequestID] = true
		a = append(a, r)
	}
	return a
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
